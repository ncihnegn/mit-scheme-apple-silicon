const smoke_options = @import("smoke_options");

pub const prim_abi = @import("core/prim_abi.zig");

comptime {
    switch (smoke_options.unit) {
        .none => {},
        .runtime => {
            _ = @import("support/transact.zig");
            _ = @import("compiler/code_arena.zig");
        },
        .fasl => _ = @import("gc/fasl.zig"),
        .gcloop => _ = @import("gc/gcloop.zig"),
        .cmpintmd => _ = @import("compiler/cmpintmd.zig"),
        .cmpint => _ = @import("compiler/cmpint.zig"),
    }
}
