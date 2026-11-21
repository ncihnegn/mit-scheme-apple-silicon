const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

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

pub export var Registers: [14]obj.SchemeObject = @splat(0);
pub export var Free: [*]obj.SchemeObject = (&mock_heap).ptr;
pub export var Free_primitive: ?[*]obj.SchemeObject = (&mock_heap).ptr;
pub export var heap_alloc_limit: [*]obj.SchemeObject = (&mock_heap).ptr + mock_heap.len - 16;
pub export var heap_start: [*]obj.SchemeObject = (&mock_heap).ptr;
pub export var heap_end: [*]obj.SchemeObject = (&mock_heap).ptr + mock_heap.len;
pub export var stack_pointer: [*]obj.SchemeObject = (&mock_stack).ptr + mock_stack.len;
pub export var stack_guard: [*]obj.SchemeObject = (&mock_stack).ptr + 8;
pub export var stack_start: [*]obj.SchemeObject = (&mock_stack).ptr;
pub export var stack_end: [*]obj.SchemeObject = (&mock_stack).ptr + mock_stack.len;
pub export var constant_start: [*]obj.SchemeObject = (&mock_const).ptr;
pub export var constant_alloc_next: [*]obj.SchemeObject = (&mock_const).ptr;
pub export var constant_end: [*]obj.SchemeObject = (&mock_const).ptr + mock_const.len;
pub export var memory_block_start: [*]obj.SchemeObject = (&mock_heap).ptr;
pub export var fixed_objects: obj.SchemeObject = obj.sharp_f;
pub export var gc_space_needed: c_ulong = 0;
pub export var trapping: bool = false;
pub export var scheme_program_name: [*:0]const u8 = "mit-scheme-unit";
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
    mock_return_to_interpreter = obj.makeObject(obj.tc_compiled_return, 1);
    mock_reflect_to_interface = obj.makeObject(obj.tc_compiled_return, 2);
    mock_heap = @splat(0);
    mock_stack = @splat(0);
    mock_const = @splat(0);
    Registers = @splat(0);
    heap_start = (&mock_heap).ptr;
    heap_end = (&mock_heap).ptr + mock_heap.len;
    heap_alloc_limit = (&mock_heap).ptr + mock_heap.len - 16;
    Free = heap_start;
    Free_primitive = heap_start;
    memory_block_start = heap_start;
    stack_start = (&mock_stack).ptr;
    stack_end = (&mock_stack).ptr + mock_stack.len;
    stack_start[0] = obj.makeBrokenHeart(stack_start);
    stack_guard = stack_start + 8;
    stack_pointer = stack_end;
    constant_start = (&mock_const).ptr;
    constant_alloc_next = (&mock_const).ptr;
    constant_end = (&mock_const).ptr + mock_const.len;
    fixed_objects = obj.sharp_f;
    gc_space_needed = 0;
    trapping = false;
}

pub fn setArgs(args: []const obj.SchemeObject) void {
    std.debug.assert(args.len <= mock_stack.len);
    stack_pointer = stack_end - args.len;
    for (args, 0..) |arg, idx| {
        stack_pointer[idx] = arg;
    }
    Registers[abi.regblock_lexpr_actuals] = @intCast(args.len);
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

pub export fn error_wrong_type_arg(_: c_int) callconv(.c) noreturn {
    @panic("mock error_wrong_type_arg");
}

pub export fn error_bad_range_arg(_: c_int) callconv(.c) noreturn {
    @panic("mock error_bad_range_arg");
}

pub export fn error_external_return() callconv(.c) noreturn {
    @panic("mock error_external_return");
}

pub export fn signal_error_from_primitive(_: c_long) callconv(.c) noreturn {
    @panic("mock signal_error_from_primitive");
}

pub export fn signal_interrupt_from_primitive() callconv(.c) noreturn {
    @panic("mock signal_interrupt_from_primitive");
}

pub export fn Microcode_Termination(_: c_int) callconv(.c) noreturn {
    @panic("mock Microcode_Termination");
}

pub export fn record_primitive_entry(_: obj.SchemeObject) callconv(.c) void {}

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

pub export fn hashable_object_p(o: obj.SchemeObject) callconv(.c) bool {
    return obj.objectType(o) != obj.tc_reference_trap;
}

pub export fn hash_object(o: obj.SchemeObject) callconv(.c) u32 {
    return @truncate(o *% 2654435761);
}

pub export fn combine_hashes(h1: u32, h2: u32) callconv(.c) u32 {
    return (h1 *% 33) ^ h2;
}

pub export fn arg_integer(n: c_int) callconv(.c) c_long {
    const val = abi.argRef(@intCast(n));
    if (!obj.fixnumP(val)) error_wrong_type_arg(n);
    return obj.fixnumToLong(val);
}

pub export fn arg_nonnegative_integer(n: c_int) callconv(.c) c_long {
    const val = arg_integer(n);
    if (val < 0) error_bad_range_arg(n);
    return val;
}

pub export fn arg_index_integer(n: c_int, upper_limit: c_long) callconv(.c) c_long {
    const val = arg_nonnegative_integer(n);
    if (val >= upper_limit) error_bad_range_arg(n);
    return val;
}

pub export fn arg_ulong_integer(n: c_int) callconv(.c) c_ulong {
    const val = abi.argRef(@intCast(n));
    if (!obj.fixnumP(val)) error_wrong_type_arg(n);
    if (!obj.fixnumToUlongP(val)) error_bad_range_arg(n);
    return obj.fixnumToUlong(val);
}

pub export fn arg_ulong_index_integer(n: c_int, upper_limit: c_ulong) callconv(.c) c_ulong {
    const val = arg_ulong_integer(n);
    if (val >= upper_limit) error_bad_range_arg(n);
    return val;
}

pub export fn memory_hash(length: c_ulong, vp: ?*const anyopaque) callconv(.c) u32 {
    var result: u32 = 2166136261;
    if (length == 0) return result;
    const bytes: [*]const u8 = @ptrCast(vp.?);
    var i: usize = 0;
    while (i < @as(usize, @intCast(length))) : (i += 1) {
        result ^= @as(u32, bytes[i]);
        result *%= 16777619;
    }
    return result;
}

pub export fn arg_integer_in_range(n: c_int, lower_limit: c_long, upper_limit: c_long) callconv(.c) c_long {
    const val = abi.argRef(@intCast(n));
    if (!obj.fixnumP(val)) error_wrong_type_arg(n);
    const num = obj.fixnumToLong(val);
    if (num < lower_limit or num >= upper_limit) error_bad_range_arg(n);
    return num;
}

pub export fn arg_index_integer_to_intmax(n: c_int, upper_limit: i64) callconv(.c) i64 {
    const val = abi.argRef(@intCast(n));
    if (!obj.fixnumP(val)) error_wrong_type_arg(n);
    const num: i64 = @intCast(obj.fixnumToLong(val));
    if (num < 0 or num >= upper_limit) error_bad_range_arg(n);
    return num;
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

pub export fn canonicalize_primitive_context() callconv(.c) void {}

pub export fn abort_to_interpreter(_: c_long) callconv(.c) noreturn {
    @panic("mock abort_to_interpreter");
}

pub export fn stack_death(_: [*:0]const u8) callconv(.c) noreturn {
    @panic("mock stack_death");
}

pub export fn termination_init_error() callconv(.c) noreturn {
    @panic("mock termination_init_error");
}

pub export fn error_in_system_call(_: c_int, _: c_int) callconv(.c) noreturn {
    @panic("mock error_in_system_call");
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
