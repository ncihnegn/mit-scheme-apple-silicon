// Derived from MIT/GNU Scheme C sources (`src/microcode/object.h`, `src/microcode/types.h`, `src/microcode/sdata.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

pub const SchemeObject = c_ulong;

pub const type_code_length = 6;
pub const datum_length: u6 = @as(comptime_int, @bitSizeOf(SchemeObject) - type_code_length);
pub const datum_mask: SchemeObject = (@as(SchemeObject, 1) << datum_length) - 1;

pub const tc_false: c_ulong = 0x00;
pub const tc_manifest_vector: c_ulong = tc_false;
pub const tc_manifest_nm_vector: c_ulong = 0x27;

pub const floating_alignment: usize = 0;

pub inline fn objectType(obj: SchemeObject) c_ulong {
    return obj >> datum_length;
}

pub inline fn objectDatum(obj: SchemeObject) c_ulong {
    return obj & datum_mask;
}

pub inline fn makeObject(tc: c_ulong, datum: c_ulong) SchemeObject {
    return (tc << datum_length) | datum;
}

pub inline fn makeVectorHeader(length: c_ulong) SchemeObject {
    return makeObject(tc_manifest_vector, length);
}

pub inline fn makeNmvHeader(length: c_ulong) SchemeObject {
    return makeObject(tc_manifest_nm_vector, length);
}

pub inline fn addressToDatum(addr: ?*const SchemeObject) c_ulong {
    return @intCast(@intFromPtr(addr));
}

pub inline fn floatingAlignedP(ptr: [*]const SchemeObject) bool {
    return ((@intFromPtr(ptr + 1)) & floating_alignment) == 0;
}

test "scheme_obj bit layout matches LP64 MIT/GNU Scheme tags" {
    if (@sizeOf(SchemeObject) == 8) {
        try std.testing.expectEqual(@as(u6, 58), datum_length);
        try std.testing.expectEqual(@as(SchemeObject, 0x03FF_FFFF_FFFF_FFFF), datum_mask);
        const v = makeVectorHeader(17);
        try std.testing.expectEqual(tc_manifest_vector, objectType(v));
        try std.testing.expectEqual(@as(c_ulong, 17), objectDatum(v));
        const nmv = makeNmvHeader(42);
        try std.testing.expectEqual(tc_manifest_nm_vector, objectType(nmv));
        try std.testing.expectEqual(@as(c_ulong, 42), objectDatum(nmv));
    }
}
