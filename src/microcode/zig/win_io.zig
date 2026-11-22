// Derived from MIT/GNU Scheme C sources (`src/microcode/uxio.c`, `uxfile.c`)
// and Win32 Console / File / Socket I/O:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const fasload = @import("fasload.zig");
const osscheme = @import("osscheme.zig");
const transact = @import("transact.zig");
const utils = @import("utils.zig");
const wind = @import("wind.zig");
const win = @import("win_api.zig");
const win_proc = @import("win_proc.zig");

pub const WinChannel = struct {
    open: bool = false,
    is_socket: bool = false,
    nonblocking: bool = false,
    internal: bool = false,
    append: bool = false,
    ch_type: abi.ChannelType = .unknown,
    handle: win.HANDLE = win.INVALID_HANDLE_VALUE,
    sock: win.SOCKET = win.INVALID_SOCKET,
};

pub const max_win_channels: usize = 1024;
pub var os_channel_table_size: abi.Tchannel = max_win_channels;
pub var win_channels: [max_win_channels]WinChannel = @splat(.{});
pub const os_have_select_p: c_int = 1;

pub fn failWin32(syscall_id: c_int) noreturn {
    utils.error_system_call(win.win32ErrorToErrno(win.kernel32.GetLastError()), syscall_id);
}

pub fn failWsa(syscall_id: c_int) noreturn {
    const err = win.ws2_32.WSAGetLastError();
    utils.error_system_call(win.win32ErrorToErrno(@bitCast(err)), syscall_id);
}

fn closeAllChannelsCleanup() callconv(.c) void {
    for (0..os_channel_table_size) |i_u| {
        const i: abi.Tchannel = @intCast(i_u);
        if (win_channels[i].open) {
            osChannelCloseNoerror(i);
        }
    }
}

pub fn initChannels() void {
    for (&win_channels) |*ch| {
        ch.* = .{};
    }
    fasload.add_reload_cleanup(&closeAllChannelsCleanup);
}

pub fn resetChannels() void {
    closeAllChannelsCleanup();
}

fn allocateSlot() abi.Tchannel {
    for (&win_channels, 0..) |*slot, i| {
        if (!slot.open) {
            slot.* = .{};
            return @intCast(i);
        }
    }
    osscheme.error_out_of_channels();
}

pub fn allocateHandleChannel(h: win.HANDLE, ch_type: abi.ChannelType, internal: bool, append: bool) abi.Tchannel {
    const ch = allocateSlot();
    win_channels[ch] = .{
        .open = true,
        .is_socket = false,
        .nonblocking = false,
        .internal = internal,
        .append = append,
        .ch_type = ch_type,
        .handle = h,
        .sock = win.INVALID_SOCKET,
    };
    return ch;
}

pub fn allocateSocketChannel(s: win.SOCKET, ch_type: abi.ChannelType) abi.Tchannel {
    const ch = allocateSlot();
    win_channels[ch] = .{
        .open = true,
        .is_socket = true,
        .nonblocking = false,
        .internal = false,
        .append = false,
        .ch_type = ch_type,
        .handle = win.INVALID_HANDLE_VALUE,
        .sock = s,
    };
    return ch;
}

pub fn getOpenChannel(ch: abi.Tchannel) ?*WinChannel {
    if (ch >= os_channel_table_size) return null;
    if (!win_channels[ch].open) return null;
    return &win_channels[ch];
}

pub fn getChannelByDesc(desc: c_int) ?*WinChannel {
    if (desc < 0 or desc >= @as(c_int, @intCast(os_channel_table_size))) return null;
    return getOpenChannel(@intCast(desc));
}

pub fn uxChannelDescriptor(ch: abi.Tchannel) callconv(.c) c_int {
    // CRITICAL: Return channel slot index (0..1023), never a truncated 64-bit HANDLE/SOCKET.
    return @intCast(ch);
}

pub fn osChannelOpenP(ch: abi.Tchannel) callconv(.c) c_int {
    return @intFromBool(getOpenChannel(ch) != null);
}

pub fn osChannelClose(ch: abi.Tchannel) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse return;
    if (entry.internal) return;
    if (entry.is_socket) {
        const s = entry.sock;
        entry.* = .{};
        if (s != win.INVALID_SOCKET and win.ws2_32.closesocket(s) == win.SOCKET_ERROR) {
            failWsa(abi.syscall_close);
        }
    } else {
        const h = entry.handle;
        entry.* = .{};
        if (h != win.INVALID_HANDLE_VALUE and win.kernel32.CloseHandle(h) == 0) {
            failWin32(abi.syscall_close);
        }
    }
}

pub fn osChannelCloseNoerror(ch: abi.Tchannel) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse return;
    if (entry.internal) return;
    if (entry.is_socket) {
        const s = entry.sock;
        entry.* = .{};
        if (s != win.INVALID_SOCKET) _ = win.ws2_32.closesocket(s);
    } else {
        const h = entry.handle;
        entry.* = .{};
        if (h != win.INVALID_HANDLE_VALUE) _ = win.kernel32.CloseHandle(h);
    }
}

fn channelCloseOnAbort1(cp: ?*anyopaque) callconv(.c) void {
    const p: *const abi.Tchannel = @ptrCast(@alignCast(cp.?));
    osChannelClose(p.*);
}

pub fn osChannelCloseOnAbort(ch: abi.Tchannel) callconv(.c) void {
    const cp: *abi.Tchannel = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(abi.Tchannel)).?));
    cp.* = ch;
    transact.transaction_record_action(.tat_abort, &channelCloseOnAbort1, @ptrCast(cp));
}

pub fn osChannelSynchronize(ch: abi.Tchannel) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse return;
    if (entry.is_socket or entry.handle == win.INVALID_HANDLE_VALUE) return;
    if (win.kernel32.FlushFileBuffers(entry.handle) == 0) {
        const err = win.kernel32.GetLastError();
        // Pipes/consoles/read-only handles legitimately reject FlushFileBuffers.
        if (err != 1 and err != 5 and err != 6 and err != 109) {
            utils.error_system_call(win.win32ErrorToErrno(err), abi.syscall_fsync);
        }
    }
}

pub fn osChannelType(ch: abi.Tchannel) callconv(.c) abi.ChannelType {
    const entry = getOpenChannel(ch) orelse return .unknown;
    return entry.ch_type;
}

pub fn osChannelRead(ch: abi.Tchannel, buffer: ?*anyopaque, nbytes: usize) callconv(.c) isize {
    if (nbytes == 0) return 0;
    const entry = getOpenChannel(ch) orelse return -1;
    const dst: [*]u8 = @ptrCast(buffer.?);

    if (entry.is_socket) {
        const chunk: c_int = @intCast(@min(nbytes, @as(usize, std.math.maxInt(c_int))));
        const n = win.ws2_32.recv(entry.sock, dst, chunk, 0);
        if (n == win.SOCKET_ERROR) {
            const err = win.ws2_32.WSAGetLastError();
            if (err == 10035) return -1; // WSAEWOULDBLOCK
            if (err == 10054) return 0; // peer reset -> EOF
            utils.error_system_call(win.win32ErrorToErrno(@bitCast(err)), abi.syscall_read);
        }
        return @intCast(n);
    }

    if (entry.handle == win.INVALID_HANDLE_VALUE) return 0;
    if (entry.nonblocking) {
        switch (entry.ch_type) {
            .win32_anonymous_pipe, .win32_named_pipe, .unix_pipe => {
                var avail: win.DWORD = 0;
                if (win.kernel32.PeekNamedPipe(entry.handle, null, 0, null, &avail, null) == 0) {
                    const err = win.kernel32.GetLastError();
                    if (err == 109 or err == 232) return 0; // ERROR_BROKEN_PIPE / NO_DATA -> EOF
                    utils.error_system_call(win.win32ErrorToErrno(err), abi.syscall_read);
                }
                if (avail == 0) return -1;
            },
            .terminal => {
                var events: win.DWORD = 0;
                if (win.kernel32.GetNumberOfConsoleInputEvents(entry.handle, &events) != 0 and events == 0) {
                    return -1;
                }
            },
            else => {},
        }
    }

    const chunk: win.DWORD = @intCast(@min(nbytes, @as(usize, std.math.maxInt(c_int))));
    var nread: win.DWORD = 0;
    if (win.kernel32.ReadFile(entry.handle, dst, chunk, &nread, null) == 0) {
        const err = win.kernel32.GetLastError();
        if (err == 109 or err == 38 or err == 232) return 0; // BROKEN_PIPE / HANDLE_EOF -> EOF
        utils.error_system_call(win.win32ErrorToErrno(err), abi.syscall_read);
    }
    return @intCast(nread);
}

pub fn osChannelWrite(ch: abi.Tchannel, buffer: ?*const anyopaque, nbytes: usize) callconv(.c) isize {
    if (nbytes == 0) return 0;
    const entry = getOpenChannel(ch) orelse return -1;
    const src: [*]const u8 = @ptrCast(buffer.?);

    if (entry.is_socket) {
        const chunk: c_int = @intCast(@min(nbytes, @as(usize, std.math.maxInt(c_int))));
        const n = win.ws2_32.send(entry.sock, src, chunk, 0);
        if (n == win.SOCKET_ERROR) {
            const err = win.ws2_32.WSAGetLastError();
            if (err == 10035) return -1; // WSAEWOULDBLOCK
            utils.error_system_call(win.win32ErrorToErrno(@bitCast(err)), abi.syscall_write);
        }
        return if (n > 0) @intCast(n) else -1;
    }

    if (entry.handle == win.INVALID_HANDLE_VALUE) return @intCast(nbytes);
    if (entry.append) {
        _ = win.kernel32.SetFilePointerEx(entry.handle, 0, null, win.FILE_END);
    }
    const chunk: win.DWORD = @intCast(@min(nbytes, @as(usize, std.math.maxInt(c_int))));
    var nwritten: win.DWORD = 0;
    if (win.kernel32.WriteFile(entry.handle, src, chunk, &nwritten, null) == 0) {
        failWin32(abi.syscall_write);
    }
    return if (nwritten > 0) @intCast(nwritten) else -1;
}

pub fn osMakePipe(readerp: *abi.Tchannel, writerp: *abi.Tchannel) callconv(.c) void {
    transact.transaction_begin();
    var h_read: win.HANDLE = undefined;
    var h_write: win.HANDLE = undefined;
    var sa = win.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 0,
    };
    if (win.kernel32.CreatePipe(&h_read, &h_write, &sa, 0) == 0) {
        failWin32(abi.syscall_pipe);
    }
    readerp.* = allocateHandleChannel(h_read, .win32_anonymous_pipe, false, false);
    osChannelCloseOnAbort(readerp.*);
    writerp.* = allocateHandleChannel(h_write, .win32_anonymous_pipe, false, false);
    transact.transaction_commit();
}

pub fn osChannelNonblockingP(ch: abi.Tchannel) callconv(.c) c_int {
    const entry = getOpenChannel(ch) orelse return 0;
    return @intFromBool(entry.nonblocking);
}

pub fn osChannelNonblocking(ch: abi.Tchannel) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse return;
    if (entry.is_socket) {
        var nb: c_ulong = 1;
        if (win.ws2_32.ioctlsocket(entry.sock, win.FIONBIO, &nb) == win.SOCKET_ERROR) {
            failWsa(abi.syscall_fcntl_SETFL);
        }
    }
    entry.nonblocking = true;
}

pub fn osChannelBlocking(ch: abi.Tchannel) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse return;
    if (entry.is_socket) {
        var nb: c_ulong = 0;
        if (win.ws2_32.ioctlsocket(entry.sock, win.FIONBIO, &nb) == win.SOCKET_ERROR) {
            failWsa(abi.syscall_fcntl_SETFL);
        }
    }
    entry.nonblocking = false;
}

const SelectEntry = extern struct {
    desc: c_int,
    req_mode: c_uint,
    ready_mode: c_uint,
};

const WinSelectRegistry = extern struct {
    capacity: c_uint,
    length: c_uint,
    entries: [*]SelectEntry,
};

const min_sr_capacity: c_uint = 8;

pub fn osAllocateSelectRegistry() callconv(.c) abi.SelectRegistry {
    const r: *WinSelectRegistry = @ptrCast(@alignCast(abi.OS_malloc(@sizeOf(WinSelectRegistry)).?));
    const entries: [*]SelectEntry = @ptrCast(@alignCast(abi.OS_malloc(@sizeOf(SelectEntry) * min_sr_capacity).?));
    r.* = .{
        .capacity = min_sr_capacity,
        .length = 0,
        .entries = entries,
    };
    return @ptrCast(r);
}

pub fn osDeallocateSelectRegistry(registry: abi.SelectRegistry) callconv(.c) void {
    const r: *WinSelectRegistry = @ptrCast(@alignCast(registry orelse return));
    abi.OS_free(@ptrCast(r.entries));
    abi.OS_free(@ptrCast(r));
}

pub fn osAddToSelectRegistry(registry: abi.SelectRegistry, desc: c_int, mode: c_uint) callconv(.c) void {
    const r: *WinSelectRegistry = @ptrCast(@alignCast(registry orelse return));
    for (r.entries[0..r.length]) |*entry| {
        if (entry.desc == desc) {
            entry.req_mode |= mode;
            return;
        }
    }
    if (r.length == r.capacity) {
        const next_cap = r.capacity * 2;
        r.entries = @ptrCast(@alignCast(abi.OS_realloc(@ptrCast(r.entries), @sizeOf(SelectEntry) * next_cap).?));
        r.capacity = next_cap;
    }
    r.entries[r.length] = .{ .desc = desc, .req_mode = mode, .ready_mode = 0 };
    r.length += 1;
}

pub fn osRemoveFromSelectRegistry(registry: abi.SelectRegistry, desc: c_int, mode: c_uint) callconv(.c) void {
    const r: *WinSelectRegistry = @ptrCast(@alignCast(registry orelse return));
    for (0..r.length) |i| {
        if (r.entries[i].desc == desc) {
            r.entries[i].req_mode &= ~mode;
            if (r.entries[i].req_mode == 0) {
                r.length -= 1;
                for (i..r.length) |j| {
                    r.entries[j] = r.entries[j + 1];
                }
            }
            return;
        }
    }
}

pub fn osSelectRegistryLength(registry: abi.SelectRegistry) callconv(.c) c_uint {
    const r: *const WinSelectRegistry = @ptrCast(@alignCast(registry orelse return 0));
    return r.length;
}

pub fn osSelectRegistryResult(registry: abi.SelectRegistry, index: c_uint, fd_r: *c_int, mode_r: *c_uint) callconv(.c) void {
    const r: *const WinSelectRegistry = @ptrCast(@alignCast(registry.?));
    fd_r.* = r.entries[index].desc;
    mode_r.* = r.entries[index].ready_mode;
}

fn probeSocketReady(sock: win.SOCKET, want_mode: c_uint, timeout_ms: c_int) c_uint {
    var events: i16 = 0;
    if ((want_mode & abi.select_mode_read) != 0) events |= win.POLLRDNORM;
    if ((want_mode & abi.select_mode_write) != 0) events |= win.POLLWRNORM;
    var pfd = [_]win.WSAPOLLFD{.{ .fd = sock, .events = events, .revents = 0 }};
    const rc = win.ws2_32.WSAPoll(&pfd, 1, timeout_ms);
    if (rc <= 0) return 0;
    var ready: c_uint = 0;
    if ((pfd[0].revents & win.POLLRDNORM) != 0) ready |= abi.select_mode_read;
    if ((pfd[0].revents & win.POLLWRNORM) != 0) ready |= abi.select_mode_write;
    if ((pfd[0].revents & win.POLLERR) != 0) ready |= abi.select_mode_error;
    if ((pfd[0].revents & win.POLLHUP) != 0) ready |= abi.select_mode_hup;
    return ready;
}

fn probeDescReady(desc: c_int, want_mode: c_uint) c_uint {
    const entry = getChannelByDesc(desc) orelse return abi.select_mode_error;
    if (entry.is_socket) {
        return probeSocketReady(entry.sock, want_mode, 0);
    }
    if (entry.handle == win.INVALID_HANDLE_VALUE) return want_mode;
    switch (entry.ch_type) {
        .win32_anonymous_pipe, .win32_named_pipe, .unix_pipe => {
            var ready: c_uint = 0;
            if ((want_mode & abi.select_mode_read) != 0) {
                var avail: win.DWORD = 0;
                if (win.kernel32.PeekNamedPipe(entry.handle, null, 0, null, &avail, null) == 0) {
                    const err = win.kernel32.GetLastError();
                    if (err == 109 or err == 232) {
                        ready |= abi.select_mode_read | abi.select_mode_hup;
                    } else {
                        ready |= abi.select_mode_error;
                    }
                } else if (avail > 0) {
                    ready |= abi.select_mode_read;
                }
            }
            if ((want_mode & abi.select_mode_write) != 0) {
                ready |= abi.select_mode_write;
            }
            return ready;
        },
        .terminal => {
            var ready: c_uint = 0;
            if ((want_mode & abi.select_mode_read) != 0) {
                if (win.kernel32.WaitForSingleObject(entry.handle, 0) == win.WAIT_OBJECT_0) {
                    ready |= abi.select_mode_read;
                }
            }
            if ((want_mode & abi.select_mode_write) != 0) {
                ready |= abi.select_mode_write;
            }
            return ready;
        },
        else => return want_mode,
    }
}

pub fn osTestSelectRegistry(registry: abi.SelectRegistry, blockp: c_int) callconv(.c) c_int {
    const r: *WinSelectRegistry = @ptrCast(@alignCast(registry orelse return 0));
    while (true) {
        if (win_proc.osProcessAnyStatusChange() != 0) return abi.select_process_status_change;
        if (osscheme.pending_interrupts_p() != 0) return abi.select_interrupt;

        var ready_count: c_int = 0;
        for (r.entries[0..r.length]) |*entry| {
            const ready = probeDescReady(entry.desc, entry.req_mode);
            entry.ready_mode = ready;
            if (ready != 0) ready_count += 1;
        }
        if (ready_count > 0 or blockp == 0) return ready_count;
        win.kernel32.Sleep(10);
    }
}

pub fn osTestSelectDescriptor(desc: c_int, blockp: c_int, mode: c_uint) callconv(.c) c_int {
    while (true) {
        if (win_proc.osProcessAnyStatusChange() != 0) return abi.select_process_status_change;
        if (osscheme.pending_interrupts_p() != 0) return abi.select_interrupt;
        const entry = getChannelByDesc(desc);
        if (entry != null and entry.?.is_socket and blockp != 0) {
            const ready = probeSocketReady(entry.?.sock, mode, 10);
            if (ready != 0) return @intCast(ready);
            continue;
        }
        const ready = probeDescReady(desc, mode);
        if (ready != 0 or blockp == 0) return @intCast(ready);
        win.kernel32.Sleep(10);
    }
}

pub fn osPause(blockp: bool, ignore_status_change: bool) callconv(.c) c_int {
    if (!blockp) {
        if (!ignore_status_change and win_proc.osProcessAnyStatusChange() != 0) {
            return abi.select_process_status_change;
        }
        return abi.select_interrupt;
    }
    while (true) {
        if (!ignore_status_change and win_proc.osProcessAnyStatusChange() != 0) {
            return abi.select_process_status_change;
        }
        if (abi.Registers[abi.regblock_int_code] != 0 or osscheme.pending_interrupts_p() != 0) {
            return abi.select_interrupt;
        }
        win.kernel32.Sleep(10);
    }
}

fn openWinFile(
    filename: [*:0]const u8,
    access: win.DWORD,
    creation: win.DWORD,
    append: bool,
) abi.Tchannel {
    const h = win.kernel32.CreateFileA(
        filename,
        access,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        null,
        creation,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == win.INVALID_HANDLE_VALUE) {
        failWin32(abi.syscall_open);
    }
    if (append) {
        _ = win.kernel32.SetFilePointerEx(h, 0, null, win.FILE_END);
    }
    const ftype = win.kernel32.GetFileType(h);
    const ch_type: abi.ChannelType = switch (ftype) {
        win.FILE_TYPE_CHAR => .terminal,
        win.FILE_TYPE_PIPE => .win32_named_pipe,
        else => .file,
    };
    return allocateHandleChannel(h, ch_type, false, append);
}

pub fn osOpenInputFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openWinFile(filename, win.GENERIC_READ, win.OPEN_EXISTING, false);
}

pub fn osOpenOutputFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openWinFile(filename, win.GENERIC_WRITE, win.CREATE_ALWAYS, false);
}

pub fn osOpenExclusiveOutputFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openWinFile(filename, win.GENERIC_WRITE, win.CREATE_NEW, false);
}

pub fn osOpenIoFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openWinFile(filename, win.GENERIC_READ | win.GENERIC_WRITE, win.OPEN_ALWAYS, false);
}

pub fn osOpenAppendFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openWinFile(filename, win.GENERIC_WRITE, win.OPEN_ALWAYS, true);
}

pub fn osFileLength(ch: abi.Tchannel) callconv(.c) abi.OffT {
    const entry = getOpenChannel(ch) orelse abi.error_bad_range_arg(1);
    var size: i64 = 0;
    if (win.kernel32.GetFileSizeEx(entry.handle, &size) == 0) {
        failWin32(abi.syscall_fstat);
    }
    return size;
}

pub fn osFilePosition(ch: abi.Tchannel) callconv(.c) abi.OffT {
    const entry = getOpenChannel(ch) orelse abi.error_bad_range_arg(1);
    var pos: i64 = 0;
    if (win.kernel32.SetFilePointerEx(entry.handle, 0, &pos, win.FILE_CURRENT) == 0) {
        failWin32(abi.syscall_lseek);
    }
    return pos;
}

pub fn osFileSetPosition(ch: abi.Tchannel, position: abi.OffT) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse abi.error_bad_range_arg(1);
    var new_pos: i64 = 0;
    if (win.kernel32.SetFilePointerEx(entry.handle, position, &new_pos, win.FILE_BEGIN) == 0) {
        failWin32(abi.syscall_lseek);
    }
    if (new_pos != position) {
        abi.error_external_return();
    }
}

pub fn osFileTruncate(ch: abi.Tchannel, length: abi.OffT) callconv(.c) void {
    const entry = getOpenChannel(ch) orelse abi.error_bad_range_arg(1);
    var cur: i64 = 0;
    _ = win.kernel32.SetFilePointerEx(entry.handle, 0, &cur, win.FILE_CURRENT);
    if (win.kernel32.SetFilePointerEx(entry.handle, length, null, win.FILE_BEGIN) == 0) {
        failWin32(abi.syscall_ftruncate);
    }
    if (win.kernel32.SetEndOfFile(entry.handle) == 0) {
        failWin32(abi.syscall_ftruncate);
    }
    if (cur <= length) {
        _ = win.kernel32.SetFilePointerEx(entry.handle, cur, null, win.FILE_BEGIN);
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&os_channel_table_size, .{ .name = "OS_channel_table_size" });
        @export(&os_have_select_p, .{ .name = "OS_have_select_p" });
        @export(&uxChannelDescriptor, .{ .name = "UX_channel_descriptor" });
        @export(&osChannelOpenP, .{ .name = "OS_channel_open_p" });
        @export(&osChannelClose, .{ .name = "OS_channel_close" });
        @export(&osChannelCloseNoerror, .{ .name = "OS_channel_close_noerror" });
        @export(&osChannelCloseOnAbort, .{ .name = "OS_channel_close_on_abort" });
        @export(&osChannelSynchronize, .{ .name = "OS_channel_synchronize" });
        @export(&osChannelType, .{ .name = "OS_channel_type" });
        @export(&osChannelRead, .{ .name = "OS_channel_read" });
        @export(&osChannelWrite, .{ .name = "OS_channel_write" });
        @export(&osMakePipe, .{ .name = "OS_make_pipe" });
        @export(&osChannelNonblockingP, .{ .name = "OS_channel_nonblocking_p" });
        @export(&osChannelNonblocking, .{ .name = "OS_channel_nonblocking" });
        @export(&osChannelBlocking, .{ .name = "OS_channel_blocking" });
        @export(&osAllocateSelectRegistry, .{ .name = "OS_allocate_select_registry" });
        @export(&osDeallocateSelectRegistry, .{ .name = "OS_deallocate_select_registry" });
        @export(&osAddToSelectRegistry, .{ .name = "OS_add_to_select_registry" });
        @export(&osRemoveFromSelectRegistry, .{ .name = "OS_remove_from_select_registry" });
        @export(&osSelectRegistryLength, .{ .name = "OS_select_registry_length" });
        @export(&osSelectRegistryResult, .{ .name = "OS_select_registry_result" });
        @export(&osTestSelectRegistry, .{ .name = "OS_test_select_registry" });
        @export(&osTestSelectDescriptor, .{ .name = "OS_test_select_descriptor" });
        @export(&osPause, .{ .name = "OS_pause" });
        @export(&osOpenInputFile, .{ .name = "OS_open_input_file" });
        @export(&osOpenOutputFile, .{ .name = "OS_open_output_file" });
        @export(&osOpenExclusiveOutputFile, .{ .name = "OS_open_exclusive_output_file" });
        @export(&osOpenIoFile, .{ .name = "OS_open_io_file" });
        @export(&osOpenAppendFile, .{ .name = "OS_open_append_file" });
        @export(&osFileLength, .{ .name = "OS_file_length" });
        @export(&osFilePosition, .{ .name = "OS_file_position" });
        @export(&osFileSetPosition, .{ .name = "OS_file_set_position" });
        @export(&osFileTruncate, .{ .name = "OS_file_truncate" });
    }
}
