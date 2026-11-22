const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("microcode_smoke").prim_abi;

pub const SchemeObject = usize;

pub const heap_in_low_memory: bool =
    builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86;

pub const type_code_length: usize = 6;
pub const datum_length: u6 = @as(comptime_int, @bitSizeOf(SchemeObject) - type_code_length);
pub const datum_mask: SchemeObject = (@as(SchemeObject, 1) << datum_length) - 1;
pub const tc_false: usize = 0x00;
pub const tc_list: usize = 0x01;
pub const tc_compiled_return: usize = 0x04;
pub const tc_constant: usize = 0x08;
pub const tc_vector: usize = 0x0A;
pub const tc_manifest_closure: usize = 0x0D;
pub const tc_fixnum: usize = 0x1A;
pub const tc_broken_heart: usize = 0x22;
pub const tc_manifest_nm_vector: usize = 0x27;
pub const tc_compiled_entry: usize = 0x28;
pub const tc_ephemeron: usize = 0x2B;
pub const tc_weak_cons: usize = 0x37;
pub const tc_compiled_code_block: usize = 0x3D;
pub const tc_manifest_vector: usize = tc_false;

pub const sharp_f: SchemeObject = makeObject(tc_false, 0);
pub const sharp_t: SchemeObject = makeObject(tc_constant, 0);
pub const gc_reclaimed: SchemeObject = makeObject(tc_constant, 10);

pub const Insn = if (build_options.cc_is_native and (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be))
    u32
else
    u8;

pub const is_native_aarch64: bool =
    build_options.cc_is_native and (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be);
pub const is_apple_jit: bool =
    builtin.os.tag.isDarwin() and builtin.cpu.arch == .aarch64;

pub const uuo_link_size: usize = if (build_options.cc_is_svm) 2 else 4;
pub const trampoline_k_apply: u8 = abi.trampoline_k_apply;

pub const fasl_version_c_code: c_uint = 10;
pub const fasl_version_code_space: c_uint = 13;
pub const fasl_file_fine: c_uint = 0;
pub const compiler_interface_version_value: c_uint = 4;

pub const FaslFileHandle = ?*anyopaque;

pub const FaslHeader = extern struct {
    version: c_uint,
    arch: c_uint,
    cc_version: c_uint,
    cc_arch: c_uint,
    band_p: bool,
    memory_base: ?[*]SchemeObject,
    root_pointer: ?[*]SchemeObject,
    heap_start: ?[*]SchemeObject,
    heap_end: ?[*]SchemeObject,
    heap_reserved: usize,
    constant_start: ?[*]SchemeObject,
    constant_end: ?[*]SchemeObject,
    code_start: ?[*]SchemeObject,
    code_end: ?[*]SchemeObject,
    stack_start: ?[*]SchemeObject,
    stack_end: ?[*]SchemeObject,
    n_primitives: usize,
    primitive_table_size: usize,
    n_c_code_blocks: usize,
    c_code_table_size: usize,
    utilities_vector: SchemeObject,
    utilities_start: ?[*]SchemeObject,
    utilities_end: ?[*]SchemeObject,
    ephemeron_count: usize,
};

comptime {
    std.debug.assert(abi.marked_ephemeron_manifest == makeVectorHeader(abi.ephemeron_size - 1));
    std.debug.assert(@sizeOf(SchemeObject) == @sizeOf(usize));
}

pub fn currentFaslArch() c_uint {
    if (build_options.cc_is_svm) {
        const endian = builtin.cpu.arch.endian();
        if (@sizeOf(usize) == 8) {
            return if (endian == .little) 29 else 28;
        }
        return if (endian == .little) 27 else 26;
    }
    return switch (builtin.cpu.arch) {
        .aarch64 => 25,
        .aarch64_be => 30,
        .x86_64 => 21,
        .x86 => 6,
        .arm => 24,
        .powerpc => 20,
        .powerpc64, .powerpc64le => 22,
        else => 0,
    };
}

pub inline fn makeObject(tc: usize, datum: usize) SchemeObject {
    return (tc << datum_length) | datum;
}

pub inline fn objectType(o: SchemeObject) usize {
    return o >> datum_length;
}

pub inline fn objectDatum(o: SchemeObject) usize {
    return o & datum_mask;
}

pub inline fn objectNewDatum(type_obj: SchemeObject, datum: usize) SchemeObject {
    return makeObject(objectType(type_obj), datum);
}

pub inline fn datumToAddress(datum: usize) [*]SchemeObject {
    comptime std.debug.assert(heap_in_low_memory);
    return @ptrFromInt(datum);
}

pub inline fn addressToDatum(addr: [*]const SchemeObject) usize {
    comptime std.debug.assert(heap_in_low_memory);
    return @intFromPtr(addr);
}

pub inline fn objectAddress(o: SchemeObject) [*]SchemeObject {
    return datumToAddress(objectDatum(o));
}

pub inline fn makePointerObject(tc: usize, addr: [*]const SchemeObject) SchemeObject {
    return makeObject(tc, addressToDatum(addr));
}

pub inline fn objectNewAddress(type_obj: SchemeObject, addr: [*]const SchemeObject) SchemeObject {
    return objectNewDatum(type_obj, addressToDatum(addr));
}

pub inline fn makeVectorHeader(length: usize) SchemeObject {
    return makeObject(tc_manifest_vector, length);
}

pub inline fn makeNmvHeader(length: usize) SchemeObject {
    return makeObject(tc_manifest_nm_vector, length);
}

pub inline fn ulongToFixnum(n: usize) SchemeObject {
    return makeObject(tc_fixnum, n);
}

pub inline fn brokenHeartP(o: SchemeObject) bool {
    return objectType(o) == tc_broken_heart;
}

pub inline fn pairP(o: SchemeObject) bool {
    return objectType(o) == tc_list;
}

pub inline fn pairCar(p: SchemeObject) SchemeObject {
    return objectAddress(p)[0];
}

pub inline fn pairCdr(p: SchemeObject) SchemeObject {
    return objectAddress(p)[1];
}

pub inline fn vectorRef(v: SchemeObject, index: usize) SchemeObject {
    return objectAddress(v)[index + 1];
}

pub inline fn memoryRef(o: SchemeObject, index: usize) SchemeObject {
    return objectAddress(o)[index];
}

pub inline fn makeCcBlock(addr: [*]const SchemeObject) SchemeObject {
    return makePointerObject(tc_compiled_code_block, addr);
}

pub inline fn makeCcEntry(addr: *const anyopaque) SchemeObject {
    return makePointerObject(tc_compiled_entry, @ptrCast(@alignCast(addr)));
}

pub inline fn ccEntryP(o: SchemeObject) bool {
    return objectType(o) == tc_compiled_entry;
}

pub inline fn ccReturnP(o: SchemeObject) bool {
    return objectType(o) == tc_compiled_return;
}

pub inline fn ccEntryAddress(entry: SchemeObject) [*]Insn {
    check(ccEntryP(entry), "CC_ENTRY_P");
    return @ptrCast(@alignCast(objectAddress(entry)));
}

pub inline fn ccReturnAddress(ret: SchemeObject) [*]Insn {
    check(ccReturnP(ret), "CC_RETURN_P");
    return @ptrCast(@alignCast(objectAddress(ret)));
}

pub inline fn ccEntryAddressPc(ep: [*]Insn) [*]Insn {
    if (build_options.cc_is_svm) unreachable;
    const off: isize = @intCast(@as(*align(1) const i64, @ptrFromInt(@intFromPtr(ep) - @sizeOf(i64))).*);
    const base: isize = @bitCast(@intFromPtr(ep));
    return @ptrFromInt(@as(usize, @bitCast(base +% off)));
}

pub inline fn ccEntryNewAddress(entry: SchemeObject, addr: [*]Insn) SchemeObject {
    check(ccEntryP(entry), "CC_ENTRY_P");
    return objectNewAddress(entry, @ptrCast(@alignCast(addr)));
}

pub inline fn ccEntryNewBlock(entry: SchemeObject, new_block: [*]SchemeObject, old_block: [*]SchemeObject) SchemeObject {
    check(ccEntryP(entry), "CC_ENTRY_P");
    const offset = (@intFromPtr(ccEntryAddress(entry)) - @intFromPtr(old_block)) / @sizeOf(Insn);
    const new_base: [*]Insn = @ptrCast(@alignCast(new_block));
    return ccEntryNewAddress(entry, new_base + offset);
}

pub inline fn ccReturnNewAddress(ret: SchemeObject, addr: [*]Insn) SchemeObject {
    check(ccReturnP(ret), "CC_RETURN_P");
    return objectNewAddress(ret, @ptrCast(@alignCast(addr)));
}

pub inline fn ccReturnNewBlock(ret: SchemeObject, new_block: [*]SchemeObject, old_block: [*]SchemeObject) SchemeObject {
    check(ccReturnP(ret), "CC_RETURN_P");
    const offset = (@intFromPtr(ccReturnAddress(ret)) - @intFromPtr(old_block)) / @sizeOf(Insn);
    const new_base: [*]Insn = @ptrCast(@alignCast(new_block));
    return ccReturnNewAddress(ret, new_base + offset);
}

pub fn check(cond: bool, msg: []const u8) void {
    if (!cond) {
        const err = abi.cStderr();
        const prefix = "CHECK failed: ";
        _ = std.c.fwrite(prefix.ptr, 1, prefix.len, err);
        _ = std.c.fwrite(msg.ptr, 1, msg.len, err);
        _ = std.c.fwrite("\n", 1, 1, err);
        _ = abi.fflush(err);
        std.c.abort();
    }
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    const out = abi.cStdout();
    _ = std.c.fwrite(msg.ptr, 1, msg.len, out);
    _ = abi.fflush(out);
}

// Shared extern symbols across smoke tests
pub extern var dstack_position: ?*anyopaque;
pub extern "c" fn dstack_initialize() void;
pub extern "c" fn dstack_set_position(?*anyopaque) void;
pub extern "c" fn transaction_initialize() void;

pub extern var code_start: ?[*]SchemeObject;
pub extern var code_alloc_next: ?[*]SchemeObject;
pub extern var code_end: ?[*]SchemeObject;
pub extern "c" fn code_arena_setup(usize) void;
pub extern "c" fn code_arena_reset(usize) void;
pub extern "c" fn code_arena_teardown() void;
pub extern "c" fn code_arena_sweep() void;
pub extern "c" fn code_range_valid_p(?[*]const SchemeObject, ?[*]const SchemeObject) bool;
pub extern "c" fn code_arena_find_block(?*const anyopaque) ?[*]SchemeObject;
pub extern "c" fn code_arena_chunk_count() usize;
pub extern "c" fn code_arena_nonempty_chunk_count() usize;
pub extern "c" fn code_arena_mark_hole(?[*]SchemeObject, usize) void;
pub extern "c" fn code_arena_live_words() usize;
pub extern "c" fn code_arena_for_each_live_block(*const fn ([*]SchemeObject, usize, ?*anyopaque) callconv(.c) void, ?*anyopaque) void;
pub extern "c" fn code_arena_rebuild_free_list() void;

pub extern "c" fn jit_available_p() bool;
pub extern "c" fn jit_page_size() usize;
pub extern "c" fn jit_map_code_space(usize) ?*anyopaque;
pub extern "c" fn jit_unmap_code_space(?*anyopaque, usize) void;
pub extern "c" fn jit_write_begin() void;
pub extern "c" fn jit_write_end() void;
pub extern "c" fn jit_write_nesting_depth() c_uint;
pub extern "c" fn jit_write_scope_begin() ?*anyopaque;
pub extern "c" fn jit_write_scope_end(?*anyopaque) void;

pub extern "c" fn write_fasl_header(*FaslHeader, FaslFileHandle) bool;
pub extern "c" fn read_fasl_header(*FaslHeader, FaslFileHandle) bool;
pub extern "c" fn check_fasl_version(*FaslHeader) c_uint;
pub extern "c" fn faslhdr_utilities_end(*FaslHeader) ?[*]SchemeObject;

pub extern "c" fn trampoline_storage([*]SchemeObject) [*]SchemeObject;

// Base stubs exported selectively by each smoke executable
fn stubOsMalloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

fn stubBlockSignals() callconv(.c) void {}
fn stubUnblockSignals() callconv(.c) void {}

fn stubExpectSequential(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) void {}
fn stubExpectNormal(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) void {}
fn stubFreePages(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn minCcEntryAddressToBlockAddress(entry_raw: ?*anyopaque) callconv(.c) [*]SchemeObject {
    var p: [*]Insn = @ptrCast(@alignCast(entry_raw.?));
    while (true) {
        var ceo: abi.CcEntryOffset = undefined;
        _ = abi.read_cc_entry_offset(&ceo, p);
        p -= ceo.offset;
        if (!ceo.continued_p) {
            check((@intFromPtr(p) % @sizeOf(SchemeObject)) == 0, "block aligned");
            return @ptrCast(@alignCast(p));
        }
    }
}

fn minCcEntryToBlockAddress(entry: SchemeObject) callconv(.c) [*]SchemeObject {
    return minCcEntryAddressToBlockAddress(ccEntryAddress(entry));
}

fn minCcEntryToBlock(entry: SchemeObject) callconv(.c) SchemeObject {
    return makeCcBlock(minCcEntryToBlockAddress(entry));
}

fn minCcReturnAddressToBlockAddress(addr: ?*anyopaque) callconv(.c) [*]SchemeObject {
    const entry_addr = if (comptime build_options.cc_is_native)
        abi.cc_return_address_to_entry_address(addr)
    else
        addr;
    return minCcEntryAddressToBlockAddress(entry_addr);
}

fn minCompiledClosureObjects(block: [*]SchemeObject) callconv(.c) [*]SchemeObject {
    return block;
}

fn minMakeCompiledProcedureType(_: *abi.CcEntryType, _: c_uint, _: c_uint, _: bool) callconv(.c) void {}
fn minMakeCompiledContinuationType(_: *abi.CcEntryType, _: usize) callconv(.c) void {}
fn minMakeCcEntryType(_: *abi.CcEntryType, _: abi.CcEntryTypeMarker) callconv(.c) void {}

pub fn exportSvmCcTypeStubs() void {
    if (comptime build_options.cc_is_svm) {
        @export(&minMakeCompiledProcedureType, .{ .name = "make_compiled_procedure_type" });
        @export(&minMakeCompiledContinuationType, .{ .name = "make_compiled_continuation_type" });
        @export(&minMakeCcEntryType, .{ .name = "make_cc_entry_type" });
    }
}

fn minCcReturnToBlockAddress(ret: SchemeObject) callconv(.c) [*]SchemeObject {
    return minCcReturnAddressToBlockAddress(ccReturnAddress(ret));
}

fn minCcReturnToBlock(ret: SchemeObject) callconv(.c) SchemeObject {
    return makeCcBlock(minCcReturnToBlockAddress(ret));
}

pub fn stubDecodeOldStyleFormatWord(_: *abi.CcEntryType, _: u16) callconv(.c) bool {
    return false;
}

pub fn stubEncodeOldStyleFormatWord(_: *abi.CcEntryType, _: *u16) callconv(.c) bool {
    return false;
}

fn minLinkageSectionType(_: SchemeObject) callconv(.c) c_uint {
    return @backingInt(abi.LinkageSectionType.operator);
}

fn minLinkageSectionCount(_: SchemeObject) callconv(.c) usize {
    return 0;
}

pub fn exportBaseRuntimeStubs() void {
    @export(&stubOsMalloc, .{ .name = "OS_malloc" });
    @export(&stubBlockSignals, .{ .name = "block_signals" });
    @export(&stubUnblockSignals, .{ .name = "unblock_signals" });
}

pub fn exportGcOsStubs() void {
    @export(&stubExpectSequential, .{ .name = "OS_expect_sequential_access" });
    @export(&stubExpectNormal, .{ .name = "OS_expect_normal_access" });
    @export(&stubFreePages, .{ .name = "OS_free_pages" });
}

pub fn exportMinimalCcHelpers() void {
    @export(&minCcEntryAddressToBlockAddress, .{ .name = "cc_entry_address_to_block_address" });
    @export(&minCcEntryToBlockAddress, .{ .name = "cc_entry_to_block_address" });
    @export(&minCcEntryToBlock, .{ .name = "cc_entry_to_block" });
    @export(&minCcReturnAddressToBlockAddress, .{ .name = "cc_return_address_to_block_address" });
    @export(&minCcReturnToBlockAddress, .{ .name = "cc_return_to_block_address" });
    @export(&minCcReturnToBlock, .{ .name = "cc_return_to_block" });
    @export(&stubDecodeOldStyleFormatWord, .{ .name = "decode_old_style_format_word" });
    @export(&stubEncodeOldStyleFormatWord, .{ .name = "encode_old_style_format_word" });
    @export(&minLinkageSectionType, .{ .name = "linkage_section_type" });
    @export(&minLinkageSectionCount, .{ .name = "linkage_section_count" });
    if (comptime build_options.cc_is_svm) {
        @export(&minCompiledClosureObjects, .{ .name = "compiled_closure_objects" });
    }
    exportSvmCcTypeStubs();
}
