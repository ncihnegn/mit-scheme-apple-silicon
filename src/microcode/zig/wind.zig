// Derived from MIT/GNU Scheme C sources (`src/microcode/wind.c`, `src/microcode/dstack.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
pub const obstack = @import("obstack.zig");
const outf = @import("outf.zig");

// Ensure obstack exports are emitted when wind.zig is built standalone (e.g. test-smoke).
comptime {
    _ = obstack;
}

extern "c" fn OS_malloc(size: usize) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;
extern "c" fn abort() noreturn;
extern "c" fn block_signals() void;
extern "c" fn unblock_signals() void;

pub const ProtectorFn = *const fn (?*anyopaque) callconv(.c) void;
pub const InitializerFn = *const fn (?*anyopaque) callconv(.c) void;

const WindingRecord = extern struct {
    next: ?*WindingRecord,
    protector: ProtectorFn,
    environment: ?*anyopaque,
};

const BindingRecord = extern struct {
    location: *?*anyopaque,
    value: ?*anyopaque,
};

var dstack: obstack.Obstack = undefined;
var current_winding_record: ?*WindingRecord = null;
pub export var dstack_position: ?*anyopaque = null;
var save_binding_location: ?*?*anyopaque = null;

fn fatalError(procedure_name: [*:0]const u8, message: [*:0]const u8) noreturn {
    outf.fatal("{s}: {s}\n", .{ procedure_name, message });
    outf.flushFatal();
    abort();
}

inline fn exportPtr(sp: anytype) ?*anyopaque {
    return @ptrCast(@as([*]u8, @ptrCast(sp)) + @sizeOf(?*anyopaque));
}

pub export fn dstack_initialize() callconv(.c) void {
    dstack.init(&OS_malloc, &free);
    dstack_position = null;
    current_winding_record = null;
}

pub export fn dstack_reset() callconv(.c) void {
    block_signals();
    dstack.freeObj(null);
    dstack_initialize();
    unblock_signals();
}

pub export fn dstack_alloc(length: c_uint) callconv(.c) ?*anyopaque {
    block_signals();
    const chunk = dstack.alloc(@sizeOf(?*anyopaque) + @as(usize, length));
    const link: *?*anyopaque = @ptrCast(@alignCast(chunk));
    link.* = dstack_position;
    dstack_position = @ptrCast(chunk);
    unblock_signals();
    return exportPtr(chunk);
}

pub export fn dstack_protect(protector: ProtectorFn, environment: ?*anyopaque) callconv(.c) void {
    const raw = dstack_alloc(@sizeOf(WindingRecord)).?;
    const record: *WindingRecord = @ptrCast(@alignCast(raw));
    record.next = current_winding_record;
    record.protector = protector;
    record.environment = environment;
    current_winding_record = record;
}

pub export fn dstack_alloc_and_protect(
    length: c_uint,
    initializer: InitializerFn,
    protector: ProtectorFn,
) callconv(.c) void {
    const raw = dstack_alloc(@as(c_uint, @sizeOf(WindingRecord)) + length).?;
    const record: *WindingRecord = @ptrCast(@alignCast(raw));
    const environment: ?*anyopaque = @ptrCast(@as([*]u8, @ptrCast(raw)) + @sizeOf(WindingRecord));
    initializer(environment);
    record.next = current_winding_record;
    record.protector = protector;
    record.environment = environment;
    current_winding_record = record;
}

pub export fn dstack_set_position(position: ?*anyopaque) callconv(.c) void {
    block_signals();
    {
        var scan: ?*?*anyopaque = @ptrCast(@alignCast(dstack_position));
        while (@as(?*anyopaque, @ptrCast(scan)) != position) {
            const sp = scan orelse fatalError("dstack_set_position", "position argument not found");
            scan = @ptrCast(@alignCast(sp.*));
        }
    }
    while (dstack_position != position) {
        const sp: *?*anyopaque = @ptrCast(@alignCast(
            dstack_position orelse fatalError("dstack_set_position", "no more stack"),
        ));
        if (exportPtr(sp) == @as(?*anyopaque, @ptrCast(current_winding_record))) {
            const record = current_winding_record.?;
            // Must unblock signals while the protector runs, and re-block afterwards,
            // in case the protector modifies the signal mask.
            unblock_signals();
            record.protector(record.environment);
            block_signals();
            if (@as(?*anyopaque, @ptrCast(sp)) != dstack_position) {
                fatalError("dstack_set_position", "stack slipped during unwind");
            }
            current_winding_record = record.next;
        }
        dstack_position = sp.*;
        dstack.freeObj(@ptrCast(sp));
    }
    unblock_signals();
}

fn undoBinding(environment: ?*anyopaque) callconv(.c) void {
    const binding: *BindingRecord = @ptrCast(@alignCast(environment.?));
    binding.location.* = binding.value;
}

fn saveBinding(environment: ?*anyopaque) callconv(.c) void {
    const binding: *BindingRecord = @ptrCast(@alignCast(environment.?));
    const loc = save_binding_location.?;
    binding.location = loc;
    binding.value = loc.*;
}

pub export fn dstack_bind(location: ?*anyopaque, value: ?*anyopaque) callconv(.c) void {
    const loc: *?*anyopaque = @ptrCast(@alignCast(location.?));
    save_binding_location = loc;
    dstack_alloc_and_protect(@sizeOf(BindingRecord), &saveBinding, &undoBinding);
    loc.* = value;
}

test "dstack unwind order, dstack_bind, and signal unblocking in protectors" {
    const stubs = @import("test_stubs.zig");
    stubs.signal_block_depth = 0;

    const Recorder = struct {
        var order_buf: [8]usize = @splat(0);
        var order_len: usize = 0;
        var depths: [8]i32 = @splat(0);
        var slots: [2]usize = .{ 111, 222 };

        fn record(env: ?*anyopaque) callconv(.c) void {
            const tag = @intFromPtr(env);
            order_buf[order_len] = tag;
            depths[order_len] = stubs.signal_block_depth;
            order_len += 1;
        }

        fn initSlot(env: ?*anyopaque) callconv(.c) void {
            const p: *usize = @ptrCast(@alignCast(env.?));
            p.* = 77;
        }

        fn unwindSlot(env: ?*anyopaque) callconv(.c) void {
            const p: *usize = @ptrCast(@alignCast(env.?));
            order_buf[order_len] = p.*;
            depths[order_len] = stubs.signal_block_depth;
            order_len += 1;
        }
    };

    dstack_initialize();
    defer dstack_reset();

    Recorder.order_len = 0;
    var bound_val: ?*anyopaque = @ptrFromInt(0x100);
    const outer_pos = dstack_position;

    _ = dstack_alloc(32);
    dstack_protect(&Recorder.record, @ptrFromInt(1));
    dstack_bind(@ptrCast(&bound_val), @ptrFromInt(0x200));
    try std.testing.expectEqual(@as(usize, 0x200), @intFromPtr(bound_val));

    const inner_pos = dstack_position;
    dstack_bind(@ptrCast(&bound_val), @ptrFromInt(0x300));
    try std.testing.expectEqual(@as(usize, 0x300), @intFromPtr(bound_val));
    dstack_protect(&Recorder.record, @ptrFromInt(2));
    dstack_alloc_and_protect(@sizeOf(usize), &Recorder.initSlot, &Recorder.unwindSlot);

    dstack_set_position(inner_pos);
    try std.testing.expectEqual(@as(usize, 2), Recorder.order_len);
    try std.testing.expectEqual(@as(usize, 77), Recorder.order_buf[0]);
    try std.testing.expectEqual(@as(usize, 2), Recorder.order_buf[1]);
    try std.testing.expectEqual(@as(i32, 0), Recorder.depths[0]);
    try std.testing.expectEqual(@as(i32, 0), Recorder.depths[1]);
    try std.testing.expectEqual(@as(usize, 0x200), @intFromPtr(bound_val));
    try std.testing.expectEqual(@as(i32, 0), stubs.signal_block_depth);

    dstack_set_position(outer_pos);
    try std.testing.expectEqual(@as(usize, 3), Recorder.order_len);
    try std.testing.expectEqual(@as(usize, 1), Recorder.order_buf[2]);
    try std.testing.expectEqual(@as(i32, 0), Recorder.depths[2]);
    try std.testing.expectEqual(@as(usize, 0x100), @intFromPtr(bound_val));
    try std.testing.expectEqual(@as(?*anyopaque, null), dstack_position);
    try std.testing.expectEqual(@as(i32, 0), stubs.signal_block_depth);
}
