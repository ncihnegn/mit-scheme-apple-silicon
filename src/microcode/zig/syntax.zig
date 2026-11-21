// Derived from MIT/GNU Scheme C sources (`src/microcode/syntax.c`, `src/microcode/syntax.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const str = @import("string.zig");
const edwin = @import("edwin_defs.zig");

pub const SyntaxCode = enum(u4) {
    whitespace = 0,
    punct = 1,
    word = 2,
    symbol = 3,
    open = 4,
    close = 5,
    quote = 6,
    string = 7,
    math = 8,
    escape = 9,
    charquote = 10,
    comment = 11,
    endcomment = 12,
    max = 13,
};

const illegal: u8 = @intFromEnum(SyntaxCode.max);

const comstart_first_a: c_ulong = 0x80;
const comstart_first_b: c_ulong = 0x40;
const comstart_second_a: c_ulong = 0x20;
const comstart_second_b: c_ulong = 0x10;
const comend_first_a: c_ulong = 0x08;
const comend_first_b: c_ulong = 0x04;
const comend_second_a: c_ulong = 0x02;
const comend_second_b: c_ulong = 0x01;

const comment_style_a: c_uint = 0xAA;
const comment_style_b: c_uint = 0x55;
const comstart_first: c_uint = 0xC0;
const comstart_second: c_uint = 0x30;
const comend_first: c_uint = 0x0C;
const comend_second: c_uint = 0x03;

pub export var syntax_spec_code: [0x80]u8 = blk: {
    var t: [0x80]u8 = @splat(illegal);
    t[' '] = @intFromEnum(SyntaxCode.whitespace);
    t['"'] = @intFromEnum(SyntaxCode.string);
    t['$'] = @intFromEnum(SyntaxCode.math);
    t['\''] = @intFromEnum(SyntaxCode.quote);
    t['('] = @intFromEnum(SyntaxCode.open);
    t[')'] = @intFromEnum(SyntaxCode.close);
    t['-'] = @intFromEnum(SyntaxCode.whitespace);
    t['.'] = @intFromEnum(SyntaxCode.punct);
    t['/'] = @intFromEnum(SyntaxCode.charquote);
    t['<'] = @intFromEnum(SyntaxCode.comment);
    t['>'] = @intFromEnum(SyntaxCode.endcomment);
    t['W'] = @intFromEnum(SyntaxCode.word);
    t['\\'] = @intFromEnum(SyntaxCode.escape);
    t['_'] = @intFromEnum(SyntaxCode.symbol);
    t['w'] = @intFromEnum(SyntaxCode.word);
    break :blk t;
};

pub export var syntax_code_spec: [13]u8 = .{
    ' ', '.', 'w', '_', '(', ')', '\'', '"', '$', '\\', '/', '<', '>',
};

pub inline fn syntaxTableP(argument: obj.SchemeObject) bool {
    return obj.vectorP(argument) and obj.vectorLength(argument) == 0x100;
}

pub inline fn syntaxTableRef(table: obj.SchemeObject, ch: u8) obj.SchemeObject {
    return obj.vectorRef(table, ch);
}

pub inline fn syntaxEntryCode(entry: obj.SchemeObject) u4 {
    return @intCast(entry & 0xF);
}

pub inline fn syntaxEntryCommentBits(entry: obj.SchemeObject) c_uint {
    return @intCast((entry >> 12) & 0xFF);
}

pub inline fn syntaxEntryCommentStyle(entry: obj.SchemeObject, m: c_uint) c_uint {
    const bits = syntaxEntryCommentBits(entry);
    const a: c_uint = if ((bits & m & comment_style_a) != 0) comment_style_a else 0;
    const b: c_uint = if ((bits & m & comment_style_b) != 0) comment_style_b else 0;
    return a | b;
}

pub inline fn syntaxEntryPrefix(entry: obj.SchemeObject) bool {
    return ((entry >> 20) & 1) != 0;
}

pub inline fn syntaxEntryQuote(entry: obj.SchemeObject) bool {
    const code = syntaxEntryCode(entry);
    return code == @intFromEnum(SyntaxCode.escape) or code == @intFromEnum(SyntaxCode.charquote);
}

// DEFINE_PRIMITIVE ("STRING->SYNTAX-ENTRY", Prim_string_to_syntax_entry, 1, 1, 0)
pub export fn Prim_string_to_syntax_entry() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const s = abi.argRef(1);
    var length = obj.legacyStringLength(s);
    var scan = obj.legacyStringLoc(s, 0);
    var result: c_ulong = undefined;

    if (length > 0) {
        const c = scan[0];
        scan += 1;
        length -= 1;
        if (c >= 0o200) abi.error_bad_range_arg(1);
        result = syntax_spec_code[c];
        if (result == illegal) abi.error_bad_range_arg(1);
    } else {
        result = @intFromEnum(SyntaxCode.whitespace);
    }

    if (length > 0) {
        const c = scan[0];
        scan += 1;
        length -= 1;
        if (c != ' ') result |= @as(c_ulong, c) << 4;
    }

    const mergeBit = struct {
        inline fn apply(res: *c_ulong, bit: c_ulong) void {
            if ((res.* & bit) != 0) abi.error_bad_range_arg(1);
            res.* |= bit;
        }
    }.apply;

    while (length > 0) {
        length -= 1;
        const ch = scan[0];
        scan += 1;
        switch (ch) {
            '1' => mergeBit(&result, comstart_first_b << 12),
            '2' => mergeBit(&result, comstart_second_b << 12),
            '3' => mergeBit(&result, comend_first_b << 12),
            '4' => mergeBit(&result, comend_second_b << 12),
            '5' => mergeBit(&result, comstart_first_a << 12),
            '6' => mergeBit(&result, comstart_second_a << 12),
            '7' => mergeBit(&result, comend_first_a << 12),
            '8' => mergeBit(&result, comend_second_a << 12),
            'b' => switch (syntaxEntryCode(result)) {
                @intFromEnum(SyntaxCode.comment) => mergeBit(&result, comstart_first_b << 12),
                @intFromEnum(SyntaxCode.endcomment) => mergeBit(&result, comend_first_b << 12),
                else => {},
            },
            'p' => mergeBit(&result, @as(c_ulong, 1) << 20),
            ' ' => {},
            else => abi.error_bad_range_arg(1),
        }
    }

    if (syntaxEntryCode(result) == @intFromEnum(SyntaxCode.comment) and
        (syntaxEntryCommentBits(result) & comstart_first) == 0)
    {
        mergeBit(&result, comstart_first_a << 12);
    }
    if (syntaxEntryCode(result) == @intFromEnum(SyntaxCode.endcomment) and
        (syntaxEntryCommentBits(result) & comend_first) == 0)
    {
        mergeBit(&result, comend_first_a << 12);
    }
    return obj.ulongToFixnum(result);
}

// DEFINE_PRIMITIVE ("CHAR->SYNTAX-CODE", Prim_char_to_syntax_code, 2, 2, 0)
pub export fn Prim_char_to_syntax_code() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, syntaxTableP);
    const ch: u8 = @truncate(@as(c_ulong, @bitCast(abi.arg_ascii_char(2))));
    const entry = syntaxTableRef(abi.argRef(1), ch);
    return obj.asciiToChar(syntax_code_spec[syntaxEntryCode(entry)]);
}

// Parser cursor over gap-buffer text

const ScanCtx = struct {
    syntax_table: obj.SchemeObject,
    first_char: [*]const u8,
    start: usize,
    end: usize,
    gap_start: usize,
    gap_length: usize,
    gap_end: usize,

    fn initForward() ScanCtx {
        abi.primitiveHeader();
        abi.checkArg(1, syntaxTableP);
        const tbl = abi.argRef(1);
        abi.checkArg(2, edwin.groupP);
        const group = abi.argRef(2);
        const first_char = edwin.groupText(group, null);
        var start: usize = @intCast(abi.arg_nonnegative_integer(3));
        var end: usize = @intCast(abi.arg_nonnegative_integer(4));
        const gap_start: usize = @intCast(edwin.groupGapStart(group));
        const gap_length: usize = @intCast(edwin.groupGapLength(group));
        const gap_end: usize = @intCast(edwin.groupGapEnd(group));
        if (start >= gap_start) start += gap_length;
        if (end >= gap_start) end += gap_length;
        return .{
            .syntax_table = tbl,
            .first_char = first_char,
            .start = start,
            .end = end,
            .gap_start = gap_start,
            .gap_length = gap_length,
            .gap_end = gap_end,
        };
    }

    fn initBackward() ScanCtx {
        abi.primitiveHeader();
        abi.checkArg(1, syntaxTableP);
        const tbl = abi.argRef(1);
        abi.checkArg(2, edwin.groupP);
        const group = abi.argRef(2);
        const first_char = edwin.groupText(group, null);
        var start: usize = @intCast(abi.arg_nonnegative_integer(3));
        var end: usize = @intCast(abi.arg_nonnegative_integer(4));
        const gap_start: usize = @intCast(edwin.groupGapStart(group));
        const gap_length: usize = @intCast(edwin.groupGapLength(group));
        const gap_end: usize = @intCast(edwin.groupGapEnd(group));
        if (start > gap_start) start += gap_length;
        if (end > gap_start) end += gap_length;
        return .{
            .syntax_table = tbl,
            .first_char = first_char,
            .start = start,
            .end = end,
            .gap_start = gap_start,
            .gap_length = gap_length,
            .gap_end = gap_end,
        };
    }

    inline fn rightEndP(self: *const ScanCtx, pos: usize) bool {
        return pos >= self.end;
    }

    inline fn leftEndP(self: *const ScanCtx, pos: usize) bool {
        return pos <= self.end;
    }

    inline fn peekRight(self: *const ScanCtx, pos: usize) obj.SchemeObject {
        return syntaxTableRef(self.syntax_table, self.first_char[pos]);
    }

    inline fn peekLeft(self: *const ScanCtx, pos: usize) obj.SchemeObject {
        return syntaxTableRef(self.syntax_table, self.first_char[pos - 1]);
    }

    inline fn moveRight(self: *const ScanCtx, pos: *usize) void {
        pos.* += 1;
        if (pos.* == self.gap_start) pos.* = self.gap_end;
    }

    inline fn moveLeft(self: *const ScanCtx, pos: *usize) void {
        pos.* -= 1;
        if (pos.* == self.gap_end) pos.* = self.gap_start;
    }

    inline fn readRight(self: *const ScanCtx, pos: *usize) obj.SchemeObject {
        const entry = self.peekRight(pos.*);
        self.moveRight(pos);
        return entry;
    }

    inline fn readLeft(self: *const ScanCtx, pos: *usize) obj.SchemeObject {
        self.moveLeft(pos);
        return self.peekRight(pos.*);
    }

    inline fn scanToIndex(self: *const ScanCtx, pos: usize) c_long {
        const logical = if (pos > self.gap_start) pos - self.gap_length else pos;
        return @intCast(logical);
    }

    inline fn indexToScan(self: *const ScanCtx, idx: c_long) usize {
        const u: usize = @intCast(idx);
        return if (u > self.gap_start) u + self.gap_length else u;
    }

    fn rightQuotedP(self: *const ScanCtx, scan_init: usize) bool {
        var scan = scan_init;
        var quoted = false;
        while (!self.leftEndP(scan)) {
            const sentry = self.readLeft(&scan);
            if (!syntaxEntryQuote(sentry)) break;
            quoted = !quoted;
        }
        return quoted;
    }

    fn leftQuotedP(self: *const ScanCtx, scan_init: usize) bool {
        var scan = scan_init;
        self.moveLeft(&scan);
        return self.rightQuotedP(scan);
    }
};

// Quote Parsers

// DEFINE_PRIMITIVE ("QUOTED-CHAR?", Prim_quoted_char_p, 4, 4, 0)
pub export fn Prim_quoted_char_p() callconv(.c) obj.SchemeObject {
    const ctx = ScanCtx.initBackward();
    return obj.booleanToObject(ctx.rightQuotedP(ctx.start));
}

// DEFINE_PRIMITIVE ("SCAN-BACKWARD-PREFIX-CHARS", Prim_scan_backward_prefix_chars, 4, 4, 0)
pub export fn Prim_scan_backward_prefix_chars() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initBackward();
    while (true) {
        if (ctx.leftEndP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        if (ctx.leftQuotedP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        const sentry = ctx.peekLeft(ctx.start);
        if (syntaxEntryCode(sentry) != @intFromEnum(SyntaxCode.quote) and !syntaxEntryPrefix(sentry)) {
            return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        }
        ctx.moveLeft(&ctx.start);
    }
}

// DEFINE_PRIMITIVE ("SCAN-FORWARD-PREFIX-CHARS", Prim_scan_forward_prefix_chars, 4, 4, 0)
pub export fn Prim_scan_forward_prefix_chars() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initForward();
    while (true) {
        if (ctx.rightEndP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        if (ctx.rightQuotedP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        const sentry = ctx.peekRight(ctx.start);
        if (syntaxEntryCode(sentry) != @intFromEnum(SyntaxCode.quote) and !syntaxEntryPrefix(sentry)) {
            return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        }
        ctx.moveRight(&ctx.start);
    }
}

// Word Parsers

// DEFINE_PRIMITIVE ("SCAN-FORWARD-TO-WORD", Prim_scan_forward_to_word, 4, 4, 0)
pub export fn Prim_scan_forward_to_word() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initForward();
    while (true) {
        if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
        if (syntaxEntryCode(ctx.peekRight(ctx.start)) == @intFromEnum(SyntaxCode.word)) {
            return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        }
        ctx.moveRight(&ctx.start);
    }
}

// DEFINE_PRIMITIVE ("SCAN-WORD-FORWARD", Prim_scan_word_forward, 4, 4, 0)
pub export fn Prim_scan_word_forward() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initForward();
    while (true) {
        if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
        const sentry = ctx.readRight(&ctx.start);
        if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.word)) break;
    }
    while (true) {
        if (ctx.rightEndP(ctx.start) or syntaxEntryCode(ctx.peekRight(ctx.start)) != @intFromEnum(SyntaxCode.word)) {
            return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        }
        ctx.moveRight(&ctx.start);
    }
}

// DEFINE_PRIMITIVE ("SCAN-WORD-BACKWARD", Prim_scan_word_backward, 4, 4, 0)
pub export fn Prim_scan_word_backward() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initBackward();
    while (true) {
        if (ctx.leftEndP(ctx.start)) return obj.sharp_f;
        const sentry = ctx.readLeft(&ctx.start);
        if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.word)) break;
    }
    while (true) {
        if (ctx.leftEndP(ctx.start) or syntaxEntryCode(ctx.peekLeft(ctx.start)) != @intFromEnum(SyntaxCode.word)) {
            return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
        }
        ctx.moveLeft(&ctx.start);
    }
}

// S-Expression Parsers

// DEFINE_PRIMITIVE ("SCAN-LIST-FORWARD", Prim_scan_list_forward, 7, 7, 0)
pub export fn Prim_scan_list_forward() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initForward();
    var depth = abi.arg_integer(5);
    const min_depth: c_long = if (depth >= 0) 0 else depth;
    const sexp_flag = obj.objectToBoolean(abi.argRef(6));
    var math_exit = false;

    while (true) {
        if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
        const c = ctx.first_char[ctx.start];
        var sentry = ctx.readRight(&ctx.start);

        var style: c_uint = 0;
        if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.comment)) {
            style = syntaxEntryCommentStyle(sentry, comstart_first);
        } else if (!ctx.rightEndP(ctx.start)) {
            style = syntaxEntryCommentStyle(sentry, comstart_first) &
                syntaxEntryCommentStyle(ctx.peekRight(ctx.start), comstart_second);
            if (style != 0) ctx.moveRight(&ctx.start);
        }
        if (style != 0) {
            if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
            while (true) {
                sentry = ctx.readRight(&ctx.start);
                if ((syntaxEntryCommentBits(sentry) & comend_first & style) != 0) {
                    if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.endcomment)) break;
                    if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
                    if ((syntaxEntryCommentBits(ctx.peekRight(ctx.start)) & comend_second & style) != 0) {
                        ctx.moveRight(&ctx.start);
                        break;
                    }
                }
            }
            continue;
        }
        if (syntaxEntryPrefix(sentry)) continue;

        switch (@as(SyntaxCode, @enumFromInt(syntaxEntryCode(sentry)))) {
            .escape, .charquote => {
                if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
                ctx.moveRight(&ctx.start);
                if (depth != 0 or !sexp_flag) continue;
                while (true) {
                    if (ctx.rightEndP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    const next_code: SyntaxCode = @enumFromInt(syntaxEntryCode(ctx.peekRight(ctx.start)));
                    switch (next_code) {
                        .escape, .charquote => {
                            ctx.moveRight(&ctx.start);
                            if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
                            ctx.moveRight(&ctx.start);
                        },
                        .word, .symbol => ctx.moveRight(&ctx.start),
                        else => return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start)),
                    }
                }
            },
            .word, .symbol => {
                if (depth != 0 or !sexp_flag) continue;
                while (true) {
                    if (ctx.rightEndP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    const next_code: SyntaxCode = @enumFromInt(syntaxEntryCode(ctx.peekRight(ctx.start)));
                    switch (next_code) {
                        .escape, .charquote => {
                            ctx.moveRight(&ctx.start);
                            if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
                            ctx.moveRight(&ctx.start);
                        },
                        .word, .symbol => ctx.moveRight(&ctx.start),
                        else => return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start)),
                    }
                }
            },
            .math => {
                if (!sexp_flag) continue;
                if (!ctx.rightEndP(ctx.start) and c == ctx.first_char[ctx.start]) ctx.moveRight(&ctx.start);
                if (math_exit) {
                    depth -= 1;
                    if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    if (depth < min_depth) return obj.sharp_f;
                    math_exit = false;
                } else {
                    depth += 1;
                    if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    math_exit = true;
                }
            },
            .open => {
                depth += 1;
                if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
            },
            .close => {
                depth -= 1;
                if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                if (depth < min_depth) return obj.sharp_f;
            },
            .string => {
                while (true) {
                    if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
                    if (c == ctx.first_char[ctx.start]) break;
                    sentry = ctx.readRight(&ctx.start);
                    if (syntaxEntryQuote(sentry)) {
                        if (ctx.rightEndP(ctx.start)) return obj.sharp_f;
                        ctx.moveRight(&ctx.start);
                    }
                }
                ctx.moveRight(&ctx.start);
                if (depth == 0 and sexp_flag) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
            },
            else => {},
        }
    }
}

// DEFINE_PRIMITIVE ("SCAN-LIST-BACKWARD", Prim_scan_list_backward, 7, 7, 0)
pub export fn Prim_scan_list_backward() callconv(.c) obj.SchemeObject {
    const ignore_comments = obj.objectToBoolean(abi.argRef(7));
    var ctx = ScanCtx.initBackward();
    var depth = abi.arg_integer(5);
    const min_depth: c_long = if (depth >= 0) 0 else depth;
    const sexp_flag = obj.objectToBoolean(abi.argRef(6));
    var math_exit = false;

    while (true) {
        if (ctx.leftEndP(ctx.start)) return obj.sharp_f;
        var quoted = ctx.leftQuotedP(ctx.start);
        var word_entry = false;
        var c: u8 = 0;
        var sentry: obj.SchemeObject = 0;

        if (quoted) {
            ctx.moveLeft(&ctx.start);
            sentry = ctx.readLeft(&ctx.start);
            word_entry = true;
        } else {
            c = ctx.first_char[ctx.start - 1];
            sentry = ctx.readLeft(&ctx.start);

            var style: c_uint = 0;
            if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.endcomment)) {
                if (ignore_comments) style = syntaxEntryCommentStyle(sentry, comend_second);
            } else if (!ctx.leftEndP(ctx.start)) {
                quoted = ctx.leftQuotedP(ctx.start);
                if (!quoted) {
                    style = syntaxEntryCommentStyle(sentry, comend_second) &
                        syntaxEntryCommentStyle(ctx.peekLeft(ctx.start), comend_first);
                    if (style != 0) ctx.moveLeft(&ctx.start);
                }
            }
            if (style != 0) {
                if (ctx.leftEndP(ctx.start)) return obj.sharp_f;
                while (true) {
                    sentry = ctx.readLeft(&ctx.start);
                    if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.comment) and
                        (syntaxEntryCommentBits(sentry) & comstart_first & style) != 0)
                    {
                        break;
                    }
                    if (ctx.leftEndP(ctx.start)) return obj.sharp_f;
                    if ((syntaxEntryCommentBits(sentry) & comstart_second & style) != 0 and
                        (syntaxEntryCommentBits(ctx.peekLeft(ctx.start)) & comstart_first & style) != 0)
                    {
                        ctx.moveLeft(&ctx.start);
                        break;
                    }
                }
                continue;
            }
        }

        const code: SyntaxCode = if (word_entry) .word else @enumFromInt(syntaxEntryCode(sentry));
        switch (code) {
            .word, .symbol => {
                if (depth != 0 or !sexp_flag) continue;
                while (true) {
                    if (ctx.leftEndP(ctx.start)) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    if (ctx.leftQuotedP(ctx.start)) {
                        ctx.moveLeft(&ctx.start);
                    } else {
                        sentry = ctx.peekLeft(ctx.start);
                        const prev_code = syntaxEntryCode(sentry);
                        if (prev_code != @intFromEnum(SyntaxCode.word) and prev_code != @intFromEnum(SyntaxCode.symbol)) {
                            return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                        }
                    }
                    ctx.moveLeft(&ctx.start);
                }
            },
            .math => {
                if (!sexp_flag) continue;
                if (!ctx.leftEndP(ctx.start) and c == ctx.first_char[ctx.start - 1]) ctx.moveLeft(&ctx.start);
                if (math_exit) {
                    depth -= 1;
                    if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    if (depth < min_depth) return obj.sharp_f;
                    math_exit = false;
                } else {
                    depth += 1;
                    if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                    math_exit = true;
                }
            },
            .close => {
                depth += 1;
                if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
            },
            .open => {
                depth -= 1;
                if (depth == 0) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
                if (depth < min_depth) return obj.sharp_f;
            },
            .string => {
                while (true) {
                    if (ctx.leftEndP(ctx.start)) return obj.sharp_f;
                    if (!ctx.leftQuotedP(ctx.start) and c == ctx.first_char[ctx.start - 1]) break;
                    ctx.moveLeft(&ctx.start);
                }
                ctx.moveLeft(&ctx.start);
                if (depth == 0 and sexp_flag) return obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start));
            },
            else => {},
        }
    }
}

// Partial S-Expression Parser

const level_array_length: usize = 100;
const LevelStruct = struct {
    last: ?usize = null,
    previous: ?usize = null,
};

const ssf_state_length: c_ulong = 9;
const ssf_state_depth: usize = 0;
const ssf_state_in_string_p: usize = 1;
const ssf_state_comment_state: usize = 2;
const ssf_state_quoted_p: usize = 3;
const ssf_state_start_of_sexp: usize = 4;
const ssf_state_last_sexp: usize = 5;
const ssf_state_containing_sexp: usize = 6;
const ssf_state_location: usize = 7;
const ssf_state_comment_start: usize = 8;

const SsfPhase = enum {
    main,
    in_comment_1,
    in_comment_2,
    in_comment_3,
    not_in_comment,
    start_quoted,
    start_quoted_in_string,
    start_in_string,
    start_atom,
    stop,
    done,
};

// DEFINE_PRIMITIVE ("SCAN-SEXPS-FORWARD", Prim_scan_sexps_forward, 7, 7, 0)
pub export fn Prim_scan_sexps_forward() callconv(.c) obj.SchemeObject {
    var ctx = ScanCtx.initForward();
    var target_depth = abi.arg_integer(5);
    const stop_before = obj.objectToBoolean(abi.argRef(6));
    const state_argument = abi.argRef(7);

    var depth: c_long = 0;
    var in_string: c_long = -1;
    var in_comment: c_uint = 0;
    var comment_style: c_uint = comment_style_a;
    var comment_start: usize = 0;
    var quoted = false;

    var levels: [level_array_length]LevelStruct = @splat(.{});
    var level_idx: usize = 0;
    var c: u8 = 0;
    var sentry: obj.SchemeObject = 0;

    if (state_argument == obj.sharp_f) {
        depth = 0;
        in_string = -1;
        in_comment = 0;
        quoted = false;
    } else if (obj.vectorP(state_argument) and obj.vectorLength(state_argument) == ssf_state_length) {
        var temp = obj.vectorRef(state_argument, ssf_state_depth);
        if (obj.fixnumP(temp)) {
            depth = obj.fixnumToLong(temp);
        } else {
            abi.error_bad_range_arg(7);
        }

        temp = obj.vectorRef(state_argument, ssf_state_in_string_p);
        if (temp == obj.sharp_f) {
            in_string = -1;
        } else if (obj.unsignedFixnumP(temp) and @as(c_ulong, @intCast(obj.unsignedFixnumToLong(temp))) < obj.max_ascii) {
            in_string = obj.unsignedFixnumToLong(temp);
        } else {
            abi.error_bad_range_arg(7);
        }

        temp = obj.vectorRef(state_argument, ssf_state_comment_state);
        if (temp == obj.sharp_f) {
            in_comment = 0;
        } else if (temp == obj.longToUnsignedFixnum(1)) {
            in_comment = 1;
            comment_style = comment_style_a;
        } else if (temp == obj.longToUnsignedFixnum(2)) {
            in_comment = 2;
            comment_style = comment_style_a;
        } else if (temp == obj.longToUnsignedFixnum(3)) {
            in_comment = 3;
            comment_style = comment_style_a;
        } else if (temp == obj.longToUnsignedFixnum(4)) {
            in_comment = 2;
            comment_style = comment_style_a | comment_style_b;
        } else if (temp == obj.longToUnsignedFixnum(5)) {
            in_comment = 1;
            comment_style = comment_style_b;
        } else if (temp == obj.longToUnsignedFixnum(6)) {
            in_comment = 2;
            comment_style = comment_style_b;
        } else if (temp == obj.longToUnsignedFixnum(7)) {
            in_comment = 3;
            comment_style = comment_style_b;
        } else {
            abi.error_bad_range_arg(7);
        }

        quoted = obj.objectToBoolean(obj.vectorRef(state_argument, ssf_state_quoted_p));
        if (in_comment != 0) {
            temp = obj.vectorRef(state_argument, ssf_state_comment_start);
            if (edwin.markP(temp)) {
                comment_start = ctx.indexToScan(edwin.markIndex(temp));
            } else if (obj.unsignedFixnumP(temp)) {
                comment_start = ctx.indexToScan(obj.unsignedFixnumToLong(temp));
            } else {
                abi.error_bad_range_arg(7);
            }
        }
        if (in_comment != 0 and (in_string != -1 or quoted)) abi.error_bad_range_arg(7);
    } else {
        abi.error_bad_range_arg(7);
    }

    abi.primitiveGcIfNeeded(ssf_state_length);

    const entry_phase: SsfPhase = switch (in_comment) {
        1 => .in_comment_1,
        2 => .in_comment_2,
        3 => .in_comment_3,
        else => if (quoted) blk: {
            quoted = false;
            break :blk if (in_string != -1) .start_quoted_in_string else .start_quoted;
        } else if (in_string != -1) .start_in_string else .main,
    };

    state: switch (entry_phase) {
        .main => {
            if (ctx.rightEndP(ctx.start)) continue :state .done;
            c = ctx.first_char[ctx.start];
            comment_start = ctx.start;
            sentry = ctx.readRight(&ctx.start);
            comment_style = syntaxEntryCommentStyle(sentry, comstart_first);
            if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.comment)) continue :state .in_comment_1;
            if (comment_style == 0) continue :state .not_in_comment;
            continue :state .in_comment_2;
        },
        .in_comment_2 => {
            in_comment = 2;
            if (ctx.rightEndP(ctx.start)) continue :state .done;
            comment_style &= syntaxEntryCommentStyle(ctx.peekRight(ctx.start), comstart_second);
            if (comment_style == 0) continue :state .not_in_comment;
            ctx.moveRight(&ctx.start);
            continue :state .in_comment_1;
        },
        .in_comment_1 => {
            in_comment = 1;
            if (ctx.rightEndP(ctx.start)) continue :state .done;
            sentry = ctx.readRight(&ctx.start);
            if ((syntaxEntryCommentBits(sentry) & comend_first & comment_style) != 0) {
                if (syntaxEntryCode(sentry) == @intFromEnum(SyntaxCode.endcomment)) {
                    in_comment = 0;
                    continue :state .main;
                }
                continue :state .in_comment_3;
            }
            continue :state .in_comment_1;
        },
        .in_comment_3 => {
            in_comment = 3;
            if (ctx.rightEndP(ctx.start)) continue :state .done;
            if ((syntaxEntryCommentBits(ctx.peekRight(ctx.start)) & comend_second & comment_style) != 0) {
                ctx.moveRight(&ctx.start);
                in_comment = 0;
                continue :state .main;
            }
            continue :state .in_comment_1;
        },
        .not_in_comment => {
            in_comment = 0;
            if (syntaxEntryPrefix(sentry)) continue :state .main;
            switch (@as(SyntaxCode, @enumFromInt(syntaxEntryCode(sentry)))) {
                .escape, .charquote => {
                    if (stop_before) continue :state .stop;
                    levels[level_idx].last = ctx.start;
                    continue :state .start_quoted;
                },
                .word, .symbol => {
                    if (stop_before) continue :state .stop;
                    levels[level_idx].last = ctx.start;
                    continue :state .start_atom;
                },
                .open => {
                    if (stop_before) continue :state .stop;
                    levels[level_idx].last = ctx.start;
                    depth += 1;
                    level_idx += 1;
                    if (level_idx == level_array_length) abi.error_bad_range_arg(5);
                    levels[level_idx] = .{};
                    target_depth -= 1;
                    if (target_depth == 0) continue :state .done;
                    continue :state .main;
                },
                .close => {
                    depth -= 1;
                    if (level_idx != 0) level_idx -= 1;
                    levels[level_idx].previous = levels[level_idx].last;
                    target_depth += 1;
                    if (target_depth == 0) continue :state .done;
                    continue :state .main;
                },
                .string => {
                    if (stop_before) continue :state .stop;
                    levels[level_idx].last = ctx.start;
                    in_string = c;
                    continue :state .start_in_string;
                },
                else => continue :state .main,
            }
        },
        .start_quoted => {
            if (ctx.rightEndP(ctx.start)) {
                quoted = true;
                continue :state .done;
            }
            ctx.moveRight(&ctx.start);
            continue :state .start_atom;
        },
        .start_atom => {
            while (!ctx.rightEndP(ctx.start)) {
                const next_code: SyntaxCode = @enumFromInt(syntaxEntryCode(ctx.peekRight(ctx.start)));
                switch (next_code) {
                    .escape, .charquote => {
                        ctx.moveRight(&ctx.start);
                        if (ctx.rightEndP(ctx.start)) {
                            quoted = true;
                            continue :state .done;
                        }
                        ctx.moveRight(&ctx.start);
                    },
                    .word, .symbol => ctx.moveRight(&ctx.start),
                    else => break,
                }
            }
            levels[level_idx].previous = levels[level_idx].last;
            continue :state .main;
        },
        .start_in_string => {
            while (true) {
                if (ctx.rightEndP(ctx.start)) continue :state .done;
                if (in_string == ctx.first_char[ctx.start]) break;
                sentry = ctx.readRight(&ctx.start);
                if (syntaxEntryQuote(sentry)) {
                    if (ctx.rightEndP(ctx.start)) {
                        quoted = true;
                        continue :state .done;
                    }
                    ctx.moveRight(&ctx.start);
                }
            }
            in_string = -1;
            levels[level_idx].previous = levels[level_idx].last;
            ctx.moveRight(&ctx.start);
            continue :state .main;
        },
        .start_quoted_in_string => {
            if (ctx.rightEndP(ctx.start)) {
                quoted = true;
                continue :state .done;
            }
            ctx.moveRight(&ctx.start);
            continue :state .start_in_string;
        },
        .stop => {
            if (ctx.start == ctx.gap_end) ctx.start = ctx.gap_start;
            ctx.start -= 1;
            continue :state .done;
        },
        .done => {},
    }

    const result = abi.allocate_vector(ssf_state_length, true);
    obj.vectorSet(result, ssf_state_depth, obj.longToFixnum(depth));
    obj.vectorSet(
        result,
        ssf_state_in_string_p,
        if (in_string == -1) obj.sharp_f else obj.longToUnsignedFixnum(in_string),
    );
    obj.vectorSet(
        result,
        ssf_state_comment_state,
        if (in_comment == 0)
            obj.sharp_f
        else
            obj.longToUnsignedFixnum(@intCast(if (in_comment == 2 and comment_style == (comment_style_a | comment_style_b))
                @as(c_uint, 4)
            else if (comment_style == comment_style_a)
                in_comment
            else
                in_comment + 4)),
    );
    obj.vectorSet(result, ssf_state_quoted_p, obj.booleanToObject(quoted));
    obj.vectorSet(
        result,
        ssf_state_start_of_sexp,
        if (levels[level_idx].last) |pos| obj.longToUnsignedFixnum(ctx.scanToIndex(pos) - 1) else obj.sharp_f,
    );
    obj.vectorSet(
        result,
        ssf_state_last_sexp,
        if (levels[level_idx].previous) |pos| obj.longToUnsignedFixnum(ctx.scanToIndex(pos) - 1) else obj.sharp_f,
    );
    obj.vectorSet(
        result,
        ssf_state_containing_sexp,
        if (level_idx == 0 or levels[level_idx - 1].last == null)
            obj.sharp_f
        else
            obj.longToUnsignedFixnum(ctx.scanToIndex(levels[level_idx - 1].last.?) - 1),
    );
    obj.vectorSet(result, ssf_state_location, obj.longToUnsignedFixnum(ctx.scanToIndex(ctx.start)));
    obj.vectorSet(
        result,
        ssf_state_comment_start,
        if (in_comment == 0) obj.sharp_f else obj.longToUnsignedFixnum(ctx.scanToIndex(comment_start)),
    );
    return result;
}

pub fn makeTestSyntaxTable() obj.SchemeObject {
    const tbl = abi.make_vector(0x100, obj.ulongToFixnum(@intFromEnum(SyntaxCode.whitespace)), true);
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) {
        obj.vectorSet(tbl, c, obj.ulongToFixnum(@intFromEnum(SyntaxCode.word)));
    }
    var uc: u8 = 'A';
    while (uc <= 'Z') : (uc += 1) {
        obj.vectorSet(tbl, uc, obj.ulongToFixnum(@intFromEnum(SyntaxCode.word)));
    }
    obj.vectorSet(tbl, '-', obj.ulongToFixnum(@intFromEnum(SyntaxCode.symbol)));
    obj.vectorSet(tbl, '"', obj.ulongToFixnum(@intFromEnum(SyntaxCode.string)));
    obj.vectorSet(tbl, '\\', obj.ulongToFixnum(@intFromEnum(SyntaxCode.escape)));
    obj.vectorSet(tbl, '\'', obj.ulongToFixnum(@intFromEnum(SyntaxCode.quote)));
    obj.vectorSet(tbl, ';', obj.ulongToFixnum(@intFromEnum(SyntaxCode.comment) | (comstart_first_a << 12)));
    obj.vectorSet(tbl, '\n', obj.ulongToFixnum(@intFromEnum(SyntaxCode.endcomment) | (comend_first_a << 12)));
    obj.vectorSet(tbl, '(', obj.ulongToFixnum(@intFromEnum(SyntaxCode.open) | (@as(c_ulong, ')') << 4)));
    obj.vectorSet(tbl, ')', obj.ulongToFixnum(@intFromEnum(SyntaxCode.close) | (@as(c_ulong, '(') << 4)));
    obj.vectorSet(tbl, '/', obj.ulongToFixnum(@intFromEnum(SyntaxCode.punct) | (comstart_first_b << 12) | (comend_second_b << 12)));
    obj.vectorSet(tbl, '*', obj.ulongToFixnum(@intFromEnum(SyntaxCode.punct) | (comstart_second_b << 12) | (comend_first_b << 12)));
    return tbl;
}

fn makeTestGroup(text_bytes: []const u8, gap_start_idx: usize, gap_len: usize) obj.SchemeObject {
    const buf = str.allocate_string(@intCast(text_bytes.len + gap_len));
    const dst = obj.legacyStringData(buf);
    @memcpy(dst[0..gap_start_idx], text_bytes[0..gap_start_idx]);
    @memset(dst[gap_start_idx .. gap_start_idx + gap_len], 'X');
    @memcpy(dst[gap_start_idx + gap_len .. text_bytes.len + gap_len], text_bytes[gap_start_idx..]);

    const g = abi.make_vector(17, obj.sharp_f, true);
    obj.vectorSet(g, 1, buf);
    obj.vectorSet(g, 2, obj.ulongToFixnum(@intCast(gap_start_idx)));
    obj.vectorSet(g, 3, obj.ulongToFixnum(@intCast(gap_len)));
    obj.vectorSet(g, 4, obj.ulongToFixnum(@intCast(gap_start_idx + gap_len)));
    return g;
}

test "syntax entry encoding, word/list scans across gap, and incremental scan-sexps-forward" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // STRING->SYNTAX-ENTRY & CHAR->SYNTAX-CODE
    stubs.setArgs(&.{str.char_pointer_to_string("() 12p")});
    const entry = Prim_string_to_syntax_entry();
    const expected = @intFromEnum(SyntaxCode.open) | (@as(c_ulong, ')') << 4) |
        ((comstart_first_b | comstart_second_b) << 12) | (@as(c_ulong, 1) << 20);
    try std.testing.expectEqual(obj.ulongToFixnum(expected), entry);

    const tbl = makeTestSyntaxTable();
    stubs.setArgs(&.{ tbl, obj.asciiToChar('a') });
    try std.testing.expectEqual(obj.asciiToChar('w'), Prim_char_to_syntax_code());

    // Gap right in the middle of "hello /* c */ (ab \"\\\"cd\")"
    const text = "  'hello /* c */ (ab \"\\\"cd\") foo";
    const g = makeTestGroup(text, 7, 5);

    // QUOTED-CHAR? on escaped quote at index 22 ('\"')
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(23), obj.ulongToFixnum(0) });
    try std.testing.expectEqual(obj.sharp_t, Prim_quoted_char_p());
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(22), obj.ulongToFixnum(0) });
    try std.testing.expectEqual(obj.sharp_f, Prim_quoted_char_p());

    // SCAN-WORD-FORWARD across gap starting at index 0 -> ends at "hello" (index 8)
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(0), obj.ulongToFixnum(text.len) });
    try std.testing.expectEqual(obj.ulongToFixnum(8), Prim_scan_word_forward());

    // SCAN-WORD-BACKWARD across gap from index 10 -> start of "hello" (index 3)
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(10), obj.ulongToFixnum(0) });
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_scan_word_backward());

    // SCAN-LIST-FORWARD skips comment /* c */ and scans balanced list ending after ')' at index 28
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(8), obj.ulongToFixnum(text.len), obj.longToFixnum(0), obj.sharp_t });
    try std.testing.expectEqual(obj.ulongToFixnum(28), Prim_scan_list_forward());

    // SCAN-LIST-BACKWARD from 29 ignores /* c */ comment and finds '(' at 17, or scans "'hello"
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(28), obj.ulongToFixnum(0), obj.longToFixnum(0), obj.sharp_t, obj.sharp_t });
    try std.testing.expectEqual(obj.ulongToFixnum(17), Prim_scan_list_backward());

    // SCAN-SEXPS-FORWARD split across end of '/*' comment chunk
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(0), obj.ulongToFixnum(12), obj.longToFixnum(100), obj.sharp_f, obj.sharp_f });
    const st1 = Prim_scan_sexps_forward();
    try std.testing.expectEqual(obj.ulongToFixnum(5), obj.vectorRef(st1, ssf_state_comment_state)); // in_comment=1, style B
    stubs.setArgs(&.{ tbl, g, obj.ulongToFixnum(12), obj.ulongToFixnum(text.len), obj.longToFixnum(1), obj.sharp_f, st1 });
    const st2 = Prim_scan_sexps_forward();
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(st2, ssf_state_comment_state));
    try std.testing.expectEqual(obj.ulongToFixnum(18), obj.vectorRef(st2, ssf_state_location)); // stopped right after '('
}
