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

pub export fn error_unimplemented_primitive() callconv(.c) noreturn {
    @panic("mock error_unimplemented_primitive");
}

fn allocMockBignum(val: i128) obj.SchemeObject {
    abi.primitiveGcIfNeeded(3);
    const ptr = Free;
    const raw: u128 = @bitCast(val);
    ptr[0] = obj.makeNmvHeader(2);
    ptr[1] = @truncate(raw);
    ptr[2] = @truncate(raw >> 64);
    Free += 3;
    return obj.makePointerObject(obj.tc_big_fixnum, ptr);
}

fn readMockBignum(b: obj.SchemeObject) i128 {
    std.debug.assert(obj.bignumP(b));
    const lo: u128 = obj.memoryRef(b, 1);
    const hi: u128 = obj.memoryRef(b, 2);
    return @bitCast((hi << 64) | lo);
}

pub export fn bignum_equal_p(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) c_int {
    return @intFromBool(readMockBignum(x) == readMockBignum(y));
}

pub export fn bignum_test(x: obj.SchemeObject) callconv(.c) c_int {
    const v = readMockBignum(x);
    if (v == 0) return @intFromEnum(abi.BignumComparison.equal);
    return if (v < 0) @intFromEnum(abi.BignumComparison.less) else @intFromEnum(abi.BignumComparison.greater);
}

pub export fn bignum_compare(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) c_int {
    const vx = readMockBignum(x);
    const vy = readMockBignum(y);
    if (vx == vy) return @intFromEnum(abi.BignumComparison.equal);
    return if (vx < vy) @intFromEnum(abi.BignumComparison.less) else @intFromEnum(abi.BignumComparison.greater);
}

pub export fn bignum_add(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) + readMockBignum(y));
}

pub export fn bignum_subtract(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) - readMockBignum(y));
}

pub export fn bignum_negate(x: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(-readMockBignum(x));
}

pub export fn bignum_multiply(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) * readMockBignum(y));
}

pub export fn bignum_divide(
    n: obj.SchemeObject,
    d: obj.SchemeObject,
    q: *obj.SchemeObject,
    r: *obj.SchemeObject,
) callconv(.c) c_int {
    const vn = readMockBignum(n);
    const vd = readMockBignum(d);
    if (vd == 0) return 1;
    q.* = allocMockBignum(@divTrunc(vn, vd));
    r.* = allocMockBignum(@rem(vn, vd));
    return 0;
}

pub export fn bignum_quotient(n: obj.SchemeObject, d: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const vd = readMockBignum(d);
    if (vd == 0) return obj.sharp_f;
    return allocMockBignum(@divTrunc(readMockBignum(n), vd));
}

pub export fn bignum_remainder(n: obj.SchemeObject, d: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const vd = readMockBignum(d);
    if (vd == 0) return obj.sharp_f;
    return allocMockBignum(@rem(readMockBignum(n), vd));
}

pub export fn long_to_bignum(n: c_long) callconv(.c) obj.SchemeObject {
    return allocMockBignum(n);
}

pub export fn ulong_to_bignum(n: c_ulong) callconv(.c) obj.SchemeObject {
    return allocMockBignum(n);
}

pub export fn intmax_to_bignum(n: i64) callconv(.c) obj.SchemeObject {
    return allocMockBignum(n);
}

pub export fn uintmax_to_bignum(n: u64) callconv(.c) obj.SchemeObject {
    return allocMockBignum(n);
}

pub export fn double_to_bignum(x: f64) callconv(.c) obj.SchemeObject {
    return allocMockBignum(@intFromFloat(x));
}

pub export fn bignum_to_long(b: obj.SchemeObject) callconv(.c) c_long {
    return @intCast(readMockBignum(b));
}

pub export fn bignum_to_ulong(b: obj.SchemeObject) callconv(.c) c_ulong {
    return @intCast(readMockBignum(b));
}

pub export fn bignum_to_intmax(b: obj.SchemeObject) callconv(.c) i64 {
    return @intCast(readMockBignum(b));
}

pub export fn bignum_to_uintmax(b: obj.SchemeObject) callconv(.c) u64 {
    return @intCast(readMockBignum(b));
}

pub export fn bignum_to_double(b: obj.SchemeObject) callconv(.c) f64 {
    return @floatFromInt(readMockBignum(b));
}

pub export fn bignum_fits_in_word_p(b: obj.SchemeObject, word_length: c_long, twos_complement_p: c_int) callconv(.c) c_int {
    const v = readMockBignum(b);
    if (twos_complement_p != 0) {
        if (word_length >= 127) return 1;
        const mag_bits: u7 = @intCast(word_length - 1);
        const limit: i128 = @as(i128, 1) << mag_bits;
        return @intFromBool(v >= -limit and v < limit);
    } else {
        if (v < 0) return 0;
        if (word_length >= 127) return 1;
        const limit: i128 = @as(i128, 1) << @as(u7, @intCast(word_length));
        return @intFromBool(v < limit);
    }
}

pub export fn bignum_length_in_bits(b: obj.SchemeObject) callconv(.c) c_ulong {
    const v = readMockBignum(b);
    const mag: u128 = if (v < 0) @intCast(-v) else @intCast(v);
    return if (mag == 0) 0 else 128 - @clz(mag);
}

pub export fn bignum_integer_length(b: obj.SchemeObject) callconv(.c) c_ulong {
    const v = readMockBignum(b);
    const u: u128 = if (v < 0) @intCast(~v) else @intCast(v);
    return if (u == 0) 0 else 128 - @clz(u);
}

pub export fn bignum_first_set_bit(b: obj.SchemeObject) callconv(.c) c_long {
    const v = readMockBignum(b);
    if (v == 0) return -1;
    const u: u128 = @bitCast(v);
    return @intCast(@ctz(u));
}

pub export fn bignum_bit_count(b: obj.SchemeObject) callconv(.c) c_ulong {
    const v = readMockBignum(b);
    const u: u128 = if (v < 0) @intCast(~v) else @intCast(v);
    return @popCount(u);
}

pub export fn bignum_hamming_distance(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) c_long {
    const vx = readMockBignum(x);
    const vy = readMockBignum(y);
    if ((vx < 0) != (vy < 0)) return -1;
    const ux: u128 = @bitCast(vx);
    const uy: u128 = @bitCast(vy);
    return @intCast(@popCount(ux ^ uy));
}

pub export fn bignum_bitwise_not(b: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(~readMockBignum(b));
}

pub export fn bignum_bitwise_and(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) & readMockBignum(y));
}

pub export fn bignum_bitwise_andc2(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) & ~readMockBignum(y));
}

pub export fn bignum_bitwise_andc1(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(y) & ~readMockBignum(x));
}

pub export fn bignum_bitwise_xor(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) ^ readMockBignum(y));
}

pub export fn bignum_bitwise_ior(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) | readMockBignum(y));
}

pub export fn bignum_bitwise_nor(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(~(readMockBignum(x) | readMockBignum(y)));
}

pub export fn bignum_bitwise_eqv(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(~(readMockBignum(x) ^ readMockBignum(y)));
}

pub export fn bignum_bitwise_orc2(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(x) | ~readMockBignum(y));
}

pub export fn bignum_bitwise_orc1(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(y) | ~readMockBignum(x));
}

pub export fn bignum_bitwise_nand(x: obj.SchemeObject, y: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return allocMockBignum(~(readMockBignum(x) & readMockBignum(y)));
}

pub export fn bignum_nonnegative_one_bits(n: c_ulong, m: c_ulong) callconv(.c) obj.SchemeObject {
    if (n == 0) return allocMockBignum(0);
    const val: i128 = ((@as(i128, 1) << @intCast(n)) - 1) << @intCast(m);
    return allocMockBignum(val);
}

pub export fn bignum_negative_zero_bits(n: c_ulong, m: c_ulong) callconv(.c) obj.SchemeObject {
    if (n == 0) return allocMockBignum(-1);
    const val: i128 = ~(((@as(i128, 1) << @intCast(n)) - 1) << @intCast(m));
    return allocMockBignum(val);
}

pub export fn bignum_shift_right(b: obj.SchemeObject, m: c_ulong) callconv(.c) obj.SchemeObject {
    const v = readMockBignum(b);
    if (m >= 127) return allocMockBignum(if (v < 0) -1 else 0);
    return allocMockBignum(v >> @intCast(m));
}

pub export fn bignum_shift_left(b: obj.SchemeObject, m: c_ulong) callconv(.c) obj.SchemeObject {
    return allocMockBignum(readMockBignum(b) << @intCast(m));
}

pub export fn unsigned_long_to_shifted_bignum(n: c_ulong, m: c_ulong, negative_p: c_int) callconv(.c) obj.SchemeObject {
    const val: i128 = @as(i128, n) << @intCast(m);
    return allocMockBignum(if (negative_p != 0) -val else val);
}

pub export fn digit_stream_to_bignum(
    n_digits: c_uint,
    producer: *const fn (?*anyopaque) callconv(.c) c_uint,
    context: ?*anyopaque,
    radix: c_uint,
    negative_p: c_int,
) callconv(.c) obj.SchemeObject {
    var acc: i128 = 0;
    var i: c_uint = 0;
    while (i < n_digits) : (i += 1) {
        acc = acc * @as(i128, radix) + @as(i128, producer(context));
    }
    return allocMockBignum(if (negative_p != 0) -acc else acc);
}

pub export fn bignum_to_digit_stream(
    b: obj.SchemeObject,
    radix: c_uint,
    consumer: *const fn (?*anyopaque, c_long) callconv(.c) void,
    context: ?*anyopaque,
) callconv(.c) void {
    const v = readMockBignum(b);
    var mag: i128 = if (v < 0) -v else v;
    while (mag > 0) {
        const d: c_long = @intCast(@rem(mag, @as(i128, radix)));
        consumer(context, d);
        mag = @divTrunc(mag, @as(i128, radix));
    }
}

pub export fn bignum_max_digit_stream_radix() callconv(.c) c_long {
    return 1 << 30;
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
