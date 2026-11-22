// Derived from MIT/GNU Scheme C sources (`src/blowfish/blowfish-adapter.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
pub const blowfish = @import("blowfish.zig");

comptime {
    _ = blowfish;
}

const BF_ENCRYPT: c_int = 1;
const BF_DECRYPT: c_int = 0;

pub export fn BF_set_key(B: *blowfish.Blowfish, nbytes: c_int, key: [*]const u8) callconv(.c) void {
    blowfish.blowfish_init(B, key, @intCast(nbytes));
}

pub export fn BF_ecb_encrypt(
    in: [*]const u8,
    out: [*]u8,
    B: *blowfish.Blowfish,
    dir: c_int,
) callconv(.c) void {
    switch (dir) {
        BF_ENCRYPT => blowfish.blowfish_encrypt(B, in[0..blowfish.BLOWFISH_BLOCKLEN], out[0..blowfish.BLOWFISH_BLOCKLEN]),
        BF_DECRYPT => blowfish.blowfish_decrypt(B, in[0..blowfish.BLOWFISH_BLOCKLEN], out[0..blowfish.BLOWFISH_BLOCKLEN]),
        else => std.c.abort(),
    }
}

pub export fn BF_cbc_encrypt(
    in: [*]const u8,
    out: [*]u8,
    nbytes: c_long,
    B: *blowfish.Blowfish,
    iv: [*]u8,
    dir: c_int,
) callconv(.c) void {
    const n: usize = @intCast(nbytes);
    switch (dir) {
        BF_ENCRYPT => blowfish.blowfish_encrypt_cbc(B, iv[0..blowfish.BLOWFISH_BLOCKLEN], in, out, n),
        BF_DECRYPT => blowfish.blowfish_decrypt_cbc(B, iv[0..blowfish.BLOWFISH_BLOCKLEN], in, out, n),
        else => std.c.abort(),
    }
}

pub export fn do_BF_cfb64_encrypt(
    in: [*]const u8,
    istart: c_long,
    out: [*]u8,
    ostart: c_long,
    length: c_long,
    schedule: *const blowfish.Blowfish,
    ivec: [*]u8,
    num: c_int,
    dir: c_int,
) callconv(.c) c_int {
    const ioff: usize = @intCast(istart);
    const ooff: usize = @intCast(ostart);
    const len: usize = @intCast(length);
    const off: c_uint = @intCast(num);
    const iv = ivec[0..blowfish.BLOWFISH_BLOCKLEN];
    return switch (dir) {
        BF_ENCRYPT => @intCast(blowfish.blowfish_encrypt_cfb64(schedule, iv, off, in + ioff, out + ooff, len)),
        BF_DECRYPT => @intCast(blowfish.blowfish_decrypt_cfb64(schedule, iv, off, in + ioff, out + ooff, len)),
        else => std.c.abort(),
    };
}

pub export fn do_BF_ofb64_encrypt(
    in: [*]const u8,
    istart: c_long,
    out: [*]u8,
    ostart: c_long,
    length: c_long,
    schedule: *const blowfish.Blowfish,
    ivec: [*]u8,
    num: c_int,
) callconv(.c) c_int {
    const ioff: usize = @intCast(istart);
    const ooff: usize = @intCast(ostart);
    const len: usize = @intCast(length);
    const off: c_uint = @intCast(num);
    return @intCast(blowfish.blowfish_encrypt_ofb64(
        schedule,
        ivec[0..blowfish.BLOWFISH_BLOCKLEN],
        off,
        in + ioff,
        out + ooff,
        len,
    ));
}

test "blowfish adapter ECB, CBC, CFB64, and OFB64 roundtrip" {
    var key: blowfish.Blowfish = undefined;
    const raw_key = "test-secret-key";
    BF_set_key(&key, @intCast(raw_key.len), raw_key.ptr);

    // ECB
    const plain8 = "ABCDEFGH".*;
    var cipher8: [8]u8 = undefined;
    var roundtrip8: [8]u8 = undefined;
    BF_ecb_encrypt(&plain8, &cipher8, &key, BF_ENCRYPT);
    BF_ecb_encrypt(&cipher8, &roundtrip8, &key, BF_DECRYPT);
    try std.testing.expectEqualSlices(u8, &plain8, &roundtrip8);

    // CBC
    const iv_init = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var iv = iv_init;
    const plain16 = "0123456789ABCDEF".*;
    var cipher16: [16]u8 = undefined;
    var roundtrip16: [16]u8 = undefined;
    BF_cbc_encrypt(&plain16, &cipher16, 16, &key, &iv, BF_ENCRYPT);
    iv = iv_init;
    BF_cbc_encrypt(&cipher16, &roundtrip16, 16, &key, &iv, BF_DECRYPT);
    try std.testing.expectEqualSlices(u8, &plain16, &roundtrip16);

    // CFB64 with non-zero istart/ostart and chained num
    var padded_in: [22]u8 = @as([4]u8, @splat(0xAA)) ++ "Hello CFB64 World!".*;
    var padded_out: [24]u8 = @splat(0x55);
    var padded_dec: [24]u8 = @splat(0x00);
    const msg_len: c_long = 18;
    iv = iv_init;
    const n1 = do_BF_cfb64_encrypt(&padded_in, 4, &padded_out, 2, 5, &key, &iv, 0, BF_ENCRYPT);
    const n2 = do_BF_cfb64_encrypt(&padded_in, 9, &padded_out, 7, msg_len - 5, &key, &iv, n1, BF_ENCRYPT);
    try std.testing.expectEqual(@as(c_int, 2), n2);
    iv = iv_init;
    const d1 = do_BF_cfb64_encrypt(&padded_out, 2, &padded_dec, 1, msg_len, &key, &iv, 0, BF_DECRYPT);
    try std.testing.expectEqual(n2, d1);
    try std.testing.expectEqualSlices(u8, padded_in[4 .. 4 + 18], padded_dec[1 .. 1 + 18]);

    // OFB64 with non-zero istart/ostart and chained num
    iv = iv_init;
    const on1 = do_BF_ofb64_encrypt(&padded_in, 4, &padded_out, 3, 7, &key, &iv, 0);
    const on2 = do_BF_ofb64_encrypt(&padded_in, 11, &padded_out, 10, msg_len - 7, &key, &iv, on1);
    try std.testing.expectEqual(@as(c_int, 2), on2);
    iv = iv_init;
    const od = do_BF_ofb64_encrypt(&padded_out, 3, &padded_dec, 0, msg_len, &key, &iv, 0);
    try std.testing.expectEqual(on2, od);
    try std.testing.expectEqualSlices(u8, padded_in[4 .. 4 + 18], padded_dec[0..18]);
}

test {
    _ = blowfish;
}
