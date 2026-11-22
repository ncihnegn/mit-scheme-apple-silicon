// Standalone smoke test for compiler_utilities, closure trampolines, and trap PC lookup.
// Derived from tests/microcode/trampoline-smoke.c (GPL v2 or later).

const std = @import("std");
const abi = @import("prim_abi");
const smoke = @import("smoke_common.zig");

comptime {
    smoke.exportBaseRuntimeStubs();
    smoke.exportGcOsStubs();
}

const sim_heap_words: usize = 4096;

export var Free: ?[*]smoke.SchemeObject = null;
export var Free_primitive: ?[*]smoke.SchemeObject = null;
export var heap_alloc_limit: ?[*]smoke.SchemeObject = null;
export var heap_start: ?[*]smoke.SchemeObject = null;
export var heap_end: ?[*]smoke.SchemeObject = null;
export var constant_start: ?[*]smoke.SchemeObject = null;
export var constant_end: ?[*]smoke.SchemeObject = null;
export var stack_start: ?[*]smoke.SchemeObject = null;
export var stack_end: ?[*]smoke.SchemeObject = null;
export var stack_pointer: ?[*]smoke.SchemeObject = null;
export var stack_guard: ?[*]smoke.SchemeObject = null;
export var memory_block_start: ?[*]smoke.SchemeObject = null;
export var fixed_objects: smoke.SchemeObject = smoke.sharp_f;
export var ephemeron_array: smoke.SchemeObject = smoke.sharp_f;
export var ephemeron_count: usize = 0;
export var gc_space_needed: usize = 0;
export var last_return_code: ?[*]smoke.SchemeObject = null;
export var prim_apply_error_code: isize = 0;
export var Primitive_Procedure_Table: ?*anyopaque = null;
export var Primitive_Arity_Table: ?[*]c_int = null;

var dummy_stack: [256]smoke.SchemeObject align(16) = undefined;
var sim_heap: [sim_heap_words]smoke.SchemeObject align(16) = undefined;

fn stubMicrocodeTermination(code: c_int) callconv(.c) noreturn {
    smoke.printf("Microcode_Termination({d})\n", .{code});
    std.c.abort();
}

fn stubTerminationInitError() callconv(.c) noreturn {
    smoke.printf("termination_init_error\n", .{});
    std.c.abort();
}

fn stubStackDeath(name: [*:0]const u8) callconv(.c) noreturn {
    smoke.printf("stack_death({s})\n", .{std.mem.span(name)});
    std.c.abort();
}

fn stubErrorExternalReturn() callconv(.c) noreturn {
    smoke.printf("error_external_return\n", .{});
    std.c.abort();
}

fn stubAbortToInterpreter(code: isize) callconv(.c) noreturn {
    smoke.printf("abort_to_interpreter({d})\n", .{code});
    std.c.abort();
}

fn stubSignalInterruptFromPrimitive() callconv(.c) void {
    std.c.abort();
}

fn stubEndSubproblem() callconv(.c) void {}
fn stubCompilerNewSubproblem() callconv(.c) void {}
fn stubCompilerNewReduction() callconv(.c) void {}

fn stubApplyPrimitiveExternal(_: smoke.SchemeObject) callconv(.c) void {
    std.c.abort();
}

fn stubPrimUnimplemented() callconv(.c) smoke.SchemeObject {
    std.c.abort();
}

fn stubMakeVector(_: usize, _: smoke.SchemeObject, _: bool) callconv(.c) smoke.SchemeObject {
    std.c.abort();
}

fn stubRecordApplicator(_: smoke.SchemeObject) callconv(.c) smoke.SchemeObject {
    return smoke.sharp_f;
}

fn stubCharPointerToString(_: ?[*:0]const u8) callconv(.c) smoke.SchemeObject {
    return smoke.sharp_f;
}

fn stubVarLookup(_: smoke.SchemeObject, _: smoke.SchemeObject, _: *smoke.SchemeObject) callconv(.c) isize {
    return abi.prim_done;
}

fn stubVarAssign(_: smoke.SchemeObject, _: smoke.SchemeObject, _: smoke.SchemeObject, _: *smoke.SchemeObject) callconv(.c) isize {
    return abi.prim_done;
}

fn stubCacheOp(_: smoke.SchemeObject, _: smoke.SchemeObject, _: usize) callconv(.c) isize {
    return abi.prim_done;
}

fn stubCompilerVarError(_: smoke.SchemeObject, _: smoke.SchemeObject, _: abi.CacheRefKind) callconv(.c) smoke.SchemeObject {
    return smoke.sharp_f;
}

fn stubVarTrap(_: smoke.SchemeObject, _: *smoke.SchemeObject) callconv(.c) isize {
    return abi.prim_done;
}

fn stubAssignmentTrap(_: smoke.SchemeObject, _: smoke.SchemeObject, _: *smoke.SchemeObject) callconv(.c) isize {
    return abi.prim_done;
}

comptime {
    @export(&stubMicrocodeTermination, .{ .name = "Microcode_Termination" });
    @export(&stubTerminationInitError, .{ .name = "termination_init_error" });
    @export(&stubStackDeath, .{ .name = "stack_death" });
    @export(&stubErrorExternalReturn, .{ .name = "error_external_return" });
    @export(&stubAbortToInterpreter, .{ .name = "abort_to_interpreter" });
    @export(&stubSignalInterruptFromPrimitive, .{ .name = "signal_interrupt_from_primitive" });
    @export(&stubEndSubproblem, .{ .name = "end_subproblem" });
    @export(&stubCompilerNewSubproblem, .{ .name = "compiler_new_subproblem" });
    @export(&stubCompilerNewReduction, .{ .name = "compiler_new_reduction" });
    @export(&stubApplyPrimitiveExternal, .{ .name = "apply_primitive_external" });
    @export(&stubPrimUnimplemented, .{ .name = "Prim_unimplemented" });
    @export(&stubMakeVector, .{ .name = "make_vector" });
    @export(&stubRecordApplicator, .{ .name = "record_applicator" });
    @export(&stubCharPointerToString, .{ .name = "char_pointer_to_string" });
    @export(&stubVarLookup, .{ .name = "lookup_variable" });
    @export(&stubVarLookup, .{ .name = "safe_lookup_variable" });
    @export(&stubVarLookup, .{ .name = "variable_unassigned_p" });
    @export(&stubVarAssign, .{ .name = "assign_variable" });
    @export(&stubCacheOp, .{ .name = "compiler_cache_lookup" });
    @export(&stubCacheOp, .{ .name = "compiler_cache_assignment" });
    @export(&stubCacheOp, .{ .name = "compiler_cache_operator" });
    @export(&stubCacheOp, .{ .name = "compiler_cache_global_operator" });
    @export(&stubCompilerVarError, .{ .name = "compiler_var_error" });
    @export(&stubVarTrap, .{ .name = "compiler_lookup_trap" });
    @export(&stubVarTrap, .{ .name = "compiler_operator_reference_trap" });
    @export(&stubVarTrap, .{ .name = "compiler_safe_lookup_trap" });
    @export(&stubVarTrap, .{ .name = "compiler_unassigned_p_trap" });
    @export(&stubAssignmentTrap, .{ .name = "compiler_assignment_trap" });
}

fn testAllocateTospace(
    n_words: usize,
    start_r: *?[*]smoke.SchemeObject,
    end_r: *?[*]smoke.SchemeObject,
) callconv(.c) void {
    if (n_words > 0) {
        const bytes = n_words * @sizeOf(smoke.SchemeObject);
        const raw = if (start_r.* == null)
            std.c.malloc(bytes)
        else
            std.c.realloc(@ptrCast(start_r.*), bytes);
        const ptr: [*]smoke.SchemeObject = @ptrCast(@alignCast(raw orelse {
            smoke.check(false, "testAllocateTospace OOM");
            unreachable;
        }));
        start_r.* = ptr;
        end_r.* = ptr + n_words;
    } else if (start_r.*) |existing| {
        std.c.free(@ptrCast(existing));
        start_r.* = null;
        end_r.* = null;
    }
}

fn testAbortGc() callconv(.c) noreturn {
    smoke.printf("test_abort_gc invoked\n", .{});
    std.c.abort();
}

fn saveTospaceCopy(
    start: [*]smoke.SchemeObject,
    end: [*]smoke.SchemeObject,
    _: ?*anyopaque,
) callconv(.c) bool {
    const n_words = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(smoke.SchemeObject);
    const dst: [*]smoke.SchemeObject = @ptrCast(@alignCast(abi.tospace_to_newspace(@ptrCast(start)).?));
    std.mem.copyForwards(smoke.SchemeObject, dst[0..n_words], start[0..n_words]);
    return true;
}

fn runClosureTrampoline(
    entry_arg: u64,
    target_pc: ?*anyopaque,
    hook_stub: ?*anyopaque,
    out: *[2]u64,
) void {
    if (comptime smoke.is_native_aarch64) {
        _ = asm volatile (
            \\str x23, [sp, #-16]!
            \\mov x23, %[hook]
            \\blr %[target]
            \\ldr x23, [sp], #16
            : [_] "={x1}" (-> u64),
            : [_] "{x1}" (entry_arg),
              [_] "{x2}" (@intFromPtr(out)),
              [target] "{x16}" (@intFromPtr(target_pc)),
              [hook] "{x9}" (@intFromPtr(hook_stub)),
            : .{ .x17 = true, .x30 = true, .memory = true }
        );
    }
}

pub fn main() u8 {
    smoke.dstack_initialize();
    smoke.transaction_initialize();
    heap_start = &sim_heap;
    Free = &sim_heap;
    heap_end = heap_start.? + sim_heap_words;
    heap_alloc_limit = heap_end.? - 64;
    stack_start = &dummy_stack;
    stack_end = stack_start.? + 256;
    stack_pointer = stack_end;
    stack_guard = stack_start;

    smoke.code_arena_setup(2048);
    abi.initialize_gc(sim_heap_words, &heap_start, &Free, testAllocateTospace, testAbortGc);

    // 1. compiler_initialize allocates compiler_utilities in code_arena.
    abi.compiler_initialize(true);
    smoke.check(abi.compiler_utilities != smoke.sharp_f, "compiler_utilities != #f");
    smoke.check(abi.code_address_p(smoke.objectAddress(abi.compiler_utilities)), "compiler_utilities in code_arena");
    smoke.check(smoke.ccReturnP(abi.return_to_interpreter), "return_to_interpreter");
    smoke.check(smoke.ccReturnP(abi.reflect_to_interface), "reflect_to_interface");
    smoke.check(abi.code_address_p(smoke.ccReturnAddress(abi.return_to_interpreter)), "return_to_interpreter in code_arena");
    smoke.check(abi.code_address_p(smoke.ccReturnAddress(abi.reflect_to_interface)), "reflect_to_interface in code_arena");
    smoke.printf("[1/5] compiler_utilities in code_arena OK (0x{x})\n", .{
        @intFromPtr(smoke.objectAddress(abi.compiler_utilities)),
    });

    // 2. coerce_to_compiled creates a 1-entry TC_MANIFEST_CLOSURE in RW heap.
    var tramp: smoke.SchemeObject = smoke.sharp_f;
    Free = heap_start.? + 32;
    smoke.check(abi.coerce_to_compiled(smoke.ulongToFixnum(999), 2, &tramp) == abi.prim_done, "coerce_to_compiled");
    smoke.check(smoke.ccEntryP(tramp), "CC_ENTRY_P(tramp)");
    const blk = abi.cc_entry_to_block_address(tramp);
    smoke.check(blk == heap_start.? + 32, "blk == heap_start + 32");
    smoke.check(!abi.code_address_p(blk), "closure blk in heap");
    smoke.check(smoke.objectType(blk[0]) == smoke.tc_manifest_closure, "TC_MANIFEST_CLOSURE");
    smoke.check(1 + smoke.objectDatum(blk[0]) == 7, "blk length 7");
    smoke.check(abi.cc_entry_closure_p(tramp), "cc_entry_closure_p");

    const util_addr = smoke.objectAddress(abi.compiler_utilities);
    const entry2 = abi.trampoline_entry_addr(util_addr, 2);
    const resolved_pc = smoke.ccEntryAddressPc(smoke.ccEntryAddress(tramp));
    smoke.check(@intFromPtr(resolved_pc) == @intFromPtr(entry2), "resolved_pc == entry2");

    const store = smoke.trampoline_storage(blk);
    smoke.check(store == blk + 4, "store == blk + 4");
    smoke.check(blk[3] == smoke.ulongToFixnum(smoke.trampoline_k_apply), "trampoline kind");
    smoke.check(store[0] == smoke.ulongToFixnum(999), "store[0] == 999");
    smoke.check(store[1] == smoke.ulongToFixnum(3), "store[1] == 3");
    smoke.check(blk[6] == tramp, "blk[6] == tramp");
    smoke.printf("[2/5] heap TC_MANIFEST_CLOSURE trampoline layout OK\n", .{});

    // 3. Execute trampoline_to_interface natively via mock hook in MAP_JIT.
    var mock_hook_page: ?*anyopaque = null;
    if (comptime smoke.is_native_aarch64) {
        mock_hook_page = smoke.jit_map_code_space(16384);
        smoke.check(mock_hook_page != null, "mock_hook_page");
        const insns: [*]volatile u32 = @ptrCast(@alignCast(mock_hook_page.?));

        smoke.jit_write_begin();
        insns[0] = 0xa9000451; // stp x17, x1, [x2]
        insns[1] = 0xd65f03c0; // ret
        abi.jit_flush_icache(mock_hook_page, 2 * @sizeOf(u32));
        smoke.jit_write_end();

        var out = [2]u64{ 0, 0 };
        runClosureTrampoline(@intFromPtr(smoke.ccEntryAddress(tramp)), resolved_pc, mock_hook_page, &out);
        smoke.check(out[0] == smoke.trampoline_k_apply, "untagged x1 kind");
        smoke.check(out[1] == @intFromPtr(store), "untagged x1 store");

        out = .{ 0, 0 };
        runClosureTrampoline(@intCast(tramp), resolved_pc, mock_hook_page, &out);
        smoke.check(out[0] == smoke.trampoline_k_apply, "tagged x1 kind");
        smoke.check(out[1] == @intFromPtr(store), "tagged x1 store");
        smoke.printf("[3/5] native arm64 trampoline_to_interface (untagged & tagged x1) OK\n", .{});
    } else {
        smoke.printf("[3/5] skipped native arm64 trampoline execution (non-native)\n", .{});
    }

    // 4. Copying GC relocates closure trampoline (-32 words) and preserves target PC.
    {
        abi.open_tospace(heap_start.?);
        abi.initialize_weak_chain();
        abi.current_gc_table = abi.std_gc_table();
        const saved_to = abi.get_newspace_ptr();
        abi.add_to_tospace(tramp);
        abi.gc_drain_tospace_and_code_arena(saved_to);
        abi.update_weak_pointers();
        Free = abi.get_newspace_ptr();
        smoke.check(abi.save_tospace(saveTospaceCopy, null), "save_tospace");
        smoke.check(abi.code_address_p(smoke.objectAddress(abi.compiler_utilities)), "utilities still in code_arena");
        smoke.check(abi.code_arena_marked_p(util_addr), "util_addr marked");
        _ = abi.code_arena_mark_block(util_addr);
        smoke.code_arena_sweep();

        const rel_tramp = heap_start.?[0];
        smoke.check(smoke.ccEntryP(rel_tramp), "rel_tramp CC_ENTRY");
        const rel_blk = abi.cc_entry_to_block_address(rel_tramp);
        smoke.check(rel_blk == heap_start.? + 1, "rel_blk == heap_start + 1");
        smoke.check(rel_blk != blk, "rel_blk moved");
        smoke.check(smoke.trampoline_storage(rel_blk)[0] == smoke.ulongToFixnum(999), "rel store[0] == 999");
        smoke.check(smoke.trampoline_storage(rel_blk)[1] == smoke.ulongToFixnum(3), "rel store[1] == 3");
        smoke.check(rel_blk[6] == rel_tramp, "rel_blk[6] == rel_tramp");
        smoke.check(@intFromPtr(smoke.ccEntryAddressPc(smoke.ccEntryAddress(rel_tramp))) == @intFromPtr(entry2), "rel pc == entry2");

        if (comptime smoke.is_native_aarch64) {
            var out = [2]u64{ 0, 0 };
            runClosureTrampoline(
                @intCast(rel_tramp),
                smoke.ccEntryAddressPc(smoke.ccEntryAddress(rel_tramp)),
                mock_hook_page,
                &out,
            );
            smoke.check(out[0] == smoke.trampoline_k_apply, "rel exec kind");
            smoke.check(out[1] == @intFromPtr(smoke.trampoline_storage(rel_blk)), "rel exec store");
            smoke.jit_unmap_code_space(mock_hook_page, 16384);
        }
        smoke.printf("[4/5] GC relocation of heap closure trampoline + re-exec OK\n", .{});
    }

    // 5. code_arena_find_block finds live blocks & rejects headers/holes/heap.
    {
        const hole_blk = abi.code_arena_alloc(8).?;
        const live_blk = abi.code_arena_alloc(8).?;

        smoke.check(smoke.code_arena_find_block(smoke.ccReturnAddress(abi.return_to_interpreter)) == util_addr, "find util_addr");
        smoke.check(smoke.code_arena_find_block(util_addr) == null, "reject header 0");
        smoke.check(smoke.code_arena_find_block(util_addr + 1) == null, "reject header 1");
        smoke.check(smoke.code_arena_find_block(smoke.code_alloc_next) == null, "reject code_alloc_next");
        smoke.check(smoke.code_arena_find_block(blk) == null, "reject heap blk");

        abi.code_arena_write_begin();
        hole_blk[0] = smoke.makeVectorHeader(7);
        hole_blk[1] = smoke.makeNmvHeader(6);
        live_blk[0] = smoke.makeVectorHeader(7);
        live_blk[1] = smoke.makeNmvHeader(6);
        abi.code_arena_write_end();

        smoke.check(smoke.code_arena_find_block(hole_blk + 3) == hole_blk, "find hole_blk");
        smoke.check(smoke.code_arena_find_block(live_blk + 3) == live_blk, "find live_blk");

        abi.code_arena_mark_begin();
        smoke.check(abi.code_arena_mark_block(util_addr), "mark util_addr");
        smoke.check(abi.code_arena_mark_block(live_blk), "mark live_blk");
        smoke.code_arena_sweep();

        smoke.check(smoke.objectType(hole_blk[0]) == smoke.tc_manifest_nm_vector, "hole_blk swept to NMV");
        smoke.check(smoke.code_arena_find_block(hole_blk + 3) == null, "reject swept hole");
        smoke.check(smoke.code_arena_find_block(live_blk + 3) == live_blk, "find live_blk after sweep");
        smoke.printf("[5/5] code_arena_find_block (live, headers, swept holes) OK\n", .{});
    }

    smoke.code_arena_teardown();
    return 0;
}
