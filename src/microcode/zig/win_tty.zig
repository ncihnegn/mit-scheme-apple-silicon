// Derived from MIT/GNU Scheme C sources (`src/microcode/uxtty.c`, `uxctty.c`, `uxterm.c`)
// and Win32 Console APIs:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const utils = @import("utils.zig");
const win = @import("win_api.zig");
const win_io = @import("win_io.zig");

const default_tty_x_size: c_uint = 80;
const default_tty_y_size: c_uint = 24;

var input_channel: abi.Tchannel = 0;
var output_channel: abi.Tchannel = 0;
var error_channel: abi.Tchannel = 0;
var control_ok: bool = false;

var interrupt_enables: abi.TinterruptEnables = 0x7;
var int_chars_buf: [2]abi.CcT = .{ 0x03, 0x07 }; // ^C, ^G
var int_handlers_buf: [2]abi.CcT = .{ 1, 2 };

var external_in_mode: win.DWORD = 0;
var external_out_mode: win.DWORD = 0;
var have_external_in_mode: bool = false;
var have_external_out_mode: bool = false;
var internal_in_mode: win.DWORD = 0;
var internal_out_mode: win.DWORD = 0;
var have_internal_state: bool = false;

const BaudEntry = struct {
    index: c_uint,
    rate: c_uint,
};

const baud_table = [_]BaudEntry{
    .{ .index = 0, .rate = 0 },
    .{ .index = 1, .rate = 50 },
    .{ .index = 2, .rate = 75 },
    .{ .index = 3, .rate = 110 },
    .{ .index = 4, .rate = 134 },
    .{ .index = 5, .rate = 150 },
    .{ .index = 6, .rate = 200 },
    .{ .index = 7, .rate = 300 },
    .{ .index = 8, .rate = 600 },
    .{ .index = 9, .rate = 1200 },
    .{ .index = 10, .rate = 1800 },
    .{ .index = 11, .rate = 2400 },
    .{ .index = 12, .rate = 4800 },
    .{ .index = 13, .rate = 9600 },
    .{ .index = 14, .rate = 19200 },
    .{ .index = 15, .rate = 38400 },
    .{ .index = 16, .rate = 57600 },
    .{ .index = 17, .rate = 115200 },
};

fn detectStdHandleChannel(std_id: win.DWORD, fallback_write: bool) abi.Tchannel {
    const raw = win.kernel32.GetStdHandle(std_id);
    if (raw == null or raw.? == win.INVALID_HANDLE_VALUE) {
        _ = fallback_write;
        return win_io.allocateHandleChannel(win.INVALID_HANDLE_VALUE, .file, true, false);
    }
    const h = raw.?;
    var mode: win.DWORD = 0;
    const ch_type: abi.ChannelType = if (win.kernel32.GetConsoleMode(h, &mode) != 0)
        .terminal
    else switch (win.kernel32.GetFileType(h)) {
        win.FILE_TYPE_CHAR => .terminal,
        win.FILE_TYPE_PIPE => .win32_anonymous_pipe,
        else => .file,
    };
    return win_io.allocateHandleChannel(h, ch_type, true, false);
}

pub fn initTty(interactive: c_int) void {
    input_channel = detectStdHandleChannel(win.STD_INPUT_HANDLE, false);
    output_channel = detectStdHandleChannel(win.STD_OUTPUT_HANDLE, true);
    error_channel = detectStdHandleChannel(win.STD_ERROR_HANDLE, true);
    control_ok = interactive != 0;
    saveExternalState();
    if (have_external_in_mode) {
        internal_in_mode = external_in_mode;
        internal_out_mode = external_out_mode | win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        have_internal_state = true;
    }
}

pub fn saveExternalState() void {
    if (win_io.getOpenChannel(input_channel)) |in_ch| {
        if (in_ch.ch_type == .terminal and in_ch.handle != win.INVALID_HANDLE_VALUE) {
            have_external_in_mode = win.kernel32.GetConsoleMode(in_ch.handle, &external_in_mode) != 0;
        }
    }
    if (win_io.getOpenChannel(output_channel)) |out_ch| {
        if (out_ch.ch_type == .terminal and out_ch.handle != win.INVALID_HANDLE_VALUE) {
            have_external_out_mode = win.kernel32.GetConsoleMode(out_ch.handle, &external_out_mode) != 0;
        }
    }
}

pub fn restoreExternalState() void {
    if (have_external_in_mode) {
        if (win_io.getOpenChannel(input_channel)) |in_ch| {
            _ = win.kernel32.SetConsoleMode(in_ch.handle, external_in_mode);
        }
    }
    if (have_external_out_mode) {
        if (win_io.getOpenChannel(output_channel)) |out_ch| {
            _ = win.kernel32.SetConsoleMode(out_ch.handle, external_out_mode);
        }
    }
}

pub fn saveInternalState() void {
    if (win_io.getOpenChannel(input_channel)) |in_ch| {
        if (in_ch.ch_type == .terminal and in_ch.handle != win.INVALID_HANDLE_VALUE) {
            have_internal_state = win.kernel32.GetConsoleMode(in_ch.handle, &internal_in_mode) != 0;
        }
    }
    if (win_io.getOpenChannel(output_channel)) |out_ch| {
        if (out_ch.ch_type == .terminal and out_ch.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.kernel32.GetConsoleMode(out_ch.handle, &internal_out_mode);
        }
    }
}

pub fn restoreInternalState() void {
    if (!have_internal_state) return;
    if (win_io.getOpenChannel(input_channel)) |in_ch| {
        if (in_ch.ch_type == .terminal and in_ch.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.kernel32.SetConsoleMode(in_ch.handle, internal_in_mode);
        }
    }
    if (win_io.getOpenChannel(output_channel)) |out_ch| {
        if (out_ch.ch_type == .terminal and out_ch.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.kernel32.SetConsoleMode(out_ch.handle, internal_out_mode);
        }
    }
}

pub fn osCttyInterruptControl() callconv(.c) c_int {
    return @intFromBool(control_ok);
}

pub fn osTtyInputChannel() callconv(.c) abi.Tchannel {
    return input_channel;
}

pub fn osTtyOutputChannel() callconv(.c) abi.Tchannel {
    return output_channel;
}

pub fn osTtyErrorChannel() callconv(.c) abi.Tchannel {
    return error_channel;
}

pub fn osTtyXSize() callconv(.c) c_uint {
    if (win_io.getOpenChannel(output_channel)) |ch| {
        if (ch.handle != win.INVALID_HANDLE_VALUE) {
            var csbi: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (win.kernel32.GetConsoleScreenBufferInfo(ch.handle, &csbi) != 0) {
                const cols = csbi.srWindow.Right - csbi.srWindow.Left + 1;
                if (cols > 0) return @intCast(cols);
            }
        }
    }
    return default_tty_x_size;
}

pub fn osTtyYSize() callconv(.c) c_uint {
    if (win_io.getOpenChannel(output_channel)) |ch| {
        if (ch.handle != win.INVALID_HANDLE_VALUE) {
            var csbi: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (win.kernel32.GetConsoleScreenBufferInfo(ch.handle, &csbi) != 0) {
                const rows = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
                if (rows > 0) return @intCast(rows);
            }
        }
    }
    return default_tty_y_size;
}

pub fn osTtyCommandBeep() callconv(.c) [*:0]const u8 {
    return "\x07";
}

pub fn osTtyCommandClear() callconv(.c) [*:0]const u8 {
    return "\x1b[2J\x1b[H";
}

pub fn osCttyGetInterruptEnables(mask: *abi.TinterruptEnables) callconv(.c) void {
    mask.* = interrupt_enables;
}

pub fn osCttySetInterruptEnables(mask: *const abi.TinterruptEnables) callconv(.c) void {
    interrupt_enables = mask.*;
}

pub fn osCttyNumIntChars() callconv(.c) c_uint {
    return int_chars_buf.len;
}

pub fn osCttyGetIntChars() callconv(.c) [*]abi.CcT {
    return &int_chars_buf;
}

pub fn osCttySetIntChars(int_chars: [*]const abi.CcT) callconv(.c) void {
    for (&int_chars_buf, 0..) |*dst, i| dst.* = int_chars[i];
}

pub fn osCttyGetIntCharHandlers() callconv(.c) [*]abi.CcT {
    return &int_handlers_buf;
}

pub fn osCttySetIntCharHandlers(int_handlers: [*]const abi.CcT) callconv(.c) void {
    for (&int_handlers_buf, 0..) |*dst, i| dst.* = int_handlers[i];
}

fn getChannelConsoleMode(channel: abi.Tchannel) win.DWORD {
    const ch = win_io.getOpenChannel(channel) orelse return 0;
    if (ch.handle == win.INVALID_HANDLE_VALUE) return 0;
    var mode: win.DWORD = 0;
    if (win.kernel32.GetConsoleMode(ch.handle, &mode) == 0) return 0;
    return mode;
}

fn setChannelConsoleMode(channel: abi.Tchannel, mode: win.DWORD) void {
    const ch = win_io.getOpenChannel(channel) orelse return;
    if (ch.handle == win.INVALID_HANDLE_VALUE) return;
    _ = win.kernel32.SetConsoleMode(ch.handle, mode);
}

pub fn osTerminalGetIspeed(_: abi.Tchannel) callconv(.c) c_uint {
    return 13; // B9600 index in baud_table
}

pub fn osTerminalGetOspeed(_: abi.Tchannel) callconv(.c) c_uint {
    return 13;
}

pub fn osTerminalSetIspeed(_: abi.Tchannel, _: c_uint) callconv(.c) void {}
pub fn osTerminalSetOspeed(_: abi.Tchannel, _: c_uint) callconv(.c) void {}

pub fn argBaudIndex(argument: c_uint) callconv(.c) c_uint {
    const index = abi.arg_ulong_integer(@intCast(argument));
    for (baud_table) |entry| {
        if (index == entry.index) return entry.index;
    }
    abi.error_bad_range_arg(@intCast(argument));
}

pub fn osBaudIndexToRate(index: c_uint) callconv(.c) c_uint {
    for (baud_table) |entry| {
        if (index == entry.index) return entry.rate;
    }
    std.c.abort();
}

pub fn osBaudRateToIndex(rate: c_uint) callconv(.c) c_int {
    for (baud_table) |entry| {
        if (rate == entry.rate) return @intCast(entry.index);
    }
    return -1;
}

pub fn osTerminalStateSize() callconv(.c) c_uint {
    return @sizeOf(abi.TttyState);
}

pub fn osTerminalGetState(channel: abi.Tchannel, statep: ?*anyopaque) callconv(.c) void {
    const dst: *abi.TttyState = @ptrCast(@alignCast(statep.?));
    dst.mode = getChannelConsoleMode(channel);
}

pub fn osTerminalSetState(channel: abi.Tchannel, statep: ?*anyopaque) callconv(.c) void {
    const src: *const abi.TttyState = @ptrCast(@alignCast(statep.?));
    setChannelConsoleMode(channel, src.mode);
}

pub fn osTerminalCookedOutputP(channel: abi.Tchannel) callconv(.c) c_int {
    return @intFromBool((getChannelConsoleMode(channel) & win.ENABLE_PROCESSED_OUTPUT) != 0);
}

pub fn osTerminalRawOutput(channel: abi.Tchannel) callconv(.c) void {
    setChannelConsoleMode(channel, getChannelConsoleMode(channel) & ~win.ENABLE_PROCESSED_OUTPUT);
}

pub fn osTerminalCookedOutput(channel: abi.Tchannel) callconv(.c) void {
    setChannelConsoleMode(channel, getChannelConsoleMode(channel) | win.ENABLE_PROCESSED_OUTPUT);
}

pub fn osTerminalBufferedP(channel: abi.Tchannel) callconv(.c) c_int {
    return @intFromBool((getChannelConsoleMode(channel) & win.ENABLE_LINE_INPUT) != 0);
}

pub fn osTerminalBuffered(channel: abi.Tchannel) callconv(.c) void {
    setChannelConsoleMode(
        channel,
        getChannelConsoleMode(channel) | win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT,
    );
}

pub fn osTerminalNonbuffered(channel: abi.Tchannel) callconv(.c) void {
    setChannelConsoleMode(
        channel,
        getChannelConsoleMode(channel) & ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT),
    );
}

pub fn osTerminalFlushInput(channel: abi.Tchannel) callconv(.c) void {
    const ch = win_io.getOpenChannel(channel) orelse return;
    if (ch.handle != win.INVALID_HANDLE_VALUE and ch.ch_type == .terminal) {
        _ = win.kernel32.FlushConsoleInputBuffer(ch.handle);
    }
}

pub fn osTerminalFlushOutput(_: abi.Tchannel) callconv(.c) void {}

pub fn osTerminalDrainOutput(channel: abi.Tchannel) callconv(.c) void {
    const ch = win_io.getOpenChannel(channel) orelse return;
    if (ch.handle != win.INVALID_HANDLE_VALUE) {
        _ = win.kernel32.FlushFileBuffers(ch.handle);
    }
}

pub fn osJobControlP() callconv(.c) c_int {
    return 0;
}

pub fn osHavePtysP() callconv(.c) c_int {
    return 0;
}

pub fn osOpenPtyMaster(_: *abi.Tchannel, _: *[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    utils.error_system_call(@intFromEnum(std.c.E.NOSYS), abi.syscall_open);
}

pub fn osPtyMasterSendSignal(_: abi.Tchannel, _: c_int) callconv(.c) void {
    utils.error_system_call(@intFromEnum(std.c.E.NOSYS), abi.syscall_kill);
}

pub fn osPtyMasterKill(ch: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(ch, 9);
}

pub fn osPtyMasterStop(ch: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(ch, 19);
}

pub fn osPtyMasterContinue(ch: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(ch, 18);
}

pub fn osPtyMasterInterrupt(ch: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(ch, 2);
}

pub fn osPtyMasterQuit(ch: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(ch, 3);
}

pub fn osPtyMasterHangup(ch: abi.Tchannel) callconv(.c) void {
    osPtyMasterSendSignal(ch, 1);
}

comptime {
    if (!builtin.is_test) {
        @export(&osTtyInputChannel, .{ .name = "OS_tty_input_channel" });
        @export(&osTtyOutputChannel, .{ .name = "OS_tty_output_channel" });
        @export(&osTtyErrorChannel, .{ .name = "OS_tty_error_channel" });
        @export(&osTtyXSize, .{ .name = "OS_tty_x_size" });
        @export(&osTtyYSize, .{ .name = "OS_tty_y_size" });
        @export(&osTtyCommandBeep, .{ .name = "OS_tty_command_beep" });
        @export(&osTtyCommandClear, .{ .name = "OS_tty_command_clear" });
        @export(&osCttyGetInterruptEnables, .{ .name = "OS_ctty_get_interrupt_enables" });
        @export(&osCttySetInterruptEnables, .{ .name = "OS_ctty_set_interrupt_enables" });
        @export(&osCttyNumIntChars, .{ .name = "OS_ctty_num_int_chars" });
        @export(&osCttyGetIntChars, .{ .name = "OS_ctty_get_int_chars" });
        @export(&osCttySetIntChars, .{ .name = "OS_ctty_set_int_chars" });
        @export(&osCttyGetIntCharHandlers, .{ .name = "OS_ctty_get_int_char_handlers" });
        @export(&osCttySetIntCharHandlers, .{ .name = "OS_ctty_set_int_char_handlers" });
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
