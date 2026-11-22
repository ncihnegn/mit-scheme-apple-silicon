// Derived from MIT/GNU Scheme C sources (`src/gdbm/gdbm-adapter.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const c = @import("gdbm_c");

extern "c" fn outf_error([*:0]const u8, ...) void;
extern "c" fn outf_flush_error() void;
extern "c" fn error_external_return() noreturn;

const need_nolock: bool = blk: {
    if (!@hasDecl(c, "GDBM_VERSION_MAJOR")) break :blk false;
    if (c.GDBM_VERSION_MAJOR > 1) break :blk true;
    break :blk c.GDBM_VERSION_MAJOR == 1 and
        @hasDecl(c, "GDBM_VERSION_MINOR") and
        c.GDBM_VERSION_MINOR >= 13;
};

fn getGdbmErrno() c.gdbm_error {
    if (@hasDecl(c, "gdbm_errno_location")) {
        return c.gdbm_errno_location().*;
    } else if (@hasDecl(c, "gdbm_errno")) {
        return c.gdbm_errno;
    } else {
        return 0;
    }
}

fn getSysErrno() c_int {
    return std.c._errno().*;
}

fn recordErrnos(args: *c.gdbm_args) void {
    args.errno_gdbm = getGdbmErrno();
    args.errno_sys = getSysErrno();
}

fn fatalError(msg: [*c]const u8) callconv(.c) void {
    outf_error("\ngdbm: %s\n", msg);
    outf_flush_error();
    error_external_return();
}

fn freeDatum(d: *c.datum) void {
    if (d.dptr != null) {
        std.c.free(d.dptr);
        d.dptr = null;
    }
    d.dsize = 0;
}

fn allocDatum(d: *c.datum, allocation: *c_int, size: c_int) ?[*]u8 {
    if (size <= allocation.*) {
        d.dsize = size;
        return @ptrCast(d.dptr);
    }
    freeDatum(d);
    const raw = std.c.malloc(@intCast(size)) orelse {
        allocation.* = 0;
        return null;
    };
    const bytes: [*]u8 = @ptrCast(raw);
    d.dptr = bytes;
    d.dsize = size;
    allocation.* = size;
    return bytes;
}

pub export fn alloc_gdbm_key(args: *c.gdbm_args, size: c_int) callconv(.c) ?[*]u8 {
    return allocDatum(&args.key, &args.key_allocation, size);
}

pub export fn alloc_gdbm_content(args: *c.gdbm_args, size: c_int) callconv(.c) ?[*]u8 {
    return allocDatum(&args.content, &args.content_allocation, size);
}

pub export fn get_gdbm_version() callconv(.c) ?[*:0]const u8 {
    return c.gdbm_version;
}

pub export fn do_gdbm_open(
    name: ?[*:0]const u8,
    block_size: c_int,
    read_write_in: c_int,
    mode: c_int,
) callconv(.c) ?*c.gdbm_args {
    const raw = std.c.malloc(@sizeOf(c.gdbm_args)) orelse return null;
    const args: *c.gdbm_args = @ptrCast(@alignCast(raw));

    var read_write = read_write_in;
    if (need_nolock) {
        read_write |= c.GDBM_NOLOCK;
    }

    args.* = .{
        .key = .{ .dptr = null, .dsize = 0 },
        .key_allocation = 0,
        .content = .{ .dptr = null, .dsize = 0 },
        .content_allocation = 0,
        .errno_gdbm = 0,
        .errno_sys = 0,
        .dbf = c.gdbm_open(name, block_size, read_write, mode, @ptrCast(&fatalError)),
    };
    if (args.dbf == null) {
        recordErrnos(args);
    }
    return args;
}

pub export fn do_gdbm_close(args: *c.gdbm_args) callconv(.c) void {
    _ = c.gdbm_close(args.dbf);
    freeDatum(&args.key);
    freeDatum(&args.content);
    std.c.free(args);
}

pub export fn do_gdbm_store(args: *c.gdbm_args, flag: c_int) callconv(.c) c_int {
    const ret = c.gdbm_store(args.dbf, args.key, args.content, flag);
    if (ret == -1) {
        recordErrnos(args);
    }
    return ret;
}

pub export fn do_gdbm_fetch(args: *c.gdbm_args) callconv(.c) void {
    freeDatum(&args.content);
    args.content = c.gdbm_fetch(args.dbf, args.key);
    args.content_allocation = if (args.content.dptr != null) args.content.dsize else 0;
}

pub export fn do_gdbm_exists(args: *c.gdbm_args) callconv(.c) c_int {
    return c.gdbm_exists(args.dbf, args.key);
}

pub export fn do_gdbm_delete(args: *c.gdbm_args) callconv(.c) c_int {
    return c.gdbm_delete(args.dbf, args.key);
}

pub export fn do_gdbm_firstkey(args: *c.gdbm_args) callconv(.c) void {
    freeDatum(&args.key);
    args.key = c.gdbm_firstkey(args.dbf);
    args.key_allocation = if (args.key.dptr != null) args.key.dsize else 0;
}

pub export fn do_gdbm_nextkey(args: *c.gdbm_args) callconv(.c) c_int {
    const next = c.gdbm_nextkey(args.dbf, args.key);
    if (next.dptr == null) {
        return 1;
    }
    freeDatum(&args.key);
    args.key = next;
    args.key_allocation = next.dsize;
    return 0;
}

pub export fn do_gdbm_reorganize(args: *c.gdbm_args) callconv(.c) c_int {
    const ret = c.gdbm_reorganize(args.dbf);
    if (ret != 0) {
        recordErrnos(args);
    }
    return ret;
}

pub export fn do_gdbm_sync(args: *c.gdbm_args) callconv(.c) void {
    _ = c.gdbm_sync(args.dbf);
}

pub export fn do_gdbm_setopt(args: *c.gdbm_args, option: c_int, value: c_int) callconv(.c) c_int {
    var val = value;
    const ret = c.gdbm_setopt(args.dbf, option, &val, @sizeOf(c_int));
    if (ret != 0) {
        recordErrnos(args);
    }
    return ret;
}
