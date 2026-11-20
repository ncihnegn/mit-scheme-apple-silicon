const std = @import("std");
const builtin = @import("builtin");

pub const chacha = @import("chacha.zig");
pub const keccak = @import("keccak.zig");
pub const md5 = @import("md5.zig");
pub const obstack = @import("obstack.zig");
pub const wind = @import("wind.zig");
pub const transact = @import("transact.zig");

comptime {
    _ = chacha;
    _ = keccak;
    _ = md5;
    _ = obstack;
    _ = wind;
    _ = transact;
    if (builtin.is_test) {
        _ = @import("test_stubs.zig");
    }
}

test "microcode zig scaffold" {
    try std.testing.expect(true);
    std.testing.refAllDecls(@This());
    _ = chacha;
    _ = keccak;
    _ = md5;
    _ = obstack;
    _ = wind;
    _ = transact;
}
