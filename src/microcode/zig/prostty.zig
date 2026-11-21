// Derived from MIT/GNU Scheme C sources (`src/microcode/prostty.c`, `src/microcode/ostty.h`, `src/microcode/osctty.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");

// DEFINE_PRIMITIVE ("TTY-INPUT-CHANNEL", Prim_tty_input_channel, 0, 0,
//   "Return the standard input channel.")
pub export fn Prim_tty_input_channel() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_tty_input_channel()));
}

// DEFINE_PRIMITIVE ("TTY-OUTPUT-CHANNEL", Prim_tty_output_channel, 0, 0,
//   "Return the standard output channel.")
pub export fn Prim_tty_output_channel() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_tty_output_channel()));
}

// DEFINE_PRIMITIVE ("TTY-ERROR-CHANNEL", Prim_tty_error_channel, 0, 0,
//   "Return the standard error channel.")
pub export fn Prim_tty_error_channel() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_tty_error_channel()));
}

// DEFINE_PRIMITIVE ("TTY-X-SIZE", Prim_tty_x_size, 0, 0,
//   "Return the display width in character columns.")
pub export fn Prim_tty_x_size() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_tty_x_size()));
}

// DEFINE_PRIMITIVE ("TTY-Y-SIZE", Prim_tty_y_size, 0, 0,
//   "Return the display height in character lines.")
pub export fn Prim_tty_y_size() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_tty_y_size()));
}

// DEFINE_PRIMITIVE ("TTY-COMMAND-BEEP", Prim_tty_command_beep, 0, 0,
//   "Return a string that, when written to the display, will make it beep.")
pub export fn Prim_tty_command_beep() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return string.char_pointer_to_string(abi.OS_tty_command_beep());
}

// DEFINE_PRIMITIVE ("TTY-COMMAND-CLEAR", Prim_tty_command_clear, 0, 0,
//   "Return a string that, when written to the display, will clear it.")
pub export fn Prim_tty_command_clear() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return string.char_pointer_to_string(abi.OS_tty_command_clear());
}

// DEFINE_PRIMITIVE ("TTY-NEXT-INTERRUPT-CHAR", Prim_tty_next_interrupt_char, 0, 0,
//   "Return the next interrupt character in the console input buffer.\n\
// The character is returned as an unsigned integer.")
pub export fn Prim_tty_next_interrupt_char() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_tty_next_interrupt_char()));
}

// DEFINE_PRIMITIVE ("TTY-GET-INTERRUPT-ENABLES", Prim_tty_get_interrupt_enables, 0, 0,
//   "Return the current keyboard interrupt enables.")
pub export fn Prim_tty_get_interrupt_enables() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var mask: abi.TinterruptEnables = undefined;
    abi.OS_ctty_get_interrupt_enables(&mask);
    return abi.long_to_integer(@intCast(mask));
}

// DEFINE_PRIMITIVE ("TTY-SET-INTERRUPT-ENABLES", Prim_tty_set_interrupt_enables, 1, 1,
//   "Change the keyboard interrupt enables to MASK.")
pub export fn Prim_tty_set_interrupt_enables() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var mask: abi.TinterruptEnables = @truncate(@as(usize, @bitCast(abi.arg_integer(1))));
    abi.OS_ctty_set_interrupt_enables(&mask);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TTY-GET-INTERRUPT-CHARS", Prim_tty_get_interrupt_chars, 0, 0,
//   "Return the current interrupt characters as a string.")
pub export fn Prim_tty_get_interrupt_chars() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const num_chars = abi.OS_ctty_num_int_chars();
    const result = abi.allocate_string(@intCast(num_chars * 2));
    const int_chars = abi.OS_ctty_get_int_chars();
    const int_handlers = abi.OS_ctty_get_int_char_handlers();
    const scan = obj.legacyStringData(result);
    for (0..@intCast(num_chars)) |i| {
        scan[i * 2] = int_chars[i];
        scan[i * 2 + 1] = int_handlers[i];
    }
    return result;
}

// DEFINE_PRIMITIVE ("TTY-SET-INTERRUPT-CHARS!", Prim_tty_set_interrupt_chars, 1, 1,
//   "Change the current interrupt characters to STRING.\n\
// STRING must be in the correct form for this operating system.")
pub export fn Prim_tty_set_interrupt_chars() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const num_chars = abi.OS_ctty_num_int_chars();
    const int_chars = abi.OS_ctty_get_int_chars();
    const int_handlers = abi.OS_ctty_get_int_char_handlers();
    const argument = abi.argRef(1);
    if (!(abi.string_p(argument) and @as(c_uint, @intCast(obj.legacyStringLength(argument))) == num_chars * 2)) {
        abi.error_wrong_type_arg(1);
    }
    const scan = obj.legacyStringData(argument);
    for (0..@intCast(num_chars)) |i| {
        int_chars[i] = scan[i * 2];
        int_handlers[i] = scan[i * 2 + 1];
    }
    abi.OS_ctty_set_int_chars(int_chars);
    abi.OS_ctty_set_int_char_handlers(int_handlers);
    return obj.unspecific;
}

test "prostty channels, dimensions, beep/clear, and interrupt chars" {
    const stubs = @import("test_stubs.zig");
    const ostty = @import("ostty.zig");
    stubs.resetMockRuntime();
    ostty.resetForTesting();
    defer ostty.resetForTesting();
    defer stubs.resetMockRuntime();

    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_tty_input_channel());
    try std.testing.expectEqual(obj.ulongToFixnum(1), Prim_tty_output_channel());
    try std.testing.expectEqual(obj.ulongToFixnum(2), Prim_tty_error_channel());
    try std.testing.expectEqual(obj.ulongToFixnum(80), Prim_tty_x_size());
    try std.testing.expectEqual(obj.ulongToFixnum(24), Prim_tty_y_size());
    ostty.tty_set_next_interrupt_char(3);
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_tty_next_interrupt_char());

    const beep = Prim_tty_command_beep();
    try std.testing.expectEqualStrings("\x07", obj.legacyStringData(beep)[0..obj.legacyStringLength(beep)]);
    const clr = Prim_tty_command_clear();
    try std.testing.expectEqualStrings("\x1b[2J", obj.legacyStringData(clr)[0..obj.legacyStringLength(clr)]);

    stubs.setArgs(&.{obj.ulongToFixnum(5)});
    _ = Prim_tty_set_interrupt_enables();
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.ulongToFixnum(5), Prim_tty_get_interrupt_enables());

    const ic = Prim_tty_get_interrupt_chars();
    try std.testing.expectEqual(@as(usize, 4), obj.legacyStringLength(ic));
    const next_ic = string.char_pointer_to_string("\x03a\x07b");
    stubs.setArgs(&.{next_ic});
    _ = Prim_tty_set_interrupt_chars();
    stubs.setArgs(&.{});
    const ic2 = Prim_tty_get_interrupt_chars();
    try std.testing.expectEqualStrings("\x03a\x07b", obj.legacyStringData(ic2)[0..4]);
}
