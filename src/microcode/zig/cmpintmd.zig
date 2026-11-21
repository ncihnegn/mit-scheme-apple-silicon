// Derived from MIT/GNU Scheme C sources (`src/microcode/cmpintmd/*.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("prim_abi.zig");

pub const aarch64 = @import("cmpintmd_aarch64.zig");

comptime {
    if (!builtin.is_test) {
        switch (build_options.compiler_processor_type) {
            abi.compiler_aarch64_type => aarch64.exportAll(),
            else => {},
        }
    }
}

test {
    _ = aarch64;
}
