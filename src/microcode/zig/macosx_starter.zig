// Derived from MIT/GNU Scheme C sources (`src/microcode/macosx-starter.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

const CFBundleRef = *opaque {};
const CFURLRef = *opaque {};
const CFStringRef = *opaque {};
const CFTypeRef = *const anyopaque;

extern "c" fn CFBundleGetMainBundle() ?CFBundleRef;
extern "c" fn CFBundleCopyResourceURL(bundle: CFBundleRef, resourceName: CFStringRef, resourceType: CFStringRef, subDirName: ?CFStringRef) ?CFURLRef;
extern "c" fn CFURLGetFileSystemRepresentation(url: CFURLRef, resolveAgainstBase: u8, buffer: [*]u8, maxBufLen: c_long) u8;
extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn __CFStringMakeConstantString(cStr: [*:0]const u8) CFStringRef;

extern "c" fn mkstemps(template: [*:0]u8, suffixlen: c_int) c_int;
extern "c" fn fchmod(fd: c_int, mode: std.c.mode_t) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn fclose(stream: *std.c.FILE) c_int;
extern "c" fn fflush(stream: ?*std.c.FILE) c_int;
extern "c" fn fputs(s: [*:0]const u8, stream: *std.c.FILE) c_int;
extern "c" fn fputc(c: c_int, stream: *std.c.FILE) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const eof_c: c_int = -1;

fn bufPrintZHelper(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]u8 {
    if (buf.len == 0) return null;
    const out = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return null;
    buf[out.len] = 0;
    return buf[0..out.len :0];
}

fn formatX11CheckPath(buf: []u8, scheme_path: []const u8) ?[:0]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, scheme_path, '/') orelse return null;
    const prefix = scheme_path[0..slash];
    return bufPrintZHelper(buf, "{s}/x11-screen/x11-screen.com", .{prefix});
}

fn x11EdwinAvailableP(scheme_path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const check_path = formatX11CheckPath(&buf, scheme_path) orelse return false;
    if (std.c.access(check_path.ptr, std.c.R_OK) != 0) {
        return false;
    }
    if (std.c.getenv("DISPLAY")) |display| {
        if (display[0] != 0) return true;
    }
    return std.c.access("/opt/X11/bin/Xquartz", std.c.X_OK) == 0 or
        std.c.access("/Applications/Utilities/XQuartz.app", std.c.F_OK) == 0;
}

fn writeShSingleQuoted(fp: *std.c.FILE, s: []const u8) bool {
    for (s) |ch| {
        if (ch == '\'') {
            if (fputs("'\\''", fp) == eof_c) return false;
        } else {
            if (fputc(@intCast(ch), fp) == eof_c) return false;
        }
    }
    return true;
}

fn formatTerminalScriptPath(buf: []u8, tmpdir_opt: ?[]const u8) ?[:0]u8 {
    var tmpdir: []const u8 = tmpdir_opt orelse "/tmp";
    if (tmpdir.len == 0) {
        tmpdir = "/tmp";
    }
    while (tmpdir.len > 1 and tmpdir[tmpdir.len - 1] == '/') {
        tmpdir = tmpdir[0 .. tmpdir.len - 1];
    }
    return bufPrintZHelper(buf, "{s}/mit-scheme-XXXXXX.command", .{tmpdir});
}

fn launchInTerminal(scheme_path: []const u8) u8 {
    const tmpdir_c = std.c.getenv("TMPDIR");
    const tmpdir_opt: ?[]const u8 = if (tmpdir_c) |p| std.mem.span(p) else null;

    var script_buf: [4096]u8 = undefined;
    const script_path = formatTerminalScriptPath(&script_buf, tmpdir_opt) orelse return 4;

    const fd = mkstemps(script_path.ptr, 8);
    if (fd < 0) return 4;

    if (fchmod(fd, 0o700) != 0) {
        _ = std.c.close(fd);
        _ = std.c.unlink(script_path.ptr);
        return 4;
    }

    const fp = fdopen(fd, "w") orelse {
        _ = std.c.close(fd);
        _ = std.c.unlink(script_path.ptr);
        return 4;
    };

    if (fputs("#!/bin/sh\nrm -f -- \"$0\"\nexec '", fp) == eof_c or
        !writeShSingleQuoted(fp, scheme_path) or
        fputs("' --macosx-application --edit\n", fp) == eof_c or
        fflush(fp) != 0)
    {
        _ = fclose(fp);
        _ = std.c.unlink(script_path.ptr);
        return 4;
    }

    if (fclose(fp) != 0) {
        _ = std.c.unlink(script_path.ptr);
        return 4;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.unlink(script_path.ptr);
        return 3;
    }
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{
            "open",
            "-a",
            "Terminal",
            script_path.ptr,
            null,
        };
        _ = execv("/usr/bin/open", &argv);
        std.c._exit(1);
    }

    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) == pid) {
        const ustatus: u32 = @bitCast(status);
        if (!std.c.W.IFEXITED(ustatus) or std.c.W.EXITSTATUS(ustatus) != 0) {
            _ = std.c.unlink(script_path.ptr);
            return 5;
        }
    }
    return 0;
}

pub fn main() u8 {
    const bundle = CFBundleGetMainBundle() orelse return 1;
    const url = CFBundleCopyResourceURL(
        bundle,
        __CFStringMakeConstantString("mit-scheme"),
        __CFStringMakeConstantString(""),
        null,
    ) orelse return 2;

    var buffer: [4096]u8 = @splat(0);
    if (CFURLGetFileSystemRepresentation(url, 1, &buffer, buffer.len) == 0) {
        CFRelease(url);
        return 3;
    }
    CFRelease(url);

    const scheme_path = std.mem.sliceTo(&buffer, 0);
    const scheme_path_z: [*:0]const u8 = @ptrCast(&buffer);

    if (x11EdwinAvailableP(scheme_path)) {
        const pid = std.c.fork();
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{
                scheme_path_z,
                "--macosx-application",
                "--edit",
                null,
            };
            _ = execv(scheme_path_z, &argv);
            std.c._exit(1);
        }
        return if (pid > 0) 0 else 3;
    }

    return launchInTerminal(scheme_path);
}

extern "c" fn tmpfile() ?*std.c.FILE;
extern "c" fn rewind(stream: *std.c.FILE) void;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *std.c.FILE) usize;

test "macosx_starter path formatting, single quoting, and x11 availability checks" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/Applications/MIT-Scheme.app/Contents/Resources/x11-screen/x11-screen.com",
        formatX11CheckPath(&buf, "/Applications/MIT-Scheme.app/Contents/Resources/mit-scheme").?,
    );
    try std.testing.expectEqual(@as(?[:0]u8, null), formatX11CheckPath(&buf, "mit-scheme"));
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[:0]u8, null), formatX11CheckPath(&tiny, "/long/path/mit-scheme"));

    try std.testing.expectEqualStrings("/tmp/mit-scheme-XXXXXX.command", formatTerminalScriptPath(&buf, null).?);
    try std.testing.expectEqualStrings("/tmp/mit-scheme-XXXXXX.command", formatTerminalScriptPath(&buf, "").?);
    try std.testing.expectEqualStrings("/tmp/mit-scheme-XXXXXX.command", formatTerminalScriptPath(&buf, "/tmp///").?);
    try std.testing.expectEqualStrings("//mit-scheme-XXXXXX.command", formatTerminalScriptPath(&buf, "/").?);
    try std.testing.expectEqualStrings("/var/tmp/mit-scheme-XXXXXX.command", formatTerminalScriptPath(&buf, "/var/tmp/").?);

    const fp = tmpfile().?;
    defer _ = fclose(fp);
    try std.testing.expect(writeShSingleQuoted(fp, "/Applications/It's Scheme/bin/'run'"));
    try std.testing.expectEqual(@as(c_int, 0), fflush(fp));
    rewind(fp);
    var read_buf: [128]u8 = @splat(0);
    const n = fread(&read_buf, 1, read_buf.len, fp);
    try std.testing.expectEqualStrings("/Applications/It'\\''s Scheme/bin/'\\''run'\\''", read_buf[0..n]);

    try std.testing.expect(!x11EdwinAvailableP("mit-scheme"));
    try std.testing.expect(!x11EdwinAvailableP("/nonexistent-zig-dir/mit-scheme"));
}
