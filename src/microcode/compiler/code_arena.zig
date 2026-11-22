// Derived from MIT/GNU Scheme C sources (`src/microcode/code_arena.h`, `src/microcode/code_arena.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const scheme_obj = @import("../core/scheme_obj.zig");
pub const jit = @import("jit.zig");
const outf = @import("../support/outf.zig");

// Ensure jit (+ wind + obstack) exports are emitted when code_arena.zig is built via smoke_runtime.
comptime {
    _ = jit;
}

pub const SchemeObject = scheme_obj.SchemeObject;

const code_arena_min_overflow_words: usize = 262144;
const code_mark_stack_initial_cap: usize = 4096;

const CodeArenaChunk = struct {
    start: ?[*]SchemeObject = null,
    alloc_next: ?[*]SchemeObject = null,
    end: ?[*]SchemeObject = null,
    byte_size: usize = 0,
    total_words: usize = 0,
    mark_bits: ?[*]u64 = null,
    next: ?*CodeArenaChunk = null,
};

pub export var code_start: ?[*]SchemeObject = null;
pub export var code_alloc_next: ?[*]SchemeObject = null;
pub export var code_end: ?[*]SchemeObject = null;

var primary_chunk: CodeArenaChunk = .{};
var primary_initialized_p: bool = false;
var code_overflow_chunks: ?*CodeArenaChunk = null;
var code_free_list: ?[*]SchemeObject = null;

var mark_stack: ?[*]?[*]SchemeObject = null;
var mark_stack_top: usize = 0;
var mark_stack_capacity: usize = 0;

inline fn wordDiff(hi: [*]const SchemeObject, lo: [*]const SchemeObject) usize {
    return (@intFromPtr(hi) - @intFromPtr(lo)) / @sizeOf(SchemeObject);
}

inline fn firstChunk() ?*CodeArenaChunk {
    return if (primary_initialized_p) &primary_chunk else null;
}

inline fn nextChunk(c: *CodeArenaChunk) ?*CodeArenaChunk {
    return if (c == &primary_chunk) code_overflow_chunks else c.next;
}

inline fn syncPrimaryAllocNext(c: *CodeArenaChunk) void {
    if (c == &primary_chunk) {
        code_alloc_next = c.alloc_next;
    }
}

fn findChunkForAddr(addr: ?*const anyopaque) ?*CodeArenaChunk {
    const p = addr orelse return null;
    const target = @intFromPtr(p);
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        const lo = @intFromPtr(c.start);
        const hi = @intFromPtr(c.alloc_next);
        if (target >= lo and target < hi) {
            return c;
        }
    }
    return null;
}

fn initChunk(c: *CodeArenaChunk, requested_words: usize) void {
    const page_size = jit.jit_page_size();
    const words: usize = if (requested_words == 0) 2048 else @intCast(requested_words);

    if (words > (std.math.maxInt(usize) - page_size) / @sizeOf(SchemeObject)) {
        outf.fatal("Requested code arena size overflows address space.\n", .{});
        outf.flushFatal();
        std.c.exit(1);
    }

    const raw_bytes = words * @sizeOf(SchemeObject);
    const byte_size = ((raw_bytes + (page_size - 1)) / page_size) * page_size;
    const mapped = jit.jit_map_code_space(byte_size) orelse {
        outf.fatal("Unable to allocate {d}-byte JIT code arena.\n", .{byte_size});
        outf.flushFatal();
        std.c.exit(1);
    };

    const start_ptr: [*]SchemeObject = @ptrCast(@alignCast(mapped));
    const total_words: usize = byte_size / @sizeOf(SchemeObject);
    c.start = start_ptr;
    c.alloc_next = start_ptr;
    c.byte_size = byte_size;
    c.total_words = @intCast(total_words);
    c.end = start_ptr + total_words;
    c.next = null;

    if (scheme_obj.addressToDatum(@ptrCast(c.end)) > scheme_obj.datum_mask) {
        jit.jit_unmap_code_space(mapped, byte_size);
        c.start = null;
        c.alloc_next = null;
        c.end = null;
        outf.fatal("Code arena exceeds tagged datum range.\n", .{});
        outf.flushFatal();
        std.c.exit(1);
    }

    const n_bit_words = (total_words + 63) / 64;
    const bits = std.c.calloc(n_bit_words, @sizeOf(u64)) orelse {
        jit.jit_unmap_code_space(mapped, byte_size);
        c.start = null;
        c.alloc_next = null;
        c.end = null;
        outf.fatal("Unable to allocate code arena mark bitmap.\n", .{});
        outf.flushFatal();
        std.c.exit(1);
    };
    c.mark_bits = @ptrCast(@alignCast(bits));
}

fn freeOverflowChunks() void {
    var c = code_overflow_chunks;
    while (c) |chunk| {
        const following = chunk.next;
        jit.jit_unmap_code_space(@ptrCast(chunk.start), chunk.byte_size);
        if (chunk.mark_bits) |mb| std.c.free(@ptrCast(mb));
        std.c.free(@ptrCast(chunk));
        c = following;
    }
    code_overflow_chunks = null;
}

pub export fn code_arena_setup(initial_words: usize) callconv(.c) void {
    if (primary_initialized_p) {
        code_arena_teardown();
    }

    initChunk(&primary_chunk, initial_words);

    const ms_raw = std.c.malloc(code_mark_stack_initial_cap * @sizeOf(?[*]SchemeObject)) orelse {
        jit.jit_unmap_code_space(@ptrCast(primary_chunk.start), primary_chunk.byte_size);
        if (primary_chunk.mark_bits) |mb| std.c.free(@ptrCast(mb));
        primary_chunk = .{};
        outf.fatal("Unable to allocate code arena mark stack.\n", .{});
        outf.flushFatal();
        std.c.exit(1);
    };
    mark_stack = @ptrCast(@alignCast(ms_raw));
    mark_stack_capacity = code_mark_stack_initial_cap;
    mark_stack_top = 0;

    code_start = primary_chunk.start;
    code_alloc_next = primary_chunk.alloc_next;
    code_end = primary_chunk.end;
    code_overflow_chunks = null;
    code_free_list = null;
    primary_initialized_p = true;
}

pub export fn code_arena_reset(required_words: usize) callconv(.c) void {
    freeOverflowChunks();
    code_free_list = null;
    mark_stack_top = 0;

    if (!primary_initialized_p) {
        code_arena_setup(required_words);
        return;
    }

    if (primary_chunk.total_words < required_words) {
        jit.jit_unmap_code_space(@ptrCast(primary_chunk.start), primary_chunk.byte_size);
        if (primary_chunk.mark_bits) |mb| std.c.free(@ptrCast(mb));
        primary_chunk = .{};
        initChunk(&primary_chunk, required_words + code_arena_min_overflow_words);
        code_start = primary_chunk.start;
        code_alloc_next = primary_chunk.alloc_next;
        code_end = primary_chunk.end;
    } else {
        const n_bit_words = (@as(usize, @intCast(primary_chunk.total_words)) + 63) / 64;
        primary_chunk.alloc_next = primary_chunk.start;
        code_alloc_next = code_start;
        @memset(primary_chunk.mark_bits.?[0..n_bit_words], 0);
    }
}

pub export fn code_arena_teardown() callconv(.c) void {
    freeOverflowChunks();

    if (primary_initialized_p) {
        jit.jit_unmap_code_space(@ptrCast(primary_chunk.start), primary_chunk.byte_size);
        if (primary_chunk.mark_bits) |mb| std.c.free(@ptrCast(mb));
        primary_chunk = .{};
        primary_initialized_p = false;
    }

    if (mark_stack) |ms| std.c.free(@ptrCast(ms));
    mark_stack = null;
    mark_stack_top = 0;
    mark_stack_capacity = 0;

    code_start = null;
    code_alloc_next = null;
    code_end = null;
    code_free_list = null;
}

pub export fn code_address_p(addr: ?*const anyopaque) callconv(.c) bool {
    return findChunkForAddr(addr) != null;
}

pub export fn code_range_valid_p(
    start: ?[*]const SchemeObject,
    end: ?[*]const SchemeObject,
) callconv(.c) bool {
    const sp = start orelse return false;
    const ep = end orelse return false;
    const s = @intFromPtr(sp);
    const e = @intFromPtr(ep);
    if (s > e) return false;

    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        const lo = @intFromPtr(c.start);
        const hi = @intFromPtr(c.alloc_next);
        if (s >= lo and e <= hi) return true;
    }
    return false;
}

pub export fn code_arena_find_block(addr: ?*const anyopaque) callconv(.c) ?[*]SchemeObject {
    const c = findChunkForAddr(addr) orelse return null;
    const target = @intFromPtr(addr.?);
    var scan = c.start.?;
    const end = c.alloc_next.?;

    while (@intFromPtr(scan) < @intFromPtr(end)) {
        const hdr = scan[0];
        const hdr_type = scheme_obj.objectType(hdr);
        const words: usize = @intCast(1 + scheme_obj.objectDatum(hdr));

        if ((hdr_type != scheme_obj.tc_manifest_vector and hdr_type != scheme_obj.tc_manifest_nm_vector) or
            words == 0 or
            words > wordDiff(end, scan))
        {
            return null;
        }

        const block_end = scan + words;
        if (target < @intFromPtr(block_end)) {
            if (hdr_type == scheme_obj.tc_manifest_vector and target >= @intFromPtr(scan + 2)) {
                return scan;
            }
            return null;
        }
        scan = block_end;
    }
    return null;
}

pub export fn code_arena_chunk_count() callconv(.c) usize {
    var count: usize = 0;
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        count += 1;
    }
    return count;
}

pub export fn code_arena_nonempty_chunk_count() callconv(.c) usize {
    var count: usize = 0;
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        if (@intFromPtr(c.alloc_next) > @intFromPtr(c.start)) {
            count += 1;
        }
    }
    return count;
}

pub export fn code_arena_max_end() callconv(.c) ?[*]SchemeObject {
    var best: ?[*]SchemeObject = null;
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        if (@intFromPtr(c.end) > @intFromPtr(best)) {
            best = c.end;
        }
    }
    return best;
}

pub export fn code_arena_mark_hole(start: ?[*]SchemeObject, n_words: usize) callconv(.c) void {
    const s = start orelse return;
    if (n_words == 0) return;
    jit.jit_write_begin();
    s[0] = scheme_obj.makeNmvHeader(n_words - 1);
    if (n_words >= 2) {
        s[1] = 0;
    }
    jit.jit_write_end();
}

pub export fn code_arena_live_words() callconv(.c) usize {
    var live: usize = 0;
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        var scan = c.start.?;
        const end = c.alloc_next.?;
        while (@intFromPtr(scan) < @intFromPtr(end)) {
            const hdr = scan[0];
            const len = 1 + scheme_obj.objectDatum(hdr);
            if (scheme_obj.objectType(hdr) == scheme_obj.tc_manifest_vector) {
                live += len;
            }
            scan += @as(usize, @intCast(len));
        }
    }
    return live;
}

pub const LiveBlockCallback = *const fn ([*]SchemeObject, usize, ?*anyopaque) callconv(.c) void;

pub export fn code_arena_for_each_live_block(
    callback: LiveBlockCallback,
    ctx: ?*anyopaque,
) callconv(.c) void {
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        var scan = c.start.?;
        const end = c.alloc_next.?;
        while (@intFromPtr(scan) < @intFromPtr(end)) {
            const hdr = scan[0];
            const hdr_type = scheme_obj.objectType(hdr);
            const len = 1 + scheme_obj.objectDatum(hdr);
            const len_usize: usize = @intCast(len);
            const block = scan;

            if ((hdr_type != scheme_obj.tc_manifest_vector and hdr_type != scheme_obj.tc_manifest_nm_vector) or
                len_usize == 0 or
                len_usize > wordDiff(end, scan))
            {
                outf.fatal("code_arena_for_each_live_block: corrupt header 0x{x} at 0x{x}\n", .{ hdr, @intFromPtr(scan) });
                outf.flushFatal();
                std.c.abort();
            }

            // Advance before invoking callback in case callback overwrites hdr.
            scan += len_usize;
            if (hdr_type == scheme_obj.tc_manifest_vector) {
                callback(block, len, ctx);
            }
        }
    }
}

fn bumpAllocInChunk(c: *CodeArenaChunk, alloc_words: usize) ?[*]SchemeObject {
    const next_ptr = c.alloc_next.?;
    const end_ptr = c.end.?;
    const pad: usize = if (!scheme_obj.floatingAlignedP(next_ptr) and @intFromPtr(next_ptr) < @intFromPtr(end_ptr))
        1
    else
        0;
    const avail = wordDiff(end_ptr, next_ptr);
    const need: usize = @intCast(alloc_words);
    if (avail < need + pad) return null;

    jit.jit_write_begin();
    var cursor = next_ptr;
    if (pad != 0) {
        cursor[0] = scheme_obj.makeNmvHeader(0);
        cursor += 1;
    }
    const result = cursor;
    result[0] = scheme_obj.makeNmvHeader(alloc_words - 1);
    result[1] = 0;
    c.alloc_next = result + need;
    syncPrimaryAllocNext(c);
    jit.jit_write_end();
    return result;
}

pub export fn code_arena_alloc(n_words: usize) callconv(.c) ?[*]SchemeObject {
    if (n_words == 0) return null;
    if (!primary_initialized_p) {
        outf.fatal("code_arena_alloc: code arena not initialized.\n", .{});
        outf.flushFatal();
        std.c.abort();
    }

    const alloc_words: usize = if (n_words < 2) 2 else n_words;
    var prev_hole: ?[*]SchemeObject = null;
    var curr = code_free_list;
    while (curr) |hole| {
        const hole_words = 1 + scheme_obj.objectDatum(hole[0]);
        const next_free: ?[*]SchemeObject = if (hole[1] == 0) null else @ptrFromInt(@as(usize, @intCast(hole[1])));
        if (scheme_obj.floatingAlignedP(hole) and hole_words >= alloc_words) {
            const rem = hole_words - alloc_words;
            var replacement = next_free;

            jit.jit_write_begin();
            hole[0] = scheme_obj.makeNmvHeader(alloc_words - 1);
            hole[1] = 0;
            if (rem >= 2) {
                const tail = hole + @as(usize, @intCast(alloc_words));
                tail[0] = scheme_obj.makeNmvHeader(rem - 1);
                tail[1] = if (next_free) |nf| @intCast(@intFromPtr(nf)) else 0;
                replacement = tail;
            } else if (rem == 1) {
                hole[@as(usize, @intCast(alloc_words))] = scheme_obj.makeNmvHeader(0);
            }

            if (prev_hole) |ph| {
                ph[1] = if (replacement) |rep| @intCast(@intFromPtr(rep)) else 0;
            } else {
                code_free_list = replacement;
            }
            jit.jit_write_end();
            return hole;
        }
        prev_hole = hole;
        curr = next_free;
    }

    var tail_chunk: ?*CodeArenaChunk = null;
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        if (bumpAllocInChunk(c, alloc_words)) |block| {
            return block;
        }
        tail_chunk = c;
    }

    const half_primary = primary_chunk.total_words / 2;
    const min_words = @max(half_primary, code_arena_min_overflow_words);
    const overflow_words = @max(alloc_words + 1, min_words);
    const extra_raw = std.c.malloc(@sizeOf(CodeArenaChunk)) orelse {
        outf.fatal("Unable to allocate overflow code arena chunk header.\n", .{});
        outf.flushFatal();
        std.c.exit(1);
    };
    const extra: *CodeArenaChunk = @ptrCast(@alignCast(extra_raw));
    extra.* = .{};
    initChunk(extra, overflow_words);
    if (tail_chunk.? == &primary_chunk) {
        code_overflow_chunks = extra;
    } else {
        tail_chunk.?.next = extra;
    }
    return bumpAllocInChunk(extra, alloc_words);
}

pub export fn code_arena_mark_begin() callconv(.c) void {
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        const n_bit_words = (@as(usize, @intCast(c.total_words)) + 63) / 64;
        @memset(c.mark_bits.?[0..n_bit_words], 0);
    }
    mark_stack_top = 0;
}

pub export fn code_arena_mark_block(block: ?[*]SchemeObject) callconv(.c) bool {
    const blk = block orelse {
        outf.fatal("code_arena_mark_block: invalid block 0x0\n", .{});
        outf.flushFatal();
        std.c.abort();
    };
    const chunk = findChunkForAddr(@ptrCast(blk)) orelse {
        outf.fatal("code_arena_mark_block: invalid block 0x{x}\n", .{@intFromPtr(blk)});
        outf.flushFatal();
        std.c.abort();
    };
    if ((@intFromPtr(blk) % @sizeOf(SchemeObject)) != 0 or
        scheme_obj.objectType(blk[0]) != scheme_obj.tc_manifest_vector)
    {
        outf.fatal("code_arena_mark_block: invalid block 0x{x}\n", .{@intFromPtr(blk)});
        outf.flushFatal();
        std.c.abort();
    }
    const len: usize = @intCast(1 + scheme_obj.objectDatum(blk[0]));
    if (len > wordDiff(chunk.alloc_next.?, blk)) {
        outf.fatal("code_arena_mark_block: block 0x{x} exceeds chunk bounds\n", .{@intFromPtr(blk)});
        outf.flushFatal();
        std.c.abort();
    }

    const idx = wordDiff(blk, chunk.start.?);
    const word_idx = idx >> 6;
    const mask = @as(u64, 1) << @as(u6, @intCast(idx & 63));
    const bits = chunk.mark_bits.?;
    if ((bits[word_idx] & mask) != 0) return false;

    bits[word_idx] |= mask;
    if (mark_stack_top == mark_stack_capacity) {
        const new_cap = mark_stack_capacity * 2;
        const grown = std.c.realloc(@ptrCast(mark_stack), new_cap * @sizeOf(?[*]SchemeObject)) orelse {
            outf.fatal("code_arena_mark_block: mark stack overflow\n", .{});
            outf.flushFatal();
            std.c.exit(1);
        };
        mark_stack = @ptrCast(@alignCast(grown));
        mark_stack_capacity = new_cap;
    }
    mark_stack.?[mark_stack_top] = blk;
    mark_stack_top += 1;
    return true;
}

pub export fn code_arena_marked_p(block: ?[*]const SchemeObject) callconv(.c) bool {
    const blk = block orelse return false;
    const chunk = findChunkForAddr(@ptrCast(blk)) orelse return false;
    if ((@intFromPtr(blk) % @sizeOf(SchemeObject)) != 0) return false;
    const idx = wordDiff(blk, chunk.start.?);
    const word_idx = idx >> 6;
    const mask = @as(u64, 1) << @as(u6, @intCast(idx & 63));
    return (chunk.mark_bits.?[word_idx] & mask) != 0;
}

pub export fn code_arena_mark_stack_empty_p() callconv(.c) bool {
    return mark_stack_top == 0;
}

pub export fn code_arena_pop_mark_stack() callconv(.c) ?[*]SchemeObject {
    if (mark_stack_top == 0) {
        outf.fatal("code_arena_pop_mark_stack: stack underflow\n", .{});
        outf.flushFatal();
        std.c.abort();
    }
    mark_stack_top -= 1;
    return mark_stack.?[mark_stack_top];
}

fn codeArenaCoalescePass(check_marks_p: bool) void {
    var free_tail: ?[*]SchemeObject = null;
    code_free_list = null;

    jit.jit_write_begin();
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        var scan = c.start.?;
        const end = c.alloc_next.?;
        var hole_start: ?[*]SchemeObject = null;

        while (@intFromPtr(scan) < @intFromPtr(end)) {
            const hdr = scan[0];
            const hdr_type = scheme_obj.objectType(hdr);
            const words: usize = @intCast(1 + scheme_obj.objectDatum(hdr));
            const idx = wordDiff(scan, c.start.?);

            if ((hdr_type != scheme_obj.tc_manifest_vector and hdr_type != scheme_obj.tc_manifest_nm_vector) or
                words == 0 or
                words > wordDiff(end, scan))
            {
                jit.jit_write_end();
                outf.fatal("code_arena sweep: corrupt header 0x{x} at 0x{x}\n", .{ hdr, @intFromPtr(scan) });
                outf.flushFatal();
                std.c.abort();
            }

            const bit_set = (c.mark_bits.?[idx >> 6] & (@as(u64, 1) << @as(u6, @intCast(idx & 63)))) != 0;
            const live_p = (hdr_type == scheme_obj.tc_manifest_vector) and (!check_marks_p or bit_set);

            if (live_p) {
                if (hole_start) |hs| {
                    const hole_words: usize = @intCast(wordDiff(scan, hs));
                    hs[0] = scheme_obj.makeNmvHeader(hole_words - 1);
                    if (hole_words >= 2) {
                        hs[1] = 0;
                        if (free_tail) |ft| {
                            ft[1] = @intCast(@intFromPtr(hs));
                        } else {
                            code_free_list = hs;
                        }
                        free_tail = hs;
                    }
                    hole_start = null;
                }
                scan += words;
            } else {
                if (hole_start == null) {
                    hole_start = scan;
                }
                scan += words;
            }
        }

        if (hole_start) |hs| {
            c.alloc_next = hs;
            syncPrimaryAllocNext(c);
        }

        if (check_marks_p) {
            const n_bit_words = (@as(usize, @intCast(c.total_words)) + 63) / 64;
            @memset(c.mark_bits.?[0..n_bit_words], 0);
        }
    }
    jit.jit_write_end();
    mark_stack_top = 0;
}

pub export fn code_arena_sweep() callconv(.c) void {
    codeArenaCoalescePass(true);
}

pub export fn code_arena_rebuild_free_list() callconv(.c) void {
    codeArenaCoalescePass(false);
}

pub export fn code_arena_write_begin() callconv(.c) void {
    jit.jit_write_begin();
}

pub export fn code_arena_write_end() callconv(.c) void {
    jit.jit_write_end();
}

pub export fn code_arena_write_scope_begin() callconv(.c) ?*anyopaque {
    return jit.jit_write_scope_begin();
}

pub export fn code_arena_write_scope_end(saved_dstack_pos: ?*anyopaque) callconv(.c) void {
    jit.jit_write_scope_end(saved_dstack_pos);
}

pub export fn code_arena_flush_icache() callconv(.c) void {
    var cur = firstChunk();
    while (cur) |c| : (cur = nextChunk(c)) {
        if (@intFromPtr(c.alloc_next) > @intFromPtr(c.start)) {
            jit.jit_flush_icache(
                @ptrCast(c.start),
                wordDiff(c.alloc_next.?, c.start.?) * @sizeOf(SchemeObject),
            );
        }
    }
}

test "code_arena alloc, mark/sweep, coalescing, 1-word remainder split, and reset" {
    _ = @import("../core/test_stubs.zig");

    code_arena_setup(256);
    defer code_arena_teardown();

    try std.testing.expectEqual(@as(usize, 1), code_arena_chunk_count());
    try std.testing.expectEqual(@as(usize, 0), code_arena_nonempty_chunk_count());
    try std.testing.expect(code_start != null);
    try std.testing.expectEqual(code_start, code_alloc_next);

    const a = code_arena_alloc(4).?;
    const b = code_arena_alloc(4).?;
    const c = code_arena_alloc(5).?;
    const d = code_arena_alloc(6).?;

    code_arena_write_begin();
    a[0] = scheme_obj.makeVectorHeader(3);
    b[0] = scheme_obj.makeVectorHeader(3);
    c[0] = scheme_obj.makeVectorHeader(4);
    d[0] = scheme_obj.makeVectorHeader(5);
    code_arena_write_end();

    try std.testing.expectEqual(@as(usize, 1), code_arena_nonempty_chunk_count());
    try std.testing.expectEqual(@as(usize, 19), code_arena_live_words());
    try std.testing.expect(code_address_p(@ptrCast(b + 2)));
    try std.testing.expect(code_range_valid_p(a, d + 6));
    try std.testing.expectEqual(@as(?[*]SchemeObject, b), code_arena_find_block(@ptrCast(b + 2)));
    try std.testing.expectEqual(@as(?[*]SchemeObject, null), code_arena_find_block(@ptrCast(b + 1)));

    const Ctx = struct { count: usize = 0 };
    var ctx = Ctx{};
    const cb = struct {
        fn visit(_: [*]SchemeObject, _: usize, raw: ?*anyopaque) callconv(.c) void {
            const p: *Ctx = @ptrCast(@alignCast(raw.?));
            p.count += 1;
        }
    }.visit;
    code_arena_for_each_live_block(&cb, &ctx);
    try std.testing.expectEqual(@as(usize, 4), ctx.count);

    // Mark A and C; sweep retracts tail D and leaves 4-word free hole at B.
    code_arena_mark_begin();
    try std.testing.expect(code_arena_mark_stack_empty_p());
    try std.testing.expect(code_arena_mark_block(a));
    try std.testing.expect(!code_arena_mark_block(a));
    try std.testing.expect(code_arena_mark_block(c));
    try std.testing.expect(code_arena_marked_p(a));
    try std.testing.expect(!code_arena_marked_p(b));
    try std.testing.expect(!code_arena_mark_stack_empty_p());
    _ = code_arena_pop_mark_stack();
    _ = code_arena_pop_mark_stack();
    try std.testing.expect(code_arena_mark_stack_empty_p());

    code_arena_sweep();
    try std.testing.expectEqual(@as(usize, 9), code_arena_live_words());
    try std.testing.expectEqual(@as(?[*]SchemeObject, d), code_alloc_next);

    // 3-word alloc from 4-word hole leaves a 1-word NMV pad at b[3].
    const reused = code_arena_alloc(3).?;
    try std.testing.expectEqual(b, reused);
    try std.testing.expectEqual(scheme_obj.makeNmvHeader(0), b[3]);

    // Convert reused and c to live vectors, then verify reset clears arena.
    code_arena_reset(256);
    try std.testing.expectEqual(code_start, code_alloc_next);
    try std.testing.expectEqual(@as(usize, 0), code_arena_nonempty_chunk_count());
}
