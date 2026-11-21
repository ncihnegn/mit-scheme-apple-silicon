// Derived from MIT/GNU Scheme C sources (`src/microcode/intprm.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");

inline fn intTest(comptime pred: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    return obj.booleanToObject(pred(abi.argRef(1)));
}

inline fn intCmp(comptime pred: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    abi.checkArg(2, obj.integerP);
    return obj.booleanToObject(pred(abi.argRef(1), abi.argRef(2)));
}

inline fn intUnary(comptime op: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    return op(abi.argRef(1));
}

inline fn intBin(comptime op: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    abi.checkArg(2, obj.integerP);
    return op(abi.argRef(1), abi.argRef(2));
}

inline fn intQr(comptime op: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    abi.checkArg(2, obj.integerP);
    const result = op(abi.argRef(1), abi.argRef(2));
    if (result == obj.sharp_f) abi.error_bad_range_arg(2);
    return result;
}

fn listToIntegerProducer(context: ?*anyopaque) callconv(.c) c_uint {
    const digits_ptr: *obj.SchemeObject = @ptrCast(@alignCast(context.?));
    const digit: c_uint = @intCast(obj.unsignedFixnumToLong(obj.pairCar(digits_ptr.*)));
    digits_ptr.* = obj.pairCdr(digits_ptr.*);
    return digit;
}

// DEFINE_PRIMITIVE ("INTEGER-ZERO?", Prim_integer_zero_p, 1, 1, 0)
pub export fn Prim_integer_zero_p() callconv(.c) obj.SchemeObject {
    return intTest(artutl.integer_zero_p);
}

// DEFINE_PRIMITIVE ("INTEGER-NEGATIVE?", Prim_integer_negative_p, 1, 1, 0)
pub export fn Prim_integer_negative_p() callconv(.c) obj.SchemeObject {
    return intTest(artutl.integer_negative_p);
}

// DEFINE_PRIMITIVE ("INTEGER-POSITIVE?", Prim_integer_positive_p, 1, 1, 0)
pub export fn Prim_integer_positive_p() callconv(.c) obj.SchemeObject {
    return intTest(artutl.integer_positive_p);
}

// DEFINE_PRIMITIVE ("INTEGER-EQUAL?", Prim_integer_equal_p, 2, 2, 0)
pub export fn Prim_integer_equal_p() callconv(.c) obj.SchemeObject {
    return intCmp(artutl.integer_equal_p);
}

// DEFINE_PRIMITIVE ("INTEGER-LESS?", Prim_integer_less_p, 2, 2, 0)
pub export fn Prim_integer_less_p() callconv(.c) obj.SchemeObject {
    return intCmp(artutl.integer_less_p);
}

// DEFINE_PRIMITIVE ("INTEGER-GREATER?", Prim_integer_greater_p, 2, 2, 0)
pub export fn Prim_integer_greater_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    abi.checkArg(2, obj.integerP);
    return obj.booleanToObject(artutl.integer_less_p(abi.argRef(2), abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("INTEGER-ADD", Prim_integer_add, 2, 2, 0)
pub export fn Prim_integer_add() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_add);
}

// DEFINE_PRIMITIVE ("INTEGER-SUBTRACT", Prim_integer_subtract, 2, 2, 0)
pub export fn Prim_integer_subtract() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_subtract);
}

// DEFINE_PRIMITIVE ("INTEGER-MULTIPLY", Prim_integer_multiply, 2, 2, 0)
pub export fn Prim_integer_multiply() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_multiply);
}

// DEFINE_PRIMITIVE ("INTEGER-HAMMING-DISTANCE", Prim_integer_hamming_distance, 2, 2, 0)
pub export fn Prim_integer_hamming_distance() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_hamming_distance);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-AND", Prim_integer_bitwise_and, 2, 2, 0)
pub export fn Prim_integer_bitwise_and() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_and);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-ANDC2", Prim_integer_bitwise_andc2, 2, 2, 0)
pub export fn Prim_integer_bitwise_andc2() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_andc2);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-ANDC1", Prim_integer_bitwise_andc1, 2, 2, 0)
pub export fn Prim_integer_bitwise_andc1() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_andc1);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-XOR", Prim_integer_bitwise_xor, 2, 2, 0)
pub export fn Prim_integer_bitwise_xor() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_xor);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-IOR", Prim_integer_bitwise_ior, 2, 2, 0)
pub export fn Prim_integer_bitwise_ior() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_ior);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-NOR", Prim_integer_bitwise_nor, 2, 2, 0)
pub export fn Prim_integer_bitwise_nor() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_nor);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-EQV", Prim_integer_bitwise_eqv, 2, 2, 0)
pub export fn Prim_integer_bitwise_eqv() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_eqv);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-ORC2", Prim_integer_bitwise_orc2, 2, 2, 0)
pub export fn Prim_integer_bitwise_orc2() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_orc2);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-ORC1", Prim_integer_bitwise_orc1, 2, 2, 0)
pub export fn Prim_integer_bitwise_orc1() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_orc1);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-NAND", Prim_integer_bitwise_nand, 2, 2, 0)
pub export fn Prim_integer_bitwise_nand() callconv(.c) obj.SchemeObject {
    return intBin(artutl.integer_bitwise_nand);
}

// DEFINE_PRIMITIVE ("INTEGER-NEGATE", Prim_integer_negate, 1, 1, 0)
pub export fn Prim_integer_negate() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_negate);
}

// DEFINE_PRIMITIVE ("INTEGER-ADD-1", Prim_integer_add_1, 1, 1, 0)
pub export fn Prim_integer_add_1() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_add_1);
}

// DEFINE_PRIMITIVE ("INTEGER-SUBTRACT-1", Prim_integer_subtract_1, 1, 1, 0)
pub export fn Prim_integer_subtract_1() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_subtract_1);
}

// DEFINE_PRIMITIVE ("INTEGER-LENGTH-IN-BITS", Prim_integer_length_in_bits, 1, 1, 0)
pub export fn Prim_integer_length_in_bits() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_length_in_bits);
}

// DEFINE_PRIMITIVE ("INTEGER-LENGTH", Prim_integer_length, 1, 1, 0)
pub export fn Prim_integer_length() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_length);
}

// DEFINE_PRIMITIVE ("INTEGER-FIRST-SET-BIT", Prim_integer_first_set_bit, 1, 1, 0)
pub export fn Prim_integer_first_set_bit() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_first_set_bit);
}

// DEFINE_PRIMITIVE ("INTEGER-BIT-COUNT", Prim_integer_bit_count, 1, 1, 0)
pub export fn Prim_integer_bit_count() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_bit_count);
}

// DEFINE_PRIMITIVE ("INTEGER-BITWISE-NOT", Prim_integer_bitwise_not, 1, 1, 0)
pub export fn Prim_integer_bitwise_not() callconv(.c) obj.SchemeObject {
    return intUnary(artutl.integer_bitwise_not);
}

// DEFINE_PRIMITIVE ("INTEGER-DIVIDE", Prim_integer_divide, 2, 2, 0)
pub export fn Prim_integer_divide() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    abi.checkArg(2, obj.integerP);
    var quotient: obj.SchemeObject = undefined;
    var remainder: obj.SchemeObject = undefined;
    if (artutl.integer_divide(abi.argRef(1), abi.argRef(2), &quotient, &remainder)) {
        abi.error_bad_range_arg(2);
    }
    return abi.cons(quotient, remainder);
}

// DEFINE_PRIMITIVE ("INTEGER-QUOTIENT", Prim_integer_quotient, 2, 2, 0)
pub export fn Prim_integer_quotient() callconv(.c) obj.SchemeObject {
    return intQr(artutl.integer_quotient);
}

// DEFINE_PRIMITIVE ("INTEGER-REMAINDER", Prim_integer_remainder, 2, 2, 0)
pub export fn Prim_integer_remainder() callconv(.c) obj.SchemeObject {
    return intQr(artutl.integer_remainder);
}

// DEFINE_PRIMITIVE ("INTEGER?", Prim_integer_p, 1, 1, 0)
pub export fn Prim_integer_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.integerP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("INTEGER->FLONUM", Prim_integer_to_flonum, 2, 2, 0)
pub export fn Prim_integer_to_flonum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    const integer = abi.argRef(1);
    const control = abi.arg_index_integer(2, 4);
    if (obj.fixnumP(integer)) {
        const d = obj.fixnumToDouble(integer);
        if ((control & 1) == 0 or
            (obj.doubleToFixnumP(d) and integer == obj.doubleToFixnum(d)))
        {
            return abi.double_to_flonum(d);
        }
        if ((control & 2) != 0) abi.error_bad_range_arg(1);
        return obj.sharp_f;
    }
    const ok = if ((control & 1) != 0) abi.losslessBignumToDoubleP(integer) else abi.bignumToDoubleP(integer);
    if (ok) return abi.bignumToFlonumVal(integer);
    if ((control & 2) != 0) abi.error_bad_range_arg(1);
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("INTEGER-NONNEGATIVE-ONE-BITS", Prim_integer_nonnegative_one_bits, 2, 2, 0)
pub export fn Prim_integer_nonnegative_one_bits() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.integer_nonnegative_one_bits(abi.arg_ulong_integer(1), abi.arg_ulong_integer(2));
}

// DEFINE_PRIMITIVE ("INTEGER-NEGATIVE-ZERO-BITS", Prim_integer_negative_zero_bits, 2, 2, 0)
pub export fn Prim_integer_negative_zero_bits() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.integer_negative_zero_bits(abi.arg_ulong_integer(1), abi.arg_ulong_integer(2));
}

// DEFINE_PRIMITIVE ("INTEGER-SHIFT-LEFT", Prim_integer_shift_left, 2, 2, 0)
pub export fn Prim_integer_shift_left() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    return artutl.integer_shift_left(abi.argRef(1), abi.arg_ulong_integer(2));
}

// DEFINE_PRIMITIVE ("INTEGER-SHIFT-RIGHT", Prim_integer_shift_right, 2, 2, 0)
pub export fn Prim_integer_shift_right() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    const n = abi.argRef(1);
    const m = abi.argRef(2);
    if (obj.fixnumP(m)) {
        if (obj.fixnumNegativeP(m)) abi.error_bad_range_arg(2);
        return artutl.integer_shift_right(n, obj.fixnumToUlong(m));
    } else if (obj.bignumP(m)) {
        if (abi.bignumNegativeP(m)) abi.error_bad_range_arg(2);
        return obj.fixnum_zero;
    } else {
        abi.error_wrong_type_arg(2);
    }
}

// DEFINE_PRIMITIVE ("LIST->INTEGER", Prim_list_to_integer, 3, 3,
//   "(list radix negative?)\n\
// LIST is a non-null list of digits in RADIX, most-significant first.\n\
// Converts the list to an integer.  NEGATIVE? specifies the sign.")
pub export fn Prim_list_to_integer() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.pairP);
    var digits = abi.argRef(1);
    const radix = abi.arg_ulong_integer(2);
    const max_radix: usize = @intCast(abi.bignum_max_digit_stream_radix());
    if (radix < 2 or radix >= max_radix) abi.error_bad_range_arg(2);

    var n_digits: c_uint = 0;
    var scan = digits;
    while (true) {
        const digit = obj.pairCar(scan);
        if (!obj.unsignedFixnumP(digit)) abi.error_wrong_type_arg(1);
        if (@as(usize, @intCast(obj.unsignedFixnumToLong(digit))) >= radix) abi.error_bad_range_arg(1);
        n_digits += 1;
        scan = obj.pairCdr(scan);
        if (obj.emptyListP(scan)) break;
        if (!obj.pairP(scan)) abi.error_wrong_type_arg(1);
    }
    return artutl.bignum_to_integer(abi.digit_stream_to_bignum(
        n_digits,
        &listToIntegerProducer,
        &digits,
        @intCast(radix),
        @intFromBool(obj.objectToBoolean(abi.argRef(3))),
    ));
}

test "intprm primitives handle exact/lossy flonum flags, shifts, and list->integer" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // integer->flonum lossless control=1
    const exact_fx = obj.longToFixnum(42);
    stubs.setArgs(&.{ exact_fx, obj.longToFixnum(1) });
    const fl = Prim_integer_to_flonum();
    try std.testing.expectEqual(@as(f64, 42.0), obj.flonumToDouble(fl));

    const lossy_fx = obj.longToFixnum((@as(isize, 1) << 53) + 1);
    stubs.setArgs(&.{ lossy_fx, obj.longToFixnum(1) });
    try std.testing.expectEqual(obj.sharp_f, Prim_integer_to_flonum());

    stubs.setArgs(&.{ lossy_fx, obj.longToFixnum(0) });
    try std.testing.expect(obj.flonumP(Prim_integer_to_flonum()));

    // Positive bignum right shift returns 0
    stubs.setArgs(&.{ obj.longToFixnum(12345), abi.long_to_bignum(200) });
    try std.testing.expectEqual(obj.fixnum_zero, Prim_integer_shift_right());

    // list->integer with radix 16, negative? = #t
    const lst = abi.cons(
        obj.longToUnsignedFixnum(15),
        abi.cons(obj.longToUnsignedFixnum(15), obj.empty_list),
    );
    stubs.setArgs(&.{ lst, obj.longToFixnum(16), obj.sharp_t });
    try std.testing.expectEqual(obj.longToFixnum(-255), Prim_list_to_integer());
}
