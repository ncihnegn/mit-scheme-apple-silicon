// Derived from MIT/GNU Scheme C sources:
// Copyright (c) 2015 Taylor R. Campbell.
// See src/microcode/keccak.h and src/microcode/keccak.c for full license text.

const std = @import("std");

inline fn theta(a: *[25]u64) void {
    var c: [5]u64 = @splat(0);
    for (0..5) |y| {
        for (0..5) |x| {
            c[x] ^= a[x + 5 * y];
        }
    }
    for (0..5) |y| {
        a[0 + 5 * y] ^= c[4] ^ std.math.rotl(u64, c[1], 1);
        a[1 + 5 * y] ^= c[0] ^ std.math.rotl(u64, c[2], 1);
        a[2 + 5 * y] ^= c[1] ^ std.math.rotl(u64, c[3], 1);
        a[3 + 5 * y] ^= c[2] ^ std.math.rotl(u64, c[4], 1);
        a[4 + 5 * y] ^= c[3] ^ std.math.rotl(u64, c[0], 1);
    }
}

const rho_pi_steps = [_]struct { idx: usize, rot: u6 }{
    .{ .idx = 10, .rot = 1 },
    .{ .idx = 7, .rot = 3 },
    .{ .idx = 11, .rot = 6 },
    .{ .idx = 17, .rot = 10 },
    .{ .idx = 18, .rot = 15 },
    .{ .idx = 3, .rot = 21 },
    .{ .idx = 5, .rot = 28 },
    .{ .idx = 16, .rot = 36 },
    .{ .idx = 8, .rot = 45 },
    .{ .idx = 21, .rot = 55 },
    .{ .idx = 24, .rot = 2 },
    .{ .idx = 4, .rot = 14 },
    .{ .idx = 15, .rot = 27 },
    .{ .idx = 23, .rot = 41 },
    .{ .idx = 19, .rot = 56 },
    .{ .idx = 13, .rot = 8 },
    .{ .idx = 12, .rot = 25 },
    .{ .idx = 2, .rot = 43 },
    .{ .idx = 20, .rot = 62 },
    .{ .idx = 14, .rot = 18 },
    .{ .idx = 22, .rot = 39 },
    .{ .idx = 9, .rot = 61 },
    .{ .idx = 6, .rot = 20 },
    .{ .idx = 1, .rot = 44 },
};

inline fn rhoPi(a: *[25]u64) void {
    // Permute by (x,y) |---> (y, 2x + 3y mod 5) starting at (1,0),
    // rotate the ith element by (i + 1)(i + 2)/2 mod 64.
    var t: u64 = a[1];
    inline for (rho_pi_steps) |step| {
        const u = a[step.idx];
        a[step.idx] = std.math.rotl(u64, t, step.rot);
        t = u;
    }
}

inline fn chi(a: *[25]u64) void {
    for (0..5) |y| {
        const b0 = a[0 + 5 * y];
        const b1 = a[1 + 5 * y];
        const b2 = a[2 + 5 * y];
        const b3 = a[3 + 5 * y];
        const b4 = a[4 + 5 * y];
        a[0 + 5 * y] ^= ~b1 & b2;
        a[1 + 5 * y] ^= ~b2 & b3;
        a[2 + 5 * y] ^= ~b3 & b4;
        a[3 + 5 * y] ^= ~b4 & b0;
        a[4 + 5 * y] ^= ~b0 & b1;
    }
}

fn round(a: *[25]u64) void {
    theta(a);
    rhoPi(a);
    chi(a);
}

pub export fn keccakf1600(a: *[25]u64) callconv(.c) void {
    // RC[i] = \sum_{j = 0,...,6} rc(j + 7i) 2^(2^j - 1),
    // rc(t) = (x^t mod x^8 + x^6 + x^5 + x^4 + 1) mod x in GF(2)[x]
    const rc = [24]u64{
        0x0000000000000001,
        0x0000000000008082,
        0x800000000000808a,
        0x8000000080008000,
        0x000000000000808b,
        0x0000000080000001,
        0x8000000080008081,
        0x8000000000008009,
        0x000000000000008a,
        0x0000000000000088,
        0x0000000080008009,
        0x000000008000000a,
        0x000000008000808b,
        0x800000000000008b,
        0x8000000000008089,
        0x8000000000008003,
        0x8000000000008002,
        0x8000000000000080,
        0x000000000000800a,
        0x800000008000000a,
        0x8000000080008081,
        0x8000000000008080,
        0x0000000080000001,
        0x8000000080008008,
    };

    for (rc) |round_const| {
        round(a);
        a[0] ^= round_const;
    }
}

test "keccakf1600 sha3-256 empty vector" {
    var buf: [200]u8 = @splat(0);
    buf[0] = 0x06;
    buf[0x87] = 0x80;

    var state: [25]u64 = undefined;
    for (0..25) |i| {
        state[i] = std.mem.readInt(u64, buf[8 * i ..][0..8], .little);
    }

    keccakf1600(&state);

    for (0..25) |i| {
        std.mem.writeInt(u64, buf[8 * i ..][0..8], state[i], .little);
    }

    const expected = [_]u8{
        0xa7, 0xff, 0xc6, 0xf8, 0xbf, 0x1e, 0xd7, 0x66,
        0x51, 0xc1, 0x47, 0x56, 0xa0, 0x61, 0xd6, 0x62,
        0xf5, 0x80, 0xff, 0x4d, 0xe4, 0x3b, 0x49, 0xfa,
        0x82, 0xd8, 0x0a, 0x4b, 0x80, 0xf8, 0x43, 0x4a,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf[0..32]);
}
