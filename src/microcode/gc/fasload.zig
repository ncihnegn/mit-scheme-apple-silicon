// Derived from MIT/GNU Scheme C sources (`src/microcode/fasload.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const outf = @import("../support/outf.zig");
const fasl = @import("fasl.zig");
const memmag = @import("memmag.zig");
const code_arena = @import("../compiler/code_arena.zig");
const jit = @import("../compiler/jit.zig");
const transact = @import("../support/transact.zig");
const wind = @import("../support/wind.zig");
const ptrvec = @import("../support/ptrvec.zig");
const primutl = @import("../runtime/primutl.zig");
const intern = @import("../runtime/intern.zig");
const string = @import("../data/string.zig");
const boot = @import("../core/boot.zig");
const storage = @import("../core/storage.zig");
const utils = @import("../core/utils.zig");

const oldest_input_fasl_version: c_uint = fasl.fasl_version_c_code;
const newest_input_fasl_version: c_uint = fasl.fasl_version_code_space;

const CleanupFn = *const fn () callconv(.c) void;

const LoadBandTerminationState = struct {
    file_name: [*:0]u8,
    no_return_p: bool,
};

const CodeLoadAbortState = struct {
    start: [*]obj.SchemeObject,
    n_words: usize,
};

var fasl_header: fasl.FaslHeader = undefined;
var fh: *fasl.FaslHeader = &fasl_header;
var new_heap_start: ?[*]obj.SchemeObject = null;
var new_constant_start: ?[*]obj.SchemeObject = null;
var new_code_start: ?[*]obj.SchemeObject = null;
var new_code_end: ?[*]obj.SchemeObject = null;
var new_stack_start: ?[*]obj.SchemeObject = null;
var new_stack_end: ?[*]obj.SchemeObject = null;
var new_utilities: ?[*]obj.SchemeObject = null;
var new_prim_table: ?[*]obj.SchemeObject = null;
var failed_heap_length: usize = 0;

var reload_band_name: ?[*:0]const u8 = null;
var reload_cleanups: ?*ptrvec.Ptrvec = null;
var reload_heap_size: usize = 0;
var reload_constant_size: usize = 0;

var relocate_table_initialized: bool = false;
var relocate_table: abi.GcTable = undefined;
var intern_table_initialized: bool = false;
var intern_table: abi.GcTable = undefined;

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

inline fn requiredHeap(h: *fasl.FaslHeader) usize {
    return fasl.ptrRangeWords(h.heap_end, h.heap_start) +
        h.n_primitives +
        h.primitive_table_size;
}

fn exitCriticalSection() void {
    if (boot.critical_section_hook_p) {
        const name = boot.critical_section_name;
        boot.critical_section_hook_p = false;
        boot.critical_section_name = null;
        if (boot.critical_section_hook) |hook| {
            hook(name);
        }
    } else {
        boot.critical_section_name = null;
    }
}

// DEFINE_PRIMITIVE ("BINARY-FASLOAD", Prim_binary_fasload, 1, 1, "(NAMESTRING)\n\
// Load the contents of the file NAMESTRING into memory.  The file was\n\
// presumably made by a call to PRIMITIVE-FASDUMP, and may contain data\n\
// for the heap and/or the pure area.  The value returned is the object\n\
// that was dumped.")
pub export fn Prim_binary_fasload() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    transact.transaction_begin();

    var handle: fasl.FaslFileHandle = null;
    initFaslFile(stringArg(1), false, &handle);
    if (fasl.ptrRangeWords(fh.constant_end, fh.constant_start) > 0) {
        abi.signal_error_from_primitive(abi.err_fasl_file_too_big);
    }

    const heap_length = requiredHeap(fh);
    var n_ephemerons: usize = 0;
    var extra_ephemeron_space: usize = 0;
    if (fh.version >= fasl.fasl_version_ephemerons) {
        n_ephemerons = fh.ephemeron_count;
        extra_ephemeron_space = memmag.compute_extra_ephemeron_space(storage.ephemeron_count + n_ephemerons);
    }
    if (abi.gcNeededP(heap_length + extra_ephemeron_space)) {
        if (heap_length == failed_heap_length) {
            abi.signal_error_from_primitive(abi.err_fasl_file_too_big);
        }
        failed_heap_length = heap_length;
        storage.n_ephemerons_requested = n_ephemerons;
        storage.ephemeron_request_hard_p = false;
        abi.requestGc(heap_length);
        abi.signal_interrupt_from_primitive();
    }
    failed_heap_length = 0;

    const result = loadFile(handle, storage.ephemeron_count);
    transact.transaction_commit();
    return result;
}

fn initFaslFile(file_name: [*:0]const u8, band_p: bool, handle: *fasl.FaslFileHandle) void {
    if (!fasl.open_fasl_input_file(file_name, handle)) {
        abi.error_bad_range_arg(1);
    }
    transact.transaction_record_action(.tat_always, &closeFaslFile, @ptrCast(handle));

    fh = &fasl_header;
    if (!fasl.read_fasl_header(fh, handle.*)) {
        abi.signal_error_from_primitive(abi.err_fasl_file_bad_data);
    }

    if (fasl.check_fasl_version(fh) != fasl.fasl_file_fine) {
        outf.err("\nBad version in FASL File: {s}\n", .{file_name});
        outf.err("File has: version {d} architecture {d}.\n", .{ fh.version, fh.arch });
        outf.err(
            "Expected: version between {d} and {d} architecture {d}.\n",
            .{
                oldest_input_fasl_version,
                newest_input_fasl_version,
                fasl.currentFaslArch(),
            },
        );
        abi.signal_error_from_primitive(abi.err_fasl_file_bad_data);
    }

    if (fasl.check_fasl_cc_version(fh, abi.compiler_interface_version, abi.compiler_processor_type) != fasl.fasl_file_fine) {
        outf.err("\nBad compiled-code version in FASL File: {s}\n", .{file_name});
        outf.err("File has: compiled-code interface {d}; architecture {d}.\n", .{ fh.cc_version, fh.cc_arch });
        outf.err(
            "Expected: compiled-code interface {d}; architecture {d}.\n",
            .{
                abi.compiler_interface_version,
                abi.compiler_processor_type,
            },
        );
        abi.signal_error_from_primitive(abi.err_fasload_compiled_mismatch);
    }

    if (fh.band_p != band_p) {
        abi.signal_error_from_primitive(abi.err_fasload_band);
    }
}

fn closeFaslFile(p: ?*anyopaque) callconv(.c) void {
    const handle: *const fasl.FaslFileHandle = @ptrCast(@alignCast(p.?));
    _ = fasl.close_fasl_input_file(handle.*);
}

// DEFINE_PRIMITIVE ("LOAD-BAND", Prim_band_load, 1, 1, "(NAMESTRING)\n\
// Restores the heap and constant space from the contents of the file\n\
// NAMESTRING, which is typically a file created by DUMP-BAND.  The file\n\
// can, however, be any file which can be loaded with BINARY-FASLOAD.")
pub export fn Prim_band_load() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, string.string_p);
    abi.canonicalize_primitive_context();
    const result = readBandFile(abi.argRef(1));

    // Reset implementation state parameters.
    abi.initializeInterrupts(0);
    if (build_options.cc_support) {
        abi.compiler_utilities = obj.pairCdr(result);
        if (abi.compiler_utilities != obj.sharp_f) {
            abi.compiler_reset(abi.compiler_utilities);
        } else {
            abi.compiler_initialize(true);
        }
    }
    abi.fixed_objects = obj.sharp_f;

    // Setup initial program
    abi.stackCheck(abi.cont_size);
    abi.pushCont(abi.rc_end_of_computation, obj.sharp_f);
    abi.Registers[abi.regblock_expr] = obj.pairCar(result);
    abi.Registers[abi.regblock_env] = obj.the_global_env;

    // Clear various interpreter state parameters.
    storage.trapping = false;
    utils.history_register = utils.make_dummy_history();
    utils.prev_restore_history_offset = 0;
    memmag.ccTransportEnd();
    execute_reload_cleanups();
    exitCriticalSection();

    // Return in a non-standard way.
    abi.abort_to_interpreter(abi.prim_do_expression);
}

fn readBandFile(s: obj.SchemeObject) obj.SchemeObject {
    transact.transaction_begin();
    const name_len: usize = @intCast(obj.legacyStringLength(s));
    const file_name_buf: [*]u8 = @ptrCast(abi.OS_malloc(name_len + 1).?);
    if (name_len > 0) {
        @memcpy(file_name_buf[0..name_len], obj.legacyStringData(s)[0..name_len]);
    }
    file_name_buf[name_len] = 0;
    const file_name: [*:0]u8 = @ptrCast(file_name_buf);

    const state: *LoadBandTerminationState = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(LoadBandTerminationState)).?));
    state.file_name = file_name;
    state.no_return_p = false;
    transact.transaction_record_action(.tat_abort, &terminateBandLoad, @ptrCast(state));

    var handle: fasl.FaslFileHandle = null;
    initFaslFile(file_name, true, &handle);

    const extra_eph: usize = if (fh.version >= fasl.fasl_version_ephemerons)
        memmag.compute_extra_ephemeron_space(fh.ephemeron_count)
    else
        0;
    if (!memmag.allocations_ok_p(
        fasl.ptrRangeWords(fh.constant_end, fh.constant_start),
        requiredHeap(fh) + extra_eph,
        fh.heap_reserved,
    )) {
        abi.signal_error_from_primitive(abi.err_fasl_file_too_big);
    }

    // Past this point we can't abort and return to the old image.
    boot.critical_section_name = "band load";
    state.no_return_p = true;

    memmag.reset_allocator_parameters(fasl.ptrRangeWords(fh.constant_end, fh.constant_start), fh.heap_reserved);
    code_arena.code_arena_reset(fasl.ptrRangeWords(fh.code_end, fh.code_start));
    storage.ephemeron_array = obj.sharp_f;
    const result = loadFile(handle, 0);

    transact.transaction_commit();

    const old_name = reload_band_name;
    reload_band_name = file_name;
    if (old_name) |old| {
        abi.OS_free(@ptrCast(@constCast(old)));
    }
    return result;
}

fn terminateBandLoad(ap: ?*anyopaque) callconv(.c) void {
    const state: *LoadBandTerminationState = @ptrCast(@alignCast(ap.?));
    if (!state.no_return_p) {
        abi.OS_free(@ptrCast(state.file_name));
        return;
    }

    var abort_value = abi.abort_to_interpreter_argument();
    outf.fatal("\nload-band: ", .{});
    if (abort_value > 0) {
        const message: ?[*:0]const u8 = if (abort_value <= abi.max_error)
            storage.Error_Names[@intCast(abort_value)]
        else
            null;
        if (message) |msg| {
            outf.fatal("Error 0x{x} ({s})", .{ @as(usize, @intCast(abort_value)), msg });
        } else {
            outf.fatal("Unknown error 0x{x}", .{@as(usize, @intCast(abort_value))});
        }
    } else {
        abort_value = (-abort_value) - 1;
        const msg: [*:0]const u8 = if (abort_value >= 0 and @as(usize, @intCast(abort_value)) < storage.Abort_Names.len)
            storage.Abort_Names[@intCast(abort_value)]
        else
            "UNKNOWN";
        outf.fatal("Abort {d} ({s})", .{ abort_value, msg });
    }
    outf.fatal(" past the point of no return.\n", .{});
    outf.fatal("file name = \"{s}\".\n", .{state.file_name});
    abi.OS_free(@ptrCast(state.file_name));

    execute_reload_cleanups();
    exitCriticalSection();
    abi.Microcode_Termination(abi.term_disk_restore);
}

// DEFINE_PRIMITIVE ("RELOAD-BAND-NAME", Prim_reload_band_name, 0, 0, "()\n\
// Return the filename from which the runtime system was last restored.\n\
// The result is a string, or #F if the system was not restored.")
pub export fn Prim_reload_band_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (reload_band_name) |name| {
        return string.char_pointer_to_string(name);
    }
    if (abi.option_band_file) |band| {
        return string.char_pointer_to_string(band);
    }
    return obj.sharp_f;
}

pub export fn get_band_parameters(heap_size: *usize, const_size: *usize) callconv(.c) void {
    heap_size.* = reload_heap_size;
    const_size.* = reload_constant_size;
}

pub export fn add_reload_cleanup(cleanup_procedure: CleanupFn) callconv(.c) void {
    const fn_ptr: ?*anyopaque = @ptrCast(@constCast(cleanup_procedure));
    if (reload_cleanups) |pv| {
        ptrvec.ptrvec_adjoin(pv, fn_ptr);
    } else {
        const pv = ptrvec.ptrvec_allocate(1);
        pv.elements.?[0] = fn_ptr;
        reload_cleanups = pv;
    }
}

pub export fn execute_reload_cleanups() callconv(.c) void {
    const pv = reload_cleanups orelse return;
    const elems = pv.elements orelse return;
    const count: usize = @intCast(pv.length);
    for (0..count) |idx| {
        if (elems[idx]) |raw_fn| {
            const cleanup: CleanupFn = @ptrCast(@alignCast(raw_fn));
            cleanup();
        }
    }
}

fn abortCodeLoad(ap: ?*anyopaque) callconv(.c) void {
    const state: *const CodeLoadAbortState = @ptrCast(@alignCast(ap.?));
    code_arena.code_arena_mark_hole(state.start, state.n_words);
    code_arena.code_arena_rebuild_free_list();
}

fn loadFile(handle: fasl.FaslFileHandle, old_ephemeron_count: usize) obj.SchemeObject {
    new_heap_start = abi.Free;
    new_constant_start = abi.constant_alloc_next;
    new_code_start = null;
    new_code_end = null;
    new_stack_start = abi.stack_start;
    new_stack_end = abi.stack_end;
    new_utilities = if (abi.compiler_utilities == obj.sharp_f)
        null
    else
        obj.objectAddress(abi.compiler_utilities);

    const heap_size = fasl.ptrRangeWords(fh.heap_end, fh.heap_start);
    const const_size = fasl.ptrRangeWords(fh.constant_end, fh.constant_start);
    const code_words = fasl.ptrRangeWords(fh.code_end, fh.code_start);

    abi.Free = readFromFile(abi.Free, heap_size, handle);
    abi.constant_alloc_next = readFromFile(abi.constant_alloc_next, const_size, handle);

    if (code_words > 0) {
        const dst = code_arena.code_arena_alloc(code_words) orelse {
            abi.signal_error_from_primitive(abi.err_fasl_file_too_big);
        };
        new_code_start = dst;
        if (!fh.band_p) {
            const abort_state: *CodeLoadAbortState = @ptrCast(@alignCast(wind.dstack_alloc(@sizeOf(CodeLoadAbortState)).?));
            abort_state.start = dst;
            abort_state.n_words = @max(code_words, 2);
            transact.transaction_record_action(.tat_abort, &abortCodeLoad, @ptrCast(abort_state));
        }
        const scope = code_arena.code_arena_write_scope_begin();
        new_code_end = readCodeFromFile(dst, @intCast(code_words), handle);
        code_arena.code_arena_write_scope_end(scope);
    }

    const prim_table_ptr = abi.Free;
    new_prim_table = prim_table_ptr;
    const raw_prim_table = prim_table_ptr + @as(usize, @intCast(fh.n_primitives));
    _ = readFromFile(raw_prim_table, @intCast(fh.primitive_table_size), handle);
    primutl.import_primitive_table(raw_prim_table, fh.n_primitives, prim_table_ptr);

    if (!fh.band_p and
        fh.utilities_vector != obj.sharp_f and
        abi.compiler_utilities == obj.sharp_f)
    {
        // File contains compiled code, but no compiled-code support available.
        abi.signal_error_from_primitive(abi.err_fasload_compiled_mismatch);
    }

    const already_relocated = fh.band_p and
        ptrAddr(fh.heap_start) == ptrAddr(new_heap_start) and
        (ptrAddr(fh.constant_start) == ptrAddr(new_constant_start) or
            ptrAddr(fh.constant_start) == ptrAddr(fh.constant_end)) and
        (code_words == 0 or ptrAddr(fh.code_start) == ptrAddr(new_code_start)) and
        (ptrAddr(fh.stack_start) == 0 or ptrAddr(fh.stack_start) == ptrAddr(new_stack_start)) and
        ptrAddr(fh.stack_end) == ptrAddr(new_stack_end) and
        (obj.heap_in_low_memory or ptrAddr(fh.memory_base) == ptrAddr(obj.memory_base)) and
        primitiveNumbersUnchangedP(prim_table_ptr);

    if (!already_relocated) {
        abi.current_gc_table = @ptrCast(relocateBlockTable());
        abi.gc_scan_oldspace(new_heap_start.?, abi.Free);
        abi.gc_scan_oldspace(new_constant_start.?, abi.constant_alloc_next);
        if (ptrAddr(new_code_end) > ptrAddr(new_code_start)) {
            const scope = code_arena.code_arena_write_scope_begin();
            abi.gc_scan_oldspace(new_code_start.?, new_code_end.?);
            code_arena.code_arena_write_scope_end(scope);
        }
    }

    if (!fh.band_p) {
        abi.current_gc_table = @ptrCast(internBlockTable());
        abi.gc_scan_oldspace(new_heap_start.?, abi.Free);
        abi.gc_scan_oldspace(new_constant_start.?, abi.constant_alloc_next);
        if (ptrAddr(new_code_end) > ptrAddr(new_code_start)) {
            const scope = code_arena.code_arena_write_scope_begin();
            abi.gc_scan_oldspace(new_code_start.?, new_code_end.?);
            code_arena.code_arena_write_scope_end(scope);
        }
    }

    if (ptrAddr(new_code_end) > ptrAddr(new_code_start)) {
        if (fh.band_p) {
            code_arena.code_arena_rebuild_free_list();
        }
        const byte_len = fasl.ptrRangeWords(new_code_end, new_code_start) * @sizeOf(obj.SchemeObject);
        jit.jit_flush_icache(@ptrCast(new_code_start.?), @intCast(byte_len));
    }

    if (comptime (build_options.cc_is_native and builtin.cpu.arch == .aarch64)) {
        if (fh.cc_version != abi.compiler_none_type) {
            if (heap_size > 0) {
                abi.aarch64_flush_i_cache_region(new_heap_start.?, @intCast(heap_size));
            }
            if (const_size > 0) {
                abi.aarch64_flush_i_cache_region(new_constant_start.?, @intCast(const_size));
            }
        }
    }

    if (fh.version >= fasl.fasl_version_ephemerons) {
        memmag.guarantee_extra_ephemeron_space(old_ephemeron_count + fh.ephemeron_count);
    }

    const root_ptr: *const obj.SchemeObject = @ptrCast(@alignCast(relocateAddress(@ptrCast(fh.root_pointer))));
    return root_ptr.*;
}

fn readFromFile(p: [*]obj.SchemeObject, n_words: usize, handle: fasl.FaslFileHandle) [*]obj.SchemeObject {
    if (!fasl.read_from_fasl_file(@ptrCast(p), n_words, handle)) {
        abi.signal_error_from_primitive(abi.err_fasl_file_bad_data);
    }
    return p + n_words;
}

// Stage file reads through an ordinary stack buffer so kernel copyout()
// never writes directly into a MAP_JIT VMA.
fn readCodeFromFile(dst_in: [*]obj.SchemeObject, n_words: usize, handle: fasl.FaslFileHandle) [*]obj.SchemeObject {
    var buf: [512]obj.SchemeObject = undefined;
    var dst = dst_in;
    var remaining = n_words;

    while (remaining > 0) {
        const chunk: usize = @min(remaining, buf.len);
        if (!fasl.read_from_fasl_file(@ptrCast(&buf), chunk, handle)) {
            abi.signal_error_from_primitive(abi.err_fasl_file_bad_data);
        }
        @memcpy(dst[0..chunk], buf[0..chunk]);
        dst += chunk;
        remaining -= chunk;
    }
    return dst;
}

fn primitiveNumbersUnchangedP(table: [*]const obj.SchemeObject) bool {
    const count: usize = @intCast(fh.n_primitives);
    for (0..count) |i| {
        if (table[i] != obj.makePrimitiveObject(@intCast(i))) {
            return false;
        }
    }
    return true;
}

fn relocateBlockTable() *abi.GcTable {
    if (!relocate_table_initialized) {
        abi.initialize_gc_table(&relocate_table, false);
        relocate_table.tuple_handler = &fasloadTuple;
        relocate_table.vector_handler = &fasloadVector;
        relocate_table.cc_entry_handler = &fasloadCcEntry;
        relocate_table.cc_return_handler = &fasloadCcReturn;
        relocate_table.raw_address_to_object = &fasloadRawAddressToObject;
        relocate_table.raw_address_to_cc_entry = &fasloadRawAddressToCcEntry;

        relocate_table.handlers[obj.tc_weak_cons] = &abi.gc_handle_pair;
        relocate_table.handlers[obj.tc_ephemeron] = &abi.gc_handle_unaligned_vector;
        relocate_table.handlers[obj.tc_primitive] = &handlePrimitive;
        relocate_table.handlers[obj.tc_broken_heart] = &abi.gc_handle_non_pointer;

        relocate_table_initialized = true;
    }
    return &relocate_table;
}

fn handlePrimitive(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    const datum = obj.objectDatum(object);
    const high_bits = datum >> obj.half_datum_length;
    const idx: usize = @intCast(if (high_bits != 0) high_bits else datum);
    scan[0] = obj.makeObjectFromObjects(object, new_prim_table.?[idx]);
    return scan + 1;
}

fn fasloadRawAddressToObject(type_code: c_uint, address: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return fasl.fasl_raw_address_to_object(type_code, address, fh);
}

fn fasloadRawAddressToCcEntry(address: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return fasl.fasl_raw_address_to_cc_entry(@ptrCast(@alignCast(address)), fh);
}

inline fn relocateObject(object: obj.SchemeObject) obj.SchemeObject {
    const old_addr = fasl.fasl_object_address(object, fh);
    const new_addr: [*]obj.SchemeObject = @ptrCast(@alignCast(relocateAddress(@ptrCast(old_addr))));
    return obj.objectNewAddress(object, new_addr);
}

fn fasloadTuple(tuple: obj.SchemeObject, _: c_uint) callconv(.c) obj.SchemeObject {
    return relocateObject(tuple);
}

fn fasloadVector(vector: obj.SchemeObject, _: bool) callconv(.c) obj.SchemeObject {
    return relocateObject(vector);
}

fn fasloadCcEntry(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (build_options.cc_support) {
        const old_addr = fasl.fasl_cc_address(object, fh);
        const new_raw = relocateAddress(@ptrCast(old_addr));
        return obj.objectNewRawAddress(object, @intFromPtr(new_raw));
    }
    return object;
}

fn fasloadCcReturn(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    if (build_options.cc_support) {
        const old_addr = fasl.fasl_cc_return(object, fh);
        const new_raw = relocateAddress(@ptrCast(old_addr));
        return obj.objectNewRawAddress(object, @intFromPtr(new_raw));
    }
    return object;
}

fn relocateAddress(vaddr: ?*anyopaque) *anyopaque {
    const caddr = ptrAddr(vaddr);

    const heap_start_addr = ptrAddr(fh.heap_start);
    const heap_end_addr = ptrAddr(fh.heap_end);
    const const_start_addr = ptrAddr(fh.constant_start);
    const const_end_addr = ptrAddr(fh.constant_end);
    const code_start_addr = ptrAddr(fh.code_start);
    const code_end_addr = ptrAddr(fh.code_end);
    const ut_start_addr = ptrAddr(fh.utilities_start);
    const ut_end_addr = ptrAddr(fasl.faslhdr_utilities_end(fh));
    const stack_start_addr = ptrAddr(fh.stack_start);
    const stack_end_addr = ptrAddr(fh.stack_end);

    const result_addr: usize = if (caddr >= heap_start_addr and caddr < heap_end_addr)
        ptrAddr(new_heap_start) + (caddr - heap_start_addr)
    else if (caddr >= const_start_addr and caddr < const_end_addr)
        ptrAddr(new_constant_start) + (caddr - const_start_addr)
    else if (caddr >= code_start_addr and caddr < code_end_addr)
        ptrAddr(new_code_start) + (caddr - code_start_addr)
    else if (caddr >= ut_start_addr and caddr < ut_end_addr)
        ptrAddr(new_utilities) + (caddr - ut_start_addr)
    else if (caddr >= stack_start_addr and caddr < stack_end_addr)
        ptrAddr(new_stack_end) - (stack_end_addr - caddr)
    else {
        outf.fatal("Pointer out of range: 0x{x}\n", .{caddr});
        outf.fatal(
            "Heap: 0x{x}-0x{x}, Constant: 0x{x}-0x{x}, Code: 0x{x}-0x{x}, Stack: 0x{x}-0x{x}\n",
            .{
                heap_start_addr,
                heap_end_addr,
                const_start_addr,
                const_end_addr,
                code_start_addr,
                code_end_addr,
                stack_start_addr,
                stack_end_addr,
            },
        );
        abi.signal_error_from_primitive(abi.err_fasl_file_bad_data);
    };

    return @ptrFromInt(result_addr);
}

fn internBlockTable() *abi.GcTable {
    if (!intern_table_initialized) {
        abi.initialize_gc_table(&intern_table, false);
        intern_table.tuple_handler = &internTuple;
        intern_table.vector_handler = &internVector;
        intern_table.cc_entry_handler = &internCcEntry;

        intern_table.handlers[obj.tc_weak_cons] = &abi.gc_handle_pair;
        intern_table.handlers[obj.tc_ephemeron] = &abi.gc_handle_unaligned_vector;
        intern_table.handlers[obj.tc_interned_symbol] = &internHandleSymbol;
        intern_table.handlers[obj.tc_broken_heart] = &abi.gc_handle_non_pointer;

        intern_table_initialized = true;
    }
    return &intern_table;
}

fn internHandleSymbol(scan: [*]obj.SchemeObject, object: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (obj.brokenHeartP(obj.symbolGlobalValue(object))) {
        obj.setSymbolGlobalValue(object, obj.unbound_object);
        const new_sym = intern.intern_symbol(object);
        if (new_sym != object) {
            scan[0] = new_sym;
            obj.setSymbolName(object, obj.objectNewType(obj.tc_broken_heart, new_sym));
        }
    } else if (obj.brokenHeartP(obj.symbolName(object))) {
        scan[0] = obj.makeObjectFromObjects(object, obj.symbolName(object));
    }
    return scan + 1;
}

fn internTuple(tuple: obj.SchemeObject, _: c_uint) callconv(.c) obj.SchemeObject {
    return tuple;
}

fn internVector(vector: obj.SchemeObject, _: bool) callconv(.c) obj.SchemeObject {
    return vector;
}

fn internCcEntry(object: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return object;
}

pub fn resetForTesting() void {
    if (reload_band_name) |old| {
        abi.OS_free(@ptrCast(@constCast(old)));
        reload_band_name = null;
    }
    if (reload_cleanups) |pv| {
        ptrvec.ptrvec_deallocate(pv);
        reload_cleanups = null;
    }
    reload_heap_size = 0;
    reload_constant_size = 0;
    failed_heap_length = 0;
    new_heap_start = null;
    new_constant_start = null;
    new_code_start = null;
    new_code_end = null;
    new_stack_start = null;
    new_stack_end = null;
    new_utilities = null;
    new_prim_table = null;
    relocate_table_initialized = false;
    intern_table_initialized = false;
}

test "fasload reload cleanups, band name, relocation regions, primitives, interning, and code read" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();
    resetForTesting();
    defer resetForTesting();

    wind.dstack_initialize();
    defer wind.dstack_reset();
    transact.transaction_initialize();

    // 1. get_band_parameters and execute_reload_cleanups before registration
    var h_sz: usize = 999;
    var c_sz: usize = 888;
    get_band_parameters(&h_sz, &c_sz);
    try std.testing.expectEqual(@as(usize, 0), h_sz);
    try std.testing.expectEqual(@as(usize, 0), c_sz);
    execute_reload_cleanups();

    const CleanupTracker = struct {
        var log: [4]u8 = @splat(0);
        var count: usize = 0;
        fn first() callconv(.c) void {
            log[count] = 'A';
            count += 1;
        }
        fn second() callconv(.c) void {
            log[count] = 'B';
            count += 1;
        }
    };
    add_reload_cleanup(&CleanupTracker.first);
    add_reload_cleanup(&CleanupTracker.second);
    add_reload_cleanup(&CleanupTracker.first);
    execute_reload_cleanups();
    try std.testing.expectEqual(@as(usize, 3), CleanupTracker.count);
    try std.testing.expectEqualStrings("ABA", CleanupTracker.log[0..3]);

    // 2. Prim_reload_band_name falls back to option_band_file or #f
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.sharp_f, Prim_reload_band_name());
    abi.option_band_file = "/mock/all.com";
    stubs.setArgs(&.{});
    const band_name_obj = Prim_reload_band_name();
    try std.testing.expectEqualStrings("/mock/all.com", obj.legacyStringData(band_name_obj)[0..obj.legacyStringLength(band_name_obj)]);

    // 3. Relocate across all 5 regions + 4-byte-aligned compiled entry/return addresses
    var old_mem: [64]obj.SchemeObject align(16) = @splat(0);
    var new_mem: [64]obj.SchemeObject align(16) = @splat(0);
    // Utilities block at old_mem[48..52]
    old_mem[48] = obj.makeNmvHeader(3);
    new_mem[48] = obj.makeNmvHeader(3);

    fh.* = std.mem.zeroes(fasl.FaslHeader);
    fh.version = fasl.fasl_version_code_space;
    fh.arch = fasl.currentFaslArch();
    fh.band_p = true;
    fh.heap_start = old_mem[0..8].ptr;
    fh.heap_end = old_mem[8..].ptr;
    fh.constant_start = old_mem[10..16].ptr;
    fh.constant_end = old_mem[16..].ptr;
    fh.code_start = old_mem[20..28].ptr;
    fh.code_end = old_mem[28..].ptr;
    fh.stack_start = old_mem[32..40].ptr;
    fh.stack_end = old_mem[40..].ptr;
    fh.utilities_vector = obj.makePointerObject(obj.tc_compiled_code_block, old_mem[48..52].ptr);
    fh.utilities_start = old_mem[48..52].ptr;
    fh.utilities_end = old_mem[52..].ptr;
    if (!obj.heap_in_low_memory) {
        fh.memory_base = obj.memory_base;
    }

    new_heap_start = new_mem[0..].ptr;
    new_constant_start = new_mem[10..].ptr;
    new_code_start = new_mem[20..].ptr;
    new_stack_start = new_mem[32..].ptr;
    new_stack_end = new_mem[40..].ptr;
    new_utilities = new_mem[48..].ptr;

    try std.testing.expectEqual(@intFromPtr(&new_mem[3]), @intFromPtr(relocateAddress(@ptrCast(&old_mem[3]))));
    try std.testing.expectEqual(@intFromPtr(&new_mem[12]), @intFromPtr(relocateAddress(@ptrCast(&old_mem[12]))));
    try std.testing.expectEqual(@intFromPtr(&new_mem[23]), @intFromPtr(relocateAddress(@ptrCast(&old_mem[23]))));
    try std.testing.expectEqual(@intFromPtr(&new_mem[49]), @intFromPtr(relocateAddress(@ptrCast(&old_mem[49]))));
    try std.testing.expectEqual(@intFromPtr(&new_mem[37]), @intFromPtr(relocateAddress(@ptrCast(&old_mem[37]))));

    // Verify 4-byte-aligned compiled entry & return relocation (requires objectNewRawAddress)
    const unaligned_old_cc = @intFromPtr(&old_mem[22]) + 4;
    const unaligned_new_cc = @intFromPtr(&new_mem[22]) + 4;
    const old_cc_entry = obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(unaligned_old_cc));
    const relocated_cc_entry = fasloadCcEntry(old_cc_entry);
    try std.testing.expectEqual(unaligned_new_cc, @intFromPtr(obj.objectRawAddress(relocated_cc_entry)));

    const old_cc_ret = obj.makeObject(obj.tc_compiled_return, obj.rawAddressToDatum(unaligned_old_cc));
    const relocated_cc_ret = fasloadCcReturn(old_cc_ret);
    try std.testing.expectEqual(unaligned_new_cc, @intFromPtr(obj.objectRawAddress(relocated_cc_ret)));

    // 4. handlePrimitive maps normal datum and high-bits datum via new_prim_table
    var ptab = [_]obj.SchemeObject{
        obj.makePrimitiveObject(4),
        obj.makePrimitiveObject(9),
        obj.makePrimitiveObject(12),
    };
    new_prim_table = &ptab;
    var prim_slot: [2]obj.SchemeObject = .{
        obj.makePrimitiveObject(1),
        obj.makePrimitiveObject((@as(usize, 2) << obj.half_datum_length) | 1),
    };
    _ = handlePrimitive(prim_slot[0..].ptr, prim_slot[0]);
    _ = handlePrimitive(prim_slot[1..].ptr, prim_slot[1]);
    try std.testing.expectEqual(obj.makePrimitiveObject(9), prim_slot[0]);
    try std.testing.expectEqual(obj.makePrimitiveObject(12), prim_slot[1]);

    // 5. internHandleSymbol deduplicates identical interned symbols
    const fixobj = abi.make_vector(abi.fixobj_gc_reclaimed + 1, obj.sharp_f, false);
    obj.vectorSet(fixobj, abi.fixobj_obarray, abi.make_vector(17, obj.empty_list, false));
    abi.fixed_objects = fixobj;

    const existing = intern.char_pointer_to_symbol("foo");
    const dup_name = string.char_pointer_to_string("foo");
    const dup_sym = abi.system_pair_cons(@intCast(obj.tc_interned_symbol), dup_name, obj.broken_heart_zero);
    var scan_sym: [1]obj.SchemeObject = .{dup_sym};
    _ = internHandleSymbol(&scan_sym, dup_sym);
    try std.testing.expectEqual(existing, scan_sym[0]);
    try std.testing.expectEqual(obj.unbound_object, obj.symbolGlobalValue(dup_sym));
    try std.testing.expect(obj.brokenHeartP(obj.symbolName(dup_sym)));
    // Second reference to same duplicate resolves via broken heart in symbolName
    var scan_sym2: [1]obj.SchemeObject = .{dup_sym};
    _ = internHandleSymbol(&scan_sym2, dup_sym);
    try std.testing.expectEqual(existing, scan_sym2[0]);

    // 6. readCodeFromFile handles > 512-word staged chunking cleanly
    const tmp = struct {
        extern "c" fn tmpfile() fasl.FaslFileHandle;
        extern "c" fn rewind(fasl.FaslFileHandle) void;
    };
    const f = tmp.tmpfile();
    try std.testing.expect(f != null);
    defer _ = fasl.close_fasl_input_file(f);

    var src_words: [600]obj.SchemeObject = undefined;
    var dst_words: [600]obj.SchemeObject = @splat(0);
    for (0..src_words.len) |i| {
        src_words[i] = 0xDEAD0000 + @as(obj.SchemeObject, @intCast(i));
    }
    try std.testing.expect(fasl.write_to_fasl_file(@ptrCast(&src_words), src_words.len, f));
    tmp.rewind(f);
    const end_dst = readCodeFromFile(&dst_words, dst_words.len, f);
    try std.testing.expectEqual(@intFromPtr(&dst_words) + dst_words.len * @sizeOf(obj.SchemeObject), @intFromPtr(end_dst));
    try std.testing.expectEqualSlices(obj.SchemeObject, &src_words, &dst_words);

    // 7. Table initializers install expected handlers
    const rt = relocateBlockTable();
    try std.testing.expectEqual(@intFromPtr(&handlePrimitive), @intFromPtr(rt.handlers[obj.tc_primitive].?));
    const it = internBlockTable();
    try std.testing.expectEqual(@intFromPtr(&internHandleSymbol), @intFromPtr(it.handlers[obj.tc_interned_symbol].?));
}
