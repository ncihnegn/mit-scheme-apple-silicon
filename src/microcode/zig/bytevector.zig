// Derived from MIT/GNU Scheme C sources (`src/microcode/bytevector.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

pub export fn arg_bytevector(n: c_int, len_r: *usize) callconv(.c) [*]u8 {
    abi.checkArg(n, obj.bytevectorP);
    const bv = abi.argRef(@intCast(n));
    len_r.* = obj.bytevectorLength(bv);
    return obj.bytevectorData(bv);
}

fn argByte(n: c_int) u8 {
    abi.checkArg(n, obj.fixnumP);
    const argument = abi.argRef(@intCast(n));
    if (!obj.fixnumToUlongP(argument)) abi.error_bad_range_arg(n);
    const value = obj.fixnumToUlong(argument);
    if (value >= 0x100) abi.error_bad_range_arg(n);
    return @intCast(value);
}

pub export fn allocate_bytevector(nbytes: usize) callconv(.c) obj.SchemeObject {
    const result = abi.allocate_non_marked_vector(
        @intCast(obj.tc_bytevector),
        obj.bytevectorLengthToGcLength(nbytes),
        true,
    );
    obj.setBytevectorLength(result, nbytes);
    obj.bytevectorSet(result, @intCast(nbytes), 0x00);
    return result;
}

pub export fn memory_to_bytevector(n_bytes: usize, vp: ?*const anyopaque) callconv(.c) obj.SchemeObject {
    const result = allocate_bytevector(n_bytes);
    if (n_bytes > 0) {
        const src: [*]const u8 = @ptrCast(vp.?);
        @memcpy(obj.bytevectorData(result)[0..@intCast(n_bytes)], src[0..@intCast(n_bytes)]);
    }
    return result;
}

// DEFINE_PRIMITIVE ("allocate-bytevector", Prim_allocate_bytevector, 1, 1, 0)
pub export fn Prim_allocate_bytevector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return allocate_bytevector(abi.arg_ulong_integer(1));
}

// DEFINE_PRIMITIVE ("bytevector?", Prim_bytevector_p, 1, 1, 0)
pub export fn Prim_bytevector_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.bytevectorP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("bytevector-length", Prim_bytevector_length, 1, 1, 0)
pub export fn Prim_bytevector_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bytevectorP);
    return abi.ulong_to_integer(obj.bytevectorLength(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("bytevector-u8-ref", Prim_bytevector_u8_ref, 2, 2, 0)
pub export fn Prim_bytevector_u8_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var length: usize = 0;
    const v = arg_bytevector(1, &length);
    const index: usize = @intCast(abi.arg_ulong_index_integer(2, length));
    return abi.ulong_to_integer(v[index]);
}

// DEFINE_PRIMITIVE ("bytevector-u8-set!", Prim_bytevector_u8_set, 3, 3, 0)
pub export fn Prim_bytevector_u8_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var length: usize = 0;
    const v = arg_bytevector(1, &length);
    const index: usize = @intCast(abi.arg_ulong_index_integer(2, length));
    v[index] = argByte(3);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("bytevector-fill!", Prim_bytevector_fill, 4, 4, 0)
pub export fn Prim_bytevector_fill() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var length: usize = 0;
    const v = arg_bytevector(1, &length);
    const value = argByte(2);
    const end: usize = @intCast(abi.arg_ulong_index_integer(4, length + 1));
    const start: usize = @intCast(abi.arg_ulong_index_integer(3, @as(usize, @intCast(end)) + 1));
    @memset(v[start..end], value);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("bytevector-copy", Prim_bytevector_copy, 3, 3, 0)
pub export fn Prim_bytevector_copy() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var length: usize = 0;
    const v = arg_bytevector(1, &length);
    const end: usize = @intCast(abi.arg_ulong_index_integer(3, length + 1));
    const start: usize = @intCast(abi.arg_ulong_index_integer(2, @as(usize, @intCast(end)) + 1));
    return memory_to_bytevector(@intCast(end - start), v + start);
}

// DEFINE_PRIMITIVE ("bytevector-copy!", Prim_bytevector_copyx, 5, 5, 0)
pub export fn Prim_bytevector_copyx() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var to_length: usize = 0;
    const to_v = arg_bytevector(1, &to_length);
    const to_start = abi.arg_ulong_index_integer(2, to_length + 1);
    var from_length: usize = 0;
    const from_v = arg_bytevector(3, &from_length);
    const from_end = abi.arg_ulong_index_integer(5, from_length + 1);
    const from_start = abi.arg_ulong_index_integer(4, from_end + 1);
    const length = from_end - from_start;
    const to_end = to_start + length;
    if (to_end > to_length) abi.error_bad_range_arg(5);
    const to_s: usize = @intCast(to_start);
    const from_s: usize = @intCast(from_start);
    const len_u: usize = @intCast(length);
    @memmove(to_v[to_s..][0..len_u], from_v[from_s..][0..len_u]);
    return abi.ulong_to_integer(to_end);
}

test "bytevector primitives allocate, fill, copy, and memmove overlaps" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{obj.ulongToFixnum(6)});
    const bv = Prim_allocate_bytevector();
    stubs.setArgs(&.{bv});
    try std.testing.expectEqual(obj.sharp_t, Prim_bytevector_p());
    try std.testing.expectEqual(obj.ulongToFixnum(6), Prim_bytevector_length());
    try std.testing.expectEqual(@as(u8, 0), obj.bytevectorRef(bv, 6)); // trailing NUL

    stubs.setArgs(&.{obj.sharp_f});
    try std.testing.expectEqual(obj.sharp_f, Prim_bytevector_p());

    stubs.setArgs(&.{ bv, obj.ulongToFixnum(0x41), obj.ulongToFixnum(0), obj.ulongToFixnum(6) });
    try std.testing.expectEqual(obj.unspecific, Prim_bytevector_fill());

    stubs.setArgs(&.{ bv, obj.ulongToFixnum(2), obj.ulongToFixnum(0x7E) });
    try std.testing.expectEqual(obj.unspecific, Prim_bytevector_u8_set());

    stubs.setArgs(&.{ bv, obj.ulongToFixnum(2) });
    try std.testing.expectEqual(obj.ulongToFixnum(0x7E), Prim_bytevector_u8_ref());

    const src = memory_to_bytevector(6, "abcdef");
    stubs.setArgs(&.{ src, obj.ulongToFixnum(1), obj.ulongToFixnum(4) });
    const slice_copy = Prim_bytevector_copy();
    try std.testing.expectEqual(@as(usize, 3), obj.bytevectorLength(slice_copy));
    try std.testing.expectEqualSlices(u8, "bcd", obj.bytevectorData(slice_copy)[0..3]);

    // Overlapping forward shift: "abcdef" -> "aabcef" via copy!(src, 1, src, 0, 3) => "aabcdf"? Wait: [0..3]="abc" to [1..4] => "aabcdf"?! No, idx 4..5 stay 'e','f' => "aabcef"
    stubs.setArgs(&.{ src, obj.ulongToFixnum(1), src, obj.ulongToFixnum(0), obj.ulongToFixnum(3) });
    try std.testing.expectEqual(obj.ulongToFixnum(4), Prim_bytevector_copyx());
    try std.testing.expectEqualSlices(u8, "aabcef", obj.bytevectorData(src)[0..6]);

    // Overlapping backward shift: copy!(src, 0, src, 2, 6) => "bcefef"
    stubs.setArgs(&.{ src, obj.ulongToFixnum(0), src, obj.ulongToFixnum(2), obj.ulongToFixnum(6) });
    try std.testing.expectEqual(obj.ulongToFixnum(4), Prim_bytevector_copyx());
    try std.testing.expectEqualSlices(u8, "bcefef", obj.bytevectorData(src)[0..6]);
}
