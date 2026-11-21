// Derived from MIT/GNU Scheme C sources (`src/microcode/uxproc.c`)
// and Win32 Process APIs:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const osscheme = @import("osscheme.zig");
const utils = @import("utils.zig");
const win = @import("win_api.zig");
const win_io = @import("win_io.zig");

const WinProcess = struct {
    handle: ?win.HANDLE = null,
    id: abi.PidT = 0,
    tick: isize = 0,
    sync_tick: isize = 0,
    raw_reason: c_ushort = 0,
    reason: c_ushort = 0,
    raw_status: abi.ProcessStatus = .free,
    status: abi.ProcessStatus = .free,
    jc_status: abi.ProcessJcStatus = .no_ctty,
};

pub const max_win_processes: usize = 64;
pub var os_process_table_size: abi.Tprocess = max_win_processes;
var process_table: [max_win_processes]WinProcess = @splat(.{});
var global_tick: isize = 0;
var global_sync_tick: isize = 0;

pub fn initProcesses() void {
    for (&process_table) |*entry| entry.* = .{};
    global_tick = 0;
    global_sync_tick = 0;
}

pub fn resetProcesses() void {
    for (&process_table) |*entry| {
        if (entry.handle) |h| {
            _ = win.kernel32.CloseHandle(h);
        }
        entry.* = .{};
    }
}

fn pollEntry(entry: *WinProcess) void {
    if (entry.raw_status != .running) return;
    const h = entry.handle orelse return;
    if (win.kernel32.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0) {
        var exit_code: win.DWORD = 0;
        if (win.kernel32.GetExitCodeProcess(h, &exit_code) != 0 and exit_code != win.STILL_ACTIVE) {
            entry.raw_status = .exited;
            entry.raw_reason = @truncate(exit_code);
            global_tick += 1;
            entry.tick = global_tick;
        }
    }
}

pub fn osProcessAnyStatusChange() callconv(.c) c_int {
    for (&process_table) |*entry| {
        pollEntry(entry);
    }
    return @intFromBool(global_tick != global_sync_tick);
}

fn duplicateInheritableStdHandle(
    ch_type: abi.ProcessChannelType,
    ch: abi.Tchannel,
    std_id: win.DWORD,
    for_write: bool,
) ?win.HANDLE {
    var src_h: ?win.HANDLE = null;
    var sa_inherit = win.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };
    switch (ch_type) {
        .explicit => {
            if (win_io.getOpenChannel(ch)) |entry| {
                if (!entry.is_socket and entry.handle != win.INVALID_HANDLE_VALUE) {
                    src_h = entry.handle;
                }
            }
        },
        .inherit => {
            src_h = win.kernel32.GetStdHandle(std_id);
        },
        .none, .ctty => {},
    }
    if (src_h == null or src_h.? == win.INVALID_HANDLE_VALUE) {
        const access = if (for_write) win.GENERIC_WRITE else win.GENERIC_READ;
        const nul = win.kernel32.CreateFileA(
            "NUL",
            access,
            win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
            &sa_inherit,
            win.OPEN_EXISTING,
            win.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (nul == win.INVALID_HANDLE_VALUE) return null;
        return nul;
    }

    var dup: win.HANDLE = win.INVALID_HANDLE_VALUE;
    const cur = win.kernel32.GetCurrentProcess();
    if (win.kernel32.DuplicateHandle(cur, src_h.?, cur, &dup, 0, 1, win.DUPLICATE_SAME_ACCESS) == 0) {
        return null;
    }
    return dup;
}

pub fn osMakeSubprocess(
    filename: [*:0]const u8,
    argv: [*]const ?[*:0]const u8,
    envp: ?[*]const ?[*:0]const u8,
    working_directory: ?[*:0]const u8,
    _: abi.ProcessCttyType,
    _: ?[*:0]u8,
    channel_in_type: abi.ProcessChannelType,
    channel_in: abi.Tchannel,
    channel_out_type: abi.ProcessChannelType,
    channel_out: abi.Tchannel,
    channel_err_type: abi.ProcessChannelType,
    channel_err: abi.Tchannel,
) callconv(.c) abi.Tprocess {
    var slot_idx: ?abi.Tprocess = null;
    for (&process_table, 0..) |*entry, i| {
        if (entry.raw_status == .free) {
            slot_idx = @intCast(i);
            break;
        }
    }
    const slot = slot_idx orelse osscheme.error_out_of_processes();

    const alloc = std.heap.c_allocator;
    var cmdline: std.ArrayList(u8) = .empty;
    defer cmdline.deinit(alloc);

    var i: usize = 0;
    while (argv[i]) |arg_z| : (i += 1) {
        if (i > 0) cmdline.append(alloc, ' ') catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
        const s = if (i == 0) std.mem.span(filename) else std.mem.span(arg_z);
        win.appendQuotedWindowsArg(&cmdline, alloc, s) catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
    }
    if (i == 0) {
        win.appendQuotedWindowsArg(&cmdline, alloc, std.mem.span(filename)) catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
    }
    cmdline.append(alloc, 0) catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);

    var env_block: std.ArrayList(u8) = .empty;
    defer env_block.deinit(alloc);
    var env_ptr: ?*anyopaque = null;
    if (envp) |ep| {
        var j: usize = 0;
        while (ep[j]) |kv| : (j += 1) {
            env_block.appendSlice(alloc, std.mem.span(kv)) catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
            env_block.append(alloc, 0) catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
        }
        env_block.append(alloc, 0) catch utils.error_system_call(@intFromEnum(std.c.E.NOMEM), abi.syscall_malloc);
        env_ptr = @ptrCast(env_block.items.ptr);
    }

    const h_in = duplicateInheritableStdHandle(channel_in_type, channel_in, win.STD_INPUT_HANDLE, false);
    defer if (h_in) |h| {
        _ = win.kernel32.CloseHandle(h);
    };
    const h_out = duplicateInheritableStdHandle(channel_out_type, channel_out, win.STD_OUTPUT_HANDLE, true);
    defer if (h_out) |h| {
        _ = win.kernel32.CloseHandle(h);
    };
    const h_err = duplicateInheritableStdHandle(channel_err_type, channel_err, win.STD_ERROR_HANDLE, true);
    defer if (h_err) |h| {
        _ = win.kernel32.CloseHandle(h);
    };

    var si = std.mem.zeroes(win.STARTUPINFOA);
    si.cb = @sizeOf(win.STARTUPINFOA);
    si.dwFlags = win.STARTF_USESTDHANDLES;
    si.hStdInput = h_in;
    si.hStdOutput = h_out;
    si.hStdError = h_err;

    var pi = std.mem.zeroes(win.PROCESS_INFORMATION);
    const fname_slice = std.mem.span(filename);
    const has_dir_sep = std.mem.indexOfAny(u8, fname_slice, "/\\:") != null;
    const app_name: ?[*:0]const u8 = if (has_dir_sep) filename else null;

    if (win.kernel32.CreateProcessA(
        app_name,
        @ptrCast(cmdline.items.ptr),
        null,
        null,
        1,
        win.CREATE_NEW_PROCESS_GROUP,
        env_ptr,
        working_directory,
        &si,
        &pi,
    ) == 0) {
        win_io.failWin32(abi.syscall_vfork);
    }
    if (pi.hThread) |ht| _ = win.kernel32.CloseHandle(ht);

    global_tick += 1;
    process_table[slot] = .{
        .handle = pi.hProcess,
        .id = pi.dwProcessId,
        .tick = global_tick,
        .sync_tick = global_tick,
        .raw_reason = 0,
        .reason = 0,
        .raw_status = .running,
        .status = .running,
        .jc_status = .no_ctty,
    };
    return slot;
}

pub fn osProcessDeallocate(process: abi.Tprocess) callconv(.c) void {
    const entry = &process_table[process];
    if (entry.handle) |h| {
        _ = win.kernel32.CloseHandle(h);
    }
    entry.* = .{};
}

pub fn osProcessValidP(process: abi.Tprocess) callconv(.c) c_int {
    if (process >= os_process_table_size) return 0;
    return switch (process_table[process].raw_status) {
        .exited, .signalled, .stopped, .running => 1,
        else => 0,
    };
}

pub fn osProcessContinuableP(_: abi.Tprocess) callconv(.c) c_int {
    return 0;
}

pub fn osProcessForegroundableP(_: abi.Tprocess) callconv(.c) c_int {
    return 0;
}

pub fn osProcessId(process: abi.Tprocess) callconv(.c) abi.PidT {
    return process_table[process].id;
}

pub fn osProcessJcStatus(process: abi.Tprocess) callconv(.c) abi.ProcessJcStatus {
    return process_table[process].jc_status;
}

pub fn osProcessStatusSync(process: abi.Tprocess) callconv(.c) c_int {
    const entry = &process_table[process];
    pollEntry(entry);
    const changed = entry.tick != entry.sync_tick;
    if (changed) {
        entry.status = entry.raw_status;
        entry.reason = entry.raw_reason;
        entry.sync_tick = entry.tick;
    }
    return @intFromBool(changed);
}

pub fn osProcessStatusSyncAll() callconv(.c) c_int {
    _ = osProcessAnyStatusChange();
    const changed = global_tick != global_sync_tick;
    if (changed) global_sync_tick = global_tick;
    return @intFromBool(changed);
}

pub fn osProcessStatus(process: abi.Tprocess) callconv(.c) abi.ProcessStatus {
    return process_table[process].status;
}

pub fn osProcessReason(process: abi.Tprocess) callconv(.c) c_ushort {
    return process_table[process].reason;
}

pub fn osProcessSendSignal(process: abi.Tprocess, sig: c_int) callconv(.c) void {
    const entry = &process_table[process];
    pollEntry(entry);
    switch (entry.raw_status) {
        .running, .stopped => {
            if (sig == 2) { // SIGINT -> Ctrl-Break to process group
                if (win.kernel32.GenerateConsoleCtrlEvent(win.CTRL_BREAK_EVENT, entry.id) != 0) return;
            }
            const h = entry.handle orelse osscheme.error_process_terminated();
            if (win.kernel32.TerminateProcess(h, 1) == 0) {
                win_io.failWin32(abi.syscall_kill);
            }
            entry.raw_status = .signalled;
            entry.raw_reason = @intCast(@min(@as(c_uint, @bitCast(sig)), std.math.maxInt(c_ushort)));
            global_tick += 1;
            entry.tick = global_tick;
        },
        .exited, .signalled => osscheme.error_process_terminated(),
        else => utils.error_in_system_call(abi.syserr_no_such_process, abi.syscall_kill),
    }
}

pub fn osProcessKill(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, 9);
}

pub fn osProcessStop(_: abi.Tprocess) callconv(.c) void {}

pub fn osProcessInterrupt(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, 2);
}

pub fn osProcessQuit(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, 3);
}

pub fn osProcessHangup(process: abi.Tprocess) callconv(.c) void {
    osProcessSendSignal(process, 1);
}

pub fn osProcessContinueBackground(_: abi.Tprocess) callconv(.c) void {}

pub fn osProcessContinueForeground(_: abi.Tprocess) callconv(.c) void {}

pub fn osProcessWait(process: abi.Tprocess) callconv(.c) void {
    const entry = &process_table[process];
    while (entry.raw_status == .running and osscheme.pending_interrupts_p() == 0) {
        const h = entry.handle orelse break;
        _ = win.kernel32.WaitForSingleObject(h, 50);
        pollEntry(entry);
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&os_process_table_size, .{ .name = "OS_process_table_size" });
        @export(&osMakeSubprocess, .{ .name = "OS_make_subprocess" });
        @export(&osProcessDeallocate, .{ .name = "OS_process_deallocate" });
        @export(&osProcessValidP, .{ .name = "OS_process_valid_p" });
        @export(&osProcessContinuableP, .{ .name = "OS_process_continuable_p" });
        @export(&osProcessForegroundableP, .{ .name = "OS_process_foregroundable_p" });
        @export(&osProcessId, .{ .name = "OS_process_id" });
        @export(&osProcessJcStatus, .{ .name = "OS_process_jc_status" });
        @export(&osProcessStatusSync, .{ .name = "OS_process_status_sync" });
        @export(&osProcessStatusSyncAll, .{ .name = "OS_process_status_sync_all" });
        @export(&osProcessStatus, .{ .name = "OS_process_status" });
        @export(&osProcessReason, .{ .name = "OS_process_reason" });
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
