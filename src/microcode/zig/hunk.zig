// Derived from MIT/GNU Scheme C sources (`src/microcode/hunk.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

fn systemHunk3Cons(
    hunk_type: c_ulong,
    cxr0: obj.SchemeObject,
    cxr1: obj.SchemeObject,
    cxr2: obj.SchemeObject,
) obj.SchemeObject {
    abi.primitiveGcIfNeeded(3);
    const base = abi.Free;
    base[0] = cxr0;
    base[1] = cxr1;
    base[2] = cxr2;
    abi.Free = base + 3;
    return obj.makePointerObject(hunk_type, base);
}

pub export fn hunk3_cons(
    cxr0: obj.SchemeObject,
    cxr1: obj.SchemeObject,
    cxr2: obj.SchemeObject,
) callconv(.c) obj.SchemeObject {
    return systemHunk3Cons(obj.tc_hunk3, cxr0, cxr1, cxr2);
}

// DEFINE_PRIMITIVE ("HUNK3-CONS", Prim_hunk3_cons, 3, 3, 0)
pub export fn Prim_hunk3_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return hunk3_cons(abi.argRef(1), abi.argRef(2), abi.argRef(3));
}

// DEFINE_PRIMITIVE ("HUNK3-CXR", Prim_hunk3_cxr, 2, 2, 0)
pub export fn Prim_hunk3_cxr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.hunk3P);
    const index: usize = @intCast(abi.arg_index_integer(2, 3));
    return obj.memoryRef(abi.argRef(1), index);
}

// DEFINE_PRIMITIVE ("HUNK3-SET-CXR!", Prim_hunk3_set_cxr, 3, 3, 0)
pub export fn Prim_hunk3_set_cxr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.hunk3P);
    const hunk3 = abi.argRef(1);
    const index: usize = @intCast(abi.arg_index_integer(2, 3));
    const object = abi.argRef(3);
    obj.memorySet(hunk3, index, object);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("system-hunk3-cons", Prim_sys_hunk3_cons, 4, 4, 0)
pub export fn Prim_sys_hunk3_cons() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const hunk_type = abi.arg_ulong_index_integer(1, obj.n_type_codes);
    if (abi.gc_type_code(@intCast(hunk_type)) != @intFromEnum(abi.GcType.triple)) {
        abi.error_bad_range_arg(1);
    }
    return systemHunk3Cons(hunk_type, abi.argRef(2), abi.argRef(3), abi.argRef(4));
}

fn argGcTriple(arg_number: c_int) obj.SchemeObject {
    const val = abi.argRef(@intCast(arg_number));
    if (!abi.gcTypeTriple(val)) abi.error_wrong_type_arg(arg_number);
    return val;
}

// DEFINE_PRIMITIVE ("SYSTEM-HUNK3-CXR0", Prim_sys_h3_0, 1, 1, 0)
pub export fn Prim_sys_h3_0() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.memoryRef(argGcTriple(1), 0);
}

// DEFINE_PRIMITIVE ("SYSTEM-HUNK3-CXR1", Prim_sys_h3_1, 1, 1, 0)
pub export fn Prim_sys_h3_1() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.memoryRef(argGcTriple(1), 1);
}

// DEFINE_PRIMITIVE ("SYSTEM-HUNK3-CXR2", Prim_sys_h3_2, 1, 1, 0)
pub export fn Prim_sys_h3_2() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.memoryRef(argGcTriple(1), 2);
}

// DEFINE_PRIMITIVE ("SYSTEM-HUNK3-SET-CXR0!", Prim_sh3_set_0, 2, 2, 0)
pub export fn Prim_sh3_set_0() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const hunk3 = argGcTriple(1);
    const object = abi.argRef(2);
    obj.memorySet(hunk3, 0, object);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SYSTEM-HUNK3-SET-CXR1!", Prim_sh3_set_1, 2, 2, 0)
pub export fn Prim_sh3_set_1() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const hunk3 = argGcTriple(1);
    const object = abi.argRef(2);
    obj.memorySet(hunk3, 1, object);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SYSTEM-HUNK3-SET-CXR2!", Prim_sh3_set_2, 2, 2, 0)
pub export fn Prim_sh3_set_2() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const hunk3 = argGcTriple(1);
    const object = abi.argRef(2);
    obj.memorySet(hunk3, 2, object);
    return obj.unspecific;
}

test "hunk3 and system-hunk3 primitives read and mutate triple fields" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{ obj.ulongToFixnum(10), obj.ulongToFixnum(20), obj.ulongToFixnum(30) });
    const h = Prim_hunk3_cons();
    try std.testing.expect(obj.hunk3P(h));

    stubs.setArgs(&.{ h, obj.ulongToFixnum(1) });
    try std.testing.expectEqual(obj.ulongToFixnum(20), Prim_hunk3_cxr());

    stubs.setArgs(&.{ h, obj.ulongToFixnum(2), obj.sharp_t });
    try std.testing.expectEqual(obj.unspecific, Prim_hunk3_set_cxr());

    stubs.setArgs(&.{ obj.ulongToFixnum(obj.tc_hunk3_a), obj.ulongToFixnum(1), obj.ulongToFixnum(2), obj.ulongToFixnum(3) });
    const sh = Prim_sys_hunk3_cons();

    stubs.setArgs(&.{sh});
    try std.testing.expectEqual(obj.ulongToFixnum(1), Prim_sys_h3_0());
    try std.testing.expectEqual(obj.ulongToFixnum(2), Prim_sys_h3_1());
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_sys_h3_2());

    stubs.setArgs(&.{ sh, obj.ulongToFixnum(99) });
    try std.testing.expectEqual(obj.unspecific, Prim_sh3_set_0());
    stubs.setArgs(&.{ sh, obj.ulongToFixnum(88) });
    try std.testing.expectEqual(obj.unspecific, Prim_sh3_set_1());
    stubs.setArgs(&.{ sh, obj.ulongToFixnum(77) });
    try std.testing.expectEqual(obj.unspecific, Prim_sh3_set_2());

    stubs.setArgs(&.{sh});
    try std.testing.expectEqual(obj.ulongToFixnum(99), Prim_sys_h3_0());
    try std.testing.expectEqual(obj.ulongToFixnum(88), Prim_sys_h3_1());
    try std.testing.expectEqual(obj.ulongToFixnum(77), Prim_sys_h3_2());
}
