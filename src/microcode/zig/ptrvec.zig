// Derived from MIT/GNU Scheme C sources (`src/microcode/ptrvec.c`, `src/microcode/dstack.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

pub const PtrvecIndex = c_ulong;
pub const PtrvecLength = c_ulong;

pub const Ptrvec = extern struct {
    length: PtrvecLength,
    elements: ?[*]?*anyopaque,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Ptrvec) == 16);
        std.debug.assert(@offsetOf(Ptrvec, "length") == 0);
        std.debug.assert(@offsetOf(Ptrvec, "elements") == 8);
    }
}

extern "c" fn OS_malloc(size: usize) ?*anyopaque;
extern "c" fn OS_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn OS_free(ptr: ?*anyopaque) void;

pub export fn ptrvec_allocate(length: PtrvecLength) callconv(.c) *Ptrvec {
    const vec: *Ptrvec = @ptrCast(@alignCast(OS_malloc(@sizeOf(Ptrvec)).?));
    vec.length = length;
    vec.elements = if (length > 0)
        @ptrCast(@alignCast(OS_malloc(@as(usize, length) * @sizeOf(?*anyopaque)).?))
    else
        null;
    return vec;
}

pub export fn ptrvec_deallocate(ptrvec: *Ptrvec) callconv(.c) void {
    if (ptrvec.elements) |elems| {
        if (ptrvec.length > 0) {
            OS_free(@ptrCast(elems));
        }
    }
    OS_free(@ptrCast(ptrvec));
}

pub export fn ptrvec_set_length(ptrvec: *Ptrvec, length: PtrvecLength) callconv(.c) void {
    ptrvec.length = length;
    if (length > 0) {
        const raw = OS_realloc(
            if (ptrvec.elements) |elems| @ptrCast(elems) else null,
            @as(usize, length) * @sizeOf(?*anyopaque),
        ).?;
        ptrvec.elements = @ptrCast(@alignCast(raw));
    } else {
        if (ptrvec.elements) |elems| {
            OS_free(@ptrCast(elems));
        }
        ptrvec.elements = null;
    }
}

pub export fn ptrvec_copy(ptrvec: *Ptrvec) callconv(.c) *Ptrvec {
    const length = ptrvec.length;
    const result = ptrvec_allocate(length);
    if (length > 0) {
        const n: usize = @intCast(length);
        const src = ptrvec.elements.?;
        const dst = result.elements.?;
        @memcpy(dst[0..n], src[0..n]);
    }
    return result;
}

pub export fn ptrvec_adjoin(ptrvec: *Ptrvec, element: ?*anyopaque) callconv(.c) void {
    const length = ptrvec.length;
    ptrvec_set_length(ptrvec, length + 1);
    ptrvec.elements.?[@intCast(length)] = element;
}

pub export fn ptrvec_memq(ptrvec: *Ptrvec, element: ?*anyopaque) callconv(.c) c_int {
    const length: usize = @intCast(ptrvec.length);
    if (length == 0) return 0;
    const elems = ptrvec.elements.?;
    for (elems[0..length]) |item| {
        if (item == element) return 1;
    }
    return 0;
}

pub export fn ptrvec_move_left(
    source: *Ptrvec,
    source_start: PtrvecIndex,
    source_end: PtrvecIndex,
    target: *Ptrvec,
    target_start: PtrvecIndex,
) callconv(.c) void {
    if (source_start >= source_end) return;
    const src = source.elements.?;
    const dst = target.elements.?;
    var s: usize = @intCast(source_start);
    const e: usize = @intCast(source_end);
    var t: usize = @intCast(target_start);
    while (s < e) : ({
        s += 1;
        t += 1;
    }) {
        dst[t] = src[s];
    }
}

pub export fn ptrvec_move_right(
    source: *Ptrvec,
    source_start: PtrvecIndex,
    source_end: PtrvecIndex,
    target: *Ptrvec,
    target_start: PtrvecIndex,
) callconv(.c) void {
    if (source_start >= source_end) return;
    const src = source.elements.?;
    const dst = target.elements.?;
    const s_end: usize = @intCast(source_start);
    var s: usize = @intCast(source_end);
    var t: usize = @as(usize, @intCast(target_start)) + (s - s_end);
    while (s > s_end) {
        s -= 1;
        t -= 1;
        dst[t] = src[s];
    }
}

test "ptrvec allocate, adjoin, set_length, copy, memq, overlapping moves" {
    _ = @import("test_stubs.zig");

    const v0 = ptrvec_allocate(0);
    defer ptrvec_deallocate(v0);
    try std.testing.expectEqual(@as(PtrvecLength, 0), v0.length);
    try std.testing.expectEqual(@as(?[*]?*anyopaque, null), v0.elements);
    try std.testing.expectEqual(@as(c_int, 0), ptrvec_memq(v0, null));

    const v0_copy = ptrvec_copy(v0);
    defer ptrvec_deallocate(v0_copy);
    try std.testing.expectEqual(@as(PtrvecLength, 0), v0_copy.length);

    ptrvec_adjoin(v0, @ptrFromInt(0x10));
    ptrvec_adjoin(v0, null);
    ptrvec_adjoin(v0, @ptrFromInt(0x20));
    try std.testing.expectEqual(@as(PtrvecLength, 3), v0.length);
    try std.testing.expectEqual(@as(c_int, 1), ptrvec_memq(v0, @ptrFromInt(0x10)));
    try std.testing.expectEqual(@as(c_int, 1), ptrvec_memq(v0, null));
    try std.testing.expectEqual(@as(c_int, 0), ptrvec_memq(v0, @ptrFromInt(0x30)));

    const copy = ptrvec_copy(v0);
    defer ptrvec_deallocate(copy);
    try std.testing.expectEqual(@as(PtrvecLength, 3), copy.length);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x10)), copy.elements.?[0]);
    try std.testing.expectEqual(@as(?*anyopaque, null), copy.elements.?[1]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x20)), copy.elements.?[2]);

    // Overlapping move_right then move_left on a 5-element vector.
    const arr = ptrvec_allocate(5);
    defer ptrvec_deallocate(arr);
    for (0..5) |i| {
        arr.elements.?[i] = @ptrFromInt((i + 1) * 0x10);
    }
    ptrvec_move_right(arr, 0, 3, arr, 2); // [10, 20, 10, 20, 30]
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x10)), arr.elements.?[2]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x20)), arr.elements.?[3]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x30)), arr.elements.?[4]);

    ptrvec_move_left(arr, 2, 5, arr, 0); // [10, 20, 30, 20, 30]
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x10)), arr.elements.?[0]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x20)), arr.elements.?[1]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x30)), arr.elements.?[2]);

    // Grow then shrink to 0 without leak.
    ptrvec_set_length(arr, 8);
    try std.testing.expectEqual(@as(PtrvecLength, 8), arr.length);
    ptrvec_set_length(arr, 0);
    try std.testing.expectEqual(@as(PtrvecLength, 0), arr.length);
    try std.testing.expectEqual(@as(?[*]?*anyopaque, null), arr.elements);
}
