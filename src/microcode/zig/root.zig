const std = @import("std");
const builtin = @import("builtin");

pub const chacha = @import("chacha.zig");
pub const keccak = @import("keccak.zig");
pub const md5 = @import("md5.zig");
pub const obstack = @import("obstack.zig");
pub const wind = @import("wind.zig");
pub const transact = @import("transact.zig");
pub const ptrvec = @import("ptrvec.zig");
pub const avltree = @import("avltree.zig");
pub const jit = @import("jit.zig");
pub const scheme_obj = @import("scheme_obj.zig");
pub const code_arena = @import("code_arena.zig");

comptime {
    _ = chacha;
    _ = keccak;
    _ = md5;
    _ = obstack;
    _ = wind;
    _ = transact;
    _ = ptrvec;
    _ = avltree;
    _ = jit;
    _ = code_arena;
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
    _ = ptrvec;
    _ = avltree;
    _ = jit;
    _ = scheme_obj;
    _ = code_arena;
}
