// Derived from MIT/GNU Scheme C sources (`src/microcode/artutl.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const bits = @import("bits.zig");

extern "c" fn floor(f64) f64;
extern "c" fn ceil(f64) f64;
extern "c" fn fmod(f64, f64) f64;
extern "c" fn modf(f64, *f64) f64;
extern "c" fn frexp(f64, *c_int) f64;
extern "c" fn ldexp(f64, c_int) f64;

inline fn asBignum(x: obj.SchemeObject) obj.SchemeObject {
    return if (obj.fixnumP(x)) abi.fixnumToBignum(x) else x;
}

inline fn fixnumDivTrunc(lx: isize, ly: isize) struct { q: isize, r: isize } {
    const abs_x = if (lx < 0) -lx else lx;
    const abs_y = if (ly < 0) -ly else ly;
    const mag_q = @divTrunc(abs_x, abs_y);
    const mag_r = @rem(abs_x, abs_y);
    const q = if ((lx < 0) != (ly < 0)) -mag_q else mag_q;
    const r = if (lx < 0) -mag_r else mag_r;
    return .{ .q = q, .r = r };
}

inline fn bitwiseBinop(
    n: obj.SchemeObject,
    m: obj.SchemeObject,
    comptime fixOp: anytype,
    comptime bigOp: anytype,
) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(m)) {
        return obj.longToFixnum(fixOp(obj.fixnumToLong(n), obj.fixnumToLong(m)));
    }
    return bignum_to_integer(bigOp(asBignum(n), asBignum(m)));
}

inline fn fixAnd(x: isize, y: isize) isize {
    return x & y;
}
inline fn fixAndc2(x: isize, y: isize) isize {
    return x & ~y;
}
inline fn fixAndc1(x: isize, y: isize) isize {
    return y & ~x;
}
inline fn fixXor(x: isize, y: isize) isize {
    return x ^ y;
}
inline fn fixIor(x: isize, y: isize) isize {
    return x | y;
}
inline fn fixNor(x: isize, y: isize) isize {
    return ~(x | y);
}
inline fn fixEqv(x: isize, y: isize) isize {
    return ~(x ^ y);
}
inline fn fixOrc2(x: isize, y: isize) isize {
    return x | ~y;
}
inline fn fixOrc1(x: isize, y: isize) isize {
    return y | ~x;
}
inline fn fixNand(x: isize, y: isize) isize {
    return ~(x & y);
}

// Conversions between Scheme types and C types.

pub export fn fixnum_to_long(fixnum: obj.SchemeObject) callconv(.c) isize {
    return obj.fixnumToLong(fixnum);
}

pub export fn double_to_fixnum(value: f64) callconv(.c) obj.SchemeObject {
    const min_f: f64 = @floatFromInt(std.math.minInt(isize));
    const max_f: f64 = -min_f;
    if (!(value >= min_f and value < max_f)) return obj.longToFixnum(0);
    return obj.longToFixnum(@intFromFloat(value));
}

pub export fn integer_to_long_p(n: obj.SchemeObject) callconv(.c) bool {
    return obj.fixnumP(n) or abi.bignumToLongP(n);
}

pub export fn integer_to_long(n: obj.SchemeObject) callconv(.c) isize {
    return if (obj.fixnumP(n)) obj.fixnumToLong(n) else abi.bignum_to_long(n);
}

pub export fn integer_to_intmax_p(n: obj.SchemeObject) callconv(.c) bool {
    return obj.fixnumP(n) or abi.bignumToIntmaxP(n);
}

pub export fn integer_to_intmax(n: obj.SchemeObject) callconv(.c) i64 {
    return if (obj.fixnumP(n)) @intCast(obj.fixnumToLong(n)) else abi.bignum_to_intmax(n);
}

pub export fn long_to_integer(number: isize) callconv(.c) obj.SchemeObject {
    return if (obj.longToFixnumP(number)) obj.longToFixnum(number) else abi.long_to_bignum(number);
}

pub export fn intmax_to_integer(number: i64) callconv(.c) obj.SchemeObject {
    const min_l: i64 = std.math.minInt(isize);
    const max_l: i64 = std.math.maxInt(isize);
    return if (number >= min_l and number <= max_l)
        long_to_integer(@intCast(number))
    else
        abi.intmax_to_bignum(number);
}

pub export fn integer_to_ulong_p(n: obj.SchemeObject) callconv(.c) bool {
    return if (obj.fixnumP(n)) !obj.fixnumNegativeP(n) else abi.bignumToUlongP(n);
}

pub export fn integer_to_ulong(n: obj.SchemeObject) callconv(.c) usize {
    return if (obj.fixnumP(n)) @bitCast(obj.fixnumToLong(n)) else abi.bignum_to_ulong(n);
}

pub export fn integer_to_uintmax_p(n: obj.SchemeObject) callconv(.c) bool {
    return if (obj.fixnumP(n)) !obj.fixnumNegativeP(n) else abi.bignumToUintmaxP(n);
}

pub export fn integer_to_uintmax(n: obj.SchemeObject) callconv(.c) u64 {
    return if (obj.fixnumP(n))
        @bitCast(@as(i64, obj.fixnumToLong(n)))
    else
        abi.bignum_to_uintmax(n);
}

pub export fn ulong_to_integer(number: usize) callconv(.c) obj.SchemeObject {
    const s_number: isize = @bitCast(number);
    if (s_number >= 0) {
        return if (obj.longToFixnumP(s_number)) obj.longToFixnum(s_number) else abi.long_to_bignum(s_number);
    }
    return abi.ulong_to_bignum(number);
}

pub export fn uintmax_to_integer(number: u64) callconv(.c) obj.SchemeObject {
    return if (number <= std.math.maxInt(usize))
        ulong_to_integer(@intCast(number))
    else
        abi.uintmax_to_bignum(number);
}

pub export fn integer_to_double_p(n: obj.SchemeObject) callconv(.c) bool {
    return obj.fixnumP(n) or abi.bignumToDoubleP(n);
}

pub export fn integer_to_double(n: obj.SchemeObject) callconv(.c) f64 {
    return if (obj.fixnumP(n)) obj.fixnumToDouble(n) else abi.bignum_to_double(n);
}

pub export fn double_to_integer(x: f64) callconv(.c) obj.SchemeObject {
    return if (obj.doubleToFixnumP(x)) double_to_fixnum(x) else abi.double_to_bignum(x);
}

pub export fn double_truncate(x: f64) callconv(.c) f64 {
    var iptr: f64 = undefined;
    _ = modf(x, &iptr);
    return iptr;
}

pub export fn double_round(x: f64) callconv(.c) f64 {
    var integral: f64 = undefined;
    const fractional = @abs(modf(x, &integral));
    const round_down = if (fractional == 0.5)
        fmod(integral, 2.0) == 0.0
    else
        !(0.5 < fractional);
    if (round_down) return integral;
    if (x < 0.0) return integral - 1.0;
    return integral + 1.0;
}

// Conversions between Scheme types and Scheme types.

pub export fn bignum_to_fixnum(bignum: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (abi.bignumToFixnumP(bignum)) abi.bignumToFixnumVal(bignum) else obj.sharp_f;
}

pub export fn bignum_to_integer(bignum: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (abi.bignumToFixnumP(bignum)) abi.bignumToFixnumVal(bignum) else bignum;
}

pub export fn bignum_to_flonum(bignum: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (abi.bignumToDoubleP(bignum)) abi.bignumToFlonumVal(bignum) else obj.sharp_f;
}

pub export fn finite_flonum_p(x: obj.SchemeObject) callconv(.c) bool {
    return obj.flonumP(x) and flonum_is_finite_p(x);
}

pub export fn flonum_is_finite_p(x: obj.SchemeObject) callconv(.c) bool {
    return std.math.isFinite(obj.flonumToDouble(x));
}

pub export fn flonum_integer_p(x: obj.SchemeObject) callconv(.c) bool {
    var iptr: f64 = undefined;
    return modf(obj.flonumToDouble(x), &iptr) == 0.0;
}

pub export fn flonum_floor(x: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return abi.double_to_flonum(floor(obj.flonumToDouble(x)));
}

pub export fn flonum_ceiling(x: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return abi.double_to_flonum(ceil(obj.flonumToDouble(x)));
}

pub export fn flonum_round(x: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return abi.double_to_flonum(double_round(obj.flonumToDouble(x)));
}

pub export fn flonum_normalize(x: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    var exponent: c_int = undefined;
    const significand = frexp(obj.flonumToDouble(x), &exponent);
    return abi.cons(abi.double_to_flonum(significand), long_to_integer(@as(isize, exponent)));
}

pub export fn flonum_denormalize(x: obj.SchemeObject, e: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const exp: c_int = @truncate(integer_to_long(e));
    return abi.double_to_flonum(ldexp(obj.flonumToDouble(x), exp));
}

// Generic Integer Operations

pub export fn integer_zero_p(n: obj.SchemeObject) callconv(.c) bool {
    return if (obj.fixnumP(n)) obj.fixnumZeroP(n) else abi.bignumZeroP(n);
}

pub export fn integer_negative_p(n: obj.SchemeObject) callconv(.c) bool {
    return if (obj.fixnumP(n)) obj.fixnumNegativeP(n) else abi.bignumNegativeP(n);
}

pub export fn integer_positive_p(n: obj.SchemeObject) callconv(.c) bool {
    return if (obj.fixnumP(n)) obj.fixnumPositiveP(n) else abi.bignumPositiveP(n);
}

pub export fn integer_equal_p(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) bool {
    if (obj.fixnumP(n) and obj.fixnumP(m)) return obj.fixnumEqualP(n, m);
    return abi.bignum_equal_p(asBignum(n), asBignum(m)) != 0;
}

pub export fn integer_less_p(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) bool {
    if (obj.fixnumP(n) and obj.fixnumP(m)) return obj.fixnumLessP(n, m);
    return abi.bignumLessP(asBignum(n), asBignum(m));
}

pub export fn integer_negate(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (obj.fixnumP(n))
        long_to_integer(-obj.fixnumToLong(n))
    else
        bignum_to_integer(abi.bignum_negate(n));
}

pub export fn integer_add(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(m)) {
        return long_to_integer(obj.fixnumToLong(n) + obj.fixnumToLong(m));
    }
    return bignum_to_integer(abi.bignum_add(asBignum(n), asBignum(m)));
}

pub export fn integer_add_1(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (obj.fixnumP(n))
        long_to_integer(obj.fixnumToLong(n) + 1)
    else
        bignum_to_integer(abi.bignum_add(n, abi.long_to_bignum(1)));
}

pub export fn integer_subtract(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(m)) {
        return long_to_integer(obj.fixnumToLong(n) - obj.fixnumToLong(m));
    }
    return bignum_to_integer(abi.bignum_subtract(asBignum(n), asBignum(m)));
}

pub export fn integer_subtract_1(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (obj.fixnumP(n))
        long_to_integer(obj.fixnumToLong(n) - 1)
    else
        bignum_to_integer(abi.bignum_subtract(n, abi.long_to_bignum(1)));
}

pub export fn integer_multiply(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(m)) {
        const result = abi.Mul(n, m);
        if (result != obj.sharp_f) return result;
    }
    return bignum_to_integer(abi.bignum_multiply(asBignum(n), asBignum(m)));
}

pub export fn integer_divide(
    n_arg: obj.SchemeObject,
    d_arg: obj.SchemeObject,
    q: *obj.SchemeObject,
    r: *obj.SchemeObject,
) callconv(.c) bool {
    if (obj.fixnumP(n_arg) and obj.fixnumP(d_arg)) {
        const ly = obj.fixnumToLong(d_arg);
        if (ly == 0) return true;
        const qr = fixnumDivTrunc(obj.fixnumToLong(n_arg), ly);
        q.* = long_to_integer(qr.q);
        r.* = obj.longToFixnum(qr.r);
        return false;
    }
    var quotient: obj.SchemeObject = undefined;
    var remainder: obj.SchemeObject = undefined;
    if (abi.bignum_divide(asBignum(n_arg), asBignum(d_arg), &quotient, &remainder) != 0) {
        return true;
    }
    q.* = bignum_to_integer(quotient);
    r.* = bignum_to_integer(remainder);
    return false;
}

pub export fn integer_quotient(n: obj.SchemeObject, d: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(d)) {
        const ly = obj.fixnumToLong(d);
        if (ly == 0) return obj.sharp_f;
        return long_to_integer(fixnumDivTrunc(obj.fixnumToLong(n), ly).q);
    }
    const result = abi.bignum_quotient(asBignum(n), asBignum(d));
    return if (result == obj.sharp_f) obj.sharp_f else bignum_to_integer(result);
}

pub export fn integer_remainder(n: obj.SchemeObject, d: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(d)) {
        const ly = obj.fixnumToLong(d);
        if (ly == 0) return obj.sharp_f;
        return long_to_integer(fixnumDivTrunc(obj.fixnumToLong(n), ly).r);
    }
    const result = abi.bignum_remainder(asBignum(n), asBignum(d));
    return if (result == obj.sharp_f) obj.sharp_f else bignum_to_integer(result);
}

// Length and Bit Counts

pub export fn integer_length_in_bits(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n)) {
        const n1 = obj.fixnumToLong(n);
        const mag: usize = @intCast(if (n1 < 0) -n1 else n1);
        return obj.ulongToFixnum(bits.ulongLengthInBits(mag));
    }
    return ulong_to_integer(abi.bignum_length_in_bits(n));
}

pub export fn integer_length(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n)) {
        const n1 = obj.fixnumToLong(n);
        const mag: usize = @intCast(if (n1 < 0) ~n1 else n1);
        return obj.ulongToFixnum(bits.ulongLengthInBits(mag));
    }
    return ulong_to_integer(abi.bignum_integer_length(n));
}

pub export fn integer_first_set_bit(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n)) {
        const n1 = obj.fixnumToLong(n);
        const uval: usize = if (n1 < 0) ~@as(usize, @intCast(~n1)) else @intCast(n1);
        return obj.longToFixnum(bits.ulongFirstSetBit(uval));
    }
    return long_to_integer(abi.bignum_first_set_bit(n));
}

pub export fn integer_bit_count(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n)) {
        const n1 = obj.fixnumToLong(n);
        const mag: usize = @intCast(if (n1 < 0) ~n1 else n1);
        return obj.ulongToFixnum(bits.ulongBitCount(mag));
    }
    return ulong_to_integer(abi.bignum_bit_count(n));
}

pub export fn integer_hamming_distance(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (obj.fixnumP(n) and obj.fixnumP(m)) {
        const x = obj.fixnumToLong(n) ^ obj.fixnumToLong(m);
        if (x < 0) return obj.longToFixnum(-1);
        return obj.ulongToFixnum(bits.ulongBitCount(@intCast(x)));
    }
    return long_to_integer(abi.bignum_hamming_distance(asBignum(n), asBignum(m)));
}

// Bitwise Operations

pub export fn integer_bitwise_not(n: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (obj.fixnumP(n))
        obj.longToFixnum(~obj.fixnumToLong(n))
    else
        abi.bignum_bitwise_not(n);
}

pub export fn integer_bitwise_and(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixAnd, abi.bignum_bitwise_and);
}

pub export fn integer_bitwise_andc2(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixAndc2, abi.bignum_bitwise_andc2);
}

pub export fn integer_bitwise_andc1(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixAndc1, abi.bignum_bitwise_andc1);
}

pub export fn integer_bitwise_xor(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixXor, abi.bignum_bitwise_xor);
}

pub export fn integer_bitwise_ior(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixIor, abi.bignum_bitwise_ior);
}

pub export fn integer_bitwise_nor(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixNor, abi.bignum_bitwise_nor);
}

pub export fn integer_bitwise_eqv(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixEqv, abi.bignum_bitwise_eqv);
}

pub export fn integer_bitwise_orc2(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixOrc2, abi.bignum_bitwise_orc2);
}

pub export fn integer_bitwise_orc1(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixOrc1, abi.bignum_bitwise_orc1);
}

pub export fn integer_bitwise_nand(n: obj.SchemeObject, m: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseBinop(n, m, fixNand, abi.bignum_bitwise_nand);
}

pub export fn integer_nonnegative_one_bits(n: usize, m: usize) callconv(.c) obj.SchemeObject {
    if (n == 0) return obj.fixnum_zero;
    if (n <= obj.fixnum_length and m <= obj.fixnum_length - n) {
        const mask = (~((~@as(usize, 0)) << @intCast(n))) << @intCast(m);
        return obj.ulongToFixnum(mask);
    }
    return abi.bignum_nonnegative_one_bits(n, m);
}

pub export fn integer_negative_zero_bits(n: usize, m: usize) callconv(.c) obj.SchemeObject {
    if (n == 0) return obj.longToFixnum(-1);
    if (n <= obj.fixnum_length and m <= obj.fixnum_length - n) {
        const mask = (~((~@as(usize, 0)) << @intCast(n))) << @intCast(m);
        return obj.longToFixnum(~@as(isize, @bitCast(mask)));
    }
    return abi.bignum_negative_zero_bits(n, m);
}

// Shift: multiplication and Euclidean division by 2^m

pub export fn integer_shift_left(n: obj.SchemeObject, m: usize) callconv(.c) obj.SchemeObject {
    if (m == 0) return n;
    if (obj.fixnumP(n)) {
        const n1 = obj.fixnumToLong(n);
        if (n1 < 0) {
            const len: usize = bits.ulongLengthInBits(@intCast(~n1));
            if (m <= obj.fixnum_length and len <= obj.fixnum_length - m) {
                const mag: usize = @intCast(-n1);
                return obj.longToFixnum(-@as(isize, @intCast(mag << @intCast(m))));
            }
            return abi.bignum_negate(abi.unsigned_long_to_shifted_bignum(@intCast(-n1), m, 0));
        }
        if (n1 > 0) {
            const len: usize = bits.ulongLengthInBits(@intCast(n1));
            if (m <= obj.fixnum_length and len <= obj.fixnum_length - m) {
                const mag: usize = @intCast(n1);
                return obj.longToFixnum(@intCast(mag << @intCast(m)));
            }
            return abi.unsigned_long_to_shifted_bignum(@intCast(n1), m, 0);
        }
        return obj.fixnum_zero;
    }
    return abi.bignum_shift_left(n, m);
}

pub export fn integer_shift_right(n: obj.SchemeObject, m: usize) callconv(.c) obj.SchemeObject {
    if (m == 0) return n;
    if (obj.fixnumP(n)) {
        const n1 = obj.fixnumToLong(n);
        if (m >= @bitSizeOf(isize)) return obj.longToFixnum(if (n1 < 0) -1 else 0);
        const sh: u6 = @intCast(m);
        return obj.longToFixnum(if (n1 < 0) ~((~n1) >> sh) else (n1 >> sh));
    }
    return bignum_to_integer(abi.bignum_shift_right(n, m));
}

test "artutl conversions, division sign rules, shifts, and double rounding" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    // Fixnum / integer boundary conversions
    try std.testing.expectEqual(obj.longToFixnum(obj.biggest_fixnum), long_to_integer(obj.biggest_fixnum));
    const big_pos = long_to_integer(obj.biggest_fixnum + 1);
    try std.testing.expect(obj.bignumP(big_pos));
    try std.testing.expectEqual(obj.biggest_fixnum + 1, integer_to_long(big_pos));

    const neg_u = ulong_to_integer(std.math.maxInt(usize));
    try std.testing.expect(obj.bignumP(neg_u));
    try std.testing.expect(integer_to_ulong_p(neg_u));
    try std.testing.expectEqual(std.math.maxInt(usize), integer_to_ulong(neg_u));

    // Negating SMALLEST_FIXNUM overflows fixnum into bignum
    const neg_min = integer_negate(obj.longToFixnum(obj.smallest_fixnum));
    try std.testing.expect(obj.bignumP(neg_min));
    try std.testing.expectEqual(obj.biggest_fixnum + 1, integer_to_long(neg_min));

    // Integer divide sign conventions matching C artutl
    var q: obj.SchemeObject = 0;
    var r: obj.SchemeObject = 0;
    try std.testing.expect(!integer_divide(obj.longToFixnum(-17), obj.longToFixnum(5), &q, &r));
    try std.testing.expectEqual(@as(isize, -3), obj.fixnumToLong(q));
    try std.testing.expectEqual(@as(isize, -2), obj.fixnumToLong(r));

    try std.testing.expect(!integer_divide(obj.longToFixnum(-17), obj.longToFixnum(-5), &q, &r));
    try std.testing.expectEqual(@as(isize, 3), obj.fixnumToLong(q));
    try std.testing.expectEqual(@as(isize, -2), obj.fixnumToLong(r));

    // Multiply fixnum overflow into bignum
    const prod = integer_multiply(obj.longToFixnum(1 << 30), obj.longToFixnum(1 << 30));
    try std.testing.expect(obj.bignumP(prod));
    try std.testing.expectEqual(@as(i64, 1) << 60, integer_to_intmax(prod));

    // Bit counts & first set bit
    try std.testing.expectEqual(@as(isize, 5), obj.fixnumToLong(integer_length(obj.longToFixnum(17))));
    try std.testing.expectEqual(@as(isize, 4), obj.fixnumToLong(integer_length(obj.longToFixnum(-16))));
    try std.testing.expectEqual(@as(isize, -1), obj.fixnumToLong(integer_first_set_bit(obj.fixnum_zero)));
    try std.testing.expectEqual(@as(isize, 2), obj.fixnumToLong(integer_first_set_bit(obj.longToFixnum(-12))));
    try std.testing.expectEqual(@as(isize, 3), obj.fixnumToLong(integer_bit_count(obj.longToFixnum(-12))));

    // Shifts & one/zero bits
    try std.testing.expectEqual(obj.longToFixnum(0), integer_shift_right(obj.longToFixnum(42), 100));
    try std.testing.expectEqual(obj.longToFixnum(-1), integer_shift_right(obj.longToFixnum(-42), 100));
    try std.testing.expect(obj.bignumP(integer_shift_left(obj.longToFixnum(1), 60)));
    try std.testing.expectEqual(@as(isize, 0b11100), obj.fixnumToLong(integer_nonnegative_one_bits(3, 2)));
    try std.testing.expectEqual(@as(isize, ~@as(isize, 0b11100)), obj.fixnumToLong(integer_negative_zero_bits(3, 2)));

    // IEEE round-to-even & normalize/denormalize
    try std.testing.expectEqual(@as(f64, 2.0), double_round(2.5));
    try std.testing.expectEqual(@as(f64, 4.0), double_round(3.5));
    try std.testing.expectEqual(@as(f64, -2.0), double_round(-2.5));
    try std.testing.expectEqual(@as(f64, -4.0), double_round(-3.5));

    const fl = abi.double_to_flonum(6.0);
    try std.testing.expect(finite_flonum_p(fl));
    try std.testing.expect(flonum_integer_p(fl));
    const norm = flonum_normalize(fl);
    try std.testing.expectEqual(@as(f64, 0.75), obj.flonumToDouble(obj.pairCar(norm)));
    try std.testing.expectEqual(@as(isize, 3), obj.fixnumToLong(obj.pairCdr(norm)));
    try std.testing.expectEqual(@as(f64, 6.0), obj.flonumToDouble(flonum_denormalize(obj.pairCar(norm), obj.pairCdr(norm))));
}
