const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const outf = @import("outf.zig");
const osscheme = @import("osscheme.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

const TerminalState = struct {
    buffer: c_int,
    state: abi.TttyState,
};

var terminal_table_size: usize = 0;
var terminal_table: ?[*]TerminalState = null;

const RawSpeedT = @typeInfo(std.c.speed_t).@"enum".tag_type;

extern "c" fn cfgetospeed(*const std.c.termios) RawSpeedT;
extern "c" fn cfgetispeed(*const std.c.termios) RawSpeedT;
extern "c" fn cfsetospeed(*std.c.termios, RawSpeedT) c_int;
extern "c" fn cfsetispeed(*std.c.termios, RawSpeedT) c_int;
extern "c" fn tcflush(c_int, c_int) c_int;
extern "c" fn tcdrain(c_int) c_int;
extern "c" fn grantpt(c_int) c_int;
extern "c" fn unlockpt(c_int) c_int;
extern "c" fn ptsname(c_int) ?[*:0]u8;

const tciflush: c_int = if (builtin.os.tag.isDarwin()) 1 else 0;
const tcoflush: c_int = if (builtin.os.tag.isDarwin()) 2 else 1;

const all_baud_rates = [_]c_uint{
    0,       50,      75,      110,     134,     150,     200,     300,
    600,     1200,    1800,    2400,    4800,    9600,    19200,   38400,
    57600,   115200,  230400,  460800,  500000,  576000,  921600,  1000000,
    1152000, 1500000, 2000000, 2500000, 3000000, 3500000, 4000000,
};

const BaudEntry = struct {
    index: c_uint,
    rate: c_uint,
};

const baud_table = blk: {
    @setEvalBranchQuota(100000);
    var count: usize = 0;
    for (all_baud_rates) |rate| {
        const name = std.fmt.comptimePrint("B{d}", .{rate});
        if (@hasField(std.c.speed_t, name)) count += 1;
    }
    var entries: [count]BaudEntry = undefined;
    var i: usize = 0;
    for (all_baud_rates) |rate| {
        const name = std.fmt.comptimePrint("B{d}", .{rate});
        if (@hasField(std.c.speed_t, name)) {
            entries[i] = .{
                .index = @intCast(@backingInt(@field(std.c.speed_t, name))),
                .rate = rate,
            };
            i += 1;
        }
    }
    break :blk entries;
};

/// Allocate the terminal state table matching `OS_channel_table_size`.
pub fn uxInitializeTerminals() callconv(.c) void {
    terminal_table_size = @intCast(abi.OS_channel_table_size);
    const raw = std.c.malloc(terminal_table_size * @sizeOf(TerminalState)) orelse {
        outf.fatal("\nUnable to allocate terminal table.\n", .{});
        outf.flushFatal();
        abi.termination_init_error();
    };
    const ptr: [*]TerminalState = @ptrCast(@alignCast(raw));
    for (ptr[0..terminal_table_size]) |*entry| {
        entry.* = .{ .buffer = -1, .state = std.mem.zeroes(abi.TttyState) };
    }
    terminal_table = ptr;
}

/// Free the terminal state table during microcode reset/reload.
pub fn uxResetTerminals() callconv(.c) void {
    std.c.free(@ptrCast(terminal_table));
    terminal_table = null;
    terminal_table_size = 0;
}

/// Record initial terminal attributes when opening a terminal `channel`.
pub fn terminalOpen(channel: abi.Tchannel) callconv(.c) void {
    const new_size: usize = @intCast(abi.OS_channel_table_size);
    if (terminal_table_size != new_size) {
        const raw = abi.OS_realloc(@ptrCast(terminal_table), new_size * @sizeOf(TerminalState));
        const ptr: [*]TerminalState = @ptrCast(@alignCast(raw.?));
        if (new_size > terminal_table_size) {
            for (ptr[terminal_table_size..new_size]) |*entry| {
                entry.* = .{ .buffer = -1, .state = std.mem.zeroes(abi.TttyState) };
            }
        }
        terminal_table = ptr;
        terminal_table_size = new_size;
    }
    const table = terminal_table.?;
    table[channel].buffer = -1;
    getTerminalState(channel, &table[channel].state);
}

/// Read POSIX terminal state for `channel` into `s`.
pub fn getTerminalState(channel: abi.Tchannel, s: *abi.TttyState) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    while (abi.UX_terminal_get_state(fd, s) < 0) {
        abi.UX_prim_check_errno(abi.syscall_terminal_get_state);
    }
}

/// Apply POSIX terminal state `s` to `channel` if Scheme controls that terminal.
pub fn setTerminalState(channel: abi.Tchannel, s: *const abi.TttyState) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    if (abi.UX_terminal_control_ok(fd) != 0) {
        while (abi.UX_terminal_set_state(fd, s) < 0) {
            abi.UX_prim_check_errno(abi.syscall_terminal_set_state);
        }
    }
}

/// Return output baud index from `TttyState`.
pub fn terminalStateGetOspeed(s: *const abi.TttyState) callconv(.c) c_uint {
    return @intCast(cfgetospeed(&s.tio));
}

/// Return input baud index from `TttyState`.
pub fn terminalStateGetIspeed(s: *const abi.TttyState) callconv(.c) c_uint {
    return @intCast(cfgetispeed(&s.tio));
}

/// Set output baud index `b` inside `TttyState`.
pub fn terminalStateSetOspeed(s: *abi.TttyState, b: c_uint) callconv(.c) void {
    _ = cfsetospeed(&s.tio, @intCast(b));
}

/// Set input baud index `b` inside `TttyState`.
pub fn terminalStateSetIspeed(s: *abi.TttyState, b: c_uint) callconv(.c) void {
    _ = cfsetispeed(&s.tio, @intCast(b));
}

/// Return 1 if output post-processing (`OPOST`) is enabled in `s`, else 0.
pub fn terminalStateCookedOutputP(s: *const abi.TttyState) callconv(.c) c_int {
    return @intFromBool(s.tio.oflag.OPOST);
}

/// Disable output post-processing (`OPOST`) in `s`.
pub fn terminalStateRawOutput(s: *abi.TttyState) callconv(.c) void {
    s.tio.oflag.OPOST = false;
}

/// Restore `OPOST` flag in `s` from the saved original state for `channel`.
pub fn terminalStateCookedOutput(s: *abi.TttyState, channel: abi.Tchannel) callconv(.c) void {
    const orig = &terminal_table.?[channel].state;
    if (orig.tio.oflag.OPOST) {
        s.tio.oflag.OPOST = true;
    }
}

/// Return 1 if canonical line buffering (`ICANON`) is enabled in `s`, else 0.
pub fn terminalStateBufferedP(s: *const abi.TttyState) callconv(.c) c_int {
    return @intFromBool(s.tio.lflag.ICANON);
}

/// Configure `s` for non-canonical raw/cbreak input with optional `polling` (`VMIN = 0`).
pub fn terminalStateNonbuffered(s: *abi.TttyState, fd: c_int, polling: c_int) callconv(.c) void {
    s.tio.lflag.ICANON = false;
    s.tio.lflag.ECHO = false;
    s.tio.lflag.IEXTEN = false;
    s.tio.lflag.ISIG = true;

    s.tio.iflag.IGNBRK = true;
    s.tio.iflag.ICRNL = false;
    s.tio.iflag.IXON = false;
    s.tio.iflag.ISTRIP = false;

    s.tio.cflag.CSIZE = .CS8;
    s.tio.cflag.PARENB = false;

    s.tio.cc[@backingInt(std.c.V.MIN)] = if (polling != 0) 0 else 1;
    s.tio.cc[@backingInt(std.c.V.TIME)] = 0;

    const disable = abi.UX_PC_VDISABLE(fd);
    s.tio.cc[@backingInt(std.c.V.STOP)] = disable;
    s.tio.cc[@backingInt(std.c.V.START)] = disable;
}

/// Configure `s` for raw input (non-buffered and `ISIG` disabled).
pub fn terminalStateRaw(s: *abi.TttyState, fd: c_int) callconv(.c) void {
    terminalStateNonbuffered(s, fd, 0);
    s.tio.lflag.ISIG = false;
}

/// Restore canonical buffered input flags in `s` from the saved state for `channel`.
pub fn terminalStateBuffered(s: *abi.TttyState, channel: abi.Tchannel) callconv(.c) void {
    const orig = &terminal_table.?[channel].state;
    s.tio.lflag.ICANON = true;
    s.tio.lflag.ISIG = true;
    if (orig.tio.lflag.ECHO) s.tio.lflag.ECHO = true;
    if (orig.tio.lflag.IEXTEN) s.tio.lflag.IEXTEN = true;
    s.tio.iflag = orig.tio.iflag;
    s.tio.cflag.CSIZE = .CS8;
    s.tio.cflag.PARENB = false;
    s.tio.cc[@backingInt(std.c.V.MIN)] = orig.tio.cc[@backingInt(std.c.V.MIN)];
    s.tio.cc[@backingInt(std.c.V.TIME)] = orig.tio.cc[@backingInt(std.c.V.TIME)];
    s.tio.cc[@backingInt(std.c.V.STOP)] = orig.tio.cc[@backingInt(std.c.V.STOP)];
    s.tio.cc[@backingInt(std.c.V.START)] = orig.tio.cc[@backingInt(std.c.V.START)];
}

/// Query terminal input baud index for `channel`.
pub fn osTerminalGetIspeed(channel: abi.Tchannel) callconv(.c) c_uint {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    return terminalStateGetIspeed(&s);
}

/// Query terminal output baud index for `channel`.
pub fn osTerminalGetOspeed(channel: abi.Tchannel) callconv(.c) c_uint {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    return terminalStateGetOspeed(&s);
}

/// Set terminal input baud index `baud` for `channel`.
pub fn osTerminalSetIspeed(channel: abi.Tchannel, baud: c_uint) callconv(.c) void {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    terminalStateSetIspeed(&s, baud);
    setTerminalState(channel, &s);
}

/// Set terminal output baud index `baud` for `channel`.
pub fn osTerminalSetOspeed(channel: abi.Tchannel, baud: c_uint) callconv(.c) void {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    terminalStateSetOspeed(&s, baud);
    setTerminalState(channel, &s);
}

/// Parse Scheme primitive argument `argument` as a valid OS baud index.
pub fn argBaudIndex(argument: c_uint) callconv(.c) c_uint {
    const index = abi.arg_ulong_integer(@intCast(argument));
    for (baud_table) |entry| {
        if (index == entry.index) return entry.index;
    }
    abi.error_bad_range_arg(@intCast(argument));
}

/// Convert OS baud index `index` to numeric bits-per-second rate.
pub fn osBaudIndexToRate(index: c_uint) callconv(.c) c_uint {
    for (baud_table) |entry| {
        if (index == entry.index) return entry.rate;
    }
    std.c.abort();
}

/// Convert numeric bits-per-second `rate` to OS baud index, or `-1` if unsupported.
pub fn osBaudRateToIndex(rate: c_uint) callconv(.c) c_int {
    for (baud_table) |entry| {
        if (rate == entry.rate) return @intCast(entry.index);
    }
    return -1;
}

/// Return byte size of `TttyState` (`struct termios`).
pub fn osTerminalStateSize() callconv(.c) c_uint {
    return @sizeOf(abi.TttyState);
}

/// Copy current terminal state of `channel` into opaque `statep`.
pub fn osTerminalGetState(channel: abi.Tchannel, statep: ?*anyopaque) callconv(.c) void {
    getTerminalState(channel, @ptrCast(@alignCast(statep.?)));
}

/// Apply opaque `statep` to terminal `channel`.
pub fn osTerminalSetState(channel: abi.Tchannel, statep: ?*anyopaque) callconv(.c) void {
    setTerminalState(channel, @ptrCast(@alignCast(statep.?)));
}

/// Return 1 if `channel` uses cooked output (`OPOST`), else 0.
pub fn osTerminalCookedOutputP(channel: abi.Tchannel) callconv(.c) c_int {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    return terminalStateCookedOutputP(&s);
}

/// Switch `channel` to raw output (`OPOST` off).
pub fn osTerminalRawOutput(channel: abi.Tchannel) callconv(.c) void {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    terminalStateRawOutput(&s);
    setTerminalState(channel, &s);
}

/// Restore cooked output on `channel` from saved state.
pub fn osTerminalCookedOutput(channel: abi.Tchannel) callconv(.c) void {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    terminalStateCookedOutput(&s, channel);
    setTerminalState(channel, &s);
}

/// Return 1 if `channel` is in canonical buffered input mode, else 0.
pub fn osTerminalBufferedP(channel: abi.Tchannel) callconv(.c) c_int {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    return terminalStateBufferedP(&s);
}

/// Restore canonical buffered input mode on `channel`.
pub fn osTerminalBuffered(channel: abi.Tchannel) callconv(.c) void {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    terminalStateBuffered(&s, channel);
    setTerminalState(channel, &s);
}

/// Switch `channel` to non-buffered input mode.
pub fn osTerminalNonbuffered(channel: abi.Tchannel) callconv(.c) void {
    var s: abi.TttyState = undefined;
    getTerminalState(channel, &s);
    terminalStateNonbuffered(&s, abi.channel_table[channel].descriptor, 0);
    setTerminalState(channel, &s);
}

/// Discard unread input queued on terminal `channel` (`tcflush(..., TCIFLUSH)`).
pub fn osTerminalFlushInput(channel: abi.Tchannel) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    while (tcflush(fd, tciflush) < 0) {
        abi.UX_prim_check_errno(abi.syscall_tcflush);
    }
}

/// Discard unwritten output queued on terminal `channel` (`tcflush(..., TCOFLUSH)`).
pub fn osTerminalFlushOutput(channel: abi.Tchannel) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    while (tcflush(fd, tcoflush) < 0) {
        abi.UX_prim_check_errno(abi.syscall_tcflush);
    }
}

/// Wait until all written output has been transmitted on `channel` (`tcdrain`).
pub fn osTerminalDrainOutput(channel: abi.Tchannel) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    while (tcdrain(fd) < 0) {
        abi.UX_prim_check_errno(abi.syscall_tcdrain);
    }
}

/// Return 1 if POSIX job control is supported.
pub fn osJobControlP() callconv(.c) c_int {
    return 1;
}

/// Return 1 if pseudo-terminals are supported (`HAVE_GRANTPT`).
pub fn osHavePtysP() callconv(.c) c_int {
    return 1;
}

/// Allocate and unlock a pseudo-terminal master, storing channel and master name, returning slave pathname.
pub fn osOpenPtyMaster(master_fd: *abi.Tchannel, master_fname: *[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const State = struct {
        var slave_name: [64]u8 = @splat(0);
    };
    while (true) {
        var fd: c_int = -1;
        if (comptime builtin.os.tag.isDarwin()) {
            const DarwinPty = struct {
                extern "c" fn openpty(*c_int, *c_int, ?[*]u8, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;
            };
            var slave_fd: c_int = -1;
            var openpty_buf: [64]u8 = @splat(0);
            const rc = DarwinPty.openpty(&fd, &slave_fd, &openpty_buf, null, null);
            if (rc < 0) {
                fd = -1;
            } else {
                _ = std.c.close(slave_fd);
            }
        } else {
            const PosixPty = struct {
                extern "c" fn posix_openpt(std.c.O) callconv(.c) c_int;
            };
            fd = PosixPty.posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true });
        }
        if (fd < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) {
                osscheme.deliver_pending_interrupts();
                continue;
            }
            return null;
        }
        _ = grantpt(fd);
        _ = unlockpt(fd);
        const pts_ptr = ptsname(fd) orelse {
            _ = std.c.close(fd);
            return null;
        };
        const pts_slice = std.mem.span(pts_ptr);
        const copy_len = @min(pts_slice.len, State.slave_name.len - 1);
        @memcpy(State.slave_name[0..copy_len], pts_slice[0..copy_len]);
        State.slave_name[copy_len] = 0;

        master_fd.* = abi.makeChannel(fd, .unix_pty_master);
        master_fname.* = "/dev/ptmx";
        return @ptrCast(&State.slave_name);
    }
}

/// Send signal `sig` to the slave process group of PTY master `channel`.
pub fn osPtyMasterSendSignal(channel: abi.Tchannel, sig: c_int) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    const tiocsig: ?u32 = if (builtin.os.tag.isDarwin())
        0x2000745f
    else if (builtin.os.tag == .linux)
        0x40045436
    else
        null;
    if (tiocsig) |req| {
        while (std.c.ioctl(fd, @bitCast(req), sig) < 0) {
            abi.UX_prim_check_errno(abi.syscall_ioctl_tiocsigsend);
        }
        return;
    }
    unreachable;
}

/// Send `SIGKILL` to the slave process group of PTY master `channel`.
pub fn osPtyMasterKill(channel: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(channel, @backingInt(std.c.SIG.KILL));
}

/// Send `SIGTSTP` to the slave process group of PTY master `channel`.
pub fn osPtyMasterStop(channel: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(channel, @backingInt(std.c.SIG.TSTP));
}

/// Send `SIGCONT` to the slave process group of PTY master `channel`.
pub fn osPtyMasterContinue(channel: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(channel, @backingInt(std.c.SIG.CONT));
}

/// Send `SIGINT` to the slave process group of PTY master `channel`.
pub fn osPtyMasterInterrupt(channel: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(channel, @backingInt(std.c.SIG.INT));
}

/// Send `SIGQUIT` to the slave process group of PTY master `channel`.
pub fn osPtyMasterQuit(channel: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(channel, @backingInt(std.c.SIG.QUIT));
}

/// Send `SIGHUP` to the slave process group of PTY master `channel`.
pub fn osPtyMasterHangup(channel: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(channel, @backingInt(std.c.SIG.HUP));
}

comptime {
    if (!builtin.is_test) {
        @export(&uxInitializeTerminals, .{ .name = "UX_initialize_terminals" });
        @export(&uxResetTerminals, .{ .name = "UX_reset_terminals" });
        @export(&terminalOpen, .{ .name = "terminal_open" });
        @export(&getTerminalState, .{ .name = "get_terminal_state" });
        @export(&setTerminalState, .{ .name = "set_terminal_state" });
        @export(&terminalStateGetOspeed, .{ .name = "terminal_state_get_ospeed" });
        @export(&terminalStateGetIspeed, .{ .name = "terminal_state_get_ispeed" });
        @export(&terminalStateSetOspeed, .{ .name = "terminal_state_set_ospeed" });
        @export(&terminalStateSetIspeed, .{ .name = "terminal_state_set_ispeed" });
        @export(&terminalStateCookedOutputP, .{ .name = "terminal_state_cooked_output_p" });
        @export(&terminalStateRawOutput, .{ .name = "terminal_state_raw_output" });
        @export(&terminalStateCookedOutput, .{ .name = "terminal_state_cooked_output" });
        @export(&terminalStateBufferedP, .{ .name = "terminal_state_buffered_p" });
        @export(&terminalStateNonbuffered, .{ .name = "terminal_state_nonbuffered" });
        @export(&terminalStateRaw, .{ .name = "terminal_state_raw" });
        @export(&terminalStateBuffered, .{ .name = "terminal_state_buffered" });
        @export(&osTerminalGetIspeed, .{ .name = "OS_terminal_get_ispeed" });
        @export(&osTerminalGetOspeed, .{ .name = "OS_terminal_get_ospeed" });
        @export(&osTerminalSetIspeed, .{ .name = "OS_terminal_set_ispeed" });
        @export(&osTerminalSetOspeed, .{ .name = "OS_terminal_set_ospeed" });
        @export(&argBaudIndex, .{ .name = "arg_baud_index" });
        @export(&osBaudIndexToRate, .{ .name = "OS_baud_index_to_rate" });
        @export(&osBaudRateToIndex, .{ .name = "OS_baud_rate_to_index" });
        @export(&osTerminalStateSize, .{ .name = "OS_terminal_state_size" });
        @export(&osTerminalGetState, .{ .name = "OS_terminal_get_state" });
        @export(&osTerminalSetState, .{ .name = "OS_terminal_set_state" });
        @export(&osTerminalCookedOutputP, .{ .name = "OS_terminal_cooked_output_p" });
        @export(&osTerminalRawOutput, .{ .name = "OS_terminal_raw_output" });
        @export(&osTerminalCookedOutput, .{ .name = "OS_terminal_cooked_output" });
        @export(&osTerminalBufferedP, .{ .name = "OS_terminal_buffered_p" });
        @export(&osTerminalBuffered, .{ .name = "OS_terminal_buffered" });
        @export(&osTerminalNonbuffered, .{ .name = "OS_terminal_nonbuffered" });
        @export(&osTerminalFlushInput, .{ .name = "OS_terminal_flush_input" });
        @export(&osTerminalFlushOutput, .{ .name = "OS_terminal_flush_output" });
        @export(&osTerminalDrainOutput, .{ .name = "OS_terminal_drain_output" });
        @export(&osJobControlP, .{ .name = "OS_job_control_p" });
        @export(&osHavePtysP, .{ .name = "OS_have_ptys_p" });
        @export(&osOpenPtyMaster, .{ .name = "OS_open_pty_master" });
        @export(&osPtyMasterSendSignal, .{ .name = "OS_pty_master_send_signal" });
        @export(&osPtyMasterKill, .{ .name = "OS_pty_master_kill" });
        @export(&osPtyMasterStop, .{ .name = "OS_pty_master_stop" });
        @export(&osPtyMasterContinue, .{ .name = "OS_pty_master_continue" });
        @export(&osPtyMasterInterrupt, .{ .name = "OS_pty_master_interrupt" });
        @export(&osPtyMasterQuit, .{ .name = "OS_pty_master_quit" });
        @export(&osPtyMasterHangup, .{ .name = "OS_pty_master_hangup" });
    }
}

test "uxterm baud round-trips, termios flag helpers, table lifecycle, and PTY open" {
    stubs.resetMockRuntime();
    uxInitializeTerminals();
    defer uxResetTerminals();

    try std.testing.expectEqual(@as(c_int, 1), osJobControlP());
    try std.testing.expectEqual(@as(c_int, 1), osHavePtysP());
    try std.testing.expectEqual(@as(c_uint, @sizeOf(abi.TttyState)), osTerminalStateSize());

    for ([_]c_uint{ 0, 9600, 115200 }) |rate| {
        const idx = osBaudRateToIndex(rate);
        try std.testing.expect(idx >= 0);
        try std.testing.expectEqual(rate, osBaudIndexToRate(@intCast(idx)));
    }
    try std.testing.expectEqual(@as(c_int, -1), osBaudRateToIndex(12345));

    var s = std.mem.zeroes(abi.TttyState);
    s.tio.oflag.OPOST = true;
    s.tio.lflag.ICANON = true;
    s.tio.lflag.ECHO = true;
    try std.testing.expectEqual(@as(c_int, 1), terminalStateCookedOutputP(&s));
    try std.testing.expectEqual(@as(c_int, 1), terminalStateBufferedP(&s));

    terminalStateRawOutput(&s);
    try std.testing.expectEqual(@as(c_int, 0), terminalStateCookedOutputP(&s));
    terminalStateRaw(&s, -1);
    try std.testing.expectEqual(@as(c_int, 0), terminalStateBufferedP(&s));
    try std.testing.expect(!s.tio.lflag.ISIG);

    var master_ch: abi.Tchannel = abi.no_channel;
    var master_fname: [*:0]const u8 = "";
    const slave = osOpenPtyMaster(&master_ch, &master_fname);
    try std.testing.expect(slave != null);
    defer {
        const fd = abi.channel_table[master_ch].descriptor;
        if (fd >= 0) {
            _ = std.c.close(fd);
            abi.channel_table[master_ch].descriptor = -1;
        }
    }
    try std.testing.expectEqual(abi.ChannelType.unix_pty_master, abi.channel_table[master_ch].type);
    try std.testing.expectEqualStrings("/dev/ptmx", std.mem.span(master_fname));
    try std.testing.expect(std.mem.span(slave.?).len > 0);
}
