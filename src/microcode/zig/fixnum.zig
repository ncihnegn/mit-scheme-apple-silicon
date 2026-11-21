// Derived from MIT/GNU Scheme C sources (`src/microcode/fixnum.c`, `src/microcode/fixnum.h`, `src/microcode/mul.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const bits = @import("bits.zig");

fn argFixnum(n: c_int) isize {
    const argument = abi.argRef(@intCast(n));
    if (!obj.fixnumP(argument)) abi.error_wrong_type_arg(n);
    return obj.fixnumToLong(argument);
}

fn argUnsignedFixnum(n: c_int) usize {
    const argument = abi.argRef(@intCast(n));
    if (!obj.fixnumP(argument)) abi.error_wrong_type_arg(n);
    return obj.objectDatum(argument);
}

inline fn fixnumResult(result: isize) obj.SchemeObject {
    if (!obj.longToFixnumP(result)) abi.error_bad_range_arg(1);
    return obj.longToFixnum(result);
}

inline fn logicalResult(val: usize) obj.SchemeObject {
    return obj.makeObject(obj.tc_fixnum, val & obj.datum_mask);
}

inline fn fixnumLsh(source: isize, number: isize) usize {
    if (number >= 0) {
        if (number > obj.datum_length) return 0;
        return @as(usize, @bitCast(source)) << @as(u6, @intCast(number));
    } else {
        const shift_right = -number;
        if (shift_right > obj.datum_length) return 0;
        const sh: u6 = @intCast(shift_right);
        const uval: usize = @bitCast(source);
        return if (source < 0) ~((~uval) >> sh) else (uval >> sh);
    }
}

pub export fn Mul(arg1: obj.SchemeObject, arg2: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const prod = @as(i128, obj.fixnumToLong(arg1)) * @as(i128, obj.fixnumToLong(arg2));
    if (prod < obj.smallest_fixnum or prod > obj.biggest_fixnum) return obj.sharp_f;
    return obj.longToFixnum(@intCast(prod));
}

// DEFINE_PRIMITIVE ("FIXNUM?", Prim_zero_fixnum_p, 1, 1, 0)
pub export fn Prim_zero_fixnum_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.fixnumP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("INDEX-FIXNUM?", Prim_index_fixnum_p, 1, 1, 0)
pub export fn Prim_index_fixnum_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.unsignedFixnumP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("ZERO-FIXNUM?", Prim_zero_fixnum, 1, 1, 0)
pub export fn Prim_zero_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(argFixnum(1) == 0);
}

// DEFINE_PRIMITIVE ("NEGATIVE-FIXNUM?", Prim_negative_fixnum, 1, 1, 0)
pub export fn Prim_negative_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(argFixnum(1) < 0);
}

// DEFINE_PRIMITIVE ("POSITIVE-FIXNUM?", Prim_positive_fixnum, 1, 1, 0)
pub export fn Prim_positive_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(argFixnum(1) > 0);
}

// DEFINE_PRIMITIVE ("EQUAL-FIXNUM?", Prim_equal_fixnum, 2, 2, 0)
pub export fn Prim_equal_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(argFixnum(1) == argFixnum(2));
}

// DEFINE_PRIMITIVE ("LESS-THAN-FIXNUM?", Prim_less_fixnum, 2, 2, 0)
pub export fn Prim_less_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(argFixnum(1) < argFixnum(2));
}

// DEFINE_PRIMITIVE ("GREATER-THAN-FIXNUM?", Prim_greater_fixnum, 2, 2, 0)
pub export fn Prim_greater_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(argFixnum(1) > argFixnum(2));
}

// DEFINE_PRIMITIVE ("ONE-PLUS-FIXNUM", Prim_one_plus_fixnum, 1, 1, 0)
pub export fn Prim_one_plus_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return fixnumResult(argFixnum(1) + 1);
}

// DEFINE_PRIMITIVE ("MINUS-ONE-PLUS-FIXNUM", Prim_m_1_plus_fixnum, 1, 1, 0)
pub export fn Prim_m_1_plus_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return fixnumResult(argFixnum(1) - 1);
}

// DEFINE_PRIMITIVE ("PLUS-FIXNUM", Prim_plus_fixnum, 2, 2, 0)
pub export fn Prim_plus_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return fixnumResult(argFixnum(1) + argFixnum(2));
}

// DEFINE_PRIMITIVE ("MINUS-FIXNUM", Prim_minus_fixnum, 2, 2, 0)
pub export fn Prim_minus_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return fixnumResult(argFixnum(1) - argFixnum(2));
}

// DEFINE_PRIMITIVE ("FIXNUM-NEGATE", Prim_fixnum_negate, 1, 1, 0)
pub export fn Prim_fixnum_negate() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return fixnumResult(-argFixnum(1));
}

// DEFINE_PRIMITIVE ("MULTIPLY-FIXNUM", Prim_multiply_fixnum, 2, 2, 0)
pub export fn Prim_multiply_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.fixnumP);
    abi.checkArg(2, obj.fixnumP);
    const result = Mul(abi.argRef(1), abi.argRef(2));
    if (result == obj.sharp_f) abi.error_bad_range_arg(1);
    return result;
}

// DEFINE_PRIMITIVE ("DIVIDE-FIXNUM", Prim_divide_fixnum, 2, 2, 0)
pub export fn Prim_divide_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const numerator = argFixnum(1);
    const denominator = argFixnum(2);
    if (denominator == 0) abi.error_bad_range_arg(2);
    const quotient = @divTrunc(numerator, denominator);
    const remainder = @rem(numerator, denominator);
    if (!obj.longToFixnumP(quotient)) abi.error_bad_range_arg(1);
    return abi.cons(obj.longToFixnum(quotient), obj.longToFixnum(remainder));
}

// DEFINE_PRIMITIVE ("FIXNUM-QUOTIENT", Prim_fixnum_quotient, 2, 2, 0)
pub export fn Prim_fixnum_quotient() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const numerator = argFixnum(1);
    const denominator = argFixnum(2);
    if (denominator == 0) abi.error_bad_range_arg(2);
    return fixnumResult(@divTrunc(numerator, denominator));
}

// DEFINE_PRIMITIVE ("FIXNUM-REMAINDER", Prim_fixnum_remainder, 2, 2, 0)
pub export fn Prim_fixnum_remainder() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const numerator = argFixnum(1);
    const denominator = argFixnum(2);
    if (denominator == 0) abi.error_bad_range_arg(2);
    return fixnumResult(@rem(numerator, denominator));
}

// DEFINE_PRIMITIVE ("GCD-FIXNUM", Prim_gcd_fixnum, 2, 2, 0)
pub export fn Prim_gcd_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var x = argFixnum(1);
    var y = argFixnum(2);
    if (x < 0) x = -x;
    if (y < 0) y = -y;
    while (y != 0) {
        const z = x;
        x = y;
        y = @rem(z, y);
    }
    return obj.longToFixnum(x);
}

// DEFINE_PRIMITIVE ("FIXNUM-ANDC", Prim_fixnum_andc, 2, 2, 0)
pub export fn Prim_fixnum_andc() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return logicalResult(argUnsignedFixnum(1) & ~argUnsignedFixnum(2));
}

// DEFINE_PRIMITIVE ("FIXNUM-AND", Prim_fixnum_and, 2, 2, 0)
pub export fn Prim_fixnum_and() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return logicalResult(argUnsignedFixnum(1) & argUnsignedFixnum(2));
}

// DEFINE_PRIMITIVE ("FIXNUM-OR", Prim_fixnum_or, 2, 2, 0)
pub export fn Prim_fixnum_or() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return logicalResult(argUnsignedFixnum(1) | argUnsignedFixnum(2));
}

// DEFINE_PRIMITIVE ("FIXNUM-XOR", Prim_fixnum_xor, 2, 2, 0)
pub export fn Prim_fixnum_xor() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return logicalResult(argUnsignedFixnum(1) ^ argUnsignedFixnum(2));
}

// DEFINE_PRIMITIVE ("FIXNUM-NOT", Prim_fixnum_not, 1, 1, 0)
pub export fn Prim_fixnum_not() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return logicalResult(~argUnsignedFixnum(1));
}

// DEFINE_PRIMITIVE ("FIXNUM-LSH", Prim_fixnum_lsh, 2, 2, 0)
pub export fn Prim_fixnum_lsh() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = argFixnum(1);
    const y = argFixnum(2);
    return logicalResult(fixnumLsh(x, y));
}

// DEFINE_PRIMITIVE ("FXBIT-COUNT", Prim_fxbit_count, 1, 1, 0)
pub export fn Prim_fxbit_count() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n = argFixnum(1);
    const bits_val: usize = @bitCast(if (n < 0) ~n else n);
    return fixnumResult(@intCast(bits.ulongBitCount(bits_val)));
}

// DEFINE_PRIMITIVE ("FXLENGTH", Prim_fxlength, 1, 1, 0)
pub export fn Prim_fxlength() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n = argFixnum(1);
    const bits_val: usize = @bitCast(if (n < 0) ~n else n);
    return fixnumResult(@intCast(bits.ulongLengthInBits(bits_val)));
}

// DEFINE_PRIMITIVE ("FXFIRST-SET-BIT", fxfirst_set_bit, 1, 1, 0)
pub export fn fxfirst_set_bit() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const bits_val: usize = @bitCast(argFixnum(1));
    return fixnumResult(@intCast(bits.ulongFirstSetBit(bits_val)));
}

// DEFINE_PRIMITIVE ("FIXNUM->FLONUM", Prim_fixnum_to_flonum, 1, 1,
//   "(FIXNUM)\n\
// Equivalent to (INTEGER->FLONUM FIXNUM 2)")
pub export fn Prim_fixnum_to_flonum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.double_to_flonum(@floatFromInt(argFixnum(1)));
}

test "fixnum primitives handle Mul overflow, signed div/rem, gcd, lsh, and fx bit ops" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // Mul fast path and overflow
    try std.testing.expectEqual(obj.longToFixnum(42), Mul(obj.longToFixnum(-6), obj.longToFixnum(-7)));
    try std.testing.expectEqual(obj.longToFixnum(obj.smallest_fixnum), Mul(obj.longToFixnum(obj.smallest_fixnum), obj.longToFixnum(1)));
    try std.testing.expectEqual(obj.sharp_f, Mul(obj.longToFixnum(1 << 30), obj.longToFixnum(1 << 30)));
    try std.testing.expectEqual(obj.sharp_f, Mul(obj.longToFixnum(obj.smallest_fixnum), obj.longToFixnum(-1)));

    // DIVIDE-FIXNUM with negative numerator and denominator
    stubs.setArgs(&.{ obj.longToFixnum(-7), obj.longToFixnum(3) });
    const div_pair = Prim_divide_fixnum();
    try std.testing.expectEqual(obj.longToFixnum(-2), obj.pairCar(div_pair));
    try std.testing.expectEqual(obj.longToFixnum(-1), obj.pairCdr(div_pair));

    stubs.setArgs(&.{ obj.longToFixnum(-7), obj.longToFixnum(-3) });
    try std.testing.expectEqual(obj.longToFixnum(2), Prim_fixnum_quotient());
    try std.testing.expectEqual(obj.longToFixnum(-1), Prim_fixnum_remainder());

    // GCD
    stubs.setArgs(&.{ obj.longToFixnum(-48), obj.longToFixnum(18) });
    try std.testing.expectEqual(obj.longToFixnum(6), Prim_gcd_fixnum());

    // FIXNUM-LSH including negative shift (sign extending) and > MAX_BIT_SHIFT
    stubs.setArgs(&.{ obj.longToFixnum(123), obj.longToFixnum(3) });
    try std.testing.expectEqual(obj.longToFixnum(984), Prim_fixnum_lsh());

    stubs.setArgs(&.{ obj.longToFixnum(-123), obj.longToFixnum(-3) });
    try std.testing.expectEqual(obj.longToFixnum(-16), Prim_fixnum_lsh());

    stubs.setArgs(&.{ obj.longToFixnum(-1), obj.longToFixnum(@intCast(obj.datum_length)) });
    try std.testing.expectEqual(obj.longToFixnum(0), Prim_fixnum_lsh());

    stubs.setArgs(&.{ obj.longToFixnum(-5), obj.longToFixnum(-@as(isize, @intCast(obj.datum_length + 1))) });
    try std.testing.expectEqual(obj.longToFixnum(0), Prim_fixnum_lsh());

    // FXBIT-COUNT, FXLENGTH, FXFIRST-SET-BIT
    stubs.setArgs(&.{obj.longToFixnum(obj.biggest_fixnum)});
    try std.testing.expectEqual(obj.longToFixnum(57), Prim_fxbit_count());
    try std.testing.expectEqual(obj.longToFixnum(57), Prim_fxlength());

    stubs.setArgs(&.{obj.longToFixnum(obj.smallest_fixnum)});
    try std.testing.expectEqual(obj.longToFixnum(57), Prim_fxbit_count());
    try std.testing.expectEqual(obj.longToFixnum(57), fxfirst_set_bit());

    stubs.setArgs(&.{obj.longToFixnum(-1)});
    try std.testing.expectEqual(obj.longToFixnum(0), Prim_fxbit_count());
    try std.testing.expectEqual(obj.longToFixnum(0), Prim_fxlength());

    stubs.setArgs(&.{obj.longToFixnum(0)});
    try std.testing.expectEqual(obj.longToFixnum(-1), fxfirst_set_bit());
}
