// Smoke test for FASL_VERSION_CODE_SPACE, closure routing, and band compaction.
// Derived from tests/microcode/fasl-code-smoke.c (GPL v2 or later).

const std = @import("std");
const abi = @import("prim_abi");
const smoke = @import("smoke_common.zig");

comptime {
    smoke.exportBaseRuntimeStubs();
    smoke.exportGcOsStubs();
    smoke.exportMinimalCcHelpers();
}

extern "c" fn tmpfile() smoke.FaslFileHandle;
extern "c" fn rewind(smoke.FaslFileHandle) void;
extern "c" fn fclose(smoke.FaslFileHandle) c_int;

const sim_heap_words: usize = 4096;

export var Free: ?[*]smoke.SchemeObject = null;
export var constant_start: ?[*]smoke.SchemeObject = null;
export var compiler_utilities: smoke.SchemeObject = smoke.sharp_f;
export var ephemeron_array: smoke.SchemeObject = smoke.sharp_f;
export var ephemeron_count: usize = 0;

var sim_heap: [sim_heap_words]smoke.SchemeObject align(16) = undefined;
var sim_heap_start: ?[*]smoke.SchemeObject = &sim_heap;
var sim_free: ?[*]smoke.SchemeObject = &sim_heap;

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

fn makeArenaCodeBlock(n_words: usize, entry_r: *smoke.SchemeObject) [*]smoke.SchemeObject {
    const block = abi.code_arena_alloc(n_words).?;
    smoke.check(n_words >= 6, "n_words >= 6");
    const entry_insn: [*]smoke.Insn = @ptrCast(block + 4);
    var ceo: abi.CcEntryOffset = .{
        .offset = (@intFromPtr(entry_insn) - @intFromPtr(block)) / @sizeOf(smoke.Insn),
        .continued_p = false,
    };

    abi.code_arena_write_begin();
    block[0] = smoke.makeVectorHeader(n_words - 1);
    block[1] = smoke.makeNmvHeader(n_words - 2);
    @memset(block[2..n_words], 0);
    smoke.check(!abi.write_cc_entry_offset(&ceo, entry_insn), "write_cc_entry_offset");
    abi.code_arena_write_end();

    entry_r.* = smoke.makeCcEntry(entry_insn);
    smoke.check(abi.cc_entry_to_block_address(entry_r.*) == block, "cc_entry_to_block_address");
    return block;
}

fn makeHeapClosure(
    target: ?*anyopaque,
    slot0: smoke.SchemeObject,
    entry_r: *smoke.SchemeObject,
) [*]smoke.SchemeObject {
    const blk = sim_free.?;
    sim_free = blk + 6;
    smoke.check(@intFromPtr(sim_free.?) <= @intFromPtr(&sim_heap) + sim_heap_words * @sizeOf(smoke.SchemeObject), "sim_heap OOM");
    blk[0] = smoke.makeObject(smoke.tc_manifest_closure, 5);
    blk[1] = 0;
    @as(*u32, @ptrCast(&blk[1])).* = 1;
    blk[2] = 0;
    blk[3] = 0;
    blk[4] = slot0;

    const start = abi.compiled_closure_start(blk + 1);
    const entry0 = abi.compiled_closure_entry(start);
    smoke.check(@intFromPtr(entry0) == @intFromPtr(blk + 3), "entry0 == blk + 3");
    blk[5] = smoke.makeCcEntry(entry0.?);

    var ceo: abi.CcEntryOffset = .{
        .offset = (@intFromPtr(entry0.?) - @intFromPtr(blk)) / @sizeOf(smoke.Insn),
        .continued_p = false,
    };
    smoke.check(!abi.write_cc_entry_offset(&ceo, entry0), "closure write_cc_entry_offset");
    abi.write_compiled_closure_target(target, start);
    entry_r.* = smoke.makeCcEntry(entry0.?);
    return blk;
}

const FixupRec = struct {
    addr: [*]smoke.SchemeObject,
    orig: smoke.SchemeObject,
};

var test_fixups: [128]FixupRec = undefined;
var n_test_fixups: usize = 0;

fn recordAndTransportToCode(
    block: [*]smoke.SchemeObject,
    n_words: usize,
    _: ?*anyopaque,
) callconv(.c) void {
    smoke.check(n_test_fixups < 128, "fixups cap");
    smoke.check(abi.code_tospace_available_p(n_words), "code_tospace_available_p");
    test_fixups[n_test_fixups] = .{ .addr = block, .orig = block[0] };
    n_test_fixups += 1;
    _ = abi.gc_transport_words_to_code_tospace(block, n_words, false);
}

fn testCompactTuple(tuple: smoke.SchemeObject, _: c_uint) callconv(.c) smoke.SchemeObject {
    return tuple;
}

fn testCompactVector(vector: smoke.SchemeObject, _: bool) callconv(.c) smoke.SchemeObject {
    if (smoke.objectType(vector) == smoke.tc_compiled_code_block) {
        const old_addr = smoke.objectAddress(vector);
        if (abi.code_address_p(old_addr) and smoke.brokenHeartP(old_addr[0])) {
            return smoke.objectNewAddress(vector, smoke.objectAddress(old_addr[0]));
        }
    }
    return vector;
}

fn testCompactCcEntry(object: smoke.SchemeObject) callconv(.c) smoke.SchemeObject {
    const old_addr = abi.cc_entry_to_block_address(object);
    if (abi.code_address_p(old_addr) and smoke.brokenHeartP(old_addr[0])) {
        return smoke.ccEntryNewBlock(object, smoke.objectAddress(old_addr[0]), old_addr);
    }
    return object;
}

fn testCompactCcReturn(object: smoke.SchemeObject) callconv(.c) smoke.SchemeObject {
    const old_addr = abi.cc_return_to_block_address(object);
    if (abi.code_address_p(old_addr) and smoke.brokenHeartP(old_addr[0])) {
        return smoke.ccReturnNewBlock(object, smoke.objectAddress(old_addr[0]), old_addr);
    }
    return object;
}

var compact_table_storage: abi.GcTable = undefined;
var compact_table_init_p: bool = false;

fn makeTestCompactTable() *abi.GcTable {
    if (!compact_table_init_p) {
        abi.initialize_gc_table(&compact_table_storage, false);
        compact_table_storage.tuple_handler = testCompactTuple;
        compact_table_storage.vector_handler = testCompactVector;
        compact_table_storage.cc_entry_handler = testCompactCcEntry;
        compact_table_storage.cc_return_handler = testCompactCcReturn;
        compact_table_storage.handlers[smoke.tc_weak_cons] = abi.gc_handle_pair;
        compact_table_storage.handlers[smoke.tc_ephemeron] = abi.gc_handle_unaligned_vector;
        compact_table_storage.handlers[smoke.tc_broken_heart] = abi.gc_handle_non_pointer;
        compact_table_init_p = true;
    }
    return &compact_table_storage;
}

fn restoreTestFixups() void {
    abi.code_arena_write_begin();
    for (test_fixups[0..n_test_fixups]) |rec| {
        rec.addr[0] = rec.orig;
    }
    abi.code_arena_write_end();
    n_test_fixups = 0;
}

fn copyOutTospace(
    start: [*]smoke.SchemeObject,
    end: [*]smoke.SchemeObject,
    p: ?*anyopaque,
) callconv(.c) bool {
    const dst: [*]smoke.SchemeObject = @ptrCast(@alignCast(p.?));
    const n_words = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(smoke.SchemeObject);
    @memcpy(dst[0..n_words], start[0..n_words]);
    return true;
}

pub fn main() u8 {
    smoke.dstack_initialize();
    abi.initialize_gc(sim_heap_words, &sim_heap_start, &sim_free, testAllocateTospace, testAbortGc);

    // 1. FASL_VERSION_CODE_SPACE (13) header round-trip.
    {
        var out_h: smoke.FaslHeader = std.mem.zeroes(smoke.FaslHeader);
        var in_h: smoke.FaslHeader = std.mem.zeroes(smoke.FaslHeader);
        const f = tmpfile();
        smoke.check(f != null, "tmpfile");

        out_h.version = smoke.fasl_version_code_space;
        out_h.arch = smoke.currentFaslArch();
        out_h.cc_version = smoke.compiler_interface_version_value;
        out_h.cc_arch = @import("build_options").compiler_processor_type;
        out_h.band_p = true;
        out_h.memory_base = null;
        out_h.heap_start = @ptrFromInt(0x100000000);
        out_h.heap_end = @ptrFromInt(0x100008000);
        out_h.root_pointer = out_h.heap_start;
        out_h.heap_reserved = 4500;
        out_h.constant_start = @ptrFromInt(0x100010000);
        out_h.constant_end = @ptrFromInt(0x100012000);
        out_h.code_start = @ptrFromInt(0x104000000);
        out_h.code_end = @ptrFromInt(0x104020000);
        out_h.stack_start = @ptrFromInt(0x100020000);
        out_h.stack_end = @ptrFromInt(0x100024000);
        out_h.n_primitives = 5;
        out_h.primitive_table_size = 12;
        out_h.utilities_vector = smoke.sharp_f;
        out_h.ephemeron_count = 7;

        smoke.check(smoke.write_fasl_header(&out_h, f), "write_fasl_header");
        rewind(f);
        smoke.check(smoke.read_fasl_header(&in_h, f), "read_fasl_header");
        smoke.check(smoke.check_fasl_version(&in_h) == smoke.fasl_file_fine, "check_fasl_version");
        smoke.check(in_h.version == smoke.fasl_version_code_space, "version 13");
        smoke.check(in_h.code_start == out_h.code_start, "code_start");
        smoke.check(in_h.code_end == out_h.code_end, "code_end");
        smoke.check(in_h.ephemeron_count == 7, "ephemeron_count == 7");
        _ = fclose(f);
        smoke.printf("[1/5] FASL_VERSION_CODE_SPACE header round-trip OK\n", .{});
    }

    // 2. Backward-compatible FASL_VERSION_C_CODE (10) defaults.
    {
        var out_h: smoke.FaslHeader = std.mem.zeroes(smoke.FaslHeader);
        var in_h: smoke.FaslHeader = undefined;
        @memset(std.mem.asBytes(&in_h), 0xff);
        const f = tmpfile();
        smoke.check(f != null, "tmpfile");

        out_h.version = smoke.fasl_version_c_code;
        out_h.arch = smoke.currentFaslArch();
        out_h.cc_version = smoke.compiler_interface_version_value;
        out_h.cc_arch = @import("build_options").compiler_processor_type;
        out_h.band_p = false;
        out_h.heap_start = @ptrFromInt(0x100000000);
        out_h.heap_end = @ptrFromInt(0x100001000);
        out_h.root_pointer = out_h.heap_start;
        out_h.utilities_vector = smoke.sharp_f;
        out_h.ephemeron_count = 99;

        smoke.check(smoke.write_fasl_header(&out_h, f), "write_fasl_header v10");
        rewind(f);
        smoke.check(smoke.read_fasl_header(&in_h, f), "read_fasl_header v10");
        smoke.check(smoke.check_fasl_version(&in_h) == smoke.fasl_file_fine, "check_fasl_version v10");
        smoke.check(in_h.version == smoke.fasl_version_c_code, "version 10");
        smoke.check(in_h.code_start == null and in_h.code_end == null, "v10 code range null");
        smoke.check(in_h.ephemeron_count == 0, "v10 ephemeron_count == 0");
        _ = fclose(f);
        smoke.printf("[2/5] FASL_VERSION_C_CODE (10) defaults OK\n", .{});
    }

    // 3. ASLR-safe faslhdr_utilities_end + code_arena_reset/mark_hole.
    {
        smoke.code_arena_setup(2048);
        const util_blk = abi.code_arena_alloc(16).?;
        abi.code_arena_write_begin();
        util_blk[0] = smoke.makeVectorHeader(15);
        abi.code_arena_write_end();
        compiler_utilities = smoke.makeCcBlock(util_blk);

        var aslr_h: smoke.FaslHeader = std.mem.zeroes(smoke.FaslHeader);
        aslr_h.utilities_start = @ptrFromInt(0x700012340000);
        aslr_h.utilities_vector = smoke.makeCcBlock(aslr_h.utilities_start.?);

        const util_end = smoke.faslhdr_utilities_end(&aslr_h);
        smoke.check(util_end == aslr_h.utilities_start.? + 16, "aslr util_end");

        smoke.code_arena_reset(4096);
        smoke.check(smoke.code_arena_chunk_count() == 1, "chunk_count 1");
        smoke.check((@intFromPtr(smoke.code_end) - @intFromPtr(smoke.code_start)) / @sizeOf(smoke.SchemeObject) >= 4096, "reset cap >= 4096");
        smoke.check(smoke.code_alloc_next == smoke.code_start, "code_alloc_next == code_start");

        const hole = abi.code_arena_alloc(10).?;
        abi.code_arena_write_begin();
        hole[0] = smoke.makeVectorHeader(9);
        abi.code_arena_write_end();
        smoke.code_arena_mark_hole(hole, 10);
        smoke.check(smoke.objectType(hole[0]) == smoke.tc_manifest_nm_vector, "hole NMV");
        smoke.check(1 + smoke.objectDatum(hole[0]) == 10, "hole length 10");

        smoke.code_arena_teardown();
        compiler_utilities = smoke.sharp_f;
        smoke.printf("[3/5] ASLR-safe faslhdr_utilities_end + code_arena_reset OK\n", .{});
    }

    // 4. TC_MANIFEST_CLOSURE stays in heap while code target goes to code_tospace.
    if (comptime @import("build_options").cc_is_native) {
        sim_free = sim_heap_start;
        smoke.code_arena_setup(2048);
        var code_entry: smoke.SchemeObject = undefined;
        const code_blk = makeArenaCodeBlock(8, &code_entry);
        var cls_entry: smoke.SchemeObject = undefined;
        const cls_blk = makeHeapClosure(smoke.ccEntryAddress(code_entry), smoke.ulongToFixnum(123), &cls_entry);
        smoke.check(!abi.code_address_p(cls_blk), "closure not in code_arena");
        smoke.check(abi.code_address_p(code_blk), "code_blk in code_arena");

        abi.open_tospace(sim_heap_start.?);
        smoke.check(abi.open_code_tospace(64), "open_code_tospace");
        _ = abi.gc_transport_words(cls_blk, 6, true);
        recordAndTransportToCode(code_blk, 8, null);

        var heap_scan = sim_heap_start.?;
        var code_scan = abi.get_code_newspace_start();
        abi.current_gc_table = makeTestCompactTable();
        while (@intFromPtr(heap_scan) < @intFromPtr(abi.get_newspace_ptr()) or
            @intFromPtr(code_scan) < @intFromPtr(abi.get_code_newspace_ptr()))
        {
            if (@intFromPtr(heap_scan) < @intFromPtr(abi.get_newspace_ptr())) {
                const target = abi.get_newspace_ptr();
                abi.gc_scan_tospace(heap_scan, target);
                heap_scan = target;
            }
            if (@intFromPtr(code_scan) < @intFromPtr(abi.get_code_newspace_ptr())) {
                const target = abi.get_code_newspace_ptr();
                abi.gc_scan_code_tospace(code_scan, target);
                code_scan = target;
            }
        }

        const new_code_blk = abi.get_code_newspace_start();
        smoke.check(abi.get_code_newspace_ptr() == new_code_blk + 8, "new_code_blk len 8");
        var dumped_heap: [16]smoke.SchemeObject align(16) = undefined;
        smoke.check(abi.save_tospace(copyOutTospace, &dumped_heap), "save_tospace");
        restoreTestFixups();

        smoke.check(smoke.objectType(dumped_heap[0]) == smoke.tc_manifest_closure, "dumped_heap closure");
        smoke.check(!abi.code_address_p(&dumped_heap), "dumped closure in heap");
        var ref: abi.RelocRef = .{
            .old_addr = smoke.ccEntryAddress(dumped_heap[5]),
            .new_addr = abi.compiled_closure_entry(abi.compiled_closure_start(dumped_heap[1..].ptr)),
        };
        const read_target = abi.read_compiled_closure_target(abi.compiled_closure_start(dumped_heap[1..].ptr), &ref);
        const target_pc: [*]smoke.Insn = @ptrCast(new_code_blk + 4);
        smoke.check(@intFromPtr(read_target) == @intFromPtr(target_pc), "read_target == target_pc");

        const fresh_code_blk = abi.code_arena_alloc(8).?;
        abi.code_arena_write_begin();
        const reloaded_src: [*]smoke.SchemeObject = @ptrCast(@alignCast(abi.newspace_to_tospace(@ptrCast(new_code_blk)).?));
        @memcpy(fresh_code_blk[0..8], reloaded_src[0..8]);
        abi.code_arena_write_end();

        abi.code_arena_mark_begin();
        smoke.check(abi.code_arena_mark_block(fresh_code_blk), "mark fresh_code_blk");
        smoke.code_arena_sweep();
        smoke.check(smoke.objectType(fresh_code_blk[0]) == smoke.tc_manifest_vector, "fresh kept");
        smoke.check(smoke.objectType(code_blk[0]) == smoke.tc_manifest_nm_vector, "old code_blk swept");

        abi.discard_code_tospace();
        smoke.code_arena_teardown();
        smoke.printf("[4/5] closure in heap + target block in code_arena OK\n", .{});
    } else {
        smoke.printf("[4/5] skipped closure heap/code_arena test (non-native)\n", .{});
    }

    // 5. Multi-chunk code_arena compaction preserves cross-chunk closure targets.
    if (comptime @import("build_options").cc_is_native) {
        sim_free = sim_heap_start;
        smoke.code_arena_setup(2048);
        var entry_a: smoke.SchemeObject = undefined;
        var entry_b: smoke.SchemeObject = undefined;
        _ = makeArenaCodeBlock(8, &entry_a);
        const blk_b = makeArenaCodeBlock(4096, &entry_b);
        smoke.check(abi.code_address_p(blk_b), "blk_b in overflow chunk");
        smoke.check(smoke.code_arena_nonempty_chunk_count() == 2, "2 nonempty chunks");

        var cls_entry: smoke.SchemeObject = undefined;
        const cls_blk = makeHeapClosure(smoke.ccEntryAddress(entry_b), smoke.ulongToFixnum(55), &cls_entry);
        const heap_words = (@intFromPtr(sim_free.?) - @intFromPtr(sim_heap_start.?)) / @sizeOf(smoke.SchemeObject);
        smoke.check(heap_words == 6, "heap_words == 6");

        smoke.check(abi.open_code_tospace(smoke.code_arena_live_words() + 64), "open_code_tospace");
        n_test_fixups = 0;
        smoke.code_arena_for_each_live_block(recordAndTransportToCode, null);
        smoke.check(n_test_fixups == 2, "2 live blocks transported");

        const code_words = (@intFromPtr(abi.get_code_newspace_ptr()) - @intFromPtr(abi.get_code_newspace_start())) / @sizeOf(smoke.SchemeObject);
        smoke.check(code_words == 8 + 4096, "code_words == 4104");

        var staged_heap: [16]smoke.SchemeObject align(16) = undefined;
        @memcpy(staged_heap[0..heap_words], sim_heap_start.?[0..heap_words]);
        abi.open_stage_tospace(sim_heap_start.?, &staged_heap, heap_words);
        abi.current_gc_table = makeTestCompactTable();
        abi.gc_scan_stage_tospace();
        abi.close_stage_tospace();

        abi.gc_scan_code_tospace(abi.get_code_newspace_start(), abi.get_code_newspace_ptr());

        var compacted_code: [128]smoke.SchemeObject align(16) = undefined;
        const compacted_src: [*]smoke.SchemeObject = @ptrCast(@alignCast(abi.newspace_to_tospace(@ptrCast(abi.get_code_newspace_start())).?));
        @memcpy(compacted_code[0..16], compacted_src[0..16]);
        restoreTestFixups();

        var ref: abi.RelocRef = .{
            .old_addr = smoke.ccEntryAddress(cls_blk[5]),
            .new_addr = abi.compiled_closure_entry(abi.compiled_closure_start(staged_heap[1..].ptr)),
        };
        const resolved = abi.read_compiled_closure_target(abi.compiled_closure_start(staged_heap[1..].ptr), &ref);
        const compacted_b_entry: [*]smoke.Insn = @ptrCast(abi.get_code_newspace_start() + 8 + 4);
        smoke.check(@intFromPtr(resolved) == @intFromPtr(compacted_b_entry), "cross-chunk target resolved");

        abi.discard_code_tospace();
        smoke.code_arena_reset(code_words + 64);
        smoke.check(smoke.code_arena_nonempty_chunk_count() == 0, "0 nonempty chunks after reset");
        const reloaded = abi.code_arena_alloc(code_words).?;
        abi.code_arena_write_begin();
        reloaded[0] = smoke.makeVectorHeader(7);
        (reloaded + 8)[0] = smoke.makeVectorHeader(4095);
        abi.code_arena_write_end();
        smoke.check(smoke.code_arena_nonempty_chunk_count() == 1, "1 compacted chunk");

        smoke.code_arena_teardown();
        smoke.printf("[5/5] multi-chunk code_arena compaction OK\n", .{});
    } else {
        smoke.printf("[5/5] skipped multi-chunk compaction closure test (non-native)\n", .{});
    }

    return 0;
}
