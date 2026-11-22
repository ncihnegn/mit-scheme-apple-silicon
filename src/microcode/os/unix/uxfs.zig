const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../../core/prim_abi.zig");
const fasload = @import("../../gc/fasload.zig");
const osscheme = @import("../osscheme.zig");
const transact = @import("../../support/transact.zig");
const utils = @import("../../core/utils.zig");
const wind = @import("../../support/wind.zig");
const stubs = if (builtin.is_test) @import("../../core/test_stubs.zig") else struct {};

const file_touch_open_tries: u32 = 5;
const file_copy_buffer_length: usize = 8192;

fn statCall(filename: [*:0]const u8, s: *abi.Stat, comptime indirect: bool) c_int {
    while (true) {
        const rc = if (indirect) abi.cStat(filename, s) else abi.cLstat(filename, s);
        if (rc >= 0) return 1;
        const err = std.c._errno().*;
        if (err == @backingInt(std.c.E.NOENT) or err == @backingInt(std.c.E.NOTDIR)) return 0;
        if (err != @backingInt(std.c.E.INTR)) {
            utils.error_system_call(err, if (indirect) abi.syscall_stat else abi.syscall_lstat);
        }
        osscheme.deliver_pending_interrupts();
    }
}

/// Populate `s` with file status for open descriptor `fd`.
pub fn uxReadFdStatus(fd: c_int, s: *abi.Stat) callconv(.c) void {
    while (abi.cFstat(fd, s) < 0) {
        abi.UX_prim_check_errno(abi.syscall_fstat);
    }
}

/// Populate `s` via `lstat(filename)`, returning 1 if present or 0 on `ENOENT`/`ENOTDIR`.
pub fn uxReadFileStatus(filename: [*:0]const u8, s: *abi.Stat) callconv(.c) c_int {
    return statCall(filename, s, false);
}

/// Populate `s` via `stat(filename)`, returning 1 if present or 0 on `ENOENT`/`ENOTDIR`.
pub fn uxReadFileStatusIndirect(filename: [*:0]const u8, s: *abi.Stat) callconv(.c) c_int {
    return statCall(filename, s, true);
}

/// Classify file existence, following symlinks (`does_exist`, `doesnt_exist`, or dangling `is_link`).
pub fn osFileExistenceTest(name: [*:0]const u8) callconv(.c) c_uint {
    var s: abi.Stat = undefined;
    if (uxReadFileStatus(name, &s) == 0) return @backingInt(abi.FileExistence.doesnt_exist);
    if ((@as(u32, s.mode) & std.c.S.IFMT) == std.c.S.IFLNK) {
        return @backingInt(if (uxReadFileStatusIndirect(name, &s) != 0)
            abi.FileExistence.does_exist
        else
            abi.FileExistence.is_link);
    }
    return @backingInt(abi.FileExistence.does_exist);
}

/// Classify file existence directly via `lstat` without dereferencing symlinks.
pub fn osFileExistenceTestDirect(name: [*:0]const u8) callconv(.c) c_uint {
    var s: abi.Stat = undefined;
    if (uxReadFileStatus(name, &s) == 0) return @backingInt(abi.FileExistence.doesnt_exist);
    if ((@as(u32, s.mode) & std.c.S.IFMT) == std.c.S.IFLNK) {
        return @backingInt(abi.FileExistence.is_link);
    }
    return @backingInt(abi.FileExistence.does_exist);
}

fn computeFileType(name: [*:0]const u8, comptime indirect: bool) c_int {
    var s: abi.Stat = undefined;
    const found = if (indirect) uxReadFileStatusIndirect(name, &s) else uxReadFileStatus(name, &s);
    if (found == 0) return @backingInt(abi.FileType.nonexistent);
    const ftype: u32 = @as(u32, s.mode) & std.c.S.IFMT;
    const kind: abi.FileType = switch (ftype) {
        std.c.S.IFREG => .regular,
        std.c.S.IFDIR => .directory,
        std.c.S.IFLNK => .unix_symbolic_link,
        std.c.S.IFCHR => .unix_character_device,
        std.c.S.IFBLK => .unix_block_device,
        std.c.S.IFIFO => .unix_fifo,
        std.c.S.IFSOCK => .unix_stream_socket,
        else => .unknown,
    };
    return @backingInt(kind);
}

/// Return `FileType` integer classification of `name` without following symlinks.
pub fn osFileTypeDirect(name: [*:0]const u8) callconv(.c) c_int {
    return computeFileType(name, false);
}

/// Return `FileType` integer classification of `name`, dereferencing symlinks.
pub fn osFileTypeIndirect(name: [*:0]const u8) callconv(.c) c_int {
    return computeFileType(name, true);
}

/// Identify known Linux filesystem names via `statfs`; returns `null` elsewhere or if unrecognized.
pub fn uxFileSystemType(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (builtin.os.tag == .linux) {
        const LinuxStatfs = extern struct {
            f_type: c_long,
            _pad: [248]u8,
        };
        const LinuxFs = struct {
            extern "c" fn statfs(path: [*:0]const u8, buf: *LinuxStatfs) callconv(.c) c_int;
        };
        var s = std.mem.zeroes(LinuxStatfs);
        while (LinuxFs.statfs(name, &s) < 0) {
            const err = std.c._errno().*;
            if (err == @backingInt(std.c.E.NOENT) or err == @backingInt(std.c.E.NOTDIR)) return null;
            if (err != @backingInt(std.c.E.INTR)) utils.error_system_call(err, abi.syscall_statfs);
            osscheme.deliver_pending_interrupts();
        }
        return switch (@as(u64, @bitCast(@as(i64, s.f_type)))) {
            0xFF534D42 => "cifs",
            0x012FF7B7 => "coherent",
            0x137D => "ext",
            0xEF53 => "ext2",
            0xf995e849 => "hpfs",
            0x9660 => "iso9660",
            0x137F => "minix1",
            0x138F => "minix1-30",
            0x2468 => "minix2",
            0x2478 => "minix2-30",
            0x4d44 => "fat",
            0x564c => "ncp",
            0x6969 => "nfs",
            0x5346544E => "ntfs",
            0x9fa0 => "proc",
            0x517B => "smb",
            0x012FF7B6 => "sysv2",
            0x012FF7B5 => "sysv4",
            0x012FF7B4 => "xenix",
            0x012FD16D => "xiafs",
            else => null,
        };
    }
    return null;
}

/// Return 1 if `name` exists (following symlinks) and is a directory, else 0.
pub fn osFileDirectoryP(name: [*:0]const u8) callconv(.c) c_int {
    var s: abi.Stat = undefined;
    return @intFromBool(
        uxReadFileStatusIndirect(name, &s) != 0 and
            (@as(u32, s.mode) & std.c.S.IFMT) == std.c.S.IFDIR,
    );
}

/// If `name` is a symlink, return a `malloc`-allocated target path C string; otherwise return `null`.
pub fn osFileSoftLinkP(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    var s: abi.Stat = undefined;
    if (uxReadFileStatus(name, &s) == 0 or (@as(u32, s.mode) & std.c.S.IFMT) != std.c.S.IFLNK) {
        return null;
    }
    var buffer_length: usize = 100;
    var buffer: [*]u8 = @ptrCast(std.c.malloc(buffer_length) orelse
        utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_malloc));
    var scr: isize = 0;
    while (true) {
        scr = std.c.readlink(name, buffer, buffer_length);
        while (scr < 0) {
            abi.UX_prim_check_errno(abi.syscall_readlink);
            scr = std.c.readlink(name, buffer, buffer_length);
        }
        const nread: usize = @intCast(scr);
        if (nread < buffer_length) {
            buffer[nread] = 0;
            return @ptrCast(buffer);
        }
        buffer_length *= 2;
        buffer = @ptrCast(std.c.realloc(@ptrCast(buffer), buffer_length) orelse
            utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_realloc));
    }
}

/// Check POSIX `access(name, mode)` permissions, returning 1 on success and 0 on failure.
pub fn osFileAccess(name: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    return @intFromBool(std.c.access(name, mode) == 0);
}

/// Remove a file entry via `unlink`.
pub fn osFileRemove(name: [*:0]const u8) callconv(.c) void {
    while (std.c.unlink(name) < 0) {
        abi.UX_prim_check_errno(abi.syscall_unlink);
    }
}

/// Unlink `name` if it exists and is either a regular file or a symbolic link.
pub fn osFileRemoveLink(name: [*:0]const u8) callconv(.c) void {
    var s: abi.Stat = undefined;
    if (uxReadFileStatus(name, &s) != 0) {
        const ftype: u32 = @as(u32, s.mode) & std.c.S.IFMT;
        if (ftype == std.c.S.IFREG or ftype == std.c.S.IFLNK) {
            _ = std.c.unlink(name);
        }
    }
}

/// Create a hard link from `from_name` to `to_name`.
pub fn osFileLinkHard(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    while (std.c.link(from_name, to_name) < 0) {
        abi.UX_prim_check_errno(abi.syscall_link);
    }
}

/// Create a symbolic link at `to_name` pointing to `from_name`.
pub fn osFileLinkSoft(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    while (std.c.symlink(from_name, to_name) < 0) {
        abi.UX_prim_check_errno(abi.syscall_symlink);
    }
}

/// Rename `from_name` to `to_name`.
pub fn osFileRename(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    while (std.c.rename(from_name, to_name) < 0) {
        abi.UX_prim_check_errno(abi.syscall_rename);
    }
}

/// Copy file contents from `from_name` to `to_name` using Scheme channel I/O.
pub fn osFileCopy(from_name: [*:0]const u8, to_name: [*:0]const u8) callconv(.c) void {
    const src = abi.OS_open_input_file(from_name);
    abi.OS_channel_close_on_abort(src);
    const dst = abi.OS_open_output_file(to_name);
    abi.OS_channel_close_on_abort(dst);
    var src_len = abi.OS_file_length(src);
    var buffer: [file_copy_buffer_length]u8 = undefined;
    var chunk_len: abi.OffT = buffer.len;
    while (src_len > 0) {
        if (src_len < chunk_len) chunk_len = src_len;
        const nread = abi.OS_channel_read(src, &buffer, @intCast(chunk_len));
        if (nread < 0) {
            utils.error_system_call(std.c._errno().*, abi.syscall_read);
        } else if (nread == 0) {
            break;
        }
        const nwrite = abi.OS_channel_write(dst, &buffer, @intCast(nread));
        if (nwrite < 0) {
            utils.error_system_call(std.c._errno().*, abi.syscall_write);
        } else if (nwrite < nread) {
            utils.error_system_call(@backingInt(std.c.E.NOSPC), abi.syscall_write);
        }
        src_len -= nread;
    }
    abi.OS_channel_close(src);
    abi.OS_channel_close(dst);
}

/// Create a directory at `name` with mode `MODE_DIR` (`0o777`).
pub fn osDirectoryMake(name: [*:0]const u8) callconv(.c) void {
    while (std.c.mkdir(name, @intCast(abi.mode_dir)) < 0) {
        abi.UX_prim_check_errno(abi.syscall_mkdir);
    }
}

/// Remove an empty directory at `name`.
pub fn osDirectoryDelete(name: [*:0]const u8) callconv(.c) void {
    while (std.c.rmdir(name) < 0) {
        abi.UX_prim_check_errno(abi.syscall_rmdir);
    }
}

fn protectFdClose(ap: ?*anyopaque) callconv(.c) void {
    const fdp: *const c_int = @ptrCast(@alignCast(ap.?));
    _ = std.c.close(fdp.*);
}

fn protectFd(fd: c_int) void {
    const raw = wind.dstack_alloc(@sizeOf(c_int));
    const p: *c_int = @ptrCast(@alignCast(raw.?));
    p.* = fd;
    transact.transaction_record_action(.tat_always, &protectFdClose, p);
}

fn isStaleErrno(err: c_int) bool {
    return @hasField(std.c.E, "STALE") and err == @backingInt(std.c.E.STALE);
}

/// Atomically create or update timestamps on `filename`, returning 1 if created, 0 if touched, or -1 if non-regular.
pub fn osFileTouch(filename: [*:0]const u8) callconv(.c) c_int {
    transact.transaction_begin();
    var fd: c_int = -1;
    var count: u32 = 0;
    while (true) {
        count += 1;
        fd = std.c.open(
            filename,
            .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true },
            @as(c_uint, abi.mode_reg),
        );
        if (fd >= 0) {
            protectFd(fd);
            transact.transaction_commit();
            return 1;
        }
        const err = std.c._errno().*;
        if (err == @backingInt(std.c.E.EXIST)) {
            fd = std.c.open(filename, .{ .ACCMODE = .RDWR }, @as(c_uint, abi.mode_reg));
            if (fd >= 0) {
                protectFd(fd);
                break;
            }
            const err2 = std.c._errno().*;
            if (err2 == @backingInt(std.c.E.NOENT) or isStaleErrno(err2)) continue;
            if (count >= file_touch_open_tries) {
                utils.error_system_call(err2, abi.syscall_open);
            }
            continue;
        }
        if (count >= file_touch_open_tries) {
            utils.error_system_call(err, abi.syscall_open);
        }
    }

    var file_status: abi.Stat = undefined;
    while (abi.cFstat(fd, &file_status) < 0) {
        abi.UX_prim_check_errno(abi.syscall_fstat);
    }
    if ((@as(u32, file_status.mode) & std.c.S.IFMT) != std.c.S.IFREG) {
        transact.transaction_commit();
        return -1;
    }

    var buf: [1]u8 = .{0};
    if (file_status.size == 0) {
        while (std.c.write(fd, &buf, 1) < 0) {
            abi.UX_prim_check_errno(abi.syscall_write);
        }
        while (std.c.ftruncate(fd, 0) < 0) {
            abi.UX_prim_check_errno(abi.syscall_ftruncate);
        }
        transact.transaction_commit();
        return 0;
    }

    var scr = std.c.read(fd, &buf, 1);
    while (scr < 0) {
        abi.UX_prim_check_errno(abi.syscall_read);
        scr = std.c.read(fd, &buf, 1);
    }
    if (scr > 0) {
        while (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) {
            abi.UX_prim_check_errno(abi.syscall_lseek);
        }
        while (std.c.write(fd, &buf, 1) < 0) {
            abi.UX_prim_check_errno(abi.syscall_write);
        }
    }
    transact.transaction_commit();
    return 0;
}

var directory_pointers: ?[*]?*std.c.DIR = null;
var n_directory_pointers: usize = 0;

fn closeAllDirectories() callconv(.c) void {
    if (directory_pointers) |ptrs| {
        for (ptrs[0..n_directory_pointers]) |*slot| {
            if (slot.*) |dir| {
                _ = std.c.closedir(dir);
                slot.* = null;
            }
        }
        std.c.free(@ptrCast(ptrs));
    }
    directory_pointers = null;
    n_directory_pointers = 0;
}

/// Reset directory table state and register reload cleanup with `fasload`.
pub fn uxInitializeDirectoryReader() callconv(.c) void {
    directory_pointers = null;
    n_directory_pointers = 0;
    fasload.add_reload_cleanup(&closeAllDirectories);
}

fn allocateDirectoryPointer(pointer: *std.c.DIR) c_uint {
    if (n_directory_pointers == 0) {
        const init_len: usize = 4;
        const raw = std.c.malloc(@sizeOf(?*std.c.DIR) * init_len) orelse
            utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_malloc);
        const ptrs: [*]?*std.c.DIR = @ptrCast(@alignCast(raw));
        ptrs[0] = pointer;
        for (ptrs[1..init_len]) |*slot| slot.* = null;
        directory_pointers = ptrs;
        n_directory_pointers = init_len;
        return 0;
    }

    const cur = directory_pointers.?;
    for (cur[0..n_directory_pointers], 0..) |*slot, idx| {
        if (slot.* == null) {
            slot.* = pointer;
            return @intCast(idx);
        }
    }

    const result = n_directory_pointers;
    const next_len = n_directory_pointers * 2;
    const raw = std.c.realloc(@ptrCast(cur), @sizeOf(?*std.c.DIR) * next_len) orelse
        utils.error_system_call(@backingInt(std.c.E.NOMEM), abi.syscall_realloc);
    const ptrs: [*]?*std.c.DIR = @ptrCast(@alignCast(raw));
    ptrs[result] = pointer;
    for (ptrs[result + 1 .. next_len]) |*slot| slot.* = null;
    directory_pointers = ptrs;
    n_directory_pointers = next_len;
    return @intCast(result);
}

/// Return 1 if `index` refers to an open directory slot in the directory table, else 0.
pub fn osDirectoryValidP(index: c_uint) callconv(.c) c_int {
    if (index >= n_directory_pointers) return 0;
    return @intFromBool(directory_pointers.?[index] != null);
}

/// Open directory `name` and return its allocated directory table index.
pub fn osDirectoryOpen(name: [*:0]const u8) callconv(.c) c_uint {
    var pointer = std.c.opendir(name);
    while (pointer == null) {
        abi.UX_prim_check_errno(abi.syscall_opendir);
        pointer = std.c.opendir(name);
    }
    return allocateDirectoryPointer(pointer.?);
}

/// Read next entry name from open directory `index`, or return `null` at EOF.
pub fn osDirectoryRead(index: c_uint) callconv(.c) ?[*:0]const u8 {
    const dir = directory_pointers.?[index].?;
    const entry = std.c.readdir(dir) orelse return null;
    return @ptrCast(&entry.name);
}

/// Read next entry name starting with `prefix` from open directory `index`, or `null` at EOF.
pub fn osDirectoryReadMatching(index: c_uint, prefix: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const dir = directory_pointers.?[index].?;
    const prefix_slice = std.mem.span(prefix);
    while (true) {
        const entry = std.c.readdir(dir) orelse return null;
        const name_slice = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.startsWith(u8, name_slice, prefix_slice)) {
            return @ptrCast(&entry.name);
        }
    }
}

/// Close open directory `index` and release its table slot.
pub fn osDirectoryClose(index: c_uint) callconv(.c) void {
    const ptrs = directory_pointers.?;
    if (ptrs[index]) |dir| {
        _ = std.c.closedir(dir);
        ptrs[index] = null;
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
        @export(&uxInitializeDirectoryReader, .{ .name = "UX_initialize_directory_reader" });
        @export(&osDirectoryValidP, .{ .name = "OS_directory_valid_p" });
        @export(&osDirectoryOpen, .{ .name = "OS_directory_open" });
        @export(&osDirectoryRead, .{ .name = "OS_directory_read" });
        @export(&osDirectoryReadMatching, .{ .name = "OS_directory_read_matching" });
        @export(&osDirectoryClose, .{ .name = "OS_directory_close" });
    }
}

test "uxfs directory lifecycle, touch, links, existence, types, and cleanup" {
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    transact.transaction_initialize();
    uxInitializeDirectoryReader();
    defer {
        closeAllDirectories();
        transact.transaction_initialize();
        wind.dstack_reset();
    }

    const dir_path: [*:0]const u8 = "/tmp/zig-n2-uxfs-dir";
    const file_a: [*:0]const u8 = "/tmp/zig-n2-uxfs-dir/alpha.txt";
    const file_h: [*:0]const u8 = "/tmp/zig-n2-uxfs-dir/hard.txt";
    const file_r: [*:0]const u8 = "/tmp/zig-n2-uxfs-dir/renamed.txt";
    const link_s: [*:0]const u8 = "/tmp/zig-n2-uxfs-dir/sym.txt";
    const link_d: [*:0]const u8 = "/tmp/zig-n2-uxfs-dir/dangling.txt";

    _ = std.c.unlink(link_d);
    _ = std.c.unlink(link_s);
    _ = std.c.unlink(file_r);
    _ = std.c.unlink(file_h);
    _ = std.c.unlink(file_a);
    _ = std.c.rmdir(dir_path);

    defer {
        _ = std.c.unlink(link_d);
        _ = std.c.unlink(link_s);
        _ = std.c.unlink(file_r);
        _ = std.c.unlink(file_h);
        _ = std.c.unlink(file_a);
        _ = std.c.rmdir(dir_path);
    }

    osDirectoryMake(dir_path);
    try std.testing.expectEqual(@as(c_int, 1), osFileDirectoryP(dir_path));
    try std.testing.expectEqual(@backingInt(abi.FileType.directory), osFileTypeDirect(dir_path));
    try std.testing.expectEqual(@backingInt(abi.FileExistence.doesnt_exist), osFileExistenceTest(file_a));

    // Touch creates empty file, then touches non-empty content
    try std.testing.expectEqual(@as(c_int, 1), osFileTouch(file_a));
    try std.testing.expectEqual(@as(c_int, 0), osFileTouch(file_a));
    {
        const fd = std.c.open(file_a, .{ .ACCMODE = .RDWR }, @as(c_uint, abi.mode_reg));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        try std.testing.expectEqual(@as(isize, 3), std.c.write(fd, "xyz", 3));
    }
    try std.testing.expectEqual(@as(c_int, 0), osFileTouch(file_a));
    try std.testing.expectEqual(@as(c_int, 1), osFileAccess(file_a, 0));

    var st: abi.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 1), uxReadFileStatus(file_a, &st));
    try std.testing.expectEqual(@as(i64, 3), st.size);

    // Hard link + rename + symlink + dangling symlink
    osFileLinkHard(file_a, file_h);
    osFileRename(file_h, file_r);
    osFileLinkSoft(file_a, link_s);
    osFileLinkSoft("/tmp/zig-n2-uxfs-dir/missing-target", link_d);

    try std.testing.expectEqual(@backingInt(abi.FileExistence.does_exist), osFileExistenceTest(link_s));
    try std.testing.expectEqual(@backingInt(abi.FileExistence.is_link), osFileExistenceTestDirect(link_s));
    try std.testing.expectEqual(@backingInt(abi.FileExistence.is_link), osFileExistenceTest(link_d));
    try std.testing.expectEqual(@backingInt(abi.FileType.unix_symbolic_link), osFileTypeDirect(link_s));
    try std.testing.expectEqual(@backingInt(abi.FileType.regular), osFileTypeIndirect(link_s));

    const target = osFileSoftLinkP(link_s).?;
    defer std.c.free(@ptrCast(@constCast(target)));
    try std.testing.expectEqualStrings(std.mem.span(file_a), std.mem.span(target));
    try std.testing.expect(osFileSoftLinkP(file_a) == null);

    // Directory reader matching
    const dir_idx = osDirectoryOpen(dir_path);
    try std.testing.expectEqual(@as(c_int, 1), osDirectoryValidP(dir_idx));
    const match = osDirectoryReadMatching(dir_idx, "alp").?;
    try std.testing.expectEqualStrings("alpha.txt", std.mem.span(match));
    osDirectoryClose(dir_idx);
    try std.testing.expectEqual(@as(c_int, 0), osDirectoryValidP(dir_idx));

    // Remove regular and symlink entries cleanly
    osFileRemove(file_r);
    osFileRemoveLink(link_d);
    osFileRemoveLink(link_s);
    osFileRemove(file_a);
    osDirectoryDelete(dir_path);
    try std.testing.expectEqual(@backingInt(abi.FileExistence.doesnt_exist), osFileExistenceTest(dir_path));
}
