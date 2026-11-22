// Derived from MIT/GNU Scheme C sources (`src/microcode/uxsig.c`, `src/microcode/uxsig.h`, `src/microcode/ossig.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("../../core/prim_abi.zig");
const outf = @import("../../support/outf.zig");
const boot = @import("../../core/boot.zig");
const debug = @import("../../runtime/debug.zig");
const floenv = @import("../../arith/floenv.zig");
const option = @import("../../core/option.zig");
const osscheme = @import("../osscheme.zig");
const ostty = @import("../ostty.zig");
const transact = @import("../../support/transact.zig");
const wind = @import("../../support/wind.zig");
const stubs = if (builtin.is_test) @import("../../core/test_stubs.zig") else struct {};

pub const TsignalHandler = ?*align(1) const fn (c_int, ?*std.c.siginfo_t, ?*anyopaque) callconv(.c) void;

pub const InterruptHandler = enum(c_uint) {
    ignore = 0,
    default = 1,
    unknown = 2,
    terminate = 3,
    stop = 4,
    interactive = 5,
    control_b = 6,
    control_g = 7,
    control_u = 8,
    control_x = 9,
};

const DflAction = enum {
    terminate,
    ignore,
    stop,
};

const SignalDescriptor = struct {
    signo: c_int,
    name: [*:0]const u8,
    action: DflAction,
    flags: u32,
};

const flag_noignore: u32 = 1;
const flag_noblock: u32 = 2;
const flag_nocatch: u32 = 4;
const flag_core_dump: u32 = 8;
const flag_async: u32 = 16;

const control_b_interrupt_char: u8 = 'B';
const control_g_interrupt_char: u8 = 'G';
const control_u_interrupt_char: u8 = 'U';
const control_x_interrupt_char: u8 = 'X';
const alert_char: u8 = '\x07';

const sig_dfl: TsignalHandler = null;
const sig_ign: TsignalHandler = @ptrFromInt(1);

const use_within_c_stack = !builtin.is_test and build_options.cc_is_native and !builtin.os.tag.isDarwin() and
    (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86);

pub var stop_signal_hook_storage: ?*const fn (c_int) callconv(.c) void = null;
pub var subprocess_death_hook_storage: ?*const fn (abi.PidT, *c_int) callconv(.c) void = null;

var blocked_signals: std.c.sigset_t = std.mem.zeroes(std.c.sigset_t);
var signal_descriptors_ptr: ?[*]SignalDescriptor = null;
var signal_descriptors_length: usize = 0;
var signal_descriptors_limit: usize = 0;
var unknown_signal_buf: [32]u8 = @splat(0);

extern "c" fn nice(incr: c_int) c_int;

inline fn sigNum(comptime name: []const u8) c_int {
    if (@hasField(std.c.SIG, name)) {
        return @intCast(@backingInt(@field(std.c.SIG, name)));
    } else if (@hasDecl(std.c.SIG, name)) {
        return @intCast(@backingInt(@field(std.c.SIG, name)));
    }
    return 0;
}

inline fn stopSignalHookSlot() *?*const fn (c_int) callconv(.c) void {
    return if (builtin.is_test) &abi.stop_signal_hook else &stop_signal_hook_storage;
}

inline fn subprocessDeathHookSlot() *?*const fn (abi.PidT, *c_int) callconv(.c) void {
    return if (builtin.is_test) &abi.subprocess_death_hook else &subprocess_death_hook_storage;
}

fn writeStream(stream: *std.c.FILE, slice: []const u8) void {
    _ = std.c.fwrite(slice.ptr, 1, slice.len, stream);
}

fn writeByte(stream: *std.c.FILE, byte: u8) void {
    const buf = [1]u8{byte};
    _ = std.c.fwrite(&buf, 1, 1, stream);
}

fn writeFmt(stream: *std.c.FILE, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStream(stream, msg);
}

fn currentHandler(signo: c_int) TsignalHandler {
    if (signo <= 0) return sig_dfl;
    var act: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    if (std.c.sigaction(@fromBackingInt(@intCast(@as(u32, @intCast(signo)))), null, &act) < 0) return sig_dfl;
    return @ptrCast(act.handler.handler);
}

/// Install POSIX signal handler `handler` for `signo` (`INSTALL_HANDLER`).
pub fn installHandler(signo: c_int, handler: TsignalHandler) callconv(.c) void {
    var act: std.c.Sigaction = .{
        .handler = undefined,
        .mask = undefined,
        .flags = 0,
    };
    if (handler == sig_ign or handler == sig_dfl) {
        act.handler = .{ .handler = @ptrCast(handler) };
        act.flags = 0;
    } else {
        act.handler = .{ .sigaction = @ptrCast(@alignCast(handler)) };
        act.flags = std.c.SA.SIGINFO | (if (builtin.os.tag.isDarwin()) std.c.SA.@"64REGSET" else 0);
    }
    _ = std.c.sigemptyset(&act.mask);
    const sig: std.c.SIG = @fromBackingInt(@intCast(@as(u32, @intCast(signo))));
    _ = std.c.sigaddset(&act.mask, sig);
    _ = std.c.sigaction(sig, &act, null);
}

fn restoreSignalMask(environment: ?*anyopaque) callconv(.c) void {
    const mask: *const std.c.sigset_t = @ptrCast(@alignCast(environment.?));
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, mask, null);
}

fn saveSignalMask(environment: ?*anyopaque) callconv(.c) void {
    const mask: *std.c.sigset_t = @ptrCast(@alignCast(environment.?));
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, null, mask);
}

/// Save current process signal mask on dstack so it is restored on unwind (`preserve_signal_mask`).
pub fn preserveSignalMask() callconv(.c) void {
    wind.dstack_alloc_and_protect(@sizeOf(std.c.sigset_t), &saveSignalMask, &restoreSignalMask);
}

/// Block all signals and stash the previous mask (`block_signals`).
pub fn blockSignals() callconv(.c) void {
    var all_signals: std.c.sigset_t = undefined;
    _ = std.c.sigfillset(&all_signals);
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, &all_signals, &blocked_signals);
}

/// Restore the signal mask saved by `blockSignals` (`unblock_signals`).
pub fn unblockSignals() callconv(.c) void {
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, &blocked_signals, null);
}

/// Ignore signal `signo` (`deactivate_handler`).
pub fn deactivateHandler(signo: c_int) callconv(.c) void {
    installHandler(signo, sig_ign);
}

/// Activate `handler` for `signo` (`activate_handler`).
pub fn activateHandler(signo: c_int, handler: TsignalHandler) callconv(.c) void {
    installHandler(signo, handler);
}

fn defsignal(signo: c_int, name: [*:0]const u8, action: DflAction, flags: u32) void {
    if (signo == 0) return;
    if (signal_descriptors_length == signal_descriptors_limit) {
        signal_descriptors_limit += 8;
        const raw = std.c.realloc(@ptrCast(signal_descriptors_ptr), signal_descriptors_limit * @sizeOf(SignalDescriptor)) orelse {
            const err_stream = abi.cStderr();
            writeStream(err_stream, "\nUnable to grow signal definitions table.\n");
            _ = abi.fflush(err_stream);
            abi.termination_init_error();
        };
        signal_descriptors_ptr = @ptrCast(@alignCast(raw));
    }
    signal_descriptors_ptr.?[signal_descriptors_length] = .{
        .signo = signo,
        .name = name,
        .action = action,
        .flags = flags,
    };
    signal_descriptors_length += 1;
}

fn findSignalDescriptor(signo: c_int) ?*const SignalDescriptor {
    const ptr = signal_descriptors_ptr orelse return null;
    for (ptr[0..signal_descriptors_length]) |*sd| {
        if (sd.signo == signo) return sd;
    }
    return null;
}

/// Return static printable name for POSIX signal `signo` (`find_signal_name`).
pub fn findSignalName(signo: c_int) callconv(.c) [*:0]const u8 {
    if (findSignalDescriptor(signo)) |sd| return sd.name;
    const msg = std.fmt.bufPrint(unknown_signal_buf[0 .. unknown_signal_buf.len - 1], "unknown signal {d}", .{signo}) catch "unknown signal";
    unknown_signal_buf[msg.len] = 0;
    return @ptrCast(&unknown_signal_buf);
}

/// Invoke `func` once for each registered asynchronous signal (`foreach_async_signal`).
pub fn foreachAsyncSignal(func: *const fn (c_int) callconv(.c) void) callconv(.c) void {
    const ptr = signal_descriptors_ptr orelse return;
    for (ptr[0..signal_descriptors_length]) |sd| {
        if ((sd.flags & flag_async) != 0) func(sd.signo);
    }
}

pub fn initializeSignalDescriptors() void {
    signal_descriptors_length = 0;
    signal_descriptors_limit = 32;
    if (signal_descriptors_ptr == null) {
        const raw = std.c.malloc(signal_descriptors_limit * @sizeOf(SignalDescriptor)) orelse {
            const err_stream = abi.cStderr();
            writeStream(err_stream, "\nUnable to allocate signal definitions table.\n");
            _ = abi.fflush(err_stream);
            abi.termination_init_error();
        };
        signal_descriptors_ptr = @ptrCast(@alignCast(raw));
    }

    const sigabrt = if (sigNum("ABRT") == sigNum("IOT")) 0 else sigNum("ABRT");
    defsignal(sigNum("HUP"), "SIGHUP", .terminate, flag_async);
    defsignal(sigNum("INT"), "SIGINT", .terminate, flag_async);
    defsignal(sigNum("QUIT"), "SIGQUIT", .terminate, flag_async | flag_core_dump);
    defsignal(sigNum("ILL"), "SIGILL", .terminate, flag_core_dump);
    defsignal(sigNum("TRAP"), "SIGTRAP", .terminate, flag_core_dump);
    defsignal(sigNum("IOT"), "SIGIOT", .terminate, flag_core_dump);
    defsignal(sigNum("EMT"), "SIGEMT", .terminate, flag_core_dump);
    defsignal(sigNum("FPE"), "SIGFPE", .terminate, flag_core_dump);
    defsignal(sigNum("KILL"), "SIGKILL", .terminate, flag_noignore | flag_noblock | flag_nocatch);
    defsignal(sigNum("BUS"), "SIGBUS", .terminate, flag_core_dump);
    defsignal(sigNum("SEGV"), "SIGSEGV", .terminate, flag_core_dump);
    defsignal(sigNum("SYS"), "SIGSYS", .terminate, flag_core_dump);
    defsignal(sigNum("PIPE"), "SIGPIPE", .terminate, 0);
    defsignal(sigNum("ALRM"), "SIGALRM", .terminate, flag_async);
    defsignal(sigNum("TERM"), "SIGTERM", .terminate, flag_async | flag_nocatch);
    defsignal(sigNum("USR1"), "SIGUSR1", .terminate, flag_async);
    defsignal(sigNum("USR2"), "SIGUSR2", .terminate, flag_async);
    defsignal(sigabrt, "SIGABRT", .terminate, flag_async | flag_core_dump);
    defsignal(sigNum("IO"), "SIGIO", .ignore, flag_async);
    defsignal(sigNum("URG"), "SIGURG", .ignore, flag_async);
    defsignal(sigNum("VTALRM"), "SIGVTALRM", .terminate, flag_async);
    defsignal(sigNum("PROF"), "SIGPROF", .terminate, 0);
    defsignal(sigNum("STOP"), "SIGSTOP", .stop, flag_noignore | flag_noblock | flag_nocatch);
    defsignal(sigNum("TSTP"), "SIGTSTP", .stop, flag_async);
    defsignal(sigNum("CONT"), "SIGCONT", .ignore, flag_noignore | flag_noblock);
    defsignal(sigNum("CHLD"), "SIGCHLD", .ignore, flag_async);
    defsignal(sigNum("TTIN"), "SIGTTIN", .stop, flag_async);
    defsignal(sigNum("TTOU"), "SIGTTOU", .stop, flag_async);
    defsignal(sigNum("LOST"), "SIGLOST", .terminate, flag_async);
    defsignal(sigNum("XCPU"), "SIGXCPU", .terminate, flag_async);
    defsignal(sigNum("XFSZ"), "SIGXFSZ", .terminate, flag_async);
    defsignal(sigNum("PWR"), "SIGPWR", .ignore, flag_async);
    defsignal(sigNum("WINDOW"), "SIGWINDOW", .ignore, flag_async);
    defsignal(sigNum("WINCH"), "SIGWINCH", .ignore, flag_async);
}

fn makeStdHandler(comptime body: fn (c_int, ?*std.c.siginfo_t, ?*anyopaque) void) fn (c_int, ?*std.c.siginfo_t, ?*anyopaque) callconv(.c) void {
    return struct {
        fn callBody(signo: c_int, info: ?*std.c.siginfo_t, pscp: ?*anyopaque) void {
            const abortp = abi.enter_interruption_extent();
            body(signo, info, pscp);
            if (abortp != 0) abi.exit_interruption_extent();
        }

        fn handler(signo: c_int, info: ?*std.c.siginfo_t, pscp: ?*anyopaque) callconv(.c) void {
            if (use_within_c_stack) {
                const NativeStack = struct {
                    const SignalInstance = struct {
                        signo: c_int,
                        info: ?*std.c.siginfo_t,
                        pscp: ?*anyopaque,
                    };
                    extern "c" fn within_c_stack(
                        func: *const fn (?*anyopaque) callconv(.c) void,
                        cookie: ?*anyopaque,
                    ) void;

                    fn wrapper(ctx: ?*anyopaque) callconv(.c) void {
                        const inst: *const SignalInstance = @ptrCast(@alignCast(ctx.?));
                        callBody(inst.signo, inst.info, inst.pscp);
                    }
                };
                var inst: NativeStack.SignalInstance = .{
                    .signo = signo,
                    .info = info,
                    .pscp = pscp,
                };
                NativeStack.within_c_stack(&NativeStack.wrapper, @ptrCast(&inst));
            } else {
                callBody(signo, info, pscp);
            }
        }
    }.handler;
}

fn echoKeyboardInterrupt(c_in: abi.CcT, dc: abi.CcT) void {
    var c = if (c_in == abi.OS_ctty_disabled_char()) dc else c_in;
    c &= 0o177;
    const out = abi.cStdout();
    if (c == alert_char) {
        writeByte(out, c);
    } else if (c < 0o040) {
        writeByte(out, '^');
        writeByte(out, c + '@');
    } else if (c == 0o177) {
        writeStream(out, "^?");
    } else {
        writeByte(out, c);
    }
    _ = abi.fflush(out);
}

fn bodyControlG(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    echoKeyboardInterrupt(abi.OS_ctty_int_char(), alert_char);
    ostty.tty_set_next_interrupt_char(control_g_interrupt_char);
}

fn bodyControlU(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    ostty.tty_set_next_interrupt_char(control_u_interrupt_char);
}

fn bodyControlX(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    ostty.tty_set_next_interrupt_char(control_x_interrupt_char);
}

fn bodyControlB(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    ostty.tty_set_next_interrupt_char(control_b_interrupt_char);
}

fn bodyInteractive(_: c_int, _: ?*std.c.siginfo_t, pscp: ?*anyopaque) void {
    interactiveInterruptHandler(pscp);
}

/// Suspend Scheme cleanly with terminal state handoff and default stop action (`stop_signal_default`).
pub fn stopSignalDefault(signo: c_int) callconv(.c) void {
    if (std.c.isatty(std.c.STDIN_FILENO) != 0 and
        std.c.isatty(std.c.STDOUT_FILENO) != 0 and
        !option.option_emacs_subprocess)
    {
        abi.OS_save_internal_state();
        abi.OS_restore_external_state();

        const handler = currentHandler(signo);
        installHandler(signo, sig_dfl);

        var signo_mask: std.c.sigset_t = undefined;
        var old_mask: std.c.sigset_t = undefined;
        _ = std.c.sigemptyset(&signo_mask);
        _ = std.c.sigaddset(&signo_mask, @fromBackingInt(@intCast(@as(u32, @intCast(signo)))));
        _ = std.c.sigprocmask(std.c.SIG.UNBLOCK, &signo_mask, &old_mask);
        _ = std.c.kill(std.c.getpid(), @fromBackingInt(@intCast(@as(u32, @intCast(signo)))));
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &old_mask, null);

        installHandler(signo, handler);

        abi.OS_save_external_state();
        abi.OS_restore_internal_state();
    }
}

fn bodyStop(signo: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    var jc_mask: std.c.sigset_t = undefined;
    var old_mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&jc_mask);
    _ = std.c.sigaddset(&jc_mask, .TTOU);
    _ = std.c.sigaddset(&jc_mask, .TTIN);
    _ = std.c.sigaddset(&jc_mask, .TSTP);
    _ = std.c.sigaddset(&jc_mask, .STOP);
    _ = std.c.sigaddset(&jc_mask, .CHLD);
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, &jc_mask, &old_mask);

    if (stopSignalHookSlot().*) |hook| {
        hook(signo);
    } else {
        stopSignalDefault(signo);
    }

    _ = std.c.sigprocmask(std.c.SIG.SETMASK, &old_mask, null);
}

/// Suspend Scheme using `SIGTSTP` (`OS_restartable_exit`).
pub fn osRestartableExit() callconv(.c) void {
    stopSignalDefault(@backingInt(std.c.SIG.TSTP));
}

fn bodyConsoleResize(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    abi.UX_reinitialize_tty();
    osscheme.request_console_resize_interrupt();
}

fn bodyTimer(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    osscheme.request_timer_interrupt();
}

fn bodySaveThenTerminate(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    osscheme.request_suspend_interrupt();
}

fn bodyTerminate(signo: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    abi.termination_signal(findSignalName(signo));
}

fn bodyFpe(signo: c_int, info: ?*std.c.siginfo_t, pscp: ?*anyopaque) void {
    floenv.clear_float_exceptions();
    abi.trap_handler("floating-point exception", signo, info, pscp);
}

fn bodyHardwareTrap(signo: c_int, info: ?*std.c.siginfo_t, pscp: ?*anyopaque) void {
    abi.trap_handler("hardware fault", signo, info, pscp);
}

fn bodySoftwareTrap(signo: c_int, info: ?*std.c.siginfo_t, pscp: ?*anyopaque) void {
    abi.trap_handler("system software fault", signo, info, pscp);
}

fn bodyRenice(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    const err_stream = abi.cStderr();
    writeFmt(err_stream, "\n;;; Renicing! New nice value = {d}\n", .{nice(5) + 20});
    _ = abi.fflush(err_stream);
}

fn bodyDeadSubprocess(_: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) void {
    while (true) {
        var status: c_int = 0;
        const pid = std.c.waitpid(-1, &status, std.c.W.NOHANG | std.c.W.UNTRACED);
        if (pid <= 0) break;
        if (subprocessDeathHookSlot().*) |hook| {
            hook(pid, &status);
        }
    }
}

const sighnd_control_g = makeStdHandler(bodyControlG);
const sighnd_control_u = makeStdHandler(bodyControlU);
const sighnd_control_x = makeStdHandler(bodyControlX);
const sighnd_control_b = makeStdHandler(bodyControlB);
const sighnd_interactive = makeStdHandler(bodyInteractive);
const sighnd_stop = makeStdHandler(bodyStop);
const sighnd_console_resize = makeStdHandler(bodyConsoleResize);
const sighnd_timer = makeStdHandler(bodyTimer);
const sighnd_save_then_terminate = makeStdHandler(bodySaveThenTerminate);
const sighnd_terminate = makeStdHandler(bodyTerminate);
const sighnd_fpe = makeStdHandler(bodyFpe);
const sighnd_hardware_trap = makeStdHandler(bodyHardwareTrap);
const sighnd_software_trap = makeStdHandler(bodySoftwareTrap);
const sighnd_renice = makeStdHandler(bodyRenice);
const sighnd_dead_subprocess = makeStdHandler(bodyDeadSubprocess);

fn bindHandler(signo: c_int, handler: TsignalHandler) void {
    if (signo == 0) return;
    const old_handler = currentHandler(signo);
    if (old_handler == sig_dfl or (old_handler == sig_ign and signo == sigNum("CHLD"))) {
        installHandler(signo, handler);
    }
}

fn unblockAllSignals() void {
    var empty_mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&empty_mask);
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, &empty_mask, null);
}

/// Initialize signal descriptors, default signal handlers, and unmask signals (`UX_initialize_signals`).
pub fn uxInitializeSignals() callconv(.c) void {
    stopSignalHookSlot().* = null;
    subprocessDeathHookSlot().* = null;
    initializeSignalDescriptors();

    bindHandler(sigNum("INT"), &sighnd_control_g);
    bindHandler(sigNum("FPE"), &sighnd_fpe);
    bindHandler(sigNum("ALRM"), &sighnd_timer);
    bindHandler(sigNum("VTALRM"), &sighnd_timer);
    bindHandler(sigNum("USR1"), &sighnd_save_then_terminate);
    bindHandler(sigNum("USR2"), &sighnd_renice);
    bindHandler(sigNum("CHLD"), &sighnd_dead_subprocess);
    bindHandler(sigNum("PIPE"), sig_ign);

    if (std.c.isatty(std.c.STDIN_FILENO) != 0 or option.option_emacs_subprocess) {
        const schematik = std.c.getenv("USE_SCHEMATIK_STYLE_INTERRUPTS") != null;
        if (schematik) bindHandler(sigNum("HUP"), &sighnd_control_b);
        bindHandler(sigNum("QUIT"), if (schematik) &sighnd_control_u else &sighnd_interactive);
        bindHandler(sigNum("PWR"), &sighnd_save_then_terminate);
        bindHandler(sigNum("TSTP"), &sighnd_stop);
        bindHandler(sigNum("ILL"), &sighnd_hardware_trap);
        bindHandler(sigNum("TRAP"), &sighnd_hardware_trap);
        bindHandler(sigNum("BUS"), &sighnd_hardware_trap);
        bindHandler(sigNum("SEGV"), &sighnd_hardware_trap);
        bindHandler(sigNum("IOT"), if (schematik) &sighnd_control_x else &sighnd_software_trap);
        bindHandler(sigNum("EMT"), &sighnd_software_trap);
        bindHandler(sigNum("SYS"), &sighnd_software_trap);
        bindHandler(sigNum("ABRT"), &sighnd_software_trap);
        bindHandler(sigNum("PROF"), &sighnd_software_trap);
        bindHandler(sigNum("WINCH"), &sighnd_console_resize);
    }

    if (signal_descriptors_ptr) |ptr| {
        for (ptr[0..signal_descriptors_length]) |sd| {
            if ((sd.flags & flag_nocatch) == 0) {
                switch (sd.action) {
                    .terminate => bindHandler(sd.signo, &sighnd_terminate),
                    .stop => bindHandler(sd.signo, &sighnd_stop),
                    .ignore => {},
                }
            }
        }
    }
    unblockAllSignals();
}

/// Reset signal mask and restore `SIGPIPE` to `SIG_DFL` in child processes (`UX_initialize_child_signals`).
pub fn uxInitializeChildSignals() callconv(.c) void {
    unblockAllSignals();
    installHandler(sigNum("PIPE"), sig_dfl);
}

/// Identity-map raw Unix interrupt character for OS-independent layer (`OS_tty_map_interrupt_char`).
pub fn osTtyMapInterruptChar(int_char: abi.CcT) callconv(.c) abi.CcT {
    return int_char;
}

fn interactiveNewline() void {
    if (!option.option_emacs_subprocess) {
        const out = abi.cStdout();
        writeByte(out, '\n');
        _ = abi.fflush(out);
    }
}

fn interactiveInterruptHandler(scp: ?*anyopaque) void {
    const out = abi.cStdout();
    if (!option.option_emacs_subprocess) {
        writeStream(out, std.mem.span(abi.OS_tty_command_beep()));
        writeByte(out, '\n');
        _ = abi.fflush(out);
    }
    while (true) {
        if (!option.option_emacs_subprocess) {
            writeStream(out, "Interrupt option (? for help): ");
            _ = abi.fflush(out);
        }
        switch (abi.userio_read_char_raw()) {
            0o002, 'B', 'b' => {
                ostty.tty_set_next_interrupt_char(control_b_interrupt_char);
                return;
            },
            0o003, 0o007, 'G', 'g' => {
                ostty.tty_set_next_interrupt_char(control_g_interrupt_char);
                return;
            },
            0o025, 'U', 'u' => {
                ostty.tty_set_next_interrupt_char(control_u_interrupt_char);
                return;
            },
            0o030, 'X', 'x' => {
                ostty.tty_set_next_interrupt_char(control_x_interrupt_char);
                return;
            },
            'E', 'e' => {
                interactiveNewline();
                examineMemory();
                return;
            },
            'D', 'd' => {
                interactiveNewline();
                debug.debug_edit_flags();
                return;
            },
            'T', 't' => {
                interactiveNewline();
                interactiveBackTrace();
                return;
            },
            'Z', 'z' => {
                interactiveNewline();
                abi.OS_restartable_exit();
                return;
            },
            'Q', 'q' => {
                interactiveNewline();
                abi.termination_normal(0);
            },
            '\x0c' => {
                if (!option.option_emacs_subprocess) {
                    writeStream(out, std.mem.span(abi.OS_tty_command_clear()));
                    _ = abi.fflush(out);
                }
                return;
            },
            'R', 'r' => {
                resetQuery(scp);
                return;
            },
            'H', 'h' => {
                if (!option.option_emacs_subprocess) printInterruptChars();
            },
            'I', 'i' => {
                if (!option.option_emacs_subprocess) {
                    writeStream(out, "Ignored.  Resuming Scheme.\n");
                    _ = abi.fflush(out);
                }
                return;
            },
            0 => {
                if (std.c._errno().* != 0) {
                    const err_stream = abi.cStderr();
                    writeStream(err_stream, "Problems reading keyboard input -- Exitting.\n");
                    abi.termination_eof();
                }
                if (!option.option_emacs_subprocess) printInteractiveHelp();
            },
            else => {
                if (!option.option_emacs_subprocess) printInteractiveHelp();
            },
        }
    }
}

pub fn encodeInterruptHandler(handler: TsignalHandler) InterruptHandler {
    if (handler == @as(TsignalHandler, @ptrCast(&sighnd_control_g))) return .control_g;
    if (handler == @as(TsignalHandler, @ptrCast(&sighnd_interactive))) return .interactive;
    if (handler == @as(TsignalHandler, @ptrCast(&sighnd_stop))) return .stop;
    if (handler == @as(TsignalHandler, @ptrCast(&sighnd_terminate))) return .terminate;
    if (handler == sig_ign) return .ignore;
    if (handler == sig_dfl) return .default;
    return .unknown;
}

pub fn decodeInterruptHandler(encoding: InterruptHandler) TsignalHandler {
    return switch (encoding) {
        .control_g => @ptrCast(&sighnd_control_g),
        .interactive => @ptrCast(&sighnd_interactive),
        .stop => @ptrCast(&sighnd_stop),
        .terminate => @ptrCast(&sighnd_terminate),
        .ignore => sig_ign,
        .default => sig_dfl,
        else => null,
    };
}

/// Return current interrupt handler encoding for `SIGQUIT` (`OS_signal_quit_handler`).
pub fn osSignalQuitHandler() callconv(.c) InterruptHandler {
    return encodeInterruptHandler(currentHandler(@backingInt(std.c.SIG.QUIT)));
}

/// Return current interrupt handler encoding for `SIGINT` (`OS_signal_int_handler`).
pub fn osSignalIntHandler() callconv(.c) InterruptHandler {
    return encodeInterruptHandler(currentHandler(@backingInt(std.c.SIG.INT)));
}

/// Return current interrupt handler encoding for `SIGTSTP` (`OS_signal_tstp_handler`).
pub fn osSignalTstpHandler() callconv(.c) InterruptHandler {
    return encodeInterruptHandler(currentHandler(@backingInt(std.c.SIG.TSTP)));
}

/// Install encoded interrupt handlers for `SIGQUIT`, `SIGINT`, and `SIGTSTP` (`OS_signal_set_interrupt_handlers`).
pub fn osSignalSetInterruptHandlers(
    quit_handler: InterruptHandler,
    int_handler: InterruptHandler,
    tstp_handler: InterruptHandler,
) callconv(.c) void {
    if (decodeInterruptHandler(quit_handler)) |h| {
        installHandler(@backingInt(std.c.SIG.QUIT), h);
    } else if (quit_handler == .default) {
        installHandler(@backingInt(std.c.SIG.QUIT), sig_dfl);
    }
    if (decodeInterruptHandler(int_handler)) |h| {
        installHandler(@backingInt(std.c.SIG.INT), h);
    } else if (int_handler == .default) {
        installHandler(@backingInt(std.c.SIG.INT), sig_dfl);
    }
    if (decodeInterruptHandler(tstp_handler)) |h| {
        installHandler(@backingInt(std.c.SIG.TSTP), h);
    } else if (tstp_handler == .default) {
        installHandler(@backingInt(std.c.SIG.TSTP), sig_dfl);
    }
}

fn describeSighnd(signo: c_int, c: u8) void {
    const out = abi.cStdout();
    var resolved = encodeInterruptHandler(currentHandler(signo));
    if (resolved == .default) {
        if (findSignalDescriptor(signo)) |sd| {
            resolved = switch (sd.action) {
                .ignore => .ignore,
                .stop => .stop,
                .terminate => .terminate,
            };
        }
    }
    switch (resolved) {
        .control_g => writeStream(out, "When typed, scheme will get the ^G character interrupt.\nThe default action is to abort the running program,\nand to resume the top level read-eval-print loop.\n"),
        .interactive => {
            writeStream(out, "When typed, various interrupt options are offered.\n");
            writeFmt(out, "Type {s} followed by `?' for a list of options.\n", .{std.mem.span(abi.char_description(c, 0))});
        },
        .terminate => writeStream(out, "When typed, scheme will terminate.\n"),
        .stop => writeStream(out, "When typed, scheme will suspend execution.\n"),
        .ignore => writeStream(out, "When typed, this character will be ignored.\n"),
        else => writeStream(out, "When typed, this character will have an unknown effect.\n"),
    }
}

fn printInterruptChars() void {
    const out = abi.cStdout();
    const quit_char = abi.OS_ctty_quit_char();
    writeFmt(out, "\n\nThe quit character is {s}.\n", .{std.mem.span(abi.char_description(quit_char, 1))});
    describeSighnd(@backingInt(std.c.SIG.QUIT), quit_char);

    const int_char = abi.OS_ctty_int_char();
    writeFmt(out, "\nThe interrupt character is {s}.\n", .{std.mem.span(abi.char_description(int_char, 1))});
    describeSighnd(@backingInt(std.c.SIG.INT), int_char);

    const tstp_char = abi.OS_ctty_tstp_char();
    writeFmt(out, "\nThe terminal stop character is {s}.\n", .{std.mem.span(abi.char_description(tstp_char, 1))});
    describeSighnd(@backingInt(std.c.SIG.TSTP), tstp_char);

    writeByte(out, '\n');
    _ = abi.fflush(out);
}

fn printInteractiveHelp() void {
    const out = abi.cStdout();
    writeStream(
        out,
        "\n\n" ++
            "^B: Enter a breakpoint loop.\n" ++
            "^C: Goto to top level read-eval-print (REP) loop.\n" ++
            "^L: Clear the screen.\n" ++
            "^U: Up to previous (lower numbered) REP loop.\n" ++
            "^X: Abort to current REP loop.\n" ++
            "D: Debugging: change interpreter flags.\n" ++
            "E: Examine memory location.\n" ++
            "H: Print simple information on interrupts.\n" ++
            "I: Ignore interrupt request.\n" ++
            "Q: Quit instantly, killing Scheme.\n" ++
            "R: Hard reset, possibly killing Scheme in the process.\n" ++
            "T: Stack trace.\n" ++
            "Z: Quit instantly, suspending Scheme.\n\n",
    );
}

fn invokeSoftReset(_: ?*const anyopaque) callconv(.c) void {
    abi.soft_reset();
}

fn resetQuery(scp: ?*anyopaque) void {
    const out = abi.cStdout();
    writeByte(out, '\n');
    _ = abi.fflush(out);
    if (boot.critical_section_name) |cs_name| {
        const reset_choices = [_]?[*:0]const u8{
            "D = delay reset until the end of the critical section",
            "N = attempt reset now",
            "P = punt reset",
            null,
        };
        writeFmt(out, "Scheme is executing within critical section \"{s}\".\n", .{std.mem.span(cs_name)});
        writeStream(out, "Resetting now is likely to kill Scheme.\n");
        _ = abi.fflush(out);
        switch (abi.userio_choose_option("Choose one of the following actions:", "Action -> ", &reset_choices)) {
            0 => {
                writeStream(abi.cStderr(), "Problems reading keyboard input -- exitting.\n");
                abi.termination_eof();
            },
            'D' => {
                boot.critical_section_hook = @ptrCast(&invokeSoftReset);
                boot.critical_section_hook_p = true;
                return;
            },
            'N' => {
                boot.critical_section_hook_p = false;
                boot.critical_section_name = null;
                abi.hard_reset(scp);
            },
            else => return,
        }
    }
    if (abi.userio_confirm("Do you really want to reset? [Y or N] ") != 0) {
        abi.hard_reset(scp);
    }
}

const userio_read_line_ok: c_int = 0;
const userio_read_line_too_long: c_int = 1;
const userio_read_line_input_failed: c_int = 2;

fn userioReadLine(line: []u8) c_int {
    var result = userio_read_line_too_long;
    transact.transaction_begin();
    abi.userio_buffered_input();
    for (line) |*slot| {
        var c = abi.userio_read_char();
        if (c == 0 and std.c._errno().* != 0) {
            result = userio_read_line_input_failed;
            break;
        }
        if (c == '\n') c = 0;
        slot.* = c;
        if (c == 0) {
            result = userio_read_line_ok;
            break;
        }
    }
    transact.transaction_commit();
    return result;
}

pub fn parseLongInput(raw: []const u8) ?isize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len > 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) {
        const uval = std.fmt.parseInt(usize, trimmed[2..], 16) catch return null;
        return @bitCast(uval);
    }
    return std.fmt.parseInt(isize, trimmed, 10) catch null;
}

fn examineMemory() void {
    var input_string: [256]u8 = undefined;
    const out = abi.cStdout();
    writeStream(out, "Enter location to examine (0x prefix for hex): ");
    _ = abi.fflush(out);
    if (userioReadLine(&input_string) == userio_read_line_input_failed) {
        writeStream(abi.cStderr(), "Problems reading keyboard input -- exiting.\n");
        abi.termination_eof();
    }
    const slice = std.mem.sliceTo(&input_string, 0);
    if (parseLongInput(slice)) |val| {
        osscheme.debug_examine_memory(val, "contents");
    }
    writeByte(out, '\n');
    _ = abi.fflush(out);
}

/// Close a C `FILE *` stream on transaction unwind (`eta_fclose`).
pub fn etaFclose(stream: ?*anyopaque) callconv(.c) void {
    if (stream) |s| {
        _ = std.c.fclose(@ptrCast(@alignCast(s)));
    }
}

fn interactiveBackTrace() void {
    var input_string: [256]u8 = undefined;
    const out = abi.cStdout();
    writeStream(out, "Enter the stack trace filename (default: terminal): ");
    _ = abi.fflush(out);
    if (userioReadLine(&input_string) == userio_read_line_input_failed) {
        writeStream(abi.cStderr(), "Problems reading keyboard input -- exiting.\n");
        abi.termination_eof();
    }
    interactiveNewline();
    const filename = std.mem.sliceTo(&input_string, 0);
    if (filename.len == 0) {
        osscheme.debug_back_trace(outf.console_output);
        return;
    }
    transact.transaction_begin();
    const fname_z: [*:0]const u8 = @ptrCast(input_string[0..filename.len :0]);
    const to_dump = std.c.fopen(fname_z, "w") orelse {
        outf.err("Error opening \"{s}\".\n", .{fname_z});
        transact.transaction_abort();
        return;
    };
    transact.transaction_record_action(.tat_always, &etaFclose, @ptrCast(to_dump));
    outf.console("Writing the stack trace to file \"{s}\" -- ", .{fname_z});
    outf.flushConsole();
    osscheme.debug_back_trace(outf.fileOutput(to_dump));
    outf.console("Done.\n", .{});
    outf.flushConsole();
    transact.transaction_commit();
}

comptime {
    if (!builtin.is_test) {
        @export(&stop_signal_hook_storage, .{ .name = "stop_signal_hook" });
        @export(&subprocess_death_hook_storage, .{ .name = "subprocess_death_hook" });
        @export(&installHandler, .{ .name = "INSTALL_HANDLER" });
        @export(&preserveSignalMask, .{ .name = "preserve_signal_mask" });
        @export(&blockSignals, .{ .name = "block_signals" });
        @export(&unblockSignals, .{ .name = "unblock_signals" });
        @export(&deactivateHandler, .{ .name = "deactivate_handler" });
        @export(&activateHandler, .{ .name = "activate_handler" });
        @export(&findSignalName, .{ .name = "find_signal_name" });
        @export(&foreachAsyncSignal, .{ .name = "foreach_async_signal" });
        @export(&stopSignalDefault, .{ .name = "stop_signal_default" });
        @export(&osRestartableExit, .{ .name = "OS_restartable_exit" });
        @export(&uxInitializeSignals, .{ .name = "UX_initialize_signals" });
        @export(&uxInitializeChildSignals, .{ .name = "UX_initialize_child_signals" });
        @export(&osTtyMapInterruptChar, .{ .name = "OS_tty_map_interrupt_char" });
        @export(&osSignalQuitHandler, .{ .name = "OS_signal_quit_handler" });
        @export(&osSignalIntHandler, .{ .name = "OS_signal_int_handler" });
        @export(&osSignalTstpHandler, .{ .name = "OS_signal_tstp_handler" });
        @export(&osSignalSetInterruptHandlers, .{ .name = "OS_signal_set_interrupt_handlers" });
        @export(&etaFclose, .{ .name = "eta_fclose" });
    }
}

fn countAsyncSig(_: c_int) callconv(.c) void {
    async_sig_counter += 1;
}

var async_sig_counter: usize = 0;

test "uxsig signal descriptors handlers masks parseLongInput and etaFclose" {
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    defer {
        transact.transaction_initialize();
        wind.dstack_reset();
    }

    initializeSignalDescriptors();
    try std.testing.expectEqualStrings("SIGINT", std.mem.span(findSignalName(@backingInt(std.c.SIG.INT))));
    try std.testing.expectEqualStrings("SIGIOT", std.mem.span(findSignalName(@backingInt(std.c.SIG.ABRT))));
    try std.testing.expectEqualStrings("SIGSEGV", std.mem.span(findSignalName(@backingInt(std.c.SIG.SEGV))));
    try std.testing.expectEqualStrings("unknown signal 999", std.mem.span(findSignalName(999)));

    async_sig_counter = 0;
    foreachAsyncSignal(&countAsyncSig);
    try std.testing.expect(async_sig_counter >= 10);

    try std.testing.expectEqual(@as(abi.CcT, 'G'), osTtyMapInterruptChar('G'));
    for ([_]InterruptHandler{ .control_g, .interactive, .stop, .terminate, .ignore, .default }) |h| {
        try std.testing.expectEqual(h, encodeInterruptHandler(decodeInterruptHandler(h)));
    }
    try std.testing.expectEqual(@as(TsignalHandler, null), decodeInterruptHandler(.unknown));

    const usr2_sig = @backingInt(std.c.SIG.USR2);
    var saved_usr2: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    try std.testing.expectEqual(@as(c_int, 0), std.c.sigaction(.USR2, null, &saved_usr2));
    defer _ = std.c.sigaction(.USR2, &saved_usr2, null);

    deactivateHandler(usr2_sig);
    try std.testing.expectEqual(InterruptHandler.ignore, encodeInterruptHandler(currentHandler(usr2_sig)));
    activateHandler(usr2_sig, &sighnd_control_g);
    try std.testing.expectEqual(InterruptHandler.control_g, encodeInterruptHandler(currentHandler(usr2_sig)));

    const pipe_sig = @backingInt(std.c.SIG.PIPE);
    var saved_pipe: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    try std.testing.expectEqual(@as(c_int, 0), std.c.sigaction(.PIPE, null, &saved_pipe));
    defer _ = std.c.sigaction(.PIPE, &saved_pipe, null);

    installHandler(pipe_sig, sig_ign);
    try std.testing.expectEqual(sig_ign, currentHandler(pipe_sig));
    uxInitializeChildSignals();
    try std.testing.expectEqual(sig_dfl, currentHandler(pipe_sig));

    var saved_mask: std.c.sigset_t = undefined;
    _ = std.c.sigprocmask(std.c.SIG.SETMASK, null, &saved_mask);
    defer _ = std.c.sigprocmask(std.c.SIG.SETMASK, &saved_mask, null);

    blockSignals();
    unblockSignals();

    transact.transaction_begin();
    preserveSignalMask();
    var usr2_mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&usr2_mask);
    _ = std.c.sigaddset(&usr2_mask, .USR2);
    _ = std.c.sigprocmask(std.c.SIG.BLOCK, &usr2_mask, null);
    transact.transaction_commit();

    try std.testing.expectEqual(@as(?isize, 0x1a), parseLongInput("0x1a"));
    try std.testing.expectEqual(@as(?isize, -1), parseLongInput("0xFFFFFFFFFFFFFFFF"));
    try std.testing.expectEqual(@as(?isize, -42), parseLongInput(" -42 "));
    try std.testing.expectEqual(@as(?isize, 123), parseLongInput("123"));
    try std.testing.expectEqual(@as(?isize, null), parseLongInput(""));
    try std.testing.expectEqual(@as(?isize, null), parseLongInput("nope"));

    var tmp_buf: [64]u8 = undefined;
    const pid = std.c.getpid();
    const tmp_slice = try std.fmt.bufPrint(tmp_buf[0 .. tmp_buf.len - 1], "/tmp/zig-uxsig-test-{d}.txt", .{pid});
    tmp_buf[tmp_slice.len] = 0;
    const tmp_path: [*:0]const u8 = @ptrCast(tmp_buf[0..tmp_slice.len :0]);
    const fp = std.c.fopen(tmp_path, "w") orelse return error.TestUnexpectedResult;
    defer _ = std.c.unlink(tmp_path);
    etaFclose(@ptrCast(fp));
}
