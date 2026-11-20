const std = @import("std");

pub var signal_block_depth: i32 = 0;
pub var fatal_count: usize = 0;

pub export fn OS_malloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(if (size == 0) 1 else size) orelse @panic("OS_malloc OOM");
}

pub export fn OS_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(ptr, if (size == 0) 1 else size) orelse @panic("OS_realloc OOM");
}

pub export fn OS_free(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

pub export fn block_signals() callconv(.c) void {
    signal_block_depth += 1;
}

pub export fn unblock_signals() callconv(.c) void {
    signal_block_depth -= 1;
}

pub export fn outf_fatal(_: [*:0]const u8, ...) callconv(.c) void {
    fatal_count += 1;
}

pub export fn outf_flush_fatal() callconv(.c) void {}

pub export fn strcmp_ci(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (true) : (i += 1) {
        const c1 = s1[i];
        const c2 = s2[i];
        if (c1 == 0) return if (c2 == 0) 0 else -1;
        if (c2 == 0) return 1;
        const ch1 = std.ascii.toUpper(c1);
        const ch2 = std.ascii.toUpper(c2);
        if (ch1 < ch2) return -1;
        if (ch1 > ch2) return 1;
    }
}
