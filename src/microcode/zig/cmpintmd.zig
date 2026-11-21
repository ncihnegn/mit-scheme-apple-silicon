// Derived from MIT/GNU Scheme C sources (`src/microcode/cmpintmd/*.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("prim_abi.zig");

pub const aarch64 = @import("cmpintmd_aarch64.zig");
pub const x86_64 = @import("cmpintmd_x86_64.zig");
pub const svm1 = @import("cmpintmd_svm1.zig");

comptime {
    if (!builtin.is_test) {
        switch (build_options.compiler_processor_type) {
            abi.compiler_aarch64_type => aarch64.exportAll(),
            abi.compiler_x86_64_type => x86_64.exportAll(),
            abi.compiler_svm_type => svm1.exportAll(),
            abi.compiler_none_type => {},
            else => @compileError("unsupported compiler_processor_type"),
        }
    }
}

test {
    _ = aarch64;
    _ = x86_64;
    _ = svm1;
}
