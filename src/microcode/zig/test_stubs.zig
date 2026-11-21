const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

pub var signal_block_depth: i32 = 0;
pub var fatal_count: usize = 0;

var mock_heap: [8192]obj.SchemeObject = @splat(0);
var mock_stack: [128]obj.SchemeObject = @splat(0);

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
pub export var memory_block_start: [*]obj.SchemeObject = (&mock_heap).ptr;
pub export var fixed_objects: obj.SchemeObject = obj.sharp_f;
pub export var gc_space_needed: c_ulong = 0;

pub fn resetMockRuntime() void {
    mock_heap = @splat(0);
    mock_stack = @splat(0);
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
    fixed_objects = obj.sharp_f;
    gc_space_needed = 0;
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
        obj.tc_pair, obj.tc_weak_cons, obj.tc_tagged_object => @intFromEnum(abi.GcType.pair),
        obj.tc_hunk3_a, obj.tc_hunk3_b => @intFromEnum(abi.GcType.triple),
        obj.tc_vector,
        obj.tc_record,
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
        => @intFromEnum(abi.GcType.non_pointer),
        else => @intFromEnum(abi.GcType.undefined),
    };
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

pub export fn arg_flonum(n: c_int) callconv(.c) f64 {
    const val = abi.argRef(@intCast(n));
    if (!obj.flonumP(val)) error_wrong_type_arg(n);
    const ptr: *const f64 = @ptrCast(@alignCast(obj.memoryLoc(val, 1)));
    return ptr.*;
}

pub export fn long_to_integer(n: c_long) callconv(.c) obj.SchemeObject {
    if (!obj.longToFixnumP(n)) @panic("mock long_to_integer overflow");
    return obj.longToFixnum(n);
}

pub export fn ulong_to_integer(n: c_ulong) callconv(.c) obj.SchemeObject {
    if (!obj.ulongToFixnumP(n)) @panic("mock ulong_to_integer overflow");
    return obj.ulongToFixnum(n);
}

pub export fn double_to_flonum(x: f64) callconv(.c) obj.SchemeObject {
    obj.alignFloat(&Free);
    abi.primitiveGcIfNeeded(obj.flonum_size + 1);
    const result = obj.makePointerObject(obj.tc_big_flonum, Free);
    Free[0] = obj.makeNmvHeader(obj.flonum_size);
    Free += 1;
    const fp: *f64 = @ptrCast(@alignCast(Free));
    fp.* = x;
    Free += @as(usize, @intCast(obj.flonum_size));
    return result;
}

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
