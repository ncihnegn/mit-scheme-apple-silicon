// Derived from MIT/GNU Scheme C sources (originally NetBSD Foundation):
// Copyright (c) 2014 The NetBSD Foundation, Inc.
// All rights reserved.
//
// This code is derived from software contributed to The NetBSD Foundation
// by Taylor R. Campbell.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE NETBSD FOUNDATION, INC. AND CONTRIBUTORS
// ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

const std = @import("std");

pub const output_bytes = 64;
pub const input_bytes = 16;
pub const key_bytes = 32;
pub const const_bytes = 16;

const chacha_core_constant32: [const_bytes]u8 = "expand 32-byte k".*;

const chacha8_core_selftest_vector = [output_bytes]u8{
    0x3e, 0x00, 0xef, 0x2f, 0x89, 0x5f, 0x40, 0xd6,
    0x7f, 0x5b, 0xb8, 0xe8, 0x1f, 0x09, 0xa5, 0xa1,
    0x2c, 0x84, 0x0e, 0xc3, 0xce, 0x9a, 0x7f, 0x3b,
    0x18, 0x1b, 0xe1, 0x88, 0xef, 0x71, 0x1a, 0x1e,
    0x98, 0x4c, 0xe1, 0x72, 0xb9, 0x21, 0x6f, 0x41,
    0x9f, 0x44, 0x53, 0x67, 0x45, 0x6d, 0x56, 0x19,
    0x31, 0x4a, 0x42, 0xa3, 0xda, 0x86, 0xb0, 0x01,
    0x38, 0x7b, 0xfd, 0xb8, 0x0e, 0x0c, 0xfe, 0x42,
};

const chacha12_core_selftest_vector = [output_bytes]u8{
    0x9b, 0xf4, 0x9a, 0x6a, 0x07, 0x55, 0xf9, 0x53,
    0x81, 0x1f, 0xce, 0x12, 0x5f, 0x26, 0x83, 0xd5,
    0x04, 0x29, 0xc3, 0xbb, 0x49, 0xe0, 0x74, 0x14,
    0x7e, 0x00, 0x89, 0xa5, 0x2e, 0xae, 0x15, 0x5f,
    0x05, 0x64, 0xf8, 0x79, 0xd2, 0x7a, 0xe3, 0xc0,
    0x2c, 0xe8, 0x28, 0x34, 0xac, 0xfa, 0x8c, 0x79,
    0x3a, 0x62, 0x9f, 0x2c, 0xa0, 0xde, 0x69, 0x19,
    0x61, 0x0b, 0xe8, 0x2f, 0x41, 0x13, 0x26, 0xbe,
};

const chacha20_core_selftest_vector = [output_bytes]u8{
    0x76, 0xb8, 0xe0, 0xad, 0xa0, 0xf1, 0x3d, 0x90,
    0x40, 0x5d, 0x6a, 0xe5, 0x53, 0x86, 0xbd, 0x28,
    0xbd, 0xd2, 0x19, 0xb8, 0xa0, 0x8d, 0xed, 0x1a,
    0xa8, 0x36, 0xef, 0xcc, 0x8b, 0x77, 0x0d, 0xc7,
    0xda, 0x41, 0x59, 0x7c, 0x51, 0x57, 0x48, 0x8d,
    0x77, 0x24, 0xe0, 0x3f, 0xb8, 0xd8, 0x4a, 0x37,
    0x6a, 0x43, 0xb8, 0xf4, 0x15, 0x18, 0xa1, 0x1c,
    0xc3, 0x87, 0xb6, 0x69, 0xb2, 0xee, 0x65, 0x86,
};

inline fn quarterRound(a: *u32, b: *u32, c: *u32, d: *u32) void {
    a.* +%= b.*;
    d.* ^= a.*;
    d.* = std.math.rotl(u32, d.*, 16);

    c.* +%= d.*;
    b.* ^= c.*;
    b.* = std.math.rotl(u32, b.*, 12);

    a.* +%= b.*;
    d.* ^= a.*;
    d.* = std.math.rotl(u32, d.*, 8);

    c.* +%= d.*;
    b.* ^= c.*;
    b.* = std.math.rotl(u32, b.*, 7);
}

fn chachaCore(
    comptime rounds: comptime_int,
    out: *[output_bytes]u8,
    in: *const [input_bytes]u8,
    k: *const [key_bytes]u8,
    c: *const [const_bytes]u8,
) void {
    comptime std.debug.assert(rounds % 2 == 0 and rounds > 0);

    var j: [16]u32 = undefined;
    for (0..4) |idx| {
        j[idx] = std.mem.readInt(u32, c[4 * idx ..][0..4], .little);
    }
    for (0..8) |idx| {
        j[4 + idx] = std.mem.readInt(u32, k[4 * idx ..][0..4], .little);
    }
    for (0..4) |idx| {
        j[12 + idx] = std.mem.readInt(u32, in[4 * idx ..][0..4], .little);
    }

    var x = j;
    for (0..rounds / 2) |_| {
        quarterRound(&x[0], &x[4], &x[8], &x[12]);
        quarterRound(&x[1], &x[5], &x[9], &x[13]);
        quarterRound(&x[2], &x[6], &x[10], &x[14]);
        quarterRound(&x[3], &x[7], &x[11], &x[15]);
        quarterRound(&x[0], &x[5], &x[10], &x[15]);
        quarterRound(&x[1], &x[6], &x[11], &x[12]);
        quarterRound(&x[2], &x[7], &x[8], &x[13]);
        quarterRound(&x[3], &x[4], &x[9], &x[14]);
    }

    for (0..16) |idx| {
        std.mem.writeInt(u32, out[4 * idx ..][0..4], x[idx] +% j[idx], .little);
    }
}

fn chachaSelftest(
    comptime rounds: comptime_int,
    expected: *const [output_bytes]u8,
) c_int {
    const nonce: [input_bytes]u8 = @splat(0);
    const key: [key_bytes]u8 = @splat(0);
    var block: [output_bytes]u8 = undefined;

    chachaCore(rounds, &block, &nonce, &key, &chacha_core_constant32);
    return if (std.mem.eql(u8, &block, expected)) 0 else -1;
}

pub export fn chacha8_core(
    out: *[output_bytes]u8,
    in: *const [input_bytes]u8,
    k: *const [key_bytes]u8,
    c: *const [const_bytes]u8,
) callconv(.c) void {
    chachaCore(8, out, in, k, c);
}

pub export fn chacha12_core(
    out: *[output_bytes]u8,
    in: *const [input_bytes]u8,
    k: *const [key_bytes]u8,
    c: *const [const_bytes]u8,
) callconv(.c) void {
    chachaCore(12, out, in, k, c);
}

pub export fn chacha20_core(
    out: *[output_bytes]u8,
    in: *const [input_bytes]u8,
    k: *const [key_bytes]u8,
    c: *const [const_bytes]u8,
) callconv(.c) void {
    chachaCore(20, out, in, k, c);
}

pub export fn chacha8_core_selftest() callconv(.c) c_int {
    return chachaSelftest(8, &chacha8_core_selftest_vector);
}

pub export fn chacha12_core_selftest() callconv(.c) c_int {
    return chachaSelftest(12, &chacha12_core_selftest_vector);
}

pub export fn chacha20_core_selftest() callconv(.c) c_int {
    return chachaSelftest(20, &chacha20_core_selftest_vector);
}

test "chacha8/12/20 selftests and core vectors" {
    try std.testing.expectEqual(@as(c_int, 0), chacha8_core_selftest());
    try std.testing.expectEqual(@as(c_int, 0), chacha12_core_selftest());
    try std.testing.expectEqual(@as(c_int, 0), chacha20_core_selftest());

    const nonce: [input_bytes]u8 = @splat(0);
    const key: [key_bytes]u8 = @splat(0);
    var out: [output_bytes]u8 = undefined;

    chacha8_core(&out, &nonce, &key, &chacha_core_constant32);
    try std.testing.expectEqualSlices(u8, &chacha8_core_selftest_vector, &out);

    chacha12_core(&out, &nonce, &key, &chacha_core_constant32);
    try std.testing.expectEqualSlices(u8, &chacha12_core_selftest_vector, &out);

    chacha20_core(&out, &nonce, &key, &chacha_core_constant32);
    try std.testing.expectEqualSlices(u8, &chacha20_core_selftest_vector, &out);
}
