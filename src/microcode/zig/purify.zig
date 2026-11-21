// Derived from MIT/GNU Scheme C sources (`src/microcode/purify.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

// DEFINE_PRIMITIVE ("PRIMITIVE-PURIFY", Prim_primitive_purify, 3, 3,
//   "(OBJECT PURE? SAFETY-MARGIN)\n\
// Copy OBJECT from the heap into constant/pure space.\n\
// PURE? is ignored.")
pub export fn Prim_primitive_purify() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();

    abi.stackCheckFatal("PURIFY");

    const object = abi.argRef(1);
    const safety_margin = abi.argHeapReserved(3);
    abi.popPrimitiveFrame(3);

    abi.critical_section_name = "purify";
    abi.heap_reserved = safety_margin;
    purifyObject(object);

    abi.stackCheck(abi.cont_size);
    const avail = abi.heapAvailable();
    const remaining: c_ulong = if (avail > abi.gc_space_needed) avail - abi.gc_space_needed else 0;
    abi.pushCont(
        abi.rc_normal_gc_done,
        abi.cons(obj.sharp_t, obj.ulongToFixnum(remaining)),
    );

    abi.critical_section_name = "purify daemon";
    const daemon = obj.vectorRef(abi.fixed_objects, abi.fixobj_gc_daemon);
    if (daemon == obj.sharp_f) {
        abi.abort_to_interpreter(abi.prim_pop_return);
    }
    abi.stackCheck(2);
    abi.stackPush(daemon);
    abi.stackPush(abi.makeApplyFrameHeader(1));
    abi.abort_to_interpreter(abi.prim_apply);
}

fn purifyObject(object: obj.SchemeObject) void {
    abi.stackCheckFatal("PURIFY");

    abi.open_tospace(abi.constant_alloc_next);
    abi.initialize_weak_chain();

    const start_copy = abi.get_newspace_ptr();
    abi.add_to_tospace(object);

    abi.current_gc_table = abi.std_gc_table();
    abi.gc_scan_tospace(start_copy, null);

    const new_constant_alloc_next = abi.get_newspace_ptr();
    abi.increment_tospace_ptr(abi.constant_space_fudge);
    const heap_copy_start = abi.get_newspace_ptr();

    abi.std_gc_pt1();

    abi.constant_alloc_next = new_constant_alloc_next;
    abi.constant_end = heap_copy_start;
    abi.heap_start = abi.constant_end;

    abi.std_gc_pt2();

    const heap_words: c_ulong = @intCast((@intFromPtr(abi.heap_end) - @intFromPtr(abi.heap_start)) / @sizeOf(obj.SchemeObject));
    abi.resize_tospace(heap_words);
}

test "purify updates constant_alloc_next, constant_end, heap_start, and resizes tospace" {
    const stubs = @import("test_stubs.zig");
    const utils = @import("utils.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    var arena: [1024]obj.SchemeObject = @splat(0);
    abi.constant_start = (&arena).ptr;
    abi.constant_alloc_next = (&arena).ptr + 4;
    abi.constant_end = (&arena).ptr + 200;
    abi.heap_start = abi.constant_end;
    abi.heap_end = (&arena).ptr + arena.len;
    abi.heap_alloc_limit = abi.heap_end - 16;
    abi.fixed_objects = obj.sharp_f;
    utils.history_register = (&arena).ptr;

    const item = obj.ulongToFixnum(42);
    purifyObject(item);

    // 1 word added for object, then CONSTANT_SPACE_FUDGE (128) words reserved.
    try std.testing.expectEqual((&arena).ptr + 5, abi.constant_alloc_next);
    try std.testing.expectEqual((&arena).ptr + 5 + abi.constant_space_fudge, abi.constant_end);
    try std.testing.expectEqual(abi.constant_end, abi.heap_start);
    try std.testing.expectEqual(item, arena[4]);
    try std.testing.expectEqual(@as(usize, 1), stubs.mock_gc_drain_calls);
    try std.testing.expectEqual(@as(usize, 1), stubs.mock_update_weak_calls);
    try std.testing.expectEqual(@as(usize, 1), stubs.mock_save_tospace_calls);
    try std.testing.expectEqual(@as(c_ulong, arena.len - (5 + abi.constant_space_fudge)), stubs.mock_resize_tospace_arg);
}
