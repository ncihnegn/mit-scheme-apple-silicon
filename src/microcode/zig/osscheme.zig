// Derived from MIT/GNU Scheme C sources (`src/microcode/osscheme.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

pub export fn error_out_of_channels() callconv(.c) noreturn {
    abi.signal_error_from_primitive(abi.err_out_of_file_handles);
}

pub export fn error_out_of_processes() callconv(.c) noreturn {
    abi.signal_error_from_primitive(abi.err_out_of_file_handles);
}

pub export fn error_unimplemented_primitive() callconv(.c) noreturn {
    abi.signal_error_from_primitive(abi.err_undefined_primitive);
}

pub export fn error_floating_point_exception() callconv(.c) noreturn {
    abi.signal_error_from_primitive(abi.err_floating_overflow);
}

pub export fn error_process_terminated() callconv(.c) noreturn {
    abi.signal_error_from_primitive(abi.err_process_terminated);
}

pub export fn executing_scheme_primitive_p() callconv(.c) c_int {
    return @intFromBool(obj.primitiveP(abi.Registers[abi.regblock_primitive]));
}

pub export fn request_console_resize_interrupt() callconv(.c) void {
    abi.requestInterrupt(abi.int_global_3);
}

pub export fn request_character_interrupt() callconv(.c) void {
    abi.requestInterrupt(abi.int_character);
}

pub export fn request_timer_interrupt() callconv(.c) void {
    abi.requestInterrupt(abi.int_timer);
}

pub export fn request_suspend_interrupt() callconv(.c) void {
    abi.requestInterrupt(abi.int_suspend);
}

pub export fn pending_interrupts_p() callconv(.c) c_int {
    return @intFromBool(abi.interruptPendingP(abi.int_mask));
}

pub export fn deliver_pending_interrupts() callconv(.c) void {
    if (abi.interruptPendingP(abi.int_mask)) {
        abi.signal_interrupt_from_primitive();
    }
}

pub export fn get_interrupt_mask() callconv(.c) usize {
    return abi.Registers[abi.regblock_int_mask];
}

pub export fn set_interrupt_mask(mask: usize) callconv(.c) void {
    abi.setInterruptMask(mask & abi.int_mask);
}

pub export fn debug_back_trace(stream: abi.OutfChannel) callconv(.c) void {
    abi.outf(stream, "*** Scheme Microcode Back Trace: ***\n");
    abi.debug_stack_trace(stream);
    abi.outf(stream, "*** End of Back Trace ***\n");
    abi.outf_flush(stream);
}

pub export fn debug_examine_memory(address: isize, label: [*:0]const u8) callconv(.c) void {
    const ptr: *const obj.SchemeObject = @ptrFromInt(@as(usize, @bitCast(address)));
    abi.debug_print_expr(ptr.*, label);
}

test "osscheme interrupt mask, request flags, pending check, and primitive status" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    try std.testing.expectEqual(@as(c_int, 0), executing_scheme_primitive_p());
    abi.Registers[abi.regblock_primitive] = obj.makePrimitiveObject(0);
    try std.testing.expectEqual(@as(c_int, 1), executing_scheme_primitive_p());

    set_interrupt_mask(abi.int_timer | (@as(usize, 1) << 20));
    try std.testing.expectEqual(abi.int_timer, get_interrupt_mask());
    try std.testing.expectEqual(@as(c_int, 0), pending_interrupts_p());

    request_character_interrupt();
    try std.testing.expectEqual(@as(c_int, 0), pending_interrupts_p());
    request_timer_interrupt();
    try std.testing.expectEqual(@as(c_int, 1), pending_interrupts_p());
}
