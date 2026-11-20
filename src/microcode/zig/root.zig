const std = @import("std");

pub const chacha = @import("chacha.zig");

comptime {
    _ = chacha;
}

test "microcode zig scaffold" {
    try std.testing.expect(true);
    std.testing.refAllDecls(@This());
    _ = chacha;
}
