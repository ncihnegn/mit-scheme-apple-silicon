const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const boot = @import("boot.zig");
const fasload = @import("fasload.zig");
const option = @import("option.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

const term_eof: c_int = 0x0E;
const term_signal: c_int = 0x16;
const posix_madv_normal: c_int = 0;
const posix_madv_sequential: c_int = 2;

const system_name: [*:0]const u8 = "unix";
const system_variant: [*:0]const u8 = if (builtin.os.tag.isDarwin())
    "OS X"
else if (builtin.os.tag == .linux)
    "GNU/Linux"
else
    "unknown";

extern "c" fn strerror(errnum: c_int) ?[*:0]const u8;
extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;
extern "c" fn getpagesize() c_int;
extern "c" fn posix_madvise(addr: ?*anyopaque, len: usize, advice: c_int) c_int;
extern "c" fn madvise(addr: ?*anyopaque, len: usize, advice: c_int) c_int;

var interactive: c_int = 0;

/// Return non-zero when Scheme is running as an Emacs subprocess.
pub fn osUnderEmacsP() callconv(.c) c_int {
    return @intFromBool(option.option_emacs_subprocess);
}

/// Initialize Unix OS subsystems, runtime identity globals, and macOS app-bundle CWD if applicable.
pub fn osInitialize() callconv(.c) void {
    abi.initialize_interruptable_extent();
    interactive = @intFromBool(
        option.option_force_interactive or
            std.c.isatty(std.c.STDIN_FILENO) != 0 or
            std.c.isatty(std.c.STDOUT_FILENO) != 0 or
            std.c.isatty(std.c.STDERR_FILENO) != 0,
    );
    if (option.option_batch_mode) {
        interactive = 0;
    }
    abi.UX_initialize_ctty(interactive);
    abi.UX_initialize_channels();
    abi.UX_initialize_terminals();
    abi.UX_initialize_environment();
    abi.UX_initialize_tty();
    abi.UX_initialize_userio();
    abi.UX_initialize_signals();
    abi.UX_initialize_processes();
    abi.UX_initialize_trap_recovery();
    abi.UX_initialize_directory_reader();
    boot.OS_Name = system_name;
    boot.OS_Variant = system_variant;

    if (comptime builtin.os.tag.isDarwin()) {
        if (macosxInAppP()) {
            var home_dir = std.c.getenv("HOME");
            if (home_dir == null or home_dir.?[0] == 0) {
                if (std.c.getpwuid(std.c.getuid())) |entry| {
                    home_dir = @constCast(entry.dir);
                }
            }
            if (home_dir) |hd| {
                if (hd[0] != 0 and std.c.chdir(hd) == 0) {
                    abi.OS_set_working_dir_pathname(hd);
                }
            }
        }
    }
}

fn writeStdout(slice: []const u8) void {
    _ = std.c.fwrite(slice.ptr, 1, slice.len, abi.cStdout());
}

/// Print the interactive keyboard interrupt help banner when appropriate.
pub fn osAnnouncement() callconv(.c) void {
    if (!option.option_emacs_subprocess and abi.OS_ctty_interrupt_control() != 0) {
        var buf: [160]u8 = undefined;
        const desc = std.mem.span(abi.char_description(abi.OS_ctty_quit_char(), 1));
        const msg = std.fmt.bufPrint(
            &buf,
            "Type {s} followed by `H' to obtain information about interrupts.\n",
            .{desc},
        ) catch return;
        writeStdout(msg);
    }
}

/// Reset Unix channels, terminals, processes, and run registered reload cleanups.
pub fn osReset() callconv(.c) void {
    abi.UX_reset_channels();
    abi.UX_reset_terminals();
    abi.UX_reset_processes();
    fasload.execute_reload_cleanups();
}

/// Prepare Unix terminal state before exiting Scheme, optionally prompting for core dump.
pub fn osQuit(code: c_int, abnormal_p: c_int) callconv(.c) void {
    _ = abi.fflush(abi.cStdout());
    if (abnormal_p != 0 and interactive != 0 and code != term_signal and code != term_eof) {
        writeStdout("\nScheme has terminated abnormally!\n");
        const dump_core = !option.option_disable_core_dump and
            abi.userio_confirm("Would you like a core dump? [Y or N] ") != 0 and
            abi.userio_confirm("Do you really want a core dump? [Y or N] ") != 0;
        writeStdout("\n");
        _ = abi.fflush(abi.cStdout());
        if (dump_core) {
            uxDumpCore();
        }
    }
    osRestoreExternalState();
}

/// Restore external terminal state and abort with default `SIGABRT` disposition.
pub fn uxDumpCore() callconv(.c) void {
    osRestoreExternalState();
    _ = signal(@intFromEnum(std.c.SIG.ABRT), null);
    std.c.abort();
}

/// Snapshot external controlling-terminal settings before Scheme alters them.
pub fn osSaveExternalState() callconv(.c) void {
    abi.UX_ctty_save_external_state();
}

/// Snapshot Scheme's internal controlling-terminal settings.
pub fn osSaveInternalState() callconv(.c) void {
    abi.UX_ctty_save_internal_state();
}

/// Restore Scheme's internal controlling-terminal settings.
pub fn osRestoreInternalState() callconv(.c) void {
    abi.UX_ctty_restore_internal_state();
}

/// Restore saved external controlling-terminal settings.
pub fn osRestoreExternalState() callconv(.c) void {
    abi.UX_ctty_restore_external_state();
}

const DarwinCF = if (builtin.os.tag.isDarwin()) struct {
    const CFBundleRef = *opaque {};
    const CFURLRef = *opaque {};
    const CFStringRef = *opaque {};
    const CFTypeRef = *const anyopaque;

    extern "c" fn CFBundleGetMainBundle() ?CFBundleRef;
    extern "c" fn CFBundleCopyResourceURL(bundle: CFBundleRef, resourceName: CFStringRef, resourceType: CFStringRef, subDirName: ?CFStringRef) ?CFURLRef;
    extern "c" fn CFURLGetFileSystemRepresentation(url: CFURLRef, resolveAgainstBase: u8, buffer: [*]u8, maxBufLen: c_long) u8;
    extern "c" fn CFRelease(cf: CFTypeRef) void;
    extern "c" fn __CFStringMakeConstantString(cStr: [*:0]const u8) CFStringRef;

    fn defaultBandUrl() ?CFURLRef {
        const bundle = CFBundleGetMainBundle() orelse return null;
        return CFBundleCopyResourceURL(
            bundle,
            __CFStringMakeConstantString("all"),
            __CFStringMakeConstantString("com"),
            null,
        );
    }
} else struct {};

/// On macOS, return a `malloc`-allocated bundle directory string containing `all.com`, or `null`.
pub fn macosxMainBundleDir() callconv(.c) ?[*:0]const u8 {
    if (comptime !builtin.os.tag.isDarwin()) return null;
    const url = DarwinCF.defaultBandUrl() orelse return null;
    defer DarwinCF.CFRelease(@ptrCast(url));
    var buffer: [4096]u8 = @splat(0);
    if (DarwinCF.CFURLGetFileSystemRepresentation(url, 1, &buffer, buffer.len) == 0) {
        return null;
    }
    var dir_slice = std.mem.sliceTo(&buffer, 0);
    if (std.mem.lastIndexOfScalar(u8, dir_slice, '/')) |idx| {
        dir_slice = dir_slice[0..idx];
    }
    const raw = std.c.malloc(dir_slice.len + 1) orelse return null;
    const dst: [*]u8 = @ptrCast(raw);
    @memcpy(dst[0..dir_slice.len], dir_slice);
    dst[dir_slice.len] = 0;
    return @ptrCast(dst);
}

/// On macOS, return true when launched inside a `.app` bundle containing `all.com`.
pub fn macosxInAppP() callconv(.c) bool {
    if (comptime !builtin.os.tag.isDarwin()) return false;
    if (!option.option_macosx_application_storage) return false;
    const url = DarwinCF.defaultBandUrl() orelse return false;
    DarwinCF.CFRelease(@ptrCast(url));
    return true;
}

const ErrnoMapEntry = struct {
    syserr: c_int,
    field: []const u8,
};

const errno_map = [_]ErrnoMapEntry{
    .{ .syserr = 4, .field = "2BIG" },
    .{ .syserr = 35, .field = "ACCES" },
    .{ .syserr = 2, .field = "ADDRINUSE" },
    .{ .syserr = 3, .field = "ADDRNOTAVAIL" },
    .{ .syserr = 1, .field = "AFNOSUPPORT" },
    .{ .syserr = 39, .field = "AGAIN" },
    .{ .syserr = 6, .field = "BADF" },
    .{ .syserr = 37, .field = "BUSY" },
    .{ .syserr = 25, .field = "CHILD" },
    .{ .syserr = 8, .field = "CONNREFUSED" },
    .{ .syserr = 9, .field = "CONNRESET" },
    .{ .syserr = 38, .field = "DEADLK" },
    .{ .syserr = 11, .field = "DOM" },
    .{ .syserr = 13, .field = "EXIST" },
    .{ .syserr = 5, .field = "FAULT" },
    .{ .syserr = 14, .field = "FBIG" },
    .{ .syserr = 17, .field = "HOSTUNREACH" },
    .{ .syserr = 20, .field = "INTR" },
    .{ .syserr = 21, .field = "INVAL" },
    .{ .syserr = 23, .field = "IO" },
    .{ .syserr = 24, .field = "ISDIR" },
    .{ .syserr = 42, .field = "MFILE" },
    .{ .syserr = 41, .field = "MLINK" },
    .{ .syserr = 15, .field = "NAMETOOLONG" },
    .{ .syserr = 43, .field = "NFILE" },
    .{ .syserr = 28, .field = "NODEV" },
    .{ .syserr = 30, .field = "NOENT" },
    .{ .syserr = 12, .field = "NOEXEC" },
    .{ .syserr = 26, .field = "NOLCK" },
    .{ .syserr = 33, .field = "NOMEM" },
    .{ .syserr = 27, .field = "NOSPC" },
    .{ .syserr = 16, .field = "NOSYS" },
    .{ .syserr = 32, .field = "NOTDIR" },
    .{ .syserr = 10, .field = "NOTEMPTY" },
    .{ .syserr = 19, .field = "NOTTY" },
    .{ .syserr = 29, .field = "NXIO" },
    .{ .syserr = 34, .field = "PERM" },
    .{ .syserr = 7, .field = "PIPE" },
    .{ .syserr = 40, .field = "RANGE" },
    .{ .syserr = 36, .field = "ROFS" },
    .{ .syserr = 22, .field = "SPIPE" },
    .{ .syserr = 31, .field = "SRCH" },
    .{ .syserr = 18, .field = "XDEV" },
};

/// Convert an OS `errno` value into MIT/GNU Scheme's `enum syserr_names`.
pub fn osErrorCodeToSyserr(code: c_int) callconv(.c) c_int {
    inline for (errno_map) |entry| {
        if (@hasField(std.c.E, entry.field)) {
            if (comptime std.mem.eql(u8, entry.field, "NOTEMPTY")) {
                if (@intFromEnum(@field(std.c.E, "NOTEMPTY")) != @intFromEnum(std.c.E.EXIST)) {
                    if (code == @intFromEnum(@field(std.c.E, entry.field))) return entry.syserr;
                }
            } else {
                if (code == @intFromEnum(@field(std.c.E, entry.field))) return entry.syserr;
            }
        }
    }
    return 0;
}

fn syserrToErrorCode(syserr: c_uint) c_int {
    inline for (errno_map) |entry| {
        if (@hasField(std.c.E, entry.field)) {
            if (syserr == entry.syserr) return @intFromEnum(@field(std.c.E, entry.field));
        }
    }
    return 0;
}

/// Convert MIT/GNU Scheme's `enum syserr_names` into a C `strerror` string, or `null` if unknown.
pub fn osErrorCodeToMessage(syserr: c_uint) callconv(.c) ?[*:0]const u8 {
    if (syserr == 0) return null;
    return strerror(syserrToErrorCode(syserr));
}

var syscall_names_table = [_]?[*:0]const u8{
    "accept",
    "bind",
    "chdir",
    "chmod",
    "clock_gettime",
    "close",
    "connect",
    "fcntl-getfl",
    "fcntl-fullfsync",
    "fcntl-setfl",
    "fdatasync",
    "fork",
    "fstat",
    "fstatfs",
    "fsync",
    "fsync_range",
    "ftruncate",
    "getcwd",
    "gethostname",
    "gettimeofday",
    "gmtime",
    "ioctl-tiocgpgrp",
    "ioctl-tiocsigsend",
    "kill",
    "link",
    "listen",
    "localtime",
    "lseek",
    "lstat",
    "malloc",
    "mkdir",
    "mktime",
    "ntp_adjtime",
    "ntp_gettime",
    "open",
    "opendir",
    "pause",
    "pipe",
    "read",
    "readlink",
    "realloc",
    "rename",
    "rmdir",
    "select",
    "setitimer",
    "setpgid",
    "setsockopt",
    "shutdown",
    "sighold",
    "sigprocmask",
    "sigsuspend",
    "sleep",
    "socket",
    "stat",
    "statfs",
    "symlink",
    "sync_file_range",
    "tcdrain",
    "tcflush",
    "tcgetpgrp",
    "tcsetpgrp",
    "terminal-get-state",
    "terminal-set-state",
    "time",
    "times",
    "uname",
    "unlink",
    "utime",
    "vfork",
    "write",
};

/// Populate `length` and `names` with the static table of MIT/GNU Scheme Unix syscall names.
pub fn osSyscallNames(length: *c_ulong, names: *[*]?[*:0]const u8) callconv(.c) void {
    length.* = syscall_names_table.len;
    names.* = &syscall_names_table;
}

var syserr_names_table = [_]?[*:0]const u8{
    "unknown",
    "address-family-not-supported",
    "address-in-use",
    "address-not-available",
    "arg-list-too-long",
    "bad-address",
    "bad-file-descriptor",
    "broken-pipe",
    "connection-refused",
    "connection-reset",
    "directory-not-empty",
    "domain-error",
    "exec-format-error",
    "file-exists",
    "file-too-large",
    "filename-too-long",
    "function-not-implemented",
    "host-is-unreachable",
    "improper-link",
    "inappropriate-io-control-operation",
    "interrupted-function-call",
    "invalid-argument",
    "invalid-seek",
    "io-error",
    "is-a-directory",
    "no-child-processes",
    "no-locks-available",
    "no-space-left-on-device",
    "no-such-device",
    "no-such-device-or-address",
    "no-such-file-or-directory",
    "no-such-process",
    "not-a-directory",
    "not-enough-space",
    "operation-not-permitted",
    "permission-denied",
    "read-only-file-system",
    "resource-busy",
    "resource-deadlock-avoided",
    "resource-temporarily-unavailable",
    "result-too-large",
    "too-many-links",
    "too-many-open-files",
    "too-many-open-files",
};

/// Populate `length` and `names` with the static table of MIT/GNU Scheme system error names.
pub fn osSyserrNames(length: *c_ulong, names: *[*]?[*:0]const u8) callconv(.c) void {
    length.* = syserr_names_table.len;
    names.* = &syserr_names_table;
}

fn roundUp(n: usize, factor: usize) usize {
    return ((n + (factor - 1)) / factor) * factor;
}

fn roundDown(n: usize, factor: usize) usize {
    return (n / factor) * factor;
}

fn estimatePages(
    start: ?*const anyopaque,
    end: ?*const anyopaque,
    comptime overestimate: bool,
    addr: *?*anyopaque,
    len: *usize,
) void {
    const start_int = @intFromPtr(start);
    const end_int = @intFromPtr(end);
    if (end_int <= start_int) {
        addr.* = @constCast(start);
        len.* = 0;
        return;
    }
    const raw_ps = getpagesize();
    const page_size: usize = if (raw_ps <= 0) 0x1000 else @intCast(raw_ps);
    const page_start = if (overestimate) roundDown(start_int, page_size) else roundUp(start_int, page_size);
    const page_end = if (overestimate) roundUp(end_int, page_size) else roundDown(end_int, page_size);
    addr.* = @ptrFromInt(page_start);
    len.* = if (page_start < page_end) page_end - page_start else 0;
}

/// Hint sequential virtual-memory page access for `[start, end)`.
pub fn osExpectSequentialAccess(start: ?*const anyopaque, end: ?*const anyopaque) callconv(.c) void {
    var addr: ?*anyopaque = null;
    var len: usize = 0;
    estimatePages(start, end, true, &addr, &len);
    _ = posix_madvise(addr, len, posix_madv_sequential);
}

/// Reset virtual-memory access hint to normal for `[start, end)`.
pub fn osExpectNormalAccess(start: ?*const anyopaque, end: ?*const anyopaque) callconv(.c) void {
    var addr: ?*anyopaque = null;
    var len: usize = 0;
    estimatePages(start, end, true, &addr, &len);
    _ = posix_madvise(addr, len, posix_madv_normal);
}

/// Release backing physical pages inside `[start, end)` via `MADV_FREE`/`MADV_DONTNEED`.
pub fn osFreePages(start: ?*anyopaque, end: ?*anyopaque) callconv(.c) void {
    var addr: ?*anyopaque = null;
    var len: usize = 0;
    estimatePages(start, end, false, &addr, &len);
    const madv_free: c_int = if (@hasField(std.c.MADV, "FREE") or @hasDecl(std.c.MADV, "FREE"))
        std.c.MADV.FREE
    else
        std.c.MADV.DONTNEED;
    _ = madvise(addr, len, madv_free);
}

comptime {
    if (!builtin.is_test) {
        @export(&osUnderEmacsP, .{ .name = "OS_under_emacs_p" });
        @export(&osInitialize, .{ .name = "OS_initialize" });
        @export(&osAnnouncement, .{ .name = "OS_announcement" });
        @export(&osReset, .{ .name = "OS_reset" });
        @export(&osQuit, .{ .name = "OS_quit" });
        @export(&uxDumpCore, .{ .name = "UX_dump_core" });
        @export(&osSaveExternalState, .{ .name = "OS_save_external_state" });
        @export(&osSaveInternalState, .{ .name = "OS_save_internal_state" });
        @export(&osRestoreInternalState, .{ .name = "OS_restore_internal_state" });
        @export(&osRestoreExternalState, .{ .name = "OS_restore_external_state" });
        if (builtin.os.tag.isDarwin()) {
            @export(&macosxMainBundleDir, .{ .name = "macosx_main_bundle_dir" });
            @export(&macosxInAppP, .{ .name = "macosx_in_app_p" });
        }
        @export(&osErrorCodeToSyserr, .{ .name = "OS_error_code_to_syserr" });
        @export(&osErrorCodeToMessage, .{ .name = "OS_error_code_to_message" });
        @export(&osSyscallNames, .{ .name = "OS_syscall_names" });
        @export(&osSyserrNames, .{ .name = "OS_syserr_names" });
        @export(&osExpectSequentialAccess, .{ .name = "OS_expect_sequential_access" });
        @export(&osExpectNormalAccess, .{ .name = "OS_expect_normal_access" });
        @export(&osFreePages, .{ .name = "OS_free_pages" });
    }
}

test "uxtop syscall/syserr tables, error translation, page hints, and Darwin bundle check" {
    stubs.resetMockRuntime();

    var sc_len: c_ulong = 0;
    var sc_names: [*]?[*:0]const u8 = undefined;
    osSyscallNames(&sc_len, &sc_names);
    try std.testing.expectEqual(@as(c_ulong, 70), sc_len);
    try std.testing.expectEqualStrings("accept", std.mem.span(sc_names[0].?));
    try std.testing.expectEqualStrings("write", std.mem.span(sc_names[69].?));

    var se_len: c_ulong = 0;
    var se_names: [*]?[*:0]const u8 = undefined;
    osSyserrNames(&se_len, &se_names);
    try std.testing.expectEqual(@as(c_ulong, 44), se_len);
    try std.testing.expectEqualStrings("unknown", std.mem.span(se_names[0].?));
    try std.testing.expectEqualStrings("too-many-open-files", std.mem.span(se_names[43].?));

    try std.testing.expectEqual(@as(c_int, 30), osErrorCodeToSyserr(@intFromEnum(std.c.E.NOENT)));
    try std.testing.expectEqual(@as(c_int, 33), osErrorCodeToSyserr(@intFromEnum(std.c.E.NOMEM)));
    try std.testing.expectEqual(@as(c_int, 39), osErrorCodeToSyserr(@intFromEnum(std.c.E.AGAIN)));
    try std.testing.expectEqual(@as(c_int, 0), osErrorCodeToSyserr(99999));

    try std.testing.expect(osErrorCodeToMessage(0) == null);
    try std.testing.expect(std.mem.span(osErrorCodeToMessage(30).?).len > 0);
    try std.testing.expect(std.mem.span(osErrorCodeToMessage(33).?).len > 0);

    var dummy: [64]u8 = @splat(0);
    osExpectSequentialAccess(&dummy, &dummy);
    osExpectNormalAccess(&dummy, &dummy);
    osFreePages(&dummy, &dummy);

    try std.testing.expectEqual(@as(c_int, @intFromBool(option.option_emacs_subprocess)), osUnderEmacsP());
    try std.testing.expect(!macosxInAppP());
}
