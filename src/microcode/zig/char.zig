// Derived from MIT/GNU Scheme C sources (`src/microcode/char.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

pub export fn arg_ascii_char(n: c_int) callconv(.c) c_long {
    abi.checkArg(n, obj.characterP);
    const object = abi.argRef(@intCast(n));
    if (!obj.charToAsciiP(object)) abi.error_bad_range_arg(n);
    return @intCast(obj.charToAscii(object));
}

pub export fn arg_ascii_integer(n: c_int) callconv(.c) c_long {
    return abi.arg_index_integer(n, @intCast(obj.max_ascii));
}

// DEFINE_PRIMITIVE ("CHAR?", Prim_char_p, 1, 1, 0)
pub export fn Prim_char_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.characterP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("MAKE-CHAR", Prim_make_char, 2, 2, 0)
pub export fn Prim_make_char() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const bits: c_ulong = @intCast(abi.arg_index_integer(2, @intCast(obj.max_bits)));
    const code: c_ulong = @intCast(abi.arg_index_integer(1, @intCast(obj.max_code)));
    return obj.makeChar(bits, code);
}

// DEFINE_PRIMITIVE ("CHAR-BITS", Prim_char_bits, 1, 1, 0)
pub export fn Prim_char_bits() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.characterP);
    return obj.ulongToFixnum(obj.charBits(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("CHAR-CODE", Prim_char_code, 1, 1, 0)
pub export fn Prim_char_code() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.characterP);
    return obj.ulongToFixnum(obj.charCode(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("CHAR->INTEGER", Prim_char_to_integer, 1, 1, 0)
pub export fn Prim_char_to_integer() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.characterP);
    return obj.ulongToFixnum(abi.argRef(1) & obj.mask_mit_ascii);
}

// DEFINE_PRIMITIVE ("INTEGER->CHAR", Prim_integer_to_char, 1, 1, 0)
pub export fn Prim_integer_to_char() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const code: c_ulong = @intCast(abi.arg_index_integer(1, @intCast(obj.max_mit_ascii)));
    return obj.makeObject(obj.tc_character, code);
}

pub export fn char_downcase(c: c_long) callconv(.c) c_long {
    return if (c >= 'A' and c <= 'Z') (c - 'A') + 'a' else c;
}

pub export fn char_upcase(c: c_long) callconv(.c) c_long {
    return if (c >= 'a' and c <= 'z') (c - 'a') + 'A' else c;
}

// DEFINE_PRIMITIVE ("CHAR-DOWNCASE", Prim_char_downcase, 1, 1, 0)
pub export fn Prim_char_downcase() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.characterP);
    const ch = abi.argRef(1);
    const down: c_ulong = @intCast(char_downcase(@intCast(obj.charCode(ch))));
    return obj.makeChar(obj.charBits(ch), down);
}

// DEFINE_PRIMITIVE ("CHAR-UPCASE", Prim_char_upcase, 1, 1, 0)
pub export fn Prim_char_upcase() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.characterP);
    const ch = abi.argRef(1);
    const up: c_ulong = @intCast(char_upcase(@intCast(obj.charCode(ch))));
    return obj.makeChar(obj.charBits(ch), up);
}

// DEFINE_PRIMITIVE ("ASCII->CHAR", Prim_ascii_to_char, 1, 1, 0)
pub export fn Prim_ascii_to_char() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.asciiToChar(@intCast(abi.arg_index_integer(1, @intCast(obj.max_ascii))));
}

// DEFINE_PRIMITIVE ("CHAR->ASCII", Prim_char_to_ascii, 1, 1, 0)
pub export fn Prim_char_to_ascii() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.longToUnsignedFixnum(arg_ascii_char(1));
}

// DEFINE_PRIMITIVE ("CHAR-ASCII?", Prim_char_ascii_p, 1, 1, 0)
pub export fn Prim_char_ascii_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.characterP);
    const character = abi.argRef(1);
    if (obj.objectDatum(character) >= obj.max_ascii) {
        return obj.sharp_f;
    }
    return obj.ulongToFixnum(obj.charToAscii(character));
}

test "char primitives handle code/bits packing, case folding, and ASCII limits" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{ obj.ulongToFixnum('A'), obj.ulongToFixnum(3) });
    const ch = Prim_make_char();

    stubs.setArgs(&.{ch});
    try std.testing.expectEqual(obj.sharp_t, Prim_char_p());
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_char_bits());
    try std.testing.expectEqual(obj.ulongToFixnum('A'), Prim_char_code());
    try std.testing.expectEqual(obj.sharp_f, Prim_char_ascii_p());

    const lowered = Prim_char_downcase();
    stubs.setArgs(&.{lowered});
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_char_bits());
    try std.testing.expectEqual(obj.ulongToFixnum('a'), Prim_char_code());
    try std.testing.expectEqual(ch, Prim_char_upcase());

    const int_repr = Prim_char_to_integer();
    stubs.setArgs(&.{int_repr});
    try std.testing.expectEqual(lowered, Prim_integer_to_char());

    stubs.setArgs(&.{obj.ulongToFixnum(0xFF)});
    const ascii_ch = Prim_ascii_to_char();
    stubs.setArgs(&.{ascii_ch});
    try std.testing.expectEqual(obj.ulongToFixnum(0xFF), Prim_char_to_ascii());
    try std.testing.expectEqual(obj.ulongToFixnum(0xFF), Prim_char_ascii_p());

    stubs.setArgs(&.{obj.ulongToFixnum(0x100)});
    const non_ascii = Prim_integer_to_char();
    stubs.setArgs(&.{non_ascii});
    try std.testing.expectEqual(obj.sharp_f, Prim_char_ascii_p());
}
