// Derived from MIT/GNU Scheme C sources (`src/microcode/string.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");

pub export fn string_p(object: obj.SchemeObject) callconv(.c) bool {
    return obj.legacyStringP(object) or
        obj.bytevectorP(object) or
        (obj.unicodeStringP(object) and obj.ustringBytesPerCp(object) == 1);
}

pub export fn allocate_string(nbytes: usize) callconv(.c) obj.SchemeObject {
    const result = abi.allocate_non_marked_vector(
        @intCast(obj.tc_character_string),
        obj.bytevectorLengthToGcLength(nbytes),
        true,
    );
    obj.setLegacyStringLength(result, nbytes);
    return result;
}

pub export fn allocate_string_no_gc(nbytes: usize) callconv(.c) obj.SchemeObject {
    const result = abi.allocate_non_marked_vector(
        @intCast(obj.tc_character_string),
        obj.bytevectorLengthToGcLength(nbytes),
        false,
    );
    obj.setLegacyStringLength(result, nbytes);
    return result;
}

pub export fn memory_to_string(n_bytes: usize, vp: ?*const anyopaque) callconv(.c) obj.SchemeObject {
    const result = allocate_string(n_bytes);
    if (n_bytes > 0) {
        const src: [*]const u8 = @ptrCast(vp.?);
        @memcpy(obj.legacyStringData(result)[0..@intCast(n_bytes)], src[0..@intCast(n_bytes)]);
    }
    return result;
}

pub export fn memory_to_string_no_gc(n_bytes: usize, vp: ?*const anyopaque) callconv(.c) obj.SchemeObject {
    const result = allocate_string_no_gc(n_bytes);
    if (n_bytes > 0) {
        const src: [*]const u8 = @ptrCast(vp.?);
        @memcpy(obj.legacyStringData(result)[0..@intCast(n_bytes)], src[0..@intCast(n_bytes)]);
    }
    return result;
}

pub export fn char_pointer_to_string(cp: ?[*:0]const u8) callconv(.c) obj.SchemeObject {
    const len: usize = if (cp) |p| @intCast(std.mem.len(p)) else 0;
    return memory_to_string(len, cp);
}

pub export fn char_pointer_to_string_no_gc(cp: ?[*:0]const u8) callconv(.c) obj.SchemeObject {
    const len: usize = if (cp) |p| @intCast(std.mem.len(p)) else 0;
    return memory_to_string_no_gc(len, cp);
}

pub export fn string_to_char_pointer(string: obj.SchemeObject, lp: ?*usize) callconv(.c) [*]u8 {
    if (lp) |out| out.* = obj.legacyStringLength(string);
    return obj.legacyStringLoc(string, 0);
}

// DEFINE_PRIMITIVE ("STRING-ALLOCATE", Prim_string_allocate, 1, 1, 0)
pub export fn Prim_string_allocate() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return allocate_string(@intCast(abi.arg_nonnegative_integer(1)));
}

// DEFINE_PRIMITIVE ("STRING?", Prim_string_p, 1, 1, 0)
pub export fn Prim_string_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(string_p(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("STRING-LENGTH", Prim_string_length, 1, 1, 0)
pub export fn Prim_string_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    return obj.longToUnsignedFixnum(@intCast(obj.legacyStringLength(abi.argRef(1))));
}

// DEFINE_PRIMITIVE ("STRING-MAXIMUM-LENGTH", Prim_string_maximum_length, 1, 1, 0)
pub export fn Prim_string_maximum_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    return obj.longToUnsignedFixnum(@intCast(obj.legacyStringMaxLength(abi.argRef(1))));
}

// DEFINE_PRIMITIVE ("SET-STRING-LENGTH!", Prim_set_string_length, 2, 2, 0)
pub export fn Prim_set_string_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    const str = abi.argRef(1);
    const max_len: isize = @intCast(obj.legacyStringMaxLength(str));
    obj.setLegacyStringLength(str, @intCast(abi.arg_index_integer(2, max_len + 1)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SET-STRING-MAXIMUM-LENGTH!", Prim_set_string_maximum_length, 2, 2, 0)
pub export fn Prim_set_string_maximum_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    const str = abi.argRef(1);
    const max_len: isize = @intCast(obj.legacyStringMaxLength(str));
    const length: usize = @intCast(abi.arg_index_integer(2, max_len + 1));
    if (length < obj.legacyStringLength(str)) {
        obj.setLegacyStringLength(str, length);
    }
    obj.setLegacyStringMaxLength(str, length);
    return obj.unspecific;
}

fn stringRefIndex() u8 {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    const str = abi.argRef(1);
    const idx = abi.arg_index_integer(2, @intCast(obj.legacyStringLength(str)));
    return obj.legacyStringRef(str, @intCast(idx));
}

// DEFINE_PRIMITIVE ("STRING-REF", Prim_string_ref, 2, 2, 0)
pub export fn Prim_string_ref() callconv(.c) obj.SchemeObject {
    return obj.asciiToChar(stringRefIndex());
}

// DEFINE_PRIMITIVE ("VECTOR-8B-REF", Prim_vec_8b_ref, 2, 2, 0)
pub export fn Prim_vec_8b_ref() callconv(.c) obj.SchemeObject {
    return obj.longToUnsignedFixnum(stringRefIndex());
}

fn stringSetImpl(comptime getAsciiFn: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    const str = abi.argRef(1);
    const idx = abi.arg_index_integer(2, @intCast(obj.legacyStringLength(str)));
    const ch: u8 = @truncate(@as(usize, @bitCast(getAsciiFn(3))));
    obj.legacyStringSet(str, @intCast(idx), ch);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("STRING-SET!", Prim_string_set, 3, 3, 0)
pub export fn Prim_string_set() callconv(.c) obj.SchemeObject {
    return stringSetImpl(abi.arg_ascii_char);
}

// DEFINE_PRIMITIVE ("VECTOR-8B-SET!", Prim_vec_8b_set, 3, 3, 0)
pub export fn Prim_vec_8b_set() callconv(.c) obj.SchemeObject {
    return stringSetImpl(abi.arg_ascii_integer);
}

const SubstringMoveArgs = struct {
    ptr1: [*]u8,
    ptr2: [*]u8,
    start1: usize,
    end1: usize,
    start2: usize,
    end2: usize,
    length: usize,
};

fn substringMovePrefix() SubstringMoveArgs {
    abi.primitiveHeader();
    var len1: usize = undefined;
    var len2: usize = undefined;
    const ptr1 = arg_extended_string(1, &len1);
    const end1 = abi.arg_ulong_index_integer(3, len1 + 1);
    const start1 = abi.arg_ulong_index_integer(2, end1 + 1);
    const ptr2 = arg_extended_string(4, &len2);
    const start2 = abi.arg_ulong_index_integer(5, len2 + 1);
    const length = end1 - start1;
    const end2 = start2 + length;
    if (end2 > len2) abi.error_bad_range_arg(5);
    return .{
        .ptr1 = ptr1,
        .ptr2 = ptr2,
        .start1 = @intCast(start1),
        .end1 = @intCast(end1),
        .start2 = @intCast(start2),
        .end2 = @intCast(end2),
        .length = @intCast(length),
    };
}

// DEFINE_PRIMITIVE ("SUBSTRING-MOVE-RIGHT!", Prim_substring_move_right, 5, 5, 0)
pub export fn Prim_substring_move_right() callconv(.c) obj.SchemeObject {
    const a = substringMovePrefix();
    var i = a.length;
    while (i > 0) {
        i -= 1;
        a.ptr2[a.start2 + i] = a.ptr1[a.start1 + i];
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SUBSTRING-MOVE-LEFT!", Prim_substring_move_left, 5, 5, 0)
pub export fn Prim_substring_move_left() callconv(.c) obj.SchemeObject {
    const a = substringMovePrefix();
    for (0..a.length) |i| {
        a.ptr2[a.start2 + i] = a.ptr1[a.start1 + i];
    }
    return obj.unspecific;
}

fn substringModify(comptime charMap: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    const str = abi.argRef(1);
    const start: usize = @intCast(abi.arg_nonnegative_integer(2));
    const end: usize = @intCast(abi.arg_nonnegative_integer(3));
    if (end > obj.legacyStringLength(str)) abi.error_bad_range_arg(3);
    if (start > end) abi.error_bad_range_arg(2);
    const scan = obj.legacyStringLoc(str, @intCast(start));
    const len: usize = @intCast(end - start);
    for (scan[0..len]) |*slot| {
        slot.* = @truncate(@as(usize, @bitCast(charMap(@as(isize, slot.*)))));
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SUBSTRING-UPCASE!", Prim_substring_upcase, 3, 3, 0)
pub export fn Prim_substring_upcase() callconv(.c) obj.SchemeObject {
    return substringModify(abi.char_upcase);
}

// DEFINE_PRIMITIVE ("SUBSTRING-DOWNCASE!", Prim_substring_downcase, 3, 3, 0)
pub export fn Prim_substring_downcase() callconv(.c) obj.SchemeObject {
    return substringModify(abi.char_downcase);
}

fn vec8bSubstringPrefix() struct { ptr: [*]u8, start: usize, end: usize, ascii: u8 } {
    abi.primitiveHeader();
    var length: usize = undefined;
    const ptr = arg_extended_string(1, &length);
    const start: usize = @intCast(abi.arg_nonnegative_integer(2));
    const end: usize = @intCast(abi.arg_nonnegative_integer(3));
    const ascii: u8 = @truncate(@as(usize, @bitCast(abi.arg_ascii_integer(4))));
    if (end > length) abi.error_bad_range_arg(3);
    if (start > end) abi.error_bad_range_arg(2);
    return .{
        .ptr = ptr,
        .start = @intCast(start),
        .end = @intCast(end),
        .ascii = ascii,
    };
}

// DEFINE_PRIMITIVE ("VECTOR-8B-FILL!", Prim_vec_8b_fill, 4, 4, 0)
pub export fn Prim_vec_8b_fill() callconv(.c) obj.SchemeObject {
    const a = vec8bSubstringPrefix();
    @memset(a.ptr[a.start..a.end], a.ascii);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("VECTOR-8B-FIND-NEXT-CHAR", Prim_vec_8b_find_next_char, 4, 4, 0)
pub export fn Prim_vec_8b_find_next_char() callconv(.c) obj.SchemeObject {
    const a = vec8bSubstringPrefix();
    for (a.start..a.end) |i| {
        if (a.ptr[i] == a.ascii) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("VECTOR-8B-FIND-PREVIOUS-CHAR", Prim_vec_8b_find_prev_char, 4, 4, 0)
pub export fn Prim_vec_8b_find_prev_char() callconv(.c) obj.SchemeObject {
    const a = vec8bSubstringPrefix();
    var i = a.end;
    while (i > a.start) {
        i -= 1;
        if (a.ptr[i] == a.ascii) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.sharp_f;
}

inline fn asciiUpcaseByte(c: u8) u8 {
    return @truncate(@as(usize, @bitCast(abi.char_upcase(@as(isize, c)))));
}

// DEFINE_PRIMITIVE ("VECTOR-8B-FIND-NEXT-CHAR-CI", Prim_vec_8b_find_next_char_ci, 4, 4, 0)
pub export fn Prim_vec_8b_find_next_char_ci() callconv(.c) obj.SchemeObject {
    const a = vec8bSubstringPrefix();
    const target = asciiUpcaseByte(a.ascii);
    for (a.start..a.end) |i| {
        if (asciiUpcaseByte(a.ptr[i]) == target) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("VECTOR-8B-FIND-PREVIOUS-CHAR-CI", Prim_vec_8b_find_prev_char_ci, 4, 4, 0)
pub export fn Prim_vec_8b_find_prev_char_ci() callconv(.c) obj.SchemeObject {
    const a = vec8bSubstringPrefix();
    const target = asciiUpcaseByte(a.ascii);
    var i = a.end;
    while (i > a.start) {
        i -= 1;
        if (asciiUpcaseByte(a.ptr[i]) == target) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.sharp_f;
}

fn substrFindCharInSetPrefix() struct { ptr: [*]const u8, start: usize, end: usize, char_set: [*]const u8 } {
    abi.primitiveHeader();
    var length: usize = undefined;
    const ptr = arg_extended_string(1, &length);
    const start: usize = @intCast(abi.arg_nonnegative_integer(2));
    const end: usize = @intCast(abi.arg_nonnegative_integer(3));
    abi.checkArg(4, string_p);
    const cs_obj = abi.argRef(4);
    const char_set = obj.legacyStringLoc(cs_obj, 0);
    if (end > length) abi.error_bad_range_arg(3);
    if (start > end) abi.error_bad_range_arg(2);
    if (obj.legacyStringLength(cs_obj) != obj.max_ascii) abi.error_bad_range_arg(4);
    return .{
        .ptr = ptr,
        .start = @intCast(start),
        .end = @intCast(end),
        .char_set = char_set,
    };
}

// DEFINE_PRIMITIVE ("SUBSTRING-FIND-NEXT-CHAR-IN-SET", Prim_find_next_char_in_set, 4, 4, 0)
pub export fn Prim_find_next_char_in_set() callconv(.c) obj.SchemeObject {
    const a = substrFindCharInSetPrefix();
    for (a.start..a.end) |i| {
        if (a.char_set[a.ptr[i]] != 0) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("SUBSTRING-FIND-PREVIOUS-CHAR-IN-SET", Prim_find_prev_char_in_set, 4, 4, 0)
pub export fn Prim_find_prev_char_in_set() callconv(.c) obj.SchemeObject {
    const a = substrFindCharInSetPrefix();
    var i = a.end;
    while (i > a.start) {
        i -= 1;
        if (a.char_set[a.ptr[i]] != 0) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.sharp_f;
}

const SubstringCmpArgs = struct {
    s1: [*]const u8,
    s2: [*]const u8,
    start1: usize,
    end1: usize,
    start2: usize,
    end2: usize,
};

fn substringComparePrefix() SubstringCmpArgs {
    abi.primitiveHeader();
    abi.checkArg(1, string_p);
    const obj1 = abi.argRef(1);
    const s1 = obj.legacyStringLoc(obj1, 0);
    const start1: usize = @intCast(abi.arg_nonnegative_integer(2));
    const end1: usize = @intCast(abi.arg_nonnegative_integer(3));
    abi.checkArg(4, string_p);
    const obj2 = abi.argRef(4);
    const s2 = obj.legacyStringLoc(obj2, 0);
    const start2: usize = @intCast(abi.arg_nonnegative_integer(5));
    const end2: usize = @intCast(abi.arg_nonnegative_integer(6));
    if (end1 > obj.legacyStringLength(obj1)) abi.error_bad_range_arg(3);
    if (start1 > end1) abi.error_bad_range_arg(2);
    if (end2 > obj.legacyStringLength(obj2)) abi.error_bad_range_arg(6);
    if (start2 > end2) abi.error_bad_range_arg(5);
    return .{
        .s1 = s1,
        .s2 = s2,
        .start1 = @intCast(start1),
        .end1 = @intCast(end1),
        .start2 = @intCast(start2),
        .end2 = @intCast(end2),
    };
}

// DEFINE_PRIMITIVE ("SUBSTRING=?", Prim_substring_equal, 6, 6, 0)
pub export fn Prim_substring_equal() callconv(.c) obj.SchemeObject {
    const a = substringComparePrefix();
    const len1 = a.end1 - a.start1;
    const len2 = a.end2 - a.start2;
    if (len1 != len2) return obj.sharp_f;
    return obj.booleanToObject(std.mem.eql(u8, a.s1[a.start1..a.end1], a.s2[a.start2..a.end2]));
}

// DEFINE_PRIMITIVE ("SUBSTRING-CI=?", Prim_substring_ci_equal, 6, 6, 0)
pub export fn Prim_substring_ci_equal() callconv(.c) obj.SchemeObject {
    const a = substringComparePrefix();
    const len1 = a.end1 - a.start1;
    const len2 = a.end2 - a.start2;
    if (len1 != len2) return obj.sharp_f;
    for (0..len1) |i| {
        if (asciiUpcaseByte(a.s1[a.start1 + i]) != asciiUpcaseByte(a.s2[a.start2 + i])) {
            return obj.sharp_f;
        }
    }
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("SUBSTRING<?", Prim_substring_less, 6, 6, 0)
pub export fn Prim_substring_less() callconv(.c) obj.SchemeObject {
    const a = substringComparePrefix();
    const len1 = a.end1 - a.start1;
    const len2 = a.end2 - a.start2;
    const limit = @min(len1, len2);
    for (0..limit) |i| {
        const c1 = a.s1[a.start1 + i];
        const c2 = a.s2[a.start2 + i];
        if (c1 != c2) return obj.booleanToObject(c1 < c2);
    }
    return obj.booleanToObject(len1 < len2);
}

fn matchForwardImpl(comptime ci: bool) obj.SchemeObject {
    const a = substringComparePrefix();
    const length = @min(a.end1 - a.start1, a.end2 - a.start2);
    for (0..length) |i| {
        const c1 = a.s1[a.start1 + i];
        const c2 = a.s2[a.start2 + i];
        const same = if (ci) asciiUpcaseByte(c1) == asciiUpcaseByte(c2) else c1 == c2;
        if (!same) return obj.longToUnsignedFixnum(@intCast(i));
    }
    return obj.longToUnsignedFixnum(@intCast(length));
}

fn matchBackwardImpl(comptime ci: bool) obj.SchemeObject {
    const a = substringComparePrefix();
    const length = @min(a.end1 - a.start1, a.end2 - a.start2);
    for (0..length) |matched| {
        const c1 = a.s1[a.end1 - 1 - matched];
        const c2 = a.s2[a.end2 - 1 - matched];
        const same = if (ci) asciiUpcaseByte(c1) == asciiUpcaseByte(c2) else c1 == c2;
        if (!same) return obj.longToUnsignedFixnum(@intCast(matched));
    }
    return obj.longToUnsignedFixnum(@intCast(length));
}

// DEFINE_PRIMITIVE ("SUBSTRING-MATCH-FORWARD", Prim_match_forward, 6, 6, 0)
pub export fn Prim_match_forward() callconv(.c) obj.SchemeObject {
    return matchForwardImpl(false);
}

// DEFINE_PRIMITIVE ("SUBSTRING-MATCH-FORWARD-CI", Prim_match_forward_ci, 6, 6, 0)
pub export fn Prim_match_forward_ci() callconv(.c) obj.SchemeObject {
    return matchForwardImpl(true);
}

// DEFINE_PRIMITIVE ("SUBSTRING-MATCH-BACKWARD", Prim_match_backward, 6, 6, 0)
pub export fn Prim_match_backward() callconv(.c) obj.SchemeObject {
    return matchBackwardImpl(false);
}

// DEFINE_PRIMITIVE ("SUBSTRING-MATCH-BACKWARD-CI", Prim_match_backward_ci, 6, 6, 0)
pub export fn Prim_match_backward_ci() callconv(.c) obj.SchemeObject {
    return matchBackwardImpl(true);
}

// External strings

const HtRecord = extern struct {
    next: ?*HtRecord,
    n_bytes: usize,
};

const HashTable = struct {
    n_records: usize,
    n_buckets: usize,
    buckets: [*]?*HtRecord,
};

const ht_min_expt: u5 = 4;
const ht_max_expt: u5 = 24;

inline fn exptToN(e: u5) usize {
    return (@as(usize, 1) << e) - 1;
}

inline fn htRecordPtr(rec: *HtRecord) [*]u8 {
    return @ptrCast(@as([*]HtRecord, @ptrCast(rec)) + 1);
}

inline fn htRecordKey(rec: *HtRecord) usize {
    return @intCast(@intFromPtr(htRecordPtr(rec)));
}

var external_strings: ?*HashTable = null;

fn zeroHtBuckets(table: *HashTable) void {
    const n: usize = @intCast(table.n_buckets);
    @memset(table.buckets[0..n], null);
}

fn ensureExternalStringsTable() *HashTable {
    if (external_strings) |tbl| return tbl;
    const n = exptToN(ht_min_expt);
    const tbl: *HashTable = @ptrCast(@alignCast(std.c.malloc(@sizeOf(HashTable)) orelse @panic("external strings table OOM")));
    const buckets_bytes: usize = @as(usize, @intCast(n)) * @sizeOf(?*HtRecord);
    const buckets: [*]?*HtRecord = @ptrCast(@alignCast(std.c.malloc(buckets_bytes) orelse @panic("external strings buckets OOM")));
    tbl.* = .{
        .n_records = 0,
        .n_buckets = n,
        .buckets = buckets,
    };
    zeroHtBuckets(tbl);
    external_strings = tbl;
    return tbl;
}

fn htRecordsList(table: *HashTable) ?*HtRecord {
    const n: usize = @intCast(table.n_buckets);
    var result: ?*HtRecord = null;
    for (table.buckets[0..n]) |*slot| {
        var scan = slot.*;
        while (scan) |rec| {
            const next = rec.next;
            rec.next = result;
            result = rec;
            scan = next;
        }
        slot.* = null;
    }
    return result;
}

fn htInsertRaw(table: *HashTable, rec: *HtRecord) usize {
    const key = htRecordKey(rec);
    const index: usize = @intCast(key % table.n_buckets);
    rec.next = null;
    if (table.buckets[index] == null) {
        table.buckets[index] = rec;
    } else {
        var scan = table.buckets[index].?;
        while (scan.next) |nxt| scan = nxt;
        scan.next = rec;
    }
    table.n_records += 1;
    return key;
}

fn htResize(table: *HashTable, new_n_buckets: usize) void {
    const new_bytes: usize = @as(usize, @intCast(new_n_buckets)) * @sizeOf(?*HtRecord);
    const new_raw = std.c.malloc(new_bytes) orelse return;
    const new_buckets: [*]?*HtRecord = @ptrCast(@alignCast(new_raw));
    const old_buckets = table.buckets;
    var records = htRecordsList(table);
    table.buckets = new_buckets;
    table.n_buckets = new_n_buckets;
    table.n_records = 0;
    zeroHtBuckets(table);
    while (records) |rec| {
        const next = rec.next;
        _ = htInsertRaw(table, rec);
        records = next;
    }
    std.c.free(@ptrCast(old_buckets));
}

fn htLookup(table: *HashTable, key: usize) ?*HtRecord {
    const index: usize = @intCast(key % table.n_buckets);
    var rec = table.buckets[index];
    while (rec) |r| {
        if (htRecordKey(r) == key) return r;
        rec = r.next;
    }
    return null;
}

fn htInsert(table: *HashTable, rec: *HtRecord) usize {
    const key = htInsertRaw(table, rec);
    if (table.n_records >= table.n_buckets and table.n_buckets < exptToN(ht_max_expt)) {
        for (ht_min_expt..@as(usize, ht_max_expt) + 1) |eu| {
            const n = exptToN(@intCast(eu));
            if (n > table.n_buckets) {
                htResize(table, n);
                break;
            }
        }
    }
    return key;
}

fn htDelete(table: *HashTable, key: usize) ?*HtRecord {
    const index: usize = @intCast(key % table.n_buckets);
    var scan = table.buckets[index];
    var prev: ?*HtRecord = null;
    while (scan) |r| {
        if (htRecordKey(r) == key) {
            if (prev) |p| {
                p.next = r.next;
            } else {
                table.buckets[index] = r.next;
            }
            table.n_records -= 1;
            const shrink_point = ((table.n_buckets + 1) / 2) - 1;
            if (table.n_records < shrink_point and table.n_buckets > exptToN(ht_min_expt)) {
                var e: u5 = ht_max_expt;
                while (e >= ht_min_expt) : (e -= 1) {
                    const n = exptToN(e);
                    if (n < table.n_buckets) {
                        htResize(table, n);
                        break;
                    }
                    if (e == ht_min_expt) break;
                }
            }
            return r;
        }
        prev = r;
        scan = r.next;
    }
    return null;
}

// DEFINE_PRIMITIVE ("ALLOCATE-EXTERNAL-STRING", Prim_alloc_external_string, 1, 1, 0)
pub export fn Prim_alloc_external_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n_bytes = abi.arg_ulong_integer(1);
    const n_usize = std.math.cast(usize, n_bytes) orelse abi.error_bad_range_arg(1);
    const size_plus_1 = std.math.add(usize, n_usize, 1) catch abi.error_bad_range_arg(1);
    const total_bytes = std.math.add(usize, size_plus_1, @sizeOf(HtRecord)) catch abi.error_bad_range_arg(1);
    const raw = std.c.malloc(total_bytes) orelse abi.error_bad_range_arg(1);
    const rec: *HtRecord = @ptrCast(@alignCast(raw));
    const tbl = ensureExternalStringsTable();
    rec.n_bytes = n_bytes;
    htRecordPtr(rec)[n_usize] = 0;
    return artutl.ulong_to_integer(htInsert(tbl, rec));
}

// DEFINE_PRIMITIVE ("EXTERNAL-STRING?", Prim_external_string_p, 1, 1, 0)
pub export fn Prim_external_string_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    if (obj.integerP(x) and artutl.integer_to_ulong_p(x)) {
        const tbl = ensureExternalStringsTable();
        const rec = htLookup(tbl, artutl.integer_to_ulong(x));
        return obj.booleanToObject(rec != null);
    }
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("DEALLOCATE-EXTERNAL-STRING", Prim_dealloc_external_string, 1, 1, 0)
pub export fn Prim_dealloc_external_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n = abi.arg_ulong_integer(1);
    const tbl = ensureExternalStringsTable();
    const rec = htDelete(tbl, n) orelse abi.error_wrong_type_arg(1);
    std.c.free(@ptrCast(rec));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("EXTENDED-STRING-LENGTH", Prim_extended_string_length, 1, 1, 0)
pub export fn Prim_extended_string_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var len: usize = undefined;
    _ = arg_extended_string(1, &len);
    return artutl.ulong_to_integer(len);
}

pub export fn lookup_external_string(descriptor: obj.SchemeObject, lp: ?*usize) callconv(.c) ?[*]u8 {
    const tbl = ensureExternalStringsTable();
    const rec = htLookup(tbl, artutl.integer_to_ulong(descriptor)) orelse return null;
    if (lp) |out| out.* = rec.n_bytes;
    return htRecordPtr(rec);
}

pub export fn arg_extended_string(n: c_uint, lp: ?*usize) callconv(.c) [*]u8 {
    const object = abi.argRef(@intCast(n));
    if (string_p(object)) {
        if (lp) |out| out.* = obj.legacyStringLength(object);
        return obj.legacyStringData(object);
    } else if (obj.integerP(object) and artutl.integer_to_ulong_p(object)) {
        return lookup_external_string(object, lp) orelse abi.error_wrong_type_arg(@intCast(n));
    } else {
        abi.error_wrong_type_arg(@intCast(n));
    }
}

test "string_p, allocation, overlapping moves, ci compare/search, and external strings" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // string_p accepts legacy strings, bytevectors, and 1-byte unicode strings only
    const s = char_pointer_to_string("HeLLo");
    try std.testing.expect(string_p(s));
    try std.testing.expectEqual(@as(usize, 5), obj.legacyStringLength(s));
    try std.testing.expectEqual(@as(u8, 0), obj.legacyStringRef(s, 5));
    const empty_s = char_pointer_to_string(null);
    try std.testing.expect(string_p(empty_s));
    try std.testing.expectEqual(@as(usize, 0), obj.legacyStringLength(empty_s));

    const bv = abi.allocate_bytevector(4);
    try std.testing.expect(string_p(bv));

    // 1-byte unicode string accepted; 2-byte unicode string rejected
    const u1_str = abi.allocate_non_marked_vector(@intCast(obj.tc_unicode_string), 2, true);
    obj.setNmVectorSubheader(u1_str, obj.makeObject(1, 2));
    try std.testing.expect(string_p(u1_str));
    const u2_str = abi.allocate_non_marked_vector(@intCast(obj.tc_unicode_string), 2, true);
    obj.setNmVectorSubheader(u2_str, obj.makeObject(2, 2));
    try std.testing.expect(!string_p(u2_str));

    // Overlapping move-left and move-right
    const buf = char_pointer_to_string("abcdef");
    stubs.setArgs(&.{ buf, obj.ulongToFixnum(0), obj.ulongToFixnum(4), buf, obj.ulongToFixnum(2) });
    _ = Prim_substring_move_right();
    try std.testing.expectEqualStrings("ababcd", obj.legacyStringData(buf)[0..6]);

    stubs.setArgs(&.{ buf, obj.ulongToFixnum(2), obj.ulongToFixnum(6), buf, obj.ulongToFixnum(0) });
    _ = Prim_substring_move_left();
    try std.testing.expectEqualStrings("abcdcd", obj.legacyStringData(buf)[0..6]);

    // CI equality, ordering, forward/backward match, char-set search
    const lower = char_pointer_to_string("hello");
    stubs.setArgs(&.{ s, obj.ulongToFixnum(0), obj.ulongToFixnum(5), lower, obj.ulongToFixnum(0), obj.ulongToFixnum(5) });
    try std.testing.expectEqual(obj.sharp_t, Prim_substring_ci_equal());
    stubs.setArgs(&.{ s, obj.ulongToFixnum(0), obj.ulongToFixnum(5), lower, obj.ulongToFixnum(0), obj.ulongToFixnum(5) });
    try std.testing.expectEqual(obj.sharp_t, Prim_substring_less()); // 'H' < 'h'

    stubs.setArgs(&.{ s, obj.ulongToFixnum(0), obj.ulongToFixnum(5), obj.ulongToFixnum('l') });
    try std.testing.expectEqual(obj.ulongToFixnum(2), Prim_vec_8b_find_next_char_ci());
    stubs.setArgs(&.{ s, obj.ulongToFixnum(0), obj.ulongToFixnum(5), obj.ulongToFixnum('l') });
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_vec_8b_find_prev_char_ci());

    // External string allocate, resize (>15 buckets), lookup, deallocate
    var descs: [20]obj.SchemeObject = undefined;
    for (&descs, 0..) |*slot, idx| {
        stubs.setArgs(&.{obj.ulongToFixnum(@intCast(idx + 4))});
        const ext = Prim_alloc_external_string();
        slot.* = ext;
        stubs.setArgs(&.{ext});
        try std.testing.expectEqual(obj.sharp_t, Prim_external_string_p());
        stubs.setArgs(&.{ext});
        try std.testing.expectEqual(obj.ulongToFixnum(@intCast(idx + 4)), Prim_extended_string_length());
    }
    var ext_len: usize = 0;
    const ext_ptr = lookup_external_string(descs[0], &ext_len).?;
    try std.testing.expectEqual(@as(usize, 4), ext_len);
    ext_ptr[0] = 'X';
    stubs.setArgs(&.{ descs[0], obj.ulongToFixnum(0), obj.ulongToFixnum(1), lower, obj.ulongToFixnum(1) });
    _ = Prim_substring_move_left();
    try std.testing.expectEqual(@as(u8, 'X'), obj.legacyStringRef(lower, 1));

    for (descs) |ext| {
        stubs.setArgs(&.{ext});
        _ = Prim_dealloc_external_string();
        stubs.setArgs(&.{ext});
        try std.testing.expectEqual(obj.sharp_f, Prim_external_string_p());
    }
}
