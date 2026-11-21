// Derived from MIT/GNU Scheme C sources (`src/microcode/bkpt.c`, `src/microcode/bkpt.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

pub const SpRecord = extern struct {
    sp: ?[*]obj.SchemeObject,
    next: ?*SpRecord,
};

extern "c" fn Print_One_Continuation_Frame(obj.SchemeObject) bool;

pub var sp_list: ?*SpRecord = null;
var one_before: SpRecord = .{
    .sp = null,
    .next = null,
};

comptime {
    if (build_options.debugging) {
        @export(&sp_list, .{ .name = "SP_List" });
        @export(&addAPopReturnBreakpoint, .{ .name = "Add_a_Pop_Return_Breakpoint" });
        @export(&handlePopReturnBreak, .{ .name = "Handle_Pop_Return_Break" });
        @export(&popReturnBreakPoint, .{ .name = "Pop_Return_Break_Point" });
    }
}

pub fn addAPopReturnBreakpoint(sp: [*]obj.SchemeObject) callconv(.c) bool {
    const old = sp_list;
    const raw = std.c.malloc(@sizeOf(SpRecord)) orelse {
        abi.outf_error("Could not allocate a breakpoint structure\n");
        sp_list = old;
        return false;
    };
    const rec: *SpRecord = @ptrCast(@alignCast(raw));
    rec.sp = sp;
    rec.next = old;
    sp_list = rec;
    one_before.next = sp_list;
    return true;
}

pub fn handlePopReturnBreak() callconv(.c) void {
    const old_stack = abi.stack_pointer;
    abi.outf_error("Pop Return Break: SP = %#zx\n", @as(usize, @intCast(@intFromPtr(abi.stack_pointer))));
    _ = Print_One_Continuation_Frame(abi.Registers[abi.regblock_return]);
    abi.stack_pointer = old_stack;
}

pub fn popReturnBreakPoint() callconv(.c) void {
    const sp = abi.stack_pointer;
    var previous: *SpRecord = &one_before;
    var current = previous.next;
    while (current) |node| {
        if (node.sp == sp) {
            handlePopReturnBreak();
            previous.next = node.next;
            break;
        }
        previous = node;
        current = node.next;
    }
    sp_list = one_before.next;
}

test "bkpt add and fire pop-return breakpoint in debugging mode" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    if (build_options.debugging) {
        abi.stackPush(obj.sharp_f);
        abi.Registers[abi.regblock_return] = obj.makeObject(obj.tc_return_code, abi.rc_end_of_computation);
        const target_sp = abi.stack_pointer;
        try std.testing.expect(addAPopReturnBreakpoint(target_sp));
        try std.testing.expect(sp_list != null);
        popReturnBreakPoint();
        try std.testing.expect(stubs.mock_outf_calls > 0);
        try std.testing.expectEqual(target_sp, abi.stack_pointer);
        try std.testing.expect(sp_list == null);
    } else {
        try std.testing.expect(sp_list == null);
    }
}
