// Derived from MIT/GNU Scheme C sources (`src/microcode/memmag.c`, `memmag.h`, `stack.h`, `cmpgc.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const outf = @import("outf.zig");
const storage = @import("storage.zig");
const utils = @import("utils.zig");
const code_arena = @import("code_arena.zig");

extern "c" fn malloc(size: usize) ?*anyopaque;
extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;
extern "c" fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
extern "c" fn exit(status: c_int) noreturn;

var saved_heap_size: usize = 0;
var saved_constant_size: usize = 0;
var saved_stack_size: usize = 0;
var saved_to: ?[*]obj.SchemeObject = null;

const primes = [_]usize{
    11,
    23,
    53,
    97,
    193,
    389,
    769,
    1543,
    3079,
    6151,
    12289,
    24593,
    49157,
    98317,
    196613,
    393241,
    786433,
    1572869,
    3145739,
    6291469,
    12582917,
    25165843,
    50331653,
    100663319,
    201326611,
    402653189,
    805306457,
    1610612741,
};

fn allocationTooLarge() noreturn {
    outf.fatal("Requested allocation is too large.\n", .{});
    outf.fatal("Try again with a smaller argument to '--heap'.\n", .{});
    outf.flushFatal();
    reset_memory();
    exit(1);
}

pub export fn setup_memory(
    heap_size: usize,
    stack_size: usize,
    constant_size: usize,
    code_size: usize,
) callconv(.c) void {
    if (heap_size == 0 or stack_size == 0) {
        outf.fatal("Configuration won't hold initial data.\n", .{});
        outf.flushFatal();
        exit(1);
    }

    const total_words_u128 = @as(u128, stack_size) + heap_size + constant_size;
    if (total_words_u128 >= obj.datum_mask) {
        allocationTooLarge();
    }

    const total_words: usize = @intCast(total_words_u128);
    const raw = abi.OS_malloc_init(total_words * @sizeOf(obj.SchemeObject)) orelse {
        outf.fatal("Not enough memory for this configuration.\n", .{});
        outf.flushFatal();
        exit(1);
    };
    const block_start: [*]obj.SchemeObject = @ptrCast(@alignCast(raw));
    const block_end = block_start + total_words;

    if (!obj.heap_in_low_memory) {
        storage.memory_base_storage = block_start;
    }
    storage.memory_block_start = block_start;
    storage.memory_block_end = block_end;

    if (obj.addressToDatum(block_end) > obj.datum_mask) {
        allocationTooLarge();
    }

    saved_stack_size = stack_size;
    saved_constant_size = constant_size;
    saved_heap_size = heap_size;
    reset_allocator_parameters(0, 0);
    code_arena.code_arena_setup(code_size);
    abi.initialize_gc(heap_size, &storage.heap_start, &storage.Free, &allocateTospace, &abortGc);
}

pub export fn reset_memory() callconv(.c) void {
    code_arena.code_arena_teardown();
    if (storage.memory_block_start) |p| {
        free(@ptrCast(p));
        storage.memory_block_start = null;
        storage.memory_block_end = null;
    }
}

pub export fn allocations_ok_p(
    n_constant: usize,
    n_heap: usize,
    n_reserved: usize,
) callconv(.c) bool {
    const start = storage.memory_block_start orelse return false;
    const end = storage.memory_block_end orelse return false;
    const block_words: u128 = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(obj.SchemeObject);
    const effective_reserved: usize = if (n_reserved == 0) abi.default_heap_reserved else n_reserved;
    const needed: u128 =
        @as(u128, saved_stack_size) +
        n_constant +
        abi.constant_space_fudge +
        n_heap +
        effective_reserved;
    return needed < block_words;
}

pub export fn reset_allocator_parameters(
    n_constant: usize,
    reserved: usize,
) callconv(.c) void {
    const start = storage.memory_block_start.?;
    const end = storage.memory_block_end.?;

    storage.heap_reserved = if (reserved == 0) abi.default_heap_reserved else reserved;
    storage.gc_space_needed = 0;
    abi.setStackLimits(start, saved_stack_size);

    const const_start = start + @as(usize, @intCast(saved_stack_size));
    const const_end = const_start + @as(usize, @intCast(n_constant + abi.constant_space_fudge));
    storage.constant_start = const_start;
    storage.constant_alloc_next = const_start;
    storage.constant_end = const_end;
    storage.heap_start = const_end;
    storage.Free = const_end;
    storage.heap_end = end;

    abi.resetHeapAllocLimit();
    abi.initializeStack();
}

fn allocateTospace(
    n_words: usize,
    start_r: *?[*]obj.SchemeObject,
    end_r: *?[*]obj.SchemeObject,
) callconv(.c) void {
    if (n_words > 0) {
        const bytes: usize = @as(usize, @intCast(n_words)) * @sizeOf(obj.SchemeObject);
        const raw = if (start_r.*) |prev| realloc(@ptrCast(prev), bytes) else malloc(bytes);
        const p: [*]obj.SchemeObject = @ptrCast(@alignCast(raw orelse {
            outf.fatal("Unable to allocate temporary heap for GC.\n", .{});
            outf.flushFatal();
            exit(1);
        }));
        start_r.* = p;
        end_r.* = p + @as(usize, @intCast(n_words));
    } else if (start_r.*) |prev| {
        free(@ptrCast(prev));
        start_r.* = null;
        end_r.* = null;
    }
}

fn abortGc() callconv(.c) noreturn {
    abi.Microcode_Termination(abi.term_exit);
}

pub export fn object_in_heap_p(object: obj.SchemeObject) callconv(.c) bool {
    const address = abi.get_object_address(object) orelse return false;
    return abi.addressInHeapP(address);
}

// DEFINE_PRIMITIVE ("GARBAGE-COLLECT", Prim_garbage_collect, 1, 1,
//   "(SAFETY-MARGIN)\n\
// Performs a garbage collection and returns the number of words\n\
// available for further allocation.  Also sets the \"safety margin\",\n\
// which is the number of reserved words at the top of the heap, to\n\
// SAFETY-MARGIN, which must be a non-negative integer.  Finally, runs\n\
// the primitive GC daemons before returning.")
pub export fn Prim_garbage_collect() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();

    abi.stackCheckFatal("GC");
    if (@intFromPtr(abi.Free) > @intFromPtr(abi.heap_end)) {
        outf.fatal("\nGC has been delayed too long!\n", .{});
        outf.fatal(
            "Free = 0x{x}; heap_alloc_limit = 0x{x}; heap_end = 0x{x}\n",
            .{
                @intFromPtr(abi.Free),
                @intFromPtr(abi.heap_alloc_limit),
                @intFromPtr(abi.heap_end),
            },
        );
        abi.Microcode_Termination(abi.term_no_space);
    }

    const safety_margin = abi.argHeapReserved(1);
    const heap_words: usize = @intCast((@intFromPtr(abi.heap_end) - @intFromPtr(abi.heap_start)) / @sizeOf(obj.SchemeObject));
    if (safety_margin < heap_words) {
        abi.heap_reserved = safety_margin;
        abi.heap_alloc_limit = abi.heap_end - @as(usize, @intCast(safety_margin));
    }
    abi.popPrimitiveFrame(1);

    abi.critical_section_name = "garbage collector";

    if (build_options.debugging and storage.gc_debug) {
        _ = abi.debug_verify_heap();
    }

    abi.open_tospace(abi.heap_start);
    abi.initialize_weak_chain();
    storage.ephemeron_count = 0;

    std_gc_pt1();
    std_gc_pt2();

    abi.stackCheck(abi.cont_size);
    const avail = abi.heapAvailable();
    const remaining: usize = if (avail > abi.gc_space_needed) avail - abi.gc_space_needed else 0;
    abi.pushCont(abi.rc_normal_gc_done, obj.ulongToFixnum(remaining));

    abi.critical_section_name = "garbage collector daemon";
    const daemon = obj.vectorRef(abi.fixed_objects, abi.fixobj_gc_daemon);
    if (daemon == obj.sharp_f) {
        abi.abort_to_interpreter(abi.prim_pop_return);
    }

    abi.stackCheck(2);
    abi.stackPush(daemon);
    abi.stackPush(abi.makeApplyFrameHeader(1));
    abi.abort_to_interpreter(abi.prim_apply);
}

pub export fn std_gc_pt1() callconv(.c) void {
    if (build_options.debugging) {
        abi.initialize_gc_object_references();
    }

    const newspace_start = abi.get_newspace_ptr();
    saved_to = newspace_start;
    abi.add_to_tospace(abi.fixed_objects);
    const hist_word = if (utils.history_register) |hr|
        obj.makePointerObject(obj.tc_history_unmarked, hr)
    else
        obj.makeObject(obj.tc_history_unmarked, 0);
    abi.add_to_tospace(hist_word);

    abi.current_gc_table = abi.std_gc_table();
    if (build_options.cc_support) {
        if (abi.compiler_utilities != obj.sharp_f and
            code_arena.code_address_p(@ptrCast(obj.objectAddress(abi.compiler_utilities))))
        {
            _ = code_arena.code_arena_mark_block(obj.objectAddress(abi.compiler_utilities));
        }
    }
    abi.gc_scan_oldspace(abi.stack_pointer, abi.stack_end);
    abi.gc_scan_oldspace(abi.constant_start, abi.constant_alloc_next);
    abi.gc_drain_tospace_and_code_arena(newspace_start);

    if (build_options.debugging) {
        abi.finalize_gc_object_references();
    }
    abi.update_weak_pointers();
}

pub fn ccTransportEnd() void {
    if (build_options.cc_support) {
        abi.Registers[abi.regblock_closure_free] = 0;
        abi.Registers[abi.regblock_closure_space] = 0;
        if (build_options.cc_is_native and builtin.cpu.arch == .aarch64) {
            abi.aarch64_flush_i_cache();
        }
    }
}

pub export fn std_gc_pt2() callconv(.c) void {
    const p = abi.get_newspace_ptr();
    _ = abi.save_tospace(&saveTospaceCopy, null);
    storage.Free = p;

    const st = saved_to.?;
    storage.fixed_objects = st[0];
    utils.history_register = obj.objectAddress(st[1]);
    saved_to = null;

    var length = computeEphemeronArrayLength(storage.ephemeron_count + storage.n_ephemerons_requested);
    if (!abi.heapAvailableP(1 + length + (storage.n_ephemerons_requested * abi.ephemeron_size))) {
        if (storage.ephemeron_request_hard_p) {
            storage.gc_space_needed += 1 + length;
        }
        length = computeEphemeronArrayLength(storage.ephemeron_count);
        if (build_options.debugging) {
            // This should never trigger, because we discard the previous
            // ephemeron array, which always has room for at least as many
            // ephemerons as are now live.
            if (!abi.heapAvailableP(1 + length)) {
                abi.std_gc_death("No room for ephemeron array");
            }
        }
    }
    storage.ephemeron_array = abi.make_vector(length, obj.sharp_f, false);
    storage.n_ephemerons_requested = 0;
    storage.ephemeron_request_hard_p = false;

    code_arena.code_arena_sweep();
    ccTransportEnd();
    abi.clearInterrupt(abi.int_gc);
}

fn saveTospaceCopy(
    start: [*]obj.SchemeObject,
    end: [*]obj.SchemeObject,
    _: ?*anyopaque,
) callconv(.c) bool {
    _ = memmove(abi.tospace_to_newspace(@ptrCast(start)), @ptrCast(start), @intFromPtr(end) - @intFromPtr(start));
    return true;
}

pub export fn stack_death(name: [*:0]const u8) callconv(.c) noreturn {
    outf.fatal("\n{s}: The stack has overflowed and overwritten adjacent memory.\n", .{name});
    outf.fatal("This was probably caused by a runaway recursion.\n", .{});
    abi.Microcode_Termination(abi.term_stack_overflow);
}

// DEFINE_PRIMITIVE ("GC-TRACE-REFERENCES", Prim_gc_trace_references, 2, 2, 0)
pub export fn Prim_gc_trace_references() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const collector = abi.argRef(2);
    if (!(collector == obj.sharp_f or (obj.vectorP(collector) and obj.vectorLength(collector) >= 1))) {
        abi.error_wrong_type_arg(2);
    }
    if (build_options.debugging) {
        abi.collect_gc_object_references(abi.argRef(1), collector);
    } else {
        abi.error_external_return();
    }
    return obj.unspecific;
}

fn computeEphemeronArrayLength(n: usize) usize {
    var start: usize = 0;
    var end: usize = primes.len;
    if (primes[end - 1] < n) return primes[end - 1];

    while (start < end) {
        const index = start + (end - start) / 2;
        if (primes[index] < n) {
            start = index + 1;
        } else if (n < primes[index]) {
            end = index;
        } else {
            return primes[index];
        }
    }
    return primes[start];
}

fn ephemeronArrayBigEnoughP(n: usize) bool {
    return n == 0 or (obj.vectorP(storage.ephemeron_array) and n <= obj.vectorLength(storage.ephemeron_array));
}

pub export fn compute_extra_ephemeron_space(n: usize) callconv(.c) usize {
    if (ephemeronArrayBigEnoughP(n)) return 0;
    return 1 + computeEphemeronArrayLength(n);
}

pub export fn guarantee_extra_ephemeron_space(n: usize) callconv(.c) void {
    storage.ephemeron_count = n;
    if (!ephemeronArrayBigEnoughP(n)) {
        const length = computeEphemeronArrayLength(n);
        std.debug.assert(abi.heapAvailableP(1 + length));
        storage.ephemeron_array = abi.make_vector(length, obj.sharp_f, false);
    }
}

fn gcIfNeededForEphemeron(extra_space: usize) void {
    if (abi.gcNeededP(abi.ephemeron_size + extra_space)) {
        storage.n_ephemerons_requested = 1;
        storage.ephemeron_request_hard_p = true;
        abi.primitiveGc(abi.ephemeron_size);
    }
}

// DEFINE_PRIMITIVE ("MAKE-EPHEMERON", Prim_make_ephemeron, 2, 2, 0)
pub export fn Prim_make_ephemeron() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    storage.ephemeron_count += 1;
    if (ephemeronArrayBigEnoughP(storage.ephemeron_count)) {
        gcIfNeededForEphemeron(0);
    } else {
        const length = computeEphemeronArrayLength(storage.ephemeron_count);
        gcIfNeededForEphemeron(1 + length);
        storage.ephemeron_array = abi.make_vector(length, obj.sharp_f, false);
    }
    const addr = storage.Free.?;
    addr[0] = abi.marked_ephemeron_manifest;
    addr[1] = abi.argRef(1); // key
    addr[2] = abi.argRef(2); // datum
    addr[3] = obj.sharp_f; // list
    addr[4] = obj.sharp_f; // queue
    storage.Free = addr + @as(usize, @intCast(abi.ephemeron_size));
    return obj.makePointerObject(obj.tc_ephemeron, addr);
}

test "memmag ephemeron array sizing, make-ephemeron, memory setup, and std_gc cycle" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    try std.testing.expectEqual(@as(usize, 11), computeEphemeronArrayLength(0));
    try std.testing.expectEqual(@as(usize, 11), computeEphemeronArrayLength(11));
    try std.testing.expectEqual(@as(usize, 23), computeEphemeronArrayLength(12));
    try std.testing.expectEqual(@as(usize, 1610612741), computeEphemeronArrayLength(std.math.maxInt(usize)));

    try std.testing.expectEqual(@as(usize, 0), compute_extra_ephemeron_space(0));
    try std.testing.expectEqual(@as(usize, 12), compute_extra_ephemeron_space(1));

    var arena: [8192]obj.SchemeObject = @splat(0);
    storage.memory_block_start = (&arena).ptr;
    storage.memory_block_end = (&arena).ptr + arena.len;
    saved_stack_size = 5000;
    saved_constant_size = 128;
    saved_heap_size = 2000;
    reset_allocator_parameters(100, 32);

    try std.testing.expectEqual(@as(usize, 32), storage.heap_reserved);
    try std.testing.expectEqual((&arena).ptr + 5000, storage.constant_start);
    try std.testing.expectEqual((&arena).ptr + 5000 + 100 + abi.constant_space_fudge, storage.heap_start);
    try std.testing.expectEqual(storage.heap_start, storage.Free);
    try std.testing.expectEqual((&arena).ptr + arena.len, storage.heap_end);
    try std.testing.expectEqual((&arena).ptr + arena.len - 32, storage.heap_alloc_limit);
    try std.testing.expect(allocations_ok_p(100, 1000, 32));
    try std.testing.expect(!allocations_ok_p(2000, 2000, 32));

    // object_in_heap_p and make-ephemeron
    var stack: [4]obj.SchemeObject = .{ obj.ulongToFixnum(7), obj.ulongToFixnum(9), 0, 0 };
    storage.stack_pointer = (&stack).ptr;
    storage.stack_end = (&stack).ptr + stack.len;

    const eph = Prim_make_ephemeron();
    try std.testing.expectEqual(obj.tc_ephemeron, obj.objectType(eph));
    try std.testing.expect(object_in_heap_p(eph));
    try std.testing.expect(obj.vectorP(storage.ephemeron_array));
    try std.testing.expectEqual(@as(usize, 11), obj.vectorLength(storage.ephemeron_array));
    try std.testing.expectEqual(@as(usize, 1), storage.ephemeron_count);
    const eph_addr = obj.objectAddress(eph);
    try std.testing.expectEqual(abi.marked_ephemeron_manifest, eph_addr[0]);
    try std.testing.expectEqual(obj.ulongToFixnum(7), eph_addr[1]);
    try std.testing.expectEqual(obj.ulongToFixnum(9), eph_addr[2]);
    try std.testing.expectEqual(obj.sharp_f, eph_addr[3]);
    try std.testing.expectEqual(obj.sharp_f, eph_addr[4]);

    guarantee_extra_ephemeron_space(12);
    try std.testing.expectEqual(@as(usize, 12), storage.ephemeron_count);
    try std.testing.expectEqual(@as(usize, 23), obj.vectorLength(storage.ephemeron_array));

    // Exercise std_gc_pt1 / std_gc_pt2 cycle
    storage.fixed_objects = obj.sharp_t;
    utils.history_register = (&arena).ptr + 5010;
    abi.open_tospace(abi.heap_start);
    abi.initialize_weak_chain();
    abi.Registers[abi.regblock_int_code] = abi.int_gc;
    if (build_options.cc_support) {
        abi.Registers[abi.regblock_closure_free] = 123;
        abi.Registers[abi.regblock_closure_space] = 456;
    }

    std_gc_pt1();
    std_gc_pt2();
    try std.testing.expectEqual(obj.sharp_t, storage.fixed_objects);
    try std.testing.expectEqual((&arena).ptr + 5010, utils.history_register.?);
    try std.testing.expectEqual(@as(usize, 0), abi.Registers[abi.regblock_int_code] & abi.int_gc);
    if (build_options.cc_support) {
        try std.testing.expectEqual(@as(usize, 0), abi.Registers[abi.regblock_closure_free]);
        try std.testing.expectEqual(@as(usize, 0), abi.Registers[abi.regblock_closure_space]);
        if (build_options.cc_is_native and builtin.cpu.arch == .aarch64) {
            try std.testing.expectEqual(@as(usize, 1), stubs.mock_icache_flush_calls);
        }
    }
    try std.testing.expectEqual(@as(usize, 23), obj.vectorLength(storage.ephemeron_array));

    // Reset before deferred resetMockRuntime (not calling OS reset_memory on stack arena)
    storage.memory_block_start = null;
    storage.memory_block_end = null;
}
