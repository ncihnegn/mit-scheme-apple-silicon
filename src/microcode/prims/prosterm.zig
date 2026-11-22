// Derived from MIT/GNU Scheme C sources (`src/microcode/prosterm.c`, `src/microcode/osterm.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");

pub export fn arg_terminal(argument_number: c_int) callconv(.c) abi.Tchannel {
    const channel = abi.arg_channel(argument_number);
    const ch_type = abi.OS_channel_type(channel);
    if (ch_type != @backingInt(abi.ChannelType.terminal) and
        ch_type != @backingInt(abi.ChannelType.unix_pty_master))
    {
        abi.error_bad_range_arg(argument_number);
    }
    return channel;
}

// DEFINE_PRIMITIVE ("TERMINAL-GET-ISPEED", Prim_terminal_get_ispeed, 1, 1, 0)
pub export fn Prim_terminal_get_ispeed() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_terminal_get_ispeed(arg_terminal(1))));
}

// DEFINE_PRIMITIVE ("TERMINAL-GET-OSPEED", Prim_terminal_get_ospeed, 1, 1, 0)
pub export fn Prim_terminal_get_ospeed() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_terminal_get_ospeed(arg_terminal(1))));
}

// DEFINE_PRIMITIVE ("TERMINAL-SET-ISPEED", Prim_terminal_set_ispeed, 2, 2, 0)
pub export fn Prim_terminal_set_ispeed() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_set_ispeed(arg_terminal(1), abi.arg_baud_index(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-SET-OSPEED", Prim_terminal_set_ospeed, 2, 2, 0)
pub export fn Prim_terminal_set_ospeed() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_set_ospeed(arg_terminal(1), abi.arg_baud_index(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("BAUD-INDEX->RATE", Prim_baud_index_to_rate, 1, 1, 0)
pub export fn Prim_baud_index_to_rate() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_baud_index_to_rate(abi.arg_baud_index(1))));
}

// DEFINE_PRIMITIVE ("BAUD-RATE->INDEX", Prim_baud_rate_to_index, 1, 1, 0)
pub export fn Prim_baud_rate_to_index() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const index = abi.OS_baud_rate_to_index(@intCast(abi.arg_nonnegative_integer(1)));
    if (index < 0) abi.error_bad_range_arg(1);
    return abi.long_to_integer(@intCast(index));
}

// DEFINE_PRIMITIVE ("TERMINAL-GET-STATE", Prim_terminal_get_state, 1, 1, 0)
pub export fn Prim_terminal_get_state() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.allocate_string(@intCast(abi.OS_terminal_state_size()));
    abi.OS_terminal_get_state(arg_terminal(1), @ptrCast(obj.legacyStringData(result)));
    return result;
}

// DEFINE_PRIMITIVE ("TERMINAL-SET-STATE", Prim_terminal_set_state, 2, 2, 0)
pub export fn Prim_terminal_set_state() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, abi.string_p);
    const state = abi.argRef(2);
    if (@as(c_uint, @intCast(obj.legacyStringLength(state))) != abi.OS_terminal_state_size()) {
        abi.error_bad_range_arg(2);
    }
    abi.OS_terminal_set_state(arg_terminal(1), @ptrCast(obj.legacyStringData(state)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-COOKED-OUTPUT?", Prim_terminal_cooked_output_p, 1, 1,
//   "Return #F iff TERMINAL is not in cooked output mode.")
pub export fn Prim_terminal_cooked_output_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_terminal_cooked_output_p(arg_terminal(1)) != 0);
}

// DEFINE_PRIMITIVE ("TERMINAL-RAW-OUTPUT", Prim_terminal_raw_output, 1, 1,
//   "Put TERMINAL into raw output mode.")
pub export fn Prim_terminal_raw_output() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_raw_output(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-COOKED-OUTPUT", Prim_terminal_cooked_output, 1, 1,
//   "Put TERMINAL into cooked output mode.")
pub export fn Prim_terminal_cooked_output() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_cooked_output(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-BUFFERED?", Prim_terminal_buffered_p, 1, 1,
//   "Return #F iff TERMINAL is not in buffered mode.")
pub export fn Prim_terminal_buffered_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_terminal_buffered_p(arg_terminal(1)) != 0);
}

// DEFINE_PRIMITIVE ("TERMINAL-BUFFERED", Prim_terminal_buffered, 1, 1,
//   "Put TERMINAL into buffered mode.")
pub export fn Prim_terminal_buffered() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_buffered(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-NONBUFFERED", Prim_terminal_nonbuffered, 1, 1,
//   "Put TERMINAL into nonbuffered mode.")
pub export fn Prim_terminal_nonbuffered() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_nonbuffered(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-FLUSH-INPUT", Prim_terminal_flush_input, 1, 1,
//   "Discard any characters in TERMINAL's input buffer.")
pub export fn Prim_terminal_flush_input() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_flush_input(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-FLUSH-OUTPUT", Prim_terminal_flush_output, 1, 1,
//   "Discard any characters in TERMINAL's output buffer.")
pub export fn Prim_terminal_flush_output() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_flush_output(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TERMINAL-DRAIN-OUTPUT", Prim_terminal_drain_output, 1, 1,
//   "Wait until all characters in TERMINAL's output buffer have been sent.")
pub export fn Prim_terminal_drain_output() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_terminal_drain_output(arg_terminal(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("OS-JOB-CONTROL?", Prim_os_job_control_p, 0, 0, 0)
pub export fn Prim_os_job_control_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_job_control_p() != 0);
}

// DEFINE_PRIMITIVE ("HAVE-PTYS?", Prim_have_ptys_p, 0, 0, 0)
pub export fn Prim_have_ptys_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_have_ptys_p() != 0);
}

test "prosterm terminal modes, baud rates, and state primitives" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    stubs.setMockChannel(1, @backingInt(abi.ChannelType.terminal), false);
    stubs.setArgs(&.{ obj.ulongToFixnum(1), obj.ulongToFixnum(3) });
    _ = Prim_terminal_set_ispeed();
    _ = Prim_terminal_set_ospeed();
    stubs.setArgs(&.{obj.ulongToFixnum(1)});
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_terminal_get_ispeed());
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_terminal_get_ospeed());

    stubs.setArgs(&.{obj.ulongToFixnum(3)});
    try std.testing.expectEqual(obj.ulongToFixnum(9600), Prim_baud_index_to_rate());
    stubs.setArgs(&.{obj.ulongToFixnum(9600)});
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_baud_rate_to_index());

    stubs.setArgs(&.{obj.ulongToFixnum(1)});
    try std.testing.expectEqual(obj.sharp_t, Prim_terminal_cooked_output_p());
    _ = Prim_terminal_raw_output();
    try std.testing.expectEqual(obj.sharp_f, Prim_terminal_cooked_output_p());
    _ = Prim_terminal_cooked_output();
    try std.testing.expectEqual(obj.sharp_t, Prim_terminal_cooked_output_p());

    try std.testing.expectEqual(obj.sharp_t, Prim_terminal_buffered_p());
    _ = Prim_terminal_nonbuffered();
    try std.testing.expectEqual(obj.sharp_f, Prim_terminal_buffered_p());
    _ = Prim_terminal_buffered();
    try std.testing.expectEqual(obj.sharp_t, Prim_terminal_buffered_p());

    const st = Prim_terminal_get_state();
    try std.testing.expectEqual(@as(usize, 4), obj.legacyStringLength(st));
    stubs.setArgs(&.{ obj.ulongToFixnum(1), st });
    _ = Prim_terminal_set_state();

    stubs.setArgs(&.{obj.ulongToFixnum(1)});
    _ = Prim_terminal_flush_input();
    _ = Prim_terminal_flush_output();
    _ = Prim_terminal_drain_output();
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.sharp_t, Prim_os_job_control_p());
    try std.testing.expectEqual(obj.sharp_t, Prim_have_ptys_p());
}
