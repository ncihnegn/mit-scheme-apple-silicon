// Derived from MIT/GNU Scheme C sources (`src/microcode/prosproc.c`, `src/microcode/osproc.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const boot = @import("../core/boot.zig");
const wind = @import("../support/wind.zig");
const string = @import("../data/string.zig");
const win = @import("../os/win/win_api.zig");

fn argProcess(argument_number: c_int) abi.Tprocess {
    const process = abi.arg_ulong_integer(argument_number);
    const proc: abi.Tprocess = @intCast(process);
    if (abi.OS_process_valid_p(proc) == 0) {
        abi.error_bad_range_arg(argument_number);
    }
    return proc;
}

inline fn processSignalPrim(comptime signal_fn: *const fn (abi.Tprocess) callconv(.c) void) obj.SchemeObject {
    abi.primitiveHeader();
    signal_fn(argProcess(1));
    return obj.unspecific;
}

pub fn environVector() obj.SchemeObject {
    if (comptime builtin.os.tag == .windows) {
        const block = win.kernel32.GetEnvironmentStringsA() orelse return abi.allocate_vector(0, true);
        defer _ = win.kernel32.FreeEnvironmentStringsA(block);

        var count: usize = 0;
        var p: [*]const u8 = block;
        while (p[0] != 0) {
            const s: [*:0]const u8 = @ptrCast(p);
            const len = std.mem.len(s);
            if (p[0] != '=') count += 1;
            p += len + 1;
        }
        const result = abi.allocate_vector(@intCast(count), true);
        var idx: usize = 0;
        p = block;
        while (p[0] != 0) {
            const s: [*:0]const u8 = @ptrCast(p);
            const len = std.mem.len(s);
            if (p[0] != '=') {
                obj.vectorSet(result, idx, string.char_pointer_to_string(s));
                idx += 1;
            }
            p += len + 1;
        }
        return result;
    } else {
        var count: usize = 0;
        while (std.c.environ[count] != null) : (count += 1) {}
        const result = abi.allocate_vector(@intCast(count), true);
        for (0..count) |i| {
            obj.vectorSet(result, i, string.char_pointer_to_string(std.c.environ[i].?));
        }
        return result;
    }
}

// DEFINE_PRIMITIVE ("SCHEME-ENVIRONMENT", Prim_scheme_environment, 0, 0, 0)
pub export fn Prim_scheme_environment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return environVector();
}

// DEFINE_PRIMITIVE ("PROCESS-DELETE", Prim_process_delete, 1, 1,
//   "Delete process PROCESS-NUMBER from the process table.")
pub export fn Prim_process_delete() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_process_deallocate(argProcess(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROCESS-TABLE", Prim_process_table, 0, 0,
//   "Return a vector of all processes in the process table.")
pub export fn Prim_process_table() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    for (0..abi.OS_process_table_size) |p_u| {
        const process: abi.Tprocess = @intCast(p_u);
        if (abi.OS_process_valid_p(process) != 0) {
            boot.scratch_obstack.grow(std.mem.asBytes(&process));
        }
    }
    const n_processes = boot.scratch_obstack.objectSize() / @sizeOf(abi.Tprocess);
    if (n_processes == 0) {
        return obj.sharp_f;
    }
    const raw = boot.scratch_obstack.finish();
    const processes: [*]const abi.Tprocess = @ptrCast(@alignCast(raw));
    const vector = abi.allocate_vector(@intCast(n_processes), true);
    const vec_loc = obj.vectorLoc(vector, 0);
    for (0..n_processes) |i| {
        vec_loc[i] = abi.long_to_integer(@intCast(processes[i]));
    }
    boot.scratch_obstack.freeObj(@ptrCast(raw));
    return vector;
}

// DEFINE_PRIMITIVE ("PROCESS-ID", Prim_process_id, 1, 1,
//   "Return the process ID of process PROCESS-NUMBER.")
pub export fn Prim_process_id() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.ulong_to_integer(@intCast(abi.OS_process_id(argProcess(1))));
}

// DEFINE_PRIMITIVE ("PROCESS-JOB-CONTROL-STATUS", Prim_process_jc_status, 1, 1,
//   "Returns the job-control status of process PROCESS-NUMBER:\n\
//   0 means this system doesn't support job control.\n\
//   1 means the process doesn't have the same controlling terminal as Scheme.\n\
//   2 means it's the same ctty but the OS doesn't have job control.\n\
//   3 means it's the same ctty and the OS has job control.")
pub export fn Prim_process_jc_status() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const status = abi.OS_process_jc_status(argProcess(1));
    return switch (@as(abi.ProcessJcStatus, @fromBackingInt(@intCast(status)))) {
        .no_ctty => obj.ulongToFixnum(0),
        .unrelated => obj.ulongToFixnum(1),
        .no_jc => obj.ulongToFixnum(2),
        .jc => obj.ulongToFixnum(3),
    };
}

// DEFINE_PRIMITIVE ("PROCESS-STATUS-SYNC", Prim_process_status_sync, 1, 1,
//   "Synchronize the status of process PROCESS-NUMBER.\n\
// Return #F if it was previously synchronized, #T if not.")
pub export fn Prim_process_status_sync() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_process_status_sync(argProcess(1)) != 0);
}

// DEFINE_PRIMITIVE ("PROCESS-STATUS-SYNC-ALL", Prim_process_status_sync_all, 0, 0, 0)
pub export fn Prim_process_status_sync_all() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_process_status_sync_all() != 0);
}

// DEFINE_PRIMITIVE ("PROCESS-STATUS", Prim_process_status, 1, 1,
//   "Return the status of process PROCESS-NUMBER, a nonnegative integer:\n\
//   0 = running; 1 = stopped; 2 = exited; 3 = signalled.\n\
// The value is from the last synchronization.")
pub export fn Prim_process_status() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const status = abi.OS_process_status(argProcess(1));
    return switch (@as(abi.ProcessStatus, @fromBackingInt(@intCast(status)))) {
        .running => obj.ulongToFixnum(0),
        .stopped => obj.ulongToFixnum(1),
        .exited => obj.ulongToFixnum(2),
        .signalled => obj.ulongToFixnum(3),
        else => abi.error_external_return(),
    };
}

// DEFINE_PRIMITIVE ("PROCESS-REASON", Prim_process_reason, 1, 1,
//   "Return the termination reason of process PROCESS-NUMBER.\n\
// This is a nonnegative integer, which depends on the process's status:\n\
//   running => zero;\n\
//   stopped => the signal that stopped the process;\n\
//   exited => the exit code returned by the process;\n\
//   signalled => the signal that killed the process.\n\
// The value is from the last synchronization.")
pub export fn Prim_process_reason() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_process_reason(argProcess(1))));
}

// DEFINE_PRIMITIVE ("PROCESS-SIGNAL", Prim_process_signal, 2, 2,
//   "Send a signal to process PROCESS-NUMBER; second arg SIGNAL says which one.")
pub export fn Prim_process_signal() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_process_send_signal(argProcess(1), @intCast(abi.arg_nonnegative_integer(2)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROCESS-KILL", Prim_process_kill, 1, 1,
//   "Kills process PROCESS-NUMBER (unix SIGKILL).")
pub export fn Prim_process_kill() callconv(.c) obj.SchemeObject {
    return processSignalPrim(&abi.OS_process_kill);
}

// DEFINE_PRIMITIVE ("PROCESS-INTERRUPT", Prim_process_interrupt, 1, 1,
//   "Interrupts process PROCESS-NUMBER (unix SIGINT).")
pub export fn Prim_process_interrupt() callconv(.c) obj.SchemeObject {
    return processSignalPrim(&abi.OS_process_interrupt);
}

// DEFINE_PRIMITIVE ("PROCESS-QUIT", Prim_process_quit, 1, 1,
//   "Sends the quit signal to process PROCESS-NUMBER (unix SIGQUIT).")
pub export fn Prim_process_quit() callconv(.c) obj.SchemeObject {
    return processSignalPrim(&abi.OS_process_quit);
}

// DEFINE_PRIMITIVE ("PROCESS-HANGUP", Prim_process_hangup, 1, 1,
//   "Sends the hangup signal to process PROCESS-NUMBER (unix SIGHUP).")
pub export fn Prim_process_hangup() callconv(.c) obj.SchemeObject {
    return processSignalPrim(&abi.OS_process_hangup);
}

// DEFINE_PRIMITIVE ("PROCESS-STOP", Prim_process_stop, 1, 1,
//   "Stops process PROCESS-NUMBER (unix SIGTSTP).")
pub export fn Prim_process_stop() callconv(.c) obj.SchemeObject {
    return processSignalPrim(&abi.OS_process_stop);
}

// DEFINE_PRIMITIVE ("PROCESS-CONTINUE-BACKGROUND", Prim_process_continue_background, 1, 1,
//   "Continues process PROCESS-NUMBER in the background.")
pub export fn Prim_process_continue_background() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const process = argProcess(1);
    if (abi.OS_process_continuable_p(process) == 0) {
        abi.error_bad_range_arg(1);
    }
    abi.OS_process_continue_background(process);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROCESS-WAIT", Prim_process_wait, 1, 1,
//   "Waits until process PROCESS-NUMBER is not running.")
pub export fn Prim_process_wait() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_process_wait(argProcess(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PROCESS-CONTINUE-FOREGROUND", Prim_process_continue_foreground, 1, 1,
//   "Continues process PROCESS-NUMBER in the foreground.\n\
// The process must have the same controlling terminal as Scheme.")
pub export fn Prim_process_continue_foreground() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const process = argProcess(1);
    if (abi.OS_process_foregroundable_p(process) == 0 or abi.OS_process_continuable_p(process) == 0) {
        abi.error_bad_range_arg(1);
    }
    abi.OS_process_continue_foreground(process);
    return obj.unspecific;
}

pub fn stringVectorArg(arg_num: c_int) [*]const ?[*:0]const u8 {
    abi.checkArg(arg_num, stringVectorP);
    return convertStringVector(abi.argRef(@intCast(arg_num)));
}

pub fn stringVectorP(vector: obj.SchemeObject) bool {
    if (!obj.vectorP(vector)) return false;
    const length: usize = @intCast(obj.vectorLength(vector));
    const scan = obj.vectorLoc(vector, 0);
    for (0..length) |i| {
        if (!abi.string_p(scan[i])) return false;
    }
    return true;
}

pub fn convertStringVector(vector: obj.SchemeObject) [*]const ?[*:0]const u8 {
    const length: usize = @intCast(obj.vectorLength(vector));
    const raw = wind.dstack_alloc(@intCast((length + 1) * @sizeOf(?[*:0]const u8))).?;
    const result: [*]?[*:0]const u8 = @ptrCast(@alignCast(raw));
    const scan = obj.vectorLoc(vector, 0);
    for (0..length) |i| {
        result[i] = @ptrCast(obj.legacyStringData(scan[i]));
    }
    result[length] = null;
    return result;
}

pub const ChannelSpec = struct {
    channel_type: abi.ProcessChannelType,
    channel: abi.Tchannel,
};

pub fn processChannelArg(arg_num: c_int, ctty_type: abi.ProcessCttyType) ChannelSpec {
    const val = abi.argRef(@intCast(arg_num));
    if (val == obj.sharp_f) {
        return .{ .channel_type = .none, .channel = abi.no_channel };
    }
    if (val == obj.longToFixnum(-1)) {
        return .{ .channel_type = .inherit, .channel = abi.no_channel };
    }
    if (val == obj.longToFixnum(-2)) {
        if (ctty_type != .explicit) abi.error_bad_range_arg(arg_num);
        return .{ .channel_type = .ctty, .channel = abi.no_channel };
    }
    return .{ .channel_type = .explicit, .channel = abi.arg_channel(arg_num) };
}

// DEFINE_PRIMITIVE ("MAKE-SUBPROCESS", Prim_make_subprocess, 7, 7,
//   "Create a subprocess.\n\
// First arg FILENAME is the program to run.\n\
// Second arg ARGV is a vector of strings to pass to the program as arguments.\n\
// Third arg ENV is a vector of strings to pass as the program's environment;\n\
//   #F means inherit Scheme's environment.\n\
// Fourth arg CTTY specifies the program's controlling terminal:\n\
//   #F means none;\n\
//   -1 means use Scheme's controlling terminal in background;\n\
//   -2 means use Scheme's controlling terminal in foreground;\n\
//   string means open that terminal.\n\
// Fifth arg STDIN is the input channel for the subprocess.\n\
// Sixth arg STDOUT is the output channel for the subprocess.\n\
// Seventh arg STDERR is the error channel for the subprocess.\n\
//   Each channel arg can take these values:\n\
//   #F means none;\n\
//   -1 means use the corresponding channel from Scheme;\n\
//   -2 means use the controlling terminal (valid only when CTTY is a string);\n\
//   otherwise the argument must be a channel.")
pub export fn Prim_make_subprocess() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, stringVectorP);
    const position = wind.dstack_position;
    const filename = abi.stringArg(1);
    const argv = convertStringVector(abi.argRef(2));
    var env_object = abi.argRef(3);
    var env: ?[*]const ?[*:0]const u8 = null;
    var working_directory: ?[*:0]const u8 = null;
    var ctty_type: abi.ProcessCttyType = undefined;
    var ctty_name: ?[*:0]u8 = null;

    if (obj.pairP(env_object) and abi.string_p(obj.pairCdr(env_object))) {
        working_directory = @ptrCast(obj.legacyStringData(obj.pairCdr(env_object)));
        env_object = obj.pairCar(env_object);
    }
    if (env_object != obj.sharp_f) {
        if (!stringVectorP(env_object)) abi.error_wrong_type_arg(3);
        env = convertStringVector(env_object);
    }
    const ctty_arg = abi.argRef(4);
    if (ctty_arg == obj.sharp_f) {
        ctty_type = .none;
    } else if (ctty_arg == obj.longToFixnum(-1)) {
        ctty_type = .inherit_bg;
    } else if (ctty_arg == obj.longToFixnum(-2)) {
        ctty_type = .inherit_fg;
    } else {
        ctty_type = .explicit;
        ctty_name = abi.stringArg(4);
    }

    const cin = processChannelArg(5, ctty_type);
    const cout = processChannelArg(6, ctty_type);
    const cerr = processChannelArg(7, ctty_type);

    const process = abi.OS_make_subprocess(
        filename,
        argv,
        env,
        working_directory,
        ctty_type,
        ctty_name,
        cin.channel_type,
        cin.channel,
        cout.channel_type,
        cout.channel,
        cerr.channel_type,
        cerr.channel,
    );
    wind.dstack_set_position(position);
    return abi.long_to_integer(@intCast(process));
}

test "prosproc environment, process table, status, signals, and make-subprocess" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    boot.scratch_obstack.init(&boot.obstack_chunk_alloc, &std.c.free);
    defer boot.scratch_obstack.freeObj(null);
    wind.dstack_initialize();
    defer wind.dstack_reset();
    defer stubs.resetMockRuntime();

    // SCHEME-ENVIRONMENT returns vector of strings matching OS environ
    stubs.setArgs(&.{});
    const env_vec = Prim_scheme_environment();
    try std.testing.expect(obj.vectorP(env_vec));
    if (comptime builtin.os.tag != .windows) {
        if (std.c.environ[0] != null) {
            try std.testing.expect(obj.vectorLength(env_vec) >= 1);
        }
    }

    // Empty PROCESS-TABLE returns #F
    try std.testing.expectEqual(obj.sharp_f, Prim_process_table());

    // MAKE-SUBPROCESS with (env . working_dir) and explicit/inherited channels
    const prog = string.char_pointer_to_string("/bin/echo");
    const argv_vec = abi.allocate_vector(2, true);
    obj.vectorSet(argv_vec, 0, prog);
    obj.vectorSet(argv_vec, 1, string.char_pointer_to_string("hi"));
    const env_list_vec = abi.allocate_vector(1, true);
    obj.vectorSet(env_list_vec, 0, string.char_pointer_to_string("FOO=bar"));
    const env_pair = abi.cons(env_list_vec, string.char_pointer_to_string("/tmp"));
    stubs.setMockChannel(1, @backingInt(abi.ChannelType.unix_pipe), false);
    stubs.setArgs(&.{
        prog,
        argv_vec,
        env_pair,
        obj.longToFixnum(-1),
        obj.ulongToFixnum(1),
        obj.sharp_f,
        obj.longToFixnum(-1),
    });
    const pidx = Prim_make_subprocess();
    try std.testing.expectEqual(obj.ulongToFixnum(0), pidx);

    // Query table & status primitives
    stubs.setArgs(&.{});
    const ptbl = Prim_process_table();
    try std.testing.expectEqual(@as(usize, 1), obj.vectorLength(ptbl));
    try std.testing.expectEqual(pidx, obj.vectorRef(ptbl, 0));

    stubs.setArgs(&.{pidx});
    try std.testing.expectEqual(obj.ulongToFixnum(4321), Prim_process_id());
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_process_jc_status());
    try std.testing.expectEqual(obj.sharp_t, Prim_process_status_sync());
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_process_status());
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_process_reason());
    try std.testing.expectEqual(obj.sharp_t, Prim_process_status_sync_all());

    _ = Prim_process_stop();
    _ = Prim_process_continue_background();
    _ = Prim_process_continue_foreground();
    _ = Prim_process_interrupt();
    _ = Prim_process_quit();
    _ = Prim_process_hangup();
    _ = Prim_process_kill();
    _ = Prim_process_wait();
    stubs.setArgs(&.{ pidx, obj.ulongToFixnum(15) });
    _ = Prim_process_signal();
    try std.testing.expectEqual(@as(c_int, 15), stubs.mock_last_proc_sig);

    stubs.setArgs(&.{pidx});
    _ = Prim_process_delete();
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.sharp_f, Prim_process_table());
}
