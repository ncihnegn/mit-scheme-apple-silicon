const std = @import("std");

pub const chacha = @import("chacha.zig");
pub const keccak = @import("keccak.zig");
pub const md5 = @import("md5.zig");

comptime {
    _ = chacha;
    _ = keccak;
    _ = md5;
}

test "microcode zig scaffold" {
    try std.testing.expect(true);
    std.testing.refAllDecls(@This());
    _ = chacha;
    _ = keccak;
    _ = md5;
}
