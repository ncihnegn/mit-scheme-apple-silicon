// Derived from MIT/GNU Scheme C sources (`src/microcode/uxio.c`, `src/microcode/uxio.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../../core/prim_abi.zig");
const outf = @import("../../support/outf.zig");
const fasload = @import("../../gc/fasload.zig");
const osscheme = @import("../osscheme.zig");
const transact = @import("../../support/transact.zig");
const utils = @import("../../core/utils.zig");
const wind = @import("../../support/wind.zig");
const stubs = if (builtin.is_test) @import("../../core/test_stubs.zig") else struct {};

pub var os_channel_table_size: abi.Tchannel = 0;
pub var channel_table_ptr: ?[*]abi.Channel = null;
pub const os_have_select_p: c_int = 1;

const have_poll: bool = builtin.os.tag == .linux;
const o_nonblock: c_int = if (builtin.os.tag.isDarwin()) 0x0004 else 0x0800;
const f_fullfsync: c_int = 51;
const sync_file_range_flags: c_uint = 1 | 2 | 4;

extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn sigsuspend(mask: *const std.c.sigset_t) c_int;

const FdSet = extern struct {
    fds_bits: [fd_setsize / 32]i32 = @splat(0),
};
const fd_setsize: usize = 1024;

const DarwinSelect = if (!have_poll) struct {
    extern "c" fn select(
        nfds: c_int,
        readfds: ?*FdSet,
        writefds: ?*FdSet,
        exceptfds: ?*FdSet,
        timeout: ?*std.c.timeval,
    ) c_int;
    extern "c" fn pselect(
        nfds: c_int,
        readfds: ?*FdSet,
        writefds: ?*FdSet,
        exceptfds: ?*FdSet,
        timeout: ?*const std.c.timespec,
        sigmask: ?*const std.c.sigset_t,
    ) c_int;
} else struct {};

const LinuxSync = if (have_poll) struct {
    extern "c" fn sync_file_range(fd: c_int, offset: std.c.off_t, nbytes: std.c.off_t, flags: c_uint) c_int;
} else struct {};

fn fdSetBit(fd: c_int, set: *FdSet, val: bool) void {
    if (fd < 0 or fd >= fd_setsize) return;
    const ufd: usize = @intCast(fd);
    const word = ufd >> 5;
    const mask: i32 = @bitCast(@as(u32, 1) << @as(u5, @truncate(ufd)));
    if (val) {
        set.fds_bits[word] |= mask;
    } else {
        set.fds_bits[word] &= ~mask;
    }
}

fn fdIsSet(fd: c_int, set: *const FdSet) bool {
    if (fd < 0 or fd >= fd_setsize) return false;
    const ufd: usize = @intCast(fd);
    const word = ufd >> 5;
    const mask: i32 = @bitCast(@as(u32, 1) << @as(u5, @truncate(ufd)));
    return (set.fds_bits[word] & mask) != 0;
}

fn uxChannelCloseAll() callconv(.c) void {
    for (0..os_channel_table_size) |ch_u| {
        const ch: abi.Tchannel = @intCast(ch_u);
        if (channel_table_ptr.?[ch].descriptor >= 0) {
            osChannelCloseNoerror(ch);
        }
    }
}

/// Allocate and initialize the Unix channel descriptor table (`UX_initialize_channels`).
pub fn uxInitializeChannels() callconv(.c) void {
    const init_size: usize = 64;
    const raw = std.c.malloc(init_size * @sizeOf(abi.Channel)) orelse {
        outf.fatal("\nUnable to allocate channel table.\n", .{});
        outf.flushFatal();
        abi.termination_init_error();
    };
    const table: [*]abi.Channel = @ptrCast(@alignCast(raw));
    for (table[0..init_size]) |*entry| {
        entry.* = .{ .descriptor = -1, .type = .unknown, .flags = .{} };
    }
    channel_table_ptr = table;
    os_channel_table_size = init_size;
    fasload.add_reload_cleanup(&uxChannelCloseAll);
}

/// Free the Unix channel descriptor table on reset/reload (`UX_reset_channels`).
pub fn uxResetChannels() callconv(.c) void {
    if (channel_table_ptr) |table| {
        std.c.free(@ptrCast(table));
    }
    channel_table_ptr = null;
    os_channel_table_size = 0;
}

/// Allocate an unused slot in `channel_table`, growing the table if needed (`channel_allocate`).
pub fn channelAllocate() callconv(.c) abi.Tchannel {
    const table = channel_table_ptr.?;
    var ch: abi.Tchannel = 0;
    while (ch < os_channel_table_size) : (ch += 1) {
        if (table[ch].descriptor < 0) return ch;
    }
    const old_size: usize = os_channel_table_size;
    const new_size: usize = (old_size * 5) / 4;
    const raw = std.c.realloc(@ptrCast(table), new_size * @sizeOf(abi.Channel)) orelse {
        osscheme.error_out_of_channels();
    };
    const new_table: [*]abi.Channel = @ptrCast(@alignCast(raw));
    for (new_table[old_size..new_size]) |*entry| {
        entry.* = .{ .descriptor = -1, .type = .unknown, .flags = .{} };
    }
    channel_table_ptr = new_table;
    os_channel_table_size = @intCast(new_size);
    return @intCast(old_size);
}

/// Return the underlying OS file descriptor for `channel`.
pub fn uxChannelDescriptor(channel: abi.Tchannel) callconv(.c) c_int {
    return channel_table_ptr.?[channel].descriptor;
}

/// Return 1 if `channel` is currently open, 0 otherwise.
pub fn osChannelOpenP(channel: abi.Tchannel) callconv(.c) c_int {
    if (channel >= os_channel_table_size) return 0;
    const table = channel_table_ptr orelse return 0;
    return @intFromBool(table[channel].descriptor >= 0);
}

/// Close `channel` unless marked internal, delivering interrupts or reporting `EBADF`.
pub fn osChannelClose(channel: abi.Tchannel) callconv(.c) void {
    const entry = &channel_table_ptr.?[channel];
    if (entry.flags.internal != 0) return;
    const status = std.c.close(entry.descriptor);
    entry.descriptor = -1;
    if (status < 0) {
        const err = std.c._errno().*;
        if (err == @backingInt(std.c.E.INTR)) {
            osscheme.deliver_pending_interrupts();
        } else if (err == @backingInt(std.c.E.BADF)) {
            utils.error_system_call(err, abi.syscall_close);
        }
    }
}

/// Close `channel` without signaling errors unless marked internal.
pub fn osChannelCloseNoerror(channel: abi.Tchannel) callconv(.c) void {
    const entry = &channel_table_ptr.?[channel];
    if (entry.flags.internal != 0) return;
    _ = std.c.close(entry.descriptor);
    entry.descriptor = -1;
}

fn channelCloseOnAbort1(cp: ?*anyopaque) callconv(.c) void {
    const p: *const abi.Tchannel = @ptrCast(@alignCast(cp.?));
    osChannelClose(p.*);
}

/// Schedule closing `channel` if the active transaction aborts.
pub fn osChannelCloseOnAbort(channel: abi.Tchannel) callconv(.c) void {
    const cp: *abi.Tchannel = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(abi.Tchannel)).?));
    cp.* = channel;
    transact.transaction_record_action(.tat_abort, &channelCloseOnAbort1, @ptrCast(cp));
}

fn fsyncCheckErrno(syscall_name: c_int) bool {
    const err = std.c._errno().*;
    if (err == @backingInt(std.c.E.INTR)) {
        osscheme.deliver_pending_interrupts();
        return false;
    }
    if (err == @backingInt(std.c.E.BADF) or
        err == @backingInt(std.c.E.INVAL) or
        err == @backingInt(std.c.E.NOSYS) or
        err == @backingInt(std.c.E.NOTTY) or
        err == @backingInt(std.c.E.OPNOTSUPP) or
        err == @backingInt(std.c.E.ROFS) or
        err == @backingInt(std.c.E.SPIPE))
    {
        return true;
    }
    if (comptime @hasField(std.c.E, "NOTSUP")) {
        if (err == @backingInt(std.c.E.NOTSUP)) return true;
    }
    if (comptime builtin.os.tag.isDarwin()) {
        // Darwin's <sys/errno.h> defines ENOTSUP=45 (std.c.E.OPNOTSUPP) and POSIX EOPNOTSUPP=102.
        const darwin_eopnotsupp: c_int = 102;
        if (err == darwin_eopnotsupp) return true;
    }
    utils.error_system_call(err, syscall_name);
}

/// Flush modified buffers and metadata for `channel` to permanent storage.
pub fn osChannelSynchronize(channel: abi.Tchannel) callconv(.c) void {
    const fd = channel_table_ptr.?[channel].descriptor;
    if (builtin.os.tag == .linux) {
        while (std.c.fdatasync(fd) < 0) {
            if (fsyncCheckErrno(abi.syscall_fdatasync)) break;
        }
        while (LinuxSync.sync_file_range(fd, 0, 0, sync_file_range_flags) < 0) {
            if (fsyncCheckErrno(abi.syscall_sync_file_range)) break;
        }
    }
    while (fsync(fd) < 0) {
        if (fsyncCheckErrno(abi.syscall_fsync)) break;
    }
    if (builtin.os.tag.isDarwin()) {
        while (std.c.fcntl(fd, f_fullfsync, @as(c_int, 0)) < 0) {
            if (fsyncCheckErrno(abi.syscall_fcntl_FULLFSYNC)) break;
        }
    }
}

/// Return the `ChannelType` of `channel`.
pub fn osChannelType(channel: abi.Tchannel) callconv(.c) abi.ChannelType {
    return channel_table_ptr.?[channel].type;
}

/// Read up to `nbytes` into `buffer`, returning -1 when a nonblocking read would block.
pub fn osChannelRead(channel: abi.Tchannel, buffer: ?*anyopaque, nbytes: usize) callconv(.c) isize {
    if (nbytes == 0) return 0;
    const entry = &channel_table_ptr.?[channel];
    const dst: [*]u8 = @ptrCast(buffer.?);
    while (true) {
        const scr = std.c.read(entry.descriptor, dst, nbytes);
        if (scr < 0) {
            const err = std.c._errno().*;
            if (err == @backingInt(std.c.E.AGAIN)) return -1;
            if (entry.type == .unix_pty_master and err == @backingInt(std.c.E.IO)) return 0;
            abi.UX_prim_check_errno(abi.syscall_read);
            continue;
        }
        if (@as(usize, @intCast(scr)) > nbytes) {
            abi.error_external_return();
        }
        return @intCast(scr);
    }
}

/// Write up to `nbytes` from `buffer`, returning -1 if nonblocking or 0 bytes written.
pub fn osChannelWrite(channel: abi.Tchannel, buffer: ?*const anyopaque, nbytes: usize) callconv(.c) isize {
    if (nbytes == 0) return 0;
    const fd = channel_table_ptr.?[channel].descriptor;
    const src: [*]const u8 = @ptrCast(buffer.?);
    while (true) {
        const scr = std.c.write(fd, src, nbytes);
        if (scr < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.AGAIN)) return -1;
            abi.UX_prim_check_errno(abi.syscall_write);
            continue;
        }
        if (@as(usize, @intCast(scr)) > nbytes) {
            abi.error_external_return();
        }
        return if (scr > 0) @intCast(scr) else -1;
    }
}

/// Single unretried read used during band/FASL loading; returns 0 on error.
pub fn osChannelReadLoadFile(channel: abi.Tchannel, buffer: ?*anyopaque, nbytes: usize) callconv(.c) usize {
    if (nbytes == 0) return 0;
    const fd = channel_table_ptr.?[channel].descriptor;
    const scr = std.c.read(fd, @ptrCast(buffer.?), nbytes);
    return if (scr < 0) 0 else @intCast(scr);
}

/// Single unretried write used during band/FASL dumping; returns 0 on error.
pub fn osChannelWriteDumpFile(channel: abi.Tchannel, buffer: ?*const anyopaque, nbytes: usize) callconv(.c) usize {
    if (nbytes == 0) return 0;
    const fd = channel_table_ptr.?[channel].descriptor;
    const scr = std.c.write(fd, @ptrCast(buffer.?), nbytes);
    return if (scr < 0) 0 else @intCast(scr);
}

/// Write NUL-terminated `string` completely to `channel` or abort via `error_external_return`.
pub fn osChannelWriteString(channel: abi.Tchannel, string: [*:0]const u8) callconv(.c) void {
    const length = std.mem.len(string);
    if (osChannelWrite(channel, @ptrCast(string), length) != @as(isize, @intCast(length))) {
        abi.error_external_return();
    }
}

fn makeLocalChannel(fd: c_int, ch_type: abi.ChannelType) abi.Tchannel {
    const ch = channelAllocate();
    channel_table_ptr.?[ch] = .{
        .descriptor = fd,
        .type = ch_type,
        .flags = .{},
    };
    return ch;
}

/// Create a pipe and bind its read/write descriptors to two new channels.
pub fn osMakePipe(readerp: *abi.Tchannel, writerp: *abi.Tchannel) callconv(.c) void {
    var pv: [2]std.c.fd_t = undefined;
    transact.transaction_begin();
    while (std.c.pipe(&pv) < 0) {
        abi.UX_prim_check_fd_errno(abi.syscall_pipe);
    }
    abi.UX_out_of_files_p = false;
    readerp.* = makeLocalChannel(pv[0], .unix_pipe);
    osChannelCloseOnAbort(readerp.*);
    writerp.* = makeLocalChannel(pv[1], .unix_pipe);
    transact.transaction_commit();
}

fn getFlags(fd: c_int) c_int {
    while (true) {
        const scr = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        if (scr >= 0) return scr;
        abi.UX_prim_check_errno(abi.syscall_fcntl_GETFL);
    }
}

fn setFlags(fd: c_int, flags: c_int) void {
    while (std.c.fcntl(fd, std.c.F.SETFL, flags) < 0) {
        abi.UX_prim_check_errno(abi.syscall_fcntl_SETFL);
    }
}

/// Return 1 if `channel` is configured nonblocking, 0 otherwise.
pub fn osChannelNonblockingP(channel: abi.Tchannel) callconv(.c) c_int {
    return @intCast(channel_table_ptr.?[channel].flags.nonblocking);
}

/// Enable nonblocking (`O_NONBLOCK`) mode on `channel`.
pub fn osChannelNonblocking(channel: abi.Tchannel) callconv(.c) void {
    const entry = &channel_table_ptr.?[channel];
    const flags = getFlags(entry.descriptor);
    if ((flags & o_nonblock) == 0) {
        setFlags(entry.descriptor, flags | o_nonblock);
    }
    entry.flags.nonblocking = 1;
}

/// Restore blocking mode on `channel`.
pub fn osChannelBlocking(channel: abi.Tchannel) callconv(.c) void {
    const entry = &channel_table_ptr.?[channel];
    const flags = getFlags(entry.descriptor);
    if ((flags & o_nonblock) != 0) {
        setFlags(entry.descriptor, flags & ~o_nonblock);
    }
    entry.flags.nonblocking = 0;
}

const PollSelectRegistry = struct {
    const min_sr_length: c_uint = 4;

    const Impl = extern struct {
        length: c_uint,
        n_fds: c_uint,
        entries: [*]std.c.pollfd,
    };

    fn decodeMode(mode: c_uint) i16 {
        var events: i16 = 0;
        if ((mode & abi.select_mode_read) != 0) events |= std.c.POLL.IN;
        if ((mode & abi.select_mode_write) != 0) events |= std.c.POLL.OUT;
        return events;
    }

    fn encodeMode(revents: i16) c_uint {
        var mode: c_uint = 0;
        if ((revents & std.c.POLL.IN) != 0) mode |= abi.select_mode_read;
        if ((revents & std.c.POLL.OUT) != 0) mode |= abi.select_mode_write;
        if ((revents & std.c.POLL.ERR) != 0) mode |= abi.select_mode_error;
        if ((revents & std.c.POLL.HUP) != 0) mode |= abi.select_mode_hup;
        return mode;
    }

    fn allocate() abi.SelectRegistry {
        const r: *Impl = @ptrCast(@alignCast(abi.OS_malloc(@sizeOf(Impl)).?));
        const entries: [*]std.c.pollfd = @ptrCast(@alignCast(abi.OS_malloc(@sizeOf(std.c.pollfd) * min_sr_length).?));
        r.* = .{
            .length = min_sr_length,
            .n_fds = 0,
            .entries = entries,
        };
        return @ptrCast(r);
    }

    fn deallocate(registry: abi.SelectRegistry) void {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        abi.OS_free(@ptrCast(r.entries));
        abi.OS_free(@ptrCast(r));
    }

    fn add(registry: abi.SelectRegistry, fd: c_int, mode: c_uint) void {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        const mask = decodeMode(mode);
        var i: c_uint = 0;
        while (i < r.n_fds) : (i += 1) {
            if (r.entries[i].fd == fd) {
                r.entries[i].events |= mask;
                return;
            }
        }
        if (i == r.length) {
            const new_len = r.length * 2;
            r.entries = @ptrCast(@alignCast(abi.OS_realloc(@ptrCast(r.entries), @sizeOf(std.c.pollfd) * new_len).?));
            r.length = new_len;
        }
        r.entries[i] = .{ .fd = fd, .events = mask, .revents = 0 };
        r.n_fds += 1;
    }

    fn remove(registry: abi.SelectRegistry, fd: c_int, mode: c_uint) void {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        const mask = decodeMode(mode);
        var i: c_uint = 0;
        while (true) {
            if (i == r.n_fds) return;
            if (r.entries[i].fd == fd) {
                r.entries[i].events &= ~mask;
                if (r.entries[i].events == 0) break;
                return;
            }
            i += 1;
        }
        r.n_fds -= 1;
        while (i < r.n_fds) : (i += 1) {
            r.entries[i] = r.entries[i + 1];
        }
        if (i < (r.length / 2) and r.length > min_sr_length) {
            const new_len = r.length / 2;
            r.entries = @ptrCast(@alignCast(abi.OS_realloc(@ptrCast(r.entries), @sizeOf(std.c.pollfd) * new_len).?));
            r.length = new_len;
        }
    }

    fn length(registry: abi.SelectRegistry) c_uint {
        const r: *const Impl = @ptrCast(@alignCast(registry.?));
        return r.n_fds;
    }

    fn entry(registry: abi.SelectRegistry, index: c_uint, fd_r: *c_int, mode_r: *c_uint) void {
        const r: *const Impl = @ptrCast(@alignCast(registry.?));
        fd_r.* = r.entries[index].fd;
        mode_r.* = encodeMode(r.entries[index].events);
    }

    fn result(registry: abi.SelectRegistry, index: c_uint, fd_r: *c_int, mode_r: *c_uint) void {
        const r: *const Impl = @ptrCast(@alignCast(registry.?));
        fd_r.* = r.entries[index].fd;
        mode_r.* = encodeMode(r.entries[index].revents);
    }

    fn safePoll(fds: [*]std.c.pollfd, nfds: std.c.nfds_t, blockp: c_int) c_int {
        if (blockp == 0) {
            return std.c.poll(fds, nfds, 0);
        }
        var old: std.c.sigset_t = undefined;
        var new: std.c.sigset_t = undefined;
        _ = std.c.sigfillset(&new);
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &new, &old);
        const n: c_int = if (abi.OS_process_any_status_change() != 0 or osscheme.pending_interrupts_p() != 0) blk: {
            std.c._errno().* = @backingInt(std.c.E.INTR);
            break :blk -1;
        } else std.c.ppoll(fds, nfds, null, &old);
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &old, null);
        return n;
    }

    fn testRegistry(registry: abi.SelectRegistry, blockp: c_int) c_int {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        while (true) {
            const nfds = safePoll(r.entries, @intCast(r.n_fds), blockp);
            if (nfds > 0) return nfds;
            if (nfds < 0) {
                const err = std.c._errno().*;
                if (err != @backingInt(std.c.E.INTR)) {
                    utils.error_system_call(err, abi.syscall_select);
                }
            }
            if (abi.OS_process_any_status_change() != 0) return abi.select_process_status_change;
            if (osscheme.pending_interrupts_p() != 0) return abi.select_interrupt;
            if (nfds == 0) return 0;
        }
    }

    fn testDescriptor(fd: c_int, blockp: c_int, mode: c_uint) c_int {
        var pfds = [_]std.c.pollfd{.{
            .fd = fd,
            .events = decodeMode(mode),
            .revents = 0,
        }};
        while (true) {
            const nfds = safePoll(&pfds, 1, blockp);
            if (nfds > 0) return @intCast(encodeMode(pfds[0].revents));
            if (nfds < 0) {
                const err = std.c._errno().*;
                if (err != @backingInt(std.c.E.INTR)) {
                    utils.error_system_call(err, abi.syscall_select);
                }
            }
            if (abi.OS_process_any_status_change() != 0) return abi.select_process_status_change;
            if (osscheme.pending_interrupts_p() != 0) return abi.select_interrupt;
            if (nfds == 0) return 0;
        }
    }
};

const FdSetSelectRegistry = struct {
    const Impl = extern struct {
        qreaders: FdSet,
        qwriters: FdSet,
        rreaders: FdSet,
        rwriters: FdSet,
        n_fds: c_uint,
    };

    fn isRegistered(r: *const Impl, fd: c_int) bool {
        return fdIsSet(fd, &r.qreaders) or fdIsSet(fd, &r.qwriters);
    }

    fn rmode(r: *const Impl, fd: c_int) c_uint {
        var mode: c_uint = 0;
        if (fdIsSet(fd, &r.rreaders)) mode |= abi.select_mode_read;
        if (fdIsSet(fd, &r.rwriters)) mode |= abi.select_mode_write;
        return mode;
    }

    fn allocate() abi.SelectRegistry {
        const r: *Impl = @ptrCast(@alignCast(abi.OS_malloc(@sizeOf(Impl)).?));
        r.* = .{
            .qreaders = .{},
            .qwriters = .{},
            .rreaders = .{},
            .rwriters = .{},
            .n_fds = 0,
        };
        return @ptrCast(r);
    }

    fn deallocate(registry: abi.SelectRegistry) void {
        abi.OS_free(registry);
    }

    fn add(registry: abi.SelectRegistry, fd: c_int, mode: c_uint) void {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        const was_set = isRegistered(r, fd);
        if ((mode & abi.select_mode_read) != 0) fdSetBit(fd, &r.qreaders, true);
        if ((mode & abi.select_mode_write) != 0) fdSetBit(fd, &r.qwriters, true);
        if (!was_set and isRegistered(r, fd)) r.n_fds += 1;
    }

    fn remove(registry: abi.SelectRegistry, fd: c_int, mode: c_uint) void {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        const was_set = isRegistered(r, fd);
        if ((mode & abi.select_mode_read) != 0) fdSetBit(fd, &r.qreaders, false);
        if ((mode & abi.select_mode_write) != 0) fdSetBit(fd, &r.qwriters, false);
        if (was_set and !isRegistered(r, fd)) r.n_fds -= 1;
    }

    fn length(registry: abi.SelectRegistry) c_uint {
        const r: *const Impl = @ptrCast(@alignCast(registry.?));
        return r.n_fds;
    }

    fn result(registry: abi.SelectRegistry, index: c_uint, fd_r: *c_int, mode_r: *c_uint) void {
        const r: *const Impl = @ptrCast(@alignCast(registry.?));
        var i: c_uint = 0;
        for (0..@intCast(fd_setsize)) |fd_u| {
            const fd: c_int = @intCast(fd_u);
            if (isRegistered(r, fd)) {
                if (i < index) {
                    i += 1;
                } else {
                    fd_r.* = fd;
                    mode_r.* = rmode(r, fd);
                    return;
                }
            }
        }
    }

    fn safeSelect(nfds: c_int, readfds: *FdSet, writefds: *FdSet, blockp: c_int) c_int {
        if (blockp == 0) {
            var zero_timeout: std.c.timeval = .{ .sec = 0, .usec = 0 };
            return DarwinSelect.select(nfds, readfds, writefds, null, &zero_timeout);
        }
        var old: std.c.sigset_t = undefined;
        var new: std.c.sigset_t = undefined;
        _ = std.c.sigfillset(&new);
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &new, &old);
        const n: c_int = if (abi.OS_process_any_status_change() != 0 or osscheme.pending_interrupts_p() != 0) blk: {
            std.c._errno().* = @backingInt(std.c.E.INTR);
            break :blk -1;
        } else DarwinSelect.pselect(nfds, readfds, writefds, null, null, &old);
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &old, null);
        return n;
    }

    fn testRegistry(registry: abi.SelectRegistry, blockp: c_int) c_int {
        const r: *Impl = @ptrCast(@alignCast(registry.?));
        while (true) {
            r.rreaders = r.qreaders;
            r.rwriters = r.qwriters;
            const nfds = safeSelect(@intCast(fd_setsize), &r.rreaders, &r.rwriters, blockp);
            if (nfds > 0) return nfds;
            if (nfds < 0) {
                const err = std.c._errno().*;
                if (err != @backingInt(std.c.E.INTR)) {
                    utils.error_system_call(err, abi.syscall_select);
                }
            }
            if (abi.OS_process_any_status_change() != 0) return abi.select_process_status_change;
            if (osscheme.pending_interrupts_p() != 0) return abi.select_interrupt;
            if (nfds == 0) return 0;
        }
    }

    fn testDescriptor(fd: c_int, blockp: c_int, mode: c_uint) c_int {
        while (true) {
            var readable: FdSet = .{};
            var writeable: FdSet = .{};
            if ((mode & abi.select_mode_read) != 0) fdSetBit(fd, &readable, true);
            if ((mode & abi.select_mode_write) != 0) fdSetBit(fd, &writeable, true);
            const nfds = safeSelect(fd + 1, &readable, &writeable, blockp);
            if (nfds > 0) {
                var ready: c_int = 0;
                if (fdIsSet(fd, &readable)) ready |= @intCast(abi.select_mode_read);
                if (fdIsSet(fd, &writeable)) ready |= @intCast(abi.select_mode_write);
                return ready;
            }
            if (nfds < 0) {
                const err = std.c._errno().*;
                if (err != @backingInt(std.c.E.INTR)) {
                    utils.error_system_call(err, abi.syscall_select);
                }
            }
            if (abi.OS_process_any_status_change() != 0) return abi.select_process_status_change;
            if (osscheme.pending_interrupts_p() != 0) return abi.select_interrupt;
            if (nfds == 0) return 0;
        }
    }
};

const SelectBackend = if (have_poll) PollSelectRegistry else FdSetSelectRegistry;

/// Allocate a select/poll descriptor registry.
pub fn osAllocateSelectRegistry() callconv(.c) abi.SelectRegistry {
    return SelectBackend.allocate();
}

/// Free a select/poll descriptor registry.
pub fn osDeallocateSelectRegistry(registry: abi.SelectRegistry) callconv(.c) void {
    SelectBackend.deallocate(registry);
}

/// Register interest in `mode` events on file descriptor `fd`.
pub fn osAddToSelectRegistry(registry: abi.SelectRegistry, fd: c_int, mode: c_uint) callconv(.c) void {
    SelectBackend.add(registry, fd, mode);
}

/// Remove interest in `mode` events on file descriptor `fd`.
pub fn osRemoveFromSelectRegistry(registry: abi.SelectRegistry, fd: c_int, mode: c_uint) callconv(.c) void {
    SelectBackend.remove(registry, fd, mode);
}

/// Return the number of file descriptors registered in `registry`.
pub fn osSelectRegistryLength(registry: abi.SelectRegistry) callconv(.c) c_uint {
    return SelectBackend.length(registry);
}

/// Read back the configured `(fd, mode)` at `index` in `registry` (Linux poll backend).
pub fn osSelectRegistryEntry(registry: abi.SelectRegistry, index: c_uint, fd_r: *c_int, mode_r: *c_uint) callconv(.c) void {
    PollSelectRegistry.entry(registry, index, fd_r, mode_r);
}

/// Read back the polled `(fd, mode)` result at `index` in `registry`.
pub fn osSelectRegistryResult(registry: abi.SelectRegistry, index: c_uint, fd_r: *c_int, mode_r: *c_uint) callconv(.c) void {
    SelectBackend.result(registry, index, fd_r, mode_r);
}

/// Poll or select registered descriptors in `registry`, optionally blocking.
pub fn osTestSelectRegistry(registry: abi.SelectRegistry, blockp: c_int) callconv(.c) c_int {
    return SelectBackend.testRegistry(registry, blockp);
}

/// Poll or select a single descriptor `fd` for `mode` events.
pub fn osTestSelectDescriptor(fd: c_int, blockp: c_int, mode: c_uint) callconv(.c) c_int {
    return SelectBackend.testDescriptor(fd, blockp, mode);
}

/// Block until a signal or subprocess status change arrives when `blockp` is true.
pub fn osPause(blockp: bool, ignore_status_change: bool) callconv(.c) c_int {
    if (!blockp) {
        if (!ignore_status_change and abi.OS_process_any_status_change() != 0) {
            return abi.select_process_status_change;
        }
        return abi.select_interrupt;
    }
    var old: std.c.sigset_t = undefined;
    var new: std.c.sigset_t = undefined;
    _ = std.c.sigfillset(&new);
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, &new, &old);
    const n: c_int = if (!ignore_status_change and abi.OS_process_any_status_change() != 0)
        abi.select_process_status_change
    else if (abi.Registers[abi.regblock_int_code] != 0)
        abi.select_interrupt
    else blk: {
        _ = sigsuspend(&old);
        break :blk if (abi.OS_process_any_status_change() != 0)
            abi.select_process_status_change
        else
            abi.select_interrupt;
    };
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, &old, null);
    return n;
}

comptime {
    if (!builtin.is_test) {
        @export(&os_channel_table_size, .{ .name = "OS_channel_table_size" });
        @export(&channel_table_ptr, .{ .name = "channel_table" });
        @export(&os_have_select_p, .{ .name = "OS_have_select_p" });
        @export(&uxInitializeChannels, .{ .name = "UX_initialize_channels" });
        @export(&uxResetChannels, .{ .name = "UX_reset_channels" });
        @export(&channelAllocate, .{ .name = "channel_allocate" });
        @export(&uxChannelDescriptor, .{ .name = "UX_channel_descriptor" });
        @export(&osChannelOpenP, .{ .name = "OS_channel_open_p" });
        @export(&osChannelClose, .{ .name = "OS_channel_close" });
        @export(&osChannelCloseNoerror, .{ .name = "OS_channel_close_noerror" });
        @export(&osChannelCloseOnAbort, .{ .name = "OS_channel_close_on_abort" });
        @export(&osChannelSynchronize, .{ .name = "OS_channel_synchronize" });
        @export(&osChannelType, .{ .name = "OS_channel_type" });
        @export(&osChannelRead, .{ .name = "OS_channel_read" });
        @export(&osChannelWrite, .{ .name = "OS_channel_write" });
        @export(&osChannelReadLoadFile, .{ .name = "OS_channel_read_load_file" });
        @export(&osChannelWriteDumpFile, .{ .name = "OS_channel_write_dump_file" });
        @export(&osChannelWriteString, .{ .name = "OS_channel_write_string" });
        @export(&osMakePipe, .{ .name = "OS_make_pipe" });
        @export(&osChannelNonblockingP, .{ .name = "OS_channel_nonblocking_p" });
        @export(&osChannelNonblocking, .{ .name = "OS_channel_nonblocking" });
        @export(&osChannelBlocking, .{ .name = "OS_channel_blocking" });
        @export(&osAllocateSelectRegistry, .{ .name = "OS_allocate_select_registry" });
        @export(&osDeallocateSelectRegistry, .{ .name = "OS_deallocate_select_registry" });
        @export(&osAddToSelectRegistry, .{ .name = "OS_add_to_select_registry" });
        @export(&osRemoveFromSelectRegistry, .{ .name = "OS_remove_from_select_registry" });
        @export(&osSelectRegistryLength, .{ .name = "OS_select_registry_length" });
        if (have_poll) {
            @export(&osSelectRegistryEntry, .{ .name = "OS_select_registry_entry" });
        }
        @export(&osSelectRegistryResult, .{ .name = "OS_select_registry_result" });
        @export(&osTestSelectRegistry, .{ .name = "OS_test_select_registry" });
        @export(&osTestSelectDescriptor, .{ .name = "OS_test_select_descriptor" });
        @export(&osPause, .{ .name = "OS_pause" });
    }
}

test "uxio pipe channels nonblocking sync select registry and pause" {
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    uxInitializeChannels();
    defer {
        uxResetChannels();
        transact.transaction_initialize();
        wind.dstack_reset();
    }

    try std.testing.expect(os_channel_table_size >= 64);

    var r_ch: abi.Tchannel = abi.no_channel;
    var w_ch: abi.Tchannel = abi.no_channel;
    osMakePipe(&r_ch, &w_ch);
    try std.testing.expectEqual(@as(c_int, 1), osChannelOpenP(r_ch));
    try std.testing.expectEqual(@as(c_int, 1), osChannelOpenP(w_ch));
    try std.testing.expectEqual(abi.ChannelType.unix_pipe, osChannelType(r_ch));
    try std.testing.expectEqual(abi.ChannelType.unix_pipe, osChannelType(w_ch));
    try std.testing.expectEqual(@as(c_int, 0), osChannelNonblockingP(r_ch));

    osChannelNonblocking(r_ch);
    try std.testing.expectEqual(@as(c_int, 1), osChannelNonblockingP(r_ch));
    var buf: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(isize, -1), osChannelRead(r_ch, &buf, buf.len));

    osChannelBlocking(r_ch);
    try std.testing.expectEqual(@as(c_int, 0), osChannelNonblockingP(r_ch));

    osChannelWriteString(w_ch, "zig-io");
    try std.testing.expectEqual(@as(c_int, @intCast(abi.select_mode_read)), osTestSelectDescriptor(uxChannelDescriptor(r_ch), 0, abi.select_mode_read));

    const reg = osAllocateSelectRegistry();
    defer osDeallocateSelectRegistry(reg);
    osAddToSelectRegistry(reg, uxChannelDescriptor(r_ch), abi.select_mode_read);
    try std.testing.expectEqual(@as(c_uint, 1), osSelectRegistryLength(reg));
    try std.testing.expectEqual(@as(c_int, 1), osTestSelectRegistry(reg, 0));

    var res_fd: c_int = -1;
    var res_mode: c_uint = 0;
    osSelectRegistryResult(reg, 0, &res_fd, &res_mode);
    try std.testing.expectEqual(uxChannelDescriptor(r_ch), res_fd);
    try std.testing.expectEqual(abi.select_mode_read, res_mode);

    osRemoveFromSelectRegistry(reg, uxChannelDescriptor(r_ch), abi.select_mode_read);
    try std.testing.expectEqual(@as(c_uint, 0), osSelectRegistryLength(reg));

    const nread = osChannelRead(r_ch, &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 6), nread);
    try std.testing.expectEqualStrings("zig-io", buf[0..6]);

    // Synchronize on a pipe (ENOTTY/EINVAL/ESPIPE/ENOTSUP ignored cleanly) and on a real temp file.
    osChannelSynchronize(w_ch);

    var tmp_buf: [64]u8 = undefined;
    const pid = std.c.getpid();
    const tmp_slice = try std.fmt.bufPrint(tmp_buf[0 .. tmp_buf.len - 1], "/tmp/zig-uxio-test-{d}.bin", .{pid});
    tmp_buf[tmp_slice.len] = 0;
    const tmp_path: [*:0]const u8 = @ptrCast(tmp_buf[0..tmp_slice.len :0]);
    const file_fd = std.c.open(tmp_path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(file_fd >= 0);
    defer _ = std.c.unlink(tmp_path);

    const file_ch = makeLocalChannel(file_fd, .file);
    defer if (osChannelOpenP(file_ch) != 0) osChannelCloseNoerror(file_ch);
    try std.testing.expectEqual(@as(usize, 4), osChannelWriteDumpFile(file_ch, "dump", 4));
    try std.testing.expect(std.c.lseek(file_fd, 0, std.c.SEEK.SET) == 0);
    var load_buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), osChannelReadLoadFile(file_ch, &load_buf, load_buf.len));
    try std.testing.expectEqualStrings("dump", &load_buf);
    osChannelSynchronize(file_ch);
    osChannelClose(file_ch);
    try std.testing.expectEqual(@as(c_int, 0), osChannelOpenP(file_ch));

    try std.testing.expectEqual(abi.select_interrupt, osPause(false, false));

    osChannelClose(r_ch);
    osChannelClose(w_ch);
    try std.testing.expectEqual(@as(c_int, 0), osChannelOpenP(r_ch));
    try std.testing.expectEqual(@as(c_int, 0), osChannelOpenP(w_ch));
}
