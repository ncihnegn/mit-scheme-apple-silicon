// Derived from MIT/GNU Scheme C sources (`src/microcode/dfloat.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

fn floatingVectorIndexArg(arg_num: c_int, vector: obj.SchemeObject) usize {
    return @intCast(abi.arg_index_integer(arg_num, @intCast(obj.floatingVectorLength(vector))));
}

// DEFINE_PRIMITIVE ("FLOATING-VECTOR-CONS", Prim_floating_vector_cons, 1, 1, 0)
pub export fn Prim_floating_vector_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const length: usize = @intCast(abi.arg_nonnegative_integer(1));
    const length_in_words: c_ulong = @as(c_ulong, @intCast(length)) * obj.flonum_size;
    obj.alignFloat(&abi.Free);
    abi.primitiveGcIfNeeded(length_in_words + 1);
    const result = obj.makePointerObject(obj.tc_big_flonum, abi.Free);
    abi.Free[0] = obj.makeNmvHeader(length_in_words);
    abi.Free += 1;
    const vect: [*]f64 = @ptrCast(@alignCast(abi.Free));
    for (0..length) |i| {
        vect[i] = 0.0;
    }
    abi.Free = @ptrCast(@alignCast(vect + length));
    return result;
}

// DEFINE_PRIMITIVE ("FLOATING-VECTOR-REF", Prim_floating_vector_ref, 2, 2, 0)
pub export fn Prim_floating_vector_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.flonumP);
    const vector = abi.argRef(1);
    abi.primitiveGcIfNeeded(obj.flonum_size + 1);
    const index = floatingVectorIndexArg(2, vector);
    return abi.double_to_flonum(obj.floatingVectorRef(vector, index));
}

// DEFINE_PRIMITIVE ("FLOATING-VECTOR-SET!", Prim_floating_vector_set, 3, 3, 0)
pub export fn Prim_floating_vector_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.flonumP);
    const vector = abi.argRef(1);
    const index = floatingVectorIndexArg(2, vector);
    obj.floatingVectorSet(vector, index, abi.arg_flonum(3));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FLOATING-VECTOR-LENGTH", Prim_floating_vector_length, 1, 1,
//                   0)
pub export fn Prim_floating_vector_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.flonumP);
    return obj.ulongToFixnum(obj.floatingVectorLength(abi.argRef(1)));
}

test "dfloat primitives construct, measure, mutate, and read floating vectors" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{obj.ulongToFixnum(4)});
    const fv = Prim_floating_vector_cons();
    try std.testing.expect(obj.flonumP(fv));

    stubs.setArgs(&.{fv});
    try std.testing.expectEqual(obj.ulongToFixnum(4), Prim_floating_vector_length());

    const flonum_val = abi.double_to_flonum(3.25);
    stubs.setArgs(&.{ fv, obj.ulongToFixnum(2), flonum_val });
    try std.testing.expectEqual(obj.unspecific, Prim_floating_vector_set());

    stubs.setArgs(&.{ fv, obj.ulongToFixnum(0) });
    const zero_elem = Prim_floating_vector_ref();
    const zero_ptr: *const f64 = @ptrCast(@alignCast(obj.memoryLoc(zero_elem, 1)));
    try std.testing.expectEqual(@as(f64, 0.0), zero_ptr.*);

    stubs.setArgs(&.{ fv, obj.ulongToFixnum(2) });
    const set_elem = Prim_floating_vector_ref();
    const set_ptr: *const f64 = @ptrCast(@alignCast(obj.memoryLoc(set_elem, 1)));
    try std.testing.expectEqual(@as(f64, 3.25), set_ptr.*);
}
