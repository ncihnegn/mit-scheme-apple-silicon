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

pub const fixobj_record_tag: usize = 0x11;
pub const fixobj_record_app_index: usize = 0x12;
pub const fixobj_proxied_record_types: usize = 0x15;

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
