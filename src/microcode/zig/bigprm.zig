// Derived from MIT/GNU Scheme C sources (`src/microcode/bigprm.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");

inline fn bignumTest(comptime pred: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    return obj.booleanToObject(pred(abi.argRef(1)));
}

inline fn bignumCmp(comptime pred: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    abi.checkArg(2, obj.bignumP);
    return obj.booleanToObject(pred(abi.argRef(1), abi.argRef(2)));
}

inline fn bignumEqualWrap(x: obj.SchemeObject, y: obj.SchemeObject) bool {
    return abi.bignum_equal_p(x, y) != 0;
}

inline fn bignumBin(comptime op: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    abi.checkArg(2, obj.bignumP);
    return op(abi.argRef(1), abi.argRef(2));
}

inline fn bignumQr(comptime op: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    abi.checkArg(2, obj.bignumP);
    const result = op(abi.argRef(1), abi.argRef(2));
    if (result == obj.sharp_f) abi.error_bad_range_arg(2);
    return result;
}

fn listifyBignumConsumer(previous_cdr: ?*anyopaque, digit: c_long) callconv(.c) void {
    const cdr_ptr: *obj.SchemeObject = @ptrCast(@alignCast(previous_cdr.?));
    cdr_ptr.* = abi.cons(obj.longToUnsignedFixnum(digit), cdr_ptr.*);
}

// DEFINE_PRIMITIVE ("BIGNUM-ZERO?", Prim_bignum_zero_p, 1, 1, 0)
pub export fn Prim_bignum_zero_p() callconv(.c) obj.SchemeObject {
    return bignumTest(abi.bignumZeroP);
}

// DEFINE_PRIMITIVE ("BIGNUM-NEGATIVE?", Prim_bignum_negative_p, 1, 1, 0)
pub export fn Prim_bignum_negative_p() callconv(.c) obj.SchemeObject {
    return bignumTest(abi.bignumNegativeP);
}

// DEFINE_PRIMITIVE ("BIGNUM-POSITIVE?", Prim_bignum_positive_p, 1, 1, 0)
pub export fn Prim_bignum_positive_p() callconv(.c) obj.SchemeObject {
    return bignumTest(abi.bignumPositiveP);
}

// DEFINE_PRIMITIVE ("BIGNUM-EQUAL?", Prim_bignum_equal_p, 2, 2, 0)
pub export fn Prim_bignum_equal_p() callconv(.c) obj.SchemeObject {
    return bignumCmp(bignumEqualWrap);
}

// DEFINE_PRIMITIVE ("BIGNUM-LESS?", Prim_bignum_less_p, 2, 2, 0)
pub export fn Prim_bignum_less_p() callconv(.c) obj.SchemeObject {
    return bignumCmp(abi.bignumLessP);
}

// DEFINE_PRIMITIVE ("BIGNUM-ADD", Prim_bignum_add, 2, 2, 0)
pub export fn Prim_bignum_add() callconv(.c) obj.SchemeObject {
    return bignumBin(abi.bignum_add);
}

// DEFINE_PRIMITIVE ("BIGNUM-SUBTRACT", Prim_bignum_subtract, 2, 2, 0)
pub export fn Prim_bignum_subtract() callconv(.c) obj.SchemeObject {
    return bignumBin(abi.bignum_subtract);
}

// DEFINE_PRIMITIVE ("BIGNUM-MULTIPLY", Prim_bignum_multiply, 2, 2, 0)
pub export fn Prim_bignum_multiply() callconv(.c) obj.SchemeObject {
    return bignumBin(abi.bignum_multiply);
}

// DEFINE_PRIMITIVE ("BIGNUM-DIVIDE", Prim_bignum_divide, 2, 2, 0)
pub export fn Prim_bignum_divide() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    abi.checkArg(2, obj.bignumP);
    var quotient: obj.SchemeObject = undefined;
    var remainder: obj.SchemeObject = undefined;
    if (abi.bignum_divide(abi.argRef(1), abi.argRef(2), &quotient, &remainder) != 0) {
        abi.error_bad_range_arg(2);
    }
    return abi.cons(quotient, remainder);
}

// DEFINE_PRIMITIVE ("BIGNUM-QUOTIENT", Prim_bignum_quotient, 2, 2, 0)
pub export fn Prim_bignum_quotient() callconv(.c) obj.SchemeObject {
    return bignumQr(abi.bignum_quotient);
}

// DEFINE_PRIMITIVE ("BIGNUM-REMAINDER", Prim_bignum_remainder, 2, 2, 0)
pub export fn Prim_bignum_remainder() callconv(.c) obj.SchemeObject {
    return bignumQr(abi.bignum_remainder);
}

// DEFINE_PRIMITIVE ("LISTIFY-BIGNUM", Prim_listify_bignum, 2, 2,
//   "Returns a list of the digits of BIGNUM in RADIX.")
pub export fn Prim_listify_bignum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    const bignum = abi.argRef(1);
    const radix = abi.arg_integer_in_range(2, 2, abi.bignum_max_digit_stream_radix());
    if (abi.bignumZeroP(bignum)) {
        return abi.cons(obj.longToUnsignedFixnum(0), obj.empty_list);
    }
    var previous_cdr = obj.empty_list;
    abi.bignum_to_digit_stream(bignum, @intCast(radix), &listifyBignumConsumer, &previous_cdr);
    return previous_cdr;
}

// DEFINE_PRIMITIVE ("FIXNUM->BIGNUM", Prim_fixnum_to_bignum, 1, 1, 0)
pub export fn Prim_fixnum_to_bignum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.fixnumP);
    return abi.fixnumToBignum(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("BIGNUM->FIXNUM", Prim_bignum_to_fixnum, 1, 1, 0)
pub export fn Prim_bignum_to_fixnum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    return artutl.bignum_to_fixnum(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("FLONUM->BIGNUM", Prim_flonum_to_bignum, 1, 1, 0)
pub export fn Prim_flonum_to_bignum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, artutl.finite_flonum_p);
    return abi.flonumToBignum(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("BIGNUM->FLONUM", Prim_bignum_to_flonum, 1, 1, 0)
pub export fn Prim_bignum_to_flonum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    return artutl.bignum_to_flonum(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("BIGNUM-LENGTH-IN-BITS", Prim_bignum_length_in_bits, 1, 1, 0)
pub export fn Prim_bignum_length_in_bits() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bignumP);
    return abi.bignum_length_in_bits(abi.argRef(1));
}

test "bigprm primitives handle conversions, arithmetic, and digit streaming" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{obj.longToFixnum(255)});
    const b255 = Prim_fixnum_to_bignum();
    try std.testing.expect(obj.bignumP(b255));

    stubs.setArgs(&.{b255});
    try std.testing.expectEqual(obj.longToFixnum(255), Prim_bignum_to_fixnum());
    try std.testing.expectEqual(obj.sharp_t, Prim_bignum_positive_p());
    try std.testing.expectEqual(obj.sharp_f, Prim_bignum_zero_p());

    stubs.setArgs(&.{ b255, obj.longToFixnum(16) });
    const digits = Prim_listify_bignum();
    try std.testing.expectEqual(@as(c_long, 15), obj.unsignedFixnumToLong(obj.pairCar(digits)));
    try std.testing.expectEqual(@as(c_long, 15), obj.unsignedFixnumToLong(obj.pairCar(obj.pairCdr(digits))));
    try std.testing.expectEqual(obj.empty_list, obj.pairCdr(obj.pairCdr(digits)));

    const b10 = abi.long_to_bignum(10);
    const b3 = abi.long_to_bignum(3);
    stubs.setArgs(&.{ b10, b3 });
    const qr = Prim_bignum_divide();
    try std.testing.expectEqual(@as(c_long, 3), abi.bignum_to_long(obj.pairCar(qr)));
    try std.testing.expectEqual(@as(c_long, 1), abi.bignum_to_long(obj.pairCdr(qr)));
}
