// Derived from MIT/GNU Scheme C sources (`src/microcode/gcloop.c`, `src/microcode/gccode.h`, `src/microcode/gc.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

const is_apple_jit: bool = builtin.os.tag.isDarwin() and builtin.cpu.arch == .aarch64;
const embedded_closure_addrs_p: bool = build_options.cc_is_native;
const uuo_link_size: usize = if (build_options.cc_is_svm) 2 else 4;
const cons_cdr: usize = 1;
const gc_scan_history_size: usize = 1024;

pub export var current_gc_table: ?*abi.GcTable = null;

var p_fromspace_start: ?*?[*]obj.SchemeObject = null;
var p_fromspace_end: ?*?[*]obj.SchemeObject = null;
var gc_tospace_allocator: ?abi.GcTospaceAllocator = null;
var gc_abort_handler: ?abi.GcAbortHandler = null;

var tospace_start: ?[*]obj.SchemeObject = null;
var tospace_next: ?[*]obj.SchemeObject = null;
var tospace_end: ?[*]obj.SchemeObject = null;
var newspace_start: ?[*]obj.SchemeObject = null;
var newspace_next: ?[*]obj.SchemeObject = null;
var newspace_end: ?[*]obj.SchemeObject = null;

var code_tospace_start: ?[*]obj.SchemeObject = null;
var code_tospace_next: ?[*]obj.SchemeObject = null;
var code_tospace_end: ?[*]obj.SchemeObject = null;
var code_newspace_start: ?[*]obj.SchemeObject = null;
var code_newspace_next: ?[*]obj.SchemeObject = null;
var code_newspace_end: ?[*]obj.SchemeObject = null;

var stage_tospace_start: ?[*]obj.SchemeObject = null;
var stage_tospace_end: ?[*]obj.SchemeObject = null;
var stage_newspace_start: ?[*]obj.SchemeObject = null;
var stage_newspace_end: ?[*]obj.SchemeObject = null;

var current_scan: ?[*]obj.SchemeObject = null;
var current_object: obj.SchemeObject = obj.sharp_f;

var weak_chain: ?[*]obj.SchemeObject = null;
var ephemeron_list: obj.SchemeObject = obj.sharp_f;
var ephemeron_queue: obj.SchemeObject = obj.sharp_f;
var scanning_ephemerons_p: bool = false;

var std_gc_table_initialized: bool = false;
var std_gc_table_storage: abi.GcTable = std.mem.zeroes(abi.GcTable);

// Debugging state (`ENABLE_GC_DEBUGGING_TOOLS`)
var gc_scan_history_index: usize = 0;
var gc_scan_history: [gc_scan_history_size]?[*]obj.SchemeObject = @splat(null);
var gc_to_history: [gc_scan_history_size]?[*]obj.SchemeObject = @splat(null);

const gc_trap: obj.SchemeObject = obj.makeObject(obj.tc_reference_trap, obj.trap_max_immediate);
var gc_scan_trap: ?[*]obj.SchemeObject = null;
var gc_to_trap: ?[*]obj.SchemeObject = null;

var gc_object_referenced: obj.SchemeObject = obj.sharp_f;
var gc_object_references: obj.SchemeObject = obj.sharp_f;
var gc_object_references_count: usize = 0;
var gc_object_references_scan: ?[*]obj.SchemeObject = null;
var gc_object_references_end: ?[*]obj.SchemeObject = null;

var weak_chain_length: usize = 0;

inline fn ptrWords(start: ?[*]const obj.SchemeObject, end: ?[*]const obj.SchemeObject) usize {
    if (start == null or end == null) return 0;
    return (@intFromPtr(end.?) -% @intFromPtr(start.?)) / @sizeOf(obj.SchemeObject);
}

inline fn addressInFromspaceP(addr: *const anyopaque) bool {
    const start_opt = if (p_fromspace_start) |ps| ps.* else return false;
    const end_opt = if (p_fromspace_end) |pe| pe.* else return false;
    const start = start_opt orelse return false;
    const end = end_opt orelse return false;
    const a = @intFromPtr(addr);
    return a >= @intFromPtr(start) and a < @intFromPtr(end);
}

inline fn addressCollectableP(addr: *const anyopaque) bool {
    return addressInFromspaceP(addr) or abi.code_address_p(addr);
}

inline fn newspaceToTospacePtr(addr: [*]obj.SchemeObject) [*]obj.SchemeObject {
    const delta = @intFromPtr(addr) -% @intFromPtr(newspace_start.?);
    return @ptrFromInt(@intFromPtr(tospace_start.?) +% delta);
}

fn closeTospace() void {
    tospace_next = null;
    newspace_start = null;
    newspace_next = null;
    newspace_end = null;
}

inline fn guaranteeTospaceOpen() void {
    if (tospace_next == null) tospaceClosed();
}

inline fn guaranteeTospaceClosed() void {
    if (tospace_next != null) tospaceOpen();
}

fn gcDeath(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const written = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch buf[0 .. buf.len - 1];
    buf[written.len] = 0;
    std_gc_death(@ptrCast(&buf));
}

pub export fn std_gc_death(msg: [*:0]const u8) callconv(.c) noreturn {
    abi.outf_fatal("\n%s\n", msg);
    if (current_scan) |scan| {
        abi.outf_fatal("scan = 0x%zx", @as(usize, @intCast(@intFromPtr(scan))));
        if (tospace_next) |to| {
            abi.outf_fatal("; to = 0x%zx", @as(usize, @intCast(@intFromPtr(to))));
        }
        abi.outf_fatal("\n");
    }
    abi.outf_flush_fatal();
    if (gc_abort_handler) |abort_fn| {
        abort_fn();
    }
    std.c.exit(1);
}

fn tospaceClosed() noreturn {
    std_gc_death("GC transport not allowed here");
}

fn tospaceOpen() noreturn {
    std_gc_death("tospace is open, should be closed");
}

pub export fn gc_no_cc_support() callconv(.c) noreturn {
    std_gc_death("No compiled-code support.");
}

pub export fn gc_bad_type(object: obj.SchemeObject) callconv(.c) noreturn {
    gcDeath("bad type code: 0x{x:0>2} 0x{x}", .{ obj.objectType(object), object });
}

fn initializeGcHistory() void {
    if (comptime build_options.debugging) {
        gc_scan_history_index = 0;
        gc_scan_history = @splat(null);
        gc_to_history = @splat(null);
    }
}

fn handleGcTrap(scan: [*]obj.SchemeObject, object: obj.SchemeObject) void {
    if (comptime build_options.debugging) {
        gc_scan_history[gc_scan_history_index] = scan;
        gc_to_history[gc_scan_history_index] = newspace_next;
        gc_scan_history_index += 1;
        if (gc_scan_history_index == gc_scan_history_size) {
            gc_scan_history_index = 0;
        }
        const scan_hit = if (gc_scan_trap) |st| @intFromPtr(scan) >= @intFromPtr(st) else false;
        const to_hit = if (gc_to_trap) |tt|
            (if (newspace_next) |nn| @intFromPtr(nn) >= @intFromPtr(tt) else false)
        else
            false;
        if (object == gc_trap or scan_hit or to_hit) {
            abi.outf_fatal("\nhandle_gc_trap: trap.\n");
            abi.outf_flush_fatal();
            std.c.abort();
        }
    }
}

fn checkNewspaceSync() void {
    if (comptime build_options.debugging) {
        const new_words = ptrWords(newspace_start, newspace_next);
        const to_words = ptrWords(tospace_start, tospace_next);
        if (new_words != to_words) {
            gcDeath("mismatch between newspace and tospace ptrs: {d}/{d}", .{ new_words, to_words });
        }
    }
}

fn debugTransportOneWord(object: obj.SchemeObject, from: [*]obj.SchemeObject) void {
    if (comptime build_options.debugging) {
        if (gc_object_references != obj.sharp_f and gc_object_referenced == from[0]) {
            gc_object_references_count += 1;
            if (gc_object_references_scan) |s| {
                if (@intFromPtr(s) < @intFromPtr(gc_object_references_end.?)) {
                    s[0] = object;
                    gc_object_references_scan = s + 1;
                }
            }
        }
    }
}

fn collectGcObjectReferencesImpl(object: obj.SchemeObject, collector: obj.SchemeObject) callconv(.c) void {
    gc_object_referenced = object;
    gc_object_references = collector;
}

fn initializeGcObjectReferencesImpl() callconv(.c) void {
    if (gc_object_references != obj.sharp_f) {
        obj.memorySet(
            gc_object_references,
            0,
            obj.makeObject(obj.tc_manifest_nm_vector, obj.objectDatum(obj.memoryRef(gc_object_references, 0))),
        );
        gc_object_references_count = 0;
        const scan_init = obj.vectorLoc(gc_object_references, 1);
        const end = obj.vectorLoc(gc_object_references, obj.vectorLength(gc_object_references));
        gc_object_references_scan = scan_init;
        gc_object_references_end = end;
        obj.vectorSet(gc_object_references, 0, obj.ulongToFixnum(0));
        var scan = scan_init;
        while (@intFromPtr(scan) < @intFromPtr(end)) : (scan += 1) {
            scan[0] = obj.sharp_f;
        }
        const tn = tospace_next.?;
        tn[0] = gc_object_references;
        tospace_next = tn + 1;
        newspace_next = newspace_next.? + 1;
    }
}

fn finalizeGcObjectReferencesImpl() callconv(.c) void {
    if (gc_object_references != obj.sharp_f) {
        const header = obj.memoryRef(gc_object_references, 0);
        if (obj.brokenHeartP(header)) {
            const to_addr = newspaceToTospacePtr(obj.objectAddress(header));
            var scan_to = to_addr;
            var scan_from = obj.vectorLoc(gc_object_references, 0);

            scan_to[0] = obj.makeVectorHeader(obj.objectDatum(to_addr[0]));
            scan_to += 1;

            obj.vectorSet(gc_object_references, 0, obj.ulongToFixnum(gc_object_references_count));

            const scan_end = gc_object_references_scan.?;
            while (@intFromPtr(scan_from) < @intFromPtr(scan_end)) {
                scan_to[0] = scan_from[0];
                scan_to += 1;
                scan_from += 1;
            }
        }
        gc_object_references = obj.sharp_f;
        gc_object_referenced = obj.sharp_f;
    }
}

comptime {
    if (build_options.debugging) {
        @export(&collectGcObjectReferencesImpl, .{ .name = "collect_gc_object_references" });
        @export(&initializeGcObjectReferencesImpl, .{ .name = "initialize_gc_object_references" });
        @export(&finalizeGcObjectReferencesImpl, .{ .name = "finalize_gc_object_references" });
    }
}

pub export fn initialize_gc(
    n_words: usize,
    pf_start: *?[*]obj.SchemeObject,
    pf_end: *?[*]obj.SchemeObject,
    allocator: abi.GcTospaceAllocator,
    abort_handler: abi.GcAbortHandler,
) callconv(.c) void {
    p_fromspace_start = pf_start;
    p_fromspace_end = pf_end;
    gc_tospace_allocator = allocator;
    gc_abort_handler = abort_handler;
    closeTospace();
    tospace_start = null;
    tospace_end = null;
    allocator(n_words, &tospace_start, &tospace_end);
}

pub export fn resize_tospace(n_words: usize) callconv(.c) void {
    guaranteeTospaceClosed();
    gc_tospace_allocator.?(n_words, &tospace_start, &tospace_end);
}

pub export fn open_tospace(start: [*]obj.SchemeObject) callconv(.c) void {
    guaranteeTospaceClosed();
    tospace_next = tospace_start;
    newspace_start = start;
    newspace_next = start;
    newspace_end = start + ptrWords(tospace_start, tospace_end);
}

pub export fn save_tospace(proc: abi.GcWalkProc, ctx: ?*anyopaque) callconv(.c) bool {
    guaranteeTospaceOpen();
    checkNewspaceSync();
    const ok = proc(tospace_start.?, tospace_next.?, ctx);
    abi.OS_free_pages(@ptrCast(tospace_start), @ptrCast(tospace_end));
    closeTospace();
    return ok;
}

pub export fn discard_tospace() callconv(.c) void {
    guaranteeTospaceOpen();
    checkNewspaceSync();
    abi.OS_free_pages(@ptrCast(tospace_start), @ptrCast(tospace_end));
    closeTospace();
}

pub export fn tospace_available_p(n_words: usize) callconv(.c) bool {
    guaranteeTospaceOpen();
    return ptrWords(tospace_next, tospace_end) >= @as(usize, @intCast(n_words));
}

pub export fn add_to_tospace(object: obj.SchemeObject) callconv(.c) void {
    guaranteeTospaceOpen();
    const tn = tospace_next.?;
    tn[0] = object;
    tospace_next = tn + 1;
    newspace_next = newspace_next.? + 1;
}

pub export fn read_tospace(addr: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    guaranteeTospaceOpen();
    const translated: [*]const obj.SchemeObject = @ptrCast(@alignCast(newspace_to_tospace(@ptrCast(addr))));
    return translated[0];
}

pub export fn write_tospace(addr: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) void {
    guaranteeTospaceOpen();
    const translated: [*]obj.SchemeObject = @ptrCast(@alignCast(newspace_to_tospace(@ptrCast(addr))));
    translated[0] = object;
}

pub export fn increment_tospace_ptr(n_words: usize) callconv(.c) void {
    guaranteeTospaceOpen();
    const n: usize = @intCast(n_words);
    tospace_next = tospace_next.? + n;
    newspace_next = newspace_next.? + n;
}

pub export fn get_newspace_ptr() callconv(.c) [*]obj.SchemeObject {
    return newspace_next.?;
}

pub export fn tospace_to_newspace(addr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const p = addr orelse return null;
    const a = @intFromPtr(p);
    if (tospace_next != null) {
        const ts = @intFromPtr(tospace_start.?);
        const te = @intFromPtr(tospace_end.?);
        if (a >= ts and a <= te) {
            return @ptrFromInt(@intFromPtr(newspace_start.?) +% (a -% ts));
        }
    }
    if (code_tospace_next != null) {
        const cs = @intFromPtr(code_tospace_start.?);
        const ce = @intFromPtr(code_tospace_end.?);
        if (a >= cs and a <= ce) {
            return @ptrFromInt(@intFromPtr(code_newspace_start.?) +% (a -% cs));
        }
    }
    if (stage_tospace_start != null) {
        const ss = @intFromPtr(stage_tospace_start.?);
        const se = @intFromPtr(stage_tospace_end.?);
        if (a >= ss and a <= se) {
            return @ptrFromInt(@intFromPtr(stage_newspace_start.?) +% (a -% ss));
        }
    }
    return p;
}

pub export fn newspace_to_tospace(addr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const p = addr orelse return null;
    const a = @intFromPtr(p);
    if (tospace_next != null) {
        const ns = @intFromPtr(newspace_start.?);
        const ne = @intFromPtr(newspace_end.?);
        if (a >= ns and a <= ne) {
            return @ptrFromInt(@intFromPtr(tospace_start.?) +% (a -% ns));
        }
    }
    if (code_tospace_next != null) {
        const cns = @intFromPtr(code_newspace_start.?);
        const cne = @intFromPtr(code_newspace_end.?);
        if (a >= cns and a <= cne) {
            return @ptrFromInt(@intFromPtr(code_tospace_start.?) +% (a -% cns));
        }
    }
    if (stage_tospace_start != null) {
        const sns = @intFromPtr(stage_newspace_start.?);
        const sne = @intFromPtr(stage_newspace_end.?);
        if (a >= sns and a <= sne) {
            return @ptrFromInt(@intFromPtr(stage_tospace_start.?) +% (a -% sns));
        }
    }
    return p;
}

inline fn maxAddr(a: usize, p: ?*const anyopaque) usize {
    const b = if (p) |ptr| @intFromPtr(ptr) else 0;
    return @max(a, b);
}

pub export fn open_code_tospace(n_words: usize) callconv(.c) bool {
    if (code_tospace_next != null) {
        discard_code_tospace();
    }
    const max_words = std.math.maxInt(usize) / @sizeOf(obj.SchemeObject);
    if (n_words > max_words - 1) return false;
    const alloc_words: usize = @as(usize, @intCast(n_words)) + 1;
    const raw = std.c.malloc(alloc_words * @sizeOf(obj.SchemeObject)) orelse return false;
    const buf: [*]obj.SchemeObject = @ptrCast(@alignCast(raw));

    code_tospace_start = buf;
    code_tospace_next = buf;
    code_tospace_end = buf + alloc_words;

    var min_base: usize = 0;
    if (p_fromspace_end) |pe| {
        min_base = maxAddr(min_base, @ptrCast(pe.*));
    }
    min_base = maxAddr(min_base, @ptrCast(newspace_end));
    min_base = maxAddr(min_base, @ptrCast(tospace_end));
    min_base = maxAddr(min_base, @ptrCast(code_tospace_end));
    min_base = maxAddr(min_base, @ptrCast(abi.code_arena_max_end()));

    const align_bytes: usize = 512 * @sizeOf(obj.SchemeObject);
    if (min_base > std.math.maxInt(usize) - 2 * align_bytes) {
        discard_code_tospace();
        return false;
    }
    const aligned_addr = ((min_base + align_bytes + (align_bytes - 1)) / align_bytes) * align_bytes;
    const cns: [*]obj.SchemeObject = @ptrFromInt(aligned_addr);
    code_newspace_start = cns;
    code_newspace_next = cns;
    code_newspace_end = cns + alloc_words;
    if (obj.addressToDatum(code_newspace_end.?) > obj.datum_mask) {
        discard_code_tospace();
        return false;
    }
    return true;
}

pub export fn discard_code_tospace() callconv(.c) void {
    if (code_tospace_start) |p| {
        std.c.free(@ptrCast(p));
    }
    code_tospace_start = null;
    code_tospace_next = null;
    code_tospace_end = null;
    code_newspace_start = null;
    code_newspace_next = null;
    code_newspace_end = null;
}

pub export fn get_code_newspace_start() callconv(.c) ?[*]obj.SchemeObject {
    return code_newspace_start;
}

pub export fn get_code_newspace_ptr() callconv(.c) ?[*]obj.SchemeObject {
    return code_newspace_next;
}

pub export fn code_tospace_available_p(n_words: usize) callconv(.c) bool {
    if (code_tospace_next == null) tospaceClosed();
    return ptrWords(code_tospace_next, code_tospace_end) >= @as(usize, @intCast(n_words)) + 1;
}

pub export fn open_stage_tospace(orig_start: [*]obj.SchemeObject, buf: [*]obj.SchemeObject, n_words: usize) callconv(.c) void {
    const n: usize = @intCast(n_words);
    stage_tospace_start = buf;
    stage_tospace_end = buf + n;
    stage_newspace_start = orig_start;
    stage_newspace_end = orig_start + n;
}

pub export fn close_stage_tospace() callconv(.c) void {
    stage_tospace_start = null;
    stage_tospace_end = null;
    stage_newspace_start = null;
    stage_newspace_end = null;
}

pub export fn gc_scan_stage_tospace() callconv(.c) void {
    const start = stage_tospace_start orelse tospaceClosed();
    gc_scan_oldspace(start, stage_tospace_end.?);
}

pub export fn initialize_gc_table(table: *abi.GcTable, transport_p: bool) callconv(.c) void {
    for (gc_type_map, 0..) |gt, idx| {
        const handler: abi.GcHandler = switch (@as(abi.GcType, @enumFromInt(gt))) {
            .non_pointer => &gc_handle_non_pointer,
            .cell => &gc_handle_cell,
            .pair => &gc_handle_pair,
            .triple => &gc_handle_triple,
            .quadruple => &gc_handle_quadruple,
            .vector => &gc_handle_unaligned_vector,
            .compiled_entry => &gc_handle_cc_entry,
            .compiled_return => &gc_handle_cc_return,
            .undefined => &gc_handle_undefined,
            .special => switch (@as(usize, idx)) {
                obj.tc_broken_heart => &gc_handle_broken_heart,
                obj.tc_reference_trap => &gc_handle_reference_trap,
                obj.tc_linkage_section => &gc_handle_linkage_section,
                obj.tc_manifest_closure => &gc_handle_manifest_closure,
                obj.tc_manifest_nm_vector => &gc_handle_nmv,
                else => gcDeath("unknown GC special type: 0x{x:0>2}\n", .{idx}),
            },
        };
        table.handlers[idx] = handler;
    }
    table.handlers[obj.tc_weak_cons] = &gc_handle_weak_pair;
    table.handlers[obj.tc_ephemeron] = &gc_handle_ephemeron;
    table.handlers[obj.tc_big_flonum] = &gc_handle_aligned_vector;
    table.handlers[obj.tc_compiled_code_block] = &gc_handle_aligned_vector;
    table.tuple_handler = &gc_tuple;
    table.vector_handler = &gc_vector;
    table.cc_entry_handler = &gc_cc_entry;
    table.cc_return_handler = &gc_cc_return;
    if (transport_p) {
        table.precheck_from = &gc_precheck_from;
        table.transport_words = &gc_transport_words;
    } else {
        table.precheck_from = &gc_precheck_from_no_transport;
        table.transport_words = &gc_no_transport_words;
    }
    table.ignore_object_p = null;
    table.raw_address_to_object = &gc_raw_address_to_object;
    table.object_to_raw_address = &gc_object_to_raw_address;
    table.raw_address_to_cc_entry = &gc_raw_address_to_cc_entry;
    table.cc_entry_to_raw_address = &gc_cc_entry_to_raw_address;
}

pub export fn std_gc_table() callconv(.c) *abi.GcTable {
    if (!std_gc_table_initialized) {
        initialize_gc_table(&std_gc_table_storage, true);
        std_gc_table_initialized = true;
    }
    return &std_gc_table_storage;
}

pub export fn gc_scan_oldspace(scan: [*]obj.SchemeObject, end_arg: [*]obj.SchemeObject) callconv(.c) void {
    var end = end_arg;
    abi.OS_expect_sequential_access(@ptrCast(scan), @ptrCast(end));
    runGcLoop(scan, &end);
    abi.OS_expect_normal_access(@ptrCast(scan), @ptrCast(end));
}

pub export fn gc_scan_tospace(scan: [*]obj.SchemeObject, end_arg: ?[*]obj.SchemeObject) callconv(.c) void {
    const tscan = newspaceToTospacePtr(scan);
    if (end_arg) |end| {
        var tend = newspaceToTospacePtr(end);
        runGcLoop(tscan, &tend);
    } else {
        runGcLoop(tscan, &tospace_next.?);
    }
}

pub export fn gc_scan_code_tospace(scan: [*]obj.SchemeObject, end_arg: ?[*]obj.SchemeObject) callconv(.c) void {
    if (code_tospace_next == null) tospaceClosed();
    const cscan: [*]obj.SchemeObject = @ptrCast(@alignCast(newspace_to_tospace(@ptrCast(scan))));
    if (end_arg) |end| {
        var cend: [*]obj.SchemeObject = @ptrCast(@alignCast(newspace_to_tospace(@ptrCast(end))));
        runGcLoop(cscan, &cend);
    } else {
        runGcLoop(cscan, &code_tospace_next.?);
    }
}

pub export fn gc_drain_tospace_and_code_arena(scan_to_init: [*]obj.SchemeObject) callconv(.c) void {
    var scan_to = scan_to_init;
    while (@intFromPtr(scan_to) < @intFromPtr(newspace_next.?) or !abi.code_arena_mark_stack_empty_p()) {
        if (@intFromPtr(scan_to) < @intFromPtr(newspace_next.?)) {
            const target = newspace_next.?;
            gc_scan_tospace(scan_to, target);
            scan_to = target;
        }
        if (!abi.code_arena_mark_stack_empty_p()) {
            abi.code_arena_write_begin();
            while (!abi.code_arena_mark_stack_empty_p()) {
                const block = abi.code_arena_pop_mark_stack().?;
                std.debug.assert(obj.objectType(block[1]) == obj.tc_manifest_nm_vector);
                const start_idx: usize = @intCast(2 + obj.objectDatum(block[1]));
                const end_idx: usize = @intCast(1 + obj.objectDatum(block[0]));
                gc_scan_oldspace(block + start_idx, block + end_idx);
            }
            abi.code_arena_write_end();
        }
    }
}

fn runGcLoop(scan_init: [*]obj.SchemeObject, p_end: *[*]obj.SchemeObject) void {
    const tbl = current_gc_table.?;
    const ignore_object_p = tbl.ignore_object_p;
    var scan = scan_init;
    initializeGcHistory();
    while (@intFromPtr(scan) < @intFromPtr(p_end.*)) {
        const object = scan[0];
        handleGcTrap(scan, object);
        if (ignore_object_p != null and ignore_object_p.?(object)) {
            scan += 1;
        } else {
            current_scan = scan;
            current_object = object;
            const tc: usize = @intCast(obj.objectType(object));
            scan = tbl.handlers[tc].?(scan, object);
        }
    }
}

inline fn ccNewBlock(
    entry: obj.SchemeObject,
    new_block: [*]const obj.SchemeObject,
    old_block: [*]const obj.SchemeObject,
) obj.SchemeObject {
    const raw_old = @intFromPtr(obj.objectRawAddress(entry));
    const byte_offset = raw_old -% @intFromPtr(old_block);
    return obj.objectNewRawAddress(entry, @intFromPtr(new_block) +% byte_offset);
}

pub export fn gc_tuple(tuple: obj.SchemeObject, n_words: c_uint) callconv(.c) obj.SchemeObject {
    const tbl = current_gc_table.?;
    const precheck = tbl.precheck_from.?;
    const transport = tbl.transport_words.?;
    const from = obj.objectAddress(tuple);
    var new_address = precheck(from);
    if (new_address == null) {
        const allocated = transport(from, n_words, false);
        // A little hack to localize lists. Transport CDRs eagerly.
        if (n_words == 2) {
            var cdr = read_tospace(allocated + cons_cdr);
            while (obj.objectType(cdr) == obj.tc_list and precheck(obj.objectAddress(cdr)) == null) {
                cdr = read_tospace(transport(obj.objectAddress(cdr), 2, false) + cons_cdr);
            }
        }
        new_address = allocated;
    }
    return obj.objectNewAddress(tuple, new_address.?);
}

pub export fn gc_vector(vector: obj.SchemeObject, align_p: bool) callconv(.c) obj.SchemeObject {
    const tbl = current_gc_table.?;
    const from = obj.objectAddress(vector);
    if (comptime (is_apple_jit and build_options.cc_is_native)) {
        if (obj.objectType(vector) == obj.tc_compiled_code_block and
            !(abi.code_address_p(@ptrCast(from)) or
                obj.brokenHeartP(from[0]) or
                obj.objectType(from[0]) == obj.tc_manifest_closure))
        {
            gcDeath("compiled code block outside code arena: 0x{x}", .{vector});
        }
    }
    const new_address = tbl.precheck_from.?(from) orelse
        tbl.transport_words.?(from, 1 + obj.objectDatum(from[0]), align_p);
    return obj.objectNewAddress(vector, new_address);
}

pub export fn gc_cc_entry(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (comptime build_options.cc_support) {
        const old_block = abi.cc_entry_to_block(object);
        const old_addr = obj.objectAddress(old_block);
        if (comptime (is_apple_jit and build_options.cc_is_native)) {
            if (!(abi.code_address_p(@ptrCast(old_addr)) or
                obj.brokenHeartP(old_addr[0]) or
                obj.objectType(old_addr[0]) == obj.tc_manifest_closure))
            {
                gcDeath("compiled entry outside code arena: 0x{x}", .{object});
            }
        }
        const new_block = current_gc_table.?.vector_handler.?(old_block, true);
        return ccNewBlock(object, obj.objectAddress(new_block), old_addr);
    }
    gc_no_cc_support();
}

pub export fn gc_cc_return(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (comptime build_options.cc_support) {
        const old_block = abi.cc_return_to_block(object);
        const old_addr = obj.objectAddress(old_block);
        if (comptime (is_apple_jit and build_options.cc_is_native)) {
            if (!abi.code_address_p(@ptrCast(old_addr))) {
                gcDeath("compiled return outside code arena: 0x{x}", .{object});
            }
        }
        const new_block = current_gc_table.?.vector_handler.?(old_block, true);
        return ccNewBlock(object, obj.objectAddress(new_block), old_addr);
    }
    gc_no_cc_support();
}

pub export fn gc_precheck_from(from: [*]obj.SchemeObject) callconv(.c) ?[*]obj.SchemeObject {
    if (abi.code_address_p(@ptrCast(from))) {
        if (abi.code_arena_mark_block(from)) {
            if (scanning_ephemerons_p) {
                queueEphemeronsForKey(from);
            }
        }
        return from;
    }
    if (!addressInFromspaceP(@ptrCast(from))) return from;
    if (obj.brokenHeartP(from[0])) return obj.objectAddress(from[0]);
    if (scanning_ephemerons_p) {
        // It would be nice if we had the new address, too; that way we
        // could eliminate a post-processing loop over the list of all
        // ephemerons. However, the GC abstraction doesn't have a nice way
        // to do that.
        queueEphemeronsForKey(from);
    }
    return null;
}

pub export fn gc_precheck_from_no_transport(from: [*]obj.SchemeObject) callconv(.c) ?[*]obj.SchemeObject {
    return from;
}

fn transportWordsInto(
    from_start: [*]obj.SchemeObject,
    n_words: usize,
    align_p: bool,
    p_to_next: *?[*]obj.SchemeObject,
    to_end: [*]obj.SchemeObject,
    p_new_next: *?[*]obj.SchemeObject,
    check_code_arena_p: bool,
) [*]obj.SchemeObject {
    var from = from_start;
    const count: usize = @intCast(n_words);
    const from_end = from_start + count;

    if (align_p) {
        while (!obj.floatingAlignedP(p_new_next.*.?)) {
            const tn = p_to_next.*.?;
            tn[0] = obj.makeNmvHeader(0);
            p_to_next.* = tn + 1;
            p_new_next.* = p_new_next.*.? + 1;
        }
    }
    if (comptime build_options.debugging) {
        if (@intFromPtr(p_to_next.*.?) >= @intFromPtr(to_end)) {
            std_gc_death("tospace completely filled");
        }
        const end = p_to_next.*.? + count;
        if (@intFromPtr(end) > @intFromPtr(to_end)) {
            gcDeath("block overflows tospace: 0x{x}", .{@intFromPtr(end)});
        }
        if (n_words == 0) {
            std_gc_death("gc_transport_words: attempt to transfer zero words.");
        }
    }
    const new_address = p_new_next.*.?;
    while (@intFromPtr(from) < @intFromPtr(from_end)) {
        debugTransportOneWord(current_object, from);
        const tn = p_to_next.*.?;
        tn[0] = from[0];
        p_to_next.* = tn + 1;
        from += 1;
        p_new_next.* = p_new_next.*.? + 1;
    }
    if (check_code_arena_p and abi.code_address_p(@ptrCast(from_start))) {
        abi.code_arena_write_begin();
        from_start[0] = obj.makeBrokenHeart(new_address);
        abi.code_arena_write_end();
    } else {
        from_start[0] = obj.makeBrokenHeart(new_address);
    }
    return new_address;
}

pub export fn gc_transport_words(from: [*]obj.SchemeObject, n_words: usize, align_p: bool) callconv(.c) [*]obj.SchemeObject {
    guaranteeTospaceOpen();
    return transportWordsInto(from, n_words, align_p, &tospace_next, tospace_end.?, &newspace_next, false);
}

pub export fn gc_transport_words_to_code_tospace(from: [*]obj.SchemeObject, n_words: usize, align_p: bool) callconv(.c) [*]obj.SchemeObject {
    if (code_tospace_next == null) tospaceClosed();
    return transportWordsInto(from, n_words, align_p, &code_tospace_next, code_tospace_end.?, &code_newspace_next, true);
}

pub export fn gc_no_transport_words(from: [*]obj.SchemeObject, _: usize, _: bool) callconv(.c) [*]obj.SchemeObject {
    _ = from;
    tospaceClosed();
}

pub export fn gc_handle_non_pointer(scan: [*]obj.SchemeObject, _: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return scan + 1;
}

pub export fn gc_handle_cell(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.tuple_handler.?(object, 1);
    return scan + 1;
}

pub export fn gc_handle_pair(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.tuple_handler.?(object, 2);
    return scan + 1;
}

pub export fn gc_handle_triple(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.tuple_handler.?(object, 3);
    return scan + 1;
}

pub export fn gc_handle_quadruple(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.tuple_handler.?(object, 4);
    return scan + 1;
}

pub export fn gc_handle_weak_pair(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    const new_address = current_gc_table.?.precheck_from.?(obj.objectAddress(object));
    scan[0] = if (new_address) |addr| obj.objectNewAddress(object, addr) else gcTransportWeakPair(object);
    return scan + 1;
}

pub export fn gc_handle_ephemeron(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    const new_address = current_gc_table.?.precheck_from.?(obj.objectAddress(object));
    scan[0] = if (new_address) |addr| obj.objectNewAddress(object, addr) else gcTransportEphemeron(object);
    return scan + 1;
}

pub export fn gc_handle_cc_entry(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.cc_entry_handler.?(object);
    return scan + 1;
}

pub export fn gc_handle_cc_return(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.cc_return_handler.?(object);
    return scan + 1;
}

pub export fn gc_handle_aligned_vector(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.vector_handler.?(object, true);
    return scan + 1;
}

pub export fn gc_handle_unaligned_vector(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = current_gc_table.?.vector_handler.?(object, false);
    return scan + 1;
}

pub export fn gc_handle_broken_heart(_: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    gcDeath("broken heart in scan: 0x{x}", .{object});
}

pub export fn gc_handle_nmv(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return scan + @as(usize, @intCast(1 + obj.objectDatum(object)));
}

pub export fn gc_handle_reference_trap(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    scan[0] = if (obj.objectDatum(object) <= obj.trap_max_immediate)
        object
    else
        current_gc_table.?.tuple_handler.?(object, 2);
    return scan + 1;
}

pub export fn gc_raw_address_to_object(tc: c_uint, address: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return obj.makePointerObject(@intCast(tc), address);
}

pub export fn gc_object_to_raw_address(object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return obj.objectAddress(object);
}

pub export fn gc_raw_address_to_cc_entry(address: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(@intFromPtr(address)));
}

pub export fn gc_cc_entry_to_raw_address(entry: obj.SchemeObject) callconv(.c) ?*anyopaque {
    return obj.objectRawAddress(entry);
}

pub export fn gc_handle_linkage_section(scan_init: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (comptime build_options.cc_support) {
        const tbl = current_gc_table.?;
        var count = abi.linkage_section_count(object);
        var scan = scan_init + 1;
        switch (abi.linkage_section_type(object)) {
            @intFromEnum(abi.LinkageSectionType.reference), @intFromEnum(abi.LinkageSectionType.assignment) => {
                while (count > 0) : (count -= 1) {
                    const slot: *[*]obj.SchemeObject = @ptrCast(scan);
                    const oaddr = slot.*;
                    const osection = tbl.raw_address_to_object.?(@intCast(obj.tc_hunk3), oaddr);
                    const nsection = tbl.tuple_handler.?(osection, 3);
                    slot.* = tbl.object_to_raw_address.?(nsection);
                    scan += 1;
                }
            },
            @intFromEnum(abi.LinkageSectionType.operator), @intFromEnum(abi.LinkageSectionType.global_operator) => {
                while (count > 0) : (count -= 1) {
                    const otarget = abi.read_uuo_target(scan);
                    const oentry = tbl.raw_address_to_cc_entry.?(otarget);
                    const nentry = tbl.cc_entry_handler.?(oentry);
                    const ntarget = tbl.cc_entry_to_raw_address.?(nentry);
                    abi.write_uuo_target(ntarget, scan);
                    scan += uuo_link_size;
                }
            },
            else => std_gc_death("Unknown linkage-section type."),
        }
        return scan;
    }
    gc_no_cc_support();
}

pub export fn gc_handle_manifest_closure(scan_init: [*]obj.SchemeObject, _: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (comptime build_options.cc_support) {
        if (comptime embedded_closure_addrs_p) {
            const tbl = current_gc_table.?;
            var ref: abi.RelocRef = undefined;
            abi.start_closure_relocation(scan_init, &ref);
            const scan = scan_init + 1;
            var start = abi.compiled_closure_start(scan);
            var count = abi.compiled_closure_count(scan);
            while (count > 0) : (count -= 1) {
                const otarget = abi.read_compiled_closure_target(start, &ref);
                const oentry = tbl.raw_address_to_cc_entry.?(otarget);
                const nentry = tbl.cc_entry_handler.?(oentry);
                const ntarget = tbl.cc_entry_to_raw_address.?(nentry);
                abi.write_compiled_closure_target(ntarget, start);
                start = abi.compiled_closure_next(start);
            }
            return abi.skip_compiled_closure_padding(start);
        } else {
            return abi.compiled_closure_objects(scan_init + 1);
        }
    }
    gc_no_cc_support();
}

pub export fn gc_handle_undefined(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    _ = scan;
    gc_bad_type(object);
}

fn weakReferentAddress(object: obj.SchemeObject) ?[*]obj.SchemeObject {
    return switch (@as(abi.GcPtrType, @enumFromInt(gc_ptr_type(object)))) {
        .normal => obj.objectAddress(object),
        .compiled_entry => if (comptime build_options.cc_support)
            abi.cc_entry_address_to_block_address(obj.objectRawAddress(object))
        else
            gc_no_cc_support(),
        .compiled_return => if (comptime build_options.cc_support)
            abi.cc_return_address_to_block_address(obj.objectRawAddress(object))
        else
            gc_no_cc_support(),
        .not => null,
    };
}

fn weakReferentForward(object: obj.SchemeObject, collected: obj.SchemeObject) obj.SchemeObject {
    switch (@as(abi.GcPtrType, @enumFromInt(gc_ptr_type(object)))) {
        .normal => {
            const addr = obj.objectAddress(object);
            if (abi.code_address_p(@ptrCast(addr))) {
                return if (abi.code_arena_marked_p(addr)) object else collected;
            }
            if (obj.brokenHeartP(addr[0])) {
                return obj.makeObjectFromObjects(object, addr[0]);
            }
            return collected;
        },
        .compiled_entry => {
            if (comptime build_options.cc_support) {
                const addr = abi.cc_entry_address_to_block_address(obj.objectRawAddress(object));
                if (abi.code_address_p(@ptrCast(addr))) {
                    return if (abi.code_arena_marked_p(addr)) object else collected;
                }
                if (obj.brokenHeartP(addr[0])) {
                    return ccNewBlock(object, obj.objectAddress(addr[0]), addr);
                }
                return collected;
            }
            gc_no_cc_support();
        },
        .compiled_return => {
            if (comptime build_options.cc_support) {
                const addr = abi.cc_return_address_to_block_address(obj.objectRawAddress(object));
                if (abi.code_address_p(@ptrCast(addr))) {
                    return if (abi.code_arena_marked_p(addr)) object else collected;
                }
                if (obj.brokenHeartP(addr[0])) {
                    return ccNewBlock(object, obj.objectAddress(addr[0]), addr);
                }
                return collected;
            }
            gc_no_cc_support();
        },
        .not => std_gc_death("Non-pointer cannot be a weak reference."),
    }
}

inline fn ephemeronP(object: obj.SchemeObject) bool {
    return obj.objectType(object) == obj.tc_ephemeron;
}

fn queueEphemeronsForKey(addr: [*]obj.SchemeObject) void {
    const ht = abi.ephemeron_array;
    const index: usize = @intCast(@intFromPtr(addr) % @as(usize, @intCast(obj.vectorLength(ht))));
    var entry_loc: [*]obj.SchemeObject = obj.vectorLoc(ht, index);

    if (comptime build_options.debugging) {
        if (!scanning_ephemerons_p) {
            std_gc_death("queue_ephemerons_for_key while not scanning ephemerons");
        }
        if (!addressCollectableP(@ptrCast(addr))) {
            std_gc_death("Queueing ephemerons for key with non-fromspace address.");
        }
    }

    while (true) {
        const entry = entry_loc[0];
        if (!ephemeronP(entry)) break;
        const entry_addr = obj.objectAddress(entry);
        const next_loc = newspaceToTospacePtr(entry_addr + abi.ephemeron_next);
        const key_addr = weakReferentAddress(read_tospace(entry_addr + abi.ephemeron_key));
        if (key_addr != null and key_addr.? == addr) {
            entry_loc[0] = next_loc[0];
            next_loc[0] = ephemeron_queue;
            ephemeron_queue = entry;
        } else {
            entry_loc = next_loc;
        }
    }
}

fn gcTransportWeakPair(pair: obj.SchemeObject) obj.SchemeObject {
    const old_addr = obj.objectAddress(pair);
    const new_addr = current_gc_table.?.transport_words.?(old_addr, 2, false);
    const old_car = read_tospace(new_addr);
    const caddr = weakReferentAddress(old_car);

    if (caddr != null and addressCollectableP(@ptrCast(caddr.?))) {
        write_tospace(new_addr, obj.objectNewType(obj.tc_false, old_car));
        old_addr[1] = if (weak_chain) |wc|
            obj.makePointerObject(obj.objectType(old_car), wc)
        else
            obj.makeObject(obj.objectType(old_car), 0);
        weak_chain = old_addr;
        if (comptime build_options.debugging) {
            weak_chain_length += 1;
        }
    }
    return obj.objectNewAddress(pair, new_addr);
}

fn gcTransportEphemeron(old_ephemeron: obj.SchemeObject) obj.SchemeObject {
    const old_addr = obj.objectAddress(old_ephemeron);
    const new_addr = current_gc_table.?.transport_words.?(old_addr, abi.ephemeron_size, false);
    const new_ephemeron = obj.objectNewAddress(old_ephemeron, new_addr);
    const old_key = read_tospace(new_addr + abi.ephemeron_key);
    const old_key_addr = weakReferentAddress(old_key);
    const ht = abi.ephemeron_array;

    abi.ephemeron_count += 1;

    // If the key is GC-invariant or live, leave a marked manifest so GC scans datum.
    if (old_key_addr == null or
        !addressCollectableP(@ptrCast(old_key_addr.?)) or
        weakReferentForward(old_key, obj.sharp_f) != obj.sharp_f)
    {
        write_tospace(new_addr, abi.marked_ephemeron_manifest);
        return new_ephemeron;
    }

    // Write a non-marked manifest so the GC skips the ephemeron during initial scan.
    write_tospace(new_addr, abi.unmarked_ephemeron_manifest);

    // Map key back to ephemeron.
    const index: usize = @intCast(@intFromPtr(old_key_addr.?) % @as(usize, @intCast(obj.vectorLength(ht))));
    write_tospace(new_addr + abi.ephemeron_next, obj.vectorRef(ht, index));
    obj.vectorSet(ht, index, new_ephemeron);

    // Link onto ephemeron_list.
    write_tospace(new_addr + abi.ephemeron_list, ephemeron_list);
    ephemeron_list = new_ephemeron;

    return new_ephemeron;
}

fn scanNewspaceAddr(addr_arg: [*]obj.SchemeObject) void {
    const tbl = current_gc_table.?;
    const ignore_object_p = tbl.ignore_object_p;
    const addr = newspaceToTospacePtr(addr_arg);
    const scan = addr;

    initializeGcHistory();
    const object = scan[0];
    handleGcTrap(scan, object);
    if (ignore_object_p != null and ignore_object_p.?(object)) return;

    current_scan = scan;
    current_object = object;
    const tc: usize = @intCast(obj.objectType(object));
    const next_scan = tbl.handlers[tc].?(scan, object);
    if (comptime build_options.debugging) {
        if (@intFromPtr(next_scan) != @intFromPtr(addr + 1)) {
            std_gc_death("scan_newspace_addr overflowed");
        }
    }
}

fn scanEphemerons() void {
    var ephemeron = ephemeron_list;
    scanning_ephemerons_p = true;
    while (ephemeronP(ephemeron)) {
        const ephemeron_addr = obj.objectAddress(ephemeron);
        const old_key = read_tospace(ephemeron_addr + abi.ephemeron_key);
        ephemeron = read_tospace(ephemeron_addr + abi.ephemeron_list);
        if (weakReferentForward(old_key, obj.sharp_f) != obj.sharp_f) {
            queueEphemeronsForKey(weakReferentAddress(old_key).?);
        }
    }
    while (ephemeronP(ephemeron_queue)) {
        ephemeron = ephemeron_queue;
        const ephemeron_addr = obj.objectAddress(ephemeron);
        if (comptime build_options.debugging) {
            const key = read_tospace(ephemeron_addr + abi.ephemeron_key);
            if (weakReferentForward(key, obj.sharp_f) == obj.sharp_f) {
                gcDeath("Ephemeron queued whose key has not been forwarded: 0x{x}", .{key});
            }
        }
        ephemeron_queue = read_tospace(ephemeron_addr + abi.ephemeron_next);
        const saved_newspace_next = newspace_next.?;
        scanNewspaceAddr(ephemeron_addr + abi.ephemeron_datum);
        gc_drain_tospace_and_code_arena(saved_newspace_next);
    }
    scanning_ephemerons_p = false;
}

pub export fn initialize_weak_chain() callconv(.c) void {
    abi.code_arena_mark_begin();
    weak_chain = null;
    if (comptime build_options.debugging) {
        weak_chain_length = 0;
        if (ephemeron_list != obj.sharp_f) std_gc_death("Bad ephemeron list.");
        if (ephemeron_queue != obj.sharp_f) std_gc_death("Bad ephemeron queue.");
        if (scanning_ephemerons_p) std_gc_death("Bad ephemeron state.");
    }
}

fn updateEphemerons() void {
    var ephemeron = ephemeron_list;
    while (ephemeronP(ephemeron)) {
        const ephemeron_addr = obj.objectAddress(ephemeron);
        const key_loc = ephemeron_addr + abi.ephemeron_key;
        const old_key = read_tospace(key_loc);
        const new_key = weakReferentForward(old_key, obj.sharp_f);
        write_tospace(ephemeron_addr, abi.marked_ephemeron_manifest);
        write_tospace(key_loc, new_key);
        ephemeron = read_tospace(ephemeron_addr + abi.ephemeron_list);
        write_tospace(ephemeron_addr + abi.ephemeron_list, obj.sharp_f);
        write_tospace(ephemeron_addr + abi.ephemeron_next, obj.sharp_f);
        if (new_key == obj.sharp_f) {
            write_tospace(ephemeron_addr + abi.ephemeron_datum, obj.sharp_f);
        }
    }
    ephemeron_list = obj.sharp_f;
}

fn updateWeakPairs() void {
    while (weak_chain) |wc| {
        const new_addr = obj.objectAddress(wc[0]);
        const link = wc[1];
        const old_car = obj.objectNewType(obj.objectType(link), read_tospace(new_addr));
        write_tospace(new_addr, weakReferentForward(old_car, obj.gc_reclaimed));
        weak_chain = if (obj.objectDatum(link) == 0) null else obj.objectAddress(link);
    }
}

pub export fn update_weak_pointers() callconv(.c) void {
    scanEphemerons();
    updateEphemerons();
    updateWeakPairs();
}

const TNP = @intFromEnum(abi.GcType.non_pointer);
const TPR = @intFromEnum(abi.GcType.pair);
const TTR = @intFromEnum(abi.GcType.triple);
const TQD = @intFromEnum(abi.GcType.quadruple);
const TCL = @intFromEnum(abi.GcType.cell);
const TVC = @intFromEnum(abi.GcType.vector);
const TSP = @intFromEnum(abi.GcType.special);
const TUD = @intFromEnum(abi.GcType.undefined);
const TCE = @intFromEnum(abi.GcType.compiled_entry);
const TCR = @intFromEnum(abi.GcType.compiled_return);

pub export var gc_type_map: [obj.n_type_codes]c_int = .{
    TNP, // 0x00 TC_FALSE
    TPR, // 0x01 TC_LIST
    TNP, // 0x02 TC_CHARACTER
    TPR, // 0x03 TC_SCODE_QUOTE
    TCR, // 0x04 TC_COMPILED_RETURN
    TPR, // 0x05 TC_UNINTERNED_SYMBOL
    TVC, // 0x06 TC_BIG_FLONUM
    TPR, // 0x07 TC_APPLY_HOOK
    TNP, // 0x08 TC_CONSTANT
    TPR, // 0x09 TC_EXTENDED_PROCEDURE
    TVC, // 0x0A TC_VECTOR
    TNP, // 0x0B TC_RETURN_CODE
    TUD, // 0x0C was TC_COMBINATION_2
    TSP, // 0x0D TC_MANIFEST_CLOSURE
    TVC, // 0x0E TC_BIG_FIXNUM
    TPR, // 0x0F TC_PROCEDURE
    TPR, // 0x10 TC_ENTITY
    TPR, // 0x11 TC_DELAY
    TVC, // 0x12 TC_ENVIRONMENT
    TPR, // 0x13 TC_DELAYED
    TTR, // 0x14 TC_EXTENDED_LAMBDA
    TPR, // 0x15 TC_COMMENT
    TVC, // 0x16 TC_NON_MARKED_VECTOR
    TPR, // 0x17 TC_LAMBDA
    TNP, // 0x18 TC_PRIMITIVE
    TPR, // 0x19 TC_SEQUENCE
    TNP, // 0x1A TC_FIXNUM
    TVC, // 0x1B TC_UNICODE_STRING
    TVC, // 0x1C TC_CONTROL_POINT
    TPR, // 0x1D TC_INTERNED_SYMBOL
    TVC, // 0x1E TC_CHARACTER_STRING
    TPR, // 0x1F TC_ACCESS
    TTR, // 0x20 TC_HUNK3_A
    TPR, // 0x21 TC_DEFINITION
    TSP, // 0x22 TC_BROKEN_HEART
    TPR, // 0x23 TC_ASSIGNMENT
    TTR, // 0x24 TC_HUNK3_B
    TPR, // 0x25 TC_TAGGED_OBJECT
    TVC, // 0x26 TC_COMBINATION
    TSP, // 0x27 TC_MANIFEST_NM_VECTOR
    TCE, // 0x28 TC_COMPILED_ENTRY
    TPR, // 0x29 TC_LEXPR
    TUD, // 0x2A was TC_PCOMB3
    TVC, // 0x2B TC_EPHEMERON
    TTR, // 0x2C TC_VARIABLE
    TNP, // 0x2D TC_THE_ENVIRONMENT
    TPR, // 0x2E TC_SYNTAX_ERROR
    TVC, // 0x2F TC_VECTOR_1B / TC_BIT_STRING
    TUD, // 0x30 was TC_PCOMB0
    TVC, // 0x31 TC_VECTOR_16B
    TSP, // 0x32 TC_REFERENCE_TRAP
    TVC, // 0x33 TC_BYTEVECTOR
    TTR, // 0x34 TC_CONDITIONAL
    TPR, // 0x35 TC_DISJUNCTION
    TCL, // 0x36 TC_CELL
    TPR, // 0x37 TC_WEAK_CONS
    TQD, // 0x38 TC_QUAD
    TSP, // 0x39 TC_LINKAGE_SECTION
    TPR, // 0x3A TC_RATNUM
    TNP, // 0x3B TC_STACK_ENVIRONMENT
    TPR, // 0x3C TC_COMPLEX
    TVC, // 0x3D TC_COMPILED_CODE_BLOCK
    TVC, // 0x3E TC_RECORD
    TUD, // 0x3F
};

pub export fn gc_type_code(type_code: c_uint) callconv(.c) c_int {
    return gc_type_map[@intCast(type_code)];
}

pub export fn gc_ptr_type(object: obj.SchemeObject) callconv(.c) c_int {
    return switch (@as(abi.GcType, @enumFromInt(abi.gcType(object)))) {
        .special => if (obj.objectType(object) == obj.tc_reference_trap and obj.objectDatum(object) >= obj.trap_max_immediate)
            @intFromEnum(abi.GcPtrType.normal)
        else
            @intFromEnum(abi.GcPtrType.not),
        .cell, .pair, .triple, .quadruple, .vector => @intFromEnum(abi.GcPtrType.normal),
        .compiled_entry => @intFromEnum(abi.GcPtrType.compiled_entry),
        .compiled_return => @intFromEnum(abi.GcPtrType.compiled_return),
        else => @intFromEnum(abi.GcPtrType.not),
    };
}

pub export fn get_object_address(object: obj.SchemeObject) callconv(.c) ?[*]obj.SchemeObject {
    return switch (@as(abi.GcPtrType, @enumFromInt(gc_ptr_type(object)))) {
        .normal => obj.objectAddress(object),
        .compiled_entry => if (comptime build_options.cc_support)
            abi.cc_entry_to_block_address(object)
        else
            null,
        .compiled_return => if (comptime build_options.cc_support)
            abi.cc_return_to_block_address(object)
        else
            null,
        .not => null,
    };
}

pub fn resetForTesting() void {
    discard_code_tospace();
    close_stage_tospace();
    closeTospace();
    tospace_start = null;
    tospace_end = null;
    p_fromspace_start = null;
    p_fromspace_end = null;
    gc_tospace_allocator = null;
    gc_abort_handler = null;
    current_gc_table = null;
    current_scan = null;
    current_object = obj.sharp_f;
    weak_chain = null;
    ephemeron_list = obj.sharp_f;
    ephemeron_queue = obj.sharp_f;
    scanning_ephemerons_p = false;
    std_gc_table_initialized = false;
    std_gc_table_storage = std.mem.zeroes(abi.GcTable);
    gc_scan_history_index = 0;
    gc_scan_history = @splat(null);
    gc_to_history = @splat(null);
    gc_scan_trap = null;
    gc_to_trap = null;
    gc_object_referenced = obj.sharp_f;
    gc_object_references = obj.sharp_f;
    gc_object_references_count = 0;
    gc_object_references_scan = null;
    gc_object_references_end = null;
    weak_chain_length = 0;
}

test "gcloop type map, copying pairs/vectors, weak pairs, ephemerons, code/stage tospace, and debugging refs" {
    const stubs = @import("test_stubs.zig");
    const storage = @import("storage.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    // 1. gc_type_map / gc_type_code / gc_ptr_type
    try std.testing.expectEqual(@intFromEnum(abi.GcType.non_pointer), gc_type_code(@intCast(obj.tc_fixnum)));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.pair), gc_type_code(@intCast(obj.tc_pair)));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.triple), gc_type_code(@intCast(obj.tc_hunk3_a)));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.quadruple), gc_type_code(@intCast(obj.tc_quad)));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.vector), gc_type_code(@intCast(obj.tc_vector)));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.undefined), gc_type_code(0x0C));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.undefined), gc_type_code(0x2A));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.undefined), gc_type_code(0x30));
    try std.testing.expectEqual(@intFromEnum(abi.GcType.undefined), gc_type_code(0x3F));

    try std.testing.expectEqual(@intFromEnum(abi.GcPtrType.not), gc_ptr_type(obj.unassigned_object));
    const heap_base = storage.heap_start.?;
    const trap_ptr_cell = heap_base + 10;
    const far_trap = obj.makePointerObject(obj.tc_reference_trap, trap_ptr_cell);
    try std.testing.expectEqual(@intFromEnum(abi.GcPtrType.normal), gc_ptr_type(far_trap));
    try std.testing.expectEqual(trap_ptr_cell, get_object_address(far_trap).?);
    try std.testing.expectEqual(@as(?[*]obj.SchemeObject, null), get_object_address(obj.ulongToFixnum(5)));

    // 2. Copying pairs (with eager CDR), vector, weak pairs (live & dead), and ephemerons (live, transitive, dead)
    const eph_vec = heap_base + 200;
    eph_vec[0] = obj.makeVectorHeader(11);
    for (1..12) |i| eph_vec[i] = obj.sharp_f;
    storage.ephemeron_array = obj.makePointerObject(obj.tc_vector, eph_vec);
    storage.ephemeron_count = 0;

    // Allocate oldspace objects starting at heap_base + 300
    var alloc = heap_base + 300;
    const live_pair_addr = alloc;
    alloc += 2;
    live_pair_addr[0] = obj.ulongToFixnum(11);
    live_pair_addr[1] = obj.sharp_t;
    const live_pair = obj.makePointerObject(obj.tc_pair, live_pair_addr);

    const cdr_pair_addr = alloc;
    alloc += 2;
    cdr_pair_addr[0] = obj.ulongToFixnum(22);
    cdr_pair_addr[1] = obj.empty_list;

    const head_pair_addr = alloc;
    alloc += 2;
    head_pair_addr[0] = live_pair;
    head_pair_addr[1] = obj.makePointerObject(obj.tc_pair, cdr_pair_addr);
    const head_pair = obj.makePointerObject(obj.tc_pair, head_pair_addr);

    const dead_pair_addr = alloc;
    alloc += 2;
    dead_pair_addr[0] = obj.ulongToFixnum(99);
    dead_pair_addr[1] = obj.empty_list;
    const dead_pair = obj.makePointerObject(obj.tc_pair, dead_pair_addr);

    const dead_datum_addr = alloc;
    alloc += 2;
    dead_datum_addr[0] = obj.ulongToFixnum(777);
    dead_datum_addr[1] = obj.sharp_f;

    const trans_datum_addr = alloc;
    alloc += 2;
    trans_datum_addr[0] = obj.ulongToFixnum(888);
    trans_datum_addr[1] = obj.sharp_f;

    const wp_live_addr = alloc;
    alloc += 2;
    wp_live_addr[0] = live_pair;
    wp_live_addr[1] = obj.ulongToFixnum(1);
    const wp_live = obj.makePointerObject(obj.tc_weak_cons, wp_live_addr);

    const wp_dead_addr = alloc;
    alloc += 2;
    wp_dead_addr[0] = dead_pair;
    wp_dead_addr[1] = obj.ulongToFixnum(2);
    const wp_dead = obj.makePointerObject(obj.tc_weak_cons, wp_dead_addr);

    const trans_key_addr = alloc;
    alloc += 2;
    trans_key_addr[0] = obj.ulongToFixnum(555);
    trans_key_addr[1] = obj.sharp_f;
    const trans_key = obj.makePointerObject(obj.tc_pair, trans_key_addr);

    const eph_live_addr = alloc;
    alloc += abi.ephemeron_size;
    eph_live_addr[0] = abi.marked_ephemeron_manifest;
    eph_live_addr[abi.ephemeron_key] = live_pair;
    eph_live_addr[abi.ephemeron_datum] = trans_key;
    eph_live_addr[abi.ephemeron_list] = obj.sharp_f;
    eph_live_addr[abi.ephemeron_next] = obj.sharp_f;

    const eph_trans_addr = alloc;
    alloc += abi.ephemeron_size;
    eph_trans_addr[0] = abi.marked_ephemeron_manifest;
    eph_trans_addr[abi.ephemeron_key] = trans_key;
    eph_trans_addr[abi.ephemeron_datum] = obj.makePointerObject(obj.tc_pair, trans_datum_addr);
    eph_trans_addr[abi.ephemeron_list] = obj.sharp_f;
    eph_trans_addr[abi.ephemeron_next] = obj.sharp_f;

    const eph_dead_addr = alloc;
    alloc += abi.ephemeron_size;
    eph_dead_addr[0] = abi.marked_ephemeron_manifest;
    eph_dead_addr[abi.ephemeron_key] = obj.makePointerObject(obj.tc_pair, dead_pair_addr);
    eph_dead_addr[abi.ephemeron_datum] = obj.makePointerObject(obj.tc_pair, dead_datum_addr);
    eph_dead_addr[abi.ephemeron_list] = obj.sharp_f;
    eph_dead_addr[abi.ephemeron_next] = obj.sharp_f;

    const root_vec_addr = alloc;
    alloc += 6;
    root_vec_addr[0] = obj.makeVectorHeader(5);
    root_vec_addr[1] = head_pair;
    root_vec_addr[2] = wp_live;
    root_vec_addr[3] = wp_dead;
    root_vec_addr[4] = obj.makePointerObject(obj.tc_ephemeron, eph_live_addr);
    root_vec_addr[5] = obj.makePointerObject(obj.tc_ephemeron, eph_trans_addr);

    const root_vec2_addr = alloc;
    alloc += 2;
    root_vec2_addr[0] = obj.makeVectorHeader(1);
    root_vec2_addr[1] = obj.makePointerObject(obj.tc_ephemeron, eph_dead_addr);

    storage.Free = alloc;

    open_tospace(heap_base);
    initialize_weak_chain();
    current_gc_table = std_gc_table();
    const scan_start = get_newspace_ptr();
    if (comptime build_options.debugging) {
        const ref_vec_addr = alloc;
        alloc += 5;
        ref_vec_addr[0] = obj.makeVectorHeader(4);
        storage.Free = alloc;
        collectGcObjectReferencesImpl(live_pair, obj.makePointerObject(obj.tc_vector, ref_vec_addr));
        initializeGcObjectReferencesImpl();
    }

    const root_slot = get_newspace_ptr();
    add_to_tospace(obj.makePointerObject(obj.tc_vector, root_vec_addr));
    add_to_tospace(obj.makePointerObject(obj.tc_vector, root_vec2_addr));
    gc_drain_tospace_and_code_arena(scan_start);
    if (comptime build_options.debugging) {
        finalizeGcObjectReferencesImpl();
        const ref_vec = read_tospace(scan_start);
        const ref_count = obj.fixnumToUlong(read_tospace(obj.objectAddress(ref_vec) + 1));
        try std.testing.expect(ref_count >= 1);
    }
    update_weak_pointers();
    const new_free = get_newspace_ptr();
    try std.testing.expect(save_tospace(&(struct {
        fn copy(start: [*]obj.SchemeObject, end: [*]obj.SchemeObject, _: ?*anyopaque) callconv(.c) bool {
            const bytes = @intFromPtr(end) - @intFromPtr(start);
            const dst: [*]u8 = @ptrCast(tospace_to_newspace(@ptrCast(start)).?);
            const src: [*]const u8 = @ptrCast(start);
            std.mem.copyForwards(u8, dst[0..bytes], src[0..bytes]);
            return true;
        }
    }).copy, null));
    _ = new_free;

    // Verify weak pairs & ephemerons in saved newspace
    const new_root = root_slot[0];
    const new_wp_live = obj.vectorRef(new_root, 1);
    const new_wp_dead = obj.vectorRef(new_root, 2);
    const new_eph_live = obj.vectorRef(new_root, 3);
    const new_eph_trans = obj.vectorRef(new_root, 4);
    const new_eph_dead = obj.vectorRef(root_slot[1], 0);

    try std.testing.expectEqual(obj.tc_pair, obj.objectType(obj.pairCar(new_wp_live)));
    try std.testing.expectEqual(obj.gc_reclaimed, obj.pairCar(new_wp_dead));
    try std.testing.expectEqual(abi.marked_ephemeron_manifest, obj.objectAddress(new_eph_live)[0]);
    try std.testing.expectEqual(obj.tc_pair, obj.objectType(obj.objectAddress(new_eph_trans)[abi.ephemeron_datum]));
    try std.testing.expectEqual(obj.sharp_f, obj.objectAddress(new_eph_dead)[abi.ephemeron_key]);
    try std.testing.expectEqual(obj.sharp_f, obj.objectAddress(new_eph_dead)[abi.ephemeron_datum]);

    // 3. code_tospace interior 4-byte translation & stage_tospace
    try std.testing.expect(open_code_tospace(32));
    defer discard_code_tospace();
    try std.testing.expect(code_tospace_available_p(16));
    const cstart = get_code_newspace_start().?;
    try std.testing.expectEqual(cstart, get_code_newspace_ptr().?);
    const interior_new: *anyopaque = @ptrFromInt(@intFromPtr(cstart) + 4);
    const interior_to = newspace_to_tospace(interior_new).?;
    try std.testing.expectEqual(@intFromPtr(code_tospace_start.?) + 4, @intFromPtr(interior_to));
    try std.testing.expectEqual(@intFromPtr(interior_new), @intFromPtr(tospace_to_newspace(interior_to).?));

    var stage_orig: [4]obj.SchemeObject = .{ obj.ulongToFixnum(1), obj.ulongToFixnum(2), 0, 0 };
    var stage_buf: [4]obj.SchemeObject = .{ obj.ulongToFixnum(3), obj.ulongToFixnum(4), 0, 0 };
    open_stage_tospace(&stage_orig, &stage_buf, 4);
    try std.testing.expectEqual(@intFromPtr(&stage_buf[2]), @intFromPtr(newspace_to_tospace(@ptrCast(&stage_orig[2])).?));
    gc_scan_stage_tospace();
    close_stage_tospace();
}
