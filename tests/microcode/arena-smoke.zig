// Standalone smoke test for code_arena mark-sweep reclamation.
// Derived from tests/microcode/arena-smoke.c (GPL v2 or later).

const std = @import("std");
const abi = @import("microcode_smoke").prim_abi;
const smoke = @import("smoke_common.zig");

comptime {
    smoke.exportBaseRuntimeStubs();
}

const is_aarch64: bool = smoke.is_native_aarch64;

const ConstFn = *const fn () callconv(.c) c_int;

fn emitConstFn(block: [*]smoke.SchemeObject, movz_insn: u32) void {
    if (comptime is_aarch64) {
        const insns: [*]u32 = @ptrCast(block + 2);
        insns[0] = movz_insn; // movz w0, #imm
        insns[1] = 0xd65f03c0; // ret
    }
}

fn callConstFn(block: [*]smoke.SchemeObject) c_int {
    if (comptime is_aarch64) {
        const f: ConstFn = @ptrCast(@alignCast(block + 2));
        return f();
    }
    return -1;
}

pub fn main() u8 {
    const a_words: usize = 6;
    const b_words: usize = 8;
    const c_words: usize = 6;
    const d_words: usize = 10;

    smoke.dstack_initialize();

    // 1. 16 KiB primary arena setup and RX steady state.
    smoke.code_arena_setup(2048);
    smoke.check(smoke.code_start != null, "code_start != null");
    smoke.check(smoke.code_alloc_next == smoke.code_start, "code_alloc_next == code_start");
    smoke.check(@intFromPtr(smoke.code_end) >= @intFromPtr(smoke.code_start.? + 2048), "code_end >= start + 2048");
    smoke.check(smoke.jit_write_nesting_depth() == 0, "jit_write_nesting_depth == 0");
    smoke.check(smoke.code_arena_chunk_count() == 1, "chunk_count == 1");
    smoke.check(smoke.code_arena_live_words() == 0, "live_words == 0");
    smoke.printf("[1/5] code_arena_setup OK (0x{x}..0x{x}, {d} words)\n", .{
        @intFromPtr(smoke.code_start),
        @intFromPtr(smoke.code_end),
        (@intFromPtr(smoke.code_end) - @intFromPtr(smoke.code_start)) / @sizeOf(smoke.SchemeObject),
    });

    // 2. Allocate 4 live blocks A, B, C, D and execute RX AArch64 stubs.
    const a = abi.code_arena_alloc(a_words).?;
    const b = abi.code_arena_alloc(b_words).?;
    const c = abi.code_arena_alloc(c_words).?;
    const d = abi.code_arena_alloc(d_words).?;
    smoke.check(b == a + a_words, "b == a + a_words");
    smoke.check(c == b + b_words, "c == b + b_words");
    smoke.check(d == c + c_words, "d == c + c_words");
    smoke.check(smoke.code_alloc_next.? == d + d_words, "code_alloc_next == d + d_words");

    abi.code_arena_write_begin();
    a[0] = smoke.makeVectorHeader(a_words - 1);
    emitConstFn(a, 0x52800160); // movz w0, #11
    b[0] = smoke.makeVectorHeader(b_words - 1);
    c[0] = smoke.makeVectorHeader(c_words - 1);
    emitConstFn(c, 0x528002c0); // movz w0, #22
    d[0] = smoke.makeVectorHeader(d_words - 1);
    abi.code_arena_write_end();
    smoke.check(smoke.jit_write_nesting_depth() == 0, "write depth == 0 after write_end");
    abi.code_arena_flush_icache();

    if (comptime is_aarch64) {
        smoke.check(callConstFn(a) == 11, "callConstFn(a) == 11");
        smoke.check(callConstFn(c) == 22, "callConstFn(c) == 22");
    }
    smoke.check(smoke.code_arena_live_words() == a_words + b_words + c_words + d_words, "live_words == A+B+C+D");
    smoke.check(smoke.code_range_valid_p(a, d + d_words), "code_range_valid_p(a, d+d_words)");
    smoke.check(!smoke.code_range_valid_p(smoke.code_start, smoke.code_alloc_next.? + 1), "!code_range_valid_p past next");
    smoke.printf("[2/5] allocate + RX execute A & C OK\n", .{});

    // 3. Mark A & C, pop mark stack, sweep B (free hole) and D (retract top).
    abi.code_arena_mark_begin();
    smoke.check(abi.code_arena_mark_block(a), "mark a newly");
    smoke.check(!abi.code_arena_mark_block(a), "mark a idempotent");
    smoke.check(abi.code_arena_mark_block(c), "mark c newly");
    smoke.check(abi.code_arena_marked_p(a), "marked_p(a)");
    smoke.check(!abi.code_arena_marked_p(b), "!marked_p(b)");
    smoke.check(abi.code_arena_marked_p(c), "marked_p(c)");
    smoke.check(!abi.code_arena_marked_p(d), "!marked_p(d)");
    smoke.check(!abi.code_arena_mark_stack_empty_p(), "!mark_stack_empty");
    smoke.check(abi.code_arena_pop_mark_stack().? == c, "pop == c");
    smoke.check(abi.code_arena_pop_mark_stack().? == a, "pop == a");
    smoke.check(abi.code_arena_mark_stack_empty_p(), "mark_stack_empty");

    smoke.code_arena_sweep();
    smoke.check(smoke.jit_write_nesting_depth() == 0, "depth == 0 after sweep");
    smoke.check(smoke.code_alloc_next.? == c + c_words, "retracted tail D");
    smoke.check(!abi.code_address_p(d), "!code_address_p(d)");
    smoke.check(abi.code_address_p(b), "code_address_p(b)");
    smoke.check(smoke.objectType(b[0]) == smoke.tc_manifest_nm_vector, "b is NMV hole");
    smoke.check(1 + smoke.objectDatum(b[0]) == b_words, "b hole length == b_words");
    smoke.check(smoke.code_arena_live_words() == a_words + c_words, "live_words == A+C");
    if (comptime is_aarch64) {
        smoke.check(callConstFn(a) == 11, "callConstFn(a) == 11 after sweep");
        smoke.check(callConstFn(c) == 22, "callConstFn(c) == 22 after sweep");
    }
    smoke.printf("[3/5] mark-sweep retract tail D + free-hole B OK\n", .{});

    // 4. Split hole B -> 1-word remainder, then sweep & coalesce back to b_words.
    const b2 = abi.code_arena_alloc(b_words - 1).?;
    smoke.check(b2 == b, "b2 == b");
    smoke.check(b2[b_words - 1] == smoke.makeNmvHeader(0), "1-word remainder NMV(0)");
    abi.code_arena_write_begin();
    b2[0] = smoke.makeVectorHeader(b_words - 2);
    abi.code_arena_write_end();

    abi.code_arena_mark_begin();
    smoke.check(abi.code_arena_mark_block(a), "mark a");
    smoke.check(abi.code_arena_mark_block(c), "mark c");
    smoke.code_arena_sweep();
    smoke.check(smoke.objectType(b[0]) == smoke.tc_manifest_nm_vector, "b coalesced to NMV");
    smoke.check(1 + smoke.objectDatum(b[0]) == b_words, "coalesced b_words");

    const b3 = abi.code_arena_alloc(b_words).?;
    smoke.check(b3 == b, "b3 == b");
    abi.code_arena_write_begin();
    b3[0] = smoke.makeVectorHeader(b_words - 1);
    abi.code_arena_write_end();
    smoke.printf("[4/5] 1-word remainder split + coalesce + exact reuse OK\n", .{});

    // 5. Overflow chunk creation, cross-chunk mark-sweep, and rebuild_free_list.
    const remaining = (@intFromPtr(smoke.code_end) - @intFromPtr(smoke.code_alloc_next)) / @sizeOf(smoke.SchemeObject);
    if (remaining >= 2) {
        const filler = abi.code_arena_alloc(remaining).?;
        abi.code_arena_write_begin();
        filler[0] = smoke.makeVectorHeader(remaining - 1);
        abi.code_arena_write_end();
    }
    smoke.check(smoke.code_alloc_next.? == smoke.code_end.?, "code_alloc_next == code_end");

    const e = abi.code_arena_alloc(16).?;
    smoke.check(smoke.code_arena_chunk_count() == 2, "chunk_count == 2");
    smoke.check(abi.code_address_p(e), "code_address_p(e)");
    abi.code_arena_write_begin();
    e[0] = smoke.makeVectorHeader(15);
    emitConstFn(e, 0x52800420); // movz w0, #33
    abi.code_arena_write_end();
    abi.code_arena_flush_icache();
    if (comptime is_aarch64) {
        smoke.check(callConstFn(e) == 33, "callConstFn(e) == 33");
    }

    abi.code_arena_mark_begin();
    smoke.check(abi.code_arena_mark_block(a), "mark a");
    smoke.check(abi.code_arena_mark_block(c), "mark c");
    smoke.check(abi.code_arena_mark_block(e), "mark e");
    smoke.code_arena_sweep();

    smoke.check(smoke.code_alloc_next.? == c + c_words, "code_alloc_next == c + c_words");
    smoke.check(smoke.objectType(b[0]) == smoke.tc_manifest_nm_vector, "b NMV after sweep");
    smoke.check(1 + smoke.objectDatum(b[0]) == b_words, "b length == b_words");
    smoke.check(abi.code_address_p(e), "e still live");
    smoke.check(smoke.code_arena_live_words() == a_words + c_words + 16, "live_words == A+C+16");

    const x = abi.code_arena_alloc(4).?;
    const y = abi.code_arena_alloc(4).?;
    smoke.check(x == b and y == b + 4, "split B into x and y");
    smoke.code_arena_rebuild_free_list();
    smoke.check(smoke.objectType(b[0]) == smoke.tc_manifest_nm_vector, "rebuild coalesced NMV");
    smoke.check(1 + smoke.objectDatum(b[0]) == b_words, "rebuild coalesced b_words");
    const z = abi.code_arena_alloc(b_words).?;
    smoke.check(z == b, "reused coalesced b");
    smoke.printf("[5/5] overflow chunk + cross-chunk sweep + rebuild_free_list OK\n", .{});

    smoke.code_arena_teardown();
    smoke.check(smoke.code_start == null and smoke.code_alloc_next == null and smoke.code_end == null, "teardown cleared globals");
    smoke.check(smoke.code_arena_chunk_count() == 0, "chunk_count == 0");
    smoke.check(!abi.code_address_p(a), "!code_address_p(a)");
    return 0;
}
