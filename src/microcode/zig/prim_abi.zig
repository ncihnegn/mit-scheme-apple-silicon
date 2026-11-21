// Derived from MIT/GNU Scheme C sources (`src/microcode/prims.h`, `src/microcode/prim.h`, `src/microcode/extern.h`, `src/microcode/intrpt.h`, `src/microcode/memmag.h`, `src/microcode/gc.h`, `src/microcode/const.h`, `src/microcode/errors.h`, `src/microcode/fixobj.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");

pub const regblock_memtop: usize = 0;
pub const regblock_int_mask: usize = 1;
pub const regblock_val: usize = 2;
pub const regblock_env: usize = 3;
pub const regblock_expr: usize = 5;
pub const regblock_return: usize = 6;
pub const regblock_lexpr_actuals: usize = 7;
pub const regblock_primitive: usize = 8;
pub const regblock_stack_guard: usize = 11;
pub const regblock_int_code: usize = 12;

pub const int_stack_overflow: c_ulong = 0x0001;
pub const int_gc: c_ulong = 0x0004;

pub const term_exit: c_int = 0x0C;
pub const err_wrong_number_of_arguments: c_long = 0x0C;
pub const prim_apply: c_long = -3;

pub const fixobj_obarray: usize = 0x03;
pub const fixobj_record_tag: usize = 0x11;
pub const fixobj_record_app_index: usize = 0x12;
pub const fixobj_proxied_record_types: usize = 0x15;

pub const fixobj_generic_trampoline_zero_p: usize = 0x24;
pub const fixobj_generic_trampoline_positive_p: usize = 0x25;
pub const fixobj_generic_trampoline_negative_p: usize = 0x26;
pub const fixobj_generic_trampoline_successor: usize = 0x27;
pub const fixobj_generic_trampoline_predecessor: usize = 0x28;
pub const fixobj_generic_trampoline_equal_p: usize = 0x29;
pub const fixobj_generic_trampoline_less_p: usize = 0x2A;
pub const fixobj_generic_trampoline_greater_p: usize = 0x2B;
pub const fixobj_generic_trampoline_add: usize = 0x2C;
pub const fixobj_generic_trampoline_subtract: usize = 0x2D;
pub const fixobj_generic_trampoline_multiply: usize = 0x2E;
pub const fixobj_generic_trampoline_divide: usize = 0x2F;
pub const fixobj_generic_trampoline_quotient: usize = 0x30;
pub const fixobj_generic_trampoline_remainder: usize = 0x31;
pub const fixobj_generic_trampoline_modulo: usize = 0x32;

pub const GcType = enum(c_int) {
    compiled_entry = -4,
    vector = -3,
    special = -2,
    undefined = -1,
    non_pointer = 0,
    cell = 1,
    pair = 2,
    triple = 3,
    quadruple = 4,
    compiled_return = 5,
};

pub extern var Registers: [14]obj.SchemeObject;
pub extern var Free: [*]obj.SchemeObject;
pub extern var Free_primitive: ?[*]obj.SchemeObject;
pub extern var heap_alloc_limit: [*]obj.SchemeObject;
pub extern var heap_start: [*]obj.SchemeObject;
pub extern var heap_end: [*]obj.SchemeObject;
pub extern var stack_pointer: [*]obj.SchemeObject;
pub extern var stack_guard: [*]obj.SchemeObject;
pub extern var stack_start: [*]obj.SchemeObject;
pub extern var stack_end: [*]obj.SchemeObject;
pub extern var memory_block_start: [*]obj.SchemeObject;
pub extern var fixed_objects: obj.SchemeObject;
pub extern var gc_space_needed: c_ulong;

pub extern "c" fn error_wrong_type_arg(c_int) noreturn;
pub extern "c" fn error_bad_range_arg(c_int) noreturn;
pub extern "c" fn error_external_return() noreturn;
pub extern "c" fn signal_error_from_primitive(c_long) noreturn;
pub extern "c" fn signal_interrupt_from_primitive() noreturn;
pub extern "c" fn Microcode_Termination(c_int) noreturn;
pub extern "c" fn outf_fatal([*:0]const u8, ...) void;
pub extern "c" fn record_primitive_entry(obj.SchemeObject) void;
pub extern "c" fn gc_type_code(c_uint) c_int;

pub extern "c" fn arg_integer(c_int) c_long;
pub extern "c" fn arg_nonnegative_integer(c_int) c_long;
pub extern "c" fn arg_index_integer(c_int, c_long) c_long;
pub extern "c" fn arg_ulong_integer(c_int) c_ulong;
pub extern "c" fn arg_ulong_index_integer(c_int, c_ulong) c_ulong;
pub extern "c" fn arg_flonum(c_int) f64;

pub extern "c" fn long_to_integer(c_long) obj.SchemeObject;
pub extern "c" fn ulong_to_integer(c_ulong) obj.SchemeObject;
pub extern "c" fn double_to_flonum(f64) obj.SchemeObject;

pub extern "c" fn allocate_non_marked_vector(c_uint, c_ulong, bool) obj.SchemeObject;
pub extern "c" fn allocate_marked_vector(c_uint, c_ulong, bool) obj.SchemeObject;
pub extern "c" fn allocate_vector(c_ulong, bool) obj.SchemeObject;
pub extern "c" fn make_vector(c_ulong, obj.SchemeObject, bool) obj.SchemeObject;

pub extern "c" fn arg_bytevector(c_int, *c_ulong) [*]u8;
pub extern "c" fn allocate_bytevector(c_ulong) obj.SchemeObject;
pub extern "c" fn memory_to_bytevector(c_ulong, ?*const anyopaque) obj.SchemeObject;
pub extern "c" fn OS_get_entropy(*[32]u8) void;

pub extern "c" fn canonicalize_primitive_context() void;
pub extern "c" fn abort_to_interpreter(c_long) noreturn;
pub extern "c" fn stack_death([*:0]const u8) noreturn;
pub extern "c" fn cons(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;

pub extern "c" fn arg_integer_in_range(c_int, c_long, c_long) c_long;
pub extern "c" fn arg_index_integer_to_intmax(c_int, i64) i64;
pub extern "c" fn error_unimplemented_primitive() noreturn;
pub extern "c" fn Mul(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn string_p(obj.SchemeObject) bool;
pub extern "c" fn allocate_string(c_ulong) obj.SchemeObject;
pub extern "c" fn system_pair_cons(c_long, obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn memory_hash(c_ulong, ?*const anyopaque) u32;
pub extern "c" fn arg_ascii_char(c_int) c_long;
pub extern "c" fn arg_ascii_integer(c_int) c_long;
pub extern "c" fn char_upcase(c_long) c_long;
pub extern "c" fn char_downcase(c_long) c_long;
pub extern "c" fn string_to_char_pointer(obj.SchemeObject, ?*c_ulong) [*]u8;
pub extern "c" fn arg_extended_string(c_uint, ?*c_ulong) [*]u8;

pub const BignumComparison = enum(c_int) {
    equal = 0,
    less = 1,
    greater = 2,
};

pub const dbl_max_exp: c_long = 1024;
pub const dbl_mant_dig: c_long = 53;

pub extern "c" fn bignum_equal_p(obj.SchemeObject, obj.SchemeObject) c_int;
pub extern "c" fn bignum_test(obj.SchemeObject) c_int;
pub extern "c" fn bignum_compare(obj.SchemeObject, obj.SchemeObject) c_int;
pub extern "c" fn bignum_add(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_subtract(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_negate(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_multiply(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_divide(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject, *obj.SchemeObject) c_int;
pub extern "c" fn bignum_quotient(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_remainder(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn long_to_bignum(c_long) obj.SchemeObject;
pub extern "c" fn ulong_to_bignum(c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_to_long(obj.SchemeObject) c_long;
pub extern "c" fn bignum_to_ulong(obj.SchemeObject) c_ulong;
pub extern "c" fn intmax_to_bignum(i64) obj.SchemeObject;
pub extern "c" fn uintmax_to_bignum(u64) obj.SchemeObject;
pub extern "c" fn bignum_to_intmax(obj.SchemeObject) i64;
pub extern "c" fn bignum_to_uintmax(obj.SchemeObject) u64;
pub extern "c" fn double_to_bignum(f64) obj.SchemeObject;
pub extern "c" fn bignum_to_double(obj.SchemeObject) f64;
pub extern "c" fn bignum_fits_in_word_p(obj.SchemeObject, c_long, c_int) c_int;
pub extern "c" fn bignum_length_in_bits(obj.SchemeObject) c_ulong;
pub extern "c" fn bignum_integer_length(obj.SchemeObject) c_ulong;
pub extern "c" fn bignum_first_set_bit(obj.SchemeObject) c_long;
pub extern "c" fn bignum_bit_count(obj.SchemeObject) c_ulong;
pub extern "c" fn bignum_hamming_distance(obj.SchemeObject, obj.SchemeObject) c_long;
pub extern "c" fn bignum_bitwise_not(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_and(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_andc2(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_andc1(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_xor(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_ior(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_nor(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_eqv(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_orc2(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_orc1(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_nand(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_nonnegative_one_bits(c_ulong, c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_negative_zero_bits(c_ulong, c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_shift_right(obj.SchemeObject, c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_shift_left(obj.SchemeObject, c_ulong) obj.SchemeObject;
pub extern "c" fn unsigned_long_to_shifted_bignum(c_ulong, c_ulong, c_int) obj.SchemeObject;
pub extern "c" fn digit_stream_to_bignum(
    c_uint,
    *const fn (?*anyopaque) callconv(.c) c_uint,
    ?*anyopaque,
    c_uint,
    c_int,
) obj.SchemeObject;
pub extern "c" fn bignum_to_digit_stream(
    obj.SchemeObject,
    c_uint,
    *const fn (?*anyopaque, c_long) callconv(.c) void,
    ?*anyopaque,
) void;
pub extern "c" fn bignum_max_digit_stream_radix() c_long;

pub inline fn bignumZeroP(b: obj.SchemeObject) bool {
    return bignum_test(b) == @intFromEnum(BignumComparison.equal);
}

pub inline fn bignumNegativeP(b: obj.SchemeObject) bool {
    return bignum_test(b) == @intFromEnum(BignumComparison.less);
}

pub inline fn bignumPositiveP(b: obj.SchemeObject) bool {
    return bignum_test(b) == @intFromEnum(BignumComparison.greater);
}

pub inline fn bignumLessP(x: obj.SchemeObject, y: obj.SchemeObject) bool {
    return bignum_compare(x, y) == @intFromEnum(BignumComparison.less);
}

pub inline fn bignumToLongP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @bitSizeOf(c_long), 1) != 0;
}

pub inline fn bignumToUlongP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @bitSizeOf(c_ulong), 0) != 0;
}

pub inline fn bignumToIntmaxP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, 64, 1) != 0;
}

pub inline fn bignumToUintmaxP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, 64, 0) != 0;
}

pub inline fn bignumToDoubleP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, dbl_max_exp + 1, 1) != 0;
}

pub inline fn losslessBignumToDoubleP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, dbl_mant_dig + 1, 1) != 0;
}

pub inline fn bignumToFixnumP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @as(c_long, obj.fixnum_length) + 1, 1) != 0;
}

pub inline fn fixnumToBignum(f: obj.SchemeObject) obj.SchemeObject {
    return long_to_bignum(obj.fixnumToLong(f));
}

pub inline fn bignumToFixnumVal(b: obj.SchemeObject) obj.SchemeObject {
    return obj.longToFixnum(bignum_to_long(b));
}

pub inline fn bignumToFlonumVal(b: obj.SchemeObject) obj.SchemeObject {
    return double_to_flonum(bignum_to_double(b));
}

pub inline fn flonumToBignum(f: obj.SchemeObject) obj.SchemeObject {
    return double_to_bignum(obj.flonumToDouble(f));
}

pub inline fn primitiveHeader() void {
    if (build_options.debugging) {
        record_primitive_entry(Registers[regblock_expr]);
    }
}

pub inline fn argRef(n: usize) obj.SchemeObject {
    return stack_pointer[n - 1];
}

pub inline fn argLoc(n: usize) [*]obj.SchemeObject {
    return stack_pointer + (n - 1);
}

pub inline fn checkArg(n: c_int, comptime pred: anytype) void {
    if (!pred(argRef(@intCast(n)))) {
        error_wrong_type_arg(n);
    }
}

pub inline fn getLexprActuals() c_ulong {
    return @intCast(Registers[regblock_lexpr_actuals]);
}

pub inline fn gcType(o: obj.SchemeObject) c_int {
    return gc_type_code(@intCast(obj.objectType(o)));
}

pub inline fn gcTypePair(o: obj.SchemeObject) bool {
    return gcType(o) == @intFromEnum(GcType.pair);
}

pub inline fn gcTypeTriple(o: obj.SchemeObject) bool {
    return gcType(o) == @intFromEnum(GcType.triple);
}

pub inline fn gcTypeVector(o: obj.SchemeObject) bool {
    return gcType(o) == @intFromEnum(GcType.vector);
}

pub inline fn interruptEnabledP(mask: c_ulong) bool {
    return (Registers[regblock_int_mask] & mask) != 0;
}

pub inline fn gcEnabledP() bool {
    return interruptEnabledP(int_gc);
}

pub inline fn pendingInterrupts() c_ulong {
    return Registers[regblock_int_mask] & Registers[regblock_int_code];
}

pub inline fn freeOkP(free: [*]const obj.SchemeObject) bool {
    return @intFromPtr(free) >= @intFromPtr(heap_start) and @intFromPtr(free) < @intFromPtr(heap_alloc_limit);
}

pub inline fn heapAvailableP(n_words: c_ulong) bool {
    if (!freeOkP(Free)) return false;
    const avail_words: c_ulong = @intCast((@intFromPtr(heap_alloc_limit) - @intFromPtr(Free)) / @sizeOf(obj.SchemeObject));
    return n_words <= avail_words;
}

pub inline fn gcNeededP(n_words: c_ulong) bool {
    return !heapAvailableP(n_words) and gcEnabledP();
}

pub inline fn compilerSetupInterrupt() void {
    const memtop_ptr: [*]obj.SchemeObject = if (pendingInterrupts() != 0)
        memory_block_start
    else if (gcEnabledP())
        heap_alloc_limit
    else
        heap_end;
    Registers[regblock_memtop] = @intCast(@intFromPtr(memtop_ptr));

    const stack_guard_ptr: [*]obj.SchemeObject = if (interruptEnabledP(int_stack_overflow))
        stack_guard
    else
        stack_start;
    Registers[regblock_stack_guard] = @intCast(@intFromPtr(stack_guard_ptr));
}

pub inline fn requestGc(n_words: c_ulong) void {
    Registers[regblock_int_code] |= int_gc;
    compilerSetupInterrupt();
    gc_space_needed = n_words;
}

pub fn primitiveGc(amount: c_ulong) noreturn {
    const free_prim = Free_primitive orelse {
        outf_fatal("\nMicrocode requested primitive GC outside primitive!\n");
        Microcode_Termination(term_exit);
    };
    if (@intFromPtr(free_prim) < @intFromPtr(heap_start)) {
        outf_fatal("\nMicrocode requested primitive GC outside primitive!\n");
        Microcode_Termination(term_exit);
    }
    if (@intFromPtr(Free) < @intFromPtr(free_prim)) {
        outf_fatal("\nFree has gone backwards!\n");
        Microcode_Termination(term_exit);
    }
    const used_words: c_ulong = @intCast((@intFromPtr(Free) - @intFromPtr(free_prim)) / @sizeOf(obj.SchemeObject));
    requestGc(amount + used_words);
    signal_interrupt_from_primitive();
}

pub inline fn primitiveGcIfNeeded(amount: c_ulong) void {
    if (gcNeededP(amount)) {
        primitiveGc(amount);
    }
}

pub inline fn stackPush(object: obj.SchemeObject) void {
    stack_pointer -= 1;
    stack_pointer[0] = object;
}

pub inline fn stackCanPushP(n: usize) bool {
    return @intFromPtr(stack_pointer) >= @intFromPtr(stack_guard) + n * @sizeOf(obj.SchemeObject);
}

pub inline fn stackOverflowedP() bool {
    return stack_start[0] != obj.makeBrokenHeart(stack_start);
}

pub inline fn stackCheck(n: usize) void {
    if (!stackCanPushP(n)) {
        if (stackOverflowedP()) stack_death("stack_check");
        Registers[regblock_int_code] |= int_stack_overflow;
        compilerSetupInterrupt();
    }
}
