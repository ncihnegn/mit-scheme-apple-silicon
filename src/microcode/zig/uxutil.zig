const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const wind = @import("wind.zig");
const transact = @import("transact.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

var original_tty_state: abi.TttyState = std.mem.zeroes(abi.TttyState);

fn charDescriptionBrief(c: u8) [*:0]const u8 {
    const State = struct {
        var buffer: [5]u8 = undefined;
    };
    return switch (c) {
        ' ' => "SPC",
        '\t' => "TAB",
        '\r' => "RET",
        '\n' => "LFD",
        0o033 => "ESC",
        0o177 => "DEL",
        else => blk: {
            if (c < ' ') {
                State.buffer[0] = '^';
                State.buffer[1] = c + '@';
                State.buffer[2] = 0;
            } else if (c < 0o177) {
                State.buffer[0] = c;
                State.buffer[1] = 0;
            } else {
                State.buffer[0] = '\\';
                State.buffer[1] = c >> 6;
                State.buffer[2] = (c >> 3) & 7;
                State.buffer[3] = c & 7;
                State.buffer[4] = 0;
            }
            break :blk @ptrCast(&State.buffer);
        },
    };
}

/// Format a human-readable ASCII/meta character description into a static buffer.
pub fn charDescription(c: u8, long_p: c_int) callconv(.c) [*:0]const u8 {
    const State = struct {
        var buffer: [64]u8 = undefined;
    };
    const description = std.mem.span(charDescriptionBrief(c));
    const slice = blk: {
        if (long_p != 0) {
            const meta = c >= 0o200;
            const cc = c & 0o177;
            const control = cc < 0o040;
            if (meta or control) {
                const disp: u8 = if (control) cc + 0o100 else cc;
                break :blk std.fmt.bufPrint(
                    State.buffer[0 .. State.buffer.len - 1],
                    "`{s}' ({s}{s}{c})",
                    .{
                        description,
                        if (meta) "meta-" else "",
                        if (control) "control-" else "",
                        disp,
                    },
                ) catch State.buffer[0..0];
            }
        }
        break :blk std.fmt.bufPrint(
            State.buffer[0 .. State.buffer.len - 1],
            "`{s}'",
            .{description},
        ) catch State.buffer[0..0];
    };
    State.buffer[slice.len] = 0;
    return @ptrCast(&State.buffer);
}

/// Record the initial stdin terminal state for interactive user-I/O restoration.
pub fn uxInitializeUserio() callconv(.c) void {
    _ = abi.UX_terminal_get_state(std.c.STDIN_FILENO, &original_tty_state);
}

fn restoreInputState(ap: ?*anyopaque) callconv(.c) void {
    const state: *const abi.TttyState = @ptrCast(@alignCast(ap.?));
    _ = abi.UX_terminal_set_state(std.c.STDIN_FILENO, state);
}

fn saveInputState() *abi.TttyState {
    const raw = wind.dstack_alloc(@sizeOf(abi.TttyState));
    const s: *abi.TttyState = @ptrCast(@alignCast(raw.?));
    _ = abi.UX_terminal_get_state(std.c.STDIN_FILENO, s);
    transact.transaction_record_action(.tat_always, &restoreInputState, s);
    return s;
}

/// Temporarily restore the original buffered terminal input state for the current transaction.
pub fn userioBufferedInput() callconv(.c) void {
    _ = saveInputState();
    _ = abi.UX_terminal_set_state(std.c.STDIN_FILENO, &original_tty_state);
}

/// Read a single character from `STDIN_FILENO`, retrying on `EINTR` or returning 0 on error/EOF.
pub fn userioReadChar() callconv(.c) u8 {
    var c: u8 = 0;
    while (true) {
        std.c._errno().* = 0;
        const nread = std.c.read(std.c.STDIN_FILENO, @ptrCast(&c), 1);
        if (nread == 1) break;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) {
            c = 0;
            break;
        }
    }
    return c;
}

/// Switch stdin to raw mode inside a transaction, read one character, and restore state.
pub fn userioReadCharRaw() callconv(.c) u8 {
    transact.transaction_begin();
    var state = saveInputState().*;
    abi.terminal_state_raw(&state, std.c.STDIN_FILENO);
    _ = abi.UX_terminal_set_state(std.c.STDIN_FILENO, &state);
    const c = userioReadChar();
    transact.transaction_commit();
    return c;
}

extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

fn cStdout() *std.c.FILE {
    if (builtin.os.tag.isDarwin()) {
        return (struct {
            extern "c" var __stdoutp: *std.c.FILE;
        }).__stdoutp;
    }
    return (struct {
        extern "c" var stdout: *std.c.FILE;
    }).stdout;
}

fn cStderr() *std.c.FILE {
    if (builtin.os.tag.isDarwin()) {
        return (struct {
            extern "c" var __stderrp: *std.c.FILE;
        }).__stderrp;
    }
    return (struct {
        extern "c" var stderr: *std.c.FILE;
    }).stderr;
}

fn writeStream(stream: *std.c.FILE, slice: []const u8) void {
    _ = std.c.fwrite(slice.ptr, 1, slice.len, stream);
}

/// Display `herald`, list `choices`, prompt, and return the uppercase matching choice initial.
pub fn userioChooseOption(
    herald: [*:0]const u8,
    prompt: [*:0]const u8,
    choices: [*]?[*:0]const u8,
) callconv(.c) u8 {
    const out = cStdout();
    while (true) {
        writeStream(out, std.mem.span(herald));
        writeStream(out, "\n");
        var scan = choices;
        while (scan[0]) |choice_z| {
            scan += 1;
            writeStream(out, "  ");
            writeStream(out, std.mem.span(choice_z));
            writeStream(out, "\n");
        }
        writeStream(out, std.mem.span(prompt));
        _ = fflush(out);

        const raw_cmd = userioReadCharRaw();
        if (raw_cmd == 0 and std.c._errno().* != 0) return raw_cmd;
        writeStream(out, "\n");
        _ = fflush(out);

        const command = std.ascii.toUpper(raw_cmd);
        scan = choices;
        while (scan[0]) |choice_z| {
            scan += 1;
            const option = std.ascii.toUpper(choice_z[0]);
            if (command == option) return option;
        }
    }
}

/// Prompt the user for confirmation and return 1 for Y/y, 0 for N/n, or terminate on I/O failure.
pub fn userioConfirm(prompt: [*:0]const u8) callconv(.c) c_int {
    const out = cStdout();
    const err = cStderr();
    const prompt_slice = std.mem.span(prompt);
    while (true) {
        writeStream(out, prompt_slice);
        _ = fflush(out);
        switch (userioReadCharRaw()) {
            'y', 'Y' => return 1,
            'n', 'N' => return 0,
            0 => if (std.c._errno().* != 0) {
                writeStream(err, "Problems reading keyboard input -- exiting.\n");
                abi.termination_eof();
            },
            else => {},
        }
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&charDescription, .{ .name = "char_description" });
        @export(&uxInitializeUserio, .{ .name = "UX_initialize_userio" });
        @export(&userioBufferedInput, .{ .name = "userio_buffered_input" });
        @export(&userioReadChar, .{ .name = "userio_read_char" });
        @export(&userioReadCharRaw, .{ .name = "userio_read_char_raw" });
        @export(&userioChooseOption, .{ .name = "userio_choose_option" });
        @export(&userioConfirm, .{ .name = "userio_confirm" });
    }
}

test "uxutil formats char descriptions and restores userio state via transaction" {
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    defer {
        transact.transaction_initialize();
        wind.dstack_reset();
    }

    try std.testing.expectEqualStrings("`a'", std.mem.span(charDescription('a', 0)));
    try std.testing.expectEqualStrings("`SPC'", std.mem.span(charDescription(' ', 0)));
    try std.testing.expectEqualStrings("`TAB'", std.mem.span(charDescription('\t', 0)));
    try std.testing.expectEqualStrings("`ESC'", std.mem.span(charDescription(0o033, 0)));
    try std.testing.expectEqualStrings("`DEL'", std.mem.span(charDescription(0o177, 0)));
    try std.testing.expectEqualStrings("`^C'", std.mem.span(charDescription(3, 0)));
    try std.testing.expectEqualStrings("`^C' (control-C)", std.mem.span(charDescription(3, 1)));
    try std.testing.expectEqualStrings("`\\\x03\x03\x03' (meta-[)", std.mem.span(charDescription(0xDB, 1)));

    uxInitializeUserio();
    try std.testing.expectEqual(@as(usize, 1), stubs.mock_tty_get_calls);

    transact.transaction_begin();
    userioBufferedInput();
    try std.testing.expectEqual(@as(usize, 2), stubs.mock_tty_get_calls);
    try std.testing.expectEqual(@as(usize, 1), stubs.mock_tty_set_calls);
    transact.transaction_commit();
    try std.testing.expectEqual(@as(usize, 2), stubs.mock_tty_set_calls);
}
