const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("prim_abi.zig");
const option = @import("option.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

const termcap_buffer_size = 2048;
const default_tty_x_size: c_int = 80;
const default_tty_y_size: c_int = 24;
const alert_string: [*:0]const u8 = "\x07";
const fallback_clear: [*:0]const u8 = "\x0c";

var input_channel: abi.Tchannel = 0;
var output_channel: abi.Tchannel = 0;
var error_channel: abi.Tchannel = 0;

var tty_x_size: c_int = default_tty_x_size;
var tty_y_size: c_int = default_tty_y_size;
var tty_command_beep: [*:0]const u8 = alert_string;
var tty_command_clear: ?[*:0]const u8 = fallback_clear;
var tty_size_synchronized_p: bool = false;

const Termcap = if (build_options.use_termcap) struct {
    extern "c" fn tgetent(?*anyopaque, [*:0]const u8) c_int;
    extern "c" fn tgetnum([*:0]const u8) c_int;
    extern "c" fn tgetstr([*:0]const u8, *[*]u8) ?[*:0]const u8;
    extern "c" fn tputs([*:0]const u8, c_int, *const fn (c_int) callconv(.c) c_int) c_int;

    var tputs_output: [termcap_buffer_size]u8 = undefined;
    var tputs_output_scan: usize = 0;
    var tgetstr_buffer: [termcap_buffer_size]u8 = undefined;

    fn tputsWriteChar(c: c_int) callconv(.c) c_int {
        if (tputs_output_scan < tputs_output.len) {
            tputs_output[tputs_output_scan] = @truncate(@as(c_uint, @bitCast(c)));
            tputs_output_scan += 1;
        }
        return c;
    }

    fn withTermcap(comptime procedure: fn () void) void {
        tputs_output_scan = 0;
        var termcap_buffer: [termcap_buffer_size]u8 = undefined;
        if (std.c.isatty(std.c.STDOUT_FILENO) != 0 and !option.option_emacs_subprocess) {
            if (std.c.getenv("TERM")) |term| {
                if (tgetent(@ptrCast(&termcap_buffer), term) > 0) {
                    procedure();
                }
            }
        }
    }

    fn syncSizeWithTermcap() void {
        tty_x_size = tgetnum("co");
        tty_y_size = tgetnum("li");
    }

    fn initTtyWithTermcap() void {
        var tbp: [*]u8 = &tgetstr_buffer;
        tty_command_clear = tgetstr("cl", &tbp);
    }
} else struct {};

fn uxSynchronizeTtySize() void {
    if (tty_size_synchronized_p) return;

    tty_x_size = -1;
    tty_y_size = -1;

    var size: std.c.winsize = undefined;
    if (std.c.ioctl(std.c.STDOUT_FILENO, @bitCast(@as(u32, std.c.T.IOCGWINSZ)), &size) >= 0) {
        tty_x_size = size.col;
        tty_y_size = size.row;
    }

    if (tty_x_size <= 0 or tty_y_size <= 0) {
        if (std.c.getenv("COLUMNS")) |cols| {
            if (std.c.getenv("LINES")) |lines| {
                const x = std.c.atoi(@ptrCast(cols));
                const y = std.c.atoi(@ptrCast(lines));
                if (x > 0 and y > 0) {
                    tty_x_size = x;
                    tty_y_size = y;
                }
            }
        }
    }

    if (build_options.use_termcap) {
        if (tty_x_size <= 0 or tty_y_size <= 0) {
            Termcap.withTermcap(Termcap.syncSizeWithTermcap);
        }
    }

    if (tty_x_size <= 0 or tty_y_size <= 0) {
        tty_x_size = default_tty_x_size;
        tty_y_size = default_tty_y_size;
    }

    tty_size_synchronized_p = true;
}

/// Return the Scheme channel wrapping `STDIN_FILENO`.
pub fn osTtyInputChannel() callconv(.c) abi.Tchannel {
    return input_channel;
}

/// Return the Scheme channel wrapping `STDOUT_FILENO`.
pub fn osTtyOutputChannel() callconv(.c) abi.Tchannel {
    return output_channel;
}

/// Return the Scheme channel wrapping `STDERR_FILENO`.
pub fn osTtyErrorChannel() callconv(.c) abi.Tchannel {
    return error_channel;
}

/// Return cached or freshly queried terminal column width.
pub fn osTtyXSize() callconv(.c) c_uint {
    uxSynchronizeTtySize();
    return @intCast(tty_x_size);
}

/// Return cached or freshly queried terminal row height.
pub fn osTtyYSize() callconv(.c) c_uint {
    uxSynchronizeTtySize();
    return @intCast(tty_y_size);
}

/// Return the terminal bell control string.
pub fn osTtyCommandBeep() callconv(.c) [*:0]const u8 {
    return tty_command_beep;
}

/// Return the terminal screen-clear control string.
pub fn osTtyCommandClear() callconv(.c) [*:0]const u8 {
    return tty_command_clear orelse fallback_clear;
}

/// Initialize standard I/O channels, terminal size, beep, and clear capabilities.
pub fn uxInitializeTty() callconv(.c) void {
    input_channel = abi.OS_open_fd(std.c.STDIN_FILENO);
    abi.channel_table[input_channel].flags.internal = 1;
    output_channel = abi.OS_open_fd(std.c.STDOUT_FILENO);
    abi.channel_table[output_channel].flags.internal = 1;
    error_channel = abi.OS_open_fd(std.c.STDERR_FILENO);
    abi.channel_table[error_channel].flags.internal = 1;
    tty_size_synchronized_p = false;
    uxSynchronizeTtySize();
    tty_command_beep = alert_string;
    if (!build_options.use_termcap) {
        tty_command_clear = fallback_clear;
    } else {
        tty_command_clear = null;
        Termcap.withTermcap(Termcap.initTtyWithTermcap);
        if (tty_command_clear) |clear_str| {
            const start = Termcap.tputs_output_scan;
            _ = Termcap.tputs(clear_str, tty_y_size, &Termcap.tputsWriteChar);
            if (Termcap.tputs_output_scan < Termcap.tputs_output.len) {
                Termcap.tputs_output[Termcap.tputs_output_scan] = 0;
                Termcap.tputs_output_scan += 1;
                tty_command_clear = @ptrCast(&Termcap.tputs_output[start]);
            } else {
                Termcap.tputs_output[Termcap.tputs_output.len - 1] = 0;
                tty_command_clear = @ptrCast(&Termcap.tputs_output[start]);
            }
        } else {
            tty_command_clear = fallback_clear;
        }
    }
}

/// Mark cached terminal dimensions stale so the next size query re-reads them.
pub fn uxReinitializeTty() callconv(.c) void {
    tty_size_synchronized_p = false;
}

comptime {
    if (!builtin.is_test) {
        @export(&uxInitializeTty, .{ .name = "UX_initialize_tty" });
        @export(&uxReinitializeTty, .{ .name = "UX_reinitialize_tty" });
        @export(&osTtyInputChannel, .{ .name = "OS_tty_input_channel" });
        @export(&osTtyOutputChannel, .{ .name = "OS_tty_output_channel" });
        @export(&osTtyErrorChannel, .{ .name = "OS_tty_error_channel" });
        @export(&osTtyXSize, .{ .name = "OS_tty_x_size" });
        @export(&osTtyYSize, .{ .name = "OS_tty_y_size" });
        @export(&osTtyCommandBeep, .{ .name = "OS_tty_command_beep" });
        @export(&osTtyCommandClear, .{ .name = "OS_tty_command_clear" });
    }
}

test "uxtty initializes standard internal channels and queries terminal properties" {
    stubs.resetMockRuntime();

    uxInitializeTty();
    const in_ch = osTtyInputChannel();
    const out_ch = osTtyOutputChannel();
    const err_ch = osTtyErrorChannel();

    try std.testing.expectEqual(@as(abi.Tchannel, 0), in_ch);
    try std.testing.expectEqual(@as(abi.Tchannel, 1), out_ch);
    try std.testing.expectEqual(@as(abi.Tchannel, 2), err_ch);
    try std.testing.expectEqual(@as(u1, 1), abi.channel_table[in_ch].flags.internal);
    try std.testing.expectEqual(@as(u1, 1), abi.channel_table[out_ch].flags.internal);
    try std.testing.expectEqual(@as(u1, 1), abi.channel_table[err_ch].flags.internal);

    try std.testing.expect(osTtyXSize() > 0);
    try std.testing.expect(osTtyYSize() > 0);
    try std.testing.expectEqualStrings("\x07", std.mem.span(osTtyCommandBeep()));
    try std.testing.expect(std.mem.span(osTtyCommandClear()).len > 0);

    uxReinitializeTty();
    try std.testing.expect(!tty_size_synchronized_p);
    try std.testing.expect(osTtyXSize() > 0);
    try std.testing.expect(tty_size_synchronized_p);
}
