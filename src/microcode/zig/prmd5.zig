// Derived from MIT/GNU Scheme C sources (`src/microcode/prmd5.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const md5 = @import("md5.zig");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

var md5_selftested: bool = false;

fn doMd5Selftest() void {
    if (md5_selftested) return;
    if (md5.md5_selftest() != 0) abi.error_external_return();
    md5_selftested = true;
}

fn md5ContextArg(arg: c_int) *md5.Md5 {
    abi.checkArg(arg, obj.bytevectorP);
    const bv = abi.argRef(@intCast(arg));
    if (obj.bytevectorLength(bv) != @sizeOf(md5.Md5)) {
        abi.error_bad_range_arg(arg);
    }
    doMd5Selftest();
    return @ptrCast(@alignCast(obj.bytevectorData(bv)));
}

// DEFINE_PRIMITIVE ("MD5", Prim_md5, 1, 1,
//   "(BYTEVECTOR)\n\
// Generate an MD5 digest of bytevector.\n\
// The digest is returned as a 16-byte bytevector.")
pub export fn Prim_md5() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bytevectorP);
    doMd5Selftest();

    const bv = abi.argRef(1);
    const result = abi.allocate_bytevector(md5.hash_len);
    var context: md5.Md5 = undefined;
    md5.md5_init(&context);
    md5.md5_update(&context, obj.bytevectorData(bv), @intCast(obj.bytevectorLength(bv)));
    md5.md5_final(&context, @ptrCast(obj.bytevectorData(result)));
    return result;
}

// DEFINE_PRIMITIVE ("MD5-INIT", Prim_md5_init, 0, 0,
//   "()\n\
// Create and return an MD5 digest context.")
pub export fn Prim_md5_init() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    doMd5Selftest();
    const context = abi.allocate_bytevector(@sizeOf(md5.Md5));
    md5.md5_init(@ptrCast(@alignCast(obj.bytevectorData(context))));
    return context;
}

// DEFINE_PRIMITIVE ("MD5-UPDATE", Prim_md5_update, 4, 4,
//   "(CONTEXT BYTEVECTOR START END)\n\
// Update CONTEXT with the contents of the subbytevector (BYTEVECTOR,START,END).")
pub export fn Prim_md5_update() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.bytevectorP);

    const bv = abi.argRef(2);
    const end = abi.arg_ulong_index_integer(4, obj.bytevectorLength(bv) + 1);
    const start = abi.arg_ulong_index_integer(3, end + 1);
    md5.md5_update(
        md5ContextArg(1),
        obj.bytevectorLoc(bv, @intCast(start)),
        @intCast(end - start),
    );
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("MD5-FINAL", Prim_md5_final, 1, 1,
//   "(CONTEXT)\n\
// Finalize CONTEXT and return the digest as a 16-byte bytevector.")
pub export fn Prim_md5_final() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const context = md5ContextArg(1);
    const result = abi.allocate_bytevector(md5.hash_len);
    md5.md5_final(context, @ptrCast(obj.bytevectorData(result)));
    return result;
}

test "prmd5 oneshot and streaming primitives match RFC1321" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const expected_abc = [_]u8{
        0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0,
        0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72,
    };

    const msg = stubs.memory_to_bytevector(5, "xabcy");
    const abc = stubs.memory_to_bytevector(3, "abc");

    // One-shot MD5
    stubs.setArgs(&.{abc});
    const digest1 = Prim_md5();
    try std.testing.expectEqual(@as(c_ulong, 16), obj.bytevectorLength(digest1));
    try std.testing.expectEqualSlices(u8, &expected_abc, obj.bytevectorData(digest1)[0..16]);

    // Streaming MD5-INIT -> MD5-UPDATE -> MD5-FINAL
    stubs.setArgs(&.{});
    const ctx = Prim_md5_init();
    stubs.setArgs(&.{ ctx, msg, obj.ulongToFixnum(1), obj.ulongToFixnum(4) });
    try std.testing.expectEqual(obj.unspecific, Prim_md5_update());
    stubs.setArgs(&.{ctx});
    const digest2 = Prim_md5_final();
    try std.testing.expectEqualSlices(u8, &expected_abc, obj.bytevectorData(digest2)[0..16]);
}
