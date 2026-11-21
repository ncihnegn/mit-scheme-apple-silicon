// Derived from MIT/GNU Scheme C sources (`src/microcode/prentropy.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

// DEFINE_PRIMITIVE ("GET-ENTROPY", Prim_get_entropy, 1, 1,
//   "(BYTEVECTOR)\n\
// Randomize the 32-byte vector BYTEVECTOR from the system entropy pool.")
pub export fn Prim_get_entropy() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var nbytes: usize = 0;
    const buf = abi.arg_bytevector(1, &nbytes);
    if (nbytes != 32) abi.error_bad_range_arg(1);
    abi.OS_get_entropy(@ptrCast(buf));
    return obj.unspecific;
}

test "prentropy fills 32-byte bytevector" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const bv = abi.allocate_bytevector(32);
    stubs.setArgs(&.{bv});
    try std.testing.expectEqual(obj.unspecific, Prim_get_entropy());
    for (0..32) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 0xA0)), obj.bytevectorRef(bv, i));
    }
}
