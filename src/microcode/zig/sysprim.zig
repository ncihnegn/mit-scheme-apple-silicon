// Derived from MIT/GNU Scheme C sources (`src/microcode/sysprim.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");
const str = @import("string.zig");

// DEFINE_PRIMITIVE ("EXIT", Prim_non_restartable_exit, 0, 0,
//   "Exit Scheme with no option to restart.")
pub export fn Prim_non_restartable_exit() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.termination_normal(0);
}

// DEFINE_PRIMITIVE ("EXIT-WITH-VALUE", Prim_non_restartable_exit_with_value, 1, 1,
//   "Exit Scheme with no option to restart, returning integer argument\n\
// as exit status.")
pub export fn Prim_non_restartable_exit_with_value() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.termination_normal(@truncate(abi.arg_integer(1)));
}

// DEFINE_PRIMITIVE ("HALT", Prim_restartable_exit, 0, 0,
//   "Exit Scheme, suspending it to that it can be restarted.")
pub export fn Prim_restartable_exit() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_restartable_exit();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("UNDER-EMACS?", Prim_under_emacs_p, 0, 0, 0)
pub export fn Prim_under_emacs_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_under_emacs_p() != 0);
}

// DEFINE_PRIMITIVE ("SET-TRAP-STATE!", Prim_set_trap_state, 1, 1, 0)
pub export fn Prim_set_trap_state() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const state = abi.arg_nonnegative_integer(1);
    if (state > std.math.maxInt(c_int)) abi.error_bad_range_arg(1);
    const result = abi.OS_set_trap_state(@intCast(state));
    if (result < 0) abi.error_bad_range_arg(1);
    return obj.longToUnsignedFixnum(@intCast(result));
}

// DEFINE_PRIMITIVE ("HEAP-AVAILABLE?", Prim_heap_available_p, 1, 1,
//   "(N-WORDS)\n\
// Tests to see if there are at least N-WORDS words of heap storage available")
pub export fn Prim_heap_available_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.heapAvailableP(abi.arg_ulong_integer(1)));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-GET-FREE", Prim_get_free, 1, 1,
//   "(TYPE-CODE)\n\
// Return the value of the free pointer tagged with TYPE-CODE")
pub export fn Prim_get_free() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.makePointerObject(abi.arg_ulong_index_integer(1, obj.n_type_codes), abi.Free);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-INCREMENT-FREE", Prim_increment_free, 1, 1,
//   "(N-WORDS)\n\
// Advance the free pointer by N-WORDS words.")
pub export fn Prim_increment_free() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.Free += @as(usize, @intCast(abi.arg_ulong_integer(1)));
    return obj.unspecific;
}

inline fn convertAddress(address: [*]const obj.SchemeObject) obj.SchemeObject {
    return artutl.ulong_to_integer(obj.addressToDatum(address));
}

// DEFINE_PRIMITIVE ("GC-SPACE-STATUS", Prim_gc_space_status, 0, 0, 0)
pub export fn Prim_gc_space_status() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const v = abi.make_vector(12, obj.sharp_f, true);
    obj.vectorSet(v, 0, obj.ulongToFixnum(@sizeOf(obj.SchemeObject)));
    obj.vectorSet(v, 1, convertAddress(abi.constant_start));
    obj.vectorSet(v, 2, convertAddress(abi.constant_alloc_next));
    obj.vectorSet(v, 3, convertAddress(abi.constant_end));
    obj.vectorSet(v, 4, convertAddress(abi.heap_start));
    obj.vectorSet(v, 5, convertAddress(abi.Free));
    obj.vectorSet(v, 6, convertAddress(abi.heap_alloc_limit));
    obj.vectorSet(v, 7, convertAddress(abi.heap_end));
    obj.vectorSet(v, 8, convertAddress(abi.stack_start));
    obj.vectorSet(v, 9, convertAddress(abi.stack_pointer));
    obj.vectorSet(v, 10, convertAddress(abi.stack_guard));
    obj.vectorSet(v, 11, convertAddress(abi.stack_end));
    return v;
}

// DEFINE_PRIMITIVE ("SCHEME-PROGRAM-NAME", Prim_scheme_program_name, 0, 0, 0)
pub export fn Prim_scheme_program_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return str.char_pointer_to_string(abi.scheme_program_name);
}

// DEFINE_PRIMITIVE ("READ-BYTE-FROM-MEMORY", Prim_read_byte_from_memory, 1, 1,
//   "(ADDRESS)\n\
// Read a byte from memory at ADDRESS and return it as an unsigned integer.")
pub export fn Prim_read_byte_from_memory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: *const u8 = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(1))));
    return artutl.ulong_to_integer(ptr.*);
}

// DEFINE_PRIMITIVE ("READ-WORD-FROM-MEMORY", Prim_read_word_from_memory, 1, 1,
//   "(ADDRESS)\n\
// Read a word from memory at ADDRESS and return it as an unsigned integer.")
pub export fn Prim_read_word_from_memory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: *align(1) const usize = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(1))));
    return artutl.ulong_to_integer(ptr.*);
}

// DEFINE_PRIMITIVE ("READ-FLOAT-FROM-MEMORY", Prim_read_float_from_memory, 1, 1,
//   "(ADDRESS)\n\
// Read a float from memory at ADDRESS and return it as a flonum.")
pub export fn Prim_read_float_from_memory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: *align(1) const f64 = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(1))));
    return abi.double_to_flonum(ptr.*);
}

// DEFINE_PRIMITIVE ("WRITE-BYTE-TO-MEMORY", Prim_write_byte_to_memory, 2, 2,
//   "(BYTE ADDRESS)\n\
// Write BYTE to memory at ADDRESS.")
pub export fn Prim_write_byte_to_memory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const val: u8 = @intCast(abi.arg_index_integer(1, 0x100));
    const ptr: *u8 = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(2))));
    ptr.* = val;
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("WRITE-WORD-TO-MEMORY", Prim_write_word_to_memory, 2, 2,
//   "(WORD ADDRESS)\n\
// Write WORD to memory at ADDRESS.")
pub export fn Prim_write_word_to_memory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const word = abi.arg_ulong_integer(1);
    const ptr: *align(1) usize = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(2))));
    ptr.* = word;
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("WRITE-FLOAT-TO-MEMORY", Prim_write_float_to_memory, 2, 2,
//   "(FLOAT ADDRESS)\n\
// Write FLOAT to memory at ADDRESS.")
pub export fn Prim_write_float_to_memory() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const fl = abi.arg_flonum(1);
    const ptr: *align(1) f64 = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(2))));
    ptr.* = fl;
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CC-BLOCK-LINKAGE-INFO", Prim_cc_block_linkage_info, 1, 1, 0)
pub export fn Prim_cc_block_linkage_info() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccBlockP);
    return abi.cc_block_linkage_info(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("control-point-next-frame", Prim_cpoint_next_frame, 2, 2, 0)
pub export fn Prim_cpoint_next_frame() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.controlPointP);
    const cpoint = abi.argRef(1);
    const length = obj.vectorLength(cpoint);
    const index = abi.arg_ulong_index_integer(2, length);
    if (!abi.return_address_p(obj.vectorRef(cpoint, @intCast(index)))) {
        abi.error_bad_range_arg(2);
    }
    const next_index = abi.cpoint_next_frame(cpoint, index);
    if (next_index == std.math.maxInt(usize)) return obj.sharp_f;
    if (!(next_index == length or
        (next_index < length and
            (obj.vectorRef(cpoint, @intCast(index)) == obj.makeReturnCode(abi.rc_hardware_trap) or
                abi.return_address_p(obj.vectorRef(cpoint, @intCast(next_index)))))))
    {
        abi.error_external_return();
    }
    std.debug.assert(obj.ulongToFixnumP(next_index));
    return obj.ulongToFixnum(next_index);
}

fn vectorOrCpointP(o: obj.SchemeObject) bool {
    return obj.vectorP(o) or obj.controlPointP(o);
}

// DEFINE_PRIMITIVE ("return-frame-type", Prim_return_frame_type, 2, 2, 0)
pub export fn Prim_return_frame_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, vectorOrCpointP);
    const v = abi.argRef(1);
    const i = abi.arg_ulong_index_integer(2, obj.vectorLength(v));
    return obj.ulongToFixnum(@intCast(abi.return_frame_type(obj.vectorLoc(v, @intCast(i)))));
}

// DEFINE_PRIMITIVE ("return-code-frame-type", Prim_return_code_frame_type, 1, 1, 0)
pub export fn Prim_return_code_frame_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.returnCodeP);
    return obj.ulongToFixnum(@intCast(abi.return_code_frame_type(abi.argRef(1))));
}

test "sysprim heap status, free pointer, trap state, and raw memory access" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{obj.ulongToFixnum(16)});
    try std.testing.expectEqual(obj.sharp_t, Prim_heap_available_p());

    const orig_free = abi.Free;
    stubs.setArgs(&.{obj.ulongToFixnum(obj.tc_vector)});
    try std.testing.expectEqual(obj.makePointerObject(obj.tc_vector, orig_free), Prim_get_free());
    stubs.setArgs(&.{obj.ulongToFixnum(4)});
    _ = Prim_increment_free();
    try std.testing.expectEqual(orig_free + 4, abi.Free);

    stubs.setArgs(&.{});
    const status = Prim_gc_space_status();
    try std.testing.expectEqual(@as(usize, 12), obj.vectorLength(status));
    try std.testing.expectEqual(obj.ulongToFixnum(@sizeOf(obj.SchemeObject)), obj.vectorRef(status, 0));

    stubs.mock_under_emacs = 1;
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.sharp_t, Prim_under_emacs_p());

    stubs.setArgs(&.{obj.ulongToFixnum(2)});
    try std.testing.expectEqual(obj.ulongToFixnum(4), Prim_set_trap_state());
    try std.testing.expectEqual(@as(c_int, 2), stubs.mock_trap_state);

    // Raw memory byte/word/float read+write on aligned & unaligned addresses
    var raw_buf: [16]u8 align(8) = @splat(0);
    const addr_byte = artutl.ulong_to_integer(@intFromPtr(&raw_buf[0]));
    const addr_word = artutl.ulong_to_integer(@intFromPtr(&raw_buf[1]));
    const addr_flt = artutl.ulong_to_integer(@intFromPtr(&raw_buf[8]));

    stubs.setArgs(&.{ obj.ulongToFixnum(0xAB), addr_byte });
    _ = Prim_write_byte_to_memory();
    stubs.setArgs(&.{addr_byte});
    try std.testing.expectEqual(obj.ulongToFixnum(0xAB), Prim_read_byte_from_memory());

    stubs.setArgs(&.{ obj.ulongToFixnum(0x12345678), addr_word });
    _ = Prim_write_word_to_memory();
    stubs.setArgs(&.{addr_word});
    try std.testing.expectEqual(obj.ulongToFixnum(0x12345678), Prim_read_word_from_memory());

    stubs.setArgs(&.{ abi.double_to_flonum(3.25), addr_flt });
    _ = Prim_write_float_to_memory();
    stubs.setArgs(&.{addr_flt});
    try std.testing.expectEqual(@as(f64, 3.25), obj.flonumToDouble(Prim_read_float_from_memory()));
}
