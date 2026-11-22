// Derived from MIT/GNU Scheme C sources (`src/microcode/edwin.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const obj = @import("../core/scheme_obj.zig");
const str = @import("../data/string.zig");

pub inline fn groupP(o: obj.SchemeObject) bool {
    return obj.vectorP(o);
}

pub inline fn groupText(group: obj.SchemeObject, len_r: ?*usize) [*]u8 {
    return str.string_to_char_pointer(obj.vectorRef(group, 1), len_r);
}

pub inline fn groupGapStart(group: obj.SchemeObject) usize {
    return obj.fixnumToUlong(obj.vectorRef(group, 2));
}

pub inline fn groupGapLength(group: obj.SchemeObject) usize {
    return obj.fixnumToUlong(obj.vectorRef(group, 3));
}

pub inline fn groupGapEnd(group: obj.SchemeObject) usize {
    return obj.fixnumToUlong(obj.vectorRef(group, 4));
}

pub inline fn groupStartMark(group: obj.SchemeObject) obj.SchemeObject {
    return obj.vectorRef(group, 6);
}

pub inline fn groupEndMark(group: obj.SchemeObject) obj.SchemeObject {
    return obj.vectorRef(group, 7);
}

pub inline fn markP(o: obj.SchemeObject) bool {
    return obj.recordP(o);
}

pub inline fn markIndex(mark: obj.SchemeObject) isize {
    return obj.unsignedFixnumToLong(obj.vectorRef(mark, 2));
}
