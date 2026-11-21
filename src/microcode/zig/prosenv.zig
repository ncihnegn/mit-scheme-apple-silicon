// Derived from MIT/GNU Scheme C sources (`src/microcode/prosenv.c`, `src/microcode/osenv.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");
const string = @import("string.zig");

const DecodeTimeFn = *const fn (abi.TimeT, *abi.TimeStructure) callconv(.c) void;

inline fn nanotimePrim(comptime fetch_fn: *const fn (*abi.SchemeNanotime) callconv(.c) void) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.pairP);
    var t: abi.SchemeNanotime = undefined;
    fetch_fn(&t);
    const pair = abi.argRef(1);
    obj.setPairCar(pair, artutl.intmax_to_integer(t.seconds));
    obj.setPairCdr(pair, artutl.uintmax_to_integer(@intCast(t.nanoseconds)));
    return obj.unspecific;
}

inline fn decodeTimePrim(comptime decode_fn: DecodeTimeFn) obj.SchemeObject {
    abi.primitiveHeader();
    const vec = abi.vectorArg(1);
    const len = obj.vectorLength(vec);
    if (len < 10) abi.error_bad_range_arg(1);
    var ts: abi.TimeStructure = undefined;
    decode_fn(@intCast(abi.arg_index_integer_to_intmax(2, abi.time_t_max)), &ts);
    obj.vectorSet(vec, 1, abi.ulong_to_integer(@intCast(ts.second)));
    obj.vectorSet(vec, 2, abi.ulong_to_integer(@intCast(ts.minute)));
    obj.vectorSet(vec, 3, abi.ulong_to_integer(@intCast(ts.hour)));
    obj.vectorSet(vec, 4, abi.ulong_to_integer(@intCast(ts.day)));
    obj.vectorSet(vec, 5, abi.ulong_to_integer(@intCast(ts.month)));
    obj.vectorSet(vec, 6, abi.ulong_to_integer(@intCast(ts.year)));
    obj.vectorSet(vec, 7, abi.ulong_to_integer(@intCast(ts.day_of_week)));
    obj.vectorSet(
        vec,
        8,
        if (ts.daylight_savings_time < 0) obj.sharp_f else abi.long_to_integer(@intCast(ts.daylight_savings_time)),
    );
    obj.vectorSet(
        vec,
        9,
        if (ts.time_zone == std.math.maxInt(c_int)) obj.sharp_f else abi.long_to_integer(@intCast(ts.time_zone)),
    );
    return obj.unspecific;
}

inline fn clockToIntmax(n: abi.ClockT) i64 {
    return if (abi.ClockT == c_ulong) @bitCast(@as(u64, n)) else @intCast(n);
}

// DEFINE_PRIMITIVE ("NANOTIME-SINCE-UTC-EPOCH", Prim_nanotime_since_utc_epoch, 1, 1, 0)
pub export fn Prim_nanotime_since_utc_epoch() callconv(.c) obj.SchemeObject {
    return nanotimePrim(&abi.OS_nanotime_since_utc_epoch);
}

// DEFINE_PRIMITIVE ("MONOTONIC-NANOTIME", Prim_monotonic_nanotime, 1, 1, 0)
pub export fn Prim_monotonic_nanotime() callconv(.c) obj.SchemeObject {
    return nanotimePrim(&abi.OS_monotonic_nanotime);
}

// DEFINE_PRIMITIVE ("ENCODED-TIME", Prim_encoded_time, 0, 0,
//   "Return the current time as an integer.")
pub export fn Prim_encoded_time() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.intmax_to_integer(@intCast(abi.OS_encoded_time()));
}

// DEFINE_PRIMITIVE ("DECODE-TIME", Prim_decode_time, 2, 2,
//   "Fill a vector with the second argument decoded.\n\
// The vector's elements are:\n\
//   #(TAG second minute hour day month year day-of-week dst zone)")
pub export fn Prim_decode_time() callconv(.c) obj.SchemeObject {
    return decodeTimePrim(&abi.OS_decode_time);
}

// DEFINE_PRIMITIVE ("DECODE-UTC", Prim_decode_utc, 2, 2,
//   "Fill a vector with the second argument decoded.\n\
// The vector's elements are:\n\
//   #(TAG second minute hour day month year day-of-week dst zone)")
pub export fn Prim_decode_utc() callconv(.c) obj.SchemeObject {
    return decodeTimePrim(&abi.OS_decode_utc);
}

// DEFINE_PRIMITIVE ("ENCODE-TIME", Prim_encode_time, 1, 1,
//   "Return the file time corresponding to the time structure given.")
pub export fn Prim_encode_time() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const vec = abi.vectorArg(1);
    const len = obj.vectorLength(vec);
    if (len < 8) abi.error_bad_range_arg(1);
    var ts: abi.TimeStructure = undefined;
    ts.second = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 1)));
    ts.minute = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 2)));
    ts.hour = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 3)));
    ts.day = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 4)));
    ts.month = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 5)));
    ts.year = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 6)));
    ts.day_of_week = @intCast(artutl.integer_to_ulong(obj.vectorRef(vec, 7)));
    ts.daylight_savings_time = if (len > 8 and obj.integerP(obj.vectorRef(vec, 8)))
        @intCast(artutl.integer_to_long(obj.vectorRef(vec, 8)))
    else
        -1;
    ts.time_zone = if (len > 9 and obj.integerP(obj.vectorRef(vec, 9)) and artutl.integer_to_long_p(obj.vectorRef(vec, 9)))
        @intCast(artutl.integer_to_long(obj.vectorRef(vec, 9)))
    else
        std.math.maxInt(c_int);
    return artutl.intmax_to_integer(@intCast(abi.OS_encode_time(&ts)));
}

// DEFINE_PRIMITIVE ("SYSTEM-CLOCK", Prim_system_clock, 0, 0,
//   "Return the current process time in units of milliseconds.")
pub export fn Prim_system_clock() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.double_to_integer(abi.OS_process_clock());
}

// DEFINE_PRIMITIVE ("REAL-TIME-CLOCK", Prim_real_time_clock, 0, 0,
//   "Return the current real time in units of milliseconds.")
pub export fn Prim_real_time_clock() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.double_to_integer(abi.OS_real_time_clock());
}

// DEFINE_PRIMITIVE ("CURRENT-JIFFY", Prim_current_jiffy, 0, 0, 0)
pub export fn Prim_current_jiffy() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n = abi.OS_current_jiffy();
    const neg_one: abi.ClockT = @bitCast(@as(isize, -1));
    return if (n == neg_one) obj.sharp_f else artutl.intmax_to_integer(clockToIntmax(n));
}

// DEFINE_PRIMITIVE ("JIFFIES-PER-SECOND", Prim_jiffies_per_second, 0, 0, 0)
pub export fn Prim_jiffies_per_second() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.intmax_to_integer(clockToIntmax(abi.OS_jiffies_per_second()));
}

// DEFINE_PRIMITIVE ("PROCESS-TIMER-CLEAR", Prim_process_timer_clear, 0, 0,
//   "Turn off the process timer.")
pub export fn Prim_process_timer_clear() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_process_timer_clear();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROCESS-TIMER-SET", Prim_process_timer_set, 2, 2,
//   "Set the process timer.\n\
// First arg FIRST says how long to wait until the first interrupt;\n\
// second arg INTERVAL says how long to wait between interrupts after that.\n\
// Both arguments are in units of milliseconds.")
pub export fn Prim_process_timer_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_process_timer_set(@intCast(abi.arg_nonnegative_integer(1)), @intCast(abi.arg_nonnegative_integer(2)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("REAL-TIMER-CLEAR", Prim_real_timer_clear, 0, 0,
//   "Turn off the real timer.")
pub export fn Prim_real_timer_clear() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_real_timer_clear();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("REAL-TIMER-SET", Prim_real_timer_set, 2, 2,
//   "Set the real timer.\n\
// First arg FIRST says how long to wait until the first interrupt;\n\
// second arg INTERVAL says how long to wait between interrupts after that.\n\
// Both arguments are in units of milliseconds.")
pub export fn Prim_real_timer_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_real_timer_set(@intCast(abi.arg_nonnegative_integer(1)), @intCast(abi.arg_nonnegative_integer(2)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROFILE-TIMER-CLEAR", Prim_profile_timer_clear, 0, 0,
//   "Turn off the profile timer.")
pub export fn Prim_profile_timer_clear() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_profile_timer_clear();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROFILE-TIMER-SET", Prim_profile_timer_set, 2, 2,
//   "Set the profile timer.\n\
// First arg FIRST says how long to wait until the first interrupt;\n\
// second arg INTERVAL says how long to wait between interrupts after that.\n\
// Both arguments are in units of milliseconds.")
pub export fn Prim_profile_timer_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_profile_timer_set(@intCast(abi.arg_nonnegative_integer(1)), @intCast(abi.arg_nonnegative_integer(2)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SETUP-TIMER-INTERRUPT", Prim_setup_timer_interrupt, 2, 2,
//   "This is an obsolete primitive; use `process-timer-set' instead.")
pub export fn Prim_setup_timer_interrupt() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (abi.argRef(1) == obj.sharp_f and abi.argRef(2) == obj.sharp_f) {
        abi.OS_process_timer_clear();
    } else {
        const days: c_ulong = @intCast(abi.arg_nonnegative_integer(1));
        const centisec: c_ulong = @intCast(abi.arg_nonnegative_integer(2));
        abi.OS_process_timer_set(@intCast(((days * 24 * 60 * 60 * 100) + centisec) * 10), 0);
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("WORKING-DIRECTORY-PATHNAME", Prim_working_dir_pathname, 0, 0,
//   "Return the current working directory as a string.")
pub export fn Prim_working_dir_pathname() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return string.char_pointer_to_string(abi.OS_working_dir_pathname());
}

// DEFINE_PRIMITIVE ("SET-WORKING-DIRECTORY-PATHNAME!", Prim_set_working_dir_pathname, 1, 1,
//   "Change the current working directory to NAME.")
pub export fn Prim_set_working_dir_pathname() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_set_working_dir_pathname(abi.stringArg(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SYSTEM-CALL-ERROR-MESSAGE", Prim_system_call_error_message, 1, 1, 0)
pub export fn Prim_system_call_error_message() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const message = abi.OS_error_code_to_message(@intCast(abi.arg_nonnegative_integer(1))) orelse return obj.sharp_f;
    return string.char_pointer_to_string(message);
}

test "prosenv time, clock, jiffy, timer, working-dir, and error message primitives" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    const p = abi.cons(obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{p});
    _ = Prim_nanotime_since_utc_epoch();
    try std.testing.expectEqual(obj.ulongToFixnum(123), obj.pairCar(p));
    try std.testing.expectEqual(obj.ulongToFixnum(456), obj.pairCdr(p));
    _ = Prim_monotonic_nanotime();
    try std.testing.expectEqual(obj.ulongToFixnum(789), obj.pairCar(p));

    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.ulongToFixnum(1700000000), Prim_encoded_time());
    try std.testing.expectEqual(obj.ulongToFixnum(100), Prim_system_clock());
    try std.testing.expectEqual(obj.ulongToFixnum(200), Prim_real_time_clock());
    try std.testing.expectEqual(obj.sharp_f, Prim_current_jiffy());
    stubs.mock_jiffy = 42;
    try std.testing.expectEqual(obj.ulongToFixnum(42), Prim_current_jiffy());
    try std.testing.expectEqual(obj.ulongToFixnum(1000), Prim_jiffies_per_second());

    const tv = abi.allocate_vector(10, true);
    stubs.setArgs(&.{ tv, obj.ulongToFixnum(1000) });
    _ = Prim_decode_time();
    try std.testing.expectEqual(obj.ulongToFixnum(2024), obj.vectorRef(tv, 6));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(tv, 8));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(tv, 9));
    _ = Prim_decode_utc();
    stubs.setArgs(&.{tv});
    try std.testing.expectEqual(obj.ulongToFixnum(1700000000), Prim_encode_time());

    const wd = Prim_working_dir_pathname();
    try std.testing.expectEqualStrings("/mock/wd", obj.legacyStringData(wd)[0..obj.legacyStringLength(wd)]);
    const new_wd = string.char_pointer_to_string("/mock/next");
    stubs.setArgs(&.{new_wd});
    _ = Prim_set_working_dir_pathname();

    stubs.setArgs(&.{obj.ulongToFixnum(1)});
    const err_s = Prim_system_call_error_message();
    try std.testing.expectEqualStrings("mock-err", obj.legacyStringData(err_s)[0..obj.legacyStringLength(err_s)]);
    stubs.setArgs(&.{obj.ulongToFixnum(99)});
    try std.testing.expectEqual(obj.sharp_f, Prim_system_call_error_message());
}
