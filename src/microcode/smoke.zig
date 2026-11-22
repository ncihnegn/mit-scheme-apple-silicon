const build_options = @import("build_options");
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
        .cmpintmd => switch (build_options.compiler_processor_type) {
            prim_abi.compiler_aarch64_type => @import("compiler/cmpintmd_aarch64.zig").exportAll(),
            prim_abi.compiler_x86_64_type => @import("compiler/cmpintmd_x86_64.zig").exportCore(),
            prim_abi.compiler_svm_type => @import("compiler/cmpintmd_svm1.zig").exportAll(),
            prim_abi.compiler_none_type => {},
            else => @compileError("unsupported compiler_processor_type"),
        },
        .cmpint => {
            _ = @import("compiler/cmpint.zig");
            if (build_options.compiler_processor_type == prim_abi.compiler_x86_64_type) {
                @import("compiler/cmpintmd_x86_64.zig").exportResetHook();
            }
        },
    }
}
