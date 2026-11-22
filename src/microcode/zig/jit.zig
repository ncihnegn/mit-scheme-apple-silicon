// Derived from MIT/GNU Scheme C sources (`src/microcode/jit.h`, `src/microcode/jit.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const wind = @import("wind.zig");
const win = @import("win_api.zig");
const outf = @import("outf.zig");

// Ensure wind + obstack exports are emitted when jit.zig is built standalone.
comptime {
    _ = wind;
}

const cc_is_native: bool = build_options.cc_is_native;
const is_apple_jit: bool = builtin.os.tag.isDarwin() and builtin.cpu.arch == .aarch64;
const use_apple_jit_wx: bool = is_apple_jit and cc_is_native;
const has_mmap: bool = builtin.os.tag.isDarwin() or builtin.os.tag == .linux;
const is_windows: bool = builtin.os.tag == .windows;

extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn abort() noreturn;

const darwin_ext = struct {
    extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
    extern "c" fn sys_icache_invalidate(start: ?*anyopaque, len: usize) void;
};

pub export var jit_write_depth: c_uint = 0;

var cached_page_size: usize = 0;

fn fatalError(message: [*:0]const u8) noreturn {
    outf.fatal("{s}", .{message});
    outf.flushFatal();
    abort();
}

pub export fn jit_available_p() callconv(.c) bool {
    return use_apple_jit_wx or has_mmap or is_windows;
}

pub export fn jit_page_size() callconv(.c) usize {
    if (cached_page_size == 0) {
        if (comptime is_windows) {
            var si: win.SYSTEM_INFO = std.mem.zeroes(win.SYSTEM_INFO);
            win.kernel32.GetSystemInfo(&si);
            cached_page_size = if (si.dwPageSize > 0) @intCast(si.dwPageSize) else 0x1000;
        } else {
            const ps = std.c.sysconf(@intFromEnum(std.c._SC.PAGESIZE));
            const fallback: usize = if (is_apple_jit) 0x4000 else 0x1000;
            cached_page_size = if (ps > 0) @intCast(ps) else fallback;
        }
    }
    return cached_page_size;
}

fn roundUpPages(byte_length: usize) usize {
    const ps = jit_page_size();
    if (byte_length == 0) return ps;
    if (byte_length > std.math.maxInt(usize) - (ps - 1)) return 0;
    return ((byte_length + (ps - 1)) / ps) * ps;
}

pub export fn jit_map_code_space(byte_length: usize) callconv(.c) ?*anyopaque {
    const size = roundUpPages(byte_length);
    if (size == 0) return null;

    if (comptime is_windows) {
        return win.kernel32.VirtualAlloc(
            null,
            size,
            win.MEM_COMMIT | win.MEM_RESERVE,
            if (cc_is_native) win.PAGE_EXECUTE_READWRITE else win.PAGE_READWRITE,
        );
    } else if (comptime use_apple_jit_wx) {
        const addr = std.c.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        );
        if (addr == std.c.MAP_FAILED) return null;
        if (jit_write_depth == 0) {
            darwin_ext.pthread_jit_write_protect_np(1);
        }
        return addr;
    } else if (comptime has_mmap) {
        const addr = std.c.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true, .EXEC = cc_is_native },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        return if (addr == std.c.MAP_FAILED) null else addr;
    } else {
        return std.c.malloc(size);
    }
}

pub export fn jit_unmap_code_space(addr: ?*anyopaque, byte_length: usize) callconv(.c) void {
    const ptr = addr orelse return;
    if (comptime is_windows) {
        _ = win.kernel32.VirtualFree(ptr, 0, win.MEM_RELEASE);
    } else if (comptime use_apple_jit_wx or has_mmap) {
        const size = roundUpPages(byte_length);
        if (size != 0) {
            _ = munmap(ptr, size);
        }
    } else {
        std.c.free(ptr);
    }
}

pub export fn jit_write_begin() callconv(.c) void {
    if (jit_write_depth == std.math.maxInt(c_uint)) {
        fatalError("jit_write_begin: nesting overflow\n");
    }
    if (jit_write_depth == 0) {
        if (comptime use_apple_jit_wx) {
            darwin_ext.pthread_jit_write_protect_np(0);
        }
    }
    jit_write_depth += 1;
}

pub export fn jit_write_end() callconv(.c) void {
    if (jit_write_depth == 0) {
        fatalError("jit_write_end: unmatched call\n");
    }
    jit_write_depth -= 1;
    if (jit_write_depth == 0) {
        if (comptime use_apple_jit_wx) {
            darwin_ext.pthread_jit_write_protect_np(1);
        }
    }
}

pub export fn jit_write_nesting_depth() callconv(.c) c_uint {
    return jit_write_depth;
}

fn jitUnwindWriteEnd(_: ?*anyopaque) callconv(.c) void {
    if (jit_write_depth > 0) {
        jit_write_end();
    }
}

pub export fn jit_write_scope_begin() callconv(.c) ?*anyopaque {
    const saved = wind.dstack_position;
    wind.dstack_protect(&jitUnwindWriteEnd, null);
    jit_write_begin();
    return saved;
}

pub export fn jit_write_scope_end(saved_dstack_pos: ?*anyopaque) callconv(.c) void {
    wind.dstack_set_position(saved_dstack_pos);
}

pub export fn jit_force_execute_mode() callconv(.c) void {
    jit_write_depth = 0;
    if (comptime use_apple_jit_wx) {
        darwin_ext.pthread_jit_write_protect_np(1);
    }
}

pub export fn jit_flush_icache(addr: ?*anyopaque, byte_length: usize) callconv(.c) void {
    const ptr = addr orelse return;
    if (byte_length == 0) return;

    if (comptime builtin.os.tag.isDarwin()) {
        darwin_ext.sys_icache_invalidate(ptr, byte_length);
    } else if (comptime is_windows) {
        _ = win.kernel32.FlushInstructionCache(win.kernel32.GetCurrentProcess(), ptr, byte_length);
    } else if (comptime builtin.cpu.arch == .aarch64) {
        const ctr_el0 = asm volatile ("mrs %[ret], ctr_el0"
            : [ret] "=r" (-> u64),
        );
        const dshift: u6 = @intCast((ctr_el0 >> 16) & 0xf);
        const ishift: u6 = @intCast(ctr_el0 & 0xf);
        const dcache_line_size: usize = @as(usize, 4) << dshift;
        const icache_line_size: usize = @as(usize, 4) << ishift;
        const start = @intFromPtr(ptr);
        const end = start + byte_length;

        var p = start & ~(dcache_line_size - 1);
        while (p < end) : (p += dcache_line_size) {
            asm volatile ("dc cvau, %[addr]"
                :
                : [addr] "r" (p),
            );
        }
        asm volatile ("dsb ish" ::: .{ .memory = true });

        p = start & ~(icache_line_size - 1);
        while (p < end) : (p += icache_line_size) {
            asm volatile ("ic ivau, %[addr]"
                :
                : [addr] "r" (p),
            );
        }
        asm volatile (
            \\dsb ish
            \\isb
            ::: .{ .memory = true });
    }
}

test "jit mapping, write scope, nesting depth, and icache flush" {
    _ = @import("test_stubs.zig");

    wind.dstack_initialize();
    defer wind.dstack_reset();

    try std.testing.expect(jit_available_p());
    const ps = jit_page_size();
    try std.testing.expect(ps >= 4096 and (ps & (ps - 1)) == 0);

    const code = jit_map_code_space(64).?;
    defer jit_unmap_code_space(code, 64);

    try std.testing.expectEqual(@as(c_uint, 0), jit_write_nesting_depth());
    const scope = jit_write_scope_begin();
    try std.testing.expectEqual(@as(c_uint, 1), jit_write_nesting_depth());

    jit_write_begin();
    try std.testing.expectEqual(@as(c_uint, 2), jit_write_nesting_depth());
    const word_ptr: *volatile u32 = @ptrCast(@alignCast(code));
    word_ptr.* = 0xD65F03C0;
    jit_write_end();
    try std.testing.expectEqual(@as(c_uint, 1), jit_write_nesting_depth());

    jit_flush_icache(code, 4);
    jit_write_scope_end(scope);
    try std.testing.expectEqual(@as(c_uint, 0), jit_write_nesting_depth());
    try std.testing.expectEqual(@as(u32, 0xD65F03C0), word_ptr.*);

    jit_write_begin();
    try std.testing.expectEqual(@as(c_uint, 1), jit_write_nesting_depth());
    jit_force_execute_mode();
    try std.testing.expectEqual(@as(c_uint, 0), jit_write_nesting_depth());
}
