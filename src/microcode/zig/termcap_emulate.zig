// Derived from GNU termcap sources (`src/microcode/termcap.c`, `src/microcode/tparam.c`):
// Copyright (C) 1985, 1986, 1987 Free Software Foundation, Inc.
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("prim_abi.zig");

extern "c" fn rewind(stream: *std.c.FILE) void;

const bufsize_initial: usize = 2048;
const max_tc_indirections: usize = 32;

pub var BC: ?[*:0]u8 = null;
pub var UP: ?[*:0]u8 = null;
pub var PC: u8 = 0;
pub var ospeed: c_short = 0;

var term_entry: ?[*:0]const u8 = null;
var owned_term_entry: ?[*]u8 = null;

comptime {
    if (!builtin.is_test and build_options.use_termcap and !build_options.use_terminfo) {
        @export(&BC, .{ .name = "BC" });
        @export(&UP, .{ .name = "UP" });
        @export(&PC, .{ .name = "PC" });
        @export(&ospeed, .{ .name = "ospeed" });
        @export(&tgetent, .{ .name = "tgetent" });
        @export(&tgetnum, .{ .name = "tgetnum" });
        @export(&tgetflag, .{ .name = "tgetflag" });
        @export(&tgetstr, .{ .name = "tgetstr" });
        @export(&tgoto, .{ .name = "tgoto" });
        @export(&tputs, .{ .name = "tputs" });
        @export(&tparam, .{ .name = "tparam" });
    }
}

fn convertOspeed(os: u16) c_int {
    const rate: u32 = abi.OS_baud_index_to_rate(@intCast(os));
    if (rate >= 300) {
        return -@as(c_int, @intCast(rate / 100));
    }
    return @intCast(rate);
}

fn findCapability(bp_opt: ?[*:0]const u8, cap0: u8, cap1: u8) ?[*]const u8 {
    const bp = bp_opt orelse return null;
    if (cap0 == 0 or cap1 == 0) return null;
    var i: usize = 0;
    while (bp[i] != 0) : (i += 1) {
        if (bp[i] == ':' and bp[i + 1] == cap0 and bp[i + 2] == cap1 and bp[i + 3] != 0) {
            return bp + i + 4;
        }
    }
    return null;
}

pub fn tgetnum(cap: [*:0]const u8) callconv(.c) c_int {
    const ptr = findCapability(term_entry, cap[0], cap[1]) orelse return -1;
    if ((ptr - 1)[0] != '#') return -1;
    var i: usize = 0;
    while (ptr[i] == ' ' or ptr[i] == '\t') : (i += 1) {}
    var neg = false;
    if (ptr[i] == '-') {
        neg = true;
        i += 1;
    } else if (ptr[i] == '+') {
        i += 1;
    }
    var val: c_int = 0;
    while (ptr[i] >= '0' and ptr[i] <= '9') : (i += 1) {
        val = val *% 10 +% @as(c_int, ptr[i] - '0');
    }
    return if (neg) -%val else val;
}

pub fn tgetflag(cap: [*:0]const u8) callconv(.c) c_int {
    const ptr = findCapability(term_entry, cap[0], cap[1]) orelse return 0;
    return @intFromBool((ptr - 1)[0] == ':');
}

fn tgetst1(ptr_opt: ?[*]const u8, area: ?*[*]u8) ?[*:0]u8 {
    const ptr = ptr_opt orelse return null;

    const ret: [*]u8 = if (area) |a| a.* else blk: {
        var len: usize = 0;
        while (ptr[len] != 0 and ptr[len] != ':' and ptr[len] != '\n') : (len += 1) {}
        const raw = std.c.malloc(len + 1) orelse return null;
        break :blk @ptrCast(raw);
    };

    var p: usize = 0;
    var r: usize = 0;
    while (ptr[p] != 0 and ptr[p] != ':' and ptr[p] != '\n') {
        var c: u8 = ptr[p];
        p += 1;
        if (c == '^') {
            const next = ptr[p];
            if (next == 0) break;
            p += 1;
            c = next & 0o37;
        } else if (c == '\\') {
            const next = ptr[p];
            if (next == 0) break;
            p += 1;
            if (next >= '0' and next <= '7') {
                var oct: u8 = next - '0';
                var digits: usize = 0;
                while (digits < 2 and ptr[p] >= '0' and ptr[p] <= '7') : (digits += 1) {
                    oct = (oct *% 8) +% (ptr[p] - '0');
                    p += 1;
                }
                c = oct;
            } else {
                const upper = next & ~@as(u8, 0o40);
                c = switch (upper) {
                    'A' => 0o007,
                    'B' => 0o010,
                    'E' => 0o033,
                    'F' => 0o014,
                    'N' => 0o012,
                    'R' => 0o015,
                    'T' => 0o011,
                    'V' => 0o013,
                    else => next,
                };
            }
        }
        ret[r] = c;
        r += 1;
    }
    ret[r] = 0;

    if (area) |a| {
        a.* = ret + r + 1;
    }
    return @ptrCast(ret);
}

pub fn tgetstr(cap: [*:0]const u8, area: ?*[*]u8) callconv(.c) ?[*:0]u8 {
    const ptr = findCapability(term_entry, cap[0], cap[1]) orelse return null;
    const delim = (ptr - 1)[0];
    if (delim != '=' and delim != '~') return null;
    return tgetst1(ptr, area);
}

pub fn tputs(
    str_opt: ?[*:0]const u8,
    nlines: c_int,
    outfun: *const fn (c_int) callconv(.c) c_int,
) callconv(.c) c_int {
    const str = str_opt orelse return 0;
    var i: usize = 0;
    var padcount: c_int = 0;

    while (str[i] >= '0' and str[i] <= '9') : (i += 1) {
        padcount = padcount *% 10 +% @as(c_int, str[i] - '0');
    }
    padcount = padcount *% 10;
    if (str[i] == '.' and str[i + 1] != 0) {
        i += 1;
        if (str[i] >= '0' and str[i] <= '9') {
            padcount = padcount +% @as(c_int, str[i] - '0');
        }
        i += 1;
    }
    if (str[i] == '*') {
        i += 1;
        padcount = padcount *% nlines;
    }
    while (str[i] != 0) : (i += 1) {
        _ = outfun(@intCast(str[i]));
    }

    const speed = convertOspeed(@bitCast(ospeed));
    padcount = padcount *% speed;
    padcount +%= 500;
    padcount = @divTrunc(padcount, 1000);
    if (speed < 0) {
        padcount = -padcount;
    } else {
        padcount +%= 50;
        padcount = @divTrunc(padcount, 100);
    }

    while (padcount > 0) : (padcount -= 1) {
        _ = outfun(@intCast(PC));
    }
    return 0;
}

const ScanBuffer = struct {
    beg: [*]u8,
    size: usize,
    ptr: usize,
    full: usize,
    ateof: bool,
};

fn isAbsoluteTermcapPath(path: [*:0]const u8) bool {
    if (path[0] == '/') return true;
    if (comptime builtin.os.tag == .windows) {
        if (path[0] == '\\') return true;
        if (path[0] != 0 and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) {
            return true;
        }
    }
    return false;
}

fn gobbleLine(fp: *std.c.FILE, bufp: *ScanBuffer, append_opt: ?usize) ?usize {
    var append_off = append_opt orelse bufp.ptr;

    while (true) {
        var end = append_off;
        while (bufp.beg[end] != 0 and bufp.beg[end] != '\n') : (end += 1) {}
        if (bufp.beg[end] != 0) {
            return end + 1;
        }
        if (bufp.ateof) {
            return bufp.full;
        }
        if (bufp.ptr == 0) {
            if (bufp.full == bufp.size) {
                const new_size = bufp.size * 2;
                const grown = std.c.realloc(bufp.beg, new_size + 1) orelse return null;
                bufp.beg = @ptrCast(grown);
                bufp.size = new_size;
            }
        } else {
            const len = bufp.full - bufp.ptr;
            std.mem.copyForwards(u8, bufp.beg[0..len], bufp.beg[bufp.ptr..bufp.full]);
            append_off -= bufp.ptr;
            bufp.ptr = 0;
            bufp.full = len;
            bufp.beg[bufp.full] = 0;
        }

        const avail = bufp.size - bufp.full;
        const nread = std.c.fread(bufp.beg + bufp.full, 1, avail, fp);
        if (nread == 0) {
            bufp.ateof = true;
        } else {
            bufp.full += nread;
        }
        bufp.beg[bufp.full] = 0;
    }
}

fn compareContin(line: [*]const u8, target: [*:0]const u8) bool {
    var idx1: usize = 0;
    var idx2: usize = 0;
    while (true) {
        var c1 = line[idx1];
        idx1 += 1;
        const c2 = target[idx2];
        idx2 += 1;
        while (true) {
            if (c1 == '\\' and line[idx1] == '\n') {
                idx1 += 1;
            } else if (c1 == '\\' and line[idx1] == '\r' and line[idx1 + 1] == '\n') {
                idx1 += 2;
            } else {
                break;
            }
            while (line[idx1] == ' ' or line[idx1] == '\t') : (idx1 += 1) {}
            c1 = line[idx1];
            idx1 += 1;
        }
        if (c2 == 0) {
            return c1 == '|' or c1 == ':';
        }
        if (c1 != c2) return false;
    }
}

fn nameMatch(line: [*]const u8, name: [*:0]const u8) bool {
    if (compareContin(line, name)) return true;
    var i: usize = 0;
    while (line[i] != 0 and line[i] != '\n' and line[i] != ':') : (i += 1) {
        if (line[i] == '|' and compareContin(line + i + 1, name)) {
            return true;
        }
    }
    return false;
}

fn isLineContinued(beg: [*]const u8, start: usize, end: usize) bool {
    if (end >= start + 2 and beg[end - 2] == '\\') return true;
    if (end >= start + 3 and beg[end - 2] == '\r' and beg[end - 3] == '\\') return true;
    return false;
}

fn scanFile(target: [*:0]const u8, fp: *std.c.FILE, bufp: *ScanBuffer) bool {
    bufp.ptr = 0;
    bufp.full = 0;
    bufp.ateof = false;
    bufp.beg[0] = 0;

    rewind(fp);

    while (!bufp.ateof) {
        var end_opt: ?usize = null;
        while (true) {
            end_opt = gobbleLine(fp, bufp, end_opt);
            const end = end_opt orelse return false;
            if (bufp.ateof or !isLineContinued(bufp.beg, bufp.ptr, end)) break;
        }
        const end = end_opt orelse return false;
        if (bufp.ptr < end and bufp.beg[bufp.ptr] != '#' and nameMatch(bufp.beg + bufp.ptr, target)) {
            return true;
        }
        bufp.ptr = end;
    }
    return false;
}

pub fn tgetent(bp_arg: ?[*]u8, name: [*:0]const u8) callconv(.c) c_int {
    var tem: ?[*:0]const u8 = std.c.getenv("TERMCAP");
    if (tem) |t| {
        if (t[0] == 0) tem = null;
    }

    const filep = if (tem) |t| isAbsoluteTermcapPath(t) else false;
    var tcenv: ?[*:0]const u8 = null;
    var indirect: ?[*:0]u8 = null;

    if (tem != null and !filep) {
        const term_env = std.c.getenv("TERM");
        if (term_env != null and std.mem.eql(u8, std.mem.span(name), std.mem.span(term_env.?))) {
            const t = tem.?;
            indirect = tgetst1(findCapability(t, 't', 'c'), null);
            if (indirect == null) {
                if (bp_arg) |bp| {
                    const slice = std.mem.span(t);
                    @memcpy(bp[0 .. slice.len + 1], slice.ptr[0 .. slice.len + 1]);
                    term_entry = @ptrCast(bp);
                } else {
                    term_entry = t;
                }
                return 1;
            } else {
                tcenv = t;
                tem = null;
            }
        }
    }

    const path: [*:0]const u8 = tem orelse "/etc/termcap";
    const fp = std.c.fopen(path, "rb") orelse {
        if (indirect) |ind| std.c.free(ind);
        return -1;
    };
    defer _ = std.c.fclose(fp);

    const raw_buf = std.c.malloc(bufsize_initial + 1) orelse {
        if (indirect) |ind| std.c.free(ind);
        return -1;
    };
    var scan_buf = ScanBuffer{
        .beg = @ptrCast(raw_buf),
        .size = bufsize_initial,
        .ptr = 0,
        .full = 0,
        .ateof = false,
    };
    defer std.c.free(scan_buf.beg);

    var term: ?[*:0]const u8 = if (indirect) |ind| ind else name;
    var term_owned: bool = (indirect != null);
    defer {
        if (term_owned) {
            if (term) |t| std.c.free(@constCast(t));
        }
    }

    const dynamic_alloc: bool = (bp_arg == null);
    var alloc_cap: usize = 0;
    var bp: [*]u8 = if (bp_arg) |caller_bp| caller_bp else blk: {
        alloc_cap = if (tcenv) |tc| std.mem.span(tc).len + 1 else scan_buf.size;
        const mem = std.c.malloc(alloc_cap) orelse return -1;
        break :blk @ptrCast(mem);
    };
    var bp_len: usize = 0;

    if (indirect != null) {
        const tc_slice = std.mem.span(tcenv.?);
        @memcpy(bp[0 .. tc_slice.len + 1], tc_slice.ptr[0 .. tc_slice.len + 1]);
        bp_len = tc_slice.len;
    }

    var hops: usize = 0;
    while (term) |cur_term| {
        if (hops >= max_tc_indirections) {
            if (dynamic_alloc) std.c.free(bp);
            return 0;
        }
        hops += 1;

        if (!scanFile(cur_term, fp, &scan_buf)) {
            if (dynamic_alloc) std.c.free(bp);
            return 0;
        }

        if (term_owned) {
            std.c.free(@constCast(cur_term));
            term = null;
            term_owned = false;
        }

        if (dynamic_alloc) {
            const needed = bp_len + scan_buf.size + 1;
            if (needed > alloc_cap) {
                const grown = std.c.realloc(bp, needed) orelse {
                    std.c.free(bp);
                    return -1;
                };
                bp = @ptrCast(grown);
                alloc_cap = needed;
            }
        }

        const chunk_start = bp_len;
        var src_i = scan_buf.ptr;
        while (src_i < scan_buf.full) {
            const c = scan_buf.beg[src_i];
            src_i += 1;
            if (c == 0 or c == '\n') break;
            if (c == '\r' and scan_buf.beg[src_i] == '\n') continue;
            if (c == '\\') {
                if (scan_buf.beg[src_i] == '\n') {
                    src_i += 1;
                    continue;
                }
                if (scan_buf.beg[src_i] == '\r' and scan_buf.beg[src_i + 1] == '\n') {
                    src_i += 2;
                    continue;
                }
            }
            if (bp_arg == null or bp_len + 1 < bufsize_initial) {
                bp[bp_len] = c;
                bp_len += 1;
            }
        }
        bp[bp_len] = 0;

        if (findCapability(@ptrCast(bp + chunk_start), 't', 'c')) |tc_ptr| {
            const next_tc = tgetst1(tc_ptr, null);
            term = next_tc;
            term_owned = (next_tc != null);
        } else {
            term = null;
        }
    }

    if (dynamic_alloc) {
        if (std.c.realloc(bp, bp_len + 1)) |shrunk| {
            bp = @ptrCast(shrunk);
        }
        if (owned_term_entry) |old| std.c.free(old);
        owned_term_entry = bp;
    }

    term_entry = @ptrCast(bp);
    return 1;
}

fn ensureCapacity(
    outstring_ref: *[*]u8,
    op_ref: *usize,
    cap_ref: *usize,
    heap_owned_ref: *bool,
    needed_extra: usize,
) bool {
    if (op_ref.* + needed_extra < cap_ref.*) return true;
    const grow = @max(@as(usize, 40), needed_extra + 16);
    if (!heap_owned_ref.*) {
        const new_cap = cap_ref.* + grow;
        const raw = std.c.malloc(new_cap) orelse return false;
        const dst: [*]u8 = @ptrCast(raw);
        if (op_ref.* > 0) {
            @memcpy(dst[0..op_ref.*], outstring_ref.*[0..op_ref.*]);
        }
        outstring_ref.* = dst;
        cap_ref.* = new_cap;
        heap_owned_ref.* = true;
    } else {
        const new_cap = cap_ref.* * 2 + needed_extra;
        const raw = std.c.realloc(outstring_ref.*, new_cap) orelse {
            std.c.free(outstring_ref.*);
            return false;
        };
        outstring_ref.* = @ptrCast(raw);
        cap_ref.* = new_cap;
    }
    return true;
}

inline fn argPtr(base: [*]c_int, idx: isize) [*]c_int {
    const base_addr: isize = @bitCast(@intFromPtr(base));
    const byte_off: isize = idx *% @as(isize, @sizeOf(c_int));
    return @ptrFromInt(@as(usize, @bitCast(base_addr +% byte_off)));
}

pub fn tparam1(
    string: [*:0]const u8,
    outstring_arg: [*]u8,
    len: c_int,
    up_opt: ?[*:0]const u8,
    left_opt: ?[*:0]const u8,
    argp_in: [*]c_int,
) callconv(.c) ?[*:0]u8 {
    if (len < 0) return null;
    var outstring = outstring_arg;
    var cap: usize = @intCast(len);
    var heap_owned = false;
    var op: usize = 0;

    var p: usize = 0;
    var arg_idx: isize = 0;
    var orig_idx: isize = 0;
    var doleft: usize = 0;
    var doup: usize = 0;

    const up_len: usize = if (up_opt) |up| std.mem.span(up).len else 0;
    const left_len: usize = if (left_opt) |left| std.mem.span(left).len else 0;

    while (true) {
        if (!ensureCapacity(&outstring, &op, &cap, &heap_owned, 5)) return null;
        const c = string[p];
        if (c == 0) break;
        p += 1;
        if (c == '%') {
            const cmd = string[p];
            if (cmd == 0) break;
            p += 1;
            var tem: c_int = argPtr(argp_in, arg_idx)[0];
            switch (cmd) {
                'd', '3', '2' => {
                    if (cmd == 'd' or cmd == '3') {
                        if (cmd == 'd' and tem < 10) {
                            outstring[op] = @intCast(@rem(tem, 10) + '0');
                            op += 1;
                            arg_idx += 1;
                            continue;
                        }
                        if (cmd == 'd' and tem < 100) {
                            const t2 = @rem(tem, 100);
                            outstring[op] = @intCast(@divTrunc(t2, 10) + '0');
                            op += 1;
                            outstring[op] = @intCast(@rem(t2, 10) + '0');
                            op += 1;
                            arg_idx += 1;
                            continue;
                        }
                        if (tem > 999) {
                            outstring[op] = @intCast(@divTrunc(tem, 1000) + '0');
                            op += 1;
                            tem = @rem(tem, 1000);
                        }
                        outstring[op] = @intCast(@divTrunc(tem, 100) + '0');
                        op += 1;
                    }
                    const t2 = @rem(tem, 100);
                    outstring[op] = @intCast(@divTrunc(t2, 10) + '0');
                    op += 1;
                    outstring[op] = @intCast(@rem(t2, 10) + '0');
                    op += 1;
                    arg_idx += 1;
                },
                'C', '+', '.' => {
                    if (cmd == 'C') {
                        if (tem >= 96) {
                            outstring[op] = @intCast(@divTrunc(tem, 96));
                            op += 1;
                            tem = @rem(tem, 96);
                        }
                    }
                    if (cmd == 'C' or cmd == '+') {
                        tem +%= @as(c_int, string[p]);
                        if (string[p] != 0) p += 1;
                    }
                    if (left_opt != null) {
                        while (tem == 0 or tem == '\n' or tem == '\t') {
                            tem +%= 1;
                            if (arg_idx == orig_idx) {
                                doup += 1;
                            } else {
                                doleft += 1;
                            }
                        }
                    }
                    const byte_val: u8 = @truncate(@as(c_uint, @bitCast(tem)));
                    outstring[op] = byte_val | 0o200;
                    op += 1;
                    arg_idx += 1;
                },
                'f' => {
                    arg_idx += 1;
                },
                'b' => {
                    arg_idx -= 1;
                },
                'r' => {
                    const ptr = argPtr(argp_in, arg_idx);
                    ptr[0] = ptr[1];
                    ptr[1] = tem;
                    orig_idx += 1;
                },
                '>' => {
                    const thresh: c_int = @as(c_int, string[p]);
                    if (string[p] != 0) p += 1;
                    const delta: c_int = @as(c_int, string[p]);
                    if (string[p] != 0) p += 1;
                    const ptr = argPtr(argp_in, arg_idx);
                    if (ptr[0] > thresh) {
                        ptr[0] +%= delta;
                    }
                },
                'a' => {
                    if (string[p] == 0 or string[p + 1] == 0 or string[p + 2] == 0) break;
                    const op_ch = string[p];
                    const mode_ch = string[p + 1];
                    const val_ch = string[p + 2];
                    var operand: c_int = @intCast(val_ch & 0o177);
                    if (mode_ch == 'p') {
                        operand = argPtr(argp_in, arg_idx + (@as(isize, operand) - 0o100))[0];
                    }
                    const ptr = argPtr(argp_in, arg_idx);
                    switch (op_ch) {
                        '-' => ptr[0] -%= operand,
                        '+' => ptr[0] +%= operand,
                        '*' => ptr[0] *%= operand,
                        '/' => if (operand != 0) {
                            ptr[0] = @divTrunc(ptr[0], operand);
                        },
                        else => ptr[0] = operand,
                    }
                    p += 3;
                },
                'i' => {
                    const ptr = argPtr(argp_in, arg_idx);
                    ptr[0] +%= 1;
                    ptr[1] +%= 1;
                },
                '%' => {
                    outstring[op] = '%';
                    op += 1;
                },
                'n' => {
                    const ptr = argPtr(argp_in, arg_idx);
                    ptr[0] ^= 0o140;
                    ptr[1] ^= 0o140;
                },
                'm' => {
                    const ptr = argPtr(argp_in, arg_idx);
                    ptr[0] ^= 0o177;
                    ptr[1] ^= 0o177;
                },
                'B' => {
                    const ptr = argPtr(argp_in, arg_idx);
                    ptr[0] +%= 6 * @divTrunc(tem, 10);
                },
                'D' => {
                    const ptr = argPtr(argp_in, arg_idx);
                    ptr[0] -%= 2 * @rem(tem, 16);
                },
                else => {},
            }
        } else {
            outstring[op] = c;
            op += 1;
        }
    }

    const tail_bytes = (doup * up_len) + (doleft * left_len);
    if (!ensureCapacity(&outstring, &op, &cap, &heap_owned, tail_bytes + 1)) return null;

    if (up_opt) |up| {
        const slice = up[0..up_len];
        for (0..doup) |_| {
            @memcpy(outstring[op .. op + up_len], slice);
            op += up_len;
        }
    }
    if (left_opt) |left| {
        const slice = left[0..left_len];
        for (0..doleft) |_| {
            @memcpy(outstring[op .. op + left_len], slice);
            op += left_len;
        }
    }
    outstring[op] = 0;
    return @ptrCast(outstring);
}

pub fn tparam(
    string: [*:0]const u8,
    outstring: [*]u8,
    len: c_int,
    a1: c_int,
    a2: c_int,
    a3: c_int,
    a4: c_int,
) callconv(.c) ?[*:0]u8 {
    var args = [4]c_int{ a1, a2, a3, a4 };
    return tparam1(string, outstring, len, null, null, &args);
}

pub fn tgoto(cm_opt: ?[*:0]const u8, hpos: c_int, vpos: c_int) callconv(.c) ?[*:0]u8 {
    const cm = cm_opt orelse return null;
    const raw = std.c.malloc(64) orelse return null;
    const init_buf: [*]u8 = @ptrCast(raw);
    var args = [2]c_int{ vpos, hpos };
    const result = tparam1(cm, init_buf, 64, UP, BC, &args) orelse {
        std.c.free(init_buf);
        return null;
    };
    if (@as([*]u8, @ptrCast(result)) != init_buf) {
        std.c.free(init_buf);
    }
    return result;
}

test "termcap_emulate tgetent, tgetnum, tgetflag, tgetstr with continuations and tc" {
    const saved_entry = term_entry;
    const saved_owned = owned_term_entry;
    const saved_bc = BC;
    const saved_up = UP;
    const saved_pc = PC;
    const saved_ospeed = ospeed;
    const saved_env_tc = std.c.getenv("TERMCAP");
    const saved_env_term = std.c.getenv("TERM");

    const EnvHelper = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        extern "c" fn getpid() c_int;
    };

    defer {
        term_entry = saved_entry;
        if (owned_term_entry != saved_owned) {
            if (owned_term_entry) |p| std.c.free(p);
        }
        owned_term_entry = saved_owned;
        BC = saved_bc;
        UP = saved_up;
        PC = saved_pc;
        ospeed = saved_ospeed;
        if (saved_env_tc) |v| {
            _ = EnvHelper.setenv("TERMCAP", v, 1);
        } else {
            _ = EnvHelper.unsetenv("TERMCAP");
        }
        if (saved_env_term) |v| {
            _ = EnvHelper.setenv("TERM", v, 1);
        } else {
            _ = EnvHelper.unsetenv("TERM");
        }
    }

    const tc_contents =
        "# comment line\n" ++
        "base-term|Alias Base:\\\n" ++
        "\t:co#80:li#24:am:\\\n" ++
        "\t:cl=\\E[H\\E[2J:ku=\\033OA:nl=\\n\\r\\t\\b\\f\\v\\a:ct=^A:\n" ++
        "sub-term|Sub Term:\\\n" ++
        "\t:li#40:tc=base-term:\n";

    var path_buf: [128]u8 = undefined;
    const path_slice = try std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "/tmp/zig-termcap-test-{d}.db", .{EnvHelper.getpid()});
    path_buf[path_slice.len] = 0;
    const tc_path: [*:0]const u8 = @ptrCast(path_buf[0..path_slice.len :0]);

    const wf = std.c.fopen(tc_path, "wb") orelse return error.OpenFailed;
    defer _ = std.c.unlink(tc_path);
    const written = std.c.fwrite(tc_contents.ptr, 1, tc_contents.len, wf);
    _ = std.c.fclose(wf);
    try std.testing.expectEqual(tc_contents.len, written);

    try std.testing.expectEqual(@as(c_int, 0), EnvHelper.setenv("TERMCAP", tc_path, 1));

    // Caller-supplied buffer with :tc= indirection and continuation lines.
    var bp: [2048]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 1), tgetent(&bp, "sub-term"));
    try std.testing.expectEqual(@as(c_int, 40), tgetnum("li"));
    try std.testing.expectEqual(@as(c_int, 80), tgetnum("co"));
    try std.testing.expectEqual(@as(c_int, -1), tgetnum("xx"));
    try std.testing.expectEqual(@as(c_int, 1), tgetflag("am"));
    try std.testing.expectEqual(@as(c_int, 0), tgetflag("bw"));

    var str_buf: [512]u8 = undefined;
    var area: [*]u8 = &str_buf;
    const cl = tgetstr("cl", &area) orelse return error.MissingCap;
    try std.testing.expectEqualStrings("\x1b[H\x1b[2J", std.mem.span(cl));
    const ku = tgetstr("ku", &area) orelse return error.MissingCap;
    try std.testing.expectEqualStrings("\x1bOA", std.mem.span(ku));
    const nl = tgetstr("nl", &area) orelse return error.MissingCap;
    try std.testing.expectEqualStrings("\n\r\t\x08\x0c\x0b\x07", std.mem.span(nl));
    const ct = tgetstr("ct", &area) orelse return error.MissingCap;
    try std.testing.expectEqualStrings("\x01", std.mem.span(ct));
    try std.testing.expect(@intFromPtr(area) > @intFromPtr(&str_buf));

    // Missing terminal returns 0.
    try std.testing.expectEqual(@as(c_int, 0), tgetent(&bp, "missing-term"));

    // Dynamic allocation when bp == null and inline TERMCAP env var.
    try std.testing.expectEqual(@as(c_int, 1), tgetent(null, "Alias Base"));
    try std.testing.expectEqual(@as(c_int, 80), tgetnum("co"));
    const cl_heap = tgetstr("cl", null) orelse return error.MissingCap;
    defer std.c.free(cl_heap);
    try std.testing.expectEqualStrings("\x1b[H\x1b[2J", std.mem.span(cl_heap));

    try std.testing.expectEqual(@as(c_int, 0), EnvHelper.setenv("TERM", "inline-vt", 1));
    try std.testing.expectEqual(@as(c_int, 0), EnvHelper.setenv("TERMCAP", "inline-vt:co#132:am:", 1));
    try std.testing.expectEqual(@as(c_int, 1), tgetent(&bp, "inline-vt"));
    try std.testing.expectEqual(@as(c_int, 132), tgetnum("co"));
    try std.testing.expectEqual(@as(c_int, 1), tgetflag("am"));
}

test "termcap_emulate tparam, tgoto, and tputs" {
    const saved_bc = BC;
    const saved_up = UP;
    const saved_pc = PC;
    const saved_ospeed = ospeed;
    defer {
        BC = saved_bc;
        UP = saved_up;
        PC = saved_pc;
        ospeed = saved_ospeed;
    }

    // Standard %i/%d/%2/%3/%r/%% formatting
    var out: [128]u8 = undefined;
    const cm = tparam("\x1b[%i%d;%dH%%", &out, out.len, 9, 19, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("\x1b[10;20H%", std.mem.span(cm));

    const pad_fmt = tparam("%r%3:%2:%d", &out, out.len, 5, 7, 123, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("007:05:123", std.mem.span(pad_fmt));

    // Arithmetic %a+c / %a-p / %> / %B / %D / %n / %m
    const arith_c = tparam("%a+cA%d", &out, out.len, 10, 0, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("75", std.mem.span(arith_c));
    const arith_p = tparam("%a-pA%d", &out, out.len, 100, 25, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("75", std.mem.span(arith_p));
    const bcd = tparam("%B%d", &out, out.len, 25, 0, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("37", std.mem.span(bcd));
    const delta = tparam("%D%d", &out, out.len, 25, 0, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("7", std.mem.span(delta));
    const gt = tparam("%>AZ%d", &out, out.len, 70, 0, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("160", std.mem.span(gt));
    const xor_n = tparam("%n%d:%d", &out, out.len, 0, 1, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("96:97", std.mem.span(xor_n));
    const xor_m = tparam("%m%d:%d", &out, out.len, 0, 1, 0, 0) orelse return error.TparamFailed;
    try std.testing.expectEqualStrings("127:126", std.mem.span(xor_m));

    // Small caller buffer growth allocates heap string (and reallocates) without corrupting output.
    var tiny: [8]u8 = undefined;
    const grown = tparam(
        "prefix-0123456789-0123456789-0123456789-%d-%d-%d-%d-suffix",
        &tiny,
        tiny.len,
        100,
        200,
        300,
        400,
    ) orelse return error.TparamFailed;
    defer if (@intFromPtr(grown) != @intFromPtr(&tiny)) std.c.free(grown);
    try std.testing.expect(@intFromPtr(grown) != @intFromPtr(&tiny));
    try std.testing.expectEqualStrings(
        "prefix-0123456789-0123456789-0123456789-100-200-300-400-suffix",
        std.mem.span(grown),
    );

    // tgoto swaps hpos/vpos and returns malloc-owned result.
    BC = @constCast("\x08");
    UP = @constCast("U");
    const goto_res = tgoto("\x1b[%i%d;%dH", 20, 10) orelse return error.TgotoFailed;
    defer std.c.free(goto_res);
    try std.testing.expectEqualStrings("\x1b[11;21H", std.mem.span(goto_res));

    // tputs emits text and baud-scaled delay padding characters.
    const Sink = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        fn put(c: c_int) callconv(.c) c_int {
            if (len < buf.len) {
                buf[len] = @truncate(@as(c_uint, @bitCast(c)));
                len += 1;
            }
            return c;
        }
    };
    const stubs = @import("test_stubs.zig");
    _ = stubs;
    // baud index 3 in test_stubs maps to 9600 bps -> (50 * -96 + 500) / 1000 = -4 -> 4 pad chars
    Sink.len = 0;
    PC = 0x7f;
    ospeed = 3;
    _ = tputs("5AB", 1, &Sink.put);
    try std.testing.expectEqual(@as(usize, 6), Sink.len);
    try std.testing.expectEqualStrings("AB\x7f\x7f\x7f\x7f", Sink.buf[0..Sink.len]);
}
