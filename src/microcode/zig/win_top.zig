// Derived from MIT/GNU Scheme C sources (`src/microcode/uxtop.c`, `ux.c`, `uxsig.c`, `uxtrap.c`)
// and Win32 OS support:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const boot = @import("boot.zig");
const code_arena = @import("code_arena.zig");
const fasload = @import("fasload.zig");
const option = @import("option.zig");
const osscheme = @import("osscheme.zig");
const ostty = @import("ostty.zig");
const utils = @import("utils.zig");
const win = @import("win_api.zig");
const win_env = @import("win_env.zig");
const win_fs = @import("win_fs.zig");
const win_io = @import("win_io.zig");
const win_proc = @import("win_proc.zig");
const win_tty = @import("win_tty.zig");

pub var ux_out_of_files_p: bool = false;
var interactive: c_int = 0;
var trap_state: c_int = 1; // default exit until Scheme installs trap handler
var wsa_initialized: bool = false;

extern "c" fn strerror(errnum: c_int) ?[*:0]const u8;
extern "c" fn _isatty(fd: c_int) c_int;

// CRITICAL: Upstream MIT/GNU Scheme 13.0.50 `src/runtime/pathname.scm` only registers
// `known-host-types` `'((0 unix))`, and `runtime.pkg` unconditionally loads `unxprm`.
const system_name: [*:0]const u8 = "unix";
const system_variant: [*:0]const u8 = "Windows";

pub fn osMallocInit(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

pub fn osMalloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size) orelse utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
}

pub fn osRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(ptr, size) orelse utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_realloc);
}

pub fn osFree(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

pub fn uxPrimCheckErrno(name: c_int) callconv(.c) void {
    const err = std.c._errno().*;
    if (err != @intFromEnum(std.c.E.INTR)) {
        utils.error_system_call(err, name);
    }
    osscheme.deliver_pending_interrupts();
}

pub fn uxPrimCheckFdErrno(name: c_int) callconv(.c) void {
    const err = std.c._errno().*;
    if (err == @intFromEnum(std.c.E.INTR)) {
        osscheme.deliver_pending_interrupts();
        return;
    }
    if (err == @intFromEnum(std.c.E.MFILE) or err == @intFromEnum(std.c.E.NFILE)) {
        if (!ux_out_of_files_p) {
            ux_out_of_files_p = true;
            abi.requestGc(0);
            osscheme.deliver_pending_interrupts();
        }
    }
    utils.error_system_call(err, name);
}

pub fn osUnderEmacsP() callconv(.c) c_int {
    return @intFromBool(option.option_emacs_subprocess);
}

fn consoleCtrlHandler(ctrl_type: win.DWORD) callconv(.winapi) win.BOOL {
    switch (ctrl_type) {
        win.CTRL_C_EVENT => {
            if (interactive != 0) {
                ostty.tty_set_next_interrupt_char('g');
                return 1;
            }
            return 0;
        },
        win.CTRL_BREAK_EVENT => {
            if (interactive != 0) {
                ostty.tty_set_next_interrupt_char('c');
                return 1;
            }
            return 0;
        },
        else => return 0,
    }
}

fn vectoredExceptionHandler(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const code = info.ExceptionRecord.ExceptionCode;
    const is_fatal_hw = (code == win.EXCEPTION_ACCESS_VIOLATION or
        code == win.EXCEPTION_ILLEGAL_INSTRUCTION or
        code == win.EXCEPTION_INT_DIVIDE_BY_ZERO or
        code == win.EXCEPTION_STACK_OVERFLOW);
    if (!is_fatal_hw) return win.EXCEPTION_CONTINUE_SEARCH;
    if (trap_state == 4 or trap_state == 1) {
        return win.EXCEPTION_CONTINUE_SEARCH;
    }
    return win.EXCEPTION_CONTINUE_SEARCH;
}

pub fn osInitialize() callconv(.c) void {
    interactive = @intFromBool(
        option.option_force_interactive or
            _isatty(0) != 0 or
            _isatty(1) != 0 or
            _isatty(2) != 0,
    );
    if (option.option_batch_mode) {
        interactive = 0;
    }

    if (!wsa_initialized) {
        var wsa: win.WSADATA = std.mem.zeroes(win.WSADATA);
        if (win.ws2_32.WSAStartup(0x0202, &wsa) == 0) {
            wsa_initialized = true;
        }
    }

    win_io.initChannels();
    win_tty.initTty(interactive);
    win_env.initEnvironment();
    win_fs.initDirectoryReader();
    win_proc.initProcesses();

    _ = win.kernel32.SetConsoleCtrlHandler(&consoleCtrlHandler, 1);
    _ = win.kernel32.AddVectoredExceptionHandler(0, &vectoredExceptionHandler);

    boot.OS_Name = system_name;
    boot.OS_Variant = system_variant;
}

fn writeStdout(slice: []const u8) void {
    _ = std.c.fwrite(slice.ptr, 1, slice.len, abi.cStdout());
}

pub fn osAnnouncement() callconv(.c) void {
    if (!option.option_emacs_subprocess and win_tty.osCttyInterruptControl() != 0) {
        writeStdout("Type Ctrl-Break to interrupt execution.\n");
    }
}

pub fn osReset() callconv(.c) void {
    win_io.resetChannels();
    win_proc.resetProcesses();
    if (wsa_initialized) {
        _ = win.ws2_32.WSACleanup();
        wsa_initialized = false;
    }
    fasload.execute_reload_cleanups();
}

pub fn osQuit(_: c_int, abnormal_p: c_int) callconv(.c) void {
    _ = abi.fflush(abi.cStdout());
    if (abnormal_p != 0 and interactive != 0) {
        writeStdout("\nScheme has terminated abnormally!\n");
        _ = abi.fflush(abi.cStdout());
    }
    osRestoreExternalState();
}

pub fn uxDumpCore() callconv(.c) void {
    osRestoreExternalState();
    std.c.abort();
}

pub fn osSaveExternalState() callconv(.c) void {
    win_tty.saveExternalState();
}

pub fn osSaveInternalState() callconv(.c) void {
    win_tty.saveInternalState();
}

pub fn osRestoreInternalState() callconv(.c) void {
    win_tty.restoreInternalState();
}

pub fn osRestoreExternalState() callconv(.c) void {
    win_tty.restoreExternalState();
}

pub fn osGetEntropy(buf: *[32]u8) callconv(.c) void {
    const status = win.bcrypt.BCryptGenRandom(null, buf, 32, win.BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (status < 0) {
        abi.outf_fatal("\nOS_get_entropy: BCryptGenRandom failed (%d).\n", status);
        abi.outf_flush_fatal();
        abi.termination_trap();
    }
}

pub fn blockSignals() callconv(.c) void {}
pub fn unblockSignals() callconv(.c) void {}
pub fn preserveSignalMask() callconv(.c) void {}
pub fn osRestartableExit() callconv(.c) void {}

pub fn osTtyMapInterruptChar(int_char: abi.CcT) callconv(.c) abi.CcT {
    return int_char;
}

pub fn osSetTrapState(state: c_int) callconv(.c) c_int {
    const old = trap_state;
    trap_state = state;
    return old;
}

const scheme_alignment_mask: usize = @sizeOf(obj.SchemeObject) - 1;
const fixnum_marker: obj.SchemeObject = 0;
const uuo_link_size: usize = 2;

fn findBlockAddress(pc: usize, area_start: [*]obj.SchemeObject) ?[*]obj.SchemeObject {
    const pcp_addr = pc & ~scheme_alignment_mask;
    var first_valid = area_start;
    var area = area_start;

    while (@intFromPtr(area) < pcp_addr) {
        const object = area[0];
        switch (obj.objectType(object)) {
            obj.tc_linkage_section => {
                const count: usize = @intCast(abi.linkage_section_count(object));
                area += 1;
                switch (abi.linkage_section_type(object)) {
                    @intFromEnum(abi.LinkageSectionType.global_operator),
                    @intFromEnum(abi.LinkageSectionType.operator),
                    => area += count * uuo_link_size,
                    else => area += count,
                }
            },
            obj.tc_manifest_closure => {
                area = abi.compiled_closure_objects(area + 1);
            },
            obj.tc_manifest_nm_vector => {
                const count = obj.objectDatum(object);
                const word_advance: usize = @intCast(count + 1);
                if (count < std.math.maxInt(usize) / @sizeOf(obj.SchemeObject) and
                    (@intFromPtr(area) + word_advance * @sizeOf(obj.SchemeObject)) < pcp_addr)
                {
                    area += word_advance;
                    first_valid = area;
                } else {
                    if (@intFromPtr(area) == @intFromPtr(first_valid)) return null;
                    const block = area - 1;
                    const block_type = obj.objectType(block[0]);
                    if ((block_type == obj.tc_manifest_vector or block_type == fixnum_marker) and
                        obj.objectDatum(block[0]) >= count + 1 and
                        abi.plausible_cc_block_p(block) != 0)
                    {
                        return block;
                    }
                    return null;
                }
            },
            else => area += 1,
        }
    }
    return null;
}

pub fn findCcblock(pc: usize) callconv(.c) obj.SchemeObject {
    if (!build_options.cc_support) return obj.sharp_f;
    if ((pc & scheme_alignment_mask) != 0) return obj.sharp_f;
    const pc_ptr: ?*const anyopaque = @ptrFromInt(pc);
    if (pc >= @intFromPtr(abi.heap_start) and pc < @intFromPtr(abi.Free)) {
        return if (findBlockAddress(pc, abi.heap_start)) |blk| obj.makeCcBlock(blk) else obj.sharp_f;
    }
    if (pc >= @intFromPtr(abi.constant_start) and pc < @intFromPtr(abi.constant_end)) {
        return if (findBlockAddress(pc, abi.constant_start)) |blk| obj.makeCcBlock(blk) else obj.sharp_f;
    }
    if (abi.code_address_p(pc_ptr)) {
        const block = code_arena.code_arena_find_block(pc_ptr) orelse return obj.sharp_f;
        return if (abi.plausible_cc_block_p(block) != 0) obj.makeCcBlock(block) else obj.sharp_f;
    }
    return obj.sharp_f;
}

const ErrnoMapEntry = struct {
    syserr: c_int,
    field: []const u8,
};

const errno_map = [_]ErrnoMapEntry{
    .{ .syserr = 4, .field = "2BIG" },
    .{ .syserr = 35, .field = "ACCES" },
    .{ .syserr = 2, .field = "ADDRINUSE" },
    .{ .syserr = 3, .field = "ADDRNOTAVAIL" },
    .{ .syserr = 1, .field = "AFNOSUPPORT" },
    .{ .syserr = 39, .field = "AGAIN" },
    .{ .syserr = 6, .field = "BADF" },
    .{ .syserr = 37, .field = "BUSY" },
    .{ .syserr = 25, .field = "CHILD" },
    .{ .syserr = 8, .field = "CONNREFUSED" },
    .{ .syserr = 9, .field = "CONNRESET" },
    .{ .syserr = 38, .field = "DEADLK" },
    .{ .syserr = 11, .field = "DOM" },
    .{ .syserr = 13, .field = "EXIST" },
    .{ .syserr = 5, .field = "FAULT" },
    .{ .syserr = 14, .field = "FBIG" },
    .{ .syserr = 17, .field = "HOSTUNREACH" },
    .{ .syserr = 20, .field = "INTR" },
    .{ .syserr = 21, .field = "INVAL" },
    .{ .syserr = 23, .field = "IO" },
    .{ .syserr = 24, .field = "ISDIR" },
    .{ .syserr = 42, .field = "MFILE" },
    .{ .syserr = 41, .field = "MLINK" },
    .{ .syserr = 15, .field = "NAMETOOLONG" },
    .{ .syserr = 43, .field = "NFILE" },
    .{ .syserr = 28, .field = "NODEV" },
    .{ .syserr = 30, .field = "NOENT" },
    .{ .syserr = 12, .field = "NOEXEC" },
    .{ .syserr = 26, .field = "NOLCK" },
    .{ .syserr = 33, .field = "NOMEM" },
    .{ .syserr = 27, .field = "NOSPC" },
    .{ .syserr = 16, .field = "NOSYS" },
    .{ .syserr = 32, .field = "NOTDIR" },
    .{ .syserr = 10, .field = "NOTEMPTY" },
    .{ .syserr = 19, .field = "NOTTY" },
    .{ .syserr = 29, .field = "NXIO" },
    .{ .syserr = 34, .field = "PERM" },
    .{ .syserr = 7, .field = "PIPE" },
    .{ .syserr = 40, .field = "RANGE" },
    .{ .syserr = 36, .field = "ROFS" },
    .{ .syserr = 22, .field = "SPIPE" },
    .{ .syserr = 31, .field = "SRCH" },
    .{ .syserr = 18, .field = "XDEV" },
};

pub fn osErrorCodeToSyserr(code: c_int) callconv(.c) c_int {
    inline for (errno_map) |entry| {
        if (@hasField(std.c.E, entry.field)) {
            if (comptime std.mem.eql(u8, entry.field, "NOTEMPTY")) {
                if (@intFromEnum(@field(std.c.E, "NOTEMPTY")) != @intFromEnum(std.c.E.EXIST)) {
                    if (code == @intFromEnum(@field(std.c.E, entry.field))) return entry.syserr;
                }
            } else {
                if (code == @intFromEnum(@field(std.c.E, entry.field))) return entry.syserr;
            }
        }
    }
    return 0;
}

fn syserrToErrorCode(syserr: c_uint) c_int {
    inline for (errno_map) |entry| {
        if (@hasField(std.c.E, entry.field)) {
            if (syserr == entry.syserr) return @intFromEnum(@field(std.c.E, entry.field));
        }
    }
    return 0;
}

pub fn osErrorCodeToMessage(syserr: c_uint) callconv(.c) ?[*:0]const u8 {
    if (syserr == 0) return null;
    return strerror(syserrToErrorCode(syserr));
}

var syscall_names_table = [_]?[*:0]const u8{
    "accept",
    "bind",
    "chdir",
    "chmod",
    "clock_gettime",
    "close",
    "connect",
    "fcntl-getfl",
    "fcntl-fullfsync",
    "fcntl-setfl",
    "fdatasync",
    "fork",
    "fstat",
    "fstatfs",
    "fsync",
    "fsync_range",
    "ftruncate",
    "getcwd",
    "gethostname",
    "gettimeofday",
    "gmtime",
    "ioctl-tiocgpgrp",
    "ioctl-tiocsigsend",
    "kill",
    "link",
    "listen",
    "localtime",
    "lseek",
    "lstat",
    "malloc",
    "mkdir",
    "mktime",
    "ntp_adjtime",
    "ntp_gettime",
    "open",
    "opendir",
    "pause",
    "pipe",
    "read",
    "readlink",
    "realloc",
    "rename",
    "rmdir",
    "select",
    "setitimer",
    "setpgid",
    "setsockopt",
    "shutdown",
    "sighold",
    "sigprocmask",
    "sigsuspend",
    "sleep",
    "socket",
    "stat",
    "statfs",
    "symlink",
    "sync_file_range",
    "tcdrain",
    "tcflush",
    "tcgetpgrp",
    "tcsetpgrp",
    "terminal-get-state",
    "terminal-set-state",
    "time",
    "times",
    "uname",
    "unlink",
    "utime",
    "vfork",
    "write",
};

pub fn osSyscallNames(length: *usize, names: *[*]?[*:0]const u8) callconv(.c) void {
    length.* = syscall_names_table.len;
    names.* = &syscall_names_table;
}

var syserr_names_table = [_]?[*:0]const u8{
    "unknown",
    "address-family-not-supported",
    "address-in-use",
    "address-not-available",
    "arg-list-too-long",
    "bad-address",
    "bad-file-descriptor",
    "broken-pipe",
    "connection-refused",
    "connection-reset",
    "directory-not-empty",
    "domain-error",
    "exec-format-error",
    "file-exists",
    "file-too-large",
    "filename-too-long",
    "function-not-implemented",
    "host-is-unreachable",
    "improper-link",
    "inappropriate-io-control-operation",
    "interrupted-function-call",
    "invalid-argument",
    "invalid-seek",
    "io-error",
    "is-a-directory",
    "no-child-processes",
    "no-locks-available",
    "no-space-left-on-device",
    "no-such-device",
    "no-such-device-or-address",
    "no-such-file-or-directory",
    "no-such-process",
    "not-a-directory",
    "not-enough-space",
    "operation-not-permitted",
    "permission-denied",
    "read-only-file-system",
    "resource-busy",
    "resource-deadlock-avoided",
    "resource-temporarily-unavailable",
    "result-too-large",
    "too-many-links",
    "too-many-open-files",
    "too-many-open-files",
};

pub fn osSyserrNames(length: *usize, names: *[*]?[*:0]const u8) callconv(.c) void {
    length.* = syserr_names_table.len;
    names.* = &syserr_names_table;
}

pub fn osExpectSequentialAccess(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) void {}
pub fn osExpectNormalAccess(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) void {}
pub fn osFreePages(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

comptime {
    if (!builtin.is_test) {
        @export(&ux_out_of_files_p, .{ .name = "UX_out_of_files_p" });
        @export(&uxPrimCheckErrno, .{ .name = "UX_prim_check_errno" });
        @export(&uxPrimCheckFdErrno, .{ .name = "UX_prim_check_fd_errno" });
        @export(&osMallocInit, .{ .name = "OS_malloc_init" });
        @export(&osMalloc, .{ .name = "OS_malloc" });
        @export(&osRealloc, .{ .name = "OS_realloc" });
        @export(&osFree, .{ .name = "OS_free" });
        @export(&osUnderEmacsP, .{ .name = "OS_under_emacs_p" });
        @export(&osInitialize, .{ .name = "OS_initialize" });
        @export(&osAnnouncement, .{ .name = "OS_announcement" });
        @export(&osReset, .{ .name = "OS_reset" });
        @export(&osQuit, .{ .name = "OS_quit" });
        @export(&uxDumpCore, .{ .name = "UX_dump_core" });
        @export(&osSaveExternalState, .{ .name = "OS_save_external_state" });
        @export(&osSaveInternalState, .{ .name = "OS_save_internal_state" });
        @export(&osRestoreInternalState, .{ .name = "OS_restore_internal_state" });
        @export(&osRestoreExternalState, .{ .name = "OS_restore_external_state" });
        @export(&osErrorCodeToSyserr, .{ .name = "OS_error_code_to_syserr" });
        @export(&osErrorCodeToMessage, .{ .name = "OS_error_code_to_message" });
        @export(&osSyscallNames, .{ .name = "OS_syscall_names" });
        @export(&osSyserrNames, .{ .name = "OS_syserr_names" });
        @export(&osExpectSequentialAccess, .{ .name = "OS_expect_sequential_access" });
        @export(&osExpectNormalAccess, .{ .name = "OS_expect_normal_access" });
        @export(&osFreePages, .{ .name = "OS_free_pages" });
        @export(&osGetEntropy, .{ .name = "OS_get_entropy" });
        @export(&blockSignals, .{ .name = "block_signals" });
        @export(&unblockSignals, .{ .name = "unblock_signals" });
        @export(&preserveSignalMask, .{ .name = "preserve_signal_mask" });
        @export(&osRestartableExit, .{ .name = "OS_restartable_exit" });
        @export(&osTtyMapInterruptChar, .{ .name = "OS_tty_map_interrupt_char" });
        @export(&osSetTrapState, .{ .name = "OS_set_trap_state" });
        if (build_options.cc_support) {
            @export(&findCcblock, .{ .name = "find_ccblock" });
        }
    }
}
