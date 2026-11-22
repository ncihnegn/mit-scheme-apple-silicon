// Derived from MIT/GNU Scheme C sources (`src/microcode/outf.c`, `src/microcode/outf.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");

pub const ChannelType = enum(c_int) {
    console = 0,
    @"error" = 1,
    fatal = 2,
    file = 3,
};

pub const OutfChannel = extern struct {
    type: c_int,
    cookie: ?*anyopaque,
};

pub const console_output: OutfChannel = .{
    .type = @backingInt(ChannelType.console),
    .cookie = null,
};

pub const error_output: OutfChannel = .{
    .type = @backingInt(ChannelType.@"error"),
    .cookie = null,
};

pub const fatal_output: OutfChannel = .{
    .type = @backingInt(ChannelType.fatal),
    .cookie = null,
};

pub inline fn fileOutput(fp: *std.c.FILE) OutfChannel {
    return .{
        .type = @backingInt(ChannelType.file),
        .cookie = @ptrCast(fp),
    };
}

pub extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

pub inline fn cStdout() *std.c.FILE {
    if (builtin.os.tag.isDarwin()) {
        return (struct {
            extern "c" var __stdoutp: *std.c.FILE;
        }).__stdoutp;
    } else if (builtin.os.tag == .windows) {
        const WinIo = struct {
            extern "c" fn __acrt_iob_func(index: c_uint) *std.c.FILE;
        };
        return WinIo.__acrt_iob_func(1);
    }
    return (struct {
        extern "c" var stdout: *std.c.FILE;
    }).stdout;
}

pub inline fn cStderr() *std.c.FILE {
    if (builtin.os.tag.isDarwin()) {
        return (struct {
            extern "c" var __stderrp: *std.c.FILE;
        }).__stderrp;
    } else if (builtin.os.tag == .windows) {
        const WinIo = struct {
            extern "c" fn __acrt_iob_func(index: c_uint) *std.c.FILE;
        };
        return WinIo.__acrt_iob_func(2);
    }
    return (struct {
        extern "c" var stderr: *std.c.FILE;
    }).stderr;
}

pub var test_call_count: usize = 0;
pub var test_fatal_count: usize = 0;

const CFileWriter = struct {
    stream: *std.c.FILE,
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn init(stream: *std.c.FILE, buffer: []u8) CFileWriter {
        return .{
            .stream = stream,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
        };
    }

    fn writeBytes(stream: *std.c.FILE, bytes: []const u8) void {
        if (bytes.len == 0) return;
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, stream);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CFileWriter = @fieldParentPtr("interface", w);
        writeBytes(self.stream, w.buffered());
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            writeBytes(self.stream, slice);
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            writeBytes(self.stream, pattern);
            consumed += pattern.len;
        }
        return consumed;
    }
};

const DiscardWriter = struct {
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn init(buffer: []u8) DiscardWriter {
        return .{
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        w.end = 0;
        return std.Io.Writer.countSplat(data, splat);
    }
};

fn resolveStream(chan: OutfChannel) *std.c.FILE {
    return switch (chan.type) {
        @backingInt(ChannelType.console) => cStdout(),
        @backingInt(ChannelType.@"error"), @backingInt(ChannelType.fatal) => cStderr(),
        @backingInt(ChannelType.file) => @ptrCast(@alignCast(chan.cookie.?)),
        else => cStderr(),
    };
}

pub fn print(chan: OutfChannel, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    if (comptime builtin.is_test) {
        if (chan.type != @backingInt(ChannelType.file)) {
            if (chan.type == @backingInt(ChannelType.fatal)) {
                test_fatal_count += 1;
            } else {
                test_call_count += 1;
            }
            var dw = DiscardWriter.init(&buf);
            dw.interface.print(fmt, args) catch {};
            dw.interface.flush() catch {};
            return;
        }
    }
    var fw = CFileWriter.init(resolveStream(chan), &buf);
    fw.interface.print(fmt, args) catch {};
    fw.interface.flush() catch {};
}

pub fn flush(chan: OutfChannel) void {
    if (comptime builtin.is_test) {
        if (chan.type != @backingInt(ChannelType.file)) return;
    }
    _ = fflush(resolveStream(chan));
}

pub fn console(comptime fmt: []const u8, args: anytype) void {
    print(console_output, fmt, args);
}

pub fn flushConsole() void {
    flush(console_output);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    print(error_output, fmt, args);
}

pub fn errLine(comptime fmt: []const u8, args: anytype) void {
    print(error_output, fmt ++ "\n", args);
    flush(error_output);
}

pub fn flushError() void {
    flush(error_output);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    print(fatal_output, fmt, args);
}

pub fn flushFatal() void {
    flush(fatal_output);
}

test "outf streams formatted bytes including multi-chunk payloads to FILE" {
    const stubs = @import("../core/test_stubs.zig");
    const TmpC = struct {
        extern "c" fn rewind(*std.c.FILE) void;
        extern "c" fn fclose(*std.c.FILE) c_int;
    };
    const fp = stubs.openTempFile("outf").?;
    defer _ = TmpC.fclose(fp);

    const ch = fileOutput(fp);
    const cstr: [*:0]const u8 = "scheme";
    const big: [1536]u8 = @splat('A');
    print(ch, "{s}:{d}:0x{x:0>4}:{c}:", .{ cstr, 42, @as(u32, 0x2a), @as(u8, 'Z') });
    print(ch, "{s}", .{&big});
    flush(ch);

    TmpC.rewind(fp);
    var out: [2048]u8 = undefined;
    const n = std.c.fread(&out, 1, out.len, fp);
    const prefix = "scheme:42:0x002a:Z:";
    try std.testing.expectEqual(prefix.len + big.len, n);
    try std.testing.expectEqualStrings(prefix, out[0..prefix.len]);
    try std.testing.expectEqualSlices(u8, &big, out[prefix.len..n]);
}

test "outf test counters track console, error, and fatal calls" {
    const saved_calls = test_call_count;
    const saved_fatal = test_fatal_count;
    defer {
        test_call_count = saved_calls;
        test_fatal_count = saved_fatal;
    }

    test_call_count = 0;
    test_fatal_count = 0;
    console("hi {d}", .{1});
    err("warn {s}", .{"x"});
    errLine("line {x}", .{0xff});
    flushConsole();
    flushError();
    try std.testing.expectEqual(@as(usize, 3), test_call_count);
    try std.testing.expectEqual(@as(usize, 0), test_fatal_count);

    fatal("boom {d}", .{7});
    flushFatal();
    try std.testing.expectEqual(@as(usize, 3), test_call_count);
    try std.testing.expectEqual(@as(usize, 1), test_fatal_count);
}
