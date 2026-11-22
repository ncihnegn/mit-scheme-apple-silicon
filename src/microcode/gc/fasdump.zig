// Derived from MIT/GNU Scheme C sources (`src/microcode/fasdump.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const outf = @import("../support/outf.zig");
const fasl = @import("fasl.zig");
const code_arena = @import("../compiler/code_arena.zig");
const transact = @import("../support/transact.zig");
const wind = @import("../support/wind.zig");
const primutl = @import("../runtime/primutl.zig");
const string = @import("../data/string.zig");
const storage = @import("../core/storage.zig");
const utils = @import("../core/utils.zig");
const md5 = @import("../crypto/md5.zig");

const EnvMode = enum {
    fe_error,
    fe_dump,
    fe_drop_cc,
};

const FaslFileInfo = struct {
    filename: [*:0]const u8,
    handle: fasl.FaslFileHandle,
};

const Fixup = struct {
    addr: [*]obj.SchemeObject,
    object: obj.SchemeObject,
};

const BandCompactCtx = struct {
    heap_buf: ?[*]obj.SchemeObject,
    const_buf: ?[*]obj.SchemeObject,
};

var fasl_header: fasl.FaslHeader = undefined;
var fh: *fasl.FaslHeader = &fasl_header;
var current_env_mode: EnvMode = .fe_error;
var current_pr: ?*primutl.PrimRenumber = null;
var cc_seen_p: bool = false;
var dumped_ephemeron_count: usize = 0;

var fasdump_table_initialized: bool = false;
var fasdump_table_storage: abi.GcTable = undefined;
var band_compact_table_initialized: bool = false;
var band_compact_table_storage: abi.GcTable = undefined;

var fixups_start: ?[*]Fixup = null;
var fixups_next: usize = 0;
var fixups_cap: usize = 0;

var saved_free: ?[*]obj.SchemeObject = null;
var saved_heap_alloc_limit: ?[*]obj.SchemeObject = null;
var saved_heap_start: ?[*]obj.SchemeObject = null;
var saved_heap_end: ?[*]obj.SchemeObject = null;
var saved_stack_pointer: ?[*]obj.SchemeObject = null;
var saved_stack_guard: ?[*]obj.SchemeObject = null;
var saved_stack_start: ?[*]obj.SchemeObject = null;
var saved_stack_end: ?[*]obj.SchemeObject = null;
var saved_constant_alloc_next: ?[*]obj.SchemeObject = null;
var saved_constant_start: ?[*]obj.SchemeObject = null;
var saved_constant_end: ?[*]obj.SchemeObject = null;
var fasdump_has_original_digest: bool = false;
var fasdump_original_digest: [md5.hash_len]u8 = @splat(0);

inline fn ptrAddr(p: anytype) usize {
    return if (@typeInfo(@TypeOf(p)) == .optional)
        (if (p) |nonnull| @intFromPtr(nonnull) else 0)
    else
        @intFromPtr(p);
}

inline fn stringArg(n: c_int) [*:0]const u8 {
    const val = abi.argRef(@intCast(n));
    if (!string.string_p(val)) {
        abi.error_wrong_type_arg(n);
    }
    return @ptrCast(obj.legacyStringData(val));
}

inline fn ccNewBlock(
    entry: obj.SchemeObject,
    new_block: [*]obj.SchemeObject,
    old_block: [*]obj.SchemeObject,
) obj.SchemeObject {
    const byte_offset = @intFromPtr(obj.objectRawAddress(entry)) - @intFromPtr(old_block);
    return obj.objectNewRawAddress(entry, @intFromPtr(new_block) + byte_offset);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-FASDUMP", Prim_prim_fasdump, 3, 3,
//   "(OBJECT NAMESTRING FLAG)\n\
// Writes a binary representation of OBJECT to the file NAMESTRING.\n\
// Returns #T if the operation is successful, or #F otherwise.\n\
// \n\
// FLAG specifies how to handle environment objects that OBJECT points\n\
// to: #F means generate an error; #T means write them as ordinary\n\
// objects; any other value is like #F except that environments pointed\n\
// at by compiled code are ignored (and discarded).")
pub export fn Prim_prim_fasdump() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();

    if (build_options.debugging) {
        saveGcVars();
        saveMemoryChecksum();
    }

    transact.transaction_begin(); // 1
    var ff_info: FaslFileInfo = .{
        .filename = stringArg(2),
        .handle = null,
    };
    if (!fasl.open_fasl_output_file(ff_info.filename, &ff_info.handle)) {
        abi.error_bad_range_arg(2);
    }
    transact.transaction_record_action(.tat_always, &closeFaslFile, @ptrCast(&ff_info));

    abi.open_tospace(abi.heap_start);
    // This must be _before_ initializeFixups():
    transact.transaction_record_action(.tat_abort, &abortFasdump, null);
    const max_code_words = code_arena.code_arena_live_words() +
        fasl.ptrRangeWords(abi.Free, abi.heap_start) +
        fasl.ptrRangeWords(abi.constant_alloc_next, abi.constant_start) +
        1024;
    if (!abi.open_code_tospace(max_code_words)) {
        abi.signal_error_from_primitive(abi.err_fasdump_object_too_large);
    }
    initializeFixups();

    const new_heap_start = abi.get_newspace_ptr();
    abi.add_to_tospace(abi.argRef(1));
    dumped_ephemeron_count = 0;

    transact.transaction_begin(); // 2

    abi.current_gc_table = @ptrCast(fasdumpTable());
    const flag = abi.argRef(3);
    current_env_mode = if (flag == obj.sharp_f)
        .fe_error
    else if (flag == obj.sharp_t)
        .fe_dump
    else
        .fe_drop_cc;
    current_pr = primutl.make_prim_renumber();
    cc_seen_p = false;

    var heap_scan = new_heap_start;
    var code_scan = abi.get_code_newspace_start();
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

    const new_heap_end = abi.get_newspace_ptr();
    const new_code_start = abi.get_code_newspace_start();
    const new_code_end = abi.get_code_newspace_ptr();

    const prim_table_start = new_heap_end;
    const pr = current_pr.?;
    const prim_table_length = primutl.renumbered_primitives_export_length(pr);
    abi.increment_tospace_ptr(prim_table_length);
    primutl.export_renumbered_primitives(@ptrCast(@alignCast(abi.newspace_to_tospace(@ptrCast(prim_table_start)).?)), pr);
    const n_primitives = pr.next_code;
    current_pr = null;

    transact.transaction_commit(); // 2

    initializeFaslHeader(cc_seen_p, false);
    fh.constant_start = new_heap_start;
    fh.constant_end = new_heap_start;
    fh.heap_start = new_heap_start;
    fh.heap_end = new_heap_end;
    fh.code_start = new_code_start;
    fh.code_end = new_code_end;
    fh.root_pointer = new_heap_start;
    fh.n_primitives = n_primitives;
    fh.primitive_table_size = prim_table_length;
    finalizeFaslHeader(dumped_ephemeron_count);

    const ok = fasl.write_fasl_header(fh, ff_info.handle) and
        abi.save_tospace(&saveFasdumpTospace, @ptrCast(&ff_info));
    abi.discard_code_tospace();
    transact.transaction_commit(); // 1

    if (build_options.debugging) {
        compareGcVars();
        compareMemoryChecksum();
    }

    return obj.booleanToObject(ok);
}

fn closeFaslFile(p: ?*anyopaque) callconv(.c) void {
    const ff_info: *const FaslFileInfo = @ptrCast(@alignCast(p.?));
    if (!fasl.close_fasl_output_file(ff_info.handle)) {
        abi.OS_file_remove(ff_info.filename);
    }
}

fn abortFasdump(_: ?*anyopaque) callconv(.c) void {
    abi.discard_code_tospace();
    abi.discard_tospace();
}

fn saveFasdumpTospace(start: [*]obj.SchemeObject, end: [*]obj.SchemeObject, p: ?*anyopaque) callconv(.c) bool {
    const ff_info: *const FaslFileInfo = @ptrCast(@alignCast(p.?));
    const heap_words = fasl.ptrRangeWords(fh.heap_end, fh.heap_start);
    const code_words = fasl.ptrRangeWords(fh.code_end, fh.code_start);
    const prim_words = fh.primitive_table_size;

    if (fasl.ptrRangeWords(end, start) != heap_words + prim_words) {
        return false;
    }
    if (!fasl.write_to_fasl_file(@ptrCast(start), @intCast(heap_words), ff_info.handle)) {
        return false;
    }
    if (code_words > 0) {
        if (!fasl.write_to_fasl_file(abi.newspace_to_tospace(@ptrCast(fh.code_start)), @intCast(code_words), ff_info.handle)) {
            return false;
        }
    }
    return fasl.write_to_fasl_file(@ptrCast(start + @as(usize, @intCast(heap_words))), @intCast(prim_words), ff_info.handle);
}

fn saveGcVars() void {
    saved_free = storage.Free;
    saved_heap_alloc_limit = storage.heap_alloc_limit;
    saved_heap_start = storage.heap_start;
    saved_heap_end = storage.heap_end;
    saved_stack_pointer = storage.stack_pointer;
    saved_stack_guard = storage.stack_guard;
    saved_stack_start = storage.stack_start;
    saved_stack_end = storage.stack_end;
    saved_constant_alloc_next = storage.constant_alloc_next;
    saved_constant_start = storage.constant_start;
    saved_constant_end = storage.constant_end;
}

inline fn compareGcVar(name: [*:0]const u8, saved: ?[*]obj.SchemeObject, current: ?[*]obj.SchemeObject) void {
    if (ptrAddr(saved) != ptrAddr(current)) {
        outf.err(
            "GC variable changed: {s}: 0x{x} -> 0x{x}\n",
            .{ name, ptrAddr(saved), ptrAddr(current) },
        );
    }
}

fn compareGcVars() void {
    compareGcVar("Free", saved_free, storage.Free);
    compareGcVar("heap_alloc_limit", saved_heap_alloc_limit, storage.heap_alloc_limit);
    compareGcVar("heap_start", saved_heap_start, storage.heap_start);
    compareGcVar("heap_end", saved_heap_end, storage.heap_end);
    compareGcVar("stack_pointer", saved_stack_pointer, storage.stack_pointer);
    compareGcVar("stack_guard", saved_stack_guard, storage.stack_guard);
    compareGcVar("stack_start", saved_stack_start, storage.stack_start);
    compareGcVar("stack_end", saved_stack_end, storage.stack_end);
    compareGcVar("constant_alloc_next", saved_constant_alloc_next, storage.constant_alloc_next);
    compareGcVar("constant_start", saved_constant_start, storage.constant_start);
    compareGcVar("constant_end", saved_constant_end, storage.constant_end);
}

fn computeMemoryChecksum(out: *[md5.hash_len]u8) void {
    var ctx: md5.Md5 = undefined;
    md5.md5_init(&ctx);

    if (ptrAddr(saved_constant_alloc_next) > ptrAddr(saved_constant_start)) {
        const bytes = ptrAddr(saved_constant_alloc_next) - ptrAddr(saved_constant_start);
        md5.md5_update(&ctx, @ptrCast(saved_constant_start.?), bytes);
    }
    if (ptrAddr(saved_free) > ptrAddr(saved_heap_start)) {
        const bytes = ptrAddr(saved_free) - ptrAddr(saved_heap_start);
        md5.md5_update(&ctx, @ptrCast(saved_heap_start.?), bytes);
    }
    if (code_arena.code_start != null and ptrAddr(code_arena.code_alloc_next) > ptrAddr(code_arena.code_start)) {
        const bytes = ptrAddr(code_arena.code_alloc_next) - ptrAddr(code_arena.code_start);
        md5.md5_update(&ctx, @ptrCast(code_arena.code_start.?), bytes);
    }

    md5.md5_final(&ctx, out);
}

fn saveMemoryChecksum() void {
    computeMemoryChecksum(&fasdump_original_digest);
    fasdump_has_original_digest = true;
}

fn compareMemoryChecksum() void {
    if (fasdump_has_original_digest) {
        fasdump_has_original_digest = false;
        var digest: [md5.hash_len]u8 = undefined;
        computeMemoryChecksum(&digest);
        if (!std.mem.eql(u8, &digest, &fasdump_original_digest)) {
            outf.err("Memory mismatch after fasdump.", .{});
        }
    }
}

fn fasdumpTable() *abi.GcTable {
    if (!fasdump_table_initialized) {
        abi.initialize_gc_table(&fasdump_table_storage, true);

        fasdump_table_storage.cc_entry_handler = &fasdumpCcEntry;
        fasdump_table_storage.cc_return_handler = &fasdumpCcReturn;
        fasdump_table_storage.precheck_from = &fasdumpPrecheckFrom;
        fasdump_table_storage.transport_words = &fasdumpTransportWords;

        fasdump_table_storage.handlers[obj.tc_compiled_code_block] = &handleCompiledCodeBlock;
        fasdump_table_storage.handlers[obj.tc_primitive] = &handlePrimitive;
        fasdump_table_storage.handlers[obj.tc_manifest_closure] = &handleManifestClosure;
        fasdump_table_storage.handlers[obj.tc_linkage_section] = &handleLinkageSection;
        fasdump_table_storage.handlers[obj.tc_interned_symbol] = &handleSymbol;
        fasdump_table_storage.handlers[obj.tc_broken_heart] = &handleBrokenHeart;
        fasdump_table_storage.handlers[obj.tc_uninterned_symbol] = &handleSymbol;
        fasdump_table_storage.handlers[obj.tc_environment] = &handleEnvironment;
        fasdump_table_storage.handlers[obj.tc_weak_cons] = &abi.gc_handle_pair;
        fasdump_table_storage.handlers[obj.tc_ephemeron] = &handleEphemeron;

        fasdump_table_initialized = true;
    }
    return &fasdump_table_storage;
}

fn fasdumpTransportCcBlock(old_addr: [*]obj.SchemeObject) [*]obj.SchemeObject {
    if (abi.compiler_utilities != obj.sharp_f and
        @intFromPtr(old_addr) == @intFromPtr(obj.objectAddress(abi.compiler_utilities)))
    {
        return old_addr;
    }
    var new_addr = fasdumpPrecheckFrom(old_addr);
    if (new_addr == null) {
        const length = obj.objectDatum(old_addr[0]);
        if (obj.objectType(old_addr[0]) == obj.tc_manifest_closure) {
            new_addr = fasdumpTransportWords(old_addr, 1 + length, true);
        } else {
            const transported = fasdumpTransportCodeWords(old_addr, 1 + length, true);
            const eptr = transported + @as(usize, @intCast(length));
            if (current_env_mode == .fe_drop_cc and obj.objectType(abi.read_tospace(eptr)) == obj.tc_environment) {
                abi.write_tospace(eptr, obj.sharp_f);
            }
            new_addr = transported;
        }
    }
    return new_addr.?;
}

fn fasdumpCcEntry(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (build_options.cc_support) {
        cc_seen_p = true;
        const old_addr = abi.cc_entry_to_block_address(object);
        const new_addr = fasdumpTransportCcBlock(old_addr);
        return ccNewBlock(object, new_addr, old_addr);
    }
    abi.gc_no_cc_support();
}

fn fasdumpCcReturn(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (build_options.cc_support) {
        cc_seen_p = true;
        const old_addr = abi.cc_return_to_block_address(object);
        const new_addr = fasdumpTransportCcBlock(old_addr);
        return ccNewBlock(object, new_addr, old_addr);
    }
    abi.gc_no_cc_support();
}

fn handleCompiledCodeBlock(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (build_options.cc_support) {
        cc_seen_p = true;
        const old_addr = obj.objectAddress(object);
        const new_addr = fasdumpTransportCcBlock(old_addr);
        scan[0] = obj.objectNewAddress(object, new_addr);
        return scan + 1;
    }
    abi.gc_no_cc_support();
}

fn fasdumpPrecheckFrom(from: [*]obj.SchemeObject) callconv(.c) ?[*]obj.SchemeObject {
    return if (obj.brokenHeartP(from[0])) obj.objectAddress(from[0]) else null;
}

fn fasdumpTransportWords(from: [*]obj.SchemeObject, n_words: usize, align_p: bool) callconv(.c) [*]obj.SchemeObject {
    // Signal error here if insufficient space -- otherwise gc_transport_words() might terminate the microcode.
    if (!abi.tospace_available_p(n_words)) {
        abi.signal_error_from_primitive(abi.err_fasdump_object_too_large);
    }
    addFixup(from);
    return abi.gc_transport_words(from, n_words, align_p);
}

fn fasdumpTransportCodeWords(from: [*]obj.SchemeObject, n_words: usize, align_p: bool) callconv(.c) [*]obj.SchemeObject {
    if (!abi.code_tospace_available_p(n_words)) {
        abi.signal_error_from_primitive(abi.err_fasdump_object_too_large);
    }
    addFixup(from);
    return abi.gc_transport_words_to_code_tospace(from, n_words, align_p);
}

fn handlePrimitive(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = primutl.renumber_primitive(object, current_pr.?);
    return scan + 1;
}

fn handleManifestClosure(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    cc_seen_p = true;
    return abi.gc_handle_manifest_closure(scan, object);
}

fn handleLinkageSection(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    cc_seen_p = true;
    return abi.gc_handle_linkage_section(scan, object);
}

fn handleSymbol(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    const from = obj.objectAddress(object);
    var new_address = fasdumpPrecheckFrom(from);
    if (new_address == null) {
        new_address = fasdumpTransportWords(from, 2, false);
        abi.write_tospace(
            new_address.? + 1,
            if (obj.objectType(object) == obj.tc_interned_symbol) obj.broken_heart_zero else obj.unbound_object,
        );
    }
    scan[0] = obj.objectNewAddress(object, new_address.?);
    return scan + 1;
}

fn handleBrokenHeart(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (obj.objectDatum(object) == 0) {
        return scan + 1;
    }
    return abi.gc_handle_broken_heart(scan, object);
}

fn handleEnvironment(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (current_env_mode != .fe_dump) {
        abi.signal_error_from_primitive(abi.err_fasdump_environment);
    }
    const tbl: *const abi.GcTable = @ptrCast(@alignCast(abi.current_gc_table.?));
    scan[0] = tbl.vector_handler.?(object, false);
    return scan + 1;
}

fn handleEphemeron(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    // Count each one once by counting only if there is no broken heart.
    if (fasdumpPrecheckFrom(obj.objectAddress(object)) == null) {
        dumped_ephemeron_count += 1;
    }
    return abi.gc_handle_unaligned_vector(scan, object);
}

fn initializeFixups() void {
    const cap: usize = 64;
    const raw = abi.OS_malloc(cap * @sizeOf(Fixup)).?;
    fixups_start = @ptrCast(@alignCast(raw));
    fixups_next = 0;
    fixups_cap = cap;
    transact.transaction_record_action(.tat_always, &runFixups, null);
}

fn addFixup(addr: [*]obj.SchemeObject) void {
    if (fixups_next >= fixups_cap) {
        const new_cap = fixups_cap * 2;
        const raw = abi.OS_realloc(@ptrCast(fixups_start.?), new_cap * @sizeOf(Fixup)).?;
        fixups_start = @ptrCast(@alignCast(raw));
        fixups_cap = new_cap;
    }
    const arr = fixups_start.?;
    arr[fixups_next] = .{
        .addr = addr,
        .object = addr[0],
    };
    fixups_next += 1;
}

fn runFixups(_: ?*anyopaque) callconv(.c) void {
    const arr = fixups_start orelse return;
    code_arena.code_arena_write_begin();
    for (0..fixups_next) |i| {
        arr[i].addr[0] = arr[i].object;
    }
    code_arena.code_arena_write_end();
    abi.OS_free(@ptrCast(arr));
    fixups_start = null;
    fixups_next = 0;
    fixups_cap = 0;
}

fn bandCompactTuple(tuple: obj.SchemeObject, _: c_uint) callconv(.c) obj.SchemeObject {
    return tuple;
}

fn bandCompactVector(vector: obj.SchemeObject, _: bool) callconv(.c) obj.SchemeObject {
    if (obj.objectType(vector) == obj.tc_compiled_code_block) {
        const old_addr = obj.objectAddress(vector);
        if (code_arena.code_address_p(@ptrCast(old_addr)) and obj.brokenHeartP(old_addr[0])) {
            return obj.objectNewAddress(vector, obj.objectAddress(old_addr[0]));
        }
    }
    return vector;
}

fn bandCompactCcEntry(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (build_options.cc_support) {
        const old_addr = abi.cc_entry_to_block_address(object);
        if (code_arena.code_address_p(@ptrCast(old_addr)) and obj.brokenHeartP(old_addr[0])) {
            return ccNewBlock(object, obj.objectAddress(old_addr[0]), old_addr);
        }
    }
    return object;
}

fn bandCompactCcReturn(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (build_options.cc_support) {
        const old_addr = abi.cc_return_to_block_address(object);
        if (code_arena.code_address_p(@ptrCast(old_addr)) and obj.brokenHeartP(old_addr[0])) {
            return ccNewBlock(object, obj.objectAddress(old_addr[0]), old_addr);
        }
    }
    return object;
}

fn bandCompactTable() *abi.GcTable {
    if (!band_compact_table_initialized) {
        abi.initialize_gc_table(&band_compact_table_storage, false);

        band_compact_table_storage.tuple_handler = &bandCompactTuple;
        band_compact_table_storage.vector_handler = &bandCompactVector;
        band_compact_table_storage.cc_entry_handler = &bandCompactCcEntry;
        band_compact_table_storage.cc_return_handler = &bandCompactCcReturn;

        band_compact_table_storage.handlers[obj.tc_weak_cons] = &abi.gc_handle_pair;
        band_compact_table_storage.handlers[obj.tc_ephemeron] = &abi.gc_handle_unaligned_vector;
        band_compact_table_storage.handlers[obj.tc_broken_heart] = &abi.gc_handle_non_pointer;

        band_compact_table_initialized = true;
    }
    return &band_compact_table_storage;
}

fn bandCompactTransportBlock(block: [*]obj.SchemeObject, n_words: usize, _: ?*anyopaque) callconv(.c) void {
    if (!abi.code_tospace_available_p(n_words)) {
        abi.signal_error_from_primitive(abi.err_fasdump_object_too_large);
    }
    addFixup(block);
    _ = abi.gc_transport_words_to_code_tospace(block, n_words, false);
}

fn cleanupBandCompact(p: ?*anyopaque) callconv(.c) void {
    const ctx: *BandCompactCtx = @ptrCast(@alignCast(p.?));
    abi.close_stage_tospace();
    abi.discard_code_tospace();
    if (ctx.const_buf) |buf| {
        abi.OS_free(@ptrCast(buf));
        ctx.const_buf = null;
    }
    if (ctx.heap_buf) |buf| {
        abi.OS_free(@ptrCast(buf));
        ctx.heap_buf = null;
    }
}

fn writeCompactedBandFile(
    filename: [*:0]const u8,
    prim_table_start: [*]obj.SchemeObject,
    c_code_table_start: [*]obj.SchemeObject,
) bool {
    const heap_words = fasl.ptrRangeWords(fh.heap_end, fh.heap_start);
    const const_words = fasl.ptrRangeWords(fh.constant_end, fh.constant_start);
    const live_words = code_arena.code_arena_live_words();

    transact.transaction_begin();
    const ctx: *BandCompactCtx = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(BandCompactCtx)).?));
    ctx.heap_buf = null;
    ctx.const_buf = null;
    transact.transaction_record_action(.tat_always, &cleanupBandCompact, @ptrCast(ctx));

    if (!abi.open_code_tospace(live_words + 64)) {
        transact.transaction_commit();
        return false;
    }
    initializeFixups();

    code_arena.code_arena_for_each_live_block(&bandCompactTransportBlock, null);
    fh.code_start = abi.get_code_newspace_start();
    fh.code_end = abi.get_code_newspace_ptr();

    if (abi.compiler_utilities != obj.sharp_f and obj.ccBlockP(abi.compiler_utilities)) {
        const uaddr = obj.objectAddress(abi.compiler_utilities);
        if (code_arena.code_address_p(@ptrCast(uaddr)) and obj.brokenHeartP(uaddr[0])) {
            fh.utilities_vector = obj.objectNewAddress(abi.compiler_utilities, obj.objectAddress(uaddr[0]));
        }
    }
    finalizeFaslHeader(storage.ephemeron_count);

    if (heap_words > 0) {
        const heap_words_u: usize = @intCast(heap_words);
        const hbuf: [*]obj.SchemeObject = @ptrCast(@alignCast(abi.OS_malloc(heap_words_u * @sizeOf(obj.SchemeObject)).?));
        ctx.heap_buf = hbuf;
        @memcpy(hbuf[0..heap_words_u], fh.heap_start.?[0..heap_words_u]);
        abi.open_stage_tospace(fh.heap_start.?, hbuf, heap_words);
        abi.current_gc_table = @ptrCast(bandCompactTable());
        abi.gc_scan_stage_tospace();
        abi.close_stage_tospace();
    }

    if (const_words > 0) {
        const const_words_u: usize = @intCast(const_words);
        const cbuf: [*]obj.SchemeObject = @ptrCast(@alignCast(abi.OS_malloc(const_words_u * @sizeOf(obj.SchemeObject)).?));
        ctx.const_buf = cbuf;
        @memcpy(cbuf[0..const_words_u], fh.constant_start.?[0..const_words_u]);
        abi.open_stage_tospace(fh.constant_start.?, cbuf, const_words);
        abi.current_gc_table = @ptrCast(bandCompactTable());
        abi.gc_scan_stage_tospace();
        abi.close_stage_tospace();
    }

    if (fasl.ptrRangeWords(fh.code_end, fh.code_start) > 0) {
        abi.current_gc_table = @ptrCast(bandCompactTable());
        abi.gc_scan_code_tospace(fh.code_start.?, fh.code_end.?);
    }

    abi.OS_file_remove_link(filename);
    var handle: fasl.FaslFileHandle = null;
    if (!fasl.open_fasl_output_file(filename, &handle)) {
        abi.error_bad_range_arg(2);
    }

    const code_words = fasl.ptrRangeWords(fh.code_end, fh.code_start);
    const ok = fasl.write_fasl_header(fh, handle) and
        (heap_words == 0 or fasl.write_to_fasl_file(@ptrCast(ctx.heap_buf.?), @intCast(heap_words), handle)) and
        (const_words == 0 or fasl.write_to_fasl_file(@ptrCast(ctx.const_buf.?), @intCast(const_words), handle)) and
        (code_words == 0 or fasl.write_to_fasl_file(abi.newspace_to_tospace(@ptrCast(fh.code_start)), @intCast(code_words), handle)) and
        fasl.write_to_fasl_file(@ptrCast(prim_table_start), @intCast(fh.primitive_table_size), handle) and
        fasl.write_to_fasl_file(@ptrCast(c_code_table_start), @intCast(fh.c_code_table_size), handle);

    if (!fasl.close_fasl_output_file(handle)) {
        abi.OS_file_remove(filename);
    }
    transact.transaction_commit();
    return ok;
}

// DEFINE_PRIMITIVE ("DUMP-BAND*", Prim_band_dump, 2, 2,
//   "(PROCEDURE NAMESTRING)\n\
// Saves an image of the current world to the file NAMESTRING.\n\
// When the file is reloaded, PROCEDURE is called with an argument of #F.")
pub export fn Prim_band_dump() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();

    abi.checkArg(1, utils.interpreter_applicable_p);
    const filename: [*:0]const u8 = @ptrCast(abi.arg_extended_string(2, null));

    abi.primitiveGcIfNeeded(5);
    initializeFaslHeader(true, true);

    var to = abi.Free;
    const comb = obj.makePointerObject(obj.tc_combination, to);
    to[0] = obj.makeVectorHeader(2);
    to[1] = abi.argRef(1);
    to[2] = obj.sharp_f;
    to += 3;

    const root = obj.makePointerObject(obj.tc_list, to);
    to[0] = comb;
    to[1] = abi.compiler_utilities;
    to += 2;

    fh.root_pointer = to;
    to[0] = root;
    to += 1;

    const prim_table_start = to;
    fh.n_primitives = primutl.MAX_PRIMITIVE;
    fh.primitive_table_size = primutl.primitive_table_export_length();
    to += @as(usize, @intCast(fh.primitive_table_size));

    const c_code_table_start = to;

    var result: bool = false;
    if (@intFromPtr(to) > @intFromPtr(abi.heap_end)) {
        result = false;
    } else {
        const nonempty = code_arena.code_arena_nonempty_chunk_count();

        primutl.export_primitive_table(prim_table_start);

        fh.heap_start = abi.heap_start;
        fh.heap_end = prim_table_start;
        fh.constant_start = abi.constant_start;
        fh.constant_end = abi.constant_alloc_next;

        if (nonempty == 0 or
            (nonempty == 1 and
                code_arena.code_start != null and
                ptrAddr(code_arena.code_alloc_next) > ptrAddr(code_arena.code_start)))
        {
            if (code_arena.code_start != null and
                ptrAddr(code_arena.code_alloc_next) > ptrAddr(code_arena.code_start))
            {
                fh.code_start = code_arena.code_start;
                fh.code_end = code_arena.code_alloc_next;
            }
            finalizeFaslHeader(storage.ephemeron_count);

            abi.OS_file_remove_link(filename);
            var handle: fasl.FaslFileHandle = null;
            if (!fasl.open_fasl_output_file(filename, &handle)) {
                abi.error_bad_range_arg(2);
            }

            result = writeFaslFile(prim_table_start, c_code_table_start, handle);

            if (!fasl.close_fasl_output_file(handle)) {
                abi.OS_file_remove(filename);
            }
        } else {
            result = writeCompactedBandFile(filename, prim_table_start, c_code_table_start);
        }
    }
    return obj.booleanToObject(result);
}

fn initializeFaslHeader(cc_p: bool, band_p: bool) void {
    fh = &fasl_header;
    // Provisionally set version -- finalizeFaslHeader upgrades to EPHEMERONS or CODE_SPACE.
    fh.version = if (band_p) fasl.fasl_version_stack_end else fasl.fasl_version_c_code;
    fh.arch = fasl.currentFaslArch();
    fh.band_p = band_p;

    fh.memory_base = if (obj.heap_in_low_memory) null else storage.memory_block_start;
    fh.heap_reserved = if (band_p) storage.heap_reserved else 0;

    fh.stack_start = storage.stack_start;
    fh.stack_end = storage.stack_end;

    if (cc_p) {
        fh.cc_version = abi.compiler_interface_version;
        fh.cc_arch = abi.compiler_processor_type;
        fh.utilities_vector = abi.compiler_utilities;
    } else {
        fh.cc_version = 0;
        fh.cc_arch = abi.compiler_none_type;
        fh.utilities_vector = obj.sharp_f;
    }
    fh.n_c_code_blocks = 0;
    fh.c_code_table_size = 0;
    fh.ephemeron_count = 0;
    fh.code_start = null;
    fh.code_end = null;
    fh.utilities_start = null;
    fh.utilities_end = null;
}

fn finalizeFaslHeader(ephemeron_cnt: usize) void {
    fh.ephemeron_count = ephemeron_cnt;
    if (fasl.ptrRangeWords(fh.code_end, fh.code_start) != 0) {
        fh.version = fasl.fasl_version_code_space;
    } else if (ephemeron_cnt != 0) {
        fh.version = fasl.fasl_version_ephemerons;
    }
}

// Stage file writes through an ordinary stack buffer so kernel copyin()
// never reads directly from a MAP_JIT VMA.
fn writeCodeToFaslFile(src_in: [*]const obj.SchemeObject, n_words: usize, handle: fasl.FaslFileHandle) bool {
    var buf: [512]obj.SchemeObject = undefined;
    var src = src_in;
    var remaining = n_words;

    while (remaining > 0) {
        const chunk: usize = @min(remaining, buf.len);
        @memcpy(buf[0..chunk], src[0..chunk]);
        if (!fasl.write_to_fasl_file(@ptrCast(&buf), chunk, handle)) {
            return false;
        }
        src += chunk;
        remaining -= chunk;
    }
    return true;
}

fn writeFaslFile(
    prim_table_start: [*]obj.SchemeObject,
    c_code_table_start: [*]obj.SchemeObject,
    handle: fasl.FaslFileHandle,
) bool {
    const heap_words = fasl.ptrRangeWords(fh.heap_end, fh.heap_start);
    const const_words = fasl.ptrRangeWords(fh.constant_end, fh.constant_start);
    const code_words = fasl.ptrRangeWords(fh.code_end, fh.code_start);
    return fasl.write_fasl_header(fh, handle) and
        fasl.write_to_fasl_file(@ptrCast(fh.heap_start), @intCast(heap_words), handle) and
        fasl.write_to_fasl_file(@ptrCast(fh.constant_start), @intCast(const_words), handle) and
        (code_words == 0 or writeCodeToFaslFile(fh.code_start.?, @intCast(code_words), handle)) and
        fasl.write_to_fasl_file(@ptrCast(prim_table_start), @intCast(fh.primitive_table_size), handle) and
        fasl.write_to_fasl_file(@ptrCast(c_code_table_start), @intCast(fh.c_code_table_size), handle);
}

pub fn resetForTesting() void {
    fasdump_table_initialized = false;
    band_compact_table_initialized = false;
    current_env_mode = .fe_error;
    current_pr = null;
    cc_seen_p = false;
    dumped_ephemeron_count = 0;
    fixups_start = null;
    fixups_next = 0;
    fixups_cap = 0;
    fasdump_has_original_digest = false;
}

test "fasdump header transitions, fixups growth/restore, ccNewBlock, staged code write, and handlers" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();
    resetForTesting();
    defer resetForTesting();

    wind.dstack_initialize();
    defer wind.dstack_reset();
    transact.transaction_initialize();

    // 1. Header initialization and version upgrade transitions
    initializeFaslHeader(true, false);
    try std.testing.expectEqual(fasl.fasl_version_c_code, fh.version);
    try std.testing.expectEqual(abi.compiler_processor_type, fh.cc_arch);
    finalizeFaslHeader(2);
    try std.testing.expectEqual(fasl.fasl_version_ephemerons, fh.version);
    try std.testing.expectEqual(@as(usize, 2), fh.ephemeron_count);

    var code_buf: [8]obj.SchemeObject = @splat(0);
    initializeFaslHeader(false, true);
    try std.testing.expectEqual(fasl.fasl_version_stack_end, fh.version);
    try std.testing.expectEqual(@as(c_uint, 0), fh.cc_arch);
    fh.code_start = &code_buf;
    fh.code_end = code_buf[4..].ptr;
    finalizeFaslHeader(3);
    try std.testing.expectEqual(fasl.fasl_version_code_space, fh.version);

    // 2. Fixups > 64 entries trigger OS_realloc growth and restore original words on commit/abort
    var targets: [80]obj.SchemeObject = undefined;
    for (&targets, 0..) |*slot, idx| {
        slot.* = obj.ulongToFixnum(@intCast(idx + 10));
    }
    transact.transaction_begin();
    initializeFixups();
    for (&targets) |*slot| {
        addFixup(@ptrCast(slot));
        slot.* = obj.makeBrokenHeart(&code_buf);
    }
    transact.transaction_commit();
    for (&targets, 0..) |slot, idx| {
        try std.testing.expectEqual(obj.ulongToFixnum(@intCast(idx + 10)), slot);
    }

    // 3. ccNewBlock preserves 4-byte offset across compiled blocks without alignment panic
    var old_block: [8]obj.SchemeObject align(16) = @splat(0);
    var new_block: [8]obj.SchemeObject align(16) = @splat(0);
    const old_unaligned = @intFromPtr(&old_block[2]) + 4;
    const expected_new = @intFromPtr(&new_block[2]) + 4;
    const entry_obj = obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(old_unaligned));
    const moved_entry = ccNewBlock(entry_obj, &new_block, &old_block);
    try std.testing.expectEqual(expected_new, @intFromPtr(obj.objectRawAddress(moved_entry)));

    // 4. writeCodeToFaslFile handles > 512-word staged writes cleanly
    const tmp = struct {
        extern "c" fn tmpfile() fasl.FaslFileHandle;
        extern "c" fn rewind(fasl.FaslFileHandle) void;
    };
    const f = tmp.tmpfile();
    try std.testing.expect(f != null);
    defer _ = fasl.close_fasl_output_file(f);

    var src_words: [600]obj.SchemeObject = undefined;
    var read_words: [600]obj.SchemeObject = @splat(0);
    for (0..src_words.len) |i| {
        src_words[i] = 0xCAFE0000 + @as(obj.SchemeObject, @intCast(i));
    }
    try std.testing.expect(writeCodeToFaslFile(&src_words, src_words.len, f));
    tmp.rewind(f);
    try std.testing.expect(fasl.read_from_fasl_file(@ptrCast(&read_words), read_words.len, f));
    try std.testing.expectEqualSlices(obj.SchemeObject, &src_words, &read_words);

    // 5. Handlers: handlePrimitive, handleSymbol, handleBrokenHeart, handleEphemeron, tables
    primutl.resetForTesting();
    defer primutl.resetForTesting();
    primutl.initialize_primitives();

    transact.transaction_begin();
    abi.open_tospace(abi.heap_start);
    transact.transaction_record_action(.tat_abort, &abortFasdump, null);
    initializeFixups();
    abi.current_gc_table = @ptrCast(fasdumpTable());

    current_pr = primutl.make_prim_renumber();
    var p_scan: [1]obj.SchemeObject = .{obj.makePrimitiveObject(1)};
    _ = handlePrimitive(&p_scan, p_scan[0]);
    try std.testing.expectEqual(obj.makePrimitiveObject(0), p_scan[0]);
    current_pr = null;

    // Place symbol objects safely above where tospace writes in mock_heap
    const sym_cell = abi.heap_start + 128;
    sym_cell[0] = obj.makeNmvHeader(0);
    sym_cell[1] = obj.ulongToFixnum(77);
    const interned_sym = obj.makePointerObject(obj.tc_interned_symbol, sym_cell);
    var sym_scan: [1]obj.SchemeObject = .{interned_sym};
    _ = handleSymbol(&sym_scan, interned_sym);
    const dumped_sym_addr = obj.objectAddress(sym_scan[0]);
    try std.testing.expectEqual(obj.broken_heart_zero, abi.read_tospace(dumped_sym_addr + 1));

    const uninterned_cell = abi.heap_start + 132;
    uninterned_cell[0] = obj.makeNmvHeader(0);
    uninterned_cell[1] = obj.ulongToFixnum(88);
    const uninterned_sym = obj.makePointerObject(obj.tc_uninterned_symbol, uninterned_cell);
    var usym_scan: [1]obj.SchemeObject = .{uninterned_sym};
    _ = handleSymbol(&usym_scan, uninterned_sym);
    const dumped_usym_addr = obj.objectAddress(usym_scan[0]);
    try std.testing.expectEqual(obj.unbound_object, abi.read_tospace(dumped_usym_addr + 1));

    // handleBrokenHeart skips datum==0 (broken_heart_zero)
    var bh_slot: [2]obj.SchemeObject = .{ obj.broken_heart_zero, obj.sharp_t };
    try std.testing.expectEqual(@intFromPtr(&bh_slot[1]), @intFromPtr(handleBrokenHeart(&bh_slot, obj.broken_heart_zero)));

    // handleEphemeron increments count once (when not forwarded)
    const eph_cell = abi.heap_start + 136;
    eph_cell[0] = obj.makeVectorHeader(2);
    eph_cell[1] = obj.sharp_f;
    eph_cell[2] = obj.sharp_f;
    const eph = obj.makePointerObject(obj.tc_ephemeron, eph_cell);
    dumped_ephemeron_count = 0;
    var eph_scan: [1]obj.SchemeObject = .{eph};
    _ = handleEphemeron(&eph_scan, eph);
    try std.testing.expectEqual(@as(usize, 1), dumped_ephemeron_count);
    eph_cell[0] = obj.makeBrokenHeart(abi.heap_start);
    _ = handleEphemeron(&eph_scan, eph);
    try std.testing.expectEqual(@as(usize, 1), dumped_ephemeron_count);

    abi.discard_tospace();
    transact.transaction_commit();
    // Fixups restored sym_cell[0] and uninterned_cell[0] after transaction_commit
    try std.testing.expectEqual(obj.makeNmvHeader(0), sym_cell[0]);
    try std.testing.expectEqual(obj.makeNmvHeader(0), uninterned_cell[0]);

    const ft = fasdumpTable();
    try std.testing.expectEqual(@intFromPtr(&handleSymbol), @intFromPtr(ft.handlers[obj.tc_interned_symbol].?));
    const bt = bandCompactTable();
    try std.testing.expectEqual(@intFromPtr(&bandCompactVector), @intFromPtr(bt.vector_handler.?));

    if (build_options.debugging) {
        storage.Free = abi.heap_start + 8;
        storage.constant_alloc_next = abi.constant_start + 4;
        saveGcVars();
        saveMemoryChecksum();
        var d1: [md5.hash_len]u8 = undefined;
        var d2: [md5.hash_len]u8 = undefined;
        computeMemoryChecksum(&d1);
        abi.heap_start[0] ^= 0x1234;
        computeMemoryChecksum(&d2);
        try std.testing.expect(!std.mem.eql(u8, &d1, &d2));
        abi.heap_start[0] ^= 0x1234;
        compareGcVars();
        compareMemoryChecksum();
        try std.testing.expect(!fasdump_has_original_digest);
    }
}
