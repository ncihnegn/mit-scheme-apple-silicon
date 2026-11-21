// Derived from MIT/GNU Scheme C sources (`src/microcode/rgxprim.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");
const str = @import("string.zig");
const syntax = @import("syntax.zig");
const edwin = @import("edwin_defs.zig");
const regex = @import("regex.zig");

inline fn reCharSetP(o: obj.SchemeObject) bool {
    return str.string_p(o) and obj.legacyStringLength(o) == (obj.max_ascii / obj.ascii_length);
}

inline fn charSetP(o: obj.SchemeObject) bool {
    return str.string_p(o) and obj.legacyStringLength(o) == obj.max_ascii;
}

inline fn charTranslationP(o: obj.SchemeObject) bool {
    return str.string_p(o) and obj.legacyStringLength(o) == obj.max_ascii;
}

inline fn reRegistersP(o: obj.SchemeObject) bool {
    return o == obj.sharp_f or (obj.vectorP(o) and obj.vectorLength(o) == (regex.re_nregs * 2));
}

fn finishReMatchResult(result: c_int, vec: obj.SchemeObject, regs: *const regex.ReRegisters) obj.SchemeObject {
    if (result >= 0) {
        if (vec != obj.sharp_f) {
            for (0..regex.re_nregs) |i| {
                const s_idx = regs.start[i];
                obj.vectorSet(vec, i, if (s_idx == -1) obj.sharp_f else artutl.long_to_integer(s_idx));
                const e_idx = regs.end[i];
                obj.vectorSet(vec, i + regex.re_nregs, if (e_idx == -1) obj.sharp_f else artutl.long_to_integer(e_idx));
            }
        }
        return artutl.long_to_integer(result);
    }
    if (result == -1 or result == -4) return obj.sharp_f;
    if (result == -2) abi.error_bad_range_arg(1);
    abi.error_external_return();
}

// DEFINE_PRIMITIVE ("RE-CHAR-SET-ADJOIN!", Prim_re_char_set_adjoin, 2, 2, 0)
pub export fn Prim_re_char_set_adjoin() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, reCharSetP);
    const ascii: c_ulong = @bitCast(abi.arg_ascii_integer(2));
    const byte_ptr = obj.legacyStringLoc(abi.argRef(1), @intCast(ascii / obj.ascii_length));
    byte_ptr[0] |= @as(u8, 1) << @intCast(ascii % obj.ascii_length);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("RE-COMPILE-FASTMAP", Prim_re_compile_fastmap, 4, 4, 0)
pub export fn Prim_re_compile_fastmap() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const pattern = abi.argRef(1);
    abi.checkArg(2, charTranslationP);
    abi.checkArg(3, syntax.syntaxTableP);
    abi.checkArg(4, charSetP);
    const pat_len: usize = @intCast(obj.legacyStringLength(pattern));
    const pat_start = obj.legacyStringLoc(pattern, 0);
    const can_be_null = regex.re_compile_fastmap(
        pat_start,
        pat_start + pat_len,
        obj.legacyStringLoc(abi.argRef(2), 0),
        abi.argRef(3),
        obj.legacyStringLoc(abi.argRef(4), 0),
    );
    if (can_be_null >= 0) return artutl.long_to_integer(can_be_null);
    if (can_be_null == -2) abi.error_bad_range_arg(1);
    abi.error_external_return();
}

const ReSearchFn = *const fn ([*]u8, [*]u8, *regex.ReBuffer, ?*regex.ReRegisters, [*]const u8, [*]const u8) callconv(.c) c_int;

fn reSubstringPrimitive(comptime proc: ReSearchFn) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const regexp = abi.argRef(1);
    abi.checkArg(2, charTranslationP);
    abi.checkArg(3, syntax.syntaxTableP);
    abi.checkArg(4, reRegistersP);
    abi.checkArg(5, str.string_p);
    const match_start: c_ulong = @intCast(abi.arg_nonnegative_integer(6));
    const match_end: c_ulong = @intCast(abi.arg_nonnegative_integer(7));
    const text_obj = abi.argRef(5);
    const text = obj.legacyStringLoc(text_obj, 0);
    const text_end = obj.legacyStringLength(text_obj);
    if (match_end > text_end) abi.error_bad_range_arg(7);
    if (match_start > match_end) abi.error_bad_range_arg(6);

    regex.re_max_failures = 20000;
    var buffer: regex.ReBuffer = undefined;
    var registers: regex.ReRegisters = undefined;
    regex.re_buffer_initialize(
        &buffer,
        obj.legacyStringLoc(abi.argRef(2), 0),
        abi.argRef(3),
        text,
        0,
        text_end,
        text_end,
        text_end,
    );
    const pat_start = obj.legacyStringLoc(regexp, 0);
    const pat_end = obj.legacyStringLoc(regexp, @intCast(obj.legacyStringLength(regexp)));
    const regs_arg = abi.argRef(4);
    const regs_ptr: ?*regex.ReRegisters = if (regs_arg == obj.sharp_f) null else &registers;
    const res = proc(
        pat_start,
        pat_end,
        &buffer,
        regs_ptr,
        text + @as(usize, @intCast(match_start)),
        text + @as(usize, @intCast(match_end)),
    );
    return finishReMatchResult(res, regs_arg, &registers);
}

fn reBufferPrimitive(comptime proc: ReSearchFn) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const regexp = abi.argRef(1);
    abi.checkArg(2, charTranslationP);
    abi.checkArg(3, syntax.syntaxTableP);
    abi.checkArg(4, reRegistersP);
    abi.checkArg(5, edwin.groupP);
    const group = abi.argRef(5);
    var match_start: c_ulong = @intCast(abi.arg_nonnegative_integer(6));
    var match_end: c_ulong = @intCast(abi.arg_nonnegative_integer(7));
    const text = edwin.groupText(group, null);
    const text_start: c_ulong = @intCast(edwin.markIndex(edwin.groupStartMark(group)));
    var text_end: c_ulong = @intCast(edwin.markIndex(edwin.groupEndMark(group)));
    const gap_start = edwin.groupGapStart(group);
    const gap_length = edwin.groupGapLength(group);
    if (text_end > gap_start) text_end += gap_length;
    if (match_end > gap_start) {
        match_end += gap_length;
        if (match_start >= gap_start) match_start += gap_length;
    }
    if (match_start > match_end) abi.error_bad_range_arg(6);
    if (match_end > text_end) abi.error_bad_range_arg(7);
    if (match_start < text_start) abi.error_bad_range_arg(6);

    regex.re_max_failures = 20000;
    var buffer: regex.ReBuffer = undefined;
    var registers: regex.ReRegisters = undefined;
    regex.re_buffer_initialize(
        &buffer,
        obj.legacyStringLoc(abi.argRef(2), 0),
        abi.argRef(3),
        text,
        text_start,
        text_end,
        gap_start,
        edwin.groupGapEnd(group),
    );
    const pat_start = obj.legacyStringLoc(regexp, 0);
    const pat_end = obj.legacyStringLoc(regexp, @intCast(obj.legacyStringLength(regexp)));
    const regs_arg = abi.argRef(4);
    const regs_ptr: ?*regex.ReRegisters = if (regs_arg == obj.sharp_f) null else &registers;
    const res = proc(
        pat_start,
        pat_end,
        &buffer,
        regs_ptr,
        text + @as(usize, @intCast(match_start)),
        text + @as(usize, @intCast(match_end)),
    );
    return finishReMatchResult(res, regs_arg, &registers);
}

// DEFINE_PRIMITIVE ("RE-MATCH-SUBSTRING", Prim_re_match_substring, 7, 7, 0)
pub export fn Prim_re_match_substring() callconv(.c) obj.SchemeObject {
    return reSubstringPrimitive(regex.re_match);
}

// DEFINE_PRIMITIVE ("RE-SEARCH-SUBSTRING-FORWARD", Prim_re_search_substr_forward, 7, 7, 0)
pub export fn Prim_re_search_substr_forward() callconv(.c) obj.SchemeObject {
    return reSubstringPrimitive(regex.re_search_forward);
}

// DEFINE_PRIMITIVE ("RE-SEARCH-SUBSTRING-BACKWARD", Prim_re_search_substr_backward, 7, 7, 0)
pub export fn Prim_re_search_substr_backward() callconv(.c) obj.SchemeObject {
    return reSubstringPrimitive(regex.re_search_backward);
}

// DEFINE_PRIMITIVE ("RE-MATCH-BUFFER", Prim_re_match_buffer, 7, 7, 0)
pub export fn Prim_re_match_buffer() callconv(.c) obj.SchemeObject {
    return reBufferPrimitive(regex.re_match);
}

// DEFINE_PRIMITIVE ("RE-SEARCH-BUFFER-FORWARD", Prim_re_search_buffer_forward, 7, 7, 0)
pub export fn Prim_re_search_buffer_forward() callconv(.c) obj.SchemeObject {
    return reBufferPrimitive(regex.re_search_forward);
}

// DEFINE_PRIMITIVE ("RE-SEARCH-BUFFER-BACKWARD", Prim_re_search_buffer_backward, 7, 7, 0)
pub export fn Prim_re_search_buffer_backward() callconv(.c) obj.SchemeObject {
    return reBufferPrimitive(regex.re_search_backward);
}

test "rgxprim char-set adjoin, compile-fastmap, substring search with register fill" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const rcs = str.allocate_string(32);
    @memset(obj.legacyStringData(rcs)[0..32], 0);
    stubs.setArgs(&.{ rcs, obj.ulongToFixnum('A') });
    _ = Prim_re_char_set_adjoin();
    try std.testing.expect((obj.legacyStringRef(rcs, 'A' / 8) & (@as(u8, 1) << ('A' % 8))) != 0);

    const trans = str.allocate_string(256);
    for (0..256) |i| obj.legacyStringSet(trans, i, @intCast(i));
    const tbl = syntax.makeTestSyntaxTable();
    const fastmap = str.allocate_string(256);
    const pat = str.allocate_string(6);
    const pat_bytes = [_]u8{
        @intFromEnum(regex.RegexpCode.start_memory), 1,
        @intFromEnum(regex.RegexpCode.exact_1), 'x',
        @intFromEnum(regex.RegexpCode.stop_memory), 1,
    };
    @memcpy(obj.legacyStringData(pat)[0..6], &pat_bytes);

    stubs.setArgs(&.{ pat, trans, tbl, fastmap });
    try std.testing.expectEqual(obj.longToFixnum(0), Prim_re_compile_fastmap());
    try std.testing.expectEqual(@as(u8, 1), obj.legacyStringRef(fastmap, 'x'));

    const regs = abi.make_vector(regex.re_nregs * 2, obj.sharp_f, true);
    const haystack = str.char_pointer_to_string("abxcd");
    stubs.setArgs(&.{ pat, trans, tbl, regs, haystack, obj.ulongToFixnum(0), obj.ulongToFixnum(5) });
    try std.testing.expectEqual(obj.longToFixnum(3), Prim_re_search_substr_forward());
    try std.testing.expectEqual(obj.longToFixnum(2), obj.vectorRef(regs, 1));
    try std.testing.expectEqual(obj.longToFixnum(3), obj.vectorRef(regs, 1 + regex.re_nregs));
}
