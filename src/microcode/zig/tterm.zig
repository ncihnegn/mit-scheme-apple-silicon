// Derived from MIT/GNU Scheme C sources (`src/microcode/tterm.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");
const wind = @import("wind.zig");
const transact = @import("transact.zig");

const termcap_buffer_size: usize = 2048;

extern "c" fn tgetent([*]u8, [*:0]const u8) c_int;
extern "c" fn tgetnum([*:0]const u8) c_int;
extern "c" fn tgetflag([*:0]const u8) c_int;
extern "c" fn tgetstr([*:0]const u8, *[*]u8) ?[*:0]u8;
extern "c" fn tgoto([*:0]const u8, c_int, c_int) ?[*:0]u8;
extern "c" fn tputs([*:0]const u8, c_int, *const fn (c_int) callconv(.c) c_int) c_int;
extern "c" fn tparm([*:0]const u8, ...) ?[*:0]u8;
extern "c" fn tparam([*:0]const u8, [*]u8, c_int, c_int, c_int, c_int, c_int) ?[*:0]u8;

extern "c" var BC: ?[*:0]u8;
extern "c" var UP: ?[*:0]u8;
extern "c" var PC: u8;
extern "c" var ospeed: c_short;

var termcap_buffer: [termcap_buffer_size]u8 = undefined;
var tgetstr_buffer: [termcap_buffer_size]u8 = undefined;
var tgetstr_pointer: [*]u8 = &tgetstr_buffer;

var tputs_output: [termcap_buffer_size]u8 = undefined;
var tputs_output_scan: [*]u8 = &tputs_output;

fn tputsWriteChar(c: c_int) callconv(.c) c_int {
    if (@intFromPtr(tputs_output_scan) >= @intFromPtr(&tputs_output) + termcap_buffer_size) {
        abi.error_external_return();
    }
    tputs_output_scan[0] = @truncate(@as(c_uint, @bitCast(c)));
    tputs_output_scan += 1;
    return c;
}

// DEFINE_PRIMITIVE ("TERMCAP-INITIALIZE", Prim_termcap_initialize, 1, 1, 0)
pub export fn Prim_termcap_initialize() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    tgetstr_pointer = &tgetstr_buffer;
    return obj.booleanToObject(tgetent(&termcap_buffer, abi.stringArg(1)) > 0);
}

// DEFINE_PRIMITIVE ("TERMCAP-GET-NUMBER", Prim_termcap_get_number, 1, 1, 0)
pub export fn Prim_termcap_get_number() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = tgetnum(abi.stringArg(1));
    return if (result < 0) obj.sharp_f else abi.long_to_integer(result);
}

// DEFINE_PRIMITIVE ("TERMCAP-GET-FLAG", Prim_termcap_get_flag, 1, 1, 0)
pub export fn Prim_termcap_get_flag() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(tgetflag(abi.stringArg(1)) != 0);
}

// DEFINE_PRIMITIVE ("TERMCAP-GET-STRING", Prim_termcap_get_string, 1, 1, 0)
pub export fn Prim_termcap_get_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = tgetstr(abi.stringArg(1), &tgetstr_pointer) orelse return obj.sharp_f;
    return string.char_pointer_to_string(result);
}

const TcEnv = struct {
    string_buffer: [*]u8,
    string_pointer: ?[*:0]u8,
};

fn protectTc(environment: ?*anyopaque) callconv(.c) void {
    const env: *const TcEnv = @ptrCast(@alignCast(environment.?));
    if (env.string_pointer) |pointer| {
        if (@as([*]u8, @ptrCast(pointer)) != env.string_buffer) {
            std.c.free(pointer);
        }
    }
}

// DEFINE_PRIMITIVE ("TERMCAP-PARAM-STRING", Prim_termcap_param_string, 5, 5, 0)
pub export fn Prim_termcap_param_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const fmt = abi.stringArg(1);
    const a1: c_int = @truncate(abi.arg_nonnegative_integer(2));
    const a2: c_int = @truncate(abi.arg_nonnegative_integer(3));
    const a3: c_int = @truncate(abi.arg_nonnegative_integer(4));
    const a4: c_int = @truncate(abi.arg_nonnegative_integer(5));
    if (comptime (build_options.use_terminfo and !builtin.is_test)) {
        const ptr = tparm(
            fmt,
            @as(c_long, a1),
            @as(c_long, a2),
            @as(c_long, a3),
            @as(c_long, a4),
            @as(c_long, 0),
            @as(c_long, 0),
            @as(c_long, 0),
            @as(c_long, 0),
            @as(c_long, 0),
        ) orelse abi.error_external_return();
        return string.char_pointer_to_string(ptr);
    } else {
        var string_buffer: [4096]u8 = undefined;
        var env = TcEnv{
            .string_buffer = &string_buffer,
            .string_pointer = null,
        };
        transact.transaction_begin();
        wind.dstack_protect(&protectTc, @ptrCast(&env));
        env.string_pointer = tparam(fmt, &string_buffer, string_buffer.len, a1, a2, a3, a4);
        const ptr = env.string_pointer orelse abi.error_external_return();
        const result = string.char_pointer_to_string(ptr);
        transact.transaction_commit();
        return result;
    }
}

fn protectFree(environment: ?*anyopaque) callconv(.c) void {
    const pointer_ref: *?[*:0]u8 = @ptrCast(@alignCast(environment.?));
    if (pointer_ref.*) |pointer| {
        std.c.free(pointer);
    }
}

// DEFINE_PRIMITIVE ("TERMCAP-GOTO-STRING", Prim_termcap_goto_string, 5, 5, 0)
pub export fn Prim_termcap_goto_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var string_pointer: ?[*:0]u8 = null;
    BC = if (abi.argRef(4) == obj.sharp_f) null else abi.stringArg(4);
    UP = if (abi.argRef(5) == obj.sharp_f) null else abi.stringArg(5);
    transact.transaction_begin();
    wind.dstack_protect(&protectFree, @ptrCast(&string_pointer));
    string_pointer = tgoto(
        abi.stringArg(1),
        @truncate(abi.arg_nonnegative_integer(2)),
        @truncate(abi.arg_nonnegative_integer(3)),
    );
    const ptr = string_pointer orelse abi.error_external_return();
    const result = string.char_pointer_to_string(ptr);
    transact.transaction_commit();
    return result;
}

// DEFINE_PRIMITIVE ("TERMCAP-PAD-STRING", Prim_termcap_pad_string, 4, 4, 0)
pub export fn Prim_termcap_pad_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    ospeed = @bitCast(@as(u16, @truncate(abi.arg_baud_index(3))));
    PC = if (abi.argRef(4) == obj.sharp_f) 0 else abi.stringArg(4)[0];
    tputs_output_scan = &tputs_output;
    _ = tputs(abi.stringArg(1), @truncate(abi.arg_nonnegative_integer(2)), &tputsWriteChar);
    const n_bytes: usize = @intCast(@intFromPtr(tputs_output_scan) - @intFromPtr(&tputs_output));
    return string.memory_to_string(n_bytes, &tputs_output);
}

test "tterm termcap initialize, query, param, goto, and pad primitives" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    defer {
        transact.transaction_initialize();
        wind.dstack_reset();
        stubs.resetMockRuntime();
    }

    stubs.setArgs(&.{string.char_pointer_to_string("xterm")});
    try std.testing.expectEqual(obj.sharp_t, Prim_termcap_initialize());

    stubs.setArgs(&.{string.char_pointer_to_string("co")});
    try std.testing.expectEqual(obj.ulongToFixnum(80), Prim_termcap_get_number());

    stubs.setArgs(&.{string.char_pointer_to_string("am")});
    try std.testing.expectEqual(obj.sharp_t, Prim_termcap_get_flag());

    stubs.setArgs(&.{string.char_pointer_to_string("cl")});
    const cl = Prim_termcap_get_string();
    try std.testing.expectEqualStrings("\x1b[H\x1b[2J", obj.legacyStringData(cl)[0..obj.legacyStringLength(cl)]);

    stubs.setArgs(&.{
        string.char_pointer_to_string("p"),
        obj.ulongToFixnum(1),
        obj.ulongToFixnum(2),
        obj.ulongToFixnum(3),
        obj.ulongToFixnum(4),
    });
    const ps = Prim_termcap_param_string();
    try std.testing.expectEqualStrings("p:1,2,3,4", obj.legacyStringData(ps)[0..obj.legacyStringLength(ps)]);

    stubs.setArgs(&.{
        string.char_pointer_to_string("\x1b[%d;%dH"),
        obj.ulongToFixnum(10),
        obj.ulongToFixnum(20),
        string.char_pointer_to_string("bc"),
        obj.sharp_f,
    });
    const gs = Prim_termcap_goto_string();
    try std.testing.expectEqualStrings("\x1b[21;11H", obj.legacyStringData(gs)[0..obj.legacyStringLength(gs)]);
    try std.testing.expect(BC != null);
    try std.testing.expectEqual(@as(?[*:0]u8, null), UP);

    stubs.setArgs(&.{
        string.char_pointer_to_string("ABC"),
        obj.ulongToFixnum(1),
        obj.ulongToFixnum(3),
        string.char_pointer_to_string("."),
    });
    const padded = Prim_termcap_pad_string();
    try std.testing.expectEqualStrings("ABC", obj.legacyStringData(padded)[0..obj.legacyStringLength(padded)]);
    try std.testing.expectEqual(@as(u8, '.'), PC);
    try std.testing.expectEqual(@as(c_short, 3), ospeed);
}
