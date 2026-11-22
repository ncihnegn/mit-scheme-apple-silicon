// Smoke test for gcloop + code_arena mark-sweep, weak pairs, and ephemerons.
// Derived from tests/microcode/gc-arena-smoke.c (GPL v2 or later).

const std = @import("std");
const abi = @import("prim_abi");
const smoke = @import("smoke_common.zig");

comptime {
    smoke.exportBaseRuntimeStubs();
    smoke.exportGcOsStubs();
    smoke.exportMinimalCcHelpers();
}

const sim_heap_words: usize = 4096;
const eph_array_len: usize = 23;

export var Free: ?[*]smoke.SchemeObject = null;
export var constant_start: ?[*]smoke.SchemeObject = null;
export var ephemeron_array: smoke.SchemeObject = smoke.sharp_f;
export var ephemeron_count: usize = 0;

var sim_heap: [sim_heap_words]smoke.SchemeObject align(16) = undefined;
var sim_heap_start: ?[*]smoke.SchemeObject = &sim_heap;
var sim_free: ?[*]smoke.SchemeObject = &sim_heap;
var sim_eph_vec: [1 + eph_array_len]smoke.SchemeObject align(16) = undefined;

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

fn resetEphemeronTable() void {
    sim_eph_vec[0] = smoke.makeVectorHeader(eph_array_len);
    for (1..sim_eph_vec.len) |i| {
        sim_eph_vec[i] = smoke.sharp_f;
    }
    ephemeron_array = smoke.makePointerObject(smoke.tc_vector, &sim_eph_vec);
    ephemeron_count = 0;
}

fn allocSimPair(tc: usize, car_obj: smoke.SchemeObject, cdr_obj: smoke.SchemeObject) smoke.SchemeObject {
    const p = sim_free.?;
    sim_free = p + 2;
    smoke.check(@intFromPtr(sim_free.?) <= @intFromPtr(&sim_heap) + sim_heap_words * @sizeOf(smoke.SchemeObject), "sim heap pair OOM");
    p[0] = car_obj;
    p[1] = cdr_obj;
    return smoke.makePointerObject(tc, p);
}

fn allocSimEphemeron(key: smoke.SchemeObject, datum: smoke.SchemeObject) smoke.SchemeObject {
    const p = sim_free.?;
    sim_free = p + abi.ephemeron_size;
    smoke.check(@intFromPtr(sim_free.?) <= @intFromPtr(&sim_heap) + sim_heap_words * @sizeOf(smoke.SchemeObject), "sim heap eph OOM");
    p[0] = abi.marked_ephemeron_manifest;
    p[abi.ephemeron_key] = key;
    p[abi.ephemeron_datum] = datum;
    p[abi.ephemeron_list] = smoke.sharp_f;
    p[abi.ephemeron_next] = smoke.sharp_f;
    return smoke.makePointerObject(smoke.tc_ephemeron, p);
}

fn makeArenaCodeBlock(
    slot6: smoke.SchemeObject,
    slot7: smoke.SchemeObject,
    entry_r: *smoke.SchemeObject,
) [*]smoke.SchemeObject {
    const block = abi.code_arena_alloc(8).?;
    const entry_insn: [*]smoke.Insn = @ptrCast(block + 4);
    var ceo: abi.CcEntryOffset = .{
        .offset = (@intFromPtr(entry_insn) - @intFromPtr(block)) / @sizeOf(smoke.Insn),
        .continued_p = false,
    };

    abi.code_arena_write_begin();
    block[0] = smoke.makeVectorHeader(7);
    block[1] = smoke.makeNmvHeader(4);
    block[2] = 0;
    block[3] = 0;
    block[4] = 0;
    block[5] = 0;
    smoke.check(!abi.write_cc_entry_offset(&ceo, entry_insn), "write_cc_entry_offset");
    block[6] = slot6;
    block[7] = slot7;
    abi.code_arena_write_end();

    entry_r.* = smoke.makeCcEntry(entry_insn);
    smoke.check(abi.cc_entry_to_block_address(entry_r.*) == block, "cc_entry_to_block_address == block");
    return block;
}

fn beginSimGc(roots: []const smoke.SchemeObject) [*]smoke.SchemeObject {
    resetEphemeronTable();
    abi.open_tospace(sim_heap_start.?);
    abi.initialize_weak_chain();
    abi.current_gc_table = abi.std_gc_table();

    const saved_to = abi.get_newspace_ptr();
    for (roots) |r| {
        abi.add_to_tospace(r);
    }

    abi.gc_drain_tospace_and_code_arena(saved_to);
    abi.update_weak_pointers();
    return abi.get_newspace_ptr();
}

fn finishSimGc(new_free: [*]smoke.SchemeObject) void {
    smoke.check(abi.save_tospace(saveTospaceCopy, null), "save_tospace");
    sim_free = new_free;
    smoke.code_arena_sweep();
}

pub fn main() u8 {
    smoke.dstack_initialize();
    smoke.code_arena_setup(2048);
    abi.initialize_gc(sim_heap_words, &sim_heap_start, &sim_free, testAllocateTospace, testAbortGc);

    // 1. Live TC_COMPILED_ENTRY root marks block in place & forwards constants.
    {
        sim_free = sim_heap_start;
        const live_pair = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(77), smoke.sharp_f);
        const old_pair_addr = smoke.objectAddress(live_pair);
        var live_entry: smoke.SchemeObject = undefined;
        const live_block = makeArenaCodeBlock(live_pair, smoke.sharp_f, &live_entry);

        const new_free = beginSimGc(&.{live_entry});
        smoke.check(smoke.brokenHeartP(old_pair_addr[0]), "old_pair broken heart");
        finishSimGc(new_free);

        smoke.check(sim_heap_start.?[0] == live_entry, "relocated root == live_entry");
        smoke.check(smoke.objectType(live_block[0]) == smoke.tc_manifest_vector, "live_block still manifest vector");
        smoke.check(smoke.pairP(live_block[6]), "live_block[6] is pair");
        smoke.check(smoke.objectAddress(live_block[6]) != old_pair_addr, "pair relocated");
        smoke.check(smoke.pairCar(live_block[6]) == smoke.ulongToFixnum(77), "pair car == 77");
        smoke.check(smoke.jit_write_nesting_depth() == 0, "write depth == 0");
        smoke.printf("[1/4] live TC_COMPILED_ENTRY marks in place & forwards constants OK\n", .{});
    }

    // 2. Dead code_arena block is swept & does not pin heap objects.
    {
        sim_free = sim_heap_start;
        const dead_pair = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(88), smoke.sharp_f);
        const dead_pair_addr = smoke.objectAddress(dead_pair);
        var dead_entry: smoke.SchemeObject = undefined;
        const dead_block = makeArenaCodeBlock(dead_pair, smoke.sharp_f, &dead_entry);

        const new_free = beginSimGc(&.{smoke.sharp_t});
        smoke.check(!smoke.brokenHeartP(dead_pair_addr[0]), "dead_pair not transported");
        finishSimGc(new_free);

        smoke.check(sim_heap_start.?[0] == smoke.sharp_t, "sim_heap_start[0] == #t");
        smoke.check(!abi.code_address_p(dead_block) or smoke.objectType(dead_block[0]) == smoke.tc_manifest_nm_vector, "dead_block swept");
        smoke.printf("[2/4] unreferenced code_arena block swept without pinning heap OK\n", .{});
    }

    // 3. TC_WEAK_CONS keeps live code_arena entry and clears dead entry.
    {
        sim_free = sim_heap_start;
        var live_entry: smoke.SchemeObject = undefined;
        var dead_entry: smoke.SchemeObject = undefined;
        const live_block = makeArenaCodeBlock(smoke.sharp_f, smoke.sharp_f, &live_entry);
        const dead_block = makeArenaCodeBlock(smoke.sharp_f, smoke.sharp_f, &dead_entry);
        const wp_live = allocSimPair(smoke.tc_weak_cons, live_entry, smoke.ulongToFixnum(1));
        const wp_dead = allocSimPair(smoke.tc_weak_cons, dead_entry, smoke.ulongToFixnum(2));
        const root_list = allocSimPair(smoke.tc_list, wp_live, allocSimPair(smoke.tc_list, wp_dead, live_entry));

        const new_free = beginSimGc(&.{root_list});
        finishSimGc(new_free);

        const rel_list = sim_heap_start.?[0];
        const rel_wp_live = smoke.pairCar(rel_list);
        const rel_wp_dead = smoke.pairCar(smoke.pairCdr(rel_list));
        smoke.check(smoke.pairCar(rel_wp_live) == live_entry, "weak live retained");
        smoke.check(smoke.pairCar(rel_wp_dead) == smoke.gc_reclaimed, "weak dead cleared");
        smoke.check(smoke.objectType(live_block[0]) == smoke.tc_manifest_vector, "live_block kept");
        smoke.check(!abi.code_address_p(dead_block) or smoke.objectType(dead_block[0]) == smoke.tc_manifest_nm_vector, "dead_block swept");
        smoke.printf("[3/4] TC_WEAK_CONS live retained & dead cleared OK\n", .{});
    }

    // 4. TC_EPHEMERON live/dead code keys + transitive ephemeron->code->ephemeron.
    {
        sim_free = sim_heap_start;
        const k1 = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(101), smoke.sharp_f);
        const k2 = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(202), smoke.sharp_f);
        const val2_pair = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(303), smoke.sharp_f);
        const live_pair = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(404), smoke.sharp_f);
        const dead_pair = allocSimPair(smoke.tc_list, smoke.ulongToFixnum(505), smoke.sharp_f);
        const dead_pair_addr = smoke.objectAddress(dead_pair);

        var live_entry: smoke.SchemeObject = undefined;
        var dead_entry: smoke.SchemeObject = undefined;
        var mid_entry: smoke.SchemeObject = undefined;
        const live_block = makeArenaCodeBlock(smoke.sharp_f, smoke.sharp_f, &live_entry);
        const dead_block = makeArenaCodeBlock(smoke.sharp_f, smoke.sharp_f, &dead_entry);
        const mid_block = makeArenaCodeBlock(k2, smoke.sharp_f, &mid_entry);

        const eph_dead = allocSimEphemeron(dead_entry, dead_pair);
        const eph_live = allocSimEphemeron(live_entry, live_pair);
        const eph1 = allocSimEphemeron(k1, mid_entry);
        const eph2 = allocSimEphemeron(k2, val2_pair);

        const vec = sim_free.?;
        sim_free = vec + 7;
        vec[0] = smoke.makeVectorHeader(6);
        vec[1] = eph_dead;
        vec[2] = eph_live;
        vec[3] = eph1;
        vec[4] = eph2;
        vec[5] = live_entry;
        vec[6] = k1;

        const root_vec = smoke.makePointerObject(smoke.tc_vector, vec);
        const new_free = beginSimGc(&.{root_vec});
        smoke.check(!smoke.brokenHeartP(dead_pair_addr[0]), "dead_pair not transported");
        finishSimGc(new_free);

        const rel_vec = sim_heap_start.?[0];
        const r_eph_dead = smoke.vectorRef(rel_vec, 0);
        const r_eph_live = smoke.vectorRef(rel_vec, 1);
        const r_eph1 = smoke.vectorRef(rel_vec, 2);
        const r_eph2 = smoke.vectorRef(rel_vec, 3);
        const r_k1 = smoke.vectorRef(rel_vec, 5);

        smoke.check(smoke.memoryRef(r_eph_dead, abi.ephemeron_key) == smoke.sharp_f, "eph_dead key cleared");
        smoke.check(smoke.memoryRef(r_eph_dead, abi.ephemeron_datum) == smoke.sharp_f, "eph_dead datum cleared");
        smoke.check(!abi.code_address_p(dead_block) or smoke.objectType(dead_block[0]) == smoke.tc_manifest_nm_vector, "dead_block swept");

        smoke.check(smoke.memoryRef(r_eph_live, abi.ephemeron_key) == live_entry, "eph_live key kept");
        smoke.check(smoke.pairCar(smoke.memoryRef(r_eph_live, abi.ephemeron_datum)) == smoke.ulongToFixnum(404), "eph_live datum 404");
        smoke.check(smoke.objectType(live_block[0]) == smoke.tc_manifest_vector, "live_block kept");

        smoke.check(smoke.memoryRef(r_eph1, abi.ephemeron_key) == r_k1, "eph1 key == r_k1");
        smoke.check(smoke.memoryRef(r_eph1, abi.ephemeron_datum) == mid_entry, "eph1 datum == mid_entry");
        smoke.check(smoke.objectType(mid_block[0]) == smoke.tc_manifest_vector, "mid_block kept");
        smoke.check(smoke.memoryRef(r_eph2, abi.ephemeron_key) == mid_block[6], "eph2 key relocated");
        smoke.check(smoke.pairCar(mid_block[6]) == smoke.ulongToFixnum(202), "k2 car == 202");
        smoke.check(smoke.pairCar(smoke.memoryRef(r_eph2, abi.ephemeron_datum)) == smoke.ulongToFixnum(303), "eph2 datum == 303");
        smoke.printf("[4/4] ephemerons (live/dead code keys + transitive chain) OK\n", .{});
    }

    smoke.code_arena_teardown();
    return 0;
}
