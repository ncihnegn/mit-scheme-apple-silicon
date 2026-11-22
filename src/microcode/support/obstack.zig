// Derived from MIT/GNU Scheme C sources (`src/microcode/obstack.h`, `src/microcode/obstack.c`):
// Copyright (C) 1988 Free Software Foundation, Inc.
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

pub const ObstackChunk = extern struct {
    limit: [*]u8,
    prev: ?*ObstackChunk,
    contents: [4]u8,
};

pub const ChunkAllocFn = *const fn (usize) callconv(.c) ?*anyopaque;
pub const ChunkAllocStoredFn = *const fn (isize) callconv(.c) ?*ObstackChunk;
pub const ChunkFreeFn = *const fn (?*anyopaque) callconv(.c) void;

pub const Obstack = extern struct {
    chunk_size: isize,
    chunk: ?*ObstackChunk,
    object_base: ?[*]u8,
    next_free: ?[*]u8,
    chunk_limit: ?[*]u8,
    temp: isize,
    alignment_mask: isize,
    chunkfun: ChunkAllocStoredFn,
    freefun: ChunkFreeFn,

    pub fn init(self: *Obstack, chunkfun: ChunkAllocFn, freefun: ChunkFreeFn) void {
        _obstack_begin(self, 0, 0, chunkfun, freefun);
    }

    pub fn initSized(self: *Obstack, size: c_int, chunkfun: ChunkAllocFn, freefun: ChunkFreeFn) void {
        _obstack_begin(self, size, 0, chunkfun, freefun);
    }

    pub fn objectSize(self: *const Obstack) usize {
        return @intFromPtr(self.next_free.?) - @intFromPtr(self.object_base.?);
    }

    pub fn grow(self: *Obstack, data: []const u8) void {
        const room = @intFromPtr(self.chunk_limit.?) - @intFromPtr(self.next_free.?);
        if (room < data.len) {
            _obstack_newchunk(self, @intCast(data.len));
        }
        @memcpy(self.next_free.?[0..data.len], data);
        self.next_free = self.next_free.? + data.len;
    }

    pub fn growByte(self: *Obstack, byte: u8) void {
        if (@intFromPtr(self.next_free.?) >= @intFromPtr(self.chunk_limit.?)) {
            _obstack_newchunk(self, 1);
        }
        self.next_free.?[0] = byte;
        self.next_free = self.next_free.? + 1;
    }

    pub fn growPtr(self: *Obstack, ptr: ?*const anyopaque) void {
        const p_bytes: *const [@sizeOf(?*const anyopaque)]u8 = @ptrCast(&ptr);
        self.grow(p_bytes);
    }

    pub fn finish(self: *Obstack) [*]u8 {
        const value = self.object_base.?;
        const align_mask: usize = @intCast(self.alignment_mask);
        var aligned = (@intFromPtr(self.next_free.?) +% align_mask) & ~align_mask;
        const limit_addr = @intFromPtr(self.chunk_limit.?);
        if (aligned > limit_addr) {
            aligned = limit_addr;
        }
        self.next_free = @ptrFromInt(aligned);
        self.object_base = self.next_free;
        return value;
    }

    pub fn alloc(self: *Obstack, len: usize) [*]u8 {
        const room = @intFromPtr(self.chunk_limit.?) - @intFromPtr(self.next_free.?);
        if (room < len) {
            _obstack_newchunk(self, @intCast(len));
        }
        self.next_free = self.next_free.? + len;
        return self.finish();
    }

    pub fn freeObj(self: *Obstack, obj: ?*anyopaque) void {
        if (obj) |ptr| {
            const addr = @intFromPtr(ptr);
            const chunk_addr = @intFromPtr(self.chunk);
            const limit_addr = @intFromPtr(self.chunk_limit);
            if (addr > chunk_addr and addr < limit_addr) {
                const byte_ptr: [*]u8 = @ptrCast(ptr);
                self.next_free = byte_ptr;
                self.object_base = byte_ptr;
                return;
            }
        }
        obstack_free(self, obj);
    }
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@offsetOf(ObstackChunk, "limit") == 0);
        std.debug.assert(@offsetOf(ObstackChunk, "prev") == 8);
        std.debug.assert(@offsetOf(ObstackChunk, "contents") == 16);

        std.debug.assert(@sizeOf(Obstack) == 72);
        std.debug.assert(@offsetOf(Obstack, "chunk_size") == 0);
        std.debug.assert(@offsetOf(Obstack, "chunk") == 8);
        std.debug.assert(@offsetOf(Obstack, "object_base") == 16);
        std.debug.assert(@offsetOf(Obstack, "next_free") == 24);
        std.debug.assert(@offsetOf(Obstack, "chunk_limit") == 32);
        std.debug.assert(@offsetOf(Obstack, "temp") == 40);
        std.debug.assert(@offsetOf(Obstack, "alignment_mask") == 48);
        std.debug.assert(@offsetOf(Obstack, "chunkfun") == 56);
        std.debug.assert(@offsetOf(Obstack, "freefun") == 64);
    }
}

const FooAlign = extern struct {
    x: u8,
    d: f64,
};
const default_alignment: isize = @intCast(@offsetOf(FooAlign, "d"));

const FooRound = extern union {
    x: isize,
    d: f64,
};
const default_rounding: usize = @sizeOf(FooRound);

// The non-GNU-C macros copy the obstack into this global variable to avoid multiple evaluation.
pub export var _obstack: ?*Obstack = null;

pub export fn _obstack_begin(
    h: *Obstack,
    size_arg: c_int,
    alignment_arg: isize,
    chunkfun: ChunkAllocFn,
    freefun: ChunkFreeFn,
) callconv(.c) void {
    const alignment: isize = if (alignment_arg == 0) default_alignment else alignment_arg;
    const size: isize = if (size_arg == 0) blk: {
        const extra = ((((12 + default_rounding - 1) & ~(default_rounding - 1)) +
            4 + default_rounding - 1) & ~(default_rounding - 1));
        break :blk @intCast(4096 - extra);
    } else @intCast(size_arg);

    h.chunkfun = @ptrCast(chunkfun);
    h.freefun = freefun;
    h.chunk_size = size;
    h.alignment_mask = alignment - 1;

    const chunk = h.chunkfun(h.chunk_size).?;
    const contents_ptr: [*]u8 = @ptrCast(&chunk.contents);
    const chunk_bytes: [*]u8 = @ptrCast(chunk);
    const limit = chunk_bytes + @as(usize, @intCast(h.chunk_size));

    h.chunk = chunk;
    h.object_base = contents_ptr;
    h.next_free = contents_ptr;
    chunk.limit = limit;
    h.chunk_limit = limit;
    chunk.prev = null;
}

pub export fn _obstack_newchunk(h: *Obstack, length: c_int) callconv(.c) void {
    const old_chunk = h.chunk.?;
    const obj_size = @intFromPtr(h.next_free.?) - @intFromPtr(h.object_base.?);

    const obj_signed: isize = @intCast(obj_size);
    const len_signed: isize = @intCast(length);
    var new_size_signed: isize = (obj_signed + len_signed) + (obj_signed >> 3) + 100;
    const min_size_signed: isize = @intCast(h.chunk_size);
    if (new_size_signed < min_size_signed) {
        new_size_signed = min_size_signed;
    }
    const new_size: usize = @intCast(new_size_signed);

    const new_chunk = h.chunkfun(@intCast(new_size)).?;
    const new_chunk_bytes: [*]u8 = @ptrCast(new_chunk);
    const new_limit = new_chunk_bytes + new_size;
    const new_contents: [*]u8 = @ptrCast(&new_chunk.contents);

    h.chunk = new_chunk;
    new_chunk.prev = old_chunk;
    new_chunk.limit = new_limit;
    h.chunk_limit = new_limit;

    if (obj_size > 0) {
        @memcpy(new_contents[0..obj_size], h.object_base.?[0..obj_size]);
    }

    // If the object just copied was the only data in old_chunk,
    // free that chunk and remove it from the chain.
    if (@intFromPtr(h.object_base.?) == @intFromPtr(&old_chunk.contents)) {
        new_chunk.prev = old_chunk.prev;
        h.freefun(old_chunk);
    }

    h.object_base = new_contents;
    h.next_free = new_contents + obj_size;
}

pub export fn _obstack_allocated_p(h: *Obstack, obj: ?*anyopaque) callconv(.c) c_int {
    const obj_addr = @intFromPtr(obj);
    var lp = h.chunk;
    while (lp) |chunk| {
        if (@intFromPtr(chunk) <= obj_addr and obj_addr <= @intFromPtr(chunk.limit)) {
            return 1;
        }
        lp = chunk.prev;
    }
    return 0;
}

pub export fn obstack_free(h: *Obstack, obj: ?*anyopaque) callconv(.c) void {
    const obj_addr: usize = if (obj) |p| @intFromPtr(p) else 0;
    var lp = h.chunk;
    while (lp) |chunk| {
        if (@intFromPtr(chunk) < obj_addr and obj_addr <= @intFromPtr(chunk.limit)) {
            break;
        }
        const plp = chunk.prev;
        h.freefun(chunk);
        lp = plp;
    }

    if (lp) |chunk| {
        const byte_ptr: [*]u8 = @ptrCast(obj);
        h.object_base = byte_ptr;
        h.next_free = byte_ptr;
        h.chunk_limit = chunk.limit;
        h.chunk = chunk;
    } else if (obj != null) {
        // obj is not in any of the chunks!
        std.c.abort();
    } else {
        h.chunk = null;
        h.object_base = null;
        h.next_free = null;
        h.chunk_limit = null;
    }
}

pub export fn _obstack_free(h: *Obstack, obj: ?*anyopaque) callconv(.c) void {
    obstack_free(h, obj);
}

test "obstack init, alloc, chunk growth, partial copy, and LIFO free" {
    var obs: Obstack = undefined;
    obs.initSized(64, &std.c.malloc, &std.c.free);
    defer obs.freeObj(null);

    try std.testing.expectEqual(@as(c_int, 1), _obstack_allocated_p(&obs, obs.object_base));

    // Allocate multiple objects forcing chunk growth.
    const a = obs.alloc(16);
    @memset(a[0..16], 0xaa);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(a) & @as(usize, @intCast(obs.alignment_mask)));
    try std.testing.expectEqual(@as(c_int, 1), _obstack_allocated_p(&obs, a));

    const b = obs.alloc(32);
    @memset(b[0..32], 0xbb);
    try std.testing.expectEqual(@as(c_int, 1), _obstack_allocated_p(&obs, b));

    // Grow a partial object across chunk boundary using _obstack_newchunk directly.
    const partial_src = "hello, obstack partial!";
    if (@intFromPtr(obs.chunk_limit.?) - @intFromPtr(obs.next_free.?) < partial_src.len) {
        _obstack_newchunk(&obs, partial_src.len);
    }
    @memcpy(obs.next_free.?[0..partial_src.len], partial_src);
    obs.next_free = obs.next_free.? + partial_src.len;
    // Trigger another chunk expansion while object_base != old_chunk.contents (or after)
    _obstack_newchunk(&obs, 200);
    const finished = obs.alloc(1);
    try std.testing.expectEqualStrings(partial_src, finished[0..partial_src.len]);

    // LIFO free back across chunk boundary.
    obs.freeObj(b);
    try std.testing.expectEqual(@as(c_int, 1), _obstack_allocated_p(&obs, a));
    try std.testing.expectEqual(@intFromPtr(b), @intFromPtr(obs.object_base));

    var unrelated: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), _obstack_allocated_p(&obs, &unrelated));
}
