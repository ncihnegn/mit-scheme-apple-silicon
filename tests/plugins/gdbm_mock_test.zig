const std = @import("std");
const c = @import("gdbm_c");
const adapter = @import("gdbm_adapter");

var mock_gdbm_errno_val: c.gdbm_error = c.GDBM_NO_ERROR;
var mock_open_should_fail: bool = false;
var mock_last_open_rw: c_int = 0;
var mock_last_setopt_val: c_int = -1;
var mock_closed_count: usize = 0;
var mock_sync_count: usize = 0;
var mock_reorg_count: usize = 0;
var mock_stored_key: [64]u8 = @splat(0);
var mock_stored_key_len: usize = 0;
var mock_stored_val: [64]u8 = @splat(0);
var mock_stored_val_len: usize = 0;
var mock_has_entry: bool = false;

pub export const gdbm_version: [*:0]const u8 = "GDBM mock 1.23";

pub export fn gdbm_errno_location() callconv(.c) *c.gdbm_error {
    return &mock_gdbm_errno_val;
}

pub export fn outf_error(_: [*:0]const u8, ...) callconv(.c) void {}
pub export fn outf_flush_error() callconv(.c) void {}
pub export fn error_external_return() callconv(.c) noreturn {
    @panic("unexpected error_external_return in test");
}

pub export fn gdbm_open(
    _: [*c]const u8,
    _: c_int,
    read_write: c_int,
    _: c_int,
    _: ?*const fn ([*c]const u8) callconv(.c) void,
) callconv(.c) c.GDBM_FILE {
    mock_last_open_rw = read_write;
    if (mock_open_should_fail) {
        mock_gdbm_errno_val = c.GDBM_FILE_OPEN_ERROR;
        return null;
    }
    return @ptrFromInt(0x1234);
}

pub export fn gdbm_close(_: c.GDBM_FILE) callconv(.c) c_int {
    mock_closed_count += 1;
    return 0;
}

pub export fn gdbm_store(_: c.GDBM_FILE, key: c.datum, content: c.datum, _: c_int) callconv(.c) c_int {
    const klen: usize = @intCast(key.dsize);
    const vlen: usize = @intCast(content.dsize);
    @memcpy(mock_stored_key[0..klen], key.dptr[0..klen]);
    mock_stored_key_len = klen;
    @memcpy(mock_stored_val[0..vlen], content.dptr[0..vlen]);
    mock_stored_val_len = vlen;
    mock_has_entry = true;
    return 0;
}

pub export fn gdbm_fetch(_: c.GDBM_FILE, key: c.datum) callconv(.c) c.datum {
    const klen: usize = @intCast(key.dsize);
    if (!mock_has_entry or klen != mock_stored_key_len or
        !std.mem.eql(u8, key.dptr[0..klen], mock_stored_key[0..mock_stored_key_len]))
    {
        return .{ .dptr = null, .dsize = 0 };
    }
    const raw = std.c.malloc(mock_stored_val_len).?;
    const buf: [*]u8 = @ptrCast(raw);
    @memcpy(buf[0..mock_stored_val_len], mock_stored_val[0..mock_stored_val_len]);
    return .{ .dptr = buf, .dsize = @intCast(mock_stored_val_len) };
}

pub export fn gdbm_exists(_: c.GDBM_FILE, key: c.datum) callconv(.c) c_int {
    const klen: usize = @intCast(key.dsize);
    return if (mock_has_entry and klen == mock_stored_key_len and
        std.mem.eql(u8, key.dptr[0..klen], mock_stored_key[0..mock_stored_key_len])) 1 else 0;
}

pub export fn gdbm_delete(_: c.GDBM_FILE, key: c.datum) callconv(.c) c_int {
    const klen: usize = @intCast(key.dsize);
    if (mock_has_entry and klen == mock_stored_key_len and
        std.mem.eql(u8, key.dptr[0..klen], mock_stored_key[0..mock_stored_key_len]))
    {
        mock_has_entry = false;
        return 0;
    }
    mock_gdbm_errno_val = c.GDBM_ITEM_NOT_FOUND;
    return -1;
}

pub export fn gdbm_firstkey(_: c.GDBM_FILE) callconv(.c) c.datum {
    if (!mock_has_entry) return .{ .dptr = null, .dsize = 0 };
    const raw = std.c.malloc(mock_stored_key_len).?;
    const buf: [*]u8 = @ptrCast(raw);
    @memcpy(buf[0..mock_stored_key_len], mock_stored_key[0..mock_stored_key_len]);
    return .{ .dptr = buf, .dsize = @intCast(mock_stored_key_len) };
}

pub export fn gdbm_nextkey(_: c.GDBM_FILE, _: c.datum) callconv(.c) c.datum {
    return .{ .dptr = null, .dsize = 0 };
}

pub export fn gdbm_reorganize(_: c.GDBM_FILE) callconv(.c) c_int {
    mock_reorg_count += 1;
    return 0;
}

pub export fn gdbm_sync(_: c.GDBM_FILE) callconv(.c) c_int {
    mock_sync_count += 1;
    return 0;
}

pub export fn gdbm_setopt(_: c.GDBM_FILE, _: c_int, val: ?*anyopaque, size: c_int) callconv(.c) c_int {
    if (size != @sizeOf(c_int)) return -1;
    const ptr: *const c_int = @ptrCast(@alignCast(val.?));
    mock_last_setopt_val = ptr.*;
    return 0;
}

pub export fn gdbm_strerror(_: c.gdbm_error) callconv(.c) [*c]const u8 {
    return "mock error";
}

test "gdbm_adapter open failure records NOLOCK and errno_gdbm" {
    mock_open_should_fail = true;
    mock_gdbm_errno_val = c.GDBM_NO_ERROR;
    const args = adapter.do_gdbm_open("missing.db", 0, c.GDBM_READER, 0o600).?;
    defer std.c.free(args);

    try std.testing.expectEqual(@as(c.GDBM_FILE, null), args.dbf);
    try std.testing.expectEqual(@as(c.gdbm_error, c.GDBM_FILE_OPEN_ERROR), args.errno_gdbm);
    try std.testing.expect((mock_last_open_rw & c.GDBM_NOLOCK) != 0);
}

test "gdbm_adapter full key/content CRUD lifecycle" {
    mock_open_should_fail = false;
    mock_has_entry = false;
    mock_closed_count = 0;
    mock_sync_count = 0;
    mock_reorg_count = 0;

    const ver = std.mem.span(adapter.get_gdbm_version().?);
    try std.testing.expectEqualStrings("GDBM mock 1.23", ver);

    const args = adapter.do_gdbm_open("test.db", 0, c.GDBM_WRCREAT, 0o644).?;
    try std.testing.expect(args.dbf != null);

    // Allocate, reuse smaller size, then grow
    const kptr1 = adapter.alloc_gdbm_key(args, 8).?;
    @memcpy(kptr1[0..5], "alpha");
    _ = adapter.alloc_gdbm_key(args, 5);
    try std.testing.expectEqual(@as(c_int, 8), args.key_allocation);
    try std.testing.expectEqual(@as(c_int, 5), args.key.dsize);

    const kptr2 = adapter.alloc_gdbm_key(args, 16).?;
    try std.testing.expectEqual(@as(c_int, 16), args.key_allocation);
    @memcpy(kptr2[0..5], "hello");
    args.key.dsize = 5;

    const vptr = adapter.alloc_gdbm_content(args, 5).?;
    @memcpy(vptr[0..5], "world");

    try std.testing.expectEqual(@as(c_int, 0), adapter.do_gdbm_store(args, c.GDBM_REPLACE));
    try std.testing.expectEqual(@as(c_int, 1), adapter.do_gdbm_exists(args));

    adapter.do_gdbm_fetch(args);
    try std.testing.expectEqual(@as(c_int, 5), args.content.dsize);
    try std.testing.expectEqualStrings("world", args.content.dptr[0..5]);

    adapter.do_gdbm_firstkey(args);
    try std.testing.expectEqual(@as(c_int, 5), args.key.dsize);
    try std.testing.expectEqualStrings("hello", args.key.dptr[0..5]);
    try std.testing.expectEqual(@as(c_int, 1), adapter.do_gdbm_nextkey(args));

    try std.testing.expectEqual(@as(c_int, 0), adapter.do_gdbm_setopt(args, c.GDBM_CACHESIZE, 42));
    try std.testing.expectEqual(@as(c_int, 42), mock_last_setopt_val);

    try std.testing.expectEqual(@as(c_int, 0), adapter.do_gdbm_reorganize(args));
    adapter.do_gdbm_sync(args);
    try std.testing.expectEqual(@as(usize, 1), mock_reorg_count);
    try std.testing.expectEqual(@as(usize, 1), mock_sync_count);

    try std.testing.expectEqual(@as(c_int, 0), adapter.do_gdbm_delete(args));
    try std.testing.expectEqual(@as(c_int, 0), adapter.do_gdbm_exists(args));

    adapter.do_gdbm_close(args);
    try std.testing.expectEqual(@as(usize, 1), mock_closed_count);
}
