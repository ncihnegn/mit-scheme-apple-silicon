// Derived from MIT/GNU Scheme C sources (`src/microcode/regex.c`, `src/microcode/regex.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const syntax = @import("syntax.zig");

pub const re_nregs: usize = 10;
const re_nfailures: usize = 512;

pub export var re_max_failures: c_int = 1000;

pub const ReBuffer = extern struct {
    translation: ?[*]const u8,
    syntax_table: obj.SchemeObject,
    text: [*]const u8,
    text_start: [*]const u8,
    text_end: [*]const u8,
    gap_start: [*]const u8,
    gap_end: [*]const u8,
};

pub const ReRegisters = extern struct {
    start: [re_nregs]c_long,
    end: [re_nregs]c_long,
};

pub const RegexpCode = enum(u8) {
    unused = 0,
    exact_1 = 1,
    exact_n = 2,
    line_start = 3,
    line_end = 4,
    jump = 5,
    on_failure_jump = 6,
    finalize_jump = 7,
    maybe_finalize_jump = 8,
    dummy_failure_jump = 9,
    any_char = 10,
    char_set = 11,
    not_char_set = 12,
    start_memory = 13,
    stop_memory = 14,
    duplicate = 15,
    buffer_start = 16,
    buffer_end = 17,
    word_char = 18,
    not_word_char = 19,
    word_start = 20,
    word_end = 21,
    word_bound = 22,
    not_word_bound = 23,
    syntax_spec = 24,
    not_syntax_spec = 25,
};

const ascii_length: usize = 8;
const max_ascii: usize = 256;
const fastmap_false: u8 = 0;
const fastmap_true: u8 = 1;
const re_match_failed: c_int = -1;

inline fn translateChar(translation: ?[*]const u8, ch: u8) u8 {
    return if (translation) |t| t[ch] else ch;
}

inline fn syntaxConstituentP(syntax_table: obj.SchemeObject, code: u4, ch: u8) bool {
    return syntax.syntaxEntryCode(syntax.syntaxTableRef(syntax_table, ch)) == code;
}

inline fn wordConstituentP(syntax_table: obj.SchemeObject, ch: u8) bool {
    return syntaxConstituentP(syntax_table, @intFromEnum(syntax.SyntaxCode.word), ch);
}

inline fn charSetMemberInternal(char_set: [*]const u8, ascii: usize) bool {
    return (char_set[ascii / ascii_length] & (@as(u8, 1) << @intCast(ascii % ascii_length))) != 0;
}

inline fn charSetMemberP(length: usize, char_set: [*]const u8, ascii: usize) bool {
    return ascii < (length * ascii_length) and charSetMemberInternal(char_set, ascii);
}

fn offsetPtr(pc: [*]u8, off: isize, p_start: [*]u8, p_end: [*]u8) ?[*]u8 {
    if (off >= 0) {
        const dist: usize = @intCast(off);
        if (dist > (@intFromPtr(p_end) - @intFromPtr(pc))) return null;
        return pc + dist;
    } else {
        const dist: usize = @intCast(-off);
        if (dist > (@intFromPtr(pc) - @intFromPtr(p_start))) return null;
        return pc - dist;
    }
}

fn readPatternOffset(pc: *[*]u8, p_start: [*]u8, p_end: [*]u8) ?isize {
    if (@intFromPtr(pc.* + 1) >= @intFromPtr(p_end)) return null;
    const lo: isize = pc.*[0];
    const hi_signed: i8 = @bitCast(pc.*[1]);
    pc.* += 2;
    const off: isize = lo + (@as(isize, hi_signed) << ascii_length);
    if (offsetPtr(pc.*, off, p_start, p_end) == null) return null;
    return off;
}

pub export fn re_buffer_initialize(
    buffer: *ReBuffer,
    translation: ?[*]const u8,
    syntax_table: obj.SchemeObject,
    text: [*]const u8,
    text_start_index: c_ulong,
    text_end_index: c_ulong,
    gap_start_index: c_ulong,
    gap_end_index: c_ulong,
) callconv(.c) void {
    const text_start = text + @as(usize, @intCast(text_start_index));
    const text_end = text + @as(usize, @intCast(text_end_index));
    const gap_start = text + @as(usize, @intCast(gap_start_index));
    const gap_end = text + @as(usize, @intCast(gap_end_index));

    buffer.translation = translation;
    buffer.syntax_table = syntax_table;
    buffer.text = text;
    buffer.text_start = if (text_start == gap_start) gap_end else text_start;
    buffer.text_end = if (text_end == gap_end) gap_start else text_end;
    buffer.gap_start = gap_start;
    buffer.gap_end = gap_end;
}

pub export fn re_compile_fastmap(
    pattern_start: [*]u8,
    pattern_end: [*]u8,
    translation: ?[*]const u8,
    syntax_table: obj.SchemeObject,
    fastmap: [*]u8,
) callconv(.c) c_int {
    var pattern_pc = pattern_start;
    var stack_buf: [re_nfailures][*]u8 = undefined;
    var stack_sp: usize = 0;
    var return_value: c_int = 0;

    @memset(fastmap[0..max_ascii], fastmap_false);

    while (true) {
        var step_next = false;
        if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return 1;

        const op_byte = pattern_pc[0];
        pattern_pc += 1;
        if (op_byte > @intFromEnum(RegexpCode.not_syntax_spec)) return -2;

        switch (@as(RegexpCode, @enumFromInt(op_byte))) {
            .unused,
            .line_start,
            .buffer_start,
            .buffer_end,
            .word_start,
            .word_end,
            .word_bound,
            .not_word_bound,
            => continue,

            .line_end => {
                fastmap[translateChar(translation, '\n')] = fastmap_true;
                if (return_value == 0) return_value = 2;
                step_next = true;
            },

            .exact_1 => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const ch = pattern_pc[0];
                pattern_pc += 1;
                fastmap[translateChar(translation, ch)] = fastmap_true;
                step_next = true;
            },

            .exact_n => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const len: usize = pattern_pc[0];
                pattern_pc += 1;
                if (len > (@intFromPtr(pattern_end) - @intFromPtr(pattern_pc))) return -2;
                if (len == 0) continue;
                fastmap[translateChar(translation, pattern_pc[0])] = fastmap_true;
                step_next = true;
            },

            .any_char => {
                for (0..max_ascii) |ascii| {
                    if (ascii != '\n') {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                if (return_value != 0) return return_value;
                step_next = true;
            },

            .char_set => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const len: usize = pattern_pc[0];
                pattern_pc += 1;
                if (len > (@intFromPtr(pattern_end) - @intFromPtr(pattern_pc))) return -2;
                for (0..(len * ascii_length)) |ascii| {
                    if (charSetMemberInternal(pattern_pc, ascii)) {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                step_next = true;
            },

            .not_char_set => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const len: usize = pattern_pc[0];
                pattern_pc += 1;
                if (len > (@intFromPtr(pattern_end) - @intFromPtr(pattern_pc))) return -2;
                const bit_len = len * ascii_length;
                for (0..bit_len) |ascii| {
                    if (!charSetMemberInternal(pattern_pc, ascii)) {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                for (bit_len..max_ascii) |ascii| {
                    fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                }
                step_next = true;
            },

            .word_char => {
                for (0..max_ascii) |ascii| {
                    if (wordConstituentP(syntax_table, @intCast(ascii))) {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                step_next = true;
            },

            .not_word_char => {
                for (0..max_ascii) |ascii| {
                    if (!wordConstituentP(syntax_table, @intCast(ascii))) {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                step_next = true;
            },

            .syntax_spec => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const code_byte = pattern_pc[0];
                pattern_pc += 1;
                if (code_byte >= @intFromEnum(syntax.SyntaxCode.max)) return -2;
                const code: u4 = @intCast(code_byte);
                for (0..max_ascii) |ascii| {
                    if (syntaxConstituentP(syntax_table, code, @intCast(ascii))) {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                step_next = true;
            },

            .not_syntax_spec => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const code_byte = pattern_pc[0];
                pattern_pc += 1;
                if (code_byte >= @intFromEnum(syntax.SyntaxCode.max)) return -2;
                const code: u4 = @intCast(code_byte);
                for (0..max_ascii) |ascii| {
                    if (!syntaxConstituentP(syntax_table, code, @intCast(ascii))) {
                        fastmap[translateChar(translation, @intCast(ascii))] = fastmap_true;
                    }
                }
                step_next = true;
            },

            .start_memory, .stop_memory => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const reg = pattern_pc[0];
                pattern_pc += 1;
                if (reg >= re_nregs) return -2;
                continue;
            },

            .duplicate => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const reg = pattern_pc[0];
                pattern_pc += 1;
                if (reg >= re_nregs) return -2;
                @memset(fastmap[0..max_ascii], fastmap_true);
                return 1;
            },

            .jump, .finalize_jump, .maybe_finalize_jump, .dummy_failure_jump => {
                return_value = 1;
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                pattern_pc = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
                if (off > 0) continue;

                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                if (pattern_pc[0] != @intFromEnum(RegexpCode.on_failure_jump)) continue;
                const off2 = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                pattern_pc = offsetPtr(pattern_pc, off2, pattern_start, pattern_end).?;
                if (stack_sp > 0 and stack_buf[stack_sp - 1] == pattern_pc) {
                    stack_sp -= 1;
                }
                continue;
            },

            .on_failure_jump => {
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                stack_buf[stack_sp] = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
                stack_sp += 1;
                continue;
            },
        }

        if (step_next) {
            if (stack_sp == 0) return return_value;
            stack_sp -= 1;
            pattern_pc = stack_buf[stack_sp];
        }
    }
}

fn beqTranslate(scan1: [*]const u8, scan2: [*]const u8, length: usize, translation: ?[*]const u8) bool {
    var i: usize = 0;
    while (i < length) : (i += 1) {
        if (translateChar(translation, scan1[i]) != translateChar(translation, scan2[i])) {
            return false;
        }
    }
    return true;
}

inline fn addressToIndex(address: [*]const u8, buffer: *const ReBuffer, gap_start: [*]const u8, gap_length: usize) c_long {
    const raw = if (@intFromPtr(address) > @intFromPtr(gap_start))
        address - gap_length
    else
        address;
    return @intCast((@intFromPtr(raw) - @intFromPtr(buffer.text)));
}

pub export fn re_match(
    pattern_start: [*]u8,
    pattern_end: [*]u8,
    buffer: *ReBuffer,
    registers: ?*ReRegisters,
    match_start: [*]const u8,
    match_end: [*]const u8,
) callconv(.c) c_int {
    var pattern_pc = pattern_start;
    var match_pc = match_start;
    const gap_start = buffer.gap_start;
    const gap_end = buffer.gap_end;
    const gap_length: usize = @intFromPtr(gap_end) - @intFromPtr(gap_start);
    const translation = buffer.translation;
    const syntax_table = buffer.syntax_table;

    var stack_len: usize = 2 * re_nfailures;
    const init_raw = std.c.malloc(stack_len * @sizeOf(?[*]const u8)) orelse return -3;
    var stack_start: [*]?[*]const u8 = @ptrCast(@alignCast(init_raw));
    defer std.c.free(@ptrCast(stack_start));
    var stack_used: usize = 0;

    var register_start: [re_nregs]?[*]const u8 = @splat(null);
    var register_end: [re_nregs]?[*]const u8 = @splat(null);

    while (true) {
        var failed = false;
        if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) {
            if (registers) |regs| {
                register_start[0] = match_start;
                register_end[0] = match_pc;
                for (0..re_nregs) |i| {
                    regs.start[i] = if (register_start[i]) |s| addressToIndex(s, buffer, gap_start, gap_length) else -1;
                    regs.end[i] = if (register_end[i]) |e| addressToIndex(e, buffer, gap_start, gap_length) else -1;
                }
            }
            return @intCast(addressToIndex(match_pc, buffer, gap_start, gap_length));
        }

        const op_byte = pattern_pc[0];
        pattern_pc += 1;
        if (op_byte > @intFromEnum(RegexpCode.not_syntax_spec)) return -2;

        const readMatchChar = struct {
            inline fn apply(mpc: *[*]const u8, mend: [*]const u8, gs: [*]const u8, ge: [*]const u8, trans: ?[*]const u8) ?u8 {
                if (@intFromPtr(mpc.*) >= @intFromPtr(mend)) return null;
                const ch = translateChar(trans, mpc.*[0]);
                mpc.* += 1;
                if (mpc.* == gs) mpc.* = ge;
                return ch;
            }
        }.apply;

        switch (@as(RegexpCode, @enumFromInt(op_byte))) {
            .unused => continue,

            .exact_1 => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const ascii_p = pattern_pc[0];
                pattern_pc += 1;
                if (readMatchChar(&match_pc, match_end, gap_start, gap_end, translation)) |ascii| {
                    if (ascii != ascii_p) failed = true;
                } else {
                    failed = true;
                }
            },

            .exact_n => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                var len: usize = pattern_pc[0];
                pattern_pc += 1;
                if (len > (@intFromPtr(pattern_end) - @intFromPtr(pattern_pc))) return -2;
                while (len > 0) : (len -= 1) {
                    const ch = pattern_pc[0];
                    pattern_pc += 1;
                    if (readMatchChar(&match_pc, match_end, gap_start, gap_end, translation)) |ascii| {
                        if (ascii != ch) {
                            failed = true;
                            break;
                        }
                    } else {
                        failed = true;
                        break;
                    }
                }
            },

            .any_char => {
                if (readMatchChar(&match_pc, match_end, gap_start, gap_end, translation)) |ascii| {
                    if (ascii == '\n') failed = true;
                } else {
                    failed = true;
                }
            },

            .char_set, .not_char_set => |kind| {
                if (readMatchChar(&match_pc, match_end, gap_start, gap_end, translation)) |ascii| {
                    if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                    const len: usize = pattern_pc[0];
                    pattern_pc += 1;
                    if (len > (@intFromPtr(pattern_end) - @intFromPtr(pattern_pc))) return -2;
                    const in_set = charSetMemberP(len, pattern_pc, ascii);
                    pattern_pc += len;
                    failed = if (kind == .char_set) !in_set else in_set;
                } else {
                    failed = true;
                }
            },

            .start_memory => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const reg = pattern_pc[0];
                pattern_pc += 1;
                if (reg >= re_nregs) return -2;
                register_start[reg] = match_pc;
            },

            .stop_memory => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const reg = pattern_pc[0];
                pattern_pc += 1;
                if (reg >= re_nregs) return -2;
                register_end[reg] = if (match_pc == gap_end) gap_start else match_pc;
            },

            .duplicate => {
                if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                const reg = pattern_pc[0];
                pattern_pc += 1;
                if (reg >= re_nregs) return -2;
                const r_start_opt = register_start[reg];
                const r_end_opt = register_end[reg];
                if (r_start_opt == null or r_end_opt == null) continue;
                const r_start = r_start_opt.?;
                const r_end = r_end_opt.?;
                if (@intFromPtr(r_end) <= @intFromPtr(r_start)) continue;
                const length: usize = @intFromPtr(r_end) - @intFromPtr(r_start);
                var new_end_addr = @intFromPtr(match_pc) + length;
                if (new_end_addr > @intFromPtr(match_end)) {
                    failed = true;
                } else {
                    var new_end: [*]const u8 = @ptrFromInt(new_end_addr);
                    if (@intFromPtr(match_pc) <= @intFromPtr(gap_start) and new_end_addr > @intFromPtr(gap_start)) {
                        new_end_addr += gap_length;
                        if (new_end_addr > @intFromPtr(match_end)) {
                            failed = true;
                        } else {
                            new_end = @ptrFromInt(new_end_addr);
                            const length1 = @intFromPtr(gap_start) - @intFromPtr(match_pc);
                            const length2 = length - length1;
                            if (!(beqTranslate(match_pc, r_start, length1, translation) and
                                beqTranslate(gap_end, r_start + length1, length2, translation)))
                            {
                                failed = true;
                            }
                        }
                    } else if (@intFromPtr(r_start) <= @intFromPtr(gap_start) and @intFromPtr(r_end) > @intFromPtr(gap_start)) {
                        const length1 = @intFromPtr(gap_start) - @intFromPtr(r_start);
                        const length2 = @intFromPtr(r_end) - @intFromPtr(gap_end);
                        if (!(beqTranslate(match_pc, r_start, length1, translation) and
                            beqTranslate(match_pc + length1, gap_end, length2, translation)))
                        {
                            failed = true;
                        }
                    } else {
                        if (!beqTranslate(match_pc, r_start, length, translation)) {
                            failed = true;
                        }
                    }
                    if (!failed) {
                        match_pc = if (new_end == gap_end or new_end == gap_start)
                            (if (new_end == gap_start) gap_end else new_end)
                        else
                            new_end;
                    }
                }
            },

            .buffer_start => {
                if (addressToIndex(match_pc, buffer, gap_start, gap_length) !=
                    addressToIndex(buffer.text_start, buffer, gap_start, gap_length))
                {
                    failed = true;
                }
            },

            .buffer_end => {
                if (addressToIndex(match_pc, buffer, gap_start, gap_length) !=
                    addressToIndex(buffer.text_end, buffer, gap_start, gap_length))
                {
                    failed = true;
                }
            },

            .line_start => {
                if (addressToIndex(match_pc, buffer, gap_start, gap_length) !=
                    addressToIndex(buffer.text_start, buffer, gap_start, gap_length))
                {
                    const base = if (match_pc == gap_end) gap_start else match_pc;
                    if (translateChar(translation, (base - 1)[0]) != '\n') failed = true;
                }
            },

            .line_end => {
                if (addressToIndex(match_pc, buffer, gap_start, gap_length) !=
                    addressToIndex(buffer.text_end, buffer, gap_start, gap_length) and
                    translateChar(translation, match_pc[0]) != '\n')
                {
                    failed = true;
                }
            },

            .word_bound, .not_word_bound, .word_start, .word_end => |kind| {
                const left_p = if (match_pc == gap_end)
                    (gap_start != buffer.text_start and wordConstituentP(syntax_table, translateChar(translation, (gap_start - 1)[0])))
                else
                    (match_pc != buffer.text_start and wordConstituentP(syntax_table, translateChar(translation, (match_pc - 1)[0])));
                const right_p = if (match_pc == gap_end)
                    (gap_end != buffer.text_end and wordConstituentP(syntax_table, translateChar(translation, gap_end[0])))
                else
                    (match_pc != buffer.text_end and wordConstituentP(syntax_table, translateChar(translation, match_pc[0])));
                const ok = switch (kind) {
                    .word_bound => left_p != right_p,
                    .not_word_bound => left_p == right_p,
                    .word_start => !left_p and right_p,
                    .word_end => left_p and !right_p,
                    else => unreachable,
                };
                if (!ok) failed = true;
            },

            .word_char, .not_word_char => |kind| {
                if (readMatchChar(&match_pc, match_end, gap_start, gap_end, translation)) |ascii| {
                    const is_word = wordConstituentP(syntax_table, ascii);
                    failed = if (kind == .word_char) !is_word else is_word;
                } else {
                    failed = true;
                }
            },

            .syntax_spec, .not_syntax_spec => |kind| {
                if (readMatchChar(&match_pc, match_end, gap_start, gap_end, translation)) |ascii| {
                    if (@intFromPtr(pattern_pc) >= @intFromPtr(pattern_end)) return -2;
                    const code_byte = pattern_pc[0];
                    pattern_pc += 1;
                    if (code_byte >= @intFromEnum(syntax.SyntaxCode.max)) return -2;
                    const is_match = syntaxConstituentP(syntax_table, @intCast(code_byte), ascii);
                    failed = if (kind == .syntax_spec) !is_match else is_match;
                } else {
                    failed = true;
                }
            },

            .on_failure_jump => {
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                const push_pc = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
                if (stack_used == stack_len) {
                    const new_len = stack_len * 2;
                    if (re_max_failures < 0 or new_len > @as(usize, @intCast(re_max_failures)) * 2) return -4;
                    const new_raw = std.c.realloc(@ptrCast(stack_start), new_len * @sizeOf(?[*]const u8)) orelse return -3;
                    stack_start = @ptrCast(@alignCast(new_raw));
                    stack_len = new_len;
                }
                stack_start[stack_used] = push_pc;
                stack_start[stack_used + 1] = match_pc;
                stack_used += 2;
            },

            .maybe_finalize_jump => {
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                var do_finalize = false;
                if (pattern_pc == pattern_end) {
                    do_finalize = true;
                } else {
                    const next_ascii: ?u8 = switch (@as(RegexpCode, @enumFromInt(pattern_pc[0]))) {
                        .exact_1 => pattern_pc[1],
                        .exact_n => pattern_pc[2],
                        .line_end => '\n',
                        else => null,
                    };
                    if (next_ascii) |ascii| {
                        const target = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
                        switch (@as(RegexpCode, @enumFromInt(target[0]))) {
                            .exact_1 => {
                                if (ascii != target[1]) do_finalize = true;
                            },
                            .exact_n => {
                                if (ascii != target[2]) do_finalize = true;
                            },
                            .char_set => {
                                if (!charSetMemberP(target[1], target + 2, ascii)) do_finalize = true;
                            },
                            .not_char_set => {
                                if (charSetMemberP(target[1], target + 2, ascii)) do_finalize = true;
                            },
                            else => {},
                        }
                    }
                }
                pattern_pc -= 2;
                if (do_finalize) {
                    (pattern_pc - 1)[0] = @intFromEnum(RegexpCode.finalize_jump);
                    stack_used -= 2;
                } else {
                    (pattern_pc - 1)[0] = @intFromEnum(RegexpCode.jump);
                }
                const jump_off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                pattern_pc = offsetPtr(pattern_pc, jump_off, pattern_start, pattern_end).?;
            },

            .finalize_jump => {
                stack_used -= 2;
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                pattern_pc = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
            },

            .jump => {
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                pattern_pc = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
            },

            .dummy_failure_jump => {
                if (stack_used == stack_len) {
                    const new_len = stack_len * 2;
                    if (re_max_failures < 0 or new_len > @as(usize, @intCast(re_max_failures)) * 2) return -4;
                    const new_raw = std.c.realloc(@ptrCast(stack_start), new_len * @sizeOf(?[*]const u8)) orelse return -3;
                    stack_start = @ptrCast(@alignCast(new_raw));
                    stack_len = new_len;
                }
                stack_start[stack_used] = null;
                stack_start[stack_used + 1] = null;
                stack_used += 2;
                const off = readPatternOffset(&pattern_pc, pattern_start, pattern_end) orelse return -2;
                pattern_pc = offsetPtr(pattern_pc, off, pattern_start, pattern_end).?;
            },
        }

        if (failed) {
            while (true) {
                if (stack_used == 0) return re_match_failed;
                stack_used -= 2;
                const p_pop = stack_start[stack_used];
                if (p_pop) |pp| {
                    match_pc = stack_start[stack_used + 1].?;
                    pattern_pc = @constCast(pp);
                    break;
                }
            }
        }
    }
}

inline fn reMatchFailureResult(res: c_int) bool {
    return res == re_match_failed or res == -4;
}

pub export fn re_search_forward(
    pattern_start: [*]u8,
    pattern_end: [*]u8,
    buffer: *ReBuffer,
    registers: ?*ReRegisters,
    match_start: [*]const u8,
    match_end: [*]const u8,
) callconv(.c) c_int {
    var fastmap: [max_ascii]u8 = undefined;
    const translation = buffer.translation;
    const can_be_null = re_compile_fastmap(pattern_start, pattern_end, translation, buffer.syntax_table, &fastmap);
    if (can_be_null < 0) return can_be_null;

    var match_pc = match_start;
    const gap_start = buffer.gap_start;

    if (can_be_null != 1) {
        if (@intFromPtr(match_pc) < @intFromPtr(gap_start) and @intFromPtr(gap_start) < @intFromPtr(match_end)) {
            while (@intFromPtr(match_pc) < @intFromPtr(gap_start)) {
                const ch = translateChar(translation, match_pc[0]);
                match_pc += 1;
                if (fastmap[ch] == fastmap_false) continue;
                const res = re_match(pattern_start, pattern_end, buffer, registers, match_pc - 1, match_end);
                if (!reMatchFailureResult(res)) return res;
            }
        }
        if (match_pc == gap_start) match_pc = buffer.gap_end;
        while (@intFromPtr(match_pc) < @intFromPtr(match_end)) {
            const ch = translateChar(translation, match_pc[0]);
            match_pc += 1;
            if (fastmap[ch] == fastmap_false) continue;
            const res = re_match(pattern_start, pattern_end, buffer, registers, match_pc - 1, match_end);
            if (!reMatchFailureResult(res)) return res;
        }
        return if (can_be_null == 0)
            re_match_failed
        else
            re_match(pattern_start, pattern_end, buffer, registers, match_end, match_end);
    } else {
        while (true) {
            const res = re_match(pattern_start, pattern_end, buffer, registers, match_pc, match_end);
            if (!reMatchFailureResult(res)) return res;
            match_pc += 1;
            if (match_pc == gap_start) match_pc = buffer.gap_end;
            if (@intFromPtr(match_pc) > @intFromPtr(match_end)) return res;
        }
    }
}

pub export fn re_search_backward(
    pattern_start: [*]u8,
    pattern_end: [*]u8,
    buffer: *ReBuffer,
    registers: ?*ReRegisters,
    match_start: [*]const u8,
    match_end: [*]const u8,
) callconv(.c) c_int {
    var fastmap: [max_ascii]u8 = undefined;
    const translation = buffer.translation;
    const can_be_null = re_compile_fastmap(pattern_start, pattern_end, translation, buffer.syntax_table, &fastmap);
    if (can_be_null < 0) return can_be_null;

    var match_pc = match_end;
    const gap_start = buffer.gap_start;
    const gap_end = buffer.gap_end;
    const gap_length: usize = @intFromPtr(gap_end) - @intFromPtr(gap_start);

    const wrapResult = struct {
        inline fn apply(res: c_int, start_ptr: [*]const u8, buf: *const ReBuffer, gs: [*]const u8, gl: usize) c_int {
            if (res < 0) return res;
            return @intCast(addressToIndex(start_ptr, buf, gs, gl));
        }
    }.apply;

    if (can_be_null != 1) {
        if (@intFromPtr(match_pc) > @intFromPtr(gap_end) and @intFromPtr(gap_end) > @intFromPtr(match_start)) {
            while (@intFromPtr(match_pc) > @intFromPtr(gap_end)) {
                match_pc -= 1;
                if (fastmap[translateChar(translation, match_pc[0])] == fastmap_false) continue;
                const res = re_match(pattern_start, pattern_end, buffer, registers, match_pc, match_end);
                if (!reMatchFailureResult(res)) return wrapResult(res, match_pc, buffer, gap_start, gap_length);
            }
        }
        if (match_pc == gap_end) match_pc = gap_start;
        while (@intFromPtr(match_pc) > @intFromPtr(match_start)) {
            match_pc -= 1;
            if (fastmap[translateChar(translation, match_pc[0])] == fastmap_false) continue;
            const res = re_match(pattern_start, pattern_end, buffer, registers, match_pc, match_end);
            if (!reMatchFailureResult(res)) return wrapResult(res, match_pc, buffer, gap_start, gap_length);
        }
        if (can_be_null == 0) return re_match_failed;
        const res = re_match(pattern_start, pattern_end, buffer, registers, match_start, match_end);
        return wrapResult(res, match_start, buffer, gap_start, gap_length);
    } else {
        while (true) {
            const res = re_match(pattern_start, pattern_end, buffer, registers, match_pc, match_end);
            if (!reMatchFailureResult(res)) return wrapResult(res, match_pc, buffer, gap_start, gap_length);
            if (match_pc == gap_end) match_pc = gap_start;
            if (@intFromPtr(match_pc) <= @intFromPtr(match_start)) return res;
            match_pc -= 1;
        }
    }
}

test "regex compile_fastmap, match captures/backrefs, smart repeat rewrite, gap search" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const tbl = syntax.makeTestSyntaxTable();

    // Pattern matching: \(foo+\)\1  compiled manually:
    //  0: start_memory 1
    //  2: exact_n 2 "fo"
    //  6: exact_1 'o'
    //  8: on_failure_jump +5 (pc=11 -> byte 16 stop_memory)
    // 11: exact_1 'o'
    // 13: maybe_finalize_jump -8 (pc=16 -> byte 8 on_failure_jump)
    // 16: stop_memory 1
    // 18: duplicate 1
    var pat = [_]u8{
        @intFromEnum(RegexpCode.start_memory), 1,
        @intFromEnum(RegexpCode.exact_n), 2, 'f', 'o',
        @intFromEnum(RegexpCode.exact_1), 'o', // one required 'o'
        @intFromEnum(RegexpCode.on_failure_jump), 5, 0, // +5 -> byte 16
        @intFromEnum(RegexpCode.exact_1), 'o',
        @intFromEnum(RegexpCode.maybe_finalize_jump), 0xF8, 0xFF, // -8 -> byte 8
        @intFromEnum(RegexpCode.stop_memory), 1,
        @intFromEnum(RegexpCode.duplicate), 1,
    };

    const pat_ptr: [*]u8 = &pat;
    const pat_end: [*]u8 = pat_ptr + pat.len;
    var fastmap: [max_ascii]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), re_compile_fastmap(pat_ptr, pat_end, null, tbl, &fastmap));
    try std.testing.expectEqual(fastmap_true, fastmap['f']);
    try std.testing.expectEqual(fastmap_false, fastmap['x']);

    // Text with gap in the middle of "ab fooooXYZfoooo cd"
    const text = "ab fooooXXXXXXfoooo cd";
    var buf: ReBuffer = undefined;
    re_buffer_initialize(&buf, null, tbl, text.ptr, 0, text.len, 8, 14);
    var regs: ReRegisters = undefined;
    const start_pos = re_search_forward(pat_ptr, pat_end, &buf, &regs, buf.text_start, buf.text_end);
    try std.testing.expectEqual(@as(c_int, 13), start_pos); // matched "foooofoooo" logical [3..13)
    try std.testing.expectEqual(@as(c_long, 3), regs.start[1]);
    try std.testing.expectEqual(@as(c_long, 8), regs.end[1]);
    // Verify maybe_finalize_jump was rewritten to jump because stop_memory follows.
    try std.testing.expectEqual(@intFromEnum(RegexpCode.jump), pat[13]);

    // Backward search from end for nullable pattern `a*` (`on_failure_jump +5`, `exact_1 'a'`, `finalize_jump -8`)
    var null_pat = [_]u8{
        @intFromEnum(RegexpCode.on_failure_jump), 5, 0,
        @intFromEnum(RegexpCode.exact_1), 'a',
        @intFromEnum(RegexpCode.finalize_jump), 0xF8, 0xFF,
    };
    const np_ptr: [*]u8 = &null_pat;
    const b_res = re_search_backward(np_ptr, np_ptr + null_pat.len, &buf, null, buf.text_start, buf.text_end);
    try std.testing.expectEqual(@as(c_int, 16), b_res);
}
