const std = @import("std");

pub const chacha = @import("chacha.zig");
pub const keccak = @import("keccak.zig");

comptime {
    _ = chacha;
    _ = keccak;
}

test "microcode zig scaffold" {
    try std.testing.expect(true);
    std.testing.refAllDecls(@This());
    _ = chacha;
    _ = keccak;
}
