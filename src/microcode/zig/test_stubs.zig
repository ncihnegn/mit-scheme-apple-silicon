const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const utils = @import("utils.zig");

pub var signal_block_depth: i32 = 0;
pub var fatal_count: usize = 0;
pub var last_closed_channel: ?c_uint = null;
pub var printed_continuation_count: usize = 0;
pub var mock_trap_state: c_int = 4;
pub var mock_under_emacs: c_int = 0;

fn mockDummyPrim() callconv(.c) obj.SchemeObject {
    return obj.unspecific;
}

var mock_heap: [8192]obj.SchemeObject = @splat(0);
var mock_stack: [128]obj.SchemeObject = @splat(0);
var mock_const: [64]obj.SchemeObject = @splat(0);

var mock_Registers: [14]obj.SchemeObject = @splat(0);

comptime {
    if (@import("build_options").cc_support) {
        @export(&mock_Registers, .{ .name = "Registers" });
    }
}

pub export var OS_Name: [*:0]const u8 = "unix";
pub export var OS_Variant: [*:0]const u8 = "macOS";
pub export var compiler_processor_type: c_uint = abi.compiler_aarch64_type;
pub export var scheme_program_name: [*:0]const u8 = "mit-scheme-unit";
pub export var critical_section_name: ?[*:0]const u8 = null;
pub export var current_gc_table: ?*anyopaque = null;
pub export var compiler_utilities: obj.SchemeObject = obj.sharp_f;
pub var mock_tospace_ptr: ?[*]obj.SchemeObject = null;
pub var mock_gc_pt1_calls: usize = 0;
pub var mock_gc_pt2_calls: usize = 0;
pub var mock_resize_tospace_arg: c_ulong = 0;
pub var mock_lookup_result: c_long = abi.prim_done;
pub var mock_lookup_value: obj.SchemeObject = obj.sharp_f;
pub var mock_define_calls: usize = 0;
pub var mock_link_calls: usize = 0;
pub var mock_apply_compiled_calls: usize = 0;
pub var mock_last_compiled_nargs: c_ulong = 0;
pub var mock_last_compiled_proc: obj.SchemeObject = obj.sharp_f;
pub var mock_stack_marker_calls: usize = 0;
pub var mock_last_marker_thunk: obj.SchemeObject = obj.sharp_f;
pub var mock_int_mask_calls: usize = 0;
pub var mock_last_compiled_mask: c_ulong = 0;
pub var mock_last_compiled_new_mask: c_ulong = 0;
pub export var ERROR_OUTPUT: abi.OutfChannel = .{ .type = 1, .cookie = null };
pub export var FATAL_OUTPUT: abi.OutfChannel = .{ .type = 2, .cookie = null };
pub var mock_cc_entry_bad: bool = false;
pub var mock_cc_entry_type: abi.CcEntryType = .{
    .marker = .procedure,
    .args = .{ .for_procedure = .{ .n_required = 0, .n_optional = 0, .rest_p = false } },
};
pub export var MAX_STATIC_PRIMITIVE: c_long = 1;
pub export var Static_Primitive_Procedure_Table = [_]abi.PrimitiveProcedure{ &mockDummyPrim, &mockDummyPrim };
pub export var Static_Primitive_Arity_Table = [_]c_int{ 1, 2 };
pub export var Static_Primitive_Count_Table = [_]c_int{ @sizeOf(obj.SchemeObject), 2 * @sizeOf(obj.SchemeObject) };
pub export var Static_Primitive_Name_Table = [_]?[*:0]const u8{ "CAR", "CDR" };
pub export var Static_Primitive_Documentation_Table = [_]?[*:0]const u8{ "Returns car", null };

pub fn resetMockRuntime() void {
    signal_block_depth = 0;
    fatal_count = 0;
    last_closed_channel = null;
    printed_continuation_count = 0;
    mock_trap_state = 4;
    mock_under_emacs = 0;
    compiler_processor_type = abi.compiler_aarch64_type;
    critical_section_name = null;
    current_gc_table = null;
    compiler_utilities = obj.sharp_f;
    mock_tospace_ptr = null;
    mock_gc_pt1_calls = 0;
    mock_gc_pt2_calls = 0;
    mock_resize_tospace_arg = 0;
    mock_lookup_result = abi.prim_done;
    mock_lookup_value = obj.sharp_f;
    mock_define_calls = 0;
    mock_link_calls = 0;
    utils.history_register = null;
    utils.prev_restore_history_offset = 0;
    utils.death_blow = 0;
    mock_cc_entry_bad = false;
    mock_cc_entry_type = .{
        .marker = .procedure,
        .args = .{ .for_procedure = .{ .n_required = 0, .n_optional = 0, .rest_p = false } },
    };
    mock_apply_compiled_calls = 0;
    mock_last_compiled_nargs = 0;
    mock_last_compiled_proc = obj.sharp_f;
    mock_stack_marker_calls = 0;
    mock_last_marker_thunk = obj.sharp_f;
    mock_int_mask_calls = 0;
    mock_last_compiled_mask = 0;
    mock_last_compiled_new_mask = 0;
    mock_return_to_interpreter = obj.makeObject(obj.tc_compiled_return, 1);
    mock_reflect_to_interface = obj.makeObject(obj.tc_compiled_return, 2);
    mock_heap = @splat(0);
    mock_stack = @splat(0);
    mock_const = @splat(0);
    abi.Registers = @splat(0);
    abi.heap_start = (&mock_heap).ptr;
    abi.heap_end = (&mock_heap).ptr + mock_heap.len;
    abi.heap_alloc_limit = (&mock_heap).ptr + mock_heap.len - 16;
    abi.Free = abi.heap_start;
    abi.Free_primitive = abi.heap_start;
    abi.memory_block_start = abi.heap_start;
    abi.stack_start = (&mock_stack).ptr;
    abi.stack_end = (&mock_stack).ptr + mock_stack.len;
    abi.stack_start[0] = obj.makeBrokenHeart(abi.stack_start);
    abi.stack_guard = abi.stack_start + 8;
    abi.stack_pointer = abi.stack_end;
    abi.constant_start = (&mock_const).ptr;
    abi.constant_alloc_next = (&mock_const).ptr;
    abi.constant_end = (&mock_const).ptr + mock_const.len;
    abi.fixed_objects = obj.sharp_f;
    abi.gc_space_needed = 0;
    abi.trapping = false;
}

pub fn setArgs(args: []const obj.SchemeObject) void {
    std.debug.assert(args.len <= mock_stack.len);
    abi.stack_pointer = abi.stack_end - args.len;
    for (args, 0..) |arg, idx| {
        abi.stack_pointer[idx] = arg;
    }
    abi.Registers[abi.regblock_lexpr_actuals] = @intCast(args.len);
}

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

pub export fn outf_error(_: [*:0]const u8, ...) callconv(.c) void {}

pub export fn outf_flush_fatal() callconv(.c) void {}

pub export fn OS_channel_close_noerror(ch: c_uint) callconv(.c) void {
    last_closed_channel = ch;
}

comptime {
    if (@import("build_options").debugging) {
        @export(&mockPrintOneContinuationFrame, .{ .name = "Print_One_Continuation_Frame" });
    }
}

fn mockPrintOneContinuationFrame(_: obj.SchemeObject) callconv(.c) bool {
    printed_continuation_count += 1;
    return true;
}

pub export fn Microcode_Termination(_: c_int) callconv(.c) noreturn {
    @panic("mock Microcode_Termination");
}

pub export fn termination_no_error_handler() callconv(.c) noreturn {
    @panic("mock termination_no_error_handler");
}

pub export fn OS_error_code_to_syserr(code: c_int) callconv(.c) c_int {
    return code;
}

pub export fn guarantee_interp_return() callconv(.c) void {}

comptime {
    if (@import("build_options").cc_support) {
        @export(&mockReadCcEntryType, .{ .name = "read_cc_entry_type" });
    }
}

fn mockReadCcEntryType(cet: *abi.CcEntryType, _: ?*anyopaque) callconv(.c) bool {
    if (mock_cc_entry_bad) return true;
    cet.* = mock_cc_entry_type;
    return false;
}

pub export fn gc_type_code(tc: c_uint) callconv(.c) c_int {
    return switch (@as(c_ulong, tc)) {
        obj.tc_pair, obj.tc_weak_cons, obj.tc_tagged_object, obj.tc_interned_symbol, obj.tc_uninterned_symbol => @intFromEnum(abi.GcType.pair),
        obj.tc_hunk3_a, obj.tc_hunk3_b => @intFromEnum(abi.GcType.triple),
        obj.tc_vector,
        obj.tc_record,
        obj.tc_big_fixnum,
        obj.tc_bytevector,
        obj.tc_big_flonum,
        obj.tc_non_marked_vector,
        obj.tc_vector_1b,
        obj.tc_unicode_string,
        obj.tc_character_string,
        => @intFromEnum(abi.GcType.vector),
        obj.tc_false,
        obj.tc_constant,
        obj.tc_fixnum,
        obj.tc_character,
        obj.tc_primitive,
        obj.tc_return_code,
        => @intFromEnum(abi.GcType.non_pointer),
        obj.tc_cell => @intFromEnum(abi.GcType.cell),
        obj.tc_reference_trap => @intFromEnum(abi.GcType.special),
        else => @intFromEnum(abi.GcType.undefined),
    };
}

pub export fn gc_ptr_type(o: obj.SchemeObject) callconv(.c) c_int {
    if (obj.objectType(o) == obj.tc_compiled_return) return @intFromEnum(abi.GcPtrType.compiled_return);
    const gt = gc_type_code(@intCast(obj.objectType(o)));
    if (gt > 0 or gt == @intFromEnum(abi.GcType.vector)) return @intFromEnum(abi.GcPtrType.normal);
    return @intFromEnum(abi.GcPtrType.not);
}

pub export fn get_object_address(o: obj.SchemeObject) callconv(.c) ?[*]obj.SchemeObject {
    return if (gc_ptr_type(o) == @intFromEnum(abi.GcPtrType.normal)) obj.objectAddress(o) else null;
}

pub export fn OS_tty_map_interrupt_char(c: u8) callconv(.c) u8 {
    return c;
}

pub export fn outf(_: abi.OutfChannel, _: [*:0]const u8, ...) callconv(.c) void {}

pub export fn outf_flush(_: abi.OutfChannel) callconv(.c) void {}

pub export fn debug_stack_trace(_: abi.OutfChannel) callconv(.c) void {}

pub export fn debug_print_expr(_: obj.SchemeObject, _: [*:0]const u8) callconv(.c) void {}

pub export fn OS_get_entropy(buf: *[32]u8) callconv(.c) void {
    for (buf, 0..) |*slot, idx| {
        slot.* = @intCast(idx + 0xA0);
    }
}

pub export fn abort_to_interpreter(_: c_long) callconv(.c) noreturn {
    @panic("mock abort_to_interpreter");
}

pub export fn stack_death(_: [*:0]const u8) callconv(.c) noreturn {
    @panic("mock stack_death");
}

pub export fn termination_init_error() callconv(.c) noreturn {
    @panic("mock termination_init_error");
}

pub export fn termination_normal(_: c_int) callconv(.c) noreturn {
    @panic("mock termination_normal");
}

pub export fn OS_restartable_exit() callconv(.c) void {}

pub export fn OS_under_emacs_p() callconv(.c) c_int {
    return mock_under_emacs;
}

pub export fn OS_set_trap_state(state: c_int) callconv(.c) c_int {
    const old = mock_trap_state;
    mock_trap_state = state;
    return old;
}

pub export fn cc_block_linkage_info(block: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return block;
}

var mock_return_to_interpreter: obj.SchemeObject = obj.makeObject(obj.tc_compiled_return, 1);
var mock_reflect_to_interface: obj.SchemeObject = obj.makeObject(obj.tc_compiled_return, 2);

comptime {
    if (@import("build_options").cc_support) {
        @export(&mock_return_to_interpreter, .{ .name = "return_to_interpreter" });
        @export(&mock_reflect_to_interface, .{ .name = "reflect_to_interface" });
        @export(&mockCcReturnAddressP, .{ .name = "cc_return_address_p" });
        @export(&mockReflectToInterfaceFrameType, .{ .name = "reflect_to_interface_frame_type" });
        @export(&mockCpointCompiledCodeNext, .{ .name = "cpoint_compiled_code_next" });
        @export(&mockCpointCompiledAddressNext, .{ .name = "cpoint_compiled_address_next" });
        @export(&mockCpointReflectToInterfaceNext, .{ .name = "cpoint_reflect_to_interface_next" });
    }
}

fn mockCcReturnAddressP(o: obj.SchemeObject) callconv(.c) bool {
    return obj.ccReturnP(o) or obj.ccEntryP(o);
}

fn mockReflectToInterfaceFrameType(frame: [*]obj.SchemeObject) callconv(.c) c_int {
    if (!obj.fixnumP(frame[1]) or !obj.fixnumToUlongP(frame[1])) {
        return @intFromEnum(abi.ReturnFrameType.undefined);
    }
    return switch (obj.fixnumToUlong(frame[1])) {
        0 => @intFromEnum(abi.ReturnFrameType.cc_internal_apply),
        1 => @intFromEnum(abi.ReturnFrameType.cc_restore_interrupt_mask),
        2 => @intFromEnum(abi.ReturnFrameType.cc_stack_marker),
        3 => @intFromEnum(abi.ReturnFrameType.cc_bkpt),
        8 => @intFromEnum(abi.ReturnFrameType.cc_invocation),
        else => @intFromEnum(abi.ReturnFrameType.undefined),
    };
}

fn mockCpointCompiledCodeNext(_: obj.SchemeObject, idx: c_ulong) callconv(.c) c_ulong {
    return idx + 3;
}

fn mockCpointCompiledAddressNext(_: obj.SchemeObject, idx: c_ulong) callconv(.c) c_ulong {
    return idx + 4;
}

fn mockCpointReflectToInterfaceNext(_: obj.SchemeObject, idx: c_ulong) callconv(.c) c_ulong {
    return idx + 5;
}

comptime {
    if (@import("build_options").cc_support) {
        @export(&mockMakeReflectCodeTable, .{ .name = "make_reflect_code_table" });
    }
}

fn mockMakeReflectCodeTable() callconv(.c) obj.SchemeObject {
    return abi.make_vector(4, obj.sharp_f, true);
}

var mock_syscall_names_arr = [_]?[*:0]const u8{ "open", null, "read" };
var mock_syserr_names_arr = [_]?[*:0]const u8{ "EPERM", "ENOENT" };

pub export fn OS_tty_x_size() callconv(.c) c_uint {
    return 80;
}

pub export fn OS_tty_y_size() callconv(.c) c_uint {
    return 24;
}

pub export fn OS_syscall_names(len_out: *c_ulong, names_out: *[*]?[*:0]const u8) callconv(.c) void {
    len_out.* = mock_syscall_names_arr.len;
    names_out.* = &mock_syscall_names_arr;
}

pub export fn OS_syserr_names(len_out: *c_ulong, names_out: *[*]?[*:0]const u8) callconv(.c) void {
    len_out.* = mock_syserr_names_arr.len;
    names_out.* = &mock_syserr_names_arr;
}

var mock_std_gc_table_sentinel: u8 = 0;

comptime {
    if (@import("build_options").cc_support) {
        @export(&mockApplyCompiledFromPrimitive, .{ .name = "apply_compiled_from_primitive" });
        @export(&mockCompiledWithStackMarker, .{ .name = "compiled_with_stack_marker" });
        @export(&mockCompiledWithInterruptMask, .{ .name = "compiled_with_interrupt_mask" });
    }
}

fn mockApplyCompiledFromPrimitive(nargs: c_ulong, proc: obj.SchemeObject) callconv(.c) void {
    mock_apply_compiled_calls += 1;
    mock_last_compiled_nargs = nargs;
    mock_last_compiled_proc = proc;
}

fn mockCompiledWithStackMarker(thunk: obj.SchemeObject) callconv(.c) void {
    mock_stack_marker_calls += 1;
    mock_last_marker_thunk = thunk;
}

fn mockCompiledWithInterruptMask(old_mask: c_ulong, _: obj.SchemeObject, new_mask: c_ulong) callconv(.c) void {
    mock_int_mask_calls += 1;
    mock_last_compiled_mask = old_mask;
    mock_last_compiled_new_mask = new_mask;
}

pub export fn open_tospace(start: [*]obj.SchemeObject) callconv(.c) void {
    mock_tospace_ptr = start;
}

pub export fn initialize_weak_chain() callconv(.c) void {}

pub export fn get_newspace_ptr() callconv(.c) [*]obj.SchemeObject {
    return mock_tospace_ptr.?;
}

pub export fn add_to_tospace(o: obj.SchemeObject) callconv(.c) void {
    mock_tospace_ptr.?[0] = o;
    mock_tospace_ptr = mock_tospace_ptr.? + 1;
}

pub export fn std_gc_table() callconv(.c) ?*anyopaque {
    return &mock_std_gc_table_sentinel;
}

pub export fn gc_scan_tospace(_: [*]obj.SchemeObject, _: ?[*]obj.SchemeObject) callconv(.c) void {}

pub export fn increment_tospace_ptr(n: c_ulong) callconv(.c) void {
    mock_tospace_ptr = mock_tospace_ptr.? + @as(usize, @intCast(n));
}

pub export fn std_gc_pt1() callconv(.c) void {
    mock_gc_pt1_calls += 1;
}

pub export fn std_gc_pt2() callconv(.c) void {
    mock_gc_pt2_calls += 1;
}

pub export fn resize_tospace(size: c_ulong) callconv(.c) void {
    mock_resize_tospace_arg = size;
}

pub export fn lookup_variable(_: obj.SchemeObject, _: obj.SchemeObject, val_out: *obj.SchemeObject) callconv(.c) c_long {
    val_out.* = mock_lookup_value;
    return mock_lookup_result;
}

pub export fn assign_variable(_: obj.SchemeObject, _: obj.SchemeObject, new_val: obj.SchemeObject, val_out: *obj.SchemeObject) callconv(.c) c_long {
    val_out.* = mock_lookup_value;
    mock_lookup_value = new_val;
    return mock_lookup_result;
}

pub export fn define_variable(_: obj.SchemeObject, _: obj.SchemeObject, new_val: obj.SchemeObject) callconv(.c) c_long {
    mock_define_calls += 1;
    mock_lookup_value = new_val;
    return mock_lookup_result;
}

pub export fn variable_unassigned_p(_: obj.SchemeObject, _: obj.SchemeObject, val_out: *obj.SchemeObject) callconv(.c) c_long {
    val_out.* = mock_lookup_value;
    return mock_lookup_result;
}

pub export fn variable_unbound_p(_: obj.SchemeObject, _: obj.SchemeObject, val_out: *obj.SchemeObject) callconv(.c) c_long {
    val_out.* = mock_lookup_value;
    return mock_lookup_result;
}

pub export fn variable_unreferenceable_p(_: obj.SchemeObject, _: obj.SchemeObject, val_out: *obj.SchemeObject) callconv(.c) c_long {
    val_out.* = mock_lookup_value;
    return mock_lookup_result;
}

pub export fn link_variables(_: obj.SchemeObject, _: obj.SchemeObject, _: obj.SchemeObject, _: obj.SchemeObject) callconv(.c) c_long {
    mock_link_calls += 1;
    return mock_lookup_result;
}

pub export fn unbind_variable(_: obj.SchemeObject, _: obj.SchemeObject, val_out: *obj.SchemeObject) callconv(.c) c_long {
    val_out.* = mock_lookup_value;
    return mock_lookup_result;
}
