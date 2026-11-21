// Derived from MIT/GNU Scheme C sources (`src/microcode/prkeccak.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const keccak = @import("keccak.zig");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

// DEFINE_PRIMITIVE ("BYTEVECTOR-KECCAK-F1600", Prim_bytevector_keccak_f1600, 1, 1,
//   "(STATE)\n\
// Perform the Keccak-f[1600] permutation on a byte vector.")
pub export fn Prim_bytevector_keccak_f1600() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var n: c_ulong = 0;
    const state_ptr = abi.arg_bytevector(1, &n);
    if (n != 200) abi.error_bad_range_arg(1);

    const state = state_ptr[0..200];
    var lanes: [25]u64 = undefined;
    for (0..25) |i| {
        lanes[i] = std.mem.readInt(u64, state[8 * i ..][0..8], .little);
    }
    keccak.keccakf1600(&lanes);
    for (0..25) |i| {
        std.mem.writeInt(u64, state[8 * i ..][0..8], lanes[i], .little);
    }
    return obj.unspecific;
}

test "prkeccak permutes sha3-256 empty block" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const bv = abi.allocate_bytevector(200);
    const data = obj.bytevectorData(bv);
    @memset(data[0..200], 0);
    data[0] = 0x06;
    data[0x87] = 0x80;

    stubs.setArgs(&.{bv});
    try std.testing.expectEqual(obj.unspecific, Prim_bytevector_keccak_f1600());

    const expected = [_]u8{
        0xa7, 0xff, 0xc6, 0xf8, 0xbf, 0x1e, 0xd7, 0x66,
        0x51, 0xc1, 0x47, 0x56, 0xa0, 0x61, 0xd6, 0x62,
        0xf5, 0x80, 0xff, 0x4d, 0xe4, 0x3b, 0x49, 0xfa,
        0x82, 0xd8, 0x0a, 0x4b, 0x80, 0xf8, 0x43, 0x4a,
    };
    try std.testing.expectEqualSlices(u8, &expected, data[0..32]);
}
