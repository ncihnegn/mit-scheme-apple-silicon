// Derived from MIT/GNU Scheme C sources (`src/microcode/vector.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

fn argVector(argument_number: c_int) obj.SchemeObject {
    const val = abi.argRef(@intCast(argument_number));
    if (!obj.vectorP(val)) abi.error_wrong_type_arg(argument_number);
    return val;
}

fn argRecord(argument_number: c_int) obj.SchemeObject {
    const val = abi.argRef(@intCast(argument_number));
    if (!obj.recordP(val)) abi.error_wrong_type_arg(argument_number);
    return val;
}

fn argGcVector(argument_number: c_int) obj.SchemeObject {
    const val = abi.argRef(@intCast(argument_number));
    if (!abi.gcTypeVector(val)) abi.error_wrong_type_arg(argument_number);
    return val;
}

fn argVectorIndex(argument_number: c_int, vector: obj.SchemeObject) usize {
    return @intCast(abi.arg_index_integer(argument_number, @intCast(obj.vectorLength(vector))));
}

pub export fn allocate_vector_internal(
    vec_type: c_uint,
    manifest_type: c_uint,
    length: usize,
    fp: *[*]obj.SchemeObject,
) callconv(.c) obj.SchemeObject {
    const base = fp.*;
    const result = obj.makePointerObject(@intCast(vec_type), base);
    base[0] = obj.makeObject(@intCast(manifest_type), length);
    fp.* = base + 1 + @as(usize, @intCast(length));
    return result;
}

pub export fn allocate_non_marked_vector(
    vec_type: c_uint,
    length: usize,
    gc_check_p: bool,
) callconv(.c) obj.SchemeObject {
    if (gc_check_p) abi.primitiveGcIfNeeded(1 + length);
    return allocate_vector_internal(vec_type, @intCast(obj.tc_manifest_nm_vector), length, &abi.Free);
}

pub export fn allocate_marked_vector(
    vec_type: c_uint,
    length: usize,
    gc_check_p: bool,
) callconv(.c) obj.SchemeObject {
    if (gc_check_p) abi.primitiveGcIfNeeded(1 + length);
    return allocate_vector_internal(vec_type, @intCast(obj.tc_manifest_vector), length, &abi.Free);
}

pub export fn allocate_vector(length: usize, gc_check_p: bool) callconv(.c) obj.SchemeObject {
    return allocate_marked_vector(@intCast(obj.tc_vector), length, gc_check_p);
}

pub export fn make_marked_vector(
    vec_type: c_uint,
    length: usize,
    fill_value: obj.SchemeObject,
    gc_check_p: bool,
) callconv(.c) obj.SchemeObject {
    if (gc_check_p) abi.primitiveGcIfNeeded(length + 1);
    const base = abi.Free;
    const result = obj.makePointerObject(@intCast(vec_type), base);
    base[0] = obj.makeVectorHeader(length);
    const len_u: usize = @intCast(length);
    @memset(base[1 .. 1 + len_u], fill_value);
    abi.Free = base + 1 + len_u;
    return result;
}

pub export fn make_vector(
    length: usize,
    filler: obj.SchemeObject,
    gc_check_p: bool,
) callconv(.c) obj.SchemeObject {
    return make_marked_vector(@intCast(obj.tc_vector), length, filler, gc_check_p);
}

// DEFINE_PRIMITIVE ("ALLOCATE-NM-VECTOR", Prim_allocate_nm_vector, 2, 2, 0)
pub export fn Prim_allocate_nm_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vec_type: c_uint = @intCast(abi.arg_ulong_index_integer(1, obj.n_type_codes));
    const length = abi.arg_ulong_index_integer(2, @as(usize, 1) << obj.datum_length);
    return allocate_non_marked_vector(vec_type, length, true);
}

// DEFINE_PRIMITIVE ("VECTOR-CONS", Prim_vector_cons, 2, 2, 0)
pub export fn Prim_vector_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const length: usize = @intCast(abi.arg_nonnegative_integer(1));
    return make_vector(length, abi.argRef(2), true);
}

// DEFINE_PRIMITIVE ("VECTOR", Prim_vector, 0, LEXPR, 0)
pub export fn Prim_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const nargs = abi.getLexprActuals();
    const result = allocate_vector(nargs, true);
    const n: usize = @intCast(nargs);
    @memcpy(obj.vectorLoc(result, 0)[0..n], abi.argLoc(1)[0..n]);
    return result;
}

// DEFINE_PRIMITIVE ("%MAKE-RECORD", Prim_make_record, 2, 2, 0)
pub export fn Prim_make_record() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const length = abi.arg_ulong_index_integer(1, @as(usize, 1) << obj.datum_length);
    return make_marked_vector(@intCast(obj.tc_record), length, abi.argRef(2), true);
}

// DEFINE_PRIMITIVE ("%RECORD", Prim_record, 0, LEXPR, 0)
pub export fn Prim_record() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const nargs = abi.getLexprActuals();
    if (nargs < 1) {
        abi.signal_error_from_primitive(abi.err_wrong_number_of_arguments);
    }
    const result = allocate_marked_vector(@intCast(obj.tc_record), nargs, true);
    const n: usize = @intCast(nargs);
    @memcpy(obj.vectorLoc(result, 0)[0..n], abi.argLoc(1)[0..n]);
    return result;
}

// DEFINE_PRIMITIVE ("VECTOR?", Prim_vector_p, 1, 1, 0)
pub export fn Prim_vector_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.vectorP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("%RECORD?", Prim_record_p, 1, 1, 0)
pub export fn Prim_record_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.recordP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("SYSTEM-VECTOR?", Prim_sys_vector, 1, 1, 0)
pub export fn Prim_sys_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.gcTypeVector(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("VECTOR-LENGTH", Prim_vector_length, 1, 1, 0)
pub export fn Prim_vector_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(obj.vectorLength(argVector(1))));
}

// DEFINE_PRIMITIVE ("%RECORD-LENGTH", Prim_record_length, 1, 1, 0)
pub export fn Prim_record_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(obj.vectorLength(argRecord(1))));
}

// DEFINE_PRIMITIVE ("SYSTEM-VECTOR-SIZE", Prim_sys_vec_size, 1, 1, 0)
pub export fn Prim_sys_vec_size() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(obj.vectorLength(argGcVector(1))));
}

// DEFINE_PRIMITIVE ("VECTOR-REF", Prim_vector_ref, 2, 2, 0)
pub export fn Prim_vector_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argVector(1);
    return obj.vectorRef(vector, argVectorIndex(2, vector));
}

// DEFINE_PRIMITIVE ("%RECORD-REF", Prim_record_ref, 2, 2, 0)
pub export fn Prim_record_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argRecord(1);
    return obj.vectorRef(vector, argVectorIndex(2, vector));
}

// DEFINE_PRIMITIVE ("SYSTEM-VECTOR-REF", Prim_sys_vector_ref, 2, 2, 0)
pub export fn Prim_sys_vector_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argGcVector(1);
    return obj.vectorRef(vector, argVectorIndex(2, vector));
}

// DEFINE_PRIMITIVE ("VECTOR-SET!", Prim_vector_set, 3, 3, 0)
pub export fn Prim_vector_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argVector(1);
    const new_value = abi.argRef(3);
    obj.vectorSet(vector, argVectorIndex(2, vector), new_value);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("%RECORD-SET!", Prim_record_set, 3, 3, 0)
pub export fn Prim_record_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argRecord(1);
    const new_value = abi.argRef(3);
    obj.vectorSet(vector, argVectorIndex(2, vector), new_value);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SYSTEM-VECTOR-SET!", Prim_sys_vec_set, 3, 3, 0)
pub export fn Prim_sys_vec_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argGcVector(1);
    const new_value = abi.argRef(3);
    obj.vectorSet(vector, argVectorIndex(2, vector), new_value);
    return obj.unspecific;
}

fn subvectorToList(vector: obj.SchemeObject, start: isize, end: isize) obj.SchemeObject {
    if (start == end) return obj.empty_list;
    const count: usize = @intCast(end - start);
    abi.primitiveGcIfNeeded(@intCast(2 * count));
    const base = abi.Free;
    const result = obj.makePointerObject(obj.tc_list, base);
    const elems = obj.vectorLoc(vector, @intCast(start));
    var pair_scan = base;
    for (0..count - 1) |i| {
        const next_pair = pair_scan + 2;
        pair_scan[0] = elems[i];
        pair_scan[1] = obj.makePointerObject(obj.tc_list, next_pair);
        pair_scan = next_pair;
    }
    pair_scan[0] = elems[count - 1];
    pair_scan[1] = obj.empty_list;
    abi.Free = pair_scan + 2;
    return result;
}

fn subvectorToListPrimitive(comptime arg_fn: fn (c_int) obj.SchemeObject) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = arg_fn(1);
    const start = abi.arg_nonnegative_integer(2);
    const end = abi.arg_nonnegative_integer(3);
    if (end > @as(isize, @intCast(obj.vectorLength(vector)))) abi.error_bad_range_arg(3);
    if (start > end) abi.error_bad_range_arg(2);
    return subvectorToList(vector, start, end);
}

// DEFINE_PRIMITIVE ("SUBVECTOR->LIST", Prim_subvector_to_list, 3, 3, 0)
pub export fn Prim_subvector_to_list() callconv(.c) obj.SchemeObject {
    return subvectorToListPrimitive(argVector);
}

// DEFINE_PRIMITIVE ("SYSTEM-SUBVECTOR-TO-LIST", Prim_sys_subvector_to_list, 3, 3, 0)
pub export fn Prim_sys_subvector_to_list() callconv(.c) obj.SchemeObject {
    return subvectorToListPrimitive(argGcVector);
}

fn listToVector(result_type: usize, argument_number: c_int) obj.SchemeObject {
    var list = abi.argRef(@intCast(argument_number));
    var count: usize = 0;
    const result = abi.Free;
    abi.Free += 1;
    while (obj.pairP(list)) {
        abi.primitiveGcIfNeeded(0);
        count += 1;
        abi.Free[0] = obj.pairCar(list);
        abi.Free += 1;
        list = obj.pairCdr(list);
    }
    if (!obj.emptyListP(list)) abi.error_wrong_type_arg(argument_number);
    result[0] = obj.makeVectorHeader(count);
    return obj.makePointerObject(result_type, result);
}

// DEFINE_PRIMITIVE ("LIST->VECTOR", Prim_list_to_vector, 1, 1, 0)
pub export fn Prim_list_to_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return listToVector(obj.tc_vector, 1);
}

// DEFINE_PRIMITIVE ("SYSTEM-LIST-TO-VECTOR", Prim_sys_list_to_vector, 2, 2, 0)
pub export fn Prim_sys_list_to_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const type_code = abi.arg_ulong_index_integer(1, obj.n_type_codes);
    if (abi.gc_type_code(@intCast(type_code)) != @backingInt(abi.GcType.vector)) {
        abi.error_bad_range_arg(1);
    }
    return listToVector(type_code, 2);
}

const MoveRange = struct {
    vector1: obj.SchemeObject,
    start1: usize,
    end1: usize,
    vector2: obj.SchemeObject,
    start2: usize,
    end2: usize,
    length: usize,
};

fn subvectorMovePrefix() MoveRange {
    abi.primitiveHeader();
    const vector1 = argVector(1);
    const start1 = abi.arg_nonnegative_integer(2);
    const end1 = abi.arg_nonnegative_integer(3);
    const vector2 = argVector(4);
    const start2 = abi.arg_nonnegative_integer(5);
    if (end1 > @as(isize, @intCast(obj.vectorLength(vector1)))) abi.error_bad_range_arg(3);
    if (start1 > end1) abi.error_bad_range_arg(2);
    const length = end1 - start1;
    const end2 = start2 + length;
    if (end2 > @as(isize, @intCast(obj.vectorLength(vector2)))) abi.error_bad_range_arg(5);
    return .{
        .vector1 = vector1,
        .start1 = @intCast(start1),
        .end1 = @intCast(end1),
        .vector2 = vector2,
        .start2 = @intCast(start2),
        .end2 = @intCast(end2),
        .length = @intCast(length),
    };
}

// DEFINE_PRIMITIVE ("SUBVECTOR-MOVE-RIGHT!", Prim_subvector_move_right, 5, 5, 0)
pub export fn Prim_subvector_move_right() callconv(.c) obj.SchemeObject {
    const r = subvectorMovePrefix();
    var scan1 = obj.vectorLoc(r.vector1, r.end1);
    var scan2 = obj.vectorLoc(r.vector2, r.end2);
    var rem = r.length;
    while (rem > 0) : (rem -= 1) {
        scan1 -= 1;
        scan2 -= 1;
        scan2[0] = scan1[0];
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SUBVECTOR-MOVE-LEFT!", Prim_subvector_move_left, 5, 5, 0)
pub export fn Prim_subvector_move_left() callconv(.c) obj.SchemeObject {
    const r = subvectorMovePrefix();
    const src = obj.vectorLoc(r.vector1, r.start1);
    const dst = obj.vectorLoc(r.vector2, r.start2);
    for (0..r.length) |i| {
        dst[i] = src[i];
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SUBVECTOR-FILL!", Prim_vector_fill, 4, 4, 0)
pub export fn Prim_vector_fill() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vector = argVector(1);
    const start = abi.arg_nonnegative_integer(2);
    const end = abi.arg_nonnegative_integer(3);
    const fill_value = abi.argRef(4);
    if (end > @as(isize, @intCast(obj.vectorLength(vector)))) abi.error_bad_range_arg(3);
    if (start > end) abi.error_bad_range_arg(2);
    const start_u: usize = @intCast(start);
    const len_u: usize = @intCast(end - start);
    @memset(obj.vectorLoc(vector, start_u)[0..len_u], fill_value);
    return obj.unspecific;
}

fn recordMarker(record: obj.SchemeObject) obj.SchemeObject {
    const marker = obj.vectorRef(record, 0);
    if (obj.objectType(marker) == obj.tc_constant and
        obj.objectDatum(marker) >= obj.fasdump_record_marker_start and
        obj.objectDatum(marker) < obj.fasdump_record_marker_end)
    {
        const proxied = obj.vectorRef(abi.fixed_objects, abi.fixobj_proxied_record_types);
        const idx: usize = @intCast(obj.objectDatum(marker) - obj.fasdump_record_marker_start);
        return obj.vectorRef(proxied, idx);
    }
    return marker;
}

pub export fn record_applicator(record: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const marker = recordMarker(record);
    if (obj.recordP(marker) and
        obj.vectorRef(marker, 0) == obj.vectorRef(abi.fixed_objects, abi.fixobj_record_tag))
    {
        const app_index: usize = @intCast(obj.fixnumToUlong(
            obj.vectorRef(abi.fixed_objects, abi.fixobj_record_app_index),
        ));
        return obj.vectorRef(marker, app_index);
    }
    return obj.sharp_f;
}

test "vector, record, subvector, list->vector, and record_applicator" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // VECTOR-CONS & VECTOR-FILL!
    stubs.setArgs(&.{ obj.ulongToFixnum(5), obj.ulongToFixnum(9) });
    const vec = Prim_vector_cons();
    stubs.setArgs(&.{vec});
    try std.testing.expectEqual(obj.sharp_t, Prim_vector_p());
    try std.testing.expectEqual(obj.ulongToFixnum(5), Prim_vector_length());

    stubs.setArgs(&.{ vec, obj.ulongToFixnum(1), obj.ulongToFixnum(4), obj.ulongToFixnum(7) });
    try std.testing.expectEqual(obj.unspecific, Prim_vector_fill());

    // LEXPR VECTOR constructor
    stubs.setArgs(&.{
        obj.ulongToFixnum(10),
        obj.ulongToFixnum(20),
        obj.ulongToFixnum(30),
        obj.ulongToFixnum(40),
        obj.ulongToFixnum(50),
    });
    const v5 = Prim_vector();
    stubs.setArgs(&.{ v5, obj.ulongToFixnum(2) });
    try std.testing.expectEqual(obj.ulongToFixnum(30), Prim_vector_ref());

    // Overlapping SUBVECTOR-MOVE-RIGHT! and SUBVECTOR-MOVE-LEFT!
    stubs.setArgs(&.{ v5, obj.ulongToFixnum(0), obj.ulongToFixnum(3), v5, obj.ulongToFixnum(1) });
    try std.testing.expectEqual(obj.unspecific, Prim_subvector_move_right());
    // Elements should now be [10, 10, 20, 30, 50]
    stubs.setArgs(&.{ v5, obj.ulongToFixnum(1), obj.ulongToFixnum(4) });
    const sub_list = Prim_subvector_to_list();
    stubs.setArgs(&.{sub_list});
    const round_trip = Prim_list_to_vector();
    try std.testing.expectEqual(@as(usize, 3), obj.vectorLength(round_trip));
    try std.testing.expectEqual(obj.ulongToFixnum(10), obj.vectorRef(round_trip, 0));
    try std.testing.expectEqual(obj.ulongToFixnum(20), obj.vectorRef(round_trip, 1));
    try std.testing.expectEqual(obj.ulongToFixnum(30), obj.vectorRef(round_trip, 2));

    stubs.setArgs(&.{ v5, obj.ulongToFixnum(2), obj.ulongToFixnum(5), v5, obj.ulongToFixnum(0) });
    try std.testing.expectEqual(obj.unspecific, Prim_subvector_move_left());
    // Elements should now be [20, 30, 50, 30, 50]
    try std.testing.expectEqual(obj.ulongToFixnum(20), obj.vectorRef(v5, 0));
    try std.testing.expectEqual(obj.ulongToFixnum(30), obj.vectorRef(v5, 1));
    try std.testing.expectEqual(obj.ulongToFixnum(50), obj.vectorRef(v5, 2));

    // %RECORD & record_applicator (direct + proxied marker)
    const fixed_vec = allocate_vector(0x20, true);
    const rec_tag = obj.makeObject(obj.tc_constant, 99);
    const proxied_types = allocate_vector(4, true);
    obj.vectorSet(fixed_vec, abi.fixobj_record_tag, rec_tag);
    obj.vectorSet(fixed_vec, abi.fixobj_record_app_index, obj.ulongToFixnum(1));
    obj.vectorSet(fixed_vec, abi.fixobj_proxied_record_types, proxied_types);
    abi.fixed_objects = fixed_vec;

    const app_proc = obj.ulongToFixnum(777);
    stubs.setArgs(&.{ rec_tag, app_proc });
    const rtd = Prim_record();
    obj.vectorSet(proxied_types, 2, rtd);

    stubs.setArgs(&.{ rtd, obj.ulongToFixnum(123) });
    const direct_rec = Prim_record();
    try std.testing.expectEqual(app_proc, record_applicator(direct_rec));

    stubs.setArgs(&.{
        obj.makeObject(obj.tc_constant, obj.fasdump_record_marker_start + 2),
        obj.ulongToFixnum(456),
    });
    const proxied_rec = Prim_record();
    try std.testing.expectEqual(app_proc, record_applicator(proxied_rec));

    stubs.setArgs(&.{ obj.ulongToFixnum(1), obj.ulongToFixnum(0) });
    const non_app_rec = Prim_record();
    try std.testing.expectEqual(obj.sharp_f, record_applicator(non_app_rec));
}
