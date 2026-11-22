// Derived from MIT/GNU Scheme C sources (`src/microcode/floenv.h`, `src/microcode/floenv.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");

pub const FenvT = switch (builtin.os.tag) {
    .macos => switch (builtin.cpu.arch) {
        .aarch64 => extern struct {
            fpsr: u64,
            fpcr: u64,
        },
        .x86_64 => extern struct {
            control: u16,
            status: u16,
            mxcsr: u32,
            reserved: [8]u8,
        },
        else => @compileError("unsupported macOS CPU arch for fenv_t"),
    },
    .linux => switch (builtin.cpu.arch) {
        .aarch64 => extern struct {
            fpcr: u32,
            fpsr: u32,
        },
        .x86_64 => extern struct {
            words: [8]u32,
        },
        else => @compileError("unsupported Linux CPU arch for fenv_t"),
    },
    .windows => extern struct {
        fe_ctl: c_ulong,
        fe_stat: c_ulong,
    },
    else => @compileError("unsupported OS for fenv_t"),
};

pub const FexceptT = switch (builtin.os.tag) {
    .macos => u16,
    .linux => switch (builtin.cpu.arch) {
        .aarch64 => u32,
        .x86_64 => u16,
        else => @compileError("unsupported Linux CPU arch for fexcept_t"),
    },
    .windows => c_ulong,
    else => @compileError("unsupported OS for fexcept_t"),
};

pub const fe_invalid: c_int = if (builtin.os.tag == .windows) 0x0010 else switch (builtin.cpu.arch) {
    .aarch64 => 0x01,
    .x86_64 => 0x01,
    else => @compileError("unsupported arch"),
};

pub const fe_divbyzero: c_int = if (builtin.os.tag == .windows) 0x0008 else switch (builtin.cpu.arch) {
    .aarch64 => 0x02,
    .x86_64 => 0x04,
    else => @compileError("unsupported arch"),
};

pub const fe_overflow: c_int = if (builtin.os.tag == .windows) 0x0004 else switch (builtin.cpu.arch) {
    .aarch64 => 0x04,
    .x86_64 => 0x08,
    else => @compileError("unsupported arch"),
};

pub const fe_underflow: c_int = if (builtin.os.tag == .windows) 0x0002 else switch (builtin.cpu.arch) {
    .aarch64 => 0x08,
    .x86_64 => 0x10,
    else => @compileError("unsupported arch"),
};

pub const fe_inexact: c_int = if (builtin.os.tag == .windows) 0x0001 else switch (builtin.cpu.arch) {
    .aarch64 => 0x10,
    .x86_64 => 0x20,
    else => @compileError("unsupported arch"),
};

pub const fe_denormal: ?c_int = if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64) 0x02 else null;

pub const fe_all_except: c_int = switch (builtin.os.tag) {
    .macos => switch (builtin.cpu.arch) {
        .aarch64 => 0x9f,
        .x86_64 => 0x3f,
        else => @compileError("unsupported arch"),
    },
    .linux => switch (builtin.cpu.arch) {
        .aarch64 => 31,
        .x86_64 => if (builtin.abi.isGnu()) 0x3d else 0x3f,
        else => @compileError("unsupported arch"),
    },
    .windows => 0x001f,
    else => @compileError("unsupported OS"),
};

pub const fe_tonearest: c_int = 0;

pub const fe_upward: c_int = if (builtin.os.tag == .windows) 0x0200 else switch (builtin.cpu.arch) {
    .aarch64 => 0x400000,
    .x86_64 => 0x800,
    else => @compileError("unsupported arch"),
};

pub const fe_downward: c_int = if (builtin.os.tag == .windows) 0x0100 else switch (builtin.cpu.arch) {
    .aarch64 => 0x800000,
    .x86_64 => 0x400,
    else => @compileError("unsupported arch"),
};

pub const fe_towardzero: c_int = if (builtin.os.tag == .windows) 0x0300 else switch (builtin.cpu.arch) {
    .aarch64 => 0xc00000,
    .x86_64 => 0xc00,
    else => @compileError("unsupported arch"),
};

pub const darwin_x86_64_feexcept: bool = builtin.os.tag == .macos and builtin.cpu.arch == .x86_64;

pub const have_feexcept_traps: bool = switch (builtin.os.tag) {
    .macos => builtin.cpu.arch == .x86_64,
    .linux => builtin.abi.isGnu(),
    else => false,
};

pub extern "c" fn fegetenv(*FenvT) c_int;
pub extern "c" fn fesetenv(*const FenvT) c_int;
pub extern "c" fn feholdexcept(*FenvT) c_int;
pub extern "c" fn feupdateenv(*const FenvT) c_int;
pub extern "c" fn fegetround() c_int;
pub extern "c" fn fesetround(c_int) c_int;
pub extern "c" fn fetestexcept(c_int) c_int;
pub extern "c" fn feclearexcept(c_int) c_int;
pub extern "c" fn feraiseexcept(c_int) c_int;
pub extern "c" fn fegetexceptflag(*FexceptT, c_int) c_int;
pub extern "c" fn fesetexceptflag(*const FexceptT, c_int) c_int;

const linux_traps = struct {
    extern "c" fn fegetexcept() c_int;
    extern "c" fn feenableexcept(c_int) c_int;
    extern "c" fn fedisableexcept(c_int) c_int;
};

inline fn getMxcsr() u32 {
    var csr: u32 = 0;
    asm volatile ("stmxcsr (%[ptr])"
        :
        : [ptr] "r" (&csr),
        : .{ .memory = true });
    return csr;
}

inline fn setMxcsr(csr: u32) void {
    asm volatile ("ldmxcsr (%[ptr])"
        :
        : [ptr] "r" (&csr),
        : .{ .memory = true });
}

fn darwinFegetexcept() callconv(.c) c_int {
    return @intCast((~(getMxcsr() >> 7)) & @as(u32, @intCast(fe_all_except)));
}

fn darwinFeenableexcept(excepts: c_uint) callconv(.c) c_int {
    const mask: u32 = @intCast(fe_all_except);
    const csr = getMxcsr();
    const old_excepts: c_uint = (~(csr >> 7)) & mask;
    setMxcsr(csr & ~((excepts & mask) << 7));
    return @intCast(old_excepts);
}

fn darwinFedisableexcept(excepts: c_uint) callconv(.c) c_int {
    const mask: u32 = @intCast(fe_all_except);
    const csr = getMxcsr();
    const old_excepts: c_uint = (~(csr >> 7)) & mask;
    setMxcsr(csr | ((excepts & mask) << 7));
    return @intCast(old_excepts);
}

comptime {
    if (darwin_x86_64_feexcept) {
        @export(&darwinFegetexcept, .{ .name = "fegetexcept" });
        @export(&darwinFeenableexcept, .{ .name = "feenableexcept" });
        @export(&darwinFedisableexcept, .{ .name = "fedisableexcept" });
    }
}

pub fn getExcept() c_int {
    if (comptime darwin_x86_64_feexcept) return darwinFegetexcept();
    return linux_traps.fegetexcept();
}

pub fn enableExcept(excepts: c_int) c_int {
    if (comptime darwin_x86_64_feexcept) return darwinFeenableexcept(@bitCast(excepts));
    return linux_traps.feenableexcept(excepts);
}

pub fn disableExcept(excepts: c_int) c_int {
    if (comptime darwin_x86_64_feexcept) return darwinFedisableexcept(@bitCast(excepts));
    return linux_traps.fedisableexcept(excepts);
}

pub fn setDefaultEnv() c_int {
    if (comptime builtin.os.tag.isDarwin()) {
        const darwin_dfl = struct {
            extern "c" var _FE_DFL_ENV: FenvT;
        };
        return fesetenv(&darwin_dfl._FE_DFL_ENV);
    } else if (comptime builtin.os.tag == .linux) {
        const raw_fn: *const fn (?*const anyopaque) callconv(.c) c_int = @ptrCast(&fesetenv);
        return raw_fn(@ptrFromInt(std.math.maxInt(usize)));
    } else if (comptime builtin.os.tag == .windows) {
        const mingw_dfl = struct {
            extern "c" var __mingw_fe_dfl_env: FenvT;
        };
        return fesetenv(&mingw_dfl.__mingw_fe_dfl_env);
    } else {
        @compileError("unsupported OS for FE_DFL_ENV");
    }
}

test "fenv_plat sizes and exception masks match host libc invariants" {
    try std.testing.expect((fe_all_except & fe_invalid) == fe_invalid);
    try std.testing.expect((fe_all_except & fe_divbyzero) == fe_divbyzero);
    try std.testing.expect((fe_all_except & fe_overflow) == fe_overflow);
    try std.testing.expect((fe_all_except & fe_underflow) == fe_underflow);
    try std.testing.expect((fe_all_except & fe_inexact) == fe_inexact);

    var env: FenvT = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fegetenv(&env));
    try std.testing.expectEqual(@as(c_int, 0), setDefaultEnv());
    try std.testing.expectEqual(@as(c_int, 0), fesetenv(&env));
}
