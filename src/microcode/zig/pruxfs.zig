// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxfs.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");
const utils = @import("utils.zig");
const artutl = @import("artutl.zig");

const Utimbuf = extern struct {
    actime: abi.TimeT,
    modtime: abi.TimeT,
};

extern "c" fn utime([*:0]const u8, ?*const Utimbuf) c_int;

inline fn fileStatTimePrim(
    comptime stat_fn: *const fn ([*:0]const u8, *abi.Stat) callconv(.c) c_int,
    comptime which: enum { mod, acc },
) obj.SchemeObject {
    abi.primitiveHeader();
    var s: abi.Stat = undefined;
    if (stat_fn(abi.stringArg(1), &s) == 0) {
        return obj.sharp_f;
    }
    const sec: i64 = switch (which) {
        .mod => @intCast(s.mtime().sec),
        .acc => @intCast(s.atime().sec),
    };
    return artutl.intmax_to_integer(sec);
}

inline fn fileAttributesPrim(
    comptime stat_fn: *const fn ([*:0]const u8, *abi.Stat) callconv(.c) c_int,
) obj.SchemeObject {
    abi.primitiveHeader();
    var s: abi.Stat = undefined;
    if (stat_fn(abi.stringArg(1), &s) == 0) {
        return obj.sharp_f;
    }
    return fileAttributesInternal(&s);
}

fn fileAttributesInternal(s: *const abi.Stat) obj.SchemeObject {
    const result = abi.allocate_vector(10, true);
    const modes = abi.allocate_string(10);
    const mode: u32 = s.mode;
    const fmt = mode & std.c.S.IFMT;
    if (fmt == std.c.S.IFDIR) {
        obj.vectorSet(result, 0, obj.sharp_t);
    } else if (fmt == std.c.S.IFLNK) {
        obj.vectorSet(result, 0, string.char_pointer_to_string(abi.OS_file_soft_link_p(@ptrCast(obj.legacyStringData(abi.argRef(1))))));
    } else {
        obj.vectorSet(result, 0, obj.sharp_f);
    }
    obj.vectorSet(result, 1, artutl.intmax_to_integer(@as(i64, @bitCast(@as(u64, s.nlink)))));
    obj.vectorSet(result, 2, artutl.intmax_to_integer(@intCast(s.uid)));
    obj.vectorSet(result, 3, artutl.intmax_to_integer(@intCast(s.gid)));
    obj.vectorSet(result, 4, artutl.intmax_to_integer(@intCast(s.atime().sec)));
    obj.vectorSet(result, 5, artutl.intmax_to_integer(@intCast(s.mtime().sec)));
    obj.vectorSet(result, 6, artutl.intmax_to_integer(@intCast(s.ctime().sec)));
    obj.vectorSet(result, 7, artutl.intmax_to_integer(@intCast(s.size)));
    fileModeString(s, obj.legacyStringData(modes));
    obj.vectorSet(result, 8, modes);
    obj.vectorSet(result, 9, artutl.intmax_to_integer(@as(i64, @bitCast(@as(u64, s.ino)))));
    return result;
}

fn fileModeString(s: *const abi.Stat, a: [*]u8) void {
    const mode: u32 = s.mode;
    a[0] = fileTypeLetter(mode);
    rwx((mode & 0o700) << 0, a + 1);
    rwx((mode & 0o070) << 3, a + 4);
    rwx((mode & 0o007) << 6, a + 7);
    if ((mode & std.c.S.ISUID) != 0) {
        a[3] = if (a[3] == 'x') 's' else 'S';
    }
    if ((mode & std.c.S.ISGID) != 0) {
        a[6] = if (a[6] == 'x') 's' else 'S';
    }
    if ((mode & std.c.S.ISVTX) != 0) {
        a[9] = if (a[9] == 'x') 't' else 'T';
    }
}

fn fileTypeLetter(mode: u32) u8 {
    return switch (mode & std.c.S.IFMT) {
        std.c.S.IFDIR => 'd',
        std.c.S.IFCHR => 'c',
        std.c.S.IFBLK => 'b',
        std.c.S.IFLNK => 'l',
        std.c.S.IFSOCK => 's',
        std.c.S.IFIFO => 'p',
        else => '-',
    };
}

fn rwx(bits: u32, chars: [*]u8) void {
    chars[0] = if ((bits & std.c.S.IRUSR) != 0) 'r' else '-';
    chars[1] = if ((bits & std.c.S.IWUSR) != 0) 'w' else '-';
    chars[2] = if ((bits & std.c.S.IXUSR) != 0) 'x' else '-';
}

// DEFINE_PRIMITIVE ("FILE-MODES", Prim_file_modes, 1, 1,
//   "Return mode bits of FILE, as an integer.")
pub export fn Prim_file_modes() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var stat_result: abi.Stat = undefined;
    if (abi.UX_read_file_status_indirect(abi.stringArg(1), &stat_result) == 0) {
        return obj.sharp_f;
    }
    return obj.longToUnsignedFixnum(@intCast(stat_result.mode & 0o7777));
}

// DEFINE_PRIMITIVE ("SET-FILE-MODES!", Prim_set_file_modes, 2, 2,
//   "Set the mode bits of FILE to MODE.")
pub export fn Prim_set_file_modes() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const path = abi.stringArg(1);
    const mode: std.c.mode_t = @intCast(abi.arg_index_integer(2, 0o10000));
    if (std.c.chmod(path, mode) < 0) {
        utils.error_system_call(std.c._errno().*, abi.syscall_chmod);
    }
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("FILE-MOD-TIME", Prim_file_mod_time, 1, 1, 0)
pub export fn Prim_file_mod_time() callconv(.c) obj.SchemeObject {
    return fileStatTimePrim(&abi.UX_read_file_status, .mod);
}

// DEFINE_PRIMITIVE ("FILE-MOD-TIME-INDIRECT", Prim_file_mod_time_indirect, 1, 1, 0)
pub export fn Prim_file_mod_time_indirect() callconv(.c) obj.SchemeObject {
    return fileStatTimePrim(&abi.UX_read_file_status_indirect, .mod);
}

// DEFINE_PRIMITIVE ("FILE-ACCESS-TIME", Prim_file_acc_time, 1, 1, 0)
pub export fn Prim_file_acc_time() callconv(.c) obj.SchemeObject {
    return fileStatTimePrim(&abi.UX_read_file_status, .acc);
}

// DEFINE_PRIMITIVE ("FILE-ACCESS-TIME-INDIRECT", Prim_file_acc_time_indirect, 1, 1, 0)
pub export fn Prim_file_acc_time_indirect() callconv(.c) obj.SchemeObject {
    return fileStatTimePrim(&abi.UX_read_file_status_indirect, .acc);
}

// DEFINE_PRIMITIVE ("SET-FILE-TIMES!", Prim_set_file_times, 3, 3,
//   "Change the access and modification times of FILE.\n\
// The second and third arguments are the respective times.\n\
// The file must exist and you must be the owner (or superuser).")
pub export fn Prim_set_file_times() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var times = Utimbuf{
        .actime = @intCast(abi.arg_index_integer_to_intmax(2, abi.time_t_max)),
        .modtime = @intCast(abi.arg_index_integer_to_intmax(3, abi.time_t_max)),
    };
    const path = abi.stringArg(1);
    while (utime(path, &times) < 0) {
        abi.UX_prim_check_errno(abi.syscall_utime);
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CHANNEL-FILE-ATTRIBUTES", Prim_channel_file_attributes, 1, 1, 0)
pub export fn Prim_channel_file_attributes() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var s: abi.Stat = undefined;
    abi.UX_read_fd_status(abi.UX_channel_descriptor(abi.arg_channel(1)), &s);
    return fileAttributesInternal(&s);
}

// DEFINE_PRIMITIVE ("FILE-ATTRIBUTES", Prim_file_attributes, 1, 1,
//   "Given a file name, return attribute information about the file.\n\
// If the file exists and its status information is accessible, the result\n\
// is a vector of 10 items (see the reference manual for details).  Otherwise\n\
// the result is #F.")
pub export fn Prim_file_attributes() callconv(.c) obj.SchemeObject {
    return fileAttributesPrim(&abi.UX_read_file_status);
}

// DEFINE_PRIMITIVE ("FILE-ATTRIBUTES-INDIRECT", Prim_file_attributes_indirect, 1, 1,
//   "Like FILE-ATTRIBUTES but indirect through symbolic links.")
pub export fn Prim_file_attributes_indirect() callconv(.c) obj.SchemeObject {
    return fileAttributesPrim(&abi.UX_read_file_status_indirect);
}

// DEFINE_PRIMITIVE ("FILE-EQ?", Prim_file_eq_p, 2, 2,
//   "True iff the two file arguments are the same file.")
pub export fn Prim_file_eq_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var s1: abi.Stat = undefined;
    var s2: abi.Stat = undefined;
    return obj.booleanToObject(
        abi.UX_read_file_status(abi.stringArg(1), &s1) != 0 and
            abi.UX_read_file_status(abi.stringArg(2), &s2) != 0 and
            s1.dev == s2.dev and
            s1.ino == s2.ino,
    );
}

// DEFINE_PRIMITIVE ("FILE-SYSTEM-TYPE", Prim_file_system_type, 1, 1, 0)
pub export fn Prim_file_system_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.UX_file_system_type(abi.stringArg(1)) orelse "unknown";
    return string.char_pointer_to_string(result);
}

fn setTestStatTimes(s: *abi.Stat, acc_sec: i64, mod_sec: i64, c_sec: i64) void {
    if (comptime builtin.os.tag.isDarwin()) {
        s.atimespec.sec = @intCast(acc_sec);
        s.mtimespec.sec = @intCast(mod_sec);
        s.ctimespec.sec = @intCast(c_sec);
    } else {
        s.atim.sec = @intCast(acc_sec);
        s.mtim.sec = @intCast(mod_sec);
        s.ctim.sec = @intCast(c_sec);
    }
}

test "pruxfs modes, times, attributes, mode string, file-eq?, and filesystem type" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    stubs.mock_stat.dev = 7;
    stubs.mock_stat.ino = 12345;
    stubs.mock_stat.mode = std.c.S.IFREG | std.c.S.ISUID | 0o751;
    stubs.mock_stat.nlink = 2;
    stubs.mock_stat.uid = 501;
    stubs.mock_stat.gid = 20;
    stubs.mock_stat.size = 4096;
    setTestStatTimes(&stubs.mock_stat, 1001, 1002, 1003);

    stubs.mock_stat_2 = stubs.mock_stat;

    const fname = string.char_pointer_to_string("/mock/file");
    stubs.setArgs(&.{fname});
    try std.testing.expectEqual(obj.ulongToFixnum(std.c.S.ISUID | 0o751), Prim_file_modes());
    try std.testing.expectEqual(obj.ulongToFixnum(1002), Prim_file_mod_time());
    try std.testing.expectEqual(obj.ulongToFixnum(1002), Prim_file_mod_time_indirect());
    try std.testing.expectEqual(obj.ulongToFixnum(1001), Prim_file_acc_time());
    try std.testing.expectEqual(obj.ulongToFixnum(1001), Prim_file_acc_time_indirect());

    const attrs = Prim_file_attributes();
    try std.testing.expectEqual(@as(c_ulong, 10), obj.vectorLength(attrs));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(attrs, 0));
    try std.testing.expectEqual(obj.ulongToFixnum(2), obj.vectorRef(attrs, 1));
    try std.testing.expectEqual(obj.ulongToFixnum(501), obj.vectorRef(attrs, 2));
    try std.testing.expectEqual(obj.ulongToFixnum(20), obj.vectorRef(attrs, 3));
    try std.testing.expectEqual(obj.ulongToFixnum(1001), obj.vectorRef(attrs, 4));
    try std.testing.expectEqual(obj.ulongToFixnum(1002), obj.vectorRef(attrs, 5));
    try std.testing.expectEqual(obj.ulongToFixnum(1003), obj.vectorRef(attrs, 6));
    try std.testing.expectEqual(obj.ulongToFixnum(4096), obj.vectorRef(attrs, 7));
    try std.testing.expectEqualStrings("-rwsr-x--x", obj.legacyStringData(obj.vectorRef(attrs, 8))[0..10]);
    try std.testing.expectEqual(obj.ulongToFixnum(12345), obj.vectorRef(attrs, 9));

    // Directory + setgid (no group x) + sticky (with other x)
    stubs.mock_stat.mode = std.c.S.IFDIR | std.c.S.ISGID | std.c.S.ISVTX | 0o741;
    stubs.setMockChannel(4, @intFromEnum(abi.ChannelType.directory), false);
    stubs.setArgs(&.{obj.ulongToFixnum(4)});
    const dir_attrs = Prim_channel_file_attributes();
    try std.testing.expectEqual(obj.sharp_t, obj.vectorRef(dir_attrs, 0));
    try std.testing.expectEqualStrings("drwxr-S--t", obj.legacyStringData(obj.vectorRef(dir_attrs, 8))[0..10]);

    // Symlink attributes resolve target name via OS_file_soft_link_p
    stubs.mock_stat.mode = std.c.S.IFLNK | 0o777;
    stubs.mock_soft_link = "/target/path";
    stubs.setArgs(&.{fname});
    const lnk_attrs = Prim_file_attributes_indirect();
    const target_obj = obj.vectorRef(lnk_attrs, 0);
    try std.testing.expectEqualStrings("/target/path", obj.legacyStringData(target_obj)[0..obj.legacyStringLength(target_obj)]);
    try std.testing.expectEqualStrings("lrwxrwxrwx", obj.legacyStringData(obj.vectorRef(lnk_attrs, 8))[0..10]);

    // FILE-EQ?
    stubs.setArgs(&.{ fname, string.char_pointer_to_string("/same-alias") });
    try std.testing.expectEqual(obj.sharp_t, Prim_file_eq_p());
    stubs.mock_stat_2.ino = 99999;
    try std.testing.expectEqual(obj.sharp_f, Prim_file_eq_p());

    // FILE-SYSTEM-TYPE
    stubs.setArgs(&.{fname});
    const fs1 = Prim_file_system_type();
    try std.testing.expectEqualStrings("apfs", obj.legacyStringData(fs1)[0..obj.legacyStringLength(fs1)]);
    stubs.mock_fs_type = null;
    const fs2 = Prim_file_system_type();
    try std.testing.expectEqualStrings("unknown", obj.legacyStringData(fs2)[0..obj.legacyStringLength(fs2)]);
}
