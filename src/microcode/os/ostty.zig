// Derived from MIT/GNU Scheme C sources (`src/microcode/ostty.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const abi = @import("../core/prim_abi.zig");
const osscheme = @import("osscheme.zig");

var next_interrupt_char: u8 = 0;

pub fn resetForTesting() void {
    next_interrupt_char = 0;
}

pub export fn tty_set_next_interrupt_char(c: u8) callconv(.c) void {
    if (next_interrupt_char == 0) {
        next_interrupt_char = c;
        osscheme.request_character_interrupt();
    }
}

pub export fn OS_tty_next_interrupt_char() callconv(.c) u8 {
    if (next_interrupt_char == 0) {
        abi.error_external_return();
    }
    const result = abi.OS_tty_map_interrupt_char(next_interrupt_char);
    next_interrupt_char = 0;
    return result;
}

test "ostty interrupt character latch and consume" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    resetForTesting();

    tty_set_next_interrupt_char('g');
    try std.testing.expect((abi.Registers[abi.regblock_int_code] & abi.int_character) != 0);
    // Subsequent char is ignored until the latched char is consumed.
    tty_set_next_interrupt_char('c');
    try std.testing.expectEqual(@as(u8, 'g'), OS_tty_next_interrupt_char());
    try std.testing.expectEqual(@as(u8, 0), next_interrupt_char);
}
