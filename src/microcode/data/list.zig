// Derived from MIT/GNU Scheme C sources (`src/microcode/list.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");

// DEFINE_PRIMITIVE ("pair?", Prim_pair, 1, 1,
//  "(OBJECT)\n\
// Returns #t iff OBJECT is a pair")
pub export fn Prim_pair() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.pairP(abi.argRef(1)));
}

pub export fn cons(car_val: obj.SchemeObject, cdr_val: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    abi.primitiveGcIfNeeded(2);
    const base = abi.Free;
    base[0] = car_val;
    base[1] = cdr_val;
    abi.Free = base + 2;
    return obj.makePointerObject(obj.tc_list, base);
}

// DEFINE_PRIMITIVE ("cons", Prim_cons, 2, 2,
// "(OBJ1 OBJ2)\n\
// Returns a newly allocated pair whose car is OBJ1 and whose cdr is OBJ2.")
pub export fn Prim_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return cons(abi.argRef(1), abi.argRef(2));
}

// DEFINE_PRIMITIVE ("car", Prim_car, 1, 1,
// "(PAIR)\n\
// Returns the contents of the car field of PAIR.")
pub export fn Prim_car() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.pairP);
    return obj.pairCar(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("cdr", Prim_cdr, 1, 1,
// "(PAIR)\n\
// Returns the contents of the cdr field of PAIR")
pub export fn Prim_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.pairP);
    return obj.pairCdr(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("set-car!", Prim_set_car, 2, 2,
//  "(PAIR OBJECT)\n\
// Stores OBJECT in the car field of PAIR and returns an unspecified value.")
pub export fn Prim_set_car() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.pairP);
    obj.setPairCar(abi.argRef(1), abi.argRef(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("set-cdr!", Prim_set_cdr, 2, 2,
// "(PAIR OBJECT)\n\
// Stores OBJECT in the cdr field of PAIR and returns an unspecified value.")
pub export fn Prim_set_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.pairP);
    obj.setPairCdr(abi.argRef(1), abi.argRef(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("general-car-cdr", Prim_general_car_cdr, 2, 2,
// "(OBJECT PATH)\n\
// \n\
// This procedure is a generalization of CAR and CDR.  PATH encodes a\n\
// particular sequence of CAR and CDR operations, which this procedure\n\
// executes on OBJECT.\n\
// \n\
// PATH is an exact non-negative integer that encodes the operations in a\n\
// bitwise fashion: a zero bit represents a CDR operation, and a one bit\n\
// represents a CAR.  The bits are executed LSB to MSB, and the most\n\
// significant one bit, rather than being interpreted as an operation,\n\
// signals the end of the sequence.\n\
// \n\
// For example, the following are equivalent:\n\
// \n\
//      (general-car-cdr OBJECT #b1011)\n\
//      (cdr (car (car OBJECT)))\n\
// \n\
// Here is a partial table of path/operation equivalents:\n\
// \n\
//     #b10    cdr\n\
//     #b11    car\n\
//     #b100   cddr\n\
//     #b101   cdar\n\
//     #b110   cadr\n\
//     #b111   caar\n\
//     #b1000  cdddr\n\
// \n\
// Note that this implementation restricts PATH to the length of the\n\
// machine word.  Since one bit is used as a limit marker, this means the\n\
// maximum length is 31 bits for a 32-bit architecture, and 63 bits for a\n\
// 64-bit architecture.")
pub export fn Prim_general_car_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var object = abi.argRef(1);
    var path = abi.arg_ulong_integer(2);
    while (path > 1) {
        if (!obj.pairP(object)) abi.error_wrong_type_arg(1);
        object = if ((path & 1) == 0) obj.pairCdr(object) else obj.pairCar(object);
        path >>= 1;
    }
    return object;
}

// DEFINE_PRIMITIVE ("system-pair?", Prim_sys_pair, 1, 1, 0)
pub export fn Prim_sys_pair() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.gcTypePair(abi.argRef(1)));
}

pub export fn system_pair_cons(
    pair_type: isize,
    car_val: obj.SchemeObject,
    cdr_val: obj.SchemeObject,
) callconv(.c) obj.SchemeObject {
    abi.primitiveGcIfNeeded(2);
    const base = abi.Free;
    base[0] = car_val;
    base[1] = cdr_val;
    abi.Free = base + 2;
    return obj.makePointerObject(@intCast(pair_type), base);
}

// DEFINE_PRIMITIVE ("system-pair-cons", Prim_sys_pair_cons, 3, 3, 0)
pub export fn Prim_sys_pair_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const pair_type = abi.arg_ulong_index_integer(1, obj.n_type_codes);
    if (abi.gc_type_code(@intCast(pair_type)) != @backingInt(abi.GcType.pair)) {
        abi.error_bad_range_arg(1);
    }
    return system_pair_cons(@intCast(pair_type), abi.argRef(2), abi.argRef(3));
}

// DEFINE_PRIMITIVE ("system-pair-car", Prim_sys_pair_car, 1, 1, 0)
pub export fn Prim_sys_pair_car() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, abi.gcTypePair);
    return obj.pairCar(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("system-pair-cdr", Prim_sys_pair_cdr, 1, 1, 0)
pub export fn Prim_sys_pair_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, abi.gcTypePair);
    return obj.pairCdr(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("system-pair-set-car!", Prim_sys_set_car, 2, 2, 0)
pub export fn Prim_sys_set_car() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, abi.gcTypePair);
    obj.setPairCar(abi.argRef(1), abi.argRef(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("system-pair-set-cdr!", Prim_sys_set_cdr, 2, 2, 0)
pub export fn Prim_sys_set_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, abi.gcTypePair);
    obj.setPairCdr(abi.argRef(1), abi.argRef(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("%tagged-object?", Prim_tagged_object_p, 1, 1, 0)
pub export fn Prim_tagged_object_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.taggedObjectP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("%make-tagged-object", Prim_make_tagged_object, 2, 2, 0)
pub export fn Prim_make_tagged_object() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.primitiveGcIfNeeded(2);
    const base = abi.Free;
    const result = obj.makePointerObject(obj.tc_tagged_object, base);
    base[0] = abi.argRef(1);
    base[1] = abi.argRef(2);
    abi.Free = base + 2;
    return result;
}

// DEFINE_PRIMITIVE ("%tagged-object-tag", Prim_tagged_object_tag, 1, 1, 0)
pub export fn Prim_tagged_object_tag() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.taggedObjectP);
    return obj.memoryRef(abi.argRef(1), 0);
}

// DEFINE_PRIMITIVE ("%tagged-object-datum", Prim_tagged_object_datum, 1, 1, 0)
pub export fn Prim_tagged_object_datum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.taggedObjectP);
    return obj.memoryRef(abi.argRef(1), 1);
}

// DEFINE_PRIMITIVE ("weak-pair?", Prim_weak_pair_p, 1, 1, 0)
pub export fn Prim_weak_pair_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.weakPairP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("weak-cons", Prim_weak_cons, 2, 2, 0)
pub export fn Prim_weak_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.primitiveGcIfNeeded(2);
    const base = abi.Free;
    const result = obj.makePointerObject(obj.tc_weak_cons, base);
    base[0] = abi.argRef(1);
    base[1] = abi.argRef(2);
    abi.Free = base + 2;
    return result;
}

// DEFINE_PRIMITIVE ("weak-car", Prim_weak_car, 1, 1, 0)
pub export fn Prim_weak_car() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.weakPairP);
    return obj.memoryRef(abi.argRef(1), 0);
}

// DEFINE_PRIMITIVE ("weak-cdr", Prim_weak_cdr, 1, 1, 0)
pub export fn Prim_weak_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.weakPairP);
    return obj.memoryRef(abi.argRef(1), 1);
}

// DEFINE_PRIMITIVE ("weak-set-car!", Prim_weak_set_car, 2, 2, 0)
pub export fn Prim_weak_set_car() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.weakPairP);
    obj.memorySet(abi.argRef(1), 0, abi.argRef(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("weak-set-cdr!", Prim_weak_set_cdr, 2, 2, 0)
pub export fn Prim_weak_set_cdr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.weakPairP);
    obj.memorySet(abi.argRef(1), 1, abi.argRef(2));
    return obj.unspecific;
}

test "list, system-pair, tagged-object, and weak-pair primitives" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    // Basic pair cons/car/cdr/set-car!/set-cdr! and general-car-cdr
    stubs.setArgs(&.{ obj.ulongToFixnum(1), obj.ulongToFixnum(2) });
    const inner = Prim_cons();
    stubs.setArgs(&.{ inner, obj.ulongToFixnum(3) });
    const mid = Prim_cons();
    stubs.setArgs(&.{ mid, obj.ulongToFixnum(4) });
    const outer = Prim_cons();

    stubs.setArgs(&.{outer});
    try std.testing.expectEqual(obj.sharp_t, Prim_pair());
    try std.testing.expectEqual(mid, Prim_car());
    try std.testing.expectEqual(obj.ulongToFixnum(4), Prim_cdr());

    // general-car-cdr path #b1011 => cdr(car(car(outer))) = 2
    stubs.setArgs(&.{ outer, obj.ulongToFixnum(0b1011) });
    try std.testing.expectEqual(obj.ulongToFixnum(2), Prim_general_car_cdr());

    // path #b1 => outer itself
    stubs.setArgs(&.{ outer, obj.ulongToFixnum(1) });
    try std.testing.expectEqual(outer, Prim_general_car_cdr());

    // mutate inner
    stubs.setArgs(&.{ inner, obj.ulongToFixnum(10) });
    try std.testing.expectEqual(obj.unspecific, Prim_set_car());
    stubs.setArgs(&.{ inner, obj.ulongToFixnum(20) });
    try std.testing.expectEqual(obj.unspecific, Prim_set_cdr());
    stubs.setArgs(&.{ outer, obj.ulongToFixnum(0b111) }); // caar -> cdr? No, car(car(outer)) = inner
    try std.testing.expectEqual(inner, Prim_general_car_cdr());
    stubs.setArgs(&.{ outer, obj.ulongToFixnum(0b1111) }); // car(car(car(outer))) = 10
    try std.testing.expectEqual(obj.ulongToFixnum(10), Prim_general_car_cdr());

    // system-pair-*
    stubs.setArgs(&.{ obj.ulongToFixnum(obj.tc_pair), obj.ulongToFixnum(5), obj.ulongToFixnum(6) });
    const sp = Prim_sys_pair_cons();
    stubs.setArgs(&.{sp});
    try std.testing.expectEqual(obj.sharp_t, Prim_sys_pair());
    try std.testing.expectEqual(obj.ulongToFixnum(5), Prim_sys_pair_car());
    try std.testing.expectEqual(obj.ulongToFixnum(6), Prim_sys_pair_cdr());
    stubs.setArgs(&.{ sp, obj.ulongToFixnum(7) });
    try std.testing.expectEqual(obj.unspecific, Prim_sys_set_car());
    stubs.setArgs(&.{ sp, obj.ulongToFixnum(8) });
    try std.testing.expectEqual(obj.unspecific, Prim_sys_set_cdr());
    stubs.setArgs(&.{sp});
    try std.testing.expectEqual(obj.ulongToFixnum(7), Prim_sys_pair_car());
    try std.testing.expectEqual(obj.ulongToFixnum(8), Prim_sys_pair_cdr());

    // %tagged-object-*
    stubs.setArgs(&.{ obj.ulongToFixnum(42), obj.sharp_t });
    const tag_obj = Prim_make_tagged_object();
    stubs.setArgs(&.{tag_obj});
    try std.testing.expectEqual(obj.sharp_t, Prim_tagged_object_p());
    try std.testing.expectEqual(obj.ulongToFixnum(42), Prim_tagged_object_tag());
    try std.testing.expectEqual(obj.sharp_t, Prim_tagged_object_datum());

    // weak-pair-*
    stubs.setArgs(&.{ obj.ulongToFixnum(11), obj.ulongToFixnum(22) });
    const wp = Prim_weak_cons();
    stubs.setArgs(&.{wp});
    try std.testing.expectEqual(obj.sharp_t, Prim_weak_pair_p());
    try std.testing.expectEqual(obj.ulongToFixnum(11), Prim_weak_car());
    try std.testing.expectEqual(obj.ulongToFixnum(22), Prim_weak_cdr());
    stubs.setArgs(&.{ wp, obj.ulongToFixnum(33) });
    try std.testing.expectEqual(obj.unspecific, Prim_weak_set_car());
    stubs.setArgs(&.{ wp, obj.ulongToFixnum(44) });
    try std.testing.expectEqual(obj.unspecific, Prim_weak_set_cdr());
    stubs.setArgs(&.{wp});
    try std.testing.expectEqual(obj.ulongToFixnum(33), Prim_weak_car());
    try std.testing.expectEqual(obj.ulongToFixnum(44), Prim_weak_cdr());
}
