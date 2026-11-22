// Derived from MIT/GNU Scheme C sources (`src/microcode/prospty.c`, `src/microcode/ospty.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const transact = @import("../support/transact.zig");
const string = @import("../data/string.zig");

fn argPtyMaster(arg: c_int) abi.Tchannel {
    _ = arg;
    const channel = abi.arg_channel(1);
    if (abi.OS_channel_type(channel) != @backingInt(abi.ChannelType.unix_pty_master)) {
        abi.error_bad_range_arg(1);
    }
    return channel;
}

// DEFINE_PRIMITIVE ("OPEN-PTY-MASTER", Prim_open_pty_master, 0, 0,
//   "Open a PTY master, returning the master's channel and the slave's name.\n\
// Returns a vector #(CHANNEL MASTER-NAME SLAVE-NAME).")
pub export fn Prim_open_pty_master() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var channel: abi.Tchannel = undefined;
    var master_name: [*:0]const u8 = undefined;
    const slave_name = abi.OS_open_pty_master(&channel, &master_name);
    transact.transaction_begin();
    abi.OS_channel_close_on_abort(channel);
    const vector = abi.allocate_vector(3, true);
    obj.vectorSet(vector, 0, abi.long_to_integer(@intCast(channel)));
    obj.vectorSet(vector, 1, string.char_pointer_to_string(master_name));
    obj.vectorSet(vector, 2, string.char_pointer_to_string(slave_name));
    transact.transaction_commit();
    return vector;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-SEND-SIGNAL", Prim_pty_master_send_signal, 2, 2,
//   "Send a signal to PTY-MASTER; second arg says which one.")
pub export fn Prim_pty_master_send_signal() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_send_signal(argPtyMaster(1), @intCast(abi.arg_nonnegative_integer(2)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-KILL", Prim_pty_master_kill, 1, 1, 0)
pub export fn Prim_pty_master_kill() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_kill(argPtyMaster(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-STOP", Prim_pty_master_stop, 1, 1, 0)
pub export fn Prim_pty_master_stop() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_stop(argPtyMaster(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-CONTINUE", Prim_pty_master_continue, 1, 1, 0)
pub export fn Prim_pty_master_continue() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_continue(argPtyMaster(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-INTERRUPT", Prim_pty_master_interrupt, 1, 1, 0)
pub export fn Prim_pty_master_interrupt() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_interrupt(argPtyMaster(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-QUIT", Prim_pty_master_quit, 1, 1, 0)
pub export fn Prim_pty_master_quit() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_quit(argPtyMaster(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PTY-MASTER-HANGUP", Prim_pty_master_hangup, 1, 1, 0)
pub export fn Prim_pty_master_hangup() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_pty_master_hangup(argPtyMaster(1));
    return obj.unspecific;
}

test "prospty open-pty-master and master signal primitives" {
    const stubs = @import("../core/test_stubs.zig");
    const wind = @import("../support/wind.zig");
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    defer wind.dstack_reset();
    defer stubs.resetMockRuntime();

    stubs.setArgs(&.{});
    const vec = Prim_open_pty_master();
    const ch = obj.vectorRef(vec, 0);
    const master_s = obj.vectorRef(vec, 1);
    const slave_s = obj.vectorRef(vec, 2);
    try std.testing.expectEqualStrings("/dev/ptym0", obj.legacyStringData(master_s)[0..obj.legacyStringLength(master_s)]);
    try std.testing.expectEqualStrings("/dev/ptys0", obj.legacyStringData(slave_s)[0..obj.legacyStringLength(slave_s)]);

    stubs.setArgs(&.{ ch, obj.ulongToFixnum(9) });
    _ = Prim_pty_master_send_signal();
    try std.testing.expectEqual(@as(c_int, 9), stubs.mock_last_pty_sig);

    stubs.setArgs(&.{ch});
    _ = Prim_pty_master_kill();
    _ = Prim_pty_master_stop();
    _ = Prim_pty_master_continue();
    _ = Prim_pty_master_interrupt();
    _ = Prim_pty_master_quit();
    _ = Prim_pty_master_hangup();
    try std.testing.expectEqual(@as(usize, 6), stubs.mock_pty_ops);
}
