// Derived from MIT/GNU Scheme C sources (`src/microcode/uxfs.c`)
// and Win32 Filesystem / Directory APIs:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const fasload = @import("fasload.zig");
const utils = @import("utils.zig");
const win = @import("win_api.zig");
const win_io = @import("win_io.zig");

const DirSlot = struct {
    open: bool = false,
    have_first: bool = false,
    handle: win.HANDLE = win.INVALID_HANDLE_VALUE,
    data: win.WIN32_FIND_DATAA = std.mem.zeroes(win.WIN32_FIND_DATAA),
    name_buf: [260]u8 = @splat(0),
};

const max_dirs: usize = 256;
var dir_slots: [max_dirs]DirSlot = @splat(.{});

fn closeAllDirsCleanup() callconv(.c) void {
    for (&dir_slots) |*slot| {
        if (slot.open) {
            if (slot.handle != win.INVALID_HANDLE_VALUE) {
                _ = win.kernel32.FindClose(slot.handle);
            }
            slot.* = .{};
        }
    }
}

pub fn initDirectoryReader() void {
    for (&dir_slots) |*slot| slot.* = .{};
    fasload.add_reload_cleanup(&closeAllDirsCleanup);
}

fn fillStatFromAttrData(d: *const win.WIN32_FILE_ATTRIBUTE_DATA, is_link: bool, s: *abi.Stat) void {
    const size_u64: u64 = (@as(u64, d.nFileSizeHigh) << 32) | @as(u64, d.nFileSizeLow);
    const at = win.filetimeToUnixNanotime(d.ftLastAccessTime);
    const mt = win.filetimeToUnixNanotime(d.ftLastWriteTime);
    const ct = win.filetimeToUnixNanotime(d.ftCreationTime);
    s.* = .{
        .dev = 0,
        .ino = 0,
        .mode = win.win32AttrToMode(d.dwFileAttributes, is_link),
        .nlink = 1,
        .uid = 0,
        .gid = 0,
        .size = @intCast(size_u64),
        .atim = .{ .sec = at.seconds, .nsec = @intCast(at.nanoseconds) },
        .mtim = .{ .sec = mt.seconds, .nsec = @intCast(mt.nanoseconds) },
        .ctim = .{ .sec = ct.seconds, .nsec = @intCast(ct.nanoseconds) },
    };
}

fn fillStatFromHandleInfo(info: *const win.BY_HANDLE_FILE_INFORMATION, is_link: bool, s: *abi.Stat) void {
    const size_u64: u64 = (@as(u64, info.nFileSizeHigh) << 32) | @as(u64, info.nFileSizeLow);
    const ino_u64: u64 = (@as(u64, info.nFileIndexHigh) << 32) | @as(u64, info.nFileIndexLow);
    const at = win.filetimeToUnixNanotime(info.ftLastAccessTime);
    const mt = win.filetimeToUnixNanotime(info.ftLastWriteTime);
    const ct = win.filetimeToUnixNanotime(info.ftCreationTime);
    s.* = .{
        .dev = info.dwVolumeSerialNumber,
        .ino = ino_u64,
        .mode = win.win32AttrToMode(info.dwFileAttributes, is_link),
        .nlink = info.nNumberOfLinks,
        .uid = 0,
        .gid = 0,
        .size = @intCast(size_u64),
        .atim = .{ .sec = at.seconds, .nsec = @intCast(at.nanoseconds) },
        .mtim = .{ .sec = mt.seconds, .nsec = @intCast(mt.nanoseconds) },
        .ctim = .{ .sec = ct.seconds, .nsec = @intCast(ct.nanoseconds) },
    };
}

fn readStatusImpl(filename: [*:0]const u8, s: *abi.Stat, indirect: bool) c_int {
    var attr_data: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win.kernel32.GetFileAttributesExA(filename, 0, &attr_data) == 0) {
        const err = win.kernel32.GetLastError();
        if (err == 2 or err == 3 or err == 15 or err == 161 or err == 267) return 0;
        if (err != 5 and err != 32) {
            utils.error_system_call(win.win32ErrorToErrno(err), if (indirect) abi.syscall_stat else abi.syscall_lstat);
        }
        return 0;
    }

    const is_reparse = (attr_data.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    if (!indirect and is_reparse) {
        fillStatFromAttrData(&attr_data, true, s);
        return 1;
    }

    const extra_flags: win.DWORD = win.FILE_FLAG_BACKUP_SEMANTICS |
        (if (!indirect) win.FILE_FLAG_OPEN_REPARSE_POINT else 0);
    const h = win.kernel32.CreateFileA(
        filename,
        0,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        null,
        win.OPEN_EXISTING,
        extra_flags,
        null,
    );
    if (h != win.INVALID_HANDLE_VALUE) {
        defer _ = win.kernel32.CloseHandle(h);
        var info: win.BY_HANDLE_FILE_INFORMATION = undefined;
        if (win.kernel32.GetFileInformationByHandle(h, &info) != 0) {
            fillStatFromHandleInfo(&info, false, s);
            return 1;
        }
    } else if (indirect and is_reparse) {
        // Broken symlink when indirecting: target does not exist
        const err = win.kernel32.GetLastError();
        if (err == 2 or err == 3 or err == 1921) return 0;
    }

    fillStatFromAttrData(&attr_data, false, s);
    return 1;
}

pub fn uxReadFdStatus(desc: c_int, s: *abi.Stat) callconv(.c) void {
    const entry = win_io.getChannelByDesc(desc) orelse abi.error_bad_range_arg(1);
    if (entry.is_socket or entry.handle == win.INVALID_HANDLE_VALUE) {
        s.* = std.mem.zeroes(abi.Stat);
        return;
    }
    var info: win.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win.kernel32.GetFileInformationByHandle(entry.handle, &info) == 0) {
        win_io.failWin32(abi.syscall_fstat);
    }
    fillStatFromHandleInfo(&info, false, s);
}

pub fn uxReadFileStatus(filename: [*:0]const u8, s: *abi.Stat) callconv(.c) c_int {
    return readStatusImpl(filename, s, false);
}

pub fn uxReadFileStatusIndirect(filename: [*:0]const u8, s: *abi.Stat) callconv(.c) c_int {
    return readStatusImpl(filename, s, true);
}

pub fn osFileExistenceTest(name: [*:0]const u8) callconv(.c) c_uint {
    var s: abi.Stat = undefined;
    if (uxReadFileStatus(name, &s) == 0) return @intFromEnum(abi.FileExistence.doesnt_exist);
    if ((s.mode & 0o170000) == 0o120000) {
        return @intFromEnum(if (uxReadFileStatusIndirect(name, &s) != 0)
            abi.FileExistence.does_exist
        else
            abi.FileExistence.is_link);
    }
    return @intFromEnum(abi.FileExistence.does_exist);
}

pub fn osFileExistenceTestDirect(name: [*:0]const u8) callconv(.c) c_uint {
    var s: abi.Stat = undefined;
    if (uxReadFileStatus(name, &s) == 0) return @intFromEnum(abi.FileExistence.doesnt_exist);
    if ((s.mode & 0o170000) == 0o120000) {
        return @intFromEnum(abi.FileExistence.is_link);
    }
    return @intFromEnum(abi.FileExistence.does_exist);
}

fn computeFileType(name: [*:0]const u8, indirect: bool) c_int {
    var s: abi.Stat = undefined;
    if (readStatusImpl(name, &s, indirect) == 0) return @intFromEnum(abi.FileType.nonexistent);
    return switch (s.mode & 0o170000) {
        0o100000 => @intFromEnum(abi.FileType.regular),
        0o040000 => @intFromEnum(abi.FileType.directory),
        0o120000 => @intFromEnum(abi.FileType.unix_symbolic_link),
        else => @intFromEnum(abi.FileType.unknown),
    };
}

pub fn osFileTypeDirect(name: [*:0]const u8) callconv(.c) c_int {
    return computeFileType(name, false);
}

pub fn osFileTypeIndirect(name: [*:0]const u8) callconv(.c) c_int {
    return computeFileType(name, true);
}

pub fn uxFileSystemType(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const State = struct {
        var fs_buf: [64]u8 = @splat(0);
    };
    const slice = std.mem.span(name);
    var root_buf: [4]u8 = @splat(0);
    var root_ptr: ?[*:0]const u8 = null;
    if (slice.len >= 2 and std.ascii.isAlphabetic(slice[0]) and slice[1] == ':') {
        root_buf[0] = slice[0];
        root_buf[1] = ':';
        root_buf[2] = '\\';
        root_buf[3] = 0;
        root_ptr = @ptrCast(&root_buf);
    }
    if (win.kernel32.GetVolumeInformationA(root_ptr, null, 0, null, null, null, &State.fs_buf, State.fs_buf.len) != 0) {
        const fs_len = std.mem.sliceTo(&State.fs_buf, 0).len;
        for (State.fs_buf[0..fs_len]) |*c| c.* = std.ascii.toLower(c.*);
        return @ptrCast(&State.fs_buf);
    }
    return "ntfs";
}

pub fn osFileDirectoryP(name: [*:0]const u8) callconv(.c) c_int {
    const attrs = win.kernel32.GetFileAttributesA(name);
    if (attrs == win.INVALID_FILE_ATTRIBUTES) return 0;
    return @intFromBool((attrs & win.FILE_ATTRIBUTE_DIRECTORY) != 0);
}

pub fn osFileSoftLinkP(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const State = struct {
        var target_buf: [1024]u8 = @splat(0);
    };
    const attrs = win.kernel32.GetFileAttributesA(name);
    if (attrs == win.INVALID_FILE_ATTRIBUTES or (attrs & win.FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
        return null;
    }
    const h = win.kernel32.CreateFileA(
        name,
        0,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        null,
        win.OPEN_EXISTING,
        win.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (h == win.INVALID_HANDLE_VALUE) return null;
    defer _ = win.kernel32.CloseHandle(h);
    const n = win.kernel32.GetFinalPathNameByHandleA(h, &State.target_buf, State.target_buf.len - 1, 0);
    if (n == 0 or n >= State.target_buf.len) return null;
    State.target_buf[n] = 0;
    win.normalizeSlashesInPlace(State.target_buf[0..n]);
    if (std.mem.startsWith(u8, State.target_buf[0..n], "//?/")) {
        return @ptrCast(&State.target_buf[4]);
    }
    return @ptrCast(&State.target_buf);
}

pub fn osFileAccess(name: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    const attrs = win.kernel32.GetFileAttributesA(name);
    if (attrs == win.INVALID_FILE_ATTRIBUTES) return 0;
    if ((mode & 2) != 0 and (attrs & win.FILE_ATTRIBUTE_DIRECTORY) == 0 and (attrs & win.FILE_ATTRIBUTE_READONLY) != 0) {
        return 0;
    }
    return 1;
}

pub fn osFileRemove(name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.DeleteFileA(name) == 0) {
        const attrs = win.kernel32.GetFileAttributesA(name);
        if (attrs != win.INVALID_FILE_ATTRIBUTES and (attrs & win.FILE_ATTRIBUTE_REPARSE_POINT) != 0 and (attrs & win.FILE_ATTRIBUTE_DIRECTORY) != 0) {
            if (win.kernel32.RemoveDirectoryA(name) != 0) return;
        }
        win_io.failWin32(abi.syscall_unlink);
    }
}

pub fn osFileRemoveLink(name: [*:0]const u8) callconv(.c) void {
    const attrs = win.kernel32.GetFileAttributesA(name);
    if (attrs == win.INVALID_FILE_ATTRIBUTES) return;
    if ((attrs & win.FILE_ATTRIBUTE_DIRECTORY) == 0) {
        _ = win.kernel32.DeleteFileA(name);
    } else if ((attrs & win.FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        _ = win.kernel32.RemoveDirectoryA(name);
    }
}

pub fn osFileLinkHard(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.CreateHardLinkA(to_name, from_name, null) == 0) {
        win_io.failWin32(abi.syscall_link);
    }
}

pub fn osFileLinkSoft(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    var flags: win.DWORD = win.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    if (osFileDirectoryP(from_name) != 0) {
        flags |= win.SYMBOLIC_LINK_FLAG_DIRECTORY;
    }
    if (win.kernel32.CreateSymbolicLinkA(to_name, from_name, flags) == 0) {
        win_io.failWin32(abi.syscall_symlink);
    }
}

pub fn osFileRename(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.MoveFileExA(from_name, to_name, win.MOVEFILE_REPLACE_EXISTING) == 0) {
        win_io.failWin32(abi.syscall_rename);
    }
}

pub fn osFileCopy(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.CopyFileA(from_name, to_name, 0) == 0) {
        win_io.failWin32(abi.syscall_open);
    }
}

pub fn osDirectoryMake(name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.CreateDirectoryA(name, null) == 0) {
        win_io.failWin32(abi.syscall_mkdir);
    }
}

pub fn osDirectoryDelete(name: [*:0]const u8) callconv(.c) void {
    if (win.kernel32.RemoveDirectoryA(name) == 0) {
        win_io.failWin32(abi.syscall_rmdir);
    }
}

pub fn osFileTouch(filename: [*:0]const u8) callconv(.c) c_int {
    const h_new = win.kernel32.CreateFileA(
        filename,
        win.GENERIC_WRITE,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        null,
        win.CREATE_NEW,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h_new != win.INVALID_HANDLE_VALUE) {
        _ = win.kernel32.CloseHandle(h_new);
        return 1;
    }
    const err = win.kernel32.GetLastError();
    if (err != 80 and err != 183) {
        utils.error_system_call(win.win32ErrorToErrno(err), abi.syscall_open);
    }
    const attrs = win.kernel32.GetFileAttributesA(filename);
    if (attrs != win.INVALID_FILE_ATTRIBUTES and (attrs & win.FILE_ATTRIBUTE_DIRECTORY) != 0) {
        return -1;
    }
    const h_existing = win.kernel32.CreateFileA(
        filename,
        win.FILE_WRITE_ATTRIBUTES,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h_existing == win.INVALID_HANDLE_VALUE) {
        win_io.failWin32(abi.syscall_open);
    }
    defer _ = win.kernel32.CloseHandle(h_existing);
    var ft: win.FILETIME = undefined;
    win.kernel32.GetSystemTimeAsFileTime(&ft);
    if (win.kernel32.SetFileTime(h_existing, null, &ft, &ft) == 0) {
        win_io.failWin32(abi.syscall_utime);
    }
    return 0;
}

pub fn osDirectoryOpen(name: [*:0]const u8) callconv(.c) c_uint {
    var slot_idx: ?usize = null;
    for (&dir_slots, 0..) |*slot, idx| {
        if (!slot.open) {
            slot_idx = idx;
            break;
        }
    }
    const idx = slot_idx orelse utils.error_system_call(@intFromEnum(std.c.E.MFILE), abi.syscall_opendir);

    const name_slice = std.mem.span(name);
    var pat_buf: [520]u8 = undefined;
    if (name_slice.len + 3 >= pat_buf.len) {
        utils.error_system_call(@intFromEnum(std.c.E.NAMETOOLONG), abi.syscall_opendir);
    }
    var n: usize = name_slice.len;
    @memcpy(pat_buf[0..n], name_slice);
    win.normalizeSlashesInPlace(pat_buf[0..n]);
    if (n > 0 and pat_buf[n - 1] != '/') {
        pat_buf[n] = '/';
        n += 1;
    }
    pat_buf[n] = '*';
    pat_buf[n + 1] = 0;

    var fdata: win.WIN32_FIND_DATAA = std.mem.zeroes(win.WIN32_FIND_DATAA);
    const h = win.kernel32.FindFirstFileA(@ptrCast(&pat_buf), &fdata);
    if (h == win.INVALID_HANDLE_VALUE) {
        const err = win.kernel32.GetLastError();
        // Empty volume/share (ERROR_FILE_NOT_FOUND / ERROR_NO_MORE_FILES)
        if (err != 2 and err != 18) {
            utils.error_system_call(win.win32ErrorToErrno(err), abi.syscall_opendir);
        }
        dir_slots[idx] = .{ .open = true, .have_first = false, .handle = win.INVALID_HANDLE_VALUE, .data = fdata };
        return @intCast(idx);
    }
    dir_slots[idx] = .{
        .open = true,
        .have_first = true,
        .handle = h,
        .data = fdata,
    };
    return @intCast(idx);
}

pub fn osDirectoryValidP(index: c_uint) callconv(.c) c_int {
    if (index >= max_dirs) return 0;
    return @intFromBool(dir_slots[index].open);
}

fn copyDirEntryName(slot: *DirSlot) [*:0]const u8 {
    const name_slice = std.mem.sliceTo(&slot.data.cFileName, 0);
    @memcpy(slot.name_buf[0..name_slice.len], name_slice);
    slot.name_buf[name_slice.len] = 0;
    return @ptrCast(&slot.name_buf);
}

fn advanceDirSlot(slot: *DirSlot) ?[*:0]const u8 {
    if (slot.handle == win.INVALID_HANDLE_VALUE) return null;
    if (slot.have_first) {
        slot.have_first = false;
        return copyDirEntryName(slot);
    }
    if (win.kernel32.FindNextFileA(slot.handle, &slot.data) == 0) {
        return null;
    }
    return copyDirEntryName(slot);
}

pub fn osDirectoryRead(index: c_uint) callconv(.c) ?[*:0]const u8 {
    return advanceDirSlot(&dir_slots[index]);
}

pub fn osDirectoryReadMatching(index: c_uint, prefix: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const slot = &dir_slots[index];
    const prefix_slice = std.mem.span(prefix);
    while (advanceDirSlot(slot)) |name_z| {
        const entry_slice = std.mem.span(name_z);
        if (std.mem.startsWith(u8, entry_slice, prefix_slice)) {
            return name_z;
        }
    }
    return null;
}

pub fn osDirectoryClose(index: c_uint) callconv(.c) void {
    const slot = &dir_slots[index];
    if (slot.open) {
        if (slot.handle != win.INVALID_HANDLE_VALUE) {
            _ = win.kernel32.FindClose(slot.handle);
        }
        slot.* = .{};
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&uxReadFdStatus, .{ .name = "UX_read_fd_status" });
        @export(&uxReadFileStatus, .{ .name = "UX_read_file_status" });
        @export(&uxReadFileStatusIndirect, .{ .name = "UX_read_file_status_indirect" });
        @export(&osFileExistenceTest, .{ .name = "OS_file_existence_test" });
        @export(&osFileExistenceTestDirect, .{ .name = "OS_file_existence_test_direct" });
        @export(&osFileTypeDirect, .{ .name = "OS_file_type_direct" });
        @export(&osFileTypeIndirect, .{ .name = "OS_file_type_indirect" });
        @export(&uxFileSystemType, .{ .name = "UX_file_system_type" });
        @export(&osFileDirectoryP, .{ .name = "OS_file_directory_p" });
        @export(&osFileSoftLinkP, .{ .name = "OS_file_soft_link_p" });
        @export(&osFileAccess, .{ .name = "OS_file_access" });
        @export(&osFileRemove, .{ .name = "OS_file_remove" });
        @export(&osFileRemoveLink, .{ .name = "OS_file_remove_link" });
        @export(&osFileLinkHard, .{ .name = "OS_file_link_hard" });
        @export(&osFileLinkSoft, .{ .name = "OS_file_link_soft" });
        @export(&osFileRename, .{ .name = "OS_file_rename" });
        @export(&osFileCopy, .{ .name = "OS_file_copy" });
        @export(&osDirectoryMake, .{ .name = "OS_directory_make" });
        @export(&osDirectoryDelete, .{ .name = "OS_directory_delete" });
        @export(&osFileTouch, .{ .name = "OS_file_touch" });
        @export(&osDirectoryValidP, .{ .name = "OS_directory_valid_p" });
        @export(&osDirectoryOpen, .{ .name = "OS_directory_open" });
        @export(&osDirectoryRead, .{ .name = "OS_directory_read" });
        @export(&osDirectoryReadMatching, .{ .name = "OS_directory_read_matching" });
        @export(&osDirectoryClose, .{ .name = "OS_directory_close" });
    }
}
