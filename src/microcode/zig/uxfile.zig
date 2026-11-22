const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

fn fdChannelType(fd: c_int) abi.ChannelType {
    var stat_buf: abi.Stat = undefined;
    if (abi.cFstat(fd, &stat_buf) < 0) return .unknown;
    const ftype: u32 = @as(u32, stat_buf.mode) & std.c.S.IFMT;
    return switch (ftype) {
        std.c.S.IFREG => .file,
        std.c.S.IFCHR => if (std.c.isatty(fd) != 0) .terminal else .unix_character_device,
        std.c.S.IFIFO => .unix_fifo,
        std.c.S.IFBLK => .unix_block_device,
        std.c.S.IFDIR => .directory,
        else => .unknown,
    };
}

/// Allocate and initialize a Scheme channel for an already-open OS file descriptor.
pub fn osOpenFd(fd: c_int) callconv(.c) abi.Tchannel {
    const ch_type = fdChannelType(fd);
    const channel = abi.makeChannel(fd, ch_type);
    if (ch_type == .terminal) {
        abi.terminal_open(channel);
    }
    return channel;
}

fn openFile(filename: [*:0]const u8, oflag: std.c.O) abi.Tchannel {
    const fd = abi.openFdRetry(filename, oflag, abi.mode_reg);
    return osOpenFd(fd);
}

/// Open an existing file for reading.
pub fn osOpenInputFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openFile(filename, .{ .ACCMODE = .RDONLY });
}

/// Open or truncate/create a file for writing.
pub fn osOpenOutputFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openFile(filename, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
}

/// Create a new file exclusively for writing, failing if it already exists.
pub fn osOpenExclusiveOutputFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openFile(filename, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true });
}

/// Open or create a file for read/write I/O.
pub fn osOpenIoFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openFile(filename, .{ .ACCMODE = .RDWR, .CREAT = true });
}

/// Open or create a file for appending.
pub fn osOpenAppendFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openFile(filename, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true });
}

fn makeLoadChannel(fd: c_int) abi.Tchannel {
    const ch_type = fdChannelType(fd);
    if (ch_type == .terminal or ch_type == .directory or ch_type == .unknown) {
        return abi.no_channel;
    }
    return abi.makeChannel(fd, ch_type);
}

fn openLoadOrDumpFile(filename: [*:0]const u8, oflag: std.c.O) abi.Tchannel {
    while (true) {
        const fd = std.c.open(filename, oflag, @as(c_uint, abi.mode_reg));
        if (fd >= 0) return makeLoadChannel(fd);
        if (std.c._errno().* != @backingInt(std.c.E.INTR)) return abi.no_channel;
    }
}

/// Open a file for fasload, returning `no_channel` on non-EINTR errors or unsupported types.
pub fn osOpenLoadFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openLoadOrDumpFile(filename, .{ .ACCMODE = .RDONLY });
}

/// Open/truncate a file for fasdump, returning `no_channel` on non-EINTR errors or unsupported types.
pub fn osOpenDumpFile(filename: [*:0]const u8) callconv(.c) abi.Tchannel {
    return openLoadOrDumpFile(filename, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
}

/// Return byte length of an open file channel via `fstat`.
pub fn osFileLength(channel: abi.Tchannel) callconv(.c) abi.OffT {
    var stat_buf: abi.Stat = undefined;
    const fd = abi.channel_table[channel].descriptor;
    while (abi.cFstat(fd, &stat_buf) < 0) {
        abi.UX_prim_check_errno(abi.syscall_fstat);
    }
    return @intCast(stat_buf.size);
}

/// Return current byte offset of an open file channel via `lseek`.
pub fn osFilePosition(channel: abi.Tchannel) callconv(.c) abi.OffT {
    const fd = abi.channel_table[channel].descriptor;
    var result = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    while (result < 0) {
        abi.UX_prim_check_errno(abi.syscall_lseek);
        result = std.c.lseek(fd, 0, std.c.SEEK.CUR);
    }
    return result;
}

/// Seek an open file channel to an absolute byte offset.
pub fn osFileSetPosition(channel: abi.Tchannel, position: abi.OffT) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    var result = std.c.lseek(fd, position, std.c.SEEK.SET);
    while (result < 0) {
        abi.UX_prim_check_errno(abi.syscall_lseek);
        result = std.c.lseek(fd, position, std.c.SEEK.SET);
    }
    if (result != position) {
        abi.error_external_return();
    }
}

/// Truncate or extend an open file channel to `length` bytes.
pub fn osFileTruncate(channel: abi.Tchannel, length: abi.OffT) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    while (std.c.ftruncate(fd, length) < 0) {
        abi.UX_prim_check_errno(abi.syscall_ftruncate);
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&osOpenFd, .{ .name = "OS_open_fd" });
        @export(&osOpenInputFile, .{ .name = "OS_open_input_file" });
        @export(&osOpenOutputFile, .{ .name = "OS_open_output_file" });
        @export(&osOpenExclusiveOutputFile, .{ .name = "OS_open_exclusive_output_file" });
        @export(&osOpenIoFile, .{ .name = "OS_open_io_file" });
        @export(&osOpenAppendFile, .{ .name = "OS_open_append_file" });
        @export(&osOpenLoadFile, .{ .name = "OS_open_load_file" });
        @export(&osOpenDumpFile, .{ .name = "OS_open_dump_file" });
        @export(&osFileLength, .{ .name = "OS_file_length" });
        @export(&osFilePosition, .{ .name = "OS_file_position" });
        @export(&osFileSetPosition, .{ .name = "OS_file_set_position" });
        @export(&osFileTruncate, .{ .name = "OS_file_truncate" });
    }
}

fn closeTestChannel(ch: abi.Tchannel) void {
    const fd = abi.channel_table[ch].descriptor;
    if (fd >= 0) {
        _ = std.c.close(fd);
        abi.channel_table[ch].descriptor = -1;
    }
}

test "uxfile open, seek, length, truncate, load, dump on real temp file" {
    stubs.resetMockRuntime();

    const path: [*:0]const u8 = "/tmp/zig-m1-uxfile.tmp";
    _ = std.c.unlink(path);
    defer _ = std.c.unlink(path);

    try std.testing.expectEqual(abi.no_channel, osOpenLoadFile("/tmp/zig-m1-missing-nonexistent.tmp"));

    const out_ch = osOpenExclusiveOutputFile(path);
    defer closeTestChannel(out_ch);
    try std.testing.expectEqual(abi.ChannelType.file, abi.channel_table[out_ch].type);

    const payload = "hello world";
    const fd = abi.channel_table[out_ch].descriptor;
    const written = std.c.write(fd, payload.ptr, payload.len);
    try std.testing.expectEqual(@as(isize, payload.len), written);
    try std.testing.expectEqual(@as(abi.OffT, 11), osFilePosition(out_ch));
    try std.testing.expectEqual(@as(abi.OffT, 11), osFileLength(out_ch));

    osFileSetPosition(out_ch, 5);
    try std.testing.expectEqual(@as(abi.OffT, 5), osFilePosition(out_ch));

    osFileTruncate(out_ch, 7);
    try std.testing.expectEqual(@as(abi.OffT, 7), osFileLength(out_ch));
    closeTestChannel(out_ch);

    const app_ch = osOpenAppendFile(path);
    defer closeTestChannel(app_ch);
    const app_written = std.c.write(abi.channel_table[app_ch].descriptor, "!", 1);
    try std.testing.expectEqual(@as(isize, 1), app_written);
    try std.testing.expectEqual(@as(abi.OffT, 8), osFileLength(app_ch));
    closeTestChannel(app_ch);

    const load_ch = osOpenLoadFile(path);
    defer closeTestChannel(load_ch);
    try std.testing.expect(load_ch != abi.no_channel);
    try std.testing.expectEqual(@as(abi.OffT, 8), osFileLength(load_ch));
    closeTestChannel(load_ch);

    const io_ch = osOpenIoFile(path);
    defer closeTestChannel(io_ch);
    try std.testing.expectEqual(@as(abi.OffT, 8), osFileLength(io_ch));
    closeTestChannel(io_ch);

    const dump_ch = osOpenDumpFile(path);
    defer closeTestChannel(dump_ch);
    try std.testing.expect(dump_ch != abi.no_channel);
    try std.testing.expectEqual(@as(abi.OffT, 0), osFileLength(dump_ch));
    closeTestChannel(dump_ch);

    const in_ch = osOpenInputFile(path);
    defer closeTestChannel(in_ch);
    try std.testing.expectEqual(@as(abi.OffT, 0), osFileLength(in_ch));
}
