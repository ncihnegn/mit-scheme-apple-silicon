// Derived from MIT/GNU Scheme C sources (`src/microcode/purutl.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const outf = @import("../support/outf.zig");

// DEFINE_PRIMITIVE ("PRIMITIVE-IMPURIFY", Prim_impurify, 1, 1,
//   "(OBJECT)\n\
// Remove OBJECT from pure space, allowing it to be modified.")
pub export fn Prim_impurify() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.argRef(1);
}

// DEFINE_PRIMITIVE ("CONSTANT?", Prim_constant_p, 1, 1,
//   "(OBJECT)\n\
// Returns #T iff OBJECT is in constant space.")
pub export fn Prim_constant_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(object_in_constant_space_p(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("PURE?", Prim_pure_p, 1, 1,
//   "(OBJECT)\n\
// Returns #T iff OBJECT is in constant space and is 'pure'.")
pub export fn Prim_pure_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.sharp_f;
}

pub export fn object_in_constant_space_p(object: obj.SchemeObject) callconv(.c) bool {
    const address = abi.get_object_address(object) orelse return false;
    return abi.addressInConstantP(address);
}

pub export fn copy_to_constant_space(source: [*]const obj.SchemeObject, n_words: usize) callconv(.c) [*]obj.SchemeObject {
    const avail_words: usize = if (@intFromPtr(abi.constant_end) > @intFromPtr(abi.constant_alloc_next))
        @intCast((@intFromPtr(abi.constant_end) - @intFromPtr(abi.constant_alloc_next)) / @sizeOf(obj.SchemeObject))
    else
        0;
    if (n_words > avail_words) {
        outf.fatal("\nInsufficient constant space!\n", .{});
        abi.Microcode_Termination(abi.term_no_space);
    }
    const result = abi.constant_alloc_next;
    const n: usize = @intCast(n_words);
    @memcpy(result[0..n], source[0..n]);
    abi.constant_alloc_next = result + n;
    return result;
}

test "purutl constant space checks, impurify/pure predicates, and copy_to_constant_space" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    const heap_pair = abi.cons(obj.sharp_t, obj.sharp_f);
    try std.testing.expect(!object_in_constant_space_p(heap_pair));
    stubs.setArgs(&.{heap_pair});
    try std.testing.expectEqual(obj.sharp_f, Prim_constant_p());
    stubs.setArgs(&.{heap_pair});
    try std.testing.expectEqual(obj.sharp_f, Prim_pure_p());
    stubs.setArgs(&.{heap_pair});
    try std.testing.expectEqual(heap_pair, Prim_impurify());

    const src = [_]obj.SchemeObject{ obj.longToFixnum(10), obj.longToFixnum(20) };
    const copied = copy_to_constant_space(&src, 2);
    const const_pair = obj.makePointerObject(obj.tc_list, copied);
    try std.testing.expect(object_in_constant_space_p(const_pair));
    stubs.setArgs(&.{const_pair});
    try std.testing.expectEqual(obj.sharp_t, Prim_constant_p());
    try std.testing.expectEqual(obj.longToFixnum(20), obj.pairCdr(const_pair));
}
