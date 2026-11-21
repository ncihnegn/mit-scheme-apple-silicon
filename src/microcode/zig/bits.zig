// Derived from MIT/GNU Scheme C sources (`src/microcode/bits.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

pub inline fn ulongBitCount(x: c_ulong) c_uint {
    return @popCount(x);
}

pub inline fn uintmaxBitCount(x: u64) c_uint {
    return @popCount(x);
}

pub inline fn ulongLengthInBits(x: c_ulong) c_uint {
    return if (x == 0) 0 else @as(c_uint, @bitSizeOf(c_ulong)) - @clz(x);
}

pub inline fn uintmaxLengthInBits(x: u64) c_uint {
    return if (x == 0) 0 else 64 - @clz(x);
}

pub inline fn ulongFirstSetBit(x: c_ulong) c_int {
    return if (x == 0) -1 else @intCast(@ctz(x));
}

pub inline fn uintmaxFirstSetBit(x: u64) c_int {
    return if (x == 0) -1 else @intCast(@ctz(x));
}

test "bits helpers handle zero, powers of two, high bit, and all ones" {
    const all_ones: c_ulong = ~@as(c_ulong, 0);
    const word_bits: c_uint = @bitSizeOf(c_ulong);

    try std.testing.expectEqual(@as(c_uint, 0), ulongBitCount(0));
    try std.testing.expectEqual(@as(c_uint, 1), ulongBitCount(1));
    try std.testing.expectEqual(word_bits, ulongBitCount(all_ones));

    try std.testing.expectEqual(@as(c_uint, 0), ulongLengthInBits(0));
    try std.testing.expectEqual(@as(c_uint, 1), ulongLengthInBits(1));
    try std.testing.expectEqual(@as(c_uint, 8), ulongLengthInBits(0x80));
    try std.testing.expectEqual(word_bits, ulongLengthInBits(all_ones));

    try std.testing.expectEqual(@as(c_int, -1), ulongFirstSetBit(0));
    try std.testing.expectEqual(@as(c_int, 0), ulongFirstSetBit(1));
    try std.testing.expectEqual(@as(c_int, 5), ulongFirstSetBit(0x60));
    try std.testing.expectEqual(@as(c_int, @intCast(word_bits - 1)), ulongFirstSetBit(@as(c_ulong, 1) << @intCast(word_bits - 1)));

    try std.testing.expectEqual(@as(c_uint, 64), uintmaxBitCount(~@as(u64, 0)));
    try std.testing.expectEqual(@as(c_uint, 64), uintmaxLengthInBits(~@as(u64, 0)));
    try std.testing.expectEqual(@as(c_int, -1), uintmaxFirstSetBit(0));
}
