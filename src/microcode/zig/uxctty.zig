const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

const TerminalStateRecording = struct {
    fd: c_int = -1,
    recorded_p: c_int = 0,
    state: abi.TttyState = std.mem.zeroes(abi.TttyState),
    flags: c_int = 0,
};

const TinterruptChars = struct {
    quit: abi.CcT,
    intrpt: abi.CcT,
    tstp: abi.CcT,
    dtstp: abi.CcT,
};

const default_sigquit_char: abi.CcT = 0o003;
const default_sigint_char: abi.CcT = 0o007;
const default_sigtstp_char: abi.CcT = 0o032;

const keyboard_quit_interrupt: abi.TinterruptEnables = 0x1;
const keyboard_intrpt_interrupt: abi.TinterruptEnables = 0x2;
const keyboard_tstp_interrupt: abi.TinterruptEnables = 0x4;
const keyboard_all_interrupts: abi.TinterruptEnables = 0x7;

pub var scheme_in_foreground: c_int = 0;

var ctty_fildes: c_int = -1;
var permit_ctty_control: c_int = 0;

var outside_ctty_state: TerminalStateRecording = .{};
var outside_stdin_state: TerminalStateRecording = .{};
var outside_stdout_state: TerminalStateRecording = .{};
var inside_ctty_state: TerminalStateRecording = .{};
var inside_stdin_state: TerminalStateRecording = .{};
var inside_stdout_state: TerminalStateRecording = .{};

var current_interrupt_enables: abi.TinterruptEnables = keyboard_all_interrupts;
var current_interrupt_chars: TinterruptChars = .{
    .quit = default_sigquit_char,
    .intrpt = default_sigint_char,
    .tstp = default_sigtstp_char,
    .dtstp = 0xff,
};

extern "c" fn tcgetpgrp(fd: c_int) std.c.pid_t;
extern "c" fn getpgrp() std.c.pid_t;
extern "c" fn ctermid(s: ?[*]u8) ?[*:0]u8;

fn getTerminalState(fd: c_int, s: *abi.TttyState) c_int {
    while (true) {
        const scr = abi.UX_terminal_get_state(fd, s);
        if (scr >= 0 or std.c._errno().* != @intFromEnum(std.c.E.INTR)) return scr;
    }
}

fn setTerminalState(fd: c_int, s: *const abi.TttyState) void {
    while (true) {
        const scr = abi.UX_terminal_set_state(fd, s);
        if (scr >= 0 or std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

fn getFlags(fd: c_int, flags: *c_int) c_int {
    while (true) {
        const scr = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        if (scr >= 0) {
            flags.* = scr;
            return 0;
        }
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return -1;
    }
}

fn setFlags(fd: c_int, flags: c_int) void {
    while (true) {
        const scr = std.c.fcntl(fd, std.c.F.SETFL, flags);
        if (scr >= 0 or std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

fn saveExternalState(s: *TerminalStateRecording) void {
    s.recorded_p = @intFromBool(
        scheme_in_foreground != 0 and
            std.c.isatty(s.fd) != 0 and
            getTerminalState(s.fd, &s.state) >= 0 and
            getFlags(s.fd, &s.flags) >= 0,
    );
}

fn restoreExternalState(s: *TerminalStateRecording) void {
    if (s.recorded_p != 0) {
        setTerminalState(s.fd, &s.state);
        setFlags(s.fd, s.flags);
        s.recorded_p = 0;
    }
}

/// Snapshot internal terminal state into `s` when external state `es` was recorded.
pub fn saveInternalState(s: *TerminalStateRecording, es: *const TerminalStateRecording) callconv(.c) void {
    if (es.recorded_p != 0) {
        s.recorded_p = @intFromBool(
            getTerminalState(s.fd, &s.state) >= 0 and
                getFlags(s.fd, &s.flags) >= 0,
        );
    }
}

fn restoreInternalState(s: *TerminalStateRecording, es: *const TerminalStateRecording) void {
    if (s.recorded_p != 0) {
        if (es.recorded_p != 0) {
            setTerminalState(s.fd, &s.state);
            setFlags(s.fd, s.flags);
        }
        s.recorded_p = 0;
    }
}

/// Determine foreground job status and save external ctty/stdin/stdout terminal states.
pub fn uxCttySaveExternalState() callconv(.c) void {
    if (permit_ctty_control != 0 and ctty_fildes >= 0) {
        const pgrp_id = tcgetpgrp(ctty_fildes);
        scheme_in_foreground = if (pgrp_id < 0)
            @intFromBool(std.c._errno().* == @intFromEnum(std.c.E.NOSYS))
        else
            @intFromBool(getpgrp() == pgrp_id);
    } else {
        scheme_in_foreground = 0;
    }
    const states = [_]*TerminalStateRecording{
        &outside_ctty_state,
        &outside_stdin_state,
        &outside_stdout_state,
    };
    for (states) |rec| saveExternalState(rec);
}

/// Restore saved external ctty/stdin/stdout terminal states before leaving Scheme.
pub fn uxCttyRestoreExternalState() callconv(.c) void {
    const states = [_]*TerminalStateRecording{
        &outside_ctty_state,
        &outside_stdin_state,
        &outside_stdout_state,
    };
    for (states) |rec| restoreExternalState(rec);
}

/// Save Scheme's internal ctty/stdin/stdout terminal states prior to external handoff.
pub fn uxCttySaveInternalState() callconv(.c) void {
    saveInternalState(&inside_ctty_state, &outside_ctty_state);
    saveInternalState(&inside_stdin_state, &outside_stdin_state);
    saveInternalState(&inside_stdout_state, &outside_stdout_state);
}

/// Restore Scheme's internal ctty/stdin/stdout terminal states upon resuming foreground.
pub fn uxCttyRestoreInternalState() callconv(.c) void {
    const do_update = inside_ctty_state.recorded_p != 0 and outside_ctty_state.recorded_p != 0;
    restoreInternalState(&inside_ctty_state, &outside_ctty_state);
    restoreInternalState(&inside_stdin_state, &outside_stdin_state);
    restoreInternalState(&inside_stdout_state, &outside_stdout_state);
    if (do_update) {
        cttyUpdateInterruptChars();
    }
}

/// Return non-zero if Scheme recorded external controlling-terminal state for interrupt control.
pub fn osCttyInterruptControl() callconv(.c) c_int {
    return outside_ctty_state.recorded_p;
}

/// Return non-zero if Scheme owns terminal settings for `fd`.
pub fn uxTerminalControlOk(fd: c_int) callconv(.c) c_int {
    if (fd == std.c.STDIN_FILENO) return outside_stdin_state.recorded_p;
    if (fd == std.c.STDOUT_FILENO) return outside_stdout_state.recorded_p;
    return 1;
}

/// Return configured QUIT interrupt character.
pub fn osCttyQuitChar() callconv(.c) abi.CcT {
    return current_interrupt_chars.quit;
}

/// Return configured INT interrupt character.
pub fn osCttyIntChar() callconv(.c) abi.CcT {
    return current_interrupt_chars.intrpt;
}

/// Return configured TSTP interrupt character.
pub fn osCttyTstpChar() callconv(.c) abi.CcT {
    return current_interrupt_chars.tstp;
}

/// Return controlling-terminal disabled character (`_POSIX_VDISABLE`).
pub fn osCttyDisabledChar() callconv(.c) abi.CcT {
    return if (ctty_fildes >= 0) abi.UX_PC_VDISABLE(ctty_fildes) else 0xff;
}

/// Return open controlling terminal file descriptor or `-1`.
pub fn osCttyFd() callconv(.c) c_int {
    return ctty_fildes;
}

fn cttySetInterruptChars(ic: *const TinterruptChars) void {
    var s: abi.TttyState = undefined;
    if (getTerminalState(ctty_fildes, &s) == 0) {
        s.tio.cc[@intFromEnum(std.c.V.QUIT)] = ic.quit;
        s.tio.cc[@intFromEnum(std.c.V.INTR)] = ic.intrpt;
        s.tio.cc[@intFromEnum(std.c.V.SUSP)] = ic.tstp;
        if (@hasField(std.c.V, "DSUSP")) {
            s.tio.cc[@intFromEnum(std.c.V.DSUSP)] = ic.dtstp;
        }
        setTerminalState(ctty_fildes, &s);
    }
}

fn cttyUpdateInterruptChars() void {
    if (outside_ctty_state.recorded_p != 0) {
        const disabled_char = abi.UX_PC_VDISABLE(ctty_fildes);
        var active = current_interrupt_chars;
        if ((current_interrupt_enables & keyboard_quit_interrupt) == 0) active.quit = disabled_char;
        if ((current_interrupt_enables & keyboard_intrpt_interrupt) == 0) active.intrpt = disabled_char;
        if ((current_interrupt_enables & keyboard_tstp_interrupt) == 0) active.tstp = disabled_char;
        active.dtstp = disabled_char;
        cttySetInterruptChars(&active);
    }
}

/// Store the current keyboard interrupt enable bitmask into `mask`.
pub fn osCttyGetInterruptEnables(mask: *abi.TinterruptEnables) callconv(.c) void {
    mask.* = current_interrupt_enables;
}

/// Set active keyboard interrupt enable bitmask from `mask` and sync ctty settings.
pub fn osCttySetInterruptEnables(mask: *const abi.TinterruptEnables) callconv(.c) void {
    current_interrupt_enables = mask.*;
    cttyUpdateInterruptChars();
}

/// Return number of configurable ctty interrupt characters (`3`).
pub fn osCttyNumIntChars() callconv(.c) c_uint {
    return 3;
}

/// Return static 3-byte array containing `[quit, intrpt, tstp]` interrupt characters.
pub fn osCttyGetIntChars() callconv(.c) [*]abi.CcT {
    const State = struct {
        var int_chars: [3]abi.CcT = undefined;
    };
    State.int_chars[0] = current_interrupt_chars.quit;
    State.int_chars[1] = current_interrupt_chars.intrpt;
    State.int_chars[2] = current_interrupt_chars.tstp;
    return &State.int_chars;
}

/// Update `[quit, intrpt, tstp]` interrupt characters and sync controlling terminal.
pub fn osCttySetIntChars(int_chars: [*]const abi.CcT) callconv(.c) void {
    current_interrupt_chars.quit = int_chars[0];
    current_interrupt_chars.intrpt = int_chars[1];
    current_interrupt_chars.tstp = int_chars[2];
    cttyUpdateInterruptChars();
}

/// Return static 3-byte array of `[quit, int, tstp]` signal handler enums.
pub fn osCttyGetIntCharHandlers() callconv(.c) [*]abi.CcT {
    const State = struct {
        var int_handlers: [3]abi.CcT = undefined;
    };
    State.int_handlers[0] = @truncate(abi.OS_signal_quit_handler());
    State.int_handlers[1] = @truncate(abi.OS_signal_int_handler());
    State.int_handlers[2] = @truncate(abi.OS_signal_tstp_handler());
    return &State.int_handlers;
}

/// Configure `[quit, int, tstp]` signal handlers via `OS_signal_set_interrupt_handlers`.
pub fn osCttySetIntCharHandlers(int_handlers: [*]const abi.CcT) callconv(.c) void {
    abi.OS_signal_set_interrupt_handlers(int_handlers[0], int_handlers[1], int_handlers[2]);
}

/// Initialize controlling terminal file descriptor, external/internal snapshots, and interrupt chars.
pub fn uxInitializeCtty(interactive: c_int) callconv(.c) void {
    var buffer: [1024]u8 = @splat(0);
    const tty = ctermid(&buffer);
    ctty_fildes = if (tty == null or tty.?[0] == 0)
        -1
    else
        std.c.open(tty.?, .{ .ACCMODE = .RDWR }, @as(c_uint, 0));

    permit_ctty_control = interactive;
    outside_ctty_state.fd = ctty_fildes;
    inside_ctty_state.fd = ctty_fildes;
    outside_stdin_state.fd = std.c.STDIN_FILENO;
    inside_stdin_state.fd = std.c.STDIN_FILENO;
    outside_stdout_state.fd = std.c.STDOUT_FILENO;
    inside_stdout_state.fd = std.c.STDOUT_FILENO;

    uxCttySaveExternalState();
    inside_ctty_state.recorded_p = 0;
    inside_stdin_state.recorded_p = 0;
    inside_stdout_state.recorded_p = 0;

    current_interrupt_chars = .{
        .quit = default_sigquit_char,
        .intrpt = default_sigint_char,
        .tstp = default_sigtstp_char,
        .dtstp = abi.UX_PC_VDISABLE(ctty_fildes),
    };
    current_interrupt_enables = keyboard_all_interrupts;
    if (outside_ctty_state.recorded_p != 0) {
        cttySetInterruptChars(&current_interrupt_chars);
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&scheme_in_foreground, .{ .name = "scheme_in_foreground" });
        @export(&saveInternalState, .{ .name = "save_internal_state" });
        @export(&uxCttySaveExternalState, .{ .name = "UX_ctty_save_external_state" });
        @export(&uxCttyRestoreExternalState, .{ .name = "UX_ctty_restore_external_state" });
        @export(&uxCttySaveInternalState, .{ .name = "UX_ctty_save_internal_state" });
        @export(&uxCttyRestoreInternalState, .{ .name = "UX_ctty_restore_internal_state" });
        @export(&osCttyInterruptControl, .{ .name = "OS_ctty_interrupt_control" });
        @export(&uxTerminalControlOk, .{ .name = "UX_terminal_control_ok" });
        @export(&osCttyQuitChar, .{ .name = "OS_ctty_quit_char" });
        @export(&osCttyIntChar, .{ .name = "OS_ctty_int_char" });
        @export(&osCttyTstpChar, .{ .name = "OS_ctty_tstp_char" });
        @export(&osCttyDisabledChar, .{ .name = "OS_ctty_disabled_char" });
        @export(&osCttyFd, .{ .name = "OS_ctty_fd" });
        @export(&osCttyGetInterruptEnables, .{ .name = "OS_ctty_get_interrupt_enables" });
        @export(&osCttySetInterruptEnables, .{ .name = "OS_ctty_set_interrupt_enables" });
        @export(&osCttyNumIntChars, .{ .name = "OS_ctty_num_int_chars" });
        @export(&osCttyGetIntChars, .{ .name = "OS_ctty_get_int_chars" });
        @export(&osCttySetIntChars, .{ .name = "OS_ctty_set_int_chars" });
        @export(&osCttyGetIntCharHandlers, .{ .name = "OS_ctty_get_int_char_handlers" });
        @export(&osCttySetIntCharHandlers, .{ .name = "OS_ctty_set_int_char_handlers" });
        @export(&uxInitializeCtty, .{ .name = "UX_initialize_ctty" });
    }
}

test "uxctty non-interactive init, interrupt chars/enables, and handlers" {
    stubs.resetMockRuntime();
    uxInitializeCtty(0);
    defer {
        if (ctty_fildes >= 0) {
            _ = std.c.close(ctty_fildes);
            ctty_fildes = -1;
        }
    }

    try std.testing.expectEqual(@as(c_int, 0), scheme_in_foreground);
    try std.testing.expectEqual(@as(c_int, 0), osCttyInterruptControl());
    try std.testing.expectEqual(@as(c_int, 1), uxTerminalControlOk(99));
    try std.testing.expectEqual(@as(c_uint, 3), osCttyNumIntChars());

    try std.testing.expectEqual(@as(abi.CcT, 0o003), osCttyQuitChar());
    try std.testing.expectEqual(@as(abi.CcT, 0o007), osCttyIntChar());
    try std.testing.expectEqual(@as(abi.CcT, 0o032), osCttyTstpChar());

    const chars = osCttyGetIntChars();
    try std.testing.expectEqualSlices(abi.CcT, &.{ 0o003, 0o007, 0o032 }, chars[0..3]);
    const custom_chars = [_]abi.CcT{ 0o034, 0o002, 0o031 };
    osCttySetIntChars(&custom_chars);
    try std.testing.expectEqual(@as(abi.CcT, 0o034), osCttyQuitChar());

    var enables: abi.TinterruptEnables = 0;
    osCttyGetInterruptEnables(&enables);
    try std.testing.expectEqual(keyboard_all_interrupts, enables);
    const masked: abi.TinterruptEnables = keyboard_quit_interrupt;
    osCttySetInterruptEnables(&masked);
    osCttyGetInterruptEnables(&enables);
    try std.testing.expectEqual(keyboard_quit_interrupt, enables);

    const h = osCttyGetIntCharHandlers();
    try std.testing.expectEqualSlices(abi.CcT, &.{ 3, 5, 4 }, h[0..3]);
    const new_h = [_]abi.CcT{ 6, 7, 8 };
    osCttySetIntCharHandlers(&new_h);
    try std.testing.expectEqualSlices(abi.CcT, &.{ 6, 7, 8 }, osCttyGetIntCharHandlers()[0..3]);
}
