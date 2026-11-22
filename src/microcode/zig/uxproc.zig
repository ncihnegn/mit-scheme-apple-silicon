// Derived from MIT/GNU Scheme C sources (`src/microcode/uxproc.c`, `src/microcode/uxproc.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const outf = @import("outf.zig");
const osscheme = @import("osscheme.zig");
const transact = @import("transact.zig");
const utils = @import("utils.zig");
const ux = @import("ux.zig");
const wind = @import("wind.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

pub var os_process_table_size: abi.Tprocess = 0;
pub var process_table_ptr: ?[*]abi.Process = null;
pub var scheme_jc_status: abi.ProcessJcStatus = .no_ctty;

var scheme_ctty_fd: c_int = -1;
var foreground_child_process: abi.Tprocess = abi.no_process;
var process_tick: isize = 0;
var sync_tick: isize = 0;
var grabbed_signal_mask: std.c.sigset_t = std.mem.zeroes(std.c.sigset_t);

const tiocsctty: c_ulong = if (builtin.os.tag.isDarwin()) 0x20007461 else 0x540E;
const RawSpeedT = @typeInfo(std.c.speed_t).@"enum".tag_type;

extern "c" fn fork() std.c.pid_t;
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn sigsuspend(mask: *const std.c.sigset_t) c_int;
extern "c" fn tcgetpgrp(fd: c_int) std.c.pid_t;
extern "c" fn tcsetpgrp(fd: c_int, pgrp: std.c.pid_t) c_int;
extern "c" fn getpgrp() std.c.pid_t;
extern "c" fn cfsetispeed(t: *std.c.termios, speed: RawSpeedT) c_int;
extern "c" fn cfsetospeed(t: *std.c.termios, speed: RawSpeedT) c_int;

inline fn volatileReadTick(ptr: *const isize) isize {
    return @as(*const volatile isize, ptr).*;
}

inline fn volatileReadRawStatus(p: abi.Tprocess) abi.ProcessStatus {
    return @as(*const volatile abi.ProcessStatus, &process_table_ptr.?[p].raw_status).*;
}

inline fn newRawStatus(p: abi.Tprocess, status: abi.ProcessStatus, reason: c_ushort) void {
    const entry = &process_table_ptr.?[p];
    entry.raw_status = status;
    entry.raw_reason = reason;
    const next_tick = process_tick + 1;
    process_tick = next_tick;
    entry.tick = next_tick;
}

inline fn syncProcessEntry(p: abi.Tprocess) void {
    const entry = &process_table_ptr.?[p];
    entry.status = entry.raw_status;
    entry.reason = entry.raw_reason;
    entry.sync_tick = entry.tick;
}

fn schemeInForeground() bool {
    return tcgetpgrp(scheme_ctty_fd) == getpgrp();
}

fn restoreSignalMask(environment: ?*anyopaque) callconv(.c) void {
    const mask: *const std.c.sigset_t = @ptrCast(@alignCast(environment.?));
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, mask, null);
}

fn blockSignalsList(sigs: []const std.c.SIG) void {
    const outside: *std.c.sigset_t = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(std.c.sigset_t)).?));
    var mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&mask);
    for (sigs) |sig| {
        _ = std.c.sigaddset(&mask, sig);
    }
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, &mask, outside);
    transact.transaction_record_action(.tat_always, &restoreSignalMask, @ptrCast(outside));
}

fn blockSigchld() void {
    blockSignalsList(&.{.CHLD});
}

fn blockJcSignals() void {
    blockSignalsList(&.{ .CHLD, .TTOU, .TTIN, .TSTP, .STOP });
}

fn grabSignalMask() void {
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, null, &grabbed_signal_mask);
}

/// Allocate the process table and install signal hooks (`UX_initialize_processes`).
pub fn uxInitializeProcesses() callconv(.c) void {
    const init_size: usize = 64;
    const raw = std.c.malloc(init_size * @sizeOf(abi.Process)) orelse {
        outf.fatal("\nUnable to allocate process table.\n", .{});
        outf.flushFatal();
        abi.termination_init_error();
    };
    process_table_ptr = @ptrCast(@alignCast(raw));
    os_process_table_size = init_size;
    var p: abi.Tprocess = 0;
    while (p < os_process_table_size) : (p += 1) {
        osProcessDeallocate(p);
    }
    scheme_ctty_fd = abi.OS_ctty_fd();
    scheme_jc_status = if (scheme_ctty_fd < 0) .no_ctty else .jc;
    foreground_child_process = abi.no_process;
    abi.subprocess_death_hook = &subprocessDeath;
    abi.stop_signal_hook = &stopSignalHandler;
    process_tick = 0;
    sync_tick = 0;
}

/// Free the process table during microcode reset/reload (`UX_reset_processes`).
pub fn uxResetProcesses() callconv(.c) void {
    if (process_table_ptr) |table| {
        std.c.free(@ptrCast(table));
    }
    process_table_ptr = null;
    os_process_table_size = 0;
}

fn processAllocateAbort(environment: ?*anyopaque) callconv(.c) void {
    const p = @as(*const abi.Tprocess, @ptrCast(@alignCast(environment.?))).*;
    const entry = &process_table_ptr.?[p];
    switch (entry.raw_status) {
        .stopped, .running => {
            _ = kill(entry.id, @intFromEnum(std.c.SIG.KILL));
        },
        else => {},
    }
    osProcessDeallocate(p);
}

fn processAllocate() abi.Tprocess {
    var table = process_table_ptr.?;
    var p: abi.Tprocess = 0;
    while (p < os_process_table_size) : (p += 1) {
        if (table[p].raw_status == .free) {
            table[p].raw_status = .allocated;
            break;
        }
    }
    if (p == os_process_table_size) {
        const old_size: usize = os_process_table_size;
        const new_size: usize = (old_size * 5) / 4;
        const raw = std.c.realloc(@ptrCast(table), new_size * @sizeOf(abi.Process)) orelse {
            osscheme.error_out_of_processes();
        };
        table = @ptrCast(@alignCast(raw));
        process_table_ptr = table;
        os_process_table_size = @intCast(new_size);
        var idx: abi.Tprocess = @intCast(old_size);
        while (idx < os_process_table_size) : (idx += 1) {
            osProcessDeallocate(idx);
        }
        p = @intCast(old_size);
        table[p].raw_status = .allocated;
    }
    const pp: *abi.Tprocess = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(abi.Tprocess)).?));
    pp.* = p;
    transact.transaction_record_action(.tat_abort, &processAllocateAbort, @ptrCast(pp));
    return p;
}

/// Release `process` slot in the process table (`OS_process_deallocate`).
pub fn osProcessDeallocate(process: abi.Tprocess) callconv(.c) void {
    const entry = &process_table_ptr.?[process];
    entry.id = 0;
    entry.raw_status = .free;
}

fn clearOflagField(comptime name: []const u8, oflag: *std.c.tc_oflag_t) void {
    if (@hasField(std.c.tc_oflag_t, name)) {
        const FieldT = @TypeOf(@field(oflag.*, name));
        @field(oflag.*, name) = switch (@typeInfo(FieldT)) {
            .@"enum" => @enumFromInt(0),
            .int => 0,
            .bool => false,
            else => unreachable,
        };
    }
}

fn childSetupTty(fd: c_int) c_int {
    const disabled_char = ux.uxPcVdisable(fd);
    var s: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &s) < 0) return -1;
    if (@hasField(std.c.tc_iflag_t, "IUCLC")) {
        s.iflag.IUCLC = false;
    }
    s.oflag.OPOST = true;
    clearOflagField("OLCUC", &s.oflag);
    s.oflag.ONLCR = false;
    clearOflagField("NLDLY", &s.oflag);
    clearOflagField("CRDLY", &s.oflag);
    clearOflagField("TABDLY", &s.oflag);
    clearOflagField("BSDLY", &s.oflag);
    clearOflagField("VTDLY", &s.oflag);
    clearOflagField("FFDLY", &s.oflag);
    s.lflag.ECHO = false;
    s.lflag.ECHOE = false;
    s.lflag.ECHOK = false;
    s.lflag.ECHONL = false;
    s.lflag.ICANON = true;
    s.lflag.ISIG = true;
    s.cc[@intFromEnum(std.c.V.EOF)] = 0o004;
    s.cc[@intFromEnum(std.c.V.ERASE)] = disabled_char;
    s.cc[@intFromEnum(std.c.V.KILL)] = disabled_char;
    const b9600: RawSpeedT = @intFromEnum(std.c.speed_t.B9600);
    _ = cfsetispeed(&s, b9600);
    _ = cfsetospeed(&s, b9600);
    return std.c.tcsetattr(fd, .DRAIN, &s);
}

fn execChildProcess(
    filename: [*:0]const u8,
    argv: [*]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    working_directory: ?[*:0]const u8,
    ctty_type: abi.ProcessCttyType,
    ctty_name: ?[*:0]u8,
    child_jc_status: abi.ProcessJcStatus,
    channel_in_type: abi.ProcessChannelType,
    channel_in: abi.Tchannel,
    channel_out_type: abi.ProcessChannelType,
    channel_out: abi.Tchannel,
    channel_err_type: abi.ProcessChannelType,
    channel_err: abi.Tchannel,
) noreturn {
    const child_pid = std.c.getpid();
    if (working_directory) |wd| {
        if (std.c.chdir(wd) < 0) std.c._exit(1);
    }

    var in_fd: c_int = if (channel_in_type == .explicit) abi.channel_table[channel_in].descriptor else -1;
    var out_fd: c_int = if (channel_out_type == .explicit) abi.channel_table[channel_out].descriptor else -1;
    var err_fd: c_int = if (channel_err_type == .explicit) abi.channel_table[channel_err].descriptor else -1;

    if (ctty_type == .inherit_bg or ctty_type == .inherit_fg) {
        if (child_jc_status == .jc) {
            if (std.c.setpgid(child_pid, child_pid) < 0) std.c._exit(1);
            if (ctty_type == .inherit_fg and schemeInForeground()) {
                if (tcsetpgrp(scheme_ctty_fd, child_pid) < 0) std.c._exit(1);
            }
        }
    } else {
        if (std.c.setsid() < 0) std.c._exit(1);
        if (ctty_type == .explicit) {
            const name = ctty_name orelse std.c._exit(1);
            const fd = std.c.open(name, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
            if (fd < 0 or std.c.isatty(fd) == 0) std.c._exit(1);
            if (ioctl(fd, tiocsctty, @as(c_int, 0)) < 0) std.c._exit(1);
            if (tcsetpgrp(fd, child_pid) < 0 and std.c._errno().* != @intFromEnum(std.c.E.NOSYS)) {
                std.c._exit(1);
            }
            if (childSetupTty(fd) < 0) std.c._exit(1);
            if (channel_in_type == .ctty) in_fd = fd;
            if (channel_out_type == .ctty) out_fd = fd;
            if (channel_err_type == .ctty) err_fd = fd;
        }
    }

    if (in_fd >= 0 and in_fd != std.c.STDIN_FILENO) {
        if (out_fd == std.c.STDIN_FILENO) {
            out_fd = std.c.dup(out_fd);
            if (out_fd < 0) std.c._exit(1);
        }
        if (err_fd == std.c.STDIN_FILENO) {
            err_fd = std.c.dup(err_fd);
            if (err_fd < 0) std.c._exit(1);
        }
        if (std.c.dup2(in_fd, std.c.STDIN_FILENO) < 0) std.c._exit(1);
    }
    if (out_fd >= 0 and out_fd != std.c.STDOUT_FILENO) {
        if (err_fd == std.c.STDOUT_FILENO) {
            err_fd = std.c.dup(err_fd);
            if (err_fd < 0) std.c._exit(1);
        }
        if (std.c.dup2(out_fd, std.c.STDOUT_FILENO) < 0) std.c._exit(1);
    }
    if (err_fd >= 0 and err_fd != std.c.STDERR_FILENO) {
        if (std.c.dup2(err_fd, std.c.STDERR_FILENO) < 0) std.c._exit(1);
    }

    if (channel_in_type == .none) _ = std.c.close(std.c.STDIN_FILENO);
    if (channel_out_type == .none) _ = std.c.close(std.c.STDOUT_FILENO);
    if (channel_err_type == .none) _ = std.c.close(std.c.STDERR_FILENO);
    _ = ux.uxClosefrom(3);

    abi.UX_initialize_child_signals();
    _ = std.c.execve(filename, @ptrCast(argv), envp);
    std.c._exit(1);
}

/// Fork and launch a subprocess with configured ctty, stdio redirections, and job control.
pub fn osMakeSubprocess(
    filename: [*:0]const u8,
    argv: [*]const ?[*:0]const u8,
    envp: ?[*]const ?[*:0]const u8,
    working_directory: ?[*:0]const u8,
    ctty_type: abi.ProcessCttyType,
    ctty_name: ?[*:0]u8,
    channel_in_type: abi.ProcessChannelType,
    channel_in: abi.Tchannel,
    channel_out_type: abi.ProcessChannelType,
    channel_out: abi.Tchannel,
    channel_err_type: abi.ProcessChannelType,
    channel_err: abi.Tchannel,
) callconv(.c) abi.Tprocess {
    const resolved_envp: [*:null]const ?[*:0]const u8 = if (envp) |e| @ptrCast(e) else @ptrCast(std.c.environ);
    const child_jc_status: abi.ProcessJcStatus = switch (ctty_type) {
        .none => .no_ctty,
        .explicit => .unrelated,
        .inherit_bg, .inherit_fg => scheme_jc_status,
    };

    transact.transaction_begin();
    const child = processAllocate();
    grabSignalMask();
    if (ctty_type == .inherit_fg) {
        blockJcSignals();
    } else {
        blockSigchld();
    }

    var child_pid = fork();
    while (child_pid < 0) {
        abi.UX_prim_check_errno(abi.syscall_vfork);
        child_pid = fork();
    }

    if (child_pid > 0) {
        const entry = &process_table_ptr.?[child];
        entry.id = child_pid;
        entry.jc_status = child_jc_status;
        entry.raw_status = .running;
        entry.raw_reason = 0;
        entry.tick = process_tick;
        syncProcessEntry(child);

        if (child_jc_status == .jc) {
            _ = std.c.setpgid(child_pid, child_pid);
        }
        if (ctty_type == .inherit_fg) {
            giveTerminalTo(child);
            processWait(child);
        }
        transact.transaction_commit();
        return child;
    }

    execChildProcess(
        filename,
        argv,
        resolved_envp,
        working_directory,
        ctty_type,
        ctty_name,
        child_jc_status,
        channel_in_type,
        channel_in,
        channel_out_type,
        channel_out,
        channel_err_type,
        channel_err,
    );
}

/// Return OS PID of `process`.
pub fn osProcessId(process: abi.Tprocess) callconv(.c) abi.PidT {
    return process_table_ptr.?[process].id;
}

/// Return synchronized `ProcessStatus` of `process`.
pub fn osProcessStatus(process: abi.Tprocess) callconv(.c) abi.ProcessStatus {
    return process_table_ptr.?[process].status;
}

/// Return synchronized termination/stop reason code of `process`.
pub fn osProcessReason(process: abi.Tprocess) callconv(.c) c_ushort {
    return process_table_ptr.?[process].reason;
}

/// Return `ProcessJcStatus` of `process`.
pub fn osProcessJcStatus(process: abi.Tprocess) callconv(.c) abi.ProcessJcStatus {
    return process_table_ptr.?[process].jc_status;
}

/// Return 1 if `process` refers to an active/recorded subprocess entry, 0 otherwise.
pub fn osProcessValidP(process: abi.Tprocess) callconv(.c) c_int {
    if (process >= os_process_table_size) return 0;
    const table = process_table_ptr orelse return 0;
    return switch (table[process].raw_status) {
        .exited, .signalled, .stopped, .running => 1,
        else => 0,
    };
}

/// Return 1 if `process` is currently running or stopped (can be resumed).
pub fn osProcessContinuableP(process: abi.Tprocess) callconv(.c) c_int {
    return switch (process_table_ptr.?[process].raw_status) {
        .stopped, .running => 1,
        else => 0,
    };
}

/// Return 1 if `process` shares Scheme's controlling terminal.
pub fn osProcessForegroundableP(process: abi.Tprocess) callconv(.c) c_int {
    return switch (process_table_ptr.?[process].jc_status) {
        .no_jc, .jc => 1,
        else => 0,
    };
}

/// Synchronize observed status/reason fields of `process`; return 1 if changed.
pub fn osProcessStatusSync(process: abi.Tprocess) callconv(.c) c_int {
    transact.transaction_begin();
    blockSigchld();
    const entry = &process_table_ptr.?[process];
    const changed = entry.tick != entry.sync_tick;
    if (changed) syncProcessEntry(process);
    transact.transaction_commit();
    return @intFromBool(changed);
}

/// Synchronize global process status tick counter; return 1 if any change occurred.
pub fn osProcessStatusSyncAll() callconv(.c) c_int {
    transact.transaction_begin();
    blockSigchld();
    const cur = volatileReadTick(&process_tick);
    const changed = cur != sync_tick;
    if (changed) sync_tick = cur;
    transact.transaction_commit();
    return @intFromBool(changed);
}

/// Return 1 if any subprocess has changed status since the last global sync.
pub fn osProcessAnyStatusChange() callconv(.c) c_int {
    return @intFromBool(volatileReadTick(&process_tick) != volatileReadTick(&sync_tick));
}

fn processSendSignal(process: abi.Tprocess, sig: c_int) void {
    const entry = &process_table_ptr.?[process];
    const target_pid: abi.PidT = if (entry.jc_status == .jc) -entry.id else entry.id;
    while (kill(target_pid, sig) < 0) {
        abi.UX_prim_check_errno(abi.syscall_kill);
    }
}

/// Send POSIX signal `sig` to `process` while holding `SIGCHLD` blocked against PID reuse.
pub fn osProcessSendSignal(process: abi.Tprocess, sig: c_int) callconv(.c) void {
    transact.transaction_begin();
    blockSigchld();
    switch (process_table_ptr.?[process].raw_status) {
        .running, .stopped => processSendSignal(process, sig),
        .exited, .signalled => osscheme.error_process_terminated(),
        else => utils.error_in_system_call(abi.syserr_no_such_process, abi.syscall_kill),
    }
    transact.transaction_commit();
}

/// Send `SIGKILL` to `process`.
pub fn osProcessKill(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, @intFromEnum(std.c.SIG.KILL));
}

/// Send `SIGTSTP` to `process`.
pub fn osProcessStop(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, @intFromEnum(std.c.SIG.TSTP));
}

/// Send `SIGINT` to `process`.
pub fn osProcessInterrupt(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, @intFromEnum(std.c.SIG.INT));
}

/// Send `SIGQUIT` to `process`.
pub fn osProcessQuit(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, @intFromEnum(std.c.SIG.QUIT));
}

/// Send `SIGHUP` to `process`.
pub fn osProcessHangup(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, @intFromEnum(std.c.SIG.HUP));
}

/// Resume stopped `process` in the background via `SIGCONT`.
pub fn osProcessContinueBackground(process: abi.Tprocess) callconv(.c) void {
    transact.transaction_begin();
    blockSigchld();
    if (process_table_ptr.?[process].raw_status == .stopped) {
        newRawStatus(process, .running, 0);
        processSendSignal(process, @intFromEnum(std.c.SIG.CONT));
    }
    transact.transaction_commit();
}

/// Hand controlling terminal to `process`, resume if stopped, and wait synchronously.
pub fn osProcessContinueForeground(process: abi.Tprocess) callconv(.c) void {
    transact.transaction_begin();
    grabSignalMask();
    blockJcSignals();
    giveTerminalTo(process);
    if (process_table_ptr.?[process].raw_status == .stopped) {
        newRawStatus(process, .running, 0);
        processSendSignal(process, @intFromEnum(std.c.SIG.CONT));
    }
    processWait(process);
    transact.transaction_commit();
}

/// Block until `process` stops/exits or a Scheme interrupt becomes pending.
pub fn osProcessWait(process: abi.Tprocess) callconv(.c) void {
    transact.transaction_begin();
    grabSignalMask();
    blockJcSignals();
    processWait(process);
    transact.transaction_commit();
}

fn getTerminalBack1(_: ?*anyopaque) callconv(.c) void {
    getTerminalBack();
}

fn giveTerminalTo(process: abi.Tprocess) void {
    const entry = &process_table_ptr.?[process];
    if (entry.jc_status == .jc and schemeInForeground()) {
        transact.transaction_record_action(.tat_always, &getTerminalBack1, null);
        foreground_child_process = process;
        abi.OS_save_internal_state();
        abi.OS_restore_external_state();
        while (tcsetpgrp(scheme_ctty_fd, entry.id) < 0) {
            const err = std.c._errno().*;
            if (err == @intFromEnum(std.c.E.NOSYS)) break;
            if (err != @intFromEnum(std.c.E.INTR)) {
                utils.error_system_call(err, abi.syscall_tcsetpgrp);
            }
        }
    }
}

fn getTerminalBack() void {
    if (foreground_child_process != abi.no_process) {
        while (tcsetpgrp(scheme_ctty_fd, getpgrp()) < 0) {
            if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) break;
        }
        abi.OS_save_external_state();
        abi.OS_restore_internal_state();
        foreground_child_process = abi.no_process;
    }
}

fn processWait(process: abi.Tprocess) void {
    while (volatileReadRawStatus(process) == .running and osscheme.pending_interrupts_p() == 0) {
        _ = sigsuspend(&grabbed_signal_mask);
    }
}

fn findProcess(pid: abi.PidT) abi.Tprocess {
    const table = process_table_ptr orelse return abi.no_process;
    var p: abi.Tprocess = 0;
    while (p < os_process_table_size) : (p += 1) {
        if (table[p].id == pid) return p;
    }
    return abi.no_process;
}

/// Record exit/stop/signal status from `waitpid` into `process_table` (`subprocess_death_hook`).
pub fn subprocessDeath(pid: abi.PidT, status: *c_int) callconv(.c) void {
    const p = findProcess(pid);
    if (p == abi.no_process) return;
    const raw: u32 = @bitCast(status.*);
    if (std.c.W.IFEXITED(raw)) {
        newRawStatus(p, .exited, std.c.W.EXITSTATUS(raw));
    } else if (std.c.W.IFSTOPPED(raw)) {
        newRawStatus(p, .stopped, @intCast(@intFromEnum(std.c.W.STOPSIG(raw))));
    } else if (std.c.W.IFSIGNALED(raw)) {
        newRawStatus(p, .signalled, @intCast(@intFromEnum(std.c.W.TERMSIG(raw))));
    }
}

fn stopSignalHandler(signo: c_int) callconv(.c) void {
    getTerminalBack();
    abi.stop_signal_default(signo);
}

comptime {
    if (!builtin.is_test) {
        @export(&os_process_table_size, .{ .name = "OS_process_table_size" });
        @export(&process_table_ptr, .{ .name = "process_table" });
        @export(&scheme_jc_status, .{ .name = "scheme_jc_status" });
        @export(&uxInitializeProcesses, .{ .name = "UX_initialize_processes" });
        @export(&uxResetProcesses, .{ .name = "UX_reset_processes" });
        @export(&osProcessDeallocate, .{ .name = "OS_process_deallocate" });
        @export(&osMakeSubprocess, .{ .name = "OS_make_subprocess" });
        @export(&osProcessId, .{ .name = "OS_process_id" });
        @export(&osProcessStatus, .{ .name = "OS_process_status" });
        @export(&osProcessReason, .{ .name = "OS_process_reason" });
        @export(&osProcessJcStatus, .{ .name = "OS_process_jc_status" });
        @export(&osProcessValidP, .{ .name = "OS_process_valid_p" });
        @export(&osProcessContinuableP, .{ .name = "OS_process_continuable_p" });
        @export(&osProcessForegroundableP, .{ .name = "OS_process_foregroundable_p" });
        @export(&osProcessStatusSync, .{ .name = "OS_process_status_sync" });
        @export(&osProcessStatusSyncAll, .{ .name = "OS_process_status_sync_all" });
        @export(&osProcessAnyStatusChange, .{ .name = "OS_process_any_status_change" });
        @export(&osProcessSendSignal, .{ .name = "OS_process_send_signal" });
        @export(&osProcessKill, .{ .name = "OS_process_kill" });
        @export(&osProcessStop, .{ .name = "OS_process_stop" });
        @export(&osProcessInterrupt, .{ .name = "OS_process_interrupt" });
        @export(&osProcessQuit, .{ .name = "OS_process_quit" });
        @export(&osProcessHangup, .{ .name = "OS_process_hangup" });
        @export(&osProcessContinueBackground, .{ .name = "OS_process_continue_background" });
        @export(&osProcessContinueForeground, .{ .name = "OS_process_continue_foreground" });
        @export(&osProcessWait, .{ .name = "OS_process_wait" });
    }
}

test "uxproc initialize subprocess waitpid death sync and deallocate" {
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    uxInitializeProcesses();
    defer {
        uxResetProcesses();
        transact.transaction_initialize();
        wind.dstack_reset();
    }

    try std.testing.expect(abi.subprocess_death_hook != null);
    try std.testing.expect(abi.stop_signal_hook != null);
    try std.testing.expectEqual(@as(c_int, 0), osProcessValidP(0));
    try std.testing.expectEqual(@as(c_int, 0), osProcessValidP(999));
    try std.testing.expectEqual(@as(c_int, 0), osProcessAnyStatusChange());

    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", "exit 7", null };
    const proc = osMakeSubprocess("/bin/sh", &argv, null, null, .none, null, .none, 0, .none, 0, .none, 0);
    try std.testing.expectEqual(@as(c_int, 1), osProcessValidP(proc));
    try std.testing.expectEqual(@as(c_int, 1), osProcessContinuableP(proc));
    try std.testing.expectEqual(@as(c_int, 0), osProcessForegroundableP(proc));
    try std.testing.expectEqual(abi.ProcessStatus.running, osProcessStatus(proc));

    const pid = osProcessId(proc);
    try std.testing.expect(pid > 0);

    var st: c_int = 0;
    const reaped = std.c.waitpid(pid, &st, 0);
    try std.testing.expectEqual(pid, reaped);

    subprocessDeath(pid, &st);
    try std.testing.expectEqual(@as(c_int, 1), osProcessAnyStatusChange());
    try std.testing.expectEqual(@as(c_int, 1), osProcessStatusSync(proc));
    try std.testing.expectEqual(abi.ProcessStatus.exited, osProcessStatus(proc));
    try std.testing.expectEqual(@as(c_ushort, 7), osProcessReason(proc));
    try std.testing.expectEqual(@as(c_int, 1), osProcessStatusSyncAll());
    try std.testing.expectEqual(@as(c_int, 0), osProcessAnyStatusChange());

    osProcessDeallocate(proc);
    try std.testing.expectEqual(@as(c_int, 0), osProcessValidP(proc));
}
