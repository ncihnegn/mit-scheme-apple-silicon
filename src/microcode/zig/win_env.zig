// Derived from MIT/GNU Scheme C sources (`src/microcode/uxenv.c`)
// and Win32 Time / Process / Directory / Timer APIs:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const osscheme = @import("osscheme.zig");
const utils = @import("utils.zig");
const win = @import("win_api.zig");
const win_io = @import("win_io.zig");

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
};

extern "c" fn _localtime64(*const abi.TimeT) ?*CTm;
extern "c" fn _gmtime64(*const abi.TimeT) ?*CTm;
extern "c" fn _mktime64(*CTm) abi.TimeT;
extern "c" fn _mkgmtime64(*CTm) abi.TimeT;
extern "c" fn _tzset() void;
extern "c" fn __timezone() *c_long;

var qpc_freq: i64 = 1;
var start_qpc: i64 = 0;
var start_proc_100ns: u64 = 0;

var current_dir_buf: [4096]u8 = @splat(0);
var current_dir_ready: bool = false;
var user_name_buf: [256]u8 = @splat(0);
var home_dir_buf: [1024]u8 = @splat(0);

var process_timer_handle: ?win.HANDLE = null;
var profile_timer_handle: ?win.HANDLE = null;
var real_timer_handle: ?win.HANDLE = null;

fn filetimeToU64(ft: win.FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

fn currentProc100ns() u64 {
    var ct: win.FILETIME = undefined;
    var et: win.FILETIME = undefined;
    var kt: win.FILETIME = undefined;
    var ut: win.FILETIME = undefined;
    if (win.kernel32.GetProcessTimes(win.kernel32.GetCurrentProcess(), &ct, &et, &kt, &ut) == 0) {
        return 0;
    }
    return filetimeToU64(kt) + filetimeToU64(ut);
}

pub fn initEnvironment() void {
    _tzset();
    var freq: i64 = 0;
    if (win.kernel32.QueryPerformanceFrequency(&freq) == 0 or freq <= 0) freq = 1;
    qpc_freq = freq;
    var now_qpc: i64 = 0;
    _ = win.kernel32.QueryPerformanceCounter(&now_qpc);
    start_qpc = now_qpc;
    start_proc_100ns = currentProc100ns();
    current_dir_ready = false;
}

pub fn osNanotimeSinceUtcEpoch(t: *abi.SchemeNanotime) callconv(.c) void {
    var ft: win.FILETIME = undefined;
    win.kernel32.GetSystemTimePreciseAsFileTime(&ft);
    const unix_nt = win.filetimeToUnixNanotime(ft);
    t.seconds = unix_nt.seconds - utc_epoch_minus_unix_epoch;
    t.nanoseconds = unix_nt.nanoseconds;
}

pub fn osMonotonicNanotime(t: *abi.SchemeNanotime) callconv(.c) void {
    var now_qpc: i64 = 0;
    _ = win.kernel32.QueryPerformanceCounter(&now_qpc);
    const ticks: u64 = if (now_qpc > 0) @intCast(now_qpc) else 0;
    const freq: u64 = if (qpc_freq > 0) @intCast(qpc_freq) else 1;
    const ns_total: u128 = (@as(u128, ticks) * 1_000_000_000) / @as(u128, freq);
    t.seconds = @intCast(ns_total / 1_000_000_000);
    t.nanoseconds = @intCast(ns_total % 1_000_000_000);
}

pub fn osEncodedTime() callconv(.c) abi.TimeT {
    var ft: win.FILETIME = undefined;
    win.kernel32.GetSystemTimeAsFileTime(&ft);
    return win.filetimeToUnixSec(ft);
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

pub fn osDecodeTime(t: abi.TimeT, buffer: *abi.TimeStructure) callconv(.c) void {
    _tzset();
    var tv = t;
    const tp = _localtime64(&tv) orelse utils.error_system_call(std.c._errno().*, abi.syscall_localtime);
    const tz: c_int = @intCast(__timezone().*);
    fillDecodedTime(tp, buffer, tp.tm_isdst, tz);
}

pub fn osDecodeUtc(t: abi.TimeT, buffer: *abi.TimeStructure) callconv(.c) void {
    var tv = t;
    const tp = _gmtime64(&tv) orelse utils.error_system_call(std.c._errno().*, abi.syscall_gmtime);
    fillDecodedTime(tp, buffer, 0, 0);
}

pub fn osEncodeTime(buffer: *abi.TimeStructure) callconv(.c) abi.TimeT {
    _tzset();
    var ts = std.mem.zeroes(CTm);
    ts.tm_year = @as(c_int, @intCast(buffer.year)) - 1900;
    ts.tm_mon = @as(c_int, @intCast(buffer.month)) - 1;
    ts.tm_mday = @intCast(buffer.day);
    ts.tm_hour = @intCast(buffer.hour);
    ts.tm_min = @intCast(buffer.minute);
    ts.tm_sec = @intCast(buffer.second);
    ts.tm_isdst = buffer.daylight_savings_time;

    const std_tz: c_int = @intCast(__timezone().*);
    if (buffer.time_zone != std.math.maxInt(c_int)) {
        const utc_t = _mkgmtime64(&ts);
        if (utc_t < 0) utils.error_system_call(std.c._errno().*, abi.syscall_mktime);
        const dst_adj: i64 = if (buffer.daylight_savings_time > 0) 3600 else 0;
        return utc_t + @as(i64, buffer.time_zone) - dst_adj;
    }

    _ = std_tz;
    const t = _mktime64(&ts);
    if (t < 0) {
        utils.error_system_call(std.c._errno().*, abi.syscall_mktime);
    }
    return t;
}

pub fn osProcessClock() callconv(.c) f64 {
    const elapsed_100ns = currentProc100ns() -| start_proc_100ns;
    return @as(f64, @floatFromInt(elapsed_100ns)) / 10_000.0;
}

pub fn osRealTimeClock() callconv(.c) f64 {
    var now_qpc: i64 = 0;
    _ = win.kernel32.QueryPerformanceCounter(&now_qpc);
    const delta = @as(f64, @floatFromInt(now_qpc - start_qpc));
    return (delta * 1000.0) / @as(f64, @floatFromInt(qpc_freq));
}

pub fn osCurrentJiffy() callconv(.c) abi.ClockT {
    return @intCast(win.kernel32.GetTickCount64());
}

pub fn osJiffiesPerSecond() callconv(.c) abi.ClockT {
    return 1000;
}

fn timerCallback(_: ?*anyopaque, _: u8) callconv(.winapi) void {
    osscheme.request_timer_interrupt();
}

fn setWinTimer(slot: *?win.HANDLE, first: abi.ClockT, interval: abi.ClockT) void {
    if (slot.*) |prev| {
        _ = win.kernel32.DeleteTimerQueueTimer(null, prev, null);
        slot.* = null;
    }
    if (first <= 0 and interval <= 0) return;
    const due: win.DWORD = if (first <= 0) 1 else @intCast(@min(@as(u64, @intCast(first)), std.math.maxInt(u32)));
    const period: win.DWORD = if (interval <= 0) 0 else @intCast(@min(@as(u64, @intCast(interval)), std.math.maxInt(u32)));
    var next: ?win.HANDLE = null;
    if (win.kernel32.CreateTimerQueueTimer(&next, null, &timerCallback, null, due, period, 0) == 0) {
        win_io.failWin32(abi.syscall_setitimer);
    }
    slot.* = next;
}

pub fn osProcessTimerSet(first: abi.ClockT, interval: abi.ClockT) callconv(.c) void {
    setWinTimer(&process_timer_handle, first, interval);
}

pub fn osProcessTimerClear() callconv(.c) void {
    setWinTimer(&process_timer_handle, 0, 0);
}

pub fn osProfileTimerSet(first: abi.ClockT, interval: abi.ClockT) callconv(.c) void {
    setWinTimer(&profile_timer_handle, first, interval);
}

pub fn osProfileTimerClear() callconv(.c) void {
    setWinTimer(&profile_timer_handle, 0, 0);
}

pub fn osRealTimerSet(first: abi.ClockT, interval: abi.ClockT) callconv(.c) void {
    setWinTimer(&real_timer_handle, first, interval);
}

pub fn osRealTimerClear() callconv(.c) void {
    setWinTimer(&real_timer_handle, 0, 0);
}

pub fn osWorkingDirPathname() callconv(.c) [*:0]const u8 {
    if (!current_dir_ready) {
        const len = win.kernel32.GetCurrentDirectoryA(current_dir_buf.len - 1, &current_dir_buf);
        if (len == 0 or len >= current_dir_buf.len) {
            win_io.failWin32(abi.syscall_getcwd);
        }
        current_dir_buf[len] = 0;
        win.normalizeSlashesInPlace(current_dir_buf[0..len]);
        current_dir_ready = true;
    }
    return @ptrCast(&current_dir_buf);
}

pub fn osSetWorkingDirPathname(name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.SetCurrentDirectoryA(name) == 0) {
        win_io.failWin32(abi.syscall_chdir);
    }
    current_dir_ready = false;
    _ = osWorkingDirPathname();
}

pub fn osCurrentUserName() callconv(.c) [*:0]const u8 {
    var len: win.DWORD = user_name_buf.len - 1;
    if (win.advapi32.GetUserNameA(&user_name_buf, &len) != 0 and len > 0) {
        const idx = @min(@as(usize, len), user_name_buf.len - 1);
        user_name_buf[idx] = 0;
        return @ptrCast(&user_name_buf);
    }
    if (std.c.getenv("USERNAME")) |u| return u;
    return "user";
}

pub fn osCurrentUserHomeDirectory() callconv(.c) [*:0]const u8 {
    if (std.c.getenv("USERPROFILE")) |up| {
        const s = std.mem.span(up);
        const n = @min(s.len, home_dir_buf.len - 1);
        @memcpy(home_dir_buf[0..n], s[0..n]);
        home_dir_buf[n] = 0;
        win.normalizeSlashesInPlace(home_dir_buf[0..n]);
        return @ptrCast(&home_dir_buf);
    }
    if (std.c.getenv("HOMEDRIVE")) |hd| {
        if (std.c.getenv("HOMEPATH")) |hp| {
            const ds = std.mem.span(hd);
            const ps = std.mem.span(hp);
            if (ds.len + ps.len < home_dir_buf.len) {
                @memcpy(home_dir_buf[0..ds.len], ds);
                @memcpy(home_dir_buf[ds.len .. ds.len + ps.len], ps);
                const total = ds.len + ps.len;
                home_dir_buf[total] = 0;
                win.normalizeSlashesInPlace(home_dir_buf[0..total]);
                return @ptrCast(&home_dir_buf);
            }
        }
    }
    if (std.c.getenv("HOME")) |h| {
        const s = std.mem.span(h);
        const n = @min(s.len, home_dir_buf.len - 1);
        @memcpy(home_dir_buf[0..n], s[0..n]);
        home_dir_buf[n] = 0;
        win.normalizeSlashesInPlace(home_dir_buf[0..n]);
        return @ptrCast(&home_dir_buf);
    }
    return "/";
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
        @export(&osWorkingDirPathname, .{ .name = "OS_working_dir_pathname" });
        @export(&osSetWorkingDirPathname, .{ .name = "OS_set_working_dir_pathname" });
        @export(&osCurrentUserName, .{ .name = "OS_current_user_name" });
        @export(&osCurrentUserHomeDirectory, .{ .name = "OS_current_user_home_directory" });
    }
}
