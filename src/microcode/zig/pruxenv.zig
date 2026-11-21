// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxenv.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");
const artutl = @import("artutl.zig");
const prosproc = @import("prosproc.zig");

const hostname_size: usize = 1024;

const Hostent = extern struct {
    h_name: ?[*:0]u8,
    h_aliases: ?[*]?[*:0]u8,
    h_addrtype: c_int,
    h_length: c_int,
    h_addr_list: ?[*]?[*]u8,
};

extern "c" fn ctime(*const abi.TimeT) ?[*]u8;
extern "c" fn system([*:0]const u8) c_int;
extern "c" fn gethostbyname([*:0]const u8) ?*Hostent;

fn getHostnameBuf(buf: *[hostname_size]u8) [*:0]const u8 {
    while (std.c.gethostname(buf, buf.len) < 0) {
        abi.UX_prim_check_errno(abi.syscall_gethostname);
    }
    buf[buf.len - 1] = 0;
    return @ptrCast(buf);
}

// DEFINE_PRIMITIVE ("FILE-TIME->STRING", Prim_file_time_to_string, 1, 1,
//   "Convert a file system time stamp into a date/time string.")
pub export fn Prim_file_time_to_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    var clock: abi.TimeT = @intCast(abi.arg_index_integer_to_intmax(1, abi.time_t_max));
    const time_string = ctime(&clock) orelse abi.error_bad_range_arg(1);
    time_string[24] = 0;
    return string.char_pointer_to_string(@ptrCast(time_string));
}

// DEFINE_PRIMITIVE ("GET-USER-HOME-DIRECTORY", Prim_get_user_home_directory, 1, 1,
//   "Return the file name of a given user's home directory.\n\
// The user name argument must be a string.\n\
// If no such user is known, #F is returned.")
pub export fn Prim_get_user_home_directory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const entry = std.c.getpwnam(abi.stringArg(1)) orelse return obj.sharp_f;
    return string.char_pointer_to_string(entry.dir);
}

// DEFINE_PRIMITIVE ("UID->STRING", Prim_uid_to_string, 1, 1,
//   "Return the user name corresponding to UID.\n\
// If the argument is not a known user ID, #F is returned.")
pub export fn Prim_uid_to_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const uid: std.c.uid_t = @truncate(@as(u64, @intCast(abi.arg_nonnegative_integer(1))));
    const entry = std.c.getpwuid(uid) orelse return obj.sharp_f;
    return string.char_pointer_to_string(entry.name);
}

// DEFINE_PRIMITIVE ("GID->STRING", Prim_gid_to_string, 1, 1,
//   "Return the group name corresponding to GID.\n\
// If the argument is not a known group ID, #F is returned.")
pub export fn Prim_gid_to_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const gid: std.c.gid_t = @truncate(@as(u64, @intCast(abi.arg_nonnegative_integer(1))));
    const entry = std.c.getgrgid(gid) orelse return obj.sharp_f;
    return string.char_pointer_to_string(entry.name);
}

// DEFINE_PRIMITIVE ("CURRENT-PID", Prim_current_pid, 0, 0,
//   "Return Scheme's PID.")
pub export fn Prim_current_pid() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(std.c.getpid()));
}

// DEFINE_PRIMITIVE ("CURRENT-UID", Prim_current_uid, 0, 0,
//   "Return Scheme's effective UID.")
pub export fn Prim_current_uid() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(std.c.geteuid()));
}

// DEFINE_PRIMITIVE ("CURRENT-GID", Prim_current_gid, 0, 0,
//   "Return Scheme's effective GID.")
pub export fn Prim_current_gid() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(std.c.getegid()));
}

// DEFINE_PRIMITIVE ("REAL-UID", Prim_real_uid, 0, 0,
//   "Return Scheme's real UID.")
pub export fn Prim_real_uid() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(std.c.getuid()));
}

// DEFINE_PRIMITIVE ("REAL-GID", Prim_real_gid, 0, 0,
//   "Return Scheme's real GID.")
pub export fn Prim_real_gid() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(std.c.getgid()));
}

// DEFINE_PRIMITIVE ("CURRENT-USER-NAME", Prim_current_user_name, 0, 0,
//   "Return (as a string) the user name of the user running Scheme.")
pub export fn Prim_current_user_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return string.char_pointer_to_string(abi.OS_current_user_name());
}

// DEFINE_PRIMITIVE ("CURRENT-USER-HOME-DIRECTORY", Prim_current_user_home_directory, 0, 0,
//   "Return the name of the current user's home directory.")
pub export fn Prim_current_user_home_directory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return string.char_pointer_to_string(abi.OS_current_user_home_directory());
}

// DEFINE_PRIMITIVE ("SYSTEM", Prim_system, 1, 1,
//   "Invoke sh (the Bourne shell) on the string argument.\n\
// Wait until the shell terminates, returning its exit status as an integer.")
pub export fn Prim_system() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(system(abi.stringArg(1))));
}

// DEFINE_PRIMITIVE ("GET-ENVIRONMENT-VARIABLE", Prim_get_environment_variable, 1, 1,
//   "Look up the value of a variable in the user's shell environment.\n\
// The argument, a variable name, must be a string.\n\
// The result is either a string (the variable's value),\n\
//  or #F indicating that the variable does not exist.")
pub export fn Prim_get_environment_variable() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const variable_value = std.c.getenv(abi.stringArg(1)) orelse return obj.sharp_f;
    return string.char_pointer_to_string(variable_value);
}

// DEFINE_PRIMITIVE ("GET-ENVIRONMENT", Prim_get_environment, 0, 0, 0)
pub export fn Prim_get_environment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return prosproc.environVector();
}

// DEFINE_PRIMITIVE ("FULL-HOSTNAME", Prim_full_hostname, 0, 0,
//   "Returns the full hostname (including domain if available) as a string.")
pub export fn Prim_full_hostname() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var buf: [hostname_size]u8 = undefined;
    const host_name = getHostnameBuf(&buf);
    const entry = gethostbyname(host_name) orelse return obj.sharp_f;
    return string.char_pointer_to_string(entry.h_name);
}

// DEFINE_PRIMITIVE ("HOSTNAME", Prim_hostname, 0, 0,
//   "Returns the hostname of the machine as a string.")
pub export fn Prim_hostname() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var buf: [hostname_size]u8 = undefined;
    return string.char_pointer_to_string(getHostnameBuf(&buf));
}

// DEFINE_PRIMITIVE ("INSTRUCTION-ADDRESS->COMPILED-CODE-BLOCK",
//   Prim_instruction_address_to_compiled_code_block, 1, 1, 0)
pub export fn Prim_instruction_address_to_compiled_code_block() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (build_options.cc_support) {
        const object = abi.argRef(1);
        const pc: c_ulong = if (obj.integerP(object)) blk: {
            if (!artutl.integer_to_ulong_p(object)) abi.error_bad_range_arg(1);
            break :blk artutl.integer_to_ulong(object);
        } else blk: {
            if (!obj.ccEntryP(object)) abi.error_bad_range_arg(1);
            break :blk @intCast(obj.datumToRawAddress(obj.objectDatum(object)));
        };
        return abi.find_ccblock(pc);
    } else {
        abi.error_unimplemented_primitive();
    }
}

// DEFINE_PRIMITIVE ("MACOSX-MAIN-BUNDLE-DIR",
//   Prim_macosx_main_bundle_dir, 0, 0, 0)
pub export fn Prim_macosx_main_bundle_dir() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (builtin.os.tag.isDarwin()) {
        const path = abi.macosx_main_bundle_dir() orelse return obj.sharp_f;
        const n_words: c_ulong = 1 + obj.bytevectorLengthToGcLength(@intCast(std.mem.len(path)));
        if (abi.gcNeededP(n_words)) {
            std.c.free(@constCast(@ptrCast(path)));
            abi.primitiveGc(n_words);
        }
        const result = string.char_pointer_to_string_no_gc(path);
        std.c.free(@constCast(@ptrCast(path)));
        return result;
    } else {
        abi.error_unimplemented_primitive();
    }
}

// DEFINE_PRIMITIVE ("uname", Prim_uname, 0, 0, 0)
pub export fn Prim_uname() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var buf: std.c.utsname = undefined;
    while (std.c.uname(&buf) < 0) {
        abi.UX_prim_check_errno(abi.syscall_uname);
    }
    const v = abi.allocate_vector(5, true);
    obj.vectorSet(v, 0, string.char_pointer_to_string(&buf.sysname));
    obj.vectorSet(v, 1, string.char_pointer_to_string(&buf.nodename));
    obj.vectorSet(v, 2, string.char_pointer_to_string(&buf.release));
    obj.vectorSet(v, 3, string.char_pointer_to_string(&buf.version));
    obj.vectorSet(v, 4, string.char_pointer_to_string(&buf.machine));
    return v;
}

test "pruxenv pid, uid, gid, time string, env, hostname, uname, and ccblock lookup" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    stubs.setArgs(&.{});
    try std.testing.expect(obj.fixnumToLong(Prim_current_pid()) > 0);
    try std.testing.expect(obj.integerP(Prim_real_uid()));
    try std.testing.expect(obj.integerP(Prim_current_uid()));
    try std.testing.expect(obj.integerP(Prim_real_gid()));
    try std.testing.expect(obj.integerP(Prim_current_gid()));

    const uname_str = Prim_current_user_name();
    try std.testing.expectEqualStrings("mock-user", obj.legacyStringData(uname_str)[0..obj.legacyStringLength(uname_str)]);
    const home_str = Prim_current_user_home_directory();
    try std.testing.expectEqualStrings("/home/mock-user", obj.legacyStringData(home_str)[0..obj.legacyStringLength(home_str)]);

    const env_vec = Prim_get_environment();
    try std.testing.expect(obj.vectorP(env_vec));

    const hn = Prim_hostname();
    try std.testing.expect(obj.legacyStringLength(hn) > 0);

    const uvec = Prim_uname();
    try std.testing.expectEqual(@as(c_ulong, 5), obj.vectorLength(uvec));
    try std.testing.expect(obj.legacyStringLength(obj.vectorRef(uvec, 0)) > 0);

    stubs.setArgs(&.{obj.ulongToFixnum(0)});
    const fts = Prim_file_time_to_string();
    try std.testing.expectEqual(@as(c_ulong, 24), obj.legacyStringLength(fts));

    stubs.setArgs(&.{string.char_pointer_to_string("PATH")});
    const path_env = Prim_get_environment_variable();
    if (std.c.getenv("PATH") != null) {
        try std.testing.expect(path_env != obj.sharp_f);
    }

    if (build_options.cc_support) {
        stubs.setArgs(&.{obj.ulongToFixnum(0x1234)});
        try std.testing.expectEqual(obj.ulongToFixnum(0x1234), Prim_instruction_address_to_compiled_code_block());
    }
    if (builtin.os.tag.isDarwin()) {
        stubs.setArgs(&.{});
        try std.testing.expectEqual(obj.sharp_f, Prim_macosx_main_bundle_dir());
    }
}
