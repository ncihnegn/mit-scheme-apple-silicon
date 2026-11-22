const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../../core/prim_abi.zig");
const osscheme = @import("../osscheme.zig");
const utils = @import("../../core/utils.zig");
const stubs = if (builtin.is_test) @import("../../core/test_stubs.zig") else struct {};

const utc_epoch_minus_unix_epoch: i64 = 63_072_000;

const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

const CTms = extern struct {
    tms_utime: abi.ClockT,
    tms_stime: abi.ClockT,
    tms_cutime: abi.ClockT,
    tms_cstime: abi.ClockT,
};

const CItimerval = extern struct {
    it_interval: std.c.timeval,
    it_value: std.c.timeval,
};

const itimer_real: c_int = 0;
const itimer_virtual: c_int = 1;
const itimer_prof: c_int = 2;

extern "c" fn time(?*abi.TimeT) abi.TimeT;
extern "c" fn localtime(*const abi.TimeT) ?*CTm;
extern "c" fn gmtime(*const abi.TimeT) ?*CTm;
extern "c" fn mktime(*CTm) abi.TimeT;
extern "c" fn times(*CTms) abi.ClockT;
extern "c" fn setitimer(c_int, *const CItimerval, ?*CItimerval) c_int;
extern "c" fn getlogin() ?[*:0]const u8;

const LinuxTimex = if (builtin.os.tag == .linux and builtin.abi.isGnu()) extern struct {
    modes: c_uint,
    offset: c_long,
    freq: c_long,
    maxerror: c_long,
    esterror: c_long,
    status: c_int,
    constant: c_long,
    precision: c_long,
    tolerance: c_long,
    time: std.c.timeval,
    tick: c_long,
    ppsfreq: c_long,
    jitter: c_long,
    shift: c_int,
    stabil: c_long,
    jitcnt: c_long,
    calcnt: c_long,
    errcnt: c_long,
    stbcnt: c_long,
    tai: c_int,
    _reserved: [11]i32,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 208);
        std.debug.assert(@offsetOf(@This(), "time") == 72);
        std.debug.assert(@offsetOf(@This(), "tai") == 160);
    }
} else void;

fn guessTimeFromPosix(posix: i64, tai: c_long) i64 {
    const n_leap: c_long = if (tai < 10) tai else tai - 10;
    return posix - utc_epoch_minus_unix_epoch + @as(i64, n_leap);
}

fn sanitizeNsec(nsec: anytype) u32 {
    if (nsec < 0) return 0;
    const u: u64 = @intCast(nsec);
    return if (u < 1_000_000_000) @intCast(u) else 999_999_999;
}

fn sanitizeUsec(usec: anytype) u32 {
    if (usec < 0) return 0;
    const u: u64 = @intCast(usec);
    return if (u < 1_000_000) @intCast(1000 * u) else 999_999;
}

/// Populate `t` with seconds since Scheme's UTC epoch (`1972-01-01`) and nanoseconds.
pub fn osNanotimeSinceUtcEpoch(t: *abi.SchemeNanotime) callconv(.c) void {
    if (builtin.os.tag == .linux and builtin.abi.isGnu()) {
        const LinuxNtp = struct {
            extern "c" fn ntp_adjtime(tx: *LinuxTimex) callconv(.c) c_int;
        };
        var tx = std.mem.zeroes(LinuxTimex);
        while (LinuxNtp.ntp_adjtime(&tx) < 0) {
            abi.UX_prim_check_errno(abi.syscall_ntp_adjtime);
        }
        t.seconds = guessTimeFromPosix(@intCast(tx.time.sec), tx.tai);
        t.nanoseconds = sanitizeUsec(tx.time.usec);
        return;
    }

    var ts: std.c.timespec = undefined;
    while (std.c.clock_gettime(.REALTIME, &ts) < 0) {
        abi.UX_prim_check_errno(abi.syscall_clock_gettime);
    }
    t.seconds = guessTimeFromPosix(@intCast(ts.sec), 0);
    t.nanoseconds = sanitizeNsec(ts.nsec);
}

/// Populate `t` with a monotonic clock timestamp.
pub fn osMonotonicNanotime(t: *abi.SchemeNanotime) callconv(.c) void {
    var ts: std.c.timespec = undefined;
    while (std.c.clock_gettime(.MONOTONIC, &ts) < 0) {
        abi.UX_prim_check_errno(abi.syscall_clock_gettime);
    }
    t.seconds = @intCast(ts.sec);
    t.nanoseconds = @intCast(ts.nsec);
}

/// Return current POSIX `time(NULL)` seconds.
pub fn osEncodedTime() callconv(.c) abi.TimeT {
    var t = time(null);
    while (t < 0) {
        abi.UX_prim_check_errno(abi.syscall_time);
        t = time(null);
    }
    return t;
}

fn fillDecodedTime(ts: *const CTm, buffer: *abi.TimeStructure, dst: c_int, tz: c_int) void {
    buffer.year = @intCast(ts.tm_year + 1900);
    buffer.month = @intCast(ts.tm_mon + 1);
    buffer.day = @intCast(ts.tm_mday);
    buffer.hour = @intCast(ts.tm_hour);
    buffer.minute = @intCast(ts.tm_min);
    buffer.second = @intCast(ts.tm_sec);
    buffer.daylight_savings_time = dst;
    buffer.time_zone = tz;
    buffer.day_of_week = @intCast(if (ts.tm_wday == 0) @as(c_int, 6) else ts.tm_wday - 1);
}

/// Decode `t` into local calendar fields (`TimeStructure`) using `localtime`.
pub fn osDecodeTime(t: abi.TimeT, buffer: *abi.TimeStructure) callconv(.c) void {
    var tv = t;
    var ts = localtime(&tv);
    while (ts == null) {
        abi.UX_prim_check_errno(abi.syscall_localtime);
        ts = localtime(&tv);
    }
    const tp = ts.?;
    var tz = -tp.tm_gmtoff;
    if (tp.tm_isdst > 0) tz += 3600;
    fillDecodedTime(tp, buffer, tp.tm_isdst, @intCast(tz));
}

/// Decode `t` into UTC calendar fields (`TimeStructure`) using `gmtime`.
pub fn osDecodeUtc(t: abi.TimeT, buffer: *abi.TimeStructure) callconv(.c) void {
    var tv = t;
    var ts = gmtime(&tv);
    while (ts == null) {
        abi.UX_prim_check_errno(abi.syscall_gmtime);
        ts = gmtime(&tv);
    }
    fillDecodedTime(ts.?, buffer, 0, 0);
}

/// Encode `TimeStructure` into POSIX `time_t` via `mktime`, adjusting for custom time zones.
pub fn osEncodeTime(buffer: *abi.TimeStructure) callconv(.c) abi.TimeT {
    var ts = std.mem.zeroes(CTm);
    ts.tm_year = @as(c_int, @intCast(buffer.year)) - 1900;
    ts.tm_mon = @as(c_int, @intCast(buffer.month)) - 1;
    ts.tm_mday = @intCast(buffer.day);
    ts.tm_hour = @intCast(buffer.hour);
    ts.tm_min = @intCast(buffer.minute);
    ts.tm_sec = @intCast(buffer.second);
    ts.tm_isdst = buffer.daylight_savings_time;
    var t = mktime(&ts);
    while (t < 0) {
        abi.UX_prim_check_errno(abi.syscall_mktime);
        t = mktime(&ts);
    }
    if (buffer.time_zone != std.math.maxInt(c_int)) {
        var assumed_zone: isize = -ts.tm_gmtoff;
        if (ts.tm_isdst > 0) assumed_zone += 3600;
        if (buffer.time_zone != assumed_zone) {
            t = (t - assumed_zone) + @as(abi.TimeT, buffer.time_zone);
        }
    }
    return t;
}

var initial_process_clock: abi.ClockT = 0;
var initial_rtc: std.c.timeval = .{ .sec = 0, .usec = 0 };

fn processTimeFromTms(buffer: *const CTms) abi.ClockT {
    if (builtin.os.tag == .linux) {
        return buffer.tms_utime + buffer.tms_stime;
    }
    return buffer.tms_utime;
}

fn initializeProcessClock() void {
    var buffer: CTms = undefined;
    while (times(&buffer) == @as(abi.ClockT, @bitCast(@as(isize, -1)))) {
        if (std.c._errno().* != @backingInt(std.c.E.INTR)) {
            initial_process_clock = 0;
            return;
        }
    }
    initial_process_clock = processTimeFromTms(&buffer);
}

/// Return elapsed process CPU time in milliseconds since initialization.
pub fn osProcessClock() callconv(.c) f64 {
    const ct: f64 = @floatFromInt(abi.UX_SC_CLK_TCK());
    var buffer: CTms = undefined;
    var t: abi.ClockT = initial_process_clock;
    while (true) {
        if (times(&buffer) != @as(abi.ClockT, @bitCast(@as(isize, -1)))) {
            t = processTimeFromTms(&buffer);
            break;
        }
        if (std.c._errno().* == @backingInt(std.c.E.INTR)) {
            osscheme.deliver_pending_interrupts();
        } else {
            break;
        }
    }
    const diff: f64 = @floatFromInt(t -% initial_process_clock);
    return ((diff * 2000.0) + ct) / (2.0 * ct);
}

fn initializeRealTimeClock() void {
    var tz: std.c.timezone = undefined;
    while (std.c.gettimeofday(&initial_rtc, &tz) == -1) {
        if (std.c._errno().* != @backingInt(std.c.E.INTR)) {
            initial_rtc = .{ .sec = 0, .usec = 0 };
            break;
        }
    }
}

/// Return elapsed wall-clock time in milliseconds since initialization.
pub fn osRealTimeClock() callconv(.c) f64 {
    var rtc: std.c.timeval = undefined;
    var tz: std.c.timezone = undefined;
    while (std.c.gettimeofday(&rtc, &tz) == -1) {
        if (std.c._errno().* == @backingInt(std.c.E.INTR)) {
            osscheme.deliver_pending_interrupts();
        } else {
            rtc = initial_rtc;
            break;
        }
    }
    const dsec: f64 = @floatFromInt(rtc.sec - initial_rtc.sec);
    const dusec: f64 = @floatFromInt(@as(i64, rtc.usec) - @as(i64, initial_rtc.usec));
    return (dsec * 1000.0) + ((dusec + 500.0) / 1000.0);
}

/// Return current OS jiffy tick count via `times`.
pub fn osCurrentJiffy() callconv(.c) abi.ClockT {
    var buffer: CTms = undefined;
    return times(&buffer);
}

/// Return system clock jiffies per second (`UX_SC_CLK_TCK()`).
pub fn osJiffiesPerSecond() callconv(.c) abi.ClockT {
    return abi.UX_SC_CLK_TCK();
}

fn setTimer(which: c_int, first: abi.ClockT, interval: abi.ClockT) void {
    var value: CItimerval = undefined;
    var ovalue: CItimerval = undefined;
    const first_s: isize = @intCast(first);
    const interval_s: isize = @intCast(interval);
    value.it_value = .{
        .sec = @intCast(@divTrunc(first_s, 1000)),
        .usec = @intCast(@rem(first_s, 1000) * 1000),
    };
    value.it_interval = .{
        .sec = @intCast(@divTrunc(interval_s, 1000)),
        .usec = @intCast(@rem(interval_s, 1000) * 1000),
    };
    while (setitimer(which, &value, &ovalue) < 0) {
        abi.UX_prim_check_errno(abi.syscall_setitimer);
    }
}

/// Arm the virtual-time process interval timer (`ITIMER_VIRTUAL`).
pub fn osProcessTimerSet(first: abi.ClockT, interval: abi.ClockT) callconv(.c) void {
    setTimer(itimer_virtual, first, interval);
}

/// Disarm the virtual-time process interval timer.
pub fn osProcessTimerClear() callconv(.c) void {
    setTimer(itimer_virtual, 0, 0);
}

/// Arm the profiling interval timer (`ITIMER_PROF`).
pub fn osProfileTimerSet(first: abi.ClockT, interval: abi.ClockT) callconv(.c) void {
    setTimer(itimer_prof, first, interval);
}

/// Disarm the profiling interval timer.
pub fn osProfileTimerClear() callconv(.c) void {
    setTimer(itimer_prof, 0, 0);
}

/// Arm the real-time interval timer (`ITIMER_REAL`).
pub fn osRealTimerSet(first: abi.ClockT, interval: abi.ClockT) callconv(.c) void {
    setTimer(itimer_real, first, interval);
}

/// Disarm the real-time interval timer.
pub fn osRealTimerClear() callconv(.c) void {
    setTimer(itimer_real, 0, 0);
}

/// Initialize process and real-time clock baselines for the OS environment module.
pub fn uxInitializeEnvironment() callconv(.c) void {
    initializeProcessClock();
    initializeRealTimeClock();
}

var current_dir_path_size: usize = 0;
var current_dir_path: ?[*]u8 = null;

/// Return a cached NUL-terminated working directory path string, growing on `ERANGE`.
pub fn osWorkingDirPathname() callconv(.c) [*:0]const u8 {
    if (current_dir_path) |p| {
        return @ptrCast(p);
    }
    if (current_dir_path_size == 0) {
        const init_sz: usize = 1024;
        const raw = std.c.malloc(init_sz) orelse
            utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_malloc);
        current_dir_path = @ptrCast(raw);
        current_dir_path_size = init_sz;
    }
    while (true) {
        if (std.c.getcwd(current_dir_path.?, current_dir_path_size) != null) {
            return @ptrCast(current_dir_path.?);
        }
        const err = std.c._errno().*;
        if (err != @backingInt(std.c.E.RANGE)) {
            utils.error_system_call(err, abi.syscall_getcwd);
        }
        current_dir_path_size *= 2;
        const raw = std.c.realloc(@ptrCast(current_dir_path.?), current_dir_path_size) orelse
            utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_realloc);
        current_dir_path = @ptrCast(raw);
    }
}

/// Change current working directory to `name` and update the cached working directory string.
pub fn osSetWorkingDirPathname(name: [*:0]const u8) callconv(.c) void {
    const name_slice = std.mem.span(name);
    while (std.c.chdir(name) < 0) {
        abi.UX_prim_check_errno(abi.syscall_chdir);
    }
    if (current_dir_path == null) {
        const init_sz = @max(@as(usize, 1024), name_slice.len + 1);
        const raw = std.c.malloc(init_sz) orelse
            utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_malloc);
        current_dir_path = @ptrCast(raw);
        current_dir_path_size = init_sz;
    }
    while (name_slice.len >= current_dir_path_size) {
        current_dir_path_size *= 2;
        const raw = std.c.realloc(@ptrCast(current_dir_path.?), current_dir_path_size) orelse
            utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_realloc);
        current_dir_path = @ptrCast(raw);
    }
    const dst = current_dir_path.?;
    @memcpy(dst[0..name_slice.len], name_slice);
    dst[name_slice.len] = 0;
}

/// Return current login or effective UID username string.
pub fn osCurrentUserName() callconv(.c) [*:0]const u8 {
    if (getlogin()) |result| {
        if (result[0] != 0) return result;
    }
    if (std.c.getpwuid(std.c.geteuid())) |entry| {
        if (entry.name) |name| return name;
    }
    abi.error_external_return();
}

/// Return current user's home directory path from login/UID passwd entry.
pub fn osCurrentUserHomeDirectory() callconv(.c) [*:0]const u8 {
    if (getlogin()) |user_name| {
        if (std.c.getpwnam(user_name)) |entry| {
            if (entry.dir) |dir| return dir;
        }
    }
    if (std.c.getpwuid(std.c.getuid())) |entry| {
        if (entry.dir) |dir| return dir;
    }
    abi.error_external_return();
}

comptime {
    if (!builtin.is_test) {
        @export(&osNanotimeSinceUtcEpoch, .{ .name = "OS_nanotime_since_utc_epoch" });
        @export(&osMonotonicNanotime, .{ .name = "OS_monotonic_nanotime" });
        @export(&osEncodedTime, .{ .name = "OS_encoded_time" });
        @export(&osDecodeTime, .{ .name = "OS_decode_time" });
        @export(&osDecodeUtc, .{ .name = "OS_decode_utc" });
        @export(&osEncodeTime, .{ .name = "OS_encode_time" });
        @export(&osProcessClock, .{ .name = "OS_process_clock" });
        @export(&osRealTimeClock, .{ .name = "OS_real_time_clock" });
        @export(&osCurrentJiffy, .{ .name = "OS_current_jiffy" });
        @export(&osJiffiesPerSecond, .{ .name = "OS_jiffies_per_second" });
        @export(&osProcessTimerSet, .{ .name = "OS_process_timer_set" });
        @export(&osProcessTimerClear, .{ .name = "OS_process_timer_clear" });
        @export(&osProfileTimerSet, .{ .name = "OS_profile_timer_set" });
        @export(&osProfileTimerClear, .{ .name = "OS_profile_timer_clear" });
        @export(&osRealTimerSet, .{ .name = "OS_real_timer_set" });
        @export(&osRealTimerClear, .{ .name = "OS_real_timer_clear" });
        @export(&uxInitializeEnvironment, .{ .name = "UX_initialize_environment" });
        @export(&osWorkingDirPathname, .{ .name = "OS_working_dir_pathname" });
        @export(&osSetWorkingDirPathname, .{ .name = "OS_set_working_dir_pathname" });
        @export(&osCurrentUserName, .{ .name = "OS_current_user_name" });
        @export(&osCurrentUserHomeDirectory, .{ .name = "OS_current_user_home_directory" });
    }
}

test "uxenv clocks, time round-trip, timers, working dir, and user identity" {
    stubs.resetMockRuntime();
    uxInitializeEnvironment();

    var nt: abi.SchemeNanotime = undefined;
    osNanotimeSinceUtcEpoch(&nt);
    try std.testing.expect(nt.seconds > 0);
    try std.testing.expect(nt.nanoseconds < 1_000_000_000);

    var mt: abi.SchemeNanotime = undefined;
    osMonotonicNanotime(&mt);
    try std.testing.expect(mt.nanoseconds < 1_000_000_000);

    const now = osEncodedTime();
    try std.testing.expect(now > 1_000_000_000);

    var utc: abi.TimeStructure = undefined;
    osDecodeUtc(now, &utc);
    try std.testing.expectEqual(@as(c_int, 0), utc.daylight_savings_time);
    try std.testing.expectEqual(@as(c_int, 0), utc.time_zone);
    try std.testing.expectEqual(now, osEncodeTime(&utc));

    var local_ts: abi.TimeStructure = undefined;
    osDecodeTime(now, &local_ts);
    try std.testing.expect(local_ts.year >= 2020);
    try std.testing.expectEqual(now, osEncodeTime(&local_ts));

    try std.testing.expect(osProcessClock() >= 0.0);
    try std.testing.expect(osRealTimeClock() >= 0.0);
    try std.testing.expect(osJiffiesPerSecond() > 0);
    _ = osCurrentJiffy();
    osRealTimerClear();

    const cwd = osWorkingDirPathname();
    try std.testing.expect(std.mem.span(cwd).len > 0);
    try std.testing.expect(std.mem.span(osCurrentUserName()).len > 0);
    try std.testing.expect(std.mem.span(osCurrentUserHomeDirectory()).len > 0);
}
