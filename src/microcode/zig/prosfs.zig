// Derived from MIT/GNU Scheme C sources (`src/microcode/prosfs.c`, `src/microcode/osfs.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");

const file_copy_buffer_length: usize = 8192;

inline fn fileExistencePrim(comptime test_fn: *const fn ([*:0]const u8) callconv(.c) c_uint) obj.SchemeObject {
    abi.primitiveHeader();
    const res = test_fn(abi.stringArg(1));
    return switch (@as(abi.FileExistence, @enumFromInt(res))) {
        .doesnt_exist => obj.sharp_f,
        .does_exist => obj.sharp_t,
        .is_link => obj.ulongToFixnum(0),
    };
}

inline fn fileTypePrim(comptime type_fn: *const fn ([*:0]const u8) callconv(.c) c_int) obj.SchemeObject {
    abi.primitiveHeader();
    const t = type_fn(abi.stringArg(1));
    return if (t == @intFromEnum(abi.FileType.nonexistent))
        obj.sharp_f
    else
        abi.ulong_to_integer(@intCast(t));
}

// DEFINE_PRIMITIVE ("FILE-EXISTS?", Prim_file_exists_p, 1, 1,
//   "Return #T iff FILENAME refers to an existing file.\n\
// Return #F if the file doesn't exist.\n\
// Return zero if it's a symbolic link that points to a nonexisting file.\n\
// Signal an error if the file's existence is indeterminate.")
pub export fn Prim_file_exists_p() callconv(.c) obj.SchemeObject {
    return fileExistencePrim(&abi.OS_file_existence_test);
}

// DEFINE_PRIMITIVE ("FILE-EXISTS-DIRECT?", Prim_file_exists_direct_p, 1, 1,
//   "Return #T iff FILENAME refers to an existing file.\n\
// Return #F if the file doesn't exist.\n\
// Return zero if it's a symbolic link.\n\
// Signal an error if the file's existence is indeterminate.")
pub export fn Prim_file_exists_direct_p() callconv(.c) obj.SchemeObject {
    return fileExistencePrim(&abi.OS_file_existence_test_direct);
}

// DEFINE_PRIMITIVE ("FILE-TYPE-DIRECT", Prim_file_type_direct, 1, 1,
//   "Return type of FILE, as an exact non-negative integer.\n\
// Don't indirect through symbolic links.")
pub export fn Prim_file_type_direct() callconv(.c) obj.SchemeObject {
    return fileTypePrim(&abi.OS_file_type_direct);
}

// DEFINE_PRIMITIVE ("FILE-TYPE-INDIRECT", Prim_file_type_indirect, 1, 1,
//   "Return type of FILE, as an exact non-negative integer.\n\
// Indirect through symbolic links.")
pub export fn Prim_file_type_indirect() callconv(.c) obj.SchemeObject {
    return fileTypePrim(&abi.OS_file_type_indirect);
}

// DEFINE_PRIMITIVE ("FILE-ACCESS", Prim_file_access, 2, 2,
//   "Return #T iff FILENAME exists and is accessible according to MODE.\n\
// MODE is an integer between 0 and 7 inclusive, bitwise encoded:\n\
//   4 ==> file is readable;\n\
//   2 ==> file is writable;\n\
//   1 ==> file is executable.")
pub export fn Prim_file_access() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_file_access(abi.stringArg(1), @intCast(abi.arg_index_integer(2, 8))) != 0);
}

// DEFINE_PRIMITIVE ("FILE-DIRECTORY?", Prim_file_directory_p, 1, 1,
//   "Return #T iff FILENAME refers to an existing directory.\n\
// Otherwise #F is returned, meaning either that FILENAME doesn't exist\n\
//  or that it isn't a directory.")
pub export fn Prim_file_directory_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_file_directory_p(abi.stringArg(1)) != 0);
}

// DEFINE_PRIMITIVE ("FILE-SOFT-LINK?", Prim_file_soft_link_p, 1, 1,
//   "Iff FILENAME refers to an existing soft link, return the link contents.\n\
// Otherwise #F is returned, meaning either that FILENAME doesn't exist\n\
//  or that it isn't a soft link.")
pub export fn Prim_file_soft_link_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const res = abi.OS_file_soft_link_p(abi.stringArg(1)) orelse return obj.sharp_f;
    return string.char_pointer_to_string(res);
}

// DEFINE_PRIMITIVE ("FILE-REMOVE", Prim_file_remove, 1, 1,
//   "Delete file FILENAME.\n\
// If FILENAME is a soft link, the link is deleted.")
pub export fn Prim_file_remove() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_remove(abi.stringArg(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FILE-REMOVE-LINK", Prim_file_remove_link, 1, 1,
//   "If file FILENAME is a link to another file (hard or soft), remove it.")
pub export fn Prim_file_remove_link() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_remove_link(abi.stringArg(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FILE-RENAME", Prim_file_rename, 2, 2,
//   "Rename file FROM-NAME to TO-NAME.")
pub export fn Prim_file_rename() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_rename(abi.stringArg(1), abi.stringArg(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FILE-LINK-HARD", Prim_file_link_hard, 2, 2,
//   "Create a hard link from file FROM-NAME to file TO-NAME.\n\
// TO-NAME becomes another name for the file FROM-NAME.")
pub export fn Prim_file_link_hard() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_link_hard(abi.stringArg(1), abi.stringArg(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FILE-LINK-SOFT", Prim_file_link_soft, 2, 2,
//   "Create a soft link from file FROM-NAME to file TO-NAME.\n\
// TO-NAME becomes a soft link containing the string FROM-NAME.")
pub export fn Prim_file_link_soft() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_link_soft(abi.stringArg(1), abi.stringArg(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("LINK-FILE", Prim_link_file, 3, 3,
//   "This is an obsolete primitive.  Use `file-link-hard' or `file-link-soft'.\n\
// Create a new name for file FROM-NAME, called TO-NAME.\n\
// If third arg HARD? is #F, a soft link is created;\n\
//  otherwise a hard link is created.")
pub export fn Prim_link_file() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const from_name = abi.stringArg(1);
    const to_name = abi.stringArg(2);
    if (abi.argRef(3) != obj.sharp_f) {
        abi.OS_file_link_hard(from_name, to_name);
    } else {
        abi.OS_file_link_soft(from_name, to_name);
    }
    return obj.unspecific;
}

pub export fn OS_channel_copy(
    source_length_init: abi.OffT,
    source_channel: abi.Tchannel,
    destination_channel: abi.Tchannel,
) callconv(.c) c_int {
    var buffer: [file_copy_buffer_length]u8 = undefined;
    var source_length = source_length_init;
    var transfer_length: usize = if (source_length > @as(abi.OffT, @intCast(buffer.len)))
        buffer.len
    else if (source_length > 0)
        @intCast(source_length)
    else
        0;

    while (source_length > 0) {
        const nread = abi.OS_channel_read(source_channel, &buffer, transfer_length);
        if (nread <= 0) return -1;
        const nread_u: usize = @intCast(nread);
        if (abi.OS_channel_write(destination_channel, &buffer, nread_u) < nread) return -1;
        source_length -= @intCast(nread_u);
        if (source_length < @as(abi.OffT, @intCast(buffer.len)) and source_length >= 0) {
            transfer_length = @intCast(source_length);
        }
    }
    return 0;
}

// DEFINE_PRIMITIVE ("FILE-COPY", Prim_file_copy, 2, 2,
//   "Make a new copy of the file FROM-NAME, called TO-NAME.")
pub export fn Prim_file_copy() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_copy(abi.stringArg(1), abi.stringArg(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("DIRECTORY-MAKE", Prim_directory_make, 1, 1,
//   "Create a new directory, called NAME.")
pub export fn Prim_directory_make() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_directory_make(abi.stringArg(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("DIRECTORY-DELETE", Prim_directory_delete, 1, 1,
//   "Delete directory called NAME.")
pub export fn Prim_directory_delete() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_directory_delete(abi.stringArg(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FILE-TOUCH", Prim_file_touch, 1, 1,
//   "Given a file name, change the times of the file to the current time.\n\
// If the file does not exist, create it.\n\
// Both the access time and modification time are changed.\n\
// Return #F if the file existed and its time was modified.\n\
// Otherwise the file did not exist and it was created.")
pub export fn Prim_file_touch() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const rc = abi.OS_file_touch(abi.stringArg(1));
    if (rc < 0) abi.error_bad_range_arg(1);
    return obj.booleanToObject(rc != 0);
}

// DEFINE_PRIMITIVE ("NEW-DIRECTORY-OPEN", Prim_new_directory_open, 1, 1,
//   "Open the directory NAME for reading, returning a directory number.")
pub export fn Prim_new_directory_open() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_directory_open(abi.stringArg(1))));
}

fn argDirectoryIndex(argument: c_int) c_uint {
    const index = abi.arg_ulong_integer(argument);
    if (abi.OS_directory_valid_p(@intCast(index)) == 0) {
        abi.error_bad_range_arg(argument);
    }
    return @intCast(index);
}

// DEFINE_PRIMITIVE ("NEW-DIRECTORY-CLOSE", Prim_new_directory_close, 1, 1,
//   "Close DIRECTORY.")
pub export fn Prim_new_directory_close() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_directory_close(argDirectoryIndex(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("NEW-DIRECTORY-READ", Prim_new_directory_read, 1, 1,
//   "Read and return a filename from DIRECTORY, or #F if no more files.")
pub export fn Prim_new_directory_read() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.OS_directory_read(argDirectoryIndex(1)) orelse return obj.sharp_f;
    return string.char_pointer_to_string_no_gc(result);
}

// DEFINE_PRIMITIVE ("NEW-DIRECTORY-READ-MATCHING",
//                   Prim_new_directory_read_match, 2, 2,
//   "Read and return a filename from DIRECTORY.\n\
// The filename must begin with the STRING.\n\
// Return #F if there are no more matching files in the directory.")
pub export fn Prim_new_directory_read_match() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.OS_directory_read_matching(argDirectoryIndex(1), abi.stringArg(2)) orelse return obj.sharp_f;
    return string.char_pointer_to_string_no_gc(result);
}

test "prosfs file queries, copy, touch, and directory primitives" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    const p = string.char_pointer_to_string("/tmp/alpha");
    const link_target = string.char_pointer_to_string("/tmp/beta");
    stubs.mock_file_existence = @intFromEnum(abi.FileExistence.is_link);
    stubs.setArgs(&.{p});
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_file_exists_p());
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_file_exists_direct_p());

    stubs.mock_file_type = @intFromEnum(abi.FileType.regular);
    try std.testing.expectEqual(obj.ulongToFixnum(@intCast(@intFromEnum(abi.FileType.regular))), Prim_file_type_direct());
    stubs.mock_file_type = @intFromEnum(abi.FileType.nonexistent);
    try std.testing.expectEqual(obj.sharp_f, Prim_file_type_indirect());

    stubs.setArgs(&.{ p, obj.ulongToFixnum(4) });
    try std.testing.expectEqual(obj.sharp_f, Prim_file_access());
    stubs.setArgs(&.{p});
    try std.testing.expectEqual(obj.sharp_f, Prim_file_directory_p());
    stubs.mock_soft_link = "/target";
    const sres = Prim_file_soft_link_p();
    try std.testing.expectEqualStrings("/target", obj.legacyStringData(sres)[0..obj.legacyStringLength(sres)]);

    stubs.setArgs(&.{p});
    try std.testing.expectEqual(obj.sharp_t, Prim_file_touch());

    // OS_channel_copy roundtrip
    stubs.setMockChannel(1, @intFromEnum(abi.ChannelType.file), false);
    stubs.setMockChannel(2, @intFromEnum(abi.ChannelType.file), false);
    _ = abi.OS_channel_write(1, "abcde", 5);
    try std.testing.expectEqual(@as(c_int, 0), OS_channel_copy(5, 1, 2));

    // Link / copy / directory lifecycle
    stubs.setArgs(&.{ p, link_target, obj.sharp_t });
    _ = Prim_link_file();
    stubs.setArgs(&.{p});
    const d = Prim_new_directory_open();
    stubs.setArgs(&.{d});
    const entry1 = Prim_new_directory_read();
    try std.testing.expectEqualStrings("entry.scm", obj.legacyStringData(entry1)[0..obj.legacyStringLength(entry1)]);
    const prefix = string.char_pointer_to_string("match");
    stubs.setArgs(&.{ d, prefix });
    const entry2 = Prim_new_directory_read_match();
    try std.testing.expectEqualStrings("match.scm", obj.legacyStringData(entry2)[0..obj.legacyStringLength(entry2)]);
    stubs.setArgs(&.{d});
    _ = Prim_new_directory_close();
}
