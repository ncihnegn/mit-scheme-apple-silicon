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
pub const prim_abi = @import("prim_abi.zig");
pub const prchacha = @import("prchacha.zig");
pub const prkeccak = @import("prkeccak.zig");
pub const prmd5 = @import("prmd5.zig");
pub const prentropy = @import("prentropy.zig");
pub const bytevector = @import("bytevector.zig");

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
    _ = prim_abi;
    _ = prchacha;
    _ = prkeccak;
    _ = prmd5;
    _ = prentropy;
    _ = bytevector;
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
    _ = prim_abi;
    _ = prchacha;
    _ = prkeccak;
    _ = prmd5;
    _ = prentropy;
    _ = bytevector;
}
