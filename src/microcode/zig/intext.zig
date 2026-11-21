// Derived from MIT/GNU Scheme C sources (`src/microcode/intext.c`, `src/microcode/intext.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

pub export var current_interruptable_extent: ?*anyopaque = null;

pub export fn initialize_interruptable_extent() callconv(.c) void {
    current_interruptable_extent = null;
}

pub export fn reset_interruptable_extent() callconv(.c) void {
    current_interruptable_extent = null;
}

pub export fn enter_interruption_extent() callconv(.c) c_int {
    return 0;
}

pub export fn exit_interruption_extent() callconv(.c) void {
    unreachable;
}

test "intext default state" {
    var dummy: u8 = 0;
    current_interruptable_extent = &dummy;
    initialize_interruptable_extent();
    try std.testing.expectEqual(@as(?*anyopaque, null), current_interruptable_extent);

    current_interruptable_extent = &dummy;
    reset_interruptable_extent();
    try std.testing.expectEqual(@as(?*anyopaque, null), current_interruptable_extent);

    try std.testing.expectEqual(@as(c_int, 0), enter_interruption_extent());
}
