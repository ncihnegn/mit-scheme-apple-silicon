// Derived from MIT/GNU Scheme C sources (`src/microcode/transact.c`, `src/microcode/dstack.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
pub const wind = @import("wind.zig");
const outf = @import("outf.zig");

// Ensure wind + obstack exports are emitted when transact.zig is built standalone (e.g. test-smoke).
comptime {
    _ = wind;
}

pub const TransactionActionType = enum(c_int) {
    tat_abort = 0,
    tat_commit = 1,
    tat_always = 2,
};

pub const ActionFn = *const fn (?*anyopaque) callconv(.c) void;

const TransactionState = enum {
    active,
    aborting,
    committing,
};

const Transaction = struct {
    checkpoint: ?*anyopaque,
    state: TransactionState,
};

const Action = struct {
    action_type: TransactionActionType,
    procedure: ActionFn,
    environment: ?*anyopaque,
};

var current_transaction: ?*Transaction = null;

fn fatalError(procedure_name: [*:0]const u8, message: [*:0]const u8) noreturn {
    outf.fatal("{s}: {s}\n", .{ procedure_name, message });
    outf.flushFatal();
    std.c.abort();
}

fn guaranteeCurrentTransaction(proc_name: [*:0]const u8) *Transaction {
    const txn = current_transaction orelse fatalError(proc_name, "no transaction");
    switch (txn.state) {
        .committing => fatalError(proc_name, "commit in progress"),
        .aborting => fatalError(proc_name, "abort in progress"),
        .active => return txn,
    }
}

pub export fn transaction_initialize() callconv(.c) void {
    current_transaction = null;
}

pub export fn transaction_begin() callconv(.c) void {
    const checkpoint = wind.dstack_position;
    const raw = wind.dstack_alloc(@sizeOf(Transaction)).?;
    const txn: *Transaction = @ptrCast(@alignCast(raw));
    txn.checkpoint = checkpoint;
    txn.state = .active;
    wind.dstack_bind(@ptrCast(&current_transaction), @ptrCast(txn));
}

pub export fn transaction_abort() callconv(.c) void {
    const txn = guaranteeCurrentTransaction("transaction_abort");
    txn.state = .aborting;
    wind.dstack_set_position(txn.checkpoint);
}

pub export fn transaction_commit() callconv(.c) void {
    const txn = guaranteeCurrentTransaction("transaction_commit");
    txn.state = .committing;
    wind.dstack_set_position(txn.checkpoint);
}

fn executeAction(raw_action: ?*anyopaque) callconv(.c) void {
    const action: *const Action = @ptrCast(@alignCast(raw_action.?));
    const skipped: TransactionActionType = if (current_transaction.?.state == .committing)
        .tat_abort
    else
        .tat_commit;
    if (action.action_type != skipped) {
        action.procedure(action.environment);
    }
}

pub export fn transaction_record_action(
    action_type: TransactionActionType,
    procedure: ActionFn,
    environment: ?*anyopaque,
) callconv(.c) void {
    _ = guaranteeCurrentTransaction("transaction_record_action");
    const raw = wind.dstack_alloc(@sizeOf(Action)).?;
    const action: *Action = @ptrCast(@alignCast(raw));
    action.action_type = action_type;
    action.procedure = procedure;
    action.environment = environment;
    wind.dstack_protect(&executeAction, @ptrCast(action));
}

test "transaction commit, abort, nested scopes, and raw dstack unwind" {
    _ = @import("../core/test_stubs.zig");

    const Log = struct {
        var buf: [16]usize = @splat(0);
        var len: usize = 0;

        fn push(env: ?*anyopaque) callconv(.c) void {
            buf[len] = @intFromPtr(env);
            len += 1;
        }
    };

    wind.dstack_initialize();
    defer wind.dstack_reset();
    transaction_initialize();

    // Commit skips tat_abort and runs tat_commit + tat_always in LIFO order.
    Log.len = 0;
    transaction_begin();
    transaction_record_action(.tat_abort, &Log.push, @ptrFromInt(10));
    transaction_record_action(.tat_commit, &Log.push, @ptrFromInt(11));
    transaction_record_action(.tat_always, &Log.push, @ptrFromInt(12));
    transaction_commit();
    try std.testing.expectEqual(@as(usize, 2), Log.len);
    try std.testing.expectEqual(@as(usize, 12), Log.buf[0]);
    try std.testing.expectEqual(@as(usize, 11), Log.buf[1]);
    try std.testing.expectEqual(@as(?*Transaction, null), current_transaction);

    // Abort skips tat_commit and runs tat_abort + tat_always in LIFO order.
    Log.len = 0;
    transaction_begin();
    transaction_record_action(.tat_abort, &Log.push, @ptrFromInt(20));
    transaction_record_action(.tat_commit, &Log.push, @ptrFromInt(21));
    transaction_record_action(.tat_always, &Log.push, @ptrFromInt(22));
    transaction_abort();
    try std.testing.expectEqual(@as(usize, 2), Log.len);
    try std.testing.expectEqual(@as(usize, 22), Log.buf[0]);
    try std.testing.expectEqual(@as(usize, 20), Log.buf[1]);
    try std.testing.expectEqual(@as(?*Transaction, null), current_transaction);

    // Nested transactions: outer commit, inner abort.
    Log.len = 0;
    transaction_begin();
    transaction_record_action(.tat_commit, &Log.push, @ptrFromInt(1));
    transaction_begin();
    transaction_record_action(.tat_abort, &Log.push, @ptrFromInt(2));
    transaction_record_action(.tat_commit, &Log.push, @ptrFromInt(3));
    transaction_abort();
    try std.testing.expectEqual(@as(usize, 1), Log.len);
    try std.testing.expectEqual(@as(usize, 2), Log.buf[0]);
    transaction_commit();
    try std.testing.expectEqual(@as(usize, 2), Log.len);
    try std.testing.expectEqual(@as(usize, 1), Log.buf[1]);
    try std.testing.expectEqual(@as(?*Transaction, null), current_transaction);

    // Raw dstack_set_position across an active transaction acts as an implicit abort.
    Log.len = 0;
    const saved_pos = wind.dstack_position;
    transaction_begin();
    transaction_record_action(.tat_abort, &Log.push, @ptrFromInt(30));
    transaction_record_action(.tat_commit, &Log.push, @ptrFromInt(31));
    transaction_record_action(.tat_always, &Log.push, @ptrFromInt(32));
    wind.dstack_set_position(saved_pos);
    try std.testing.expectEqual(@as(usize, 2), Log.len);
    try std.testing.expectEqual(@as(usize, 32), Log.buf[0]);
    try std.testing.expectEqual(@as(usize, 30), Log.buf[1]);
    try std.testing.expectEqual(@as(?*Transaction, null), current_transaction);
}
