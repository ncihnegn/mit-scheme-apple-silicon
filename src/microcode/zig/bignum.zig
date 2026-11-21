// Derived from MIT/GNU Scheme C sources (`src/microcode/bignum.c`, `src/microcode/bignum.h`, `src/microcode/bignmint.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const bits = @import("bits.zig");

const BignumDigit = c_long;
const UnsignedDigit = c_ulong;
const BignumLength = c_long;

const bignum_out_of_band: obj.SchemeObject = obj.sharp_f;

const bignum_digit_length: comptime_int = @bitSizeOf(BignumDigit) - 2;
const bignum_half_digit_length: comptime_int = bignum_digit_length / 2;
const bignum_radix: UnsignedDigit = @as(UnsignedDigit, 1) << bignum_digit_length;
const bignum_radix_root: UnsignedDigit = @as(UnsignedDigit, 1) << bignum_half_digit_length;
const bignum_digit_mask: UnsignedDigit = bignum_radix - 1;
const bignum_half_digit_mask: UnsignedDigit = bignum_radix_root - 1;
const bignum_length_max: BignumLength = @intCast((bignum_radix / bignum_digit_length) - bignum_digit_length);

const half_shift: std.math.Log2Int(UnsignedDigit) = @intCast(bignum_half_digit_length);
const digit_shift: std.math.Log2Int(UnsignedDigit) = @intCast(bignum_digit_length);

extern "c" fn frexp(f64, *c_int) f64;
extern "c" fn ldexp(f64, c_int) f64;

inline fn bignumAssert(ok: bool) void {
    if (!ok) abi.error_external_return();
}

inline fn bignumLengthToGcLength(length: BignumLength) c_ulong {
    return obj.bytesToWords((@as(c_ulong, @intCast(length)) + 1) * @sizeOf(BignumDigit));
}

inline fn bignumToPointer(bignum: obj.SchemeObject) [*]UnsignedDigit {
    return @ptrCast(obj.vectorLoc(bignum, 0));
}

inline fn bignumStartPtr(bignum: obj.SchemeObject) [*]UnsignedDigit {
    return bignumToPointer(bignum) + 1;
}

inline fn bignumSetHeader(bignum: obj.SchemeObject, length: BignumLength, negative_p: bool) void {
    bignumToPointer(bignum)[0] = @as(UnsignedDigit, @intCast(length)) | (if (negative_p) bignum_radix else 0);
}

inline fn bignumLength(bignum: obj.SchemeObject) BignumLength {
    return @intCast(bignumToPointer(bignum)[0] & bignum_digit_mask);
}

inline fn bignumNegativeP(bignum: obj.SchemeObject) bool {
    return (bignumToPointer(bignum)[0] & bignum_radix) != 0;
}

inline fn bignumZeroP(bignum: obj.SchemeObject) bool {
    return bignumLength(bignum) == 0;
}

inline fn bignumPositiveP(bignum: obj.SchemeObject) bool {
    return !bignumZeroP(bignum) and !bignumNegativeP(bignum);
}

inline fn bignumRef(bignum: obj.SchemeObject, index: usize) UnsignedDigit {
    return bignumStartPtr(bignum)[index];
}

inline fn bignumSet(bignum: obj.SchemeObject, index: usize, val: UnsignedDigit) void {
    bignumStartPtr(bignum)[index] = val;
}

inline fn hdLow(digit: UnsignedDigit) UnsignedDigit {
    return digit & bignum_half_digit_mask;
}

inline fn hdHigh(digit: UnsignedDigit) UnsignedDigit {
    return digit >> half_shift;
}

inline fn hdCons(high: UnsignedDigit, low: UnsignedDigit) UnsignedDigit {
    return (high << half_shift) | low;
}

inline fn digitOnes(n: usize) UnsignedDigit {
    return if (n == 0) 0 else (@as(UnsignedDigit, 1) << @intCast(n)) - 1;
}

inline fn bitsToDigits(n_bits: usize) usize {
    return (n_bits + (bignum_digit_length - 1)) / bignum_digit_length;
}

inline fn digitsForType(comptime T: type) usize {
    return bitsToDigits(@bitSizeOf(T));
}

fn bignumAllocate(length: BignumLength, negative_p: bool) obj.SchemeObject {
    bignumAssert(length >= 0 and length <= bignum_length_max);
    const result = abi.allocate_non_marked_vector(@intCast(obj.tc_big_fixnum), bignumLengthToGcLength(length), true);
    bignumSetHeader(result, length, negative_p);
    return result;
}

fn bignumAllocateZeroed(length: BignumLength, negative_p: bool) obj.SchemeObject {
    const result = bignumAllocate(length, negative_p);
    const start = bignumStartPtr(result);
    @memset(start[0..@as(usize, @intCast(length))], 0);
    return result;
}

fn bignumReduceLength(source: obj.SchemeObject, length: BignumLength) obj.SchemeObject {
    const new_gc_length = bignumLengthToGcLength(length);
    const old_gc_length = obj.vectorLength(source);
    std.debug.assert(new_gc_length <= old_gc_length);
    const delta = old_gc_length - new_gc_length;
    if (delta == 1) {
        obj.vectorSet(source, @intCast(new_gc_length), obj.sharp_f);
    } else if (delta > 1) {
        obj.vectorSet(source, @intCast(new_gc_length), obj.makeNmvHeader(delta - 1));
    }
    if (delta != 0) {
        obj.setVectorLength(source, new_gc_length);
    }
    return source;
}

fn bignumShortenLength(bignum: obj.SchemeObject, length: BignumLength) obj.SchemeObject {
    const current_length = bignumLength(bignum);
    bignumAssert(length >= 0 and length <= current_length);
    if (length < current_length) {
        bignumSetHeader(bignum, length, length != 0 and bignumNegativeP(bignum));
        return bignumReduceLength(bignum, length);
    }
    return bignum;
}

fn bignumTrim(bignum: obj.SchemeObject) obj.SchemeObject {
    const start = bignumStartPtr(bignum);
    const orig_len: usize = @intCast(bignumLength(bignum));
    var scan = orig_len;
    while (scan > 0 and start[scan - 1] == 0) {
        scan -= 1;
    }
    if (scan < orig_len) {
        const new_len: BignumLength = @intCast(scan);
        bignumSetHeader(bignum, new_len, new_len != 0 and bignumNegativeP(bignum));
        return bignumReduceLength(bignum, new_len);
    }
    return bignum;
}

fn bignumDestructiveCopy(source: obj.SchemeObject, target: obj.SchemeObject) void {
    const len: usize = @intCast(bignumLength(source));
    @memcpy(bignumStartPtr(target)[0..len], bignumStartPtr(source)[0..len]);
}

fn bignumNewSign(bignum: obj.SchemeObject, negative_p: bool) obj.SchemeObject {
    const result = bignumAllocate(bignumLength(bignum), negative_p);
    bignumDestructiveCopy(bignum, result);
    return result;
}

inline fn bignumMaybeNewSign(bignum: obj.SchemeObject, negative_p: bool) obj.SchemeObject {
    return if (bignumNegativeP(bignum) == negative_p) bignum else bignumNewSign(bignum, negative_p);
}

fn bignumCopy(source: obj.SchemeObject) obj.SchemeObject {
    return bignumNewSign(source, bignumNegativeP(source));
}

fn bignumDigitToBignum(digit: UnsignedDigit, negative_p: bool) obj.SchemeObject {
    if (digit == 0) return bignum_make_zero();
    const result = bignumAllocate(1, negative_p);
    bignumSet(result, 0, digit);
    return result;
}

pub export fn bignum_make_zero() callconv(.c) obj.SchemeObject {
    const result = abi.allocate_non_marked_vector(@intCast(obj.tc_big_fixnum), bignumLengthToGcLength(0), true);
    bignumSetHeader(result, 0, false);
    return result;
}

pub export fn bignum_make_one(negative_p: c_int) callconv(.c) obj.SchemeObject {
    const result = abi.allocate_non_marked_vector(@intCast(obj.tc_big_fixnum), bignumLengthToGcLength(1), true);
    bignumSetHeader(result, 1, negative_p != 0);
    bignumSet(result, 0, 1);
    return result;
}

fn bignumEqualPUnsigned(x: obj.SchemeObject, y: obj.SchemeObject) bool {
    const len = bignumLength(x);
    if (len != bignumLength(y)) return false;
    const len_u: usize = @intCast(len);
    return std.mem.eql(UnsignedDigit, bignumStartPtr(x)[0..len_u], bignumStartPtr(y)[0..len_u]);
}

fn bignumCompareUnsigned(x: obj.SchemeObject, y: obj.SchemeObject) abi.BignumComparison {
    const x_len = bignumLength(x);
    const y_len = bignumLength(y);
    if (x_len < y_len) return .less;
    if (x_len > y_len) return .greater;
    const x_ptr = bignumStartPtr(x);
    const y_ptr = bignumStartPtr(y);
    var idx: usize = @intCast(x_len);
    while (idx > 0) {
        idx -= 1;
        if (x_ptr[idx] < y_ptr[idx]) return .less;
        if (x_ptr[idx] > y_ptr[idx]) return .greater;
    }
    return .equal;
}

pub export fn bignum_equal_p(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) c_int {
    if (bignumZeroP(x)) return @intFromBool(bignumZeroP(y));
    return @intFromBool(!bignumZeroP(y) and bignumNegativeP(x) == bignumNegativeP(y) and bignumEqualPUnsigned(x, y));
}

pub export fn bignum_test(bignum: obj.SchemeObject) callconv(.c) c_int {
    if (bignumZeroP(bignum)) return @intFromEnum(abi.BignumComparison.equal);
    return @intFromEnum(if (bignumNegativeP(bignum)) abi.BignumComparison.less else abi.BignumComparison.greater);
}

pub export fn bignum_compare(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) c_int {
    const cmp: abi.BignumComparison = if (bignumZeroP(x))
        (if (bignumZeroP(y)) .equal else if (bignumNegativeP(y)) .greater else .less)
    else if (bignumZeroP(y))
        (if (bignumNegativeP(x)) .less else .greater)
    else if (bignumNegativeP(x))
        (if (bignumNegativeP(y)) bignumCompareUnsigned(y, x) else .less)
    else
        (if (bignumNegativeP(y)) .greater else bignumCompareUnsigned(x, y));
    return @intFromEnum(cmp);
}

fn bignumAddUnsigned(x_in: obj.SchemeObject, y_in: obj.SchemeObject, negative_p: bool) obj.SchemeObject {
    var x = x_in;
    var y = y_in;
    if (bignumLength(y) > bignumLength(x)) {
        std.mem.swap(obj.SchemeObject, &x, &y);
    }
    const x_len: usize = @intCast(bignumLength(x));
    const y_len: usize = @intCast(bignumLength(y));
    const r = bignumAllocate(@intCast(x_len + 1), negative_p);
    const x_ptr = bignumStartPtr(x);
    const y_ptr = bignumStartPtr(y);
    const r_ptr = bignumStartPtr(r);

    var carry: UnsignedDigit = 0;
    var i: usize = 0;
    while (i < y_len) : (i += 1) {
        const sum = x_ptr[i] + y_ptr[i] + carry;
        if (sum < bignum_radix) {
            r_ptr[i] = sum;
            carry = 0;
        } else {
            r_ptr[i] = sum - bignum_radix;
            carry = 1;
        }
    }
    if (carry != 0) {
        while (i < x_len) : (i += 1) {
            const sum = x_ptr[i] + 1;
            if (sum < bignum_radix) {
                r_ptr[i] = sum;
                carry = 0;
                i += 1;
                break;
            } else {
                r_ptr[i] = sum - bignum_radix;
            }
        }
    }
    while (i < x_len) : (i += 1) {
        r_ptr[i] = x_ptr[i];
    }
    if (carry != 0) {
        r_ptr[x_len] = 1;
        return r;
    }
    return bignumShortenLength(r, @intCast(x_len));
}

fn bignumSubtractUnsigned(x_in: obj.SchemeObject, y_in: obj.SchemeObject) obj.SchemeObject {
    var x = x_in;
    var y = y_in;
    var negative_p = false;
    switch (bignumCompareUnsigned(x, y)) {
        .equal => return bignum_make_zero(),
        .less => {
            std.mem.swap(obj.SchemeObject, &x, &y);
            negative_p = true;
        },
        .greater => negative_p = false,
    }
    const x_len: usize = @intCast(bignumLength(x));
    const y_len: usize = @intCast(bignumLength(y));
    const r = bignumAllocate(@intCast(x_len), negative_p);
    const x_ptr = bignumStartPtr(x);
    const y_ptr = bignumStartPtr(y);
    const r_ptr = bignumStartPtr(r);

    var borrow: BignumDigit = 0;
    var i: usize = 0;
    while (i < y_len) : (i += 1) {
        const diff: BignumDigit = @as(BignumDigit, @bitCast(x_ptr[i])) - @as(BignumDigit, @bitCast(y_ptr[i])) - borrow;
        if (diff < 0) {
            r_ptr[i] = @intCast(diff + @as(BignumDigit, @intCast(bignum_radix)));
            borrow = 1;
        } else {
            r_ptr[i] = @intCast(diff);
            borrow = 0;
        }
    }
    if (borrow != 0) {
        while (i < x_len) : (i += 1) {
            const diff: BignumDigit = @as(BignumDigit, @bitCast(x_ptr[i])) - borrow;
            if (diff < 0) {
                r_ptr[i] = @intCast(diff + @as(BignumDigit, @intCast(bignum_radix)));
            } else {
                r_ptr[i] = @intCast(diff);
                borrow = 0;
                i += 1;
                break;
            }
        }
    }
    bignumAssert(borrow == 0);
    while (i < x_len) : (i += 1) {
        r_ptr[i] = x_ptr[i];
    }
    return bignumTrim(r);
}

pub export fn bignum_add(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (bignumZeroP(x)) return y;
    if (bignumZeroP(y)) return x;
    if (bignumNegativeP(x)) {
        return if (bignumNegativeP(y)) bignumAddUnsigned(x, y, true) else bignumSubtractUnsigned(y, x);
    } else {
        return if (bignumNegativeP(y)) bignumSubtractUnsigned(x, y) else bignumAddUnsigned(x, y, false);
    }
}

pub export fn bignum_subtract(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (bignumZeroP(x)) {
        return if (bignumZeroP(y)) y else bignumNewSign(y, !bignumNegativeP(y));
    }
    if (bignumZeroP(y)) return x;
    if (bignumNegativeP(x)) {
        return if (bignumNegativeP(y)) bignumSubtractUnsigned(y, x) else bignumAddUnsigned(x, y, true);
    } else {
        return if (bignumNegativeP(y)) bignumAddUnsigned(x, y, false) else bignumSubtractUnsigned(x, y);
    }
}

pub export fn bignum_negate(x: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return if (bignumZeroP(x)) x else bignumNewSign(x, !bignumNegativeP(x));
}

fn bignumDestructiveScaleUp(bignum: obj.SchemeObject, factor: UnsignedDigit) void {
    const ptr = bignumStartPtr(bignum);
    const len: usize = @intCast(bignumLength(bignum));
    bignumAssert(factor > 1 and factor < bignum_radix_root);
    var carry: UnsignedDigit = 0;
    for (0..len) |i| {
        const two_digits = ptr[i];
        const product_low = factor * hdLow(two_digits) + hdLow(carry);
        const product_high = factor * hdHigh(two_digits) + hdHigh(product_low) + hdHigh(carry);
        ptr[i] = hdCons(hdLow(product_high), hdLow(product_low));
        carry = hdHigh(product_high);
    }
    bignumAssert(carry == 0);
}

fn bignumDestructiveAdd(bignum: obj.SchemeObject, n: UnsignedDigit) void {
    const ptr = bignumStartPtr(bignum);
    var digit = ptr[0] + n;
    if (digit < bignum_radix) {
        ptr[0] = digit;
        return;
    }
    ptr[0] = digit - bignum_radix;
    var i: usize = 1;
    while (true) : (i += 1) {
        digit = ptr[i] + 1;
        if (digit < bignum_radix) {
            ptr[i] = digit;
            return;
        }
        ptr[i] = digit - bignum_radix;
    }
}

fn bignumMultiplyUnsignedSmallFactor(x: obj.SchemeObject, y: UnsignedDigit, negative_p: bool) obj.SchemeObject {
    const len_x = bignumLength(x);
    const p = bignumAllocate(len_x + 1, negative_p);
    bignumDestructiveCopy(x, p);
    bignumSet(p, @intCast(len_x), 0);
    bignumDestructiveScaleUp(p, y);
    return bignumTrim(p);
}

fn bignumMultiplyUnsigned(x_in: obj.SchemeObject, y_in: obj.SchemeObject, negative_p: bool) obj.SchemeObject {
    var x = x_in;
    var y = y_in;
    if (bignumLength(y) > bignumLength(x)) {
        std.mem.swap(obj.SchemeObject, &x, &y);
    }
    const x_len: usize = @intCast(bignumLength(x));
    const y_len: usize = @intCast(bignumLength(y));
    const r = bignumAllocateZeroed(@intCast(x_len + y_len), negative_p);
    const x_ptr = bignumStartPtr(x);
    const y_ptr = bignumStartPtr(y);
    const r_ptr = bignumStartPtr(r);

    for (0..x_len) |ix| {
        const x_digit = x_ptr[ix];
        const x_lo = hdLow(x_digit);
        const x_hi = hdHigh(x_digit);
        var carry: UnsignedDigit = 0;
        for (0..y_len) |iy| {
            const y_digit = y_ptr[iy];
            const y_lo = hdLow(y_digit);
            const y_hi = hdHigh(y_digit);
            const ri = ix + iy;
            const prod_lo = r_ptr[ri] + (x_lo * y_lo) + hdLow(carry);
            const prod_hi = (x_hi * y_lo) + (x_lo * y_hi) + hdHigh(prod_lo) + hdHigh(carry);
            r_ptr[ri] = hdCons(hdLow(prod_hi), hdLow(prod_lo));
            carry = (x_hi * y_hi) + hdHigh(prod_hi);
        }
        r_ptr[ix + y_len] += carry;
    }
    return bignumTrim(r);
}

pub export fn bignum_multiply(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const x_len = bignumLength(x);
    const y_len = bignumLength(y);
    const negative_p = bignumNegativeP(x) != bignumNegativeP(y);
    if (bignumZeroP(x)) return x;
    if (bignumZeroP(y)) return y;
    if (x_len == 1) {
        const digit = bignumRef(x, 0);
        if (digit == 1) return bignumMaybeNewSign(y, negative_p);
        if (digit < bignum_radix_root) return bignumMultiplyUnsignedSmallFactor(y, digit, negative_p);
    }
    if (y_len == 1) {
        const digit = bignumRef(y, 0);
        if (digit == 1) return bignumMaybeNewSign(x, negative_p);
        if (digit < bignum_radix_root) return bignumMultiplyUnsignedSmallFactor(x, digit, negative_p);
    }
    return bignumMultiplyUnsigned(x, y, negative_p);
}

fn bignumDestructiveNormalization(source: obj.SchemeObject, target: obj.SchemeObject, shift_left_amt: usize) void {
    const src_ptr = bignumStartPtr(source);
    const dst_ptr = bignumStartPtr(target);
    const src_len: usize = @intCast(bignumLength(source));
    const dst_len: usize = @intCast(bignumLength(target));
    const shift_right_amt = bignum_digit_length - shift_left_amt;
    const mask = digitOnes(shift_right_amt);
    const lsh: std.math.Log2Int(UnsignedDigit) = @intCast(shift_left_amt);
    const rsh: std.math.Log2Int(UnsignedDigit) = @intCast(shift_right_amt);

    var carry: UnsignedDigit = 0;
    for (0..src_len) |i| {
        const digit = src_ptr[i];
        dst_ptr[i] = ((digit & mask) << lsh) | carry;
        carry = digit >> rsh;
    }
    if (src_len < dst_len) {
        dst_ptr[src_len] = carry;
    } else {
        bignumAssert(carry == 0);
    }
}

fn bignumDestructiveUnnormalization(bignum: obj.SchemeObject, shift_right_amt: usize) void {
    const ptr = bignumStartPtr(bignum);
    var idx: usize = @intCast(bignumLength(bignum));
    const shift_left_amt = bignum_digit_length - shift_right_amt;
    const mask = digitOnes(shift_right_amt);
    const rsh: std.math.Log2Int(UnsignedDigit) = @intCast(shift_right_amt);
    const lsh: std.math.Log2Int(UnsignedDigit) = @intCast(shift_left_amt);

    var carry: UnsignedDigit = 0;
    while (idx > 0) {
        idx -= 1;
        const digit = ptr[idx];
        ptr[idx] = (digit >> rsh) | carry;
        carry = (digit & mask) << lsh;
    }
    bignumAssert(carry == 0);
}

fn bignumDigitDivideSubtract(
    v1: UnsignedDigit,
    v2: UnsignedDigit,
    guess: UnsignedDigit,
    u: *[4]UnsignedDigit,
    j: usize,
) UnsignedDigit {
    var carry: UnsignedDigit = 0;
    inline for (.{ .{ v2, j + 2 }, .{ v1, j + 1 } }) |step| {
        const vn = step[0];
        const idx = step[1];
        const product = vn * guess + carry;
        const diff: BignumDigit = @as(BignumDigit, @bitCast(u[idx])) - @as(BignumDigit, @bitCast(hdLow(product)));
        if (diff < 0) {
            u[idx] = @intCast(diff + @as(BignumDigit, @intCast(bignum_radix_root)));
            carry = hdHigh(product) + 1;
        } else {
            u[idx] = @intCast(diff);
            carry = hdHigh(product);
        }
    }
    if (carry == 0) return guess;

    const top_diff: BignumDigit = @as(BignumDigit, @bitCast(u[j])) - @as(BignumDigit, @bitCast(carry));
    if (top_diff < 0) {
        u[j] = @intCast(top_diff + @as(BignumDigit, @intCast(bignum_radix)));
    } else {
        u[j] = @intCast(top_diff);
        return guess;
    }

    var add_carry: UnsignedDigit = 0;
    inline for (.{ .{ v2, j + 2 }, .{ v1, j + 1 } }) |step| {
        const vn = step[0];
        const idx = step[1];
        const sum = vn + u[idx] + add_carry;
        if (sum < bignum_radix_root) {
            u[idx] = sum;
            add_carry = 0;
        } else {
            u[idx] = sum - bignum_radix_root;
            add_carry = 1;
        }
    }
    if (add_carry == 1) u[j] += 1;
    return guess - 1;
}

fn bignumDigitDivide(uh: UnsignedDigit, ul: UnsignedDigit, v: UnsignedDigit, q: *UnsignedDigit) UnsignedDigit {
    if (uh == 0) {
        if (ul < v) {
            q.* = 0;
            return ul;
        } else if (ul == v) {
            q.* = 1;
            return 0;
        }
    }
    var u = [4]UnsignedDigit{ hdHigh(uh), hdLow(uh), hdHigh(ul), hdLow(ul) };
    const v1 = hdHigh(v);
    const v2 = hdLow(v);
    var qs: [2]UnsignedDigit = undefined;
    inline for (0..2) |j| {
        const uj = u[j];
        var guess: UnsignedDigit = undefined;
        var comparand: UnsignedDigit = undefined;
        if (uj != v1) {
            const uj_uj1 = hdCons(uj, u[j + 1]);
            guess = uj_uj1 / v1;
            comparand = hdCons(uj_uj1 % v1, u[j + 2]);
        } else {
            guess = bignum_radix_root - 1;
            comparand = hdCons(u[j + 1] + v1, u[j + 2]);
        }
        while (guess * v2 > comparand) {
            guess -= 1;
            comparand += v1 << half_shift;
            if (comparand >= bignum_radix) break;
        }
        qs[j] = bignumDigitDivideSubtract(v1, v2, guess, &u, j);
    }
    q.* = hdCons(qs[0], qs[1]);
    return hdCons(u[2], u[3]);
}

fn bignumDivideSubtract(
    v_ptr: [*]const UnsignedDigit,
    v_len: usize,
    guess: UnsignedDigit,
    u_ptr: [*]UnsignedDigit,
) UnsignedDigit {
    if (guess == 0) return 0;
    const gl = hdLow(guess);
    const gh = hdHigh(guess);
    var carry: UnsignedDigit = 0;
    for (0..v_len) |i| {
        const v = v_ptr[i];
        const vl = hdLow(v);
        const vh = hdHigh(v);
        const pl = (vl * gl) + hdLow(carry);
        const ph = (vl * gh) + (vh * gl) + hdHigh(pl) + hdHigh(carry);
        const sub = hdCons(hdLow(ph), hdLow(pl));
        const diff: BignumDigit = @as(BignumDigit, @bitCast(u_ptr[i])) - @as(BignumDigit, @bitCast(sub));
        if (diff < 0) {
            u_ptr[i] = @intCast(diff + @as(BignumDigit, @intCast(bignum_radix)));
            carry = (vh * gh) + hdHigh(ph) + 1;
        } else {
            u_ptr[i] = @intCast(diff);
            carry = (vh * gh) + hdHigh(ph);
        }
    }
    if (carry == 0) return guess;

    const top_diff: BignumDigit = @as(BignumDigit, @bitCast(u_ptr[v_len])) - @as(BignumDigit, @bitCast(carry));
    if (top_diff < 0) {
        u_ptr[v_len] = @intCast(top_diff + @as(BignumDigit, @intCast(bignum_radix)));
    } else {
        u_ptr[v_len] = @intCast(top_diff);
        return guess;
    }

    var add_carry: UnsignedDigit = 0;
    for (0..v_len) |i| {
        const sum = v_ptr[i] + u_ptr[i] + add_carry;
        if (sum < bignum_radix) {
            u_ptr[i] = sum;
            add_carry = 0;
        } else {
            u_ptr[i] = sum - bignum_radix;
            add_carry = 1;
        }
    }
    if (add_carry == 1) {
        const sum = u_ptr[v_len] + 1;
        u_ptr[v_len] = if (sum < bignum_radix) sum else sum - bignum_radix;
    }
    return guess - 1;
}

fn bignumDivideUnsignedNormalized(u: obj.SchemeObject, v: obj.SchemeObject, q: obj.SchemeObject) void {
    const u_len: usize = @intCast(bignumLength(u));
    const v_len: usize = @intCast(bignumLength(v));
    const u_start = bignumStartPtr(u);
    const v_start = bignumStartPtr(v);
    var u_scan = u_len;
    var u_scan_start = u_len - v_len;
    const v1 = v_start[v_len - 1];
    const v2 = v_start[v_len - 2];
    const v2l = hdLow(v2);
    const v2h = hdHigh(v2);
    var q_scan: usize = if (q != bignum_out_of_band) @intCast(bignumLength(q)) else 0;
    const q_start: [*]UnsignedDigit = if (q != bignum_out_of_band) bignumStartPtr(q) else undefined;

    while (u_scan > v_len) {
        u_scan -= 1;
        const uj = u_start[u_scan];
        const cl = u_start[u_scan - 2];
        var ch: UnsignedDigit = undefined;
        var guess: UnsignedDigit = undefined;
        if (uj != v1) {
            ch = bignumDigitDivide(uj, u_start[u_scan - 1], v1, &guess);
        } else {
            ch = u_start[u_scan - 1] + v1;
            guess = bignum_radix - 1;
        }
        while (true) {
            const gl = hdLow(guess);
            const gh = hdHigh(guess);
            var pl = v2l * gl;
            var ph = (v2l * gh) + (v2h * gl) + hdHigh(pl);
            pl = hdCons(hdLow(ph), hdLow(pl));
            ph = (v2h * gh) + hdHigh(ph);
            if (ch > ph or (ch == ph and cl >= pl)) break;
            guess -= 1;
            ch += v1;
            if (ch >= bignum_radix) break;
        }
        u_scan_start -= 1;
        const qj = bignumDivideSubtract(v_start, v_len, guess, u_start + u_scan_start);
        if (q != bignum_out_of_band) {
            q_scan -= 1;
            q_start[q_scan] = qj;
        }
    }
}

fn bignumDivideUnsignedLargeDenominator(
    numerator: obj.SchemeObject,
    denominator: obj.SchemeObject,
    quotient: ?*obj.SchemeObject,
    remainder: ?*obj.SchemeObject,
    q_negative_p: bool,
    r_negative_p: bool,
) void {
    const length_n = bignumLength(numerator) + 1;
    const length_d = bignumLength(denominator);
    bignumAssert(length_d > 1);
    const q = if (quotient != null) bignumAllocate(length_n - length_d, q_negative_p) else bignum_out_of_band;
    const u = bignumAllocate(length_n, r_negative_p);

    var shift: usize = 0;
    var v1 = bignumRef(denominator, @intCast(length_d - 1));
    while (v1 < bignum_radix / 2) {
        v1 <<= 1;
        shift += 1;
    }
    if (shift == 0) {
        bignumDestructiveCopy(numerator, u);
        bignumSet(u, @intCast(length_n - 1), 0);
        bignumDivideUnsignedNormalized(u, denominator, q);
    } else {
        const v = bignumAllocate(length_d, false);
        bignumDestructiveNormalization(numerator, u, shift);
        bignumDestructiveNormalization(denominator, v, shift);
        bignumDivideUnsignedNormalized(u, v, q);
        if (remainder != null) bignumDestructiveUnnormalization(u, shift);
    }
    if (quotient) |qp| qp.* = bignumTrim(q);
    if (remainder) |rp| rp.* = bignumTrim(u);
}

fn bignumDivideUnsignedMediumDenominator(
    numerator: obj.SchemeObject,
    denominator_in: UnsignedDigit,
    quotient: ?*obj.SchemeObject,
    remainder: ?*obj.SchemeObject,
    q_negative_p: bool,
    r_negative_p: bool,
) void {
    var denominator = denominator_in;
    const length_n = bignumLength(numerator);
    var shift: usize = 0;
    while (denominator < bignum_radix / 2) {
        denominator <<= 1;
        shift += 1;
    }
    const length_q = if (shift == 0) length_n else length_n + 1;
    const q = bignumAllocate(length_q, q_negative_p);
    if (shift == 0) {
        bignumDestructiveCopy(numerator, q);
    } else {
        bignumDestructiveNormalization(numerator, q, shift);
    }
    var r: UnsignedDigit = 0;
    const q_ptr = bignumStartPtr(q);
    var idx: usize = @intCast(length_q);
    var qj: UnsignedDigit = undefined;
    if (quotient) |qp| {
        while (idx > 0) {
            idx -= 1;
            r = bignumDigitDivide(r, q_ptr[idx], denominator, &qj);
            q_ptr[idx] = qj;
        }
        qp.* = bignumTrim(q);
    } else {
        while (idx > 0) {
            idx -= 1;
            r = bignumDigitDivide(r, q_ptr[idx], denominator, &qj);
        }
    }
    if (remainder) |rp| {
        if (shift != 0) r >>= @intCast(shift);
        rp.* = bignumDigitToBignum(r, r_negative_p);
    }
}

fn bignumDestructiveScaleDown(bignum: obj.SchemeObject, denominator: UnsignedDigit) UnsignedDigit {
    bignumAssert(denominator > 1 and denominator < bignum_radix_root);
    const ptr = bignumStartPtr(bignum);
    var idx: usize = @intCast(bignumLength(bignum));
    var remainder: UnsignedDigit = 0;
    while (idx > 0) {
        idx -= 1;
        const two_digits = ptr[idx];
        var num = hdCons(remainder, hdHigh(two_digits));
        const q_hi = num / denominator;
        num = hdCons(num % denominator, hdLow(two_digits));
        ptr[idx] = hdCons(q_hi, num / denominator);
        remainder = num % denominator;
    }
    return remainder;
}

fn bignumDivideUnsignedSmallDenominator(
    numerator: obj.SchemeObject,
    denominator: UnsignedDigit,
    quotient: *obj.SchemeObject,
    remainder: ?*obj.SchemeObject,
    q_negative_p: bool,
    r_negative_p: bool,
) void {
    const q = bignumNewSign(numerator, q_negative_p);
    const r = bignumDestructiveScaleDown(q, denominator);
    quotient.* = bignumTrim(q);
    if (remainder) |rp| {
        rp.* = bignumDigitToBignum(r, r_negative_p);
    }
}

fn bignumRemainderUnsignedSmallDenominator(
    n: obj.SchemeObject,
    d: UnsignedDigit,
    negative_p: bool,
) obj.SchemeObject {
    bignumAssert(d > 1 and d < bignum_radix_root);
    const ptr = bignumStartPtr(n);
    var idx: usize = @intCast(bignumLength(n));
    var r: UnsignedDigit = 0;
    while (idx > 0) {
        idx -= 1;
        const two_digits = ptr[idx];
        const hi_rem = hdCons(r, hdHigh(two_digits)) % d;
        r = hdCons(hi_rem, hdLow(two_digits)) % d;
    }
    return bignumDigitToBignum(r, negative_p);
}

pub export fn bignum_divide(
    numerator: obj.SchemeObject,
    denominator: obj.SchemeObject,
    quotient: *obj.SchemeObject,
    remainder: *obj.SchemeObject,
) callconv(.c) c_int {
    if (bignumZeroP(denominator)) return 1;
    if (bignumZeroP(numerator)) {
        quotient.* = numerator;
        remainder.* = numerator;
        return 0;
    }
    const r_neg = bignumNegativeP(numerator);
    const q_neg = if (bignumNegativeP(denominator)) !r_neg else r_neg;
    switch (bignumCompareUnsigned(numerator, denominator)) {
        .equal => {
            quotient.* = bignum_make_one(@intFromBool(q_neg));
            remainder.* = bignum_make_zero();
        },
        .less => {
            quotient.* = bignum_make_zero();
            remainder.* = numerator;
        },
        .greater => {
            if (bignumLength(denominator) == 1) {
                const digit = bignumRef(denominator, 0);
                if (digit == 1) {
                    quotient.* = bignumMaybeNewSign(numerator, q_neg);
                    remainder.* = bignum_make_zero();
                    return 0;
                } else if (digit < bignum_radix_root) {
                    bignumDivideUnsignedSmallDenominator(numerator, digit, quotient, remainder, q_neg, r_neg);
                    return 0;
                } else {
                    bignumDivideUnsignedMediumDenominator(numerator, digit, quotient, remainder, q_neg, r_neg);
                    return 0;
                }
            }
            bignumDivideUnsignedLargeDenominator(numerator, denominator, quotient, remainder, q_neg, r_neg);
        },
    }
    return 0;
}

pub export fn bignum_quotient(numerator: obj.SchemeObject, denominator: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (bignumZeroP(denominator)) return bignum_out_of_band;
    if (bignumZeroP(numerator)) return numerator;
    const q_neg = bignumNegativeP(denominator) != bignumNegativeP(numerator);
    switch (bignumCompareUnsigned(numerator, denominator)) {
        .equal => return bignum_make_one(@intFromBool(q_neg)),
        .less => return bignum_make_zero(),
        .greater => {
            var quotient: obj.SchemeObject = undefined;
            if (bignumLength(denominator) == 1) {
                const digit = bignumRef(denominator, 0);
                if (digit == 1) return bignumMaybeNewSign(numerator, q_neg);
                if (digit < bignum_radix_root) {
                    bignumDivideUnsignedSmallDenominator(numerator, digit, &quotient, null, q_neg, false);
                } else {
                    bignumDivideUnsignedMediumDenominator(numerator, digit, &quotient, null, q_neg, false);
                }
            } else {
                bignumDivideUnsignedLargeDenominator(numerator, denominator, &quotient, null, q_neg, false);
            }
            return quotient;
        },
    }
}

pub export fn bignum_remainder(numerator: obj.SchemeObject, denominator: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (bignumZeroP(denominator)) return bignum_out_of_band;
    if (bignumZeroP(numerator)) return numerator;
    switch (bignumCompareUnsigned(numerator, denominator)) {
        .equal => return bignum_make_zero(),
        .less => return numerator,
        .greater => {
            var rem: obj.SchemeObject = undefined;
            if (bignumLength(denominator) == 1) {
                const digit = bignumRef(denominator, 0);
                if ((digit & (digit - 1)) == 0) {
                    if (bignumLength(numerator) == 0) return bignum_make_zero();
                    const urem = (digit - 1) & bignumRef(numerator, 0);
                    if (urem == 0) return bignum_make_zero();
                    return bignumDigitToBignum(urem, bignumNegativeP(numerator));
                }
                if (digit < bignum_radix_root) {
                    return bignumRemainderUnsignedSmallDenominator(numerator, digit, bignumNegativeP(numerator));
                }
                bignumDivideUnsignedMediumDenominator(numerator, digit, null, &rem, false, bignumNegativeP(numerator));
            } else {
                bignumDivideUnsignedLargeDenominator(numerator, denominator, null, &rem, false, bignumNegativeP(numerator));
            }
            return rem;
        },
    }
}

fn bignumFromDigits(digits: []const UnsignedDigit, negative_p: bool) obj.SchemeObject {
    const result = bignumAllocate(@intCast(digits.len), negative_p);
    @memcpy(bignumStartPtr(result)[0..digits.len], digits);
    return result;
}

fn intToBignum(comptime T: type, comptime U: type, n: T) obj.SchemeObject {
    if (n == 0) return bignum_make_zero();
    if (n == 1) return bignum_make_one(0);
    if (n == -1) return bignum_make_one(1);
    const negative_p = n < 0;
    var acc: U = if (negative_p) @as(U, 0) -% @as(U, @bitCast(n)) else @intCast(n);
    var result_digits: [digitsForType(T)]UnsignedDigit = undefined;
    var len: usize = 0;
    while (true) {
        result_digits[len] = @intCast(acc & bignum_digit_mask);
        len += 1;
        acc >>= digit_shift;
        if (acc == 0) break;
    }
    return bignumFromDigits(result_digits[0..len], negative_p);
}

fn uintToBignum(comptime T: type, n: T) obj.SchemeObject {
    if (n == 0) return bignum_make_zero();
    if (n == 1) return bignum_make_one(0);
    var acc = n;
    var result_digits: [digitsForType(T)]UnsignedDigit = undefined;
    var len: usize = 0;
    while (true) {
        result_digits[len] = @intCast(acc & bignum_digit_mask);
        len += 1;
        acc >>= digit_shift;
        if (acc == 0) break;
    }
    return bignumFromDigits(result_digits[0..len], false);
}

fn bignumToInt(comptime T: type, comptime U: type, bignum: obj.SchemeObject) T {
    if (bignumZeroP(bignum)) return 0;
    var acc: U = 0;
    const ptr = bignumStartPtr(bignum);
    var idx: usize = @intCast(bignumLength(bignum));
    while (idx > 0) {
        idx -= 1;
        acc = (acc << digit_shift) +% @as(U, @intCast(ptr[idx]));
    }
    return if (bignumNegativeP(bignum)) @bitCast(@as(U, 0) -% acc) else @bitCast(acc);
}

fn bignumToUint(comptime U: type, bignum: obj.SchemeObject) U {
    if (bignumZeroP(bignum)) return 0;
    bignumAssert(bignumPositiveP(bignum));
    var acc: U = 0;
    const ptr = bignumStartPtr(bignum);
    var idx: usize = @intCast(bignumLength(bignum));
    while (idx > 0) {
        idx -= 1;
        acc = (acc << digit_shift) +% @as(U, @intCast(ptr[idx]));
    }
    return acc;
}

pub export fn long_to_bignum(n: c_long) callconv(.c) obj.SchemeObject {
    return intToBignum(c_long, c_ulong, n);
}

pub export fn intmax_to_bignum(n: i64) callconv(.c) obj.SchemeObject {
    return intToBignum(i64, u64, n);
}

pub export fn bignum_to_long(bignum: obj.SchemeObject) callconv(.c) c_long {
    return bignumToInt(c_long, c_ulong, bignum);
}

pub export fn bignum_to_intmax(bignum: obj.SchemeObject) callconv(.c) i64 {
    return bignumToInt(i64, u64, bignum);
}

pub export fn ulong_to_bignum(n: c_ulong) callconv(.c) obj.SchemeObject {
    return uintToBignum(c_ulong, n);
}

pub export fn uintmax_to_bignum(n: u64) callconv(.c) obj.SchemeObject {
    return uintToBignum(u64, n);
}

pub export fn bignum_to_ulong(bignum: obj.SchemeObject) callconv(.c) c_ulong {
    return bignumToUint(c_ulong, bignum);
}

pub export fn bignum_to_uintmax(bignum: obj.SchemeObject) callconv(.c) u64 {
    return bignumToUint(u64, bignum);
}

pub export fn double_to_bignum(x: f64) callconv(.c) obj.SchemeObject {
    var exponent: c_int = 0;
    var significand = frexp(x, &exponent);
    if (exponent <= 0) return bignum_make_zero();
    if (exponent == 1) return bignum_make_one(@intFromBool(x < 0));
    if (significand < 0) significand = -significand;

    const length: BignumLength = @intCast(bitsToDigits(@intCast(exponent)));
    const result = bignumAllocate(length, x < 0);
    const start = bignumStartPtr(result);
    var idx: usize = @intCast(length);
    var n_valid_bits: usize = @intCast(abi.dbl_mant_dig);

    const odd_bits: usize = @intCast(@rem(exponent, bignum_digit_length));
    if (odd_bits > 0) {
        significand *= @as(f64, @floatFromInt(@as(UnsignedDigit, 1) << @intCast(odd_bits)));
        const digit: UnsignedDigit = @intFromFloat(significand);
        idx -= 1;
        start[idx] = digit;
        significand -= @as(f64, @floatFromInt(digit));
        // odd_bits can exceed dbl_mant_dig (e.g. 60 > 53 on 64-bit digits).
        n_valid_bits -|= odd_bits;
    }

    const radix_f: f64 = @floatFromInt(bignum_radix);
    while (idx > 0) {
        if (significand == 0.0 or n_valid_bits == 0) {
            @memset(start[0..idx], 0);
            break;
        }
        if (n_valid_bits >= bignum_digit_length) {
            significand *= radix_f;
            const digit: UnsignedDigit = @intFromFloat(significand);
            idx -= 1;
            start[idx] = digit;
            significand -= @as(f64, @floatFromInt(digit));
            n_valid_bits -= bignum_digit_length;
        } else {
            significand *= radix_f;
            const digit: UnsignedDigit = @intFromFloat(significand);
            const keep_mask = digitOnes(n_valid_bits) << @intCast(bignum_digit_length - n_valid_bits);
            idx -= 1;
            start[idx] = digit & keep_mask;
            significand = 0.0;
            n_valid_bits = 0;
        }
    }
    return result;
}

pub export fn bignum_to_double(bignum: obj.SchemeObject) callconv(.c) f64 {
    if (bignumZeroP(bignum)) return 0.0;

    const length = bignumLength(bignum);
    var index: usize = @intCast(length - 1);
    var scale_words: usize = 0;
    const msd = bignumRef(bignum, index);
    var bits_to_get: usize = @intCast(abi.dbl_mant_dig);
    var value: f64 = 0.0;
    const radix_f: f64 = @floatFromInt(bignum_radix);
    var guard_bit_mask: UnsignedDigit = bignum_radix >> 1;
    var rounding_correction: UnsignedDigit = 0;
    var current_digit_bit_count: usize = bits.ulongLengthInBits(msd);
    var mask: UnsignedDigit = digitOnes(current_digit_bit_count);
    var hit_digit_boundary = false;

    const result: f64 = blk: {
        while (true) {
            if (current_digit_bit_count > bits_to_get) {
                guard_bit_mask = @as(UnsignedDigit, 1) << @intCast(current_digit_bit_count - bits_to_get - 1);
                mask &= ~((guard_bit_mask << 1) - 1);
                current_digit_bit_count = bits_to_get;
                bits_to_get = 0;
                hit_digit_boundary = false;
            } else {
                bits_to_get -= current_digit_bit_count;
                hit_digit_boundary = (bits_to_get == 0);
            }

            value = (value * radix_f) + @as(f64, @floatFromInt(bignumRef(bignum, index) & mask));

            if (bits_to_get == 0) {
                scale_words = index;
                if (hit_digit_boundary) {
                    if (index == 0) break :blk value;
                    guard_bit_mask = @as(UnsignedDigit, 1) << (bignum_digit_length - 1);
                    rounding_correction = 1;
                    index -= 1;
                } else {
                    rounding_correction = guard_bit_mask << 1;
                }
                break;
            }
            if (index == 0) break :blk value;
            index -= 1;
            current_digit_bit_count = bignum_digit_length;
            mask = bignum_digit_mask;
        }

        const digit_at_idx = bignumRef(bignum, index);
        var round_up = false;
        if ((digit_at_idx & guard_bit_mask) == 0) {
            round_up = false;
        } else if ((digit_at_idx & (guard_bit_mask - 1)) != 0) {
            round_up = true;
        } else if ((guard_bit_mask << 1) == bignum_radix) {
            round_up = (bignumRef(bignum, index + 1) & 1) != 0;
        } else if ((digit_at_idx & (guard_bit_mask << 1)) != 0) {
            round_up = true;
        } else {
            var idx2 = index;
            while (idx2 > 0) {
                idx2 -= 1;
                if (bignumRef(bignum, idx2) != 0) {
                    round_up = true;
                    break;
                }
            }
        }

        if (round_up) {
            value += @floatFromInt(rounding_correction);
        }
        if (scale_words > 0) {
            const bit_shift = scale_words * bignum_digit_length;
            const exp_arg: c_int = if (bit_shift > std.math.maxInt(c_int))
                std.math.maxInt(c_int)
            else
                @intCast(bit_shift);
            value = ldexp(value, exp_arg);
        }
        break :blk value;
    };

    return if (bignumNegativeP(bignum)) -result else result;
}

pub export fn bignum_fits_in_word_p(
    bignum: obj.SchemeObject,
    word_length: c_long,
    twos_complement_p: c_int,
) callconv(.c) c_int {
    if (twos_complement_p == 0 and bignumNegativeP(bignum)) return 0;
    const raw_bits = if (twos_complement_p != 0) word_length - 1 else word_length;
    bignumAssert(raw_bits > 0);
    const n_bits: usize = @intCast(raw_bits);

    const length: usize = @intCast(bignumLength(bignum));
    const max_digits = bitsToDigits(n_bits);
    if (length < max_digits) return 1;
    if (length > max_digits) return 0;

    const msd = bignumRef(bignum, length - 1);
    const max = @as(UnsignedDigit, 1) << @intCast(n_bits - (length - 1) * bignum_digit_length);
    if (msd < max) return 1;
    if (twos_complement_p != 0 and msd == max and bignumNegativeP(bignum)) {
        for (0..length - 1) |i| {
            if (bignumRef(bignum, i) != 0) return 0;
        }
        return 1;
    }
    return 0;
}

pub export fn bignum_bitwise_not(bignum: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bignum_subtract(bignum_make_one(1), bignum);
}

const BitwiseOpKind = enum {
    u_and,
    u_andc2,
    u_andc1,
    u_xor,
    u_ior,
    u_nor,
    u_eqv,
    u_nand,
};

fn bitwiseUnsigned(comptime kind: BitwiseOpKind, x_in: obj.SchemeObject, y_in: obj.SchemeObject) obj.SchemeObject {
    var x = x_in;
    var y = y_in;
    if (bignumLength(x) < bignumLength(y)) {
        switch (kind) {
            .u_andc2 => return bitwiseUnsigned(.u_andc1, y, x),
            .u_andc1 => return bitwiseUnsigned(.u_andc2, y, x),
            else => std.mem.swap(obj.SchemeObject, &x, &y),
        }
    }
    const x_len: usize = @intCast(bignumLength(x));
    const y_len: usize = @intCast(bignumLength(y));
    const r = bignumAllocate(@intCast(x_len), false);
    const x_ptr = bignumStartPtr(x);
    const y_ptr = bignumStartPtr(y);
    const r_ptr = bignumStartPtr(r);

    var i: usize = 0;
    while (i < y_len) : (i += 1) {
        const vx = x_ptr[i];
        const vy = y_ptr[i];
        r_ptr[i] = switch (kind) {
            .u_and, .u_nand => vx & vy,
            .u_andc2 => vx & ~vy,
            .u_andc1 => vy & ~vx,
            .u_xor, .u_eqv => vx ^ vy,
            .u_ior, .u_nor => vx | vy,
        };
    }
    while (i < x_len) : (i += 1) {
        const vx = x_ptr[i];
        r_ptr[i] = switch (kind) {
            .u_and, .u_nand, .u_andc1 => 0,
            .u_andc2, .u_xor, .u_eqv, .u_ior, .u_nor => vx,
        };
    }
    const trimmed = bignumTrim(r);
    return switch (kind) {
        .u_nor, .u_eqv, .u_nand => bignum_bitwise_not(trimmed),
        else => trimmed,
    };
}

const BitwiseKind = enum {
    and_op,
    andc2_op,
    andc1_op,
    xor_op,
    ior_op,
    nor_op,
    eqv_op,
    orc2_op,
    orc1_op,
    nand_op,
};

fn bitwiseApplyUnsigned(comptime op: enum { b_and, b_andc2, b_andc1, b_xor, b_ior, b_nor, b_eqv, b_orc2, b_orc1, b_nand }, a: obj.SchemeObject, b: obj.SchemeObject) obj.SchemeObject {
    return switch (op) {
        .b_and => bitwiseUnsigned(.u_and, a, b),
        .b_andc2 => bitwiseUnsigned(.u_andc2, a, b),
        .b_andc1 => bitwiseUnsigned(.u_andc1, a, b),
        .b_xor => bitwiseUnsigned(.u_xor, a, b),
        .b_ior => bitwiseUnsigned(.u_ior, a, b),
        .b_nor => bitwiseUnsigned(.u_nor, a, b),
        .b_eqv => bitwiseUnsigned(.u_eqv, a, b),
        .b_nand => bitwiseUnsigned(.u_nand, a, b),
        .b_orc2 => bignum_bitwise_not(bitwiseUnsigned(.u_andc1, a, b)),
        .b_orc1 => bignum_bitwise_not(bitwiseUnsigned(.u_andc2, a, b)),
    };
}

fn bitwiseCombine(comptime kind: BitwiseKind, x: obj.SchemeObject, y: obj.SchemeObject) obj.SchemeObject {
    if (bignumZeroP(x)) {
        return switch (kind) {
            .and_op, .andc2_op => bignum_make_zero(),
            .andc1_op, .xor_op, .ior_op => y,
            .nor_op, .eqv_op, .orc2_op => bignum_bitwise_not(y),
            .orc1_op, .nand_op => bignum_make_one(1),
        };
    }
    if (bignumZeroP(y)) {
        return switch (kind) {
            .and_op, .andc1_op => bignum_make_zero(),
            .andc2_op, .xor_op, .ior_op => x,
            .nor_op, .eqv_op, .orc1_op => bignum_bitwise_not(x),
            .orc2_op, .nand_op => bignum_make_one(1),
        };
    }
    const px = bignumPositiveP(x);
    const py = bignumPositiveP(y);
    const ax = if (px) x else bignum_bitwise_not(x);
    const ay = if (py) y else bignum_bitwise_not(y);

    return switch (kind) {
        .and_op => if (px) (if (py) bitwiseApplyUnsigned(.b_and, ax, ay) else bitwiseApplyUnsigned(.b_andc2, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_andc1, ax, ay) else bitwiseApplyUnsigned(.b_nor, ax, ay)),
        .andc2_op => if (px) (if (py) bitwiseApplyUnsigned(.b_andc2, ax, ay) else bitwiseApplyUnsigned(.b_and, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_nor, ax, ay) else bitwiseApplyUnsigned(.b_andc1, ax, ay)),
        .andc1_op => if (px) (if (py) bitwiseApplyUnsigned(.b_andc1, ax, ay) else bitwiseApplyUnsigned(.b_nor, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_and, ax, ay) else bitwiseApplyUnsigned(.b_andc2, ax, ay)),
        .xor_op => if (px == py) bitwiseApplyUnsigned(.b_xor, ax, ay) else bitwiseApplyUnsigned(.b_eqv, ax, ay),
        .ior_op => if (px) (if (py) bitwiseApplyUnsigned(.b_ior, ax, ay) else bitwiseApplyUnsigned(.b_orc2, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_orc1, ax, ay) else bitwiseApplyUnsigned(.b_nand, ax, ay)),
        .nor_op => if (px) (if (py) bitwiseApplyUnsigned(.b_nor, ax, ay) else bitwiseApplyUnsigned(.b_andc1, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_andc2, ax, ay) else bitwiseApplyUnsigned(.b_and, ax, ay)),
        .eqv_op => if (px == py) bitwiseApplyUnsigned(.b_eqv, ax, ay) else bitwiseApplyUnsigned(.b_xor, ax, ay),
        .orc2_op => if (px) (if (py) bitwiseApplyUnsigned(.b_orc2, ax, ay) else bitwiseApplyUnsigned(.b_ior, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_nand, ax, ay) else bitwiseApplyUnsigned(.b_orc1, ax, ay)),
        .orc1_op => if (px) (if (py) bitwiseApplyUnsigned(.b_orc1, ax, ay) else bitwiseApplyUnsigned(.b_nand, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_ior, ax, ay) else bitwiseApplyUnsigned(.b_orc2, ax, ay)),
        .nand_op => if (px) (if (py) bitwiseApplyUnsigned(.b_nand, ax, ay) else bitwiseApplyUnsigned(.b_orc1, ax, ay)) else (if (py) bitwiseApplyUnsigned(.b_orc2, ax, ay) else bitwiseApplyUnsigned(.b_ior, ax, ay)),
    };
}

pub export fn bignum_bitwise_and(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.and_op, x, y);
}
pub export fn bignum_bitwise_andc2(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.andc2_op, x, y);
}
pub export fn bignum_bitwise_andc1(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.andc1_op, x, y);
}
pub export fn bignum_bitwise_xor(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.xor_op, x, y);
}
pub export fn bignum_bitwise_ior(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.ior_op, x, y);
}
pub export fn bignum_bitwise_nor(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.nor_op, x, y);
}
pub export fn bignum_bitwise_eqv(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.eqv_op, x, y);
}
pub export fn bignum_bitwise_orc2(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.orc2_op, x, y);
}
pub export fn bignum_bitwise_orc1(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.orc1_op, x, y);
}
pub export fn bignum_bitwise_nand(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return bitwiseCombine(.nand_op, x, y);
}

pub export fn bignum_length_in_bits(bignum: obj.SchemeObject) callconv(.c) c_ulong {
    if (bignumZeroP(bignum)) return 0;
    const index: usize = @intCast(bignumLength(bignum) - 1);
    return @as(c_ulong, bits.ulongLengthInBits(bignumRef(bignum, index))) + (bignum_digit_length * @as(c_ulong, @intCast(index)));
}

pub export fn bignum_integer_length(bignum: obj.SchemeObject) callconv(.c) c_ulong {
    const len_in_bits = bignum_length_in_bits(bignum);
    if (bignumZeroP(bignum) or bignumPositiveP(bignum)) return len_in_bits;
    const ptr = bignumStartPtr(bignum);
    const end_idx: usize = @intCast(bignumLength(bignum) - 1);
    for (0..end_idx) |i| {
        if (ptr[i] != 0) return len_in_bits;
    }
    const msd = ptr[end_idx];
    return if ((msd & (msd - 1)) == 0) len_in_bits - 1 else len_in_bits;
}

pub export fn bignum_first_set_bit(bignum: obj.SchemeObject) callconv(.c) c_long {
    if (bignumZeroP(bignum)) return -1;
    const ptr = bignumStartPtr(bignum);
    const len: usize = @intCast(bignumLength(bignum));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (ptr[i] != 0) {
            return @intCast(@as(usize, @ctz(ptr[i])) + (i * bignum_digit_length));
        }
    }
    bignumAssert(false);
    unreachable;
}

fn digitsBitCount(ptr: [*]const UnsignedDigit, count: usize) c_ulong {
    var total: c_ulong = 0;
    for (0..count) |i| {
        total += bits.ulongBitCount(ptr[i]);
    }
    return total;
}

fn digitsHammingDistance(x_ptr: [*]const UnsignedDigit, y_ptr: [*]const UnsignedDigit, count: usize) c_ulong {
    var total: c_ulong = 0;
    for (0..count) |i| {
        total += bits.ulongBitCount(x_ptr[i] ^ y_ptr[i]);
    }
    return total;
}

fn bignumBitCountUnsigned(x: obj.SchemeObject) c_ulong {
    return digitsBitCount(bignumStartPtr(x), @intCast(bignumLength(x)));
}

fn bignumPositiveHammingDistance(x_in: obj.SchemeObject, y_in: obj.SchemeObject) c_ulong {
    var x = x_in;
    var y = y_in;
    bignumAssert(!bignumZeroP(x) and !bignumZeroP(y) and bignumPositiveP(x) and bignumPositiveP(y));
    if (bignumLength(x) < bignumLength(y)) {
        std.mem.swap(obj.SchemeObject, &x, &y);
    }
    const x_len: usize = @intCast(bignumLength(x));
    const y_len: usize = @intCast(bignumLength(y));
    const x_ptr = bignumStartPtr(x);
    const y_ptr = bignumStartPtr(y);
    return digitsHammingDistance(x_ptr, y_ptr, y_len) + digitsBitCount(x_ptr + y_len, x_len - y_len);
}

fn bignumNegativeHammingDistance(x_in: obj.SchemeObject, y_in: obj.SchemeObject) c_ulong {
    const x = bignum_bitwise_not(x_in);
    const y = bignum_bitwise_not(y_in);
    if (bignumZeroP(x)) return bignumBitCountUnsigned(y);
    if (bignumZeroP(y)) return bignumBitCountUnsigned(x);
    return bignumPositiveHammingDistance(x, y);
}

pub export fn bignum_bit_count(x: obj.SchemeObject) callconv(.c) c_ulong {
    if (bignumZeroP(x)) return 0;
    if (bignumNegativeP(x)) return bignumBitCountUnsigned(bignum_bitwise_not(x));
    return bignumBitCountUnsigned(x);
}

pub export fn bignum_hamming_distance(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) c_long {
    if (x == y) return 0;
    if (bignumZeroP(x)) return if (bignumNegativeP(y)) -1 else @intCast(bignumBitCountUnsigned(y));
    if (bignumZeroP(y)) return if (bignumNegativeP(x)) -1 else @intCast(bignumBitCountUnsigned(x));
    if (bignumPositiveP(x)) {
        return if (bignumPositiveP(y)) @intCast(bignumPositiveHammingDistance(x, y)) else -1;
    } else {
        return if (bignumPositiveP(y)) -1 else @intCast(bignumNegativeHammingDistance(x, y));
    }
}

pub export fn bignum_nonnegative_one_bits(size: c_ulong, position: c_ulong) callconv(.c) obj.SchemeObject {
    return bignum_shift_left(bignum_bitwise_not(bignum_shift_left(bignum_make_one(1), size)), position);
}

pub export fn bignum_negative_zero_bits(n: c_ulong, m: c_ulong) callconv(.c) obj.SchemeObject {
    return bignum_bitwise_not(bignum_nonnegative_one_bits(n, m));
}

fn bignumShiftRightUnsigned(n: obj.SchemeObject, digits_arg: c_ulong, shift_bits: c_ulong) obj.SchemeObject {
    const n_len_raw = bignumLength(n);
    if (digits_arg >= @as(c_ulong, @intCast(n_len_raw))) return bignum_make_zero();
    const digits: usize = @intCast(digits_arg);
    const n_len: usize = @intCast(n_len_raw);
    const n_ptr = bignumStartPtr(n);
    const sh: std.math.Log2Int(UnsignedDigit) = @intCast(shift_bits);

    const drop_msd: usize = if (n_len > 0 and (n_ptr[n_len - 1] >> sh) == 0) 1 else 0;
    const r_len = n_len - digits - drop_msd;
    const r = bignumAllocate(@intCast(r_len), false);
    const r_ptr = bignumStartPtr(r);

    if (shift_bits == 0) {
        @memcpy(r_ptr[0..r_len], n_ptr[digits..n_len]);
    } else {
        const mask = digitOnes(@intCast(shift_bits));
        const comp_sh: std.math.Log2Int(UnsignedDigit) = @intCast(bignum_digit_length - @as(usize, @intCast(shift_bits)));
        var extra = n_ptr[digits] >> sh;
        var out_idx: usize = 0;
        var in_idx: usize = digits + 1;
        while (in_idx < n_len) : (in_idx += 1) {
            const digit = n_ptr[in_idx];
            r_ptr[out_idx] = ((digit & mask) << comp_sh) | extra;
            out_idx += 1;
            extra = digit >> sh;
        }
        if (extra != 0) {
            r_ptr[out_idx] = extra;
            out_idx += 1;
        }
        bignumAssert(out_idx == r_len);
    }
    return r;
}

pub export fn bignum_shift_right(n: obj.SchemeObject, m: c_ulong) callconv(.c) obj.SchemeObject {
    const digits = m / bignum_digit_length;
    const shift_bits = m % bignum_digit_length;
    if (digits >= @as(c_ulong, @intCast(bignumLength(n)))) {
        return if (bignumNegativeP(n)) bignum_make_one(1) else bignum_make_zero();
    }
    if (bignumNegativeP(n)) {
        return bignum_bitwise_not(bignumShiftRightUnsigned(bignum_bitwise_not(n), digits, shift_bits));
    }
    return bignumShiftRightUnsigned(n, digits, shift_bits);
}

pub export fn bignum_shift_left(n: obj.SchemeObject, m: c_ulong) callconv(.c) obj.SchemeObject {
    if (m == 0 or bignumZeroP(n)) return n;
    const ln: usize = @intCast(bignumLength(n));
    const delta: c_ulong = bits.ulongLengthInBits(bignumRef(n, ln - 1));
    const total = delta + m;
    const zeroes: usize = @intCast(m / bignum_digit_length);
    const shift: usize = @intCast(m % bignum_digit_length);
    const ln2: usize = (ln - 1) + @as(usize, @intCast(total / bignum_digit_length)) + @intFromBool((total % bignum_digit_length) != 0);

    const result = bignumAllocate(@intCast(ln2), bignumNegativeP(n));
    const src_ptr = bignumStartPtr(n);
    const dst_ptr = bignumStartPtr(result);
    @memset(dst_ptr[0..zeroes], 0);
    if (shift == 0) {
        @memcpy(dst_ptr[zeroes .. zeroes + ln], src_ptr[0..ln]);
    } else {
        const lsh: std.math.Log2Int(UnsignedDigit) = @intCast(shift);
        const rsh: std.math.Log2Int(UnsignedDigit) = @intCast(bignum_digit_length - shift);
        var temp: UnsignedDigit = 0;
        for (0..ln) |i| {
            const digit = src_ptr[i];
            dst_ptr[zeroes + i] = ((digit << lsh) & bignum_digit_mask) | temp;
            temp = digit >> rsh;
        }
        if (temp != 0) dst_ptr[zeroes + ln] = temp;
    }
    return result;
}

pub export fn unsigned_long_to_shifted_bignum(n_in: c_ulong, m: c_ulong, sign: c_int) callconv(.c) obj.SchemeObject {
    if (n_in == 0) return bignum_make_zero();
    var n = n_in;
    const delta: c_ulong = bits.ulongLengthInBits(n);
    const total = delta + m;
    const zeroes: usize = @intCast(m / bignum_digit_length);
    const shift: usize = @intCast(m % bignum_digit_length);
    const ln: usize = @intCast((total / bignum_digit_length) + @intFromBool((total % bignum_digit_length) != 0));

    const result = bignumAllocate(@intCast(ln), sign != 0);
    const dst_ptr = bignumStartPtr(result);
    @memset(dst_ptr[0..zeroes], 0);
    var pos = zeroes;
    dst_ptr[pos] = (n << @intCast(shift)) & bignum_digit_mask;
    pos += 1;
    n >>= @intCast(bignum_digit_length - shift);
    while (n > 0) {
        dst_ptr[pos] = n & bignum_digit_mask;
        pos += 1;
        n >>= digit_shift;
    }
    return result;
}

pub export fn digit_stream_to_bignum(
    n_digits_in: c_uint,
    producer: *const fn (?*anyopaque) callconv(.c) c_uint,
    context: ?*anyopaque,
    radix: c_uint,
    negative_p: c_int,
) callconv(.c) obj.SchemeObject {
    bignumAssert(@as(c_ulong, radix) > 1 and @as(c_ulong, radix) <= bignum_radix_root);
    if (n_digits_in == 0) return bignum_make_zero();
    if (n_digits_in == 1) {
        const digit: c_long = @intCast(producer(context));
        return long_to_bignum(if (negative_p != 0) -digit else digit);
    }
    const total_bits: usize = @as(usize, n_digits_in) * @as(usize, bits.ulongLengthInBits(radix));
    const length: BignumLength = @intCast(bitsToDigits(total_bits));
    const result = bignumAllocateZeroed(length, negative_p != 0);
    var rem = n_digits_in;
    while (rem > 0) : (rem -= 1) {
        bignumDestructiveScaleUp(result, @intCast(radix));
        bignumDestructiveAdd(result, @intCast(producer(context)));
    }
    return bignumTrim(result);
}

pub export fn bignum_to_digit_stream(
    bignum: obj.SchemeObject,
    radix: c_uint,
    consumer: *const fn (?*anyopaque, c_long) callconv(.c) void,
    context: ?*anyopaque,
) callconv(.c) void {
    bignumAssert(@as(c_ulong, radix) > 1 and @as(c_ulong, radix) <= bignum_radix_root);
    if (bignumZeroP(bignum)) return;
    const working_copy = bignumCopy(bignum);
    const start = bignumStartPtr(working_copy);
    var scan: usize = @intCast(bignumLength(working_copy));
    while (scan > 0) {
        if (start[scan - 1] == 0) {
            scan -= 1;
        } else {
            consumer(context, @intCast(bignumDestructiveScaleDown(working_copy, @intCast(radix))));
        }
    }
}

pub export fn bignum_max_digit_stream_radix() callconv(.c) c_long {
    return @intCast(bignum_radix_root);
}

test "bignum arithmetic, division, conversions, floats, and bitwise operations" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // Small constants and signed/unsigned edge cases
    const zero = bignum_make_zero();
    const one = bignum_make_one(0);
    const neg_one = bignum_make_one(1);
    try std.testing.expectEqual(@as(c_int, 0), bignum_test(zero));
    try std.testing.expectEqual(@as(c_int, 2), bignum_test(one));
    try std.testing.expectEqual(@as(c_int, 1), bignum_test(neg_one));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(one, bignum_negate(neg_one)));

    const min_l = std.math.minInt(c_long);
    const max_ul = std.math.maxInt(c_ulong);
    const b_min_l = long_to_bignum(min_l);
    const b_max_ul = ulong_to_bignum(max_ul);
    try std.testing.expectEqual(min_l, bignum_to_long(b_min_l));
    try std.testing.expectEqual(max_ul, bignum_to_ulong(b_max_ul));
    try std.testing.expectEqual(@as(c_int, 1), bignum_fits_in_word_p(b_min_l, @bitSizeOf(c_long), 1));
    try std.testing.expectEqual(@as(c_int, 0), bignum_fits_in_word_p(bignum_subtract(b_min_l, one), @bitSizeOf(c_long), 1));
    try std.testing.expectEqual(@as(c_int, 1), bignum_fits_in_word_p(b_max_ul, @bitSizeOf(c_ulong), 0));

    // Multi-digit arithmetic + small/medium/Knuth D division
    const a = bignum_shift_left(b_max_ul, 70);
    const b = bignum_add(a, bignum_shift_left(long_to_bignum(123456789), 15));
    const prod = bignum_multiply(b, b);

    // Small divisor (< bignum_radix_root)
    var q: obj.SchemeObject = undefined;
    var r: obj.SchemeObject = undefined;
    try std.testing.expectEqual(@as(c_int, 0), bignum_divide(prod, long_to_bignum(97), &q, &r));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(prod, bignum_add(bignum_multiply(q, long_to_bignum(97)), r)));

    // Medium divisor (bignum_radix_root <= d < bignum_radix)
    const med_d = ulong_to_bignum((@as(c_ulong, 1) << 40) + 1337);
    try std.testing.expectEqual(@as(c_int, 0), bignum_divide(prod, med_d, &q, &r));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(prod, bignum_add(bignum_multiply(q, med_d), r)));

    // Large divisor (Knuth D, length >= 2, negative numerator)
    const neg_prod = bignum_negate(prod);
    const large_d = bignum_add(bignum_shift_left(one, 90), long_to_bignum(987654321));
    try std.testing.expectEqual(@as(c_int, 0), bignum_divide(neg_prod, large_d, &q, &r));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(neg_prod, bignum_add(bignum_multiply(q, large_d), r)));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(q, bignum_quotient(neg_prod, large_d)));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(r, bignum_remainder(neg_prod, large_d)));

    // Float <-> bignum roundtrips & 53-bit msd rounding tie
    const d1e18 = double_to_bignum(1.0e18);
    try std.testing.expectEqual(@as(f64, 1.0e18), bignum_to_double(d1e18));
    try std.testing.expectEqual(@as(f64, -1.0e40), bignum_to_double(double_to_bignum(-1.0e40)));
    const p114 = bignum_shift_left(one, 114);
    const tie_even = bignum_add(p114, bignum_shift_left(one, 61));
    const above_tie = bignum_add(tie_even, one);
    try std.testing.expectEqual(std.math.ldexp(@as(f64, 1.0), 114), bignum_to_double(tie_even));
    try std.testing.expectEqual(std.math.ldexp(@as(f64, 1.0), 114) + std.math.ldexp(@as(f64, 1.0), 62), bignum_to_double(above_tie));

    // Bitwise, shifts, bit lengths & counts
    const p62 = bignum_shift_left(one, 62);
    const neg_p62 = bignum_negate(p62);
    try std.testing.expectEqual(@as(c_ulong, 63), bignum_length_in_bits(neg_p62));
    try std.testing.expectEqual(@as(c_ulong, 62), bignum_integer_length(neg_p62));
    try std.testing.expectEqual(@as(c_ulong, 63), bignum_integer_length(bignum_subtract(neg_p62, one)));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(neg_one, bignum_shift_right(neg_p62, 62)));
    try std.testing.expectEqual(@as(c_int, 1), bignum_equal_p(neg_one, bignum_shift_right(neg_p62, 63)));
    try std.testing.expectEqual(@as(c_long, 62), bignum_first_set_bit(neg_p62));
    try std.testing.expectEqual(@as(c_ulong, 62), bignum_bit_count(neg_p62));
    try std.testing.expectEqual(@as(c_long, -1), bignum_hamming_distance(p62, neg_p62));
    try std.testing.expectEqual(@as(c_long, 62), bignum_hamming_distance(neg_p62, neg_one));

    // Digit stream roundtrip
    const Ctx = struct {
        digits: [4]c_uint = .{ 1, 2, 3, 4 },
        idx: usize = 0,
        out: [16]c_long = undefined,
        out_len: usize = 0,
    };
    var ctx = Ctx{};
    const prod_fn = struct {
        fn next(p: ?*anyopaque) callconv(.c) c_uint {
            const c: *Ctx = @ptrCast(@alignCast(p.?));
            const d = c.digits[c.idx];
            c.idx += 1;
            return d;
        }
    }.next;
    const cons_fn = struct {
        fn emit(p: ?*anyopaque, d: c_long) callconv(.c) void {
            const c: *Ctx = @ptrCast(@alignCast(p.?));
            c.out[c.out_len] = d;
            c.out_len += 1;
        }
    }.emit;
    const from_stream = digit_stream_to_bignum(4, &prod_fn, &ctx, 10, 0);
    try std.testing.expectEqual(@as(c_long, 1234), bignum_to_long(from_stream));
    bignum_to_digit_stream(from_stream, 10, &cons_fn, &ctx);
    try std.testing.expectEqualSlices(c_long, &.{ 4, 3, 2, 1 }, ctx.out[0..ctx.out_len]);
}
