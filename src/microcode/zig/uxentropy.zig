const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const transact = @import("transact.zig");
const wind = @import("wind.zig");

const path_urandom: [*:0]const u8 = "/dev/urandom";

fn txClose(cookie: ?*anyopaque) callconv(.c) void {
    const fdp: *c_int = @ptrCast(@alignCast(cookie.?));
    if (fdp.* != -1) {
        _ = std.c.close(fdp.*);
    }
}

/// Fill a 32-byte buffer from `/dev/urandom`, closing the descriptor via a transaction action.
pub fn osGetEntropy(buf: *[32]u8) callconv(.c) void {
    var fd: c_int = -1;
    transact.transaction_begin();
    transact.transaction_record_action(.tat_always, &txClose, @ptrCast(&fd));
    fd = abi.openFdRetry(path_urandom, .{ .ACCMODE = .RDONLY }, abi.mode_reg);
    var offset: usize = 0;
    while (offset < buf.len) {
        const nread = std.c.read(fd, @ptrCast(buf[offset..].ptr), buf.len - offset);
        if (nread == 0) break;
        if (nread < 0) {
            abi.UX_prim_check_errno(abi.syscall_read);
            continue;
        }
        offset += @intCast(nread);
    }
    if (offset >= buf.len) {
        transact.transaction_commit();
        return;
    }
    // Premature EOF makes no sense on /dev/urandom.
    abi.error_external_return();
}

comptime {
    if (!builtin.is_test) {
        @export(&osGetEntropy, .{ .name = "OS_get_entropy" });
    }
}

test "uxentropy reads 32 random bytes from /dev/urandom" {
    wind.dstack_initialize();
    transact.transaction_initialize();
    defer {
        transact.transaction_initialize();
        wind.dstack_reset();
    }

    var buf1: [32]u8 = @splat(0);
    var buf2: [32]u8 = @splat(0);
    osGetEntropy(&buf1);
    osGetEntropy(&buf2);

    try std.testing.expect(!std.mem.allEqual(u8, &buf1, 0));
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}
