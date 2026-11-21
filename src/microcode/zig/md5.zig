// Derived from MIT/GNU Scheme C sources:
// Copyright (c) 2017 Taylor R. Campbell
// All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
// OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
// SUCH DAMAGE.

const std = @import("std");

pub const hash_len = 16;
pub const block_len = 64;

pub const Md5 = extern struct {
    state: [4]u32,
    block: [block_len]u8,
    b: u64,
    i: u8,
};

comptime {
    std.debug.assert(@sizeOf(Md5) == 96);
    std.debug.assert(@offsetOf(Md5, "state") == 0);
    std.debug.assert(@offsetOf(Md5, "block") == 16);
    std.debug.assert(@offsetOf(Md5, "b") == 80);
    std.debug.assert(@offsetOf(Md5, "i") == 88);
}

extern "c" fn memset(s: ?*anyopaque, c: c_int, n: usize) ?*anyopaque;
pub export var md5_explicit_memset_impl: ?*const fn (?*anyopaque, c_int, usize) callconv(.c) ?*anyopaque = &memset;

const RoundKind = enum { f, g, h, i };

const Step = struct {
    kind: RoundKind,
    k: u4,
    shift: u5,
    constant: u32,
};

const md5_steps = [64]Step{
    // Round 1
    .{ .kind = .f, .k = 0, .shift = 7, .constant = 0xd76aa478 },
    .{ .kind = .f, .k = 1, .shift = 12, .constant = 0xe8c7b756 },
    .{ .kind = .f, .k = 2, .shift = 17, .constant = 0x242070db },
    .{ .kind = .f, .k = 3, .shift = 22, .constant = 0xc1bdceee },
    .{ .kind = .f, .k = 4, .shift = 7, .constant = 0xf57c0faf },
    .{ .kind = .f, .k = 5, .shift = 12, .constant = 0x4787c62a },
    .{ .kind = .f, .k = 6, .shift = 17, .constant = 0xa8304613 },
    .{ .kind = .f, .k = 7, .shift = 22, .constant = 0xfd469501 },
    .{ .kind = .f, .k = 8, .shift = 7, .constant = 0x698098d8 },
    .{ .kind = .f, .k = 9, .shift = 12, .constant = 0x8b44f7af },
    .{ .kind = .f, .k = 10, .shift = 17, .constant = 0xffff5bb1 },
    .{ .kind = .f, .k = 11, .shift = 22, .constant = 0x895cd7be },
    .{ .kind = .f, .k = 12, .shift = 7, .constant = 0x6b901122 },
    .{ .kind = .f, .k = 13, .shift = 12, .constant = 0xfd987193 },
    .{ .kind = .f, .k = 14, .shift = 17, .constant = 0xa679438e },
    .{ .kind = .f, .k = 15, .shift = 22, .constant = 0x49b40821 },

    // Round 2
    .{ .kind = .g, .k = 1, .shift = 5, .constant = 0xf61e2562 },
    .{ .kind = .g, .k = 6, .shift = 9, .constant = 0xc040b340 },
    .{ .kind = .g, .k = 11, .shift = 14, .constant = 0x265e5a51 },
    .{ .kind = .g, .k = 0, .shift = 20, .constant = 0xe9b6c7aa },
    .{ .kind = .g, .k = 5, .shift = 5, .constant = 0xd62f105d },
    .{ .kind = .g, .k = 10, .shift = 9, .constant = 0x02441453 },
    .{ .kind = .g, .k = 15, .shift = 14, .constant = 0xd8a1e681 },
    .{ .kind = .g, .k = 4, .shift = 20, .constant = 0xe7d3fbc8 },
    .{ .kind = .g, .k = 9, .shift = 5, .constant = 0x21e1cde6 },
    .{ .kind = .g, .k = 14, .shift = 9, .constant = 0xc33707d6 },
    .{ .kind = .g, .k = 3, .shift = 14, .constant = 0xf4d50d87 },
    .{ .kind = .g, .k = 8, .shift = 20, .constant = 0x455a14ed },
    .{ .kind = .g, .k = 13, .shift = 5, .constant = 0xa9e3e905 },
    .{ .kind = .g, .k = 2, .shift = 9, .constant = 0xfcefa3f8 },
    .{ .kind = .g, .k = 7, .shift = 14, .constant = 0x676f02d9 },
    .{ .kind = .g, .k = 12, .shift = 20, .constant = 0x8d2a4c8a },

    // Round 3
    .{ .kind = .h, .k = 5, .shift = 4, .constant = 0xfffa3942 },
    .{ .kind = .h, .k = 8, .shift = 11, .constant = 0x8771f681 },
    .{ .kind = .h, .k = 11, .shift = 16, .constant = 0x6d9d6122 },
    .{ .kind = .h, .k = 14, .shift = 23, .constant = 0xfde5380c },
    .{ .kind = .h, .k = 1, .shift = 4, .constant = 0xa4beea44 },
    .{ .kind = .h, .k = 4, .shift = 11, .constant = 0x4bdecfa9 },
    .{ .kind = .h, .k = 7, .shift = 16, .constant = 0xf6bb4b60 },
    .{ .kind = .h, .k = 10, .shift = 23, .constant = 0xbebfbc70 },
    .{ .kind = .h, .k = 13, .shift = 4, .constant = 0x289b7ec6 },
    .{ .kind = .h, .k = 0, .shift = 11, .constant = 0xeaa127fa },
    .{ .kind = .h, .k = 3, .shift = 16, .constant = 0xd4ef3085 },
    .{ .kind = .h, .k = 6, .shift = 23, .constant = 0x04881d05 },
    .{ .kind = .h, .k = 9, .shift = 4, .constant = 0xd9d4d039 },
    .{ .kind = .h, .k = 12, .shift = 11, .constant = 0xe6db99e5 },
    .{ .kind = .h, .k = 15, .shift = 16, .constant = 0x1fa27cf8 },
    .{ .kind = .h, .k = 2, .shift = 23, .constant = 0xc4ac5665 },

    // Round 4
    .{ .kind = .i, .k = 0, .shift = 6, .constant = 0xf4292244 },
    .{ .kind = .i, .k = 7, .shift = 10, .constant = 0x432aff97 },
    .{ .kind = .i, .k = 14, .shift = 15, .constant = 0xab9423a7 },
    .{ .kind = .i, .k = 5, .shift = 21, .constant = 0xfc93a039 },
    .{ .kind = .i, .k = 12, .shift = 6, .constant = 0x655b59c3 },
    .{ .kind = .i, .k = 3, .shift = 10, .constant = 0x8f0ccc92 },
    .{ .kind = .i, .k = 10, .shift = 15, .constant = 0xffeff47d },
    .{ .kind = .i, .k = 1, .shift = 21, .constant = 0x85845dd1 },
    .{ .kind = .i, .k = 8, .shift = 6, .constant = 0x6fa87e4f },
    .{ .kind = .i, .k = 15, .shift = 10, .constant = 0xfe2ce6e0 },
    .{ .kind = .i, .k = 6, .shift = 15, .constant = 0xa3014314 },
    .{ .kind = .i, .k = 13, .shift = 21, .constant = 0x4e0811a1 },
    .{ .kind = .i, .k = 4, .shift = 6, .constant = 0xf7537e82 },
    .{ .kind = .i, .k = 11, .shift = 10, .constant = 0xbd3af235 },
    .{ .kind = .i, .k = 2, .shift = 15, .constant = 0x2ad7d2bb },
    .{ .kind = .i, .k = 9, .shift = 21, .constant = 0xeb86d391 },
};

inline fn roundMix(comptime kind: RoundKind, x: u32, y: u32, z: u32) u32 {
    return switch (kind) {
        .f => (x & y) | (~x & z),
        .g => (x & z) | (y & ~z),
        .h => x ^ y ^ z,
        .i => y ^ (x | ~z),
    };
}

fn md5Compress(s: *[4]u32, block: *const [block_len]u8) void {
    var words: [16]u32 = undefined;
    for (0..16) |k| {
        words[k] = std.mem.readInt(u32, block[4 * k ..][0..4], .little);
    }

    var v = s.*;
    inline for (md5_steps, 0..) |step, idx| {
        const ia = (4 - (idx % 4)) % 4;
        const ib = (ia + 1) % 4;
        const ic = (ia + 2) % 4;
        const id = (ia + 3) % 4;

        const mixed = roundMix(step.kind, v[ib], v[ic], v[id]);
        const sum = v[ia] +% mixed +% words[step.k] +% step.constant;
        v[ia] = v[ib] +% std.math.rotl(u32, sum, step.shift);
    }

    s[0] +%= v[0];
    s[1] +%= v[1];
    s[2] +%= v[2];
    s[3] +%= v[3];
}

const md5_iv = [4]u32{
    0x67452301,
    0xefcdab89,
    0x98badcfe,
    0x10325476,
};

pub export fn md5_init(m: *Md5) callconv(.c) void {
    m.state = md5_iv;
    m.b = 0;
    m.i = 0;
}

pub export fn md5_update(m: *Md5, buf: ?[*]const u8, len: usize) callconv(.c) void {
    std.debug.assert(m.i < block_len);
    std.debug.assert(m.i == @as(u8, @intCast(m.b % block_len)));

    if (len == 0) return;

    var src = (buf orelse unreachable)[0..len];
    const idx: usize = m.i;

    if (src.len < block_len - idx) {
        @memcpy(m.block[idx..][0..src.len], src);
        m.b +%= src.len;
        m.i = @intCast(idx + src.len);
        std.debug.assert(m.i < block_len);
        std.debug.assert(m.i == @as(u8, @intCast(m.b % block_len)));
        return;
    } else if (idx > 0) {
        const fill = block_len - idx;
        @memcpy(m.block[idx..][0..fill], src[0..fill]);
        m.b +%= fill;
        md5Compress(&m.state, &m.block);
        src = src[fill..];
    }

    while (src.len >= block_len) {
        m.b +%= block_len;
        md5Compress(&m.state, src[0..block_len]);
        src = src[block_len..];
    }

    if (src.len > 0) {
        @memcpy(m.block[0..src.len], src);
        m.b +%= src.len;
    }
    m.i = @intCast(src.len);
    std.debug.assert(m.i < block_len);
    std.debug.assert(m.i == @as(u8, @intCast(m.b % block_len)));
}

pub export fn md5_final(m: *Md5, h: *[hash_len]u8) callconv(.c) void {
    std.debug.assert(m.i < block_len);
    std.debug.assert(m.i == @as(u8, @intCast(m.b % block_len)));

    var idx: usize = m.i;

    // Append 1 bit.
    m.block[idx] = 0x80;
    idx += 1;

    // If there's less than 8 bytes left, zero and go to new block.
    if (block_len - 8 < idx) {
        @memset(m.block[idx..block_len], 0);
        md5Compress(&m.state, &m.block);
        idx = 0;
    }

    // Zero up to the last 64 bits.
    if (idx < block_len - 8) {
        @memset(m.block[idx .. block_len - 8], 0);
    }

    // Append length in bits.
    std.mem.writeInt(u64, m.block[block_len - 8 .. block_len], m.b *% 8, .little);

    // Compress one last time.
    md5Compress(&m.state, &m.block);

    // Reveal the complete state.
    for (0..4) |n| {
        std.mem.writeInt(u32, h[4 * n ..][0..4], m.state[n], .little);
    }

    // Zero the full context struct.
    std.crypto.secureZero(u8, std.mem.asBytes(m));
}

pub export fn md5_selftest() callconv(.c) c_int {
    const expected = [hash_len]u8{
        0xbf, 0xd5, 0x08, 0x30, 0xba, 0x3e, 0xbc, 0x1d,
        0xf2, 0x78, 0xc0, 0x26, 0x97, 0x79, 0xa0, 0x3e,
    };
    var s: [256]u8 = undefined;
    for (0..256) |i| {
        s[i] = @intCast(i);
    }

    var m: Md5 = undefined;
    var actual: [hash_len]u8 = undefined;
    md5_init(&m);
    for (0..256) |i| {
        var m0: Md5 = undefined;
        var h: [hash_len]u8 = undefined;
        md5_init(&m0);
        md5_update(&m0, &s, i / 2);
        md5_update(&m0, @as([*]const u8, &s) + (i / 2), i - (i / 2));
        md5_final(&m0, &h);
        md5_update(&m, &h, hash_len);
    }
    md5_final(&m, &actual);

    return if (std.mem.eql(u8, &expected, &actual)) 0 else -1;
}

fn hashSlice(data: []const u8) [hash_len]u8 {
    var ctx: Md5 = undefined;
    var out: [hash_len]u8 = undefined;
    md5_init(&ctx);
    if (data.len > 0) {
        md5_update(&ctx, data.ptr, data.len);
    }
    md5_final(&ctx, &out);
    return out;
}

test "md5_selftest" {
    try std.testing.expectEqual(@as(c_int, 0), md5_selftest());
}

test "md5 rfc1321 vectors and boundary zeroing" {
    const vectors = [_]struct { input: []const u8, digest: [hash_len]u8 }{
        .{
            .input = "",
            .digest = .{
                0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04,
                0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
            },
        },
        .{
            .input = "abc",
            .digest = .{
                0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0,
                0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72,
            },
        },
        .{
            .input = "message digest",
            .digest = .{
                0xf9, 0x6b, 0x69, 0x7d, 0x7c, 0xb7, 0x93, 0x8d,
                0x52, 0x5a, 0x2f, 0x31, 0xaa, 0xf1, 0x61, 0xd0,
            },
        },
        .{
            .input = "abcdefghijklmnopqrstuvwxyz",
            .digest = .{
                0xc3, 0xfc, 0xd3, 0xd7, 0x61, 0x92, 0xe4, 0x00,
                0x7d, 0xfb, 0x49, 0x6c, 0xca, 0x67, 0xe1, 0x3b,
            },
        },
    };

    for (vectors) |v| {
        const digest = hashSlice(v.input);
        try std.testing.expectEqualSlices(u8, &v.digest, &digest);
    }

    // 1-byte streaming, empty/null update, and final context zeroing.
    var ctx: Md5 = undefined;
    var out: [hash_len]u8 = undefined;
    const msg = "abcdefghijklmnopqrstuvwxyz";
    md5_init(&ctx);
    md5_update(&ctx, null, 0);
    for (msg) |byte| {
        const single = [1]u8{byte};
        md5_update(&ctx, &single, 1);
    }
    md5_final(&ctx, &out);
    try std.testing.expectEqualSlices(u8, &vectors[3].digest, &out);
    const zero_ctx: [@sizeOf(Md5)]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zero_ctx, std.mem.asBytes(&ctx));

    // Boundary lengths around 55/56/63/64 bytes matching std.crypto.hash.Md5.
    const sizes = [_]usize{ 55, 56, 63, 64, 65, 119, 120, 128 };
    for (sizes) |sz| {
        var buf: [128]u8 = undefined;
        for (0..sz) |idx| {
            buf[idx] = @truncate(idx *% 17 +% 3);
        }
        var expected: [hash_len]u8 = undefined;
        std.crypto.hash.Md5.hash(buf[0..sz], &expected, .{});
        const actual = hashSlice(buf[0..sz]);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}
