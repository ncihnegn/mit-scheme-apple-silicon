const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const osscheme = @import("osscheme.zig");
const utils = @import("utils.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

pub var ux_out_of_files_p: bool = false;
var memoized_clk_tck: abi.ClockT = 0;

/// Check C `errno` after a failed syscall: deliver pending interrupts on `EINTR` or raise a system call error.
pub fn uxPrimCheckErrno(name: c_int) callconv(.c) void {
    const err = std.c._errno().*;
    if (err != @backingInt(std.c.E.INTR)) {
        utils.error_system_call(err, name);
    }
    osscheme.deliver_pending_interrupts();
}

/// Check C `errno` after a descriptor-allocating syscall, requesting GC once on `EMFILE`/`ENFILE`.
pub fn uxPrimCheckFdErrno(name: c_int) callconv(.c) void {
    const err = std.c._errno().*;
    if (err == @backingInt(std.c.E.INTR)) {
        osscheme.deliver_pending_interrupts();
        return;
    }
    if (err == @backingInt(std.c.E.MFILE) or err == @backingInt(std.c.E.NFILE)) {
        if (!ux_out_of_files_p) {
            ux_out_of_files_p = true;
            abi.requestGc(0);
            osscheme.deliver_pending_interrupts();
        }
    }
    utils.error_system_call(err, name);
}

/// Read POSIX `termios` state for `fd` into `s`, returning 0 or -1 on error.
pub fn uxTerminalGetState(fd: c_int, s: *abi.TttyState) callconv(.c) c_int {
    return if (std.c.tcgetattr(fd, &s.tio) < 0) -1 else 0;
}

/// Apply POSIX `termios` state from `s` to `fd` immediately (`TCSANOW`), returning 0 or -1 on error.
pub fn uxTerminalSetState(fd: c_int, s: *const abi.TttyState) callconv(.c) c_int {
    return if (std.c.tcsetattr(fd, .NOW, &s.tio) < 0) -1 else 0;
}

/// Return `_POSIX_VDISABLE` sentinel byte for disabling special terminal control characters.
pub fn uxPcVdisable(_: c_int) callconv(.c) abi.CcT {
    return if (builtin.os.tag.isDarwin()) 0xff else 0;
}

/// Return clock ticks per second (`sysconf(_SC_CLK_TCK)`), memoized across calls.
pub fn uxScClkTck() callconv(.c) abi.ClockT {
    if (memoized_clk_tck == 0) {
        const sc_clk_tck: c_int = if (builtin.os.tag.isDarwin()) 3 else 2;
        memoized_clk_tck = @intCast(std.c.sysconf(sc_clk_tck));
    }
    return memoized_clk_tck;
}

/// Close all file descriptors from `start_fd` up to `_SC_OPEN_MAX`, ignoring `EBADF`.
pub fn uxClosefrom(start_fd: c_int) callconv(.c) c_int {
    const sc_open_max: c_int = if (builtin.os.tag.isDarwin()) 5 else 4;
    const fd_limit: c_int = @intCast(std.c.sysconf(sc_open_max));
    var status: c_int = 0;
    var last_err: c_int = 0;
    var fd = start_fd;
    while (fd < fd_limit) : (fd += 1) {
        if (std.c.close(fd) < 0) {
            const err = std.c._errno().*;
            if (err != @backingInt(std.c.E.BADF)) {
                status = -1;
                last_err = err;
            }
        }
    }
    std.c._errno().* = last_err;
    return status;
}

/// Allocate raw OS memory during VM initialization without raising Scheme errors on failure.
pub fn osMallocInit(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

/// Allocate `size` bytes via `malloc` or signal `ENOMEM` (`syscall_malloc`).
pub fn osMalloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size) orelse utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_malloc);
}

/// Reallocate `ptr` to `size` bytes via `realloc` or signal `ENOMEM` (`syscall_realloc`).
pub fn osRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(ptr, size) orelse utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_realloc);
}

/// Free memory allocated via `OS_malloc`, `OS_malloc_init`, or `OS_realloc`.
pub fn osFree(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

comptime {
    if (!builtin.is_test) {
        @export(&ux_out_of_files_p, .{ .name = "UX_out_of_files_p" });
        @export(&uxPrimCheckErrno, .{ .name = "UX_prim_check_errno" });
        @export(&uxPrimCheckFdErrno, .{ .name = "UX_prim_check_fd_errno" });
        @export(&uxTerminalGetState, .{ .name = "UX_terminal_get_state" });
        @export(&uxTerminalSetState, .{ .name = "UX_terminal_set_state" });
        @export(&uxPcVdisable, .{ .name = "UX_PC_VDISABLE" });
        @export(&uxScClkTck, .{ .name = "UX_SC_CLK_TCK" });
        @export(&uxClosefrom, .{ .name = "UX_closefrom" });
        @export(&osMallocInit, .{ .name = "OS_malloc_init" });
        @export(&osMalloc, .{ .name = "OS_malloc" });
        @export(&osRealloc, .{ .name = "OS_realloc" });
        @export(&osFree, .{ .name = "OS_free" });
    }
}

test "ux sysconf, allocation helpers, closefrom, and EINTR handling" {
    stubs.resetMockRuntime();

    const clk = uxScClkTck();
    try std.testing.expect(clk > 0);
    try std.testing.expectEqual(clk, uxScClkTck());
    try std.testing.expectEqual(if (builtin.os.tag.isDarwin()) @as(abi.CcT, 0xff) else @as(abi.CcT, 0), uxPcVdisable(0));

    const p0 = osMallocInit(16);
    try std.testing.expect(p0 != null);
    osFree(p0);

    const p1 = osMalloc(32);
    try std.testing.expect(p1 != null);
    const p2 = osRealloc(p1, 64);
    try std.testing.expect(p2 != null);
    osFree(p2);

    const sc_open_max: c_int = if (builtin.os.tag.isDarwin()) 5 else 4;
    const fd_limit: c_int = @intCast(std.c.sysconf(sc_open_max));
    try std.testing.expectEqual(@as(c_int, 0), uxClosefrom(fd_limit));

    std.c._errno().* = @backingInt(std.c.E.INTR);
    uxPrimCheckErrno(abi.syscall_read);
    uxPrimCheckFdErrno(abi.syscall_open);
}
