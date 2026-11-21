// Derived from MIT/GNU Scheme C sources (`src/microcode/fasl.c`, `src/microcode/fasl.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");

pub const Insn = if (build_options.cc_is_native and (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be))
    u32
else
    u8;

pub const FaslFileHandle = ?*anyopaque;

extern var compiler_utilities: obj.SchemeObject;

extern "c" fn fopen([*:0]const u8, [*:0]const u8) FaslFileHandle;
extern "c" fn fclose(FaslFileHandle) c_int;
extern "c" fn fread(?*anyopaque, usize, usize, FaslFileHandle) usize;
extern "c" fn fwrite(?*const anyopaque, usize, usize, FaslFileHandle) usize;
extern "c" fn abort() noreturn;

pub const fasl_file_marker: obj.SchemeObject = if (@sizeOf(c_ulong) == 4)
    0xFAFAFAFA
else
    0xFAFAFAFAFAFAFAFA;

pub const fasl_header_length: usize = 50;

pub const fasl_offset_marker: usize = 0;
pub const fasl_offset_heap_size: usize = 1;
pub const fasl_offset_heap_base: usize = 2;
pub const fasl_offset_dumped_obj: usize = 3;
pub const fasl_offset_const_size: usize = 4;
pub const fasl_offset_const_base: usize = 5;
pub const fasl_offset_version: usize = 6;
pub const fasl_offset_stack_start: usize = 7;
pub const fasl_offset_prim_length: usize = 8;
pub const fasl_offset_prim_size: usize = 9;
pub const fasl_offset_ci_version: usize = 10;
pub const fasl_offset_ut_base: usize = 11;
pub const fasl_offset_c_length: usize = 13;
pub const fasl_offset_c_size: usize = 14;
pub const fasl_offset_mem_base: usize = 15;
pub const fasl_offset_stack_size: usize = 16;
pub const fasl_offset_heap_rsvd: usize = 17;
pub const fasl_offset_ephemerons: usize = 18;
pub const fasl_offset_code_size: usize = 19;
pub const fasl_offset_code_base: usize = 20;

const half_datum_length: std.math.Log2Int(obj.SchemeObject) = if (@sizeOf(c_ulong) == 4) 13 else 29;
const half_datum_mask: obj.SchemeObject = (@as(obj.SchemeObject, 1) << half_datum_length) - 1;

const fasl_arch_length: std.math.Log2Int(obj.SchemeObject) = @bitSizeOf(obj.SchemeObject) / 2;
const fasl_arch_mask: obj.SchemeObject = (@as(obj.SchemeObject, 1) << fasl_arch_length) - 1;
const fasl_version_length: std.math.Log2Int(obj.SchemeObject) = fasl_arch_length - obj.type_code_length;
const fasl_version_mask: obj.SchemeObject = (@as(obj.SchemeObject, 1) << fasl_version_length) - 1;

pub const fasl_version_none: c_uint = 0;
pub const fasl_version_c_code: c_uint = 10;
pub const fasl_version_stack_end: c_uint = 11;
pub const fasl_version_ephemerons: c_uint = 12;
pub const fasl_version_code_space: c_uint = 13;

pub const compiler_none_type: c_ulong = 0;

pub const fasl_file_fine: c_uint = 0;
pub const fasl_file_too_short: c_uint = 1;
pub const fasl_file_not_fasl: c_uint = 2;
pub const fasl_file_bad_machine: c_uint = 3;
pub const fasl_file_bad_version: c_uint = 4;
pub const fasl_file_bad_subversion: c_uint = 5;
pub const fasl_file_bad_processor: c_uint = 6;
pub const fasl_file_bad_interface: c_uint = 7;

pub const FaslHeader = extern struct {
    version: c_uint,
    arch: c_uint,
    cc_version: c_uint,
    cc_arch: c_uint,
    band_p: bool,
    memory_base: ?[*]obj.SchemeObject,
    root_pointer: ?[*]obj.SchemeObject,
    heap_start: ?[*]obj.SchemeObject,
    heap_end: ?[*]obj.SchemeObject,
    heap_reserved: c_ulong,
    constant_start: ?[*]obj.SchemeObject,
    constant_end: ?[*]obj.SchemeObject,
    code_start: ?[*]obj.SchemeObject,
    code_end: ?[*]obj.SchemeObject,
    stack_start: ?[*]obj.SchemeObject,
    stack_end: ?[*]obj.SchemeObject,
    n_primitives: c_ulong,
    primitive_table_size: c_ulong,
    n_c_code_blocks: c_ulong,
    c_code_table_size: c_ulong,
    utilities_vector: obj.SchemeObject,
    utilities_start: ?[*]obj.SchemeObject,
    utilities_end: ?[*]obj.SchemeObject,
    ephemeron_count: c_ulong,
};

fn currentFaslArch() c_uint {
    if (build_options.cc_is_svm) {
        const endian = builtin.cpu.arch.endian();
        if (@sizeOf(c_ulong) == 8) {
            return if (endian == .little) 29 else 28; // FASL_SVM1_64LE : FASL_SVM1_64BE
        }
        return if (endian == .little) 27 else 26; // FASL_SVM1_32LE : FASL_SVM1_32BE
    }
    return switch (builtin.cpu.arch) {
        .aarch64 => 25, // FASL_AARCH64LE
        .aarch64_be => 30, // FASL_AARCH64BE
        .x86_64 => 21, // FASL_X86_64
        .x86 => 6, // FASL_IA32
        .arm => 24, // FASL_ARM
        .powerpc => 20, // FASL_PPC32
        .powerpc64, .powerpc64le => 22, // FASL_PPC64
        else => 0,
    };
}

inline fn faslArch(p: obj.SchemeObject) c_uint {
    return @intCast(p & fasl_arch_mask);
}

inline fn faslVersion(p: obj.SchemeObject) c_uint {
    return @intCast((p >> fasl_arch_length) & fasl_version_mask);
}

inline fn makeFaslVersion(s: c_uint, a: c_uint) obj.SchemeObject {
    return obj.makeObject(1, (@as(obj.SchemeObject, s) << fasl_arch_length) | @as(obj.SchemeObject, a));
}

inline fn ciVersion(p: obj.SchemeObject) c_uint {
    return @intCast((p >> half_datum_length) & half_datum_mask);
}

inline fn ciProcessor(p: obj.SchemeObject) c_uint {
    return @intCast(p & half_datum_mask);
}

inline fn ciBandP(p: obj.SchemeObject) bool {
    return obj.objectType(p) == obj.tc_constant;
}

inline fn makeCiVersion(b: bool, v: c_uint, a: c_uint) obj.SchemeObject {
    const tc: obj.SchemeObject = if (b) obj.tc_constant else obj.tc_false;
    return obj.makeObject(tc, (@as(obj.SchemeObject, v) << half_datum_length) | @as(obj.SchemeObject, a));
}

inline fn ptrToBrokenHeart(ptr: ?[*]const obj.SchemeObject) obj.SchemeObject {
    if (obj.heap_in_low_memory) {
        return obj.makeObject(obj.tc_broken_heart, @intCast(@intFromPtr(ptr)));
    }
    const datum: obj.SchemeObject = if (ptr) |p| obj.addressToDatum(p) else 0;
    return obj.makeObject(obj.tc_broken_heart, datum);
}

inline fn ptrRangeWords(end: ?[*]const obj.SchemeObject, start: ?[*]const obj.SchemeObject) c_ulong {
    return @intCast((@intFromPtr(end) -% @intFromPtr(start)) / @sizeOf(obj.SchemeObject));
}

inline fn ptrAddWords(base: ?[*]obj.SchemeObject, n_words: c_ulong) ?[*]obj.SchemeObject {
    if (n_words == 0) return base;
    return base.? + @as(usize, @intCast(n_words));
}

pub export fn open_fasl_output_file(filename: [*:0]const u8, handle_r: *FaslFileHandle) callconv(.c) bool {
    const s = fopen(filename, "wb") orelse return false;
    handle_r.* = s;
    return true;
}

pub export fn close_fasl_output_file(handle: FaslFileHandle) callconv(.c) bool {
    return fclose(handle) == 0;
}

pub export fn write_fasl_header(h: *FaslHeader, handle: FaslFileHandle) callconv(.c) bool {
    var raw: [fasl_header_length]obj.SchemeObject = undefined;
    encodeFaslHeader(&raw, h);
    return write_to_fasl_file(&raw, fasl_header_length, handle);
}

pub export fn write_to_fasl_file(start: ?*const anyopaque, n_words: usize, handle: FaslFileHandle) callconv(.c) bool {
    return fwrite(start, @sizeOf(obj.SchemeObject), n_words, handle) == n_words;
}

pub export fn open_fasl_input_file(filename: [*:0]const u8, handle_r: *FaslFileHandle) callconv(.c) bool {
    const s = fopen(filename, "rb") orelse return false;
    handle_r.* = s;
    return true;
}

pub export fn close_fasl_input_file(handle: FaslFileHandle) callconv(.c) bool {
    return fclose(handle) == 0;
}

pub export fn read_fasl_header(h: *FaslHeader, handle: FaslFileHandle) callconv(.c) bool {
    var raw: [fasl_header_length]obj.SchemeObject = undefined;
    return read_from_fasl_file(&raw, fasl_header_length, handle) and decodeFaslHeader(&raw, h);
}

pub export fn read_from_fasl_file(start: ?*anyopaque, n_words: usize, handle: FaslFileHandle) callconv(.c) bool {
    return fread(start, @sizeOf(obj.SchemeObject), n_words, handle) == n_words;
}

pub export fn check_fasl_version(fh: *FaslHeader) callconv(.c) c_uint {
    if (fh.version >= fasl_version_c_code and fh.version <= fasl_version_code_space) {
        return if (fh.arch == currentFaslArch()) fasl_file_fine else fasl_file_bad_machine;
    }
    return fasl_file_bad_version;
}

pub export fn check_fasl_cc_version(fh: *FaslHeader, version: c_ulong, cc_type: c_ulong) callconv(.c) c_uint {
    if (fh.cc_version == 0 and fh.cc_arch == compiler_none_type) {
        return fasl_file_fine;
    }
    if (fh.cc_version == version) {
        return if (fh.cc_arch == cc_type) fasl_file_fine else fasl_file_bad_processor;
    }
    return fasl_file_bad_interface;
}

fn encodeFaslHeader(raw: *[fasl_header_length]obj.SchemeObject, h: *FaslHeader) void {
    raw.* = @splat(obj.sharp_f);

    raw[fasl_offset_marker] = fasl_file_marker;
    raw[fasl_offset_version] = makeFaslVersion(h.version, h.arch);
    raw[fasl_offset_ci_version] = makeCiVersion(h.band_p, h.cc_version, h.cc_arch);
    raw[fasl_offset_mem_base] = @intFromPtr(h.memory_base);
    raw[fasl_offset_dumped_obj] = ptrToBrokenHeart(h.root_pointer);

    raw[fasl_offset_heap_base] = ptrToBrokenHeart(h.heap_start);
    raw[fasl_offset_heap_size] = obj.makeObject(obj.tc_broken_heart, ptrRangeWords(h.heap_end, h.heap_start));

    if (h.version >= fasl_version_stack_end) {
        raw[fasl_offset_heap_rsvd] = obj.makeObject(obj.tc_broken_heart, h.heap_reserved);
    }

    raw[fasl_offset_const_base] = ptrToBrokenHeart(h.constant_start);
    raw[fasl_offset_const_size] = obj.makeObject(obj.tc_broken_heart, ptrRangeWords(h.constant_end, h.constant_start));

    if (h.version >= fasl_version_stack_end) {
        raw[fasl_offset_stack_start] = ptrToBrokenHeart(h.stack_start);
        raw[fasl_offset_stack_size] = obj.makeObject(obj.tc_broken_heart, ptrRangeWords(h.stack_end, h.stack_start));
    } else {
        raw[fasl_offset_stack_start] = ptrToBrokenHeart(h.stack_end);
    }

    raw[fasl_offset_prim_length] = obj.makeObject(obj.tc_broken_heart, h.n_primitives);
    raw[fasl_offset_prim_size] = obj.makeObject(obj.tc_broken_heart, h.primitive_table_size);
    raw[fasl_offset_c_length] = obj.makeObject(obj.tc_broken_heart, h.n_c_code_blocks);
    raw[fasl_offset_c_size] = obj.makeObject(obj.tc_broken_heart, h.c_code_table_size);
    raw[fasl_offset_ut_base] = h.utilities_vector;

    if (h.version >= fasl_version_ephemerons) {
        raw[fasl_offset_ephemerons] = obj.makeObject(obj.tc_broken_heart, h.ephemeron_count);
    }

    if (h.version >= fasl_version_code_space) {
        raw[fasl_offset_code_base] = ptrToBrokenHeart(h.code_start);
        raw[fasl_offset_code_size] = obj.makeObject(obj.tc_broken_heart, ptrRangeWords(h.code_end, h.code_start));
    }
}

fn decodeFaslHeader(raw: *[fasl_header_length]obj.SchemeObject, h: *FaslHeader) bool {
    if (raw[fasl_offset_marker] != fasl_file_marker) return false;

    const ver_obj = raw[fasl_offset_version];
    h.version = faslVersion(ver_obj);
    h.arch = faslArch(ver_obj);
    if (check_fasl_version(h) != fasl_file_fine) return false;

    const ci_obj = raw[fasl_offset_ci_version];
    h.cc_version = ciVersion(ci_obj);
    h.cc_arch = ciProcessor(ci_obj);
    h.band_p = ciBandP(ci_obj);

    const fasl_memory_base: ?[*]obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(raw[fasl_offset_mem_base])));
    h.memory_base = fasl_memory_base;

    h.root_pointer = fasl_object_address(raw[fasl_offset_dumped_obj], h);

    h.heap_start = fasl_object_address(raw[fasl_offset_heap_base], h);
    h.heap_end = ptrAddWords(h.heap_start, obj.objectDatum(raw[fasl_offset_heap_size]));
    h.heap_reserved = if (h.version >= fasl_version_stack_end) obj.objectDatum(raw[fasl_offset_heap_rsvd]) else 0;

    h.constant_start = fasl_object_address(raw[fasl_offset_const_base], h);
    h.constant_end = ptrAddWords(h.constant_start, obj.objectDatum(raw[fasl_offset_const_size]));

    if (h.version >= fasl_version_stack_end) {
        h.stack_start = fasl_object_address(raw[fasl_offset_stack_start], h);
        h.stack_end = ptrAddWords(h.stack_start, obj.objectDatum(raw[fasl_offset_stack_size]));
    } else {
        h.stack_end = fasl_object_address(raw[fasl_offset_stack_start], h);
        h.stack_start = fasl_memory_base;
    }

    h.n_primitives = obj.objectDatum(raw[fasl_offset_prim_length]);
    h.primitive_table_size = obj.objectDatum(raw[fasl_offset_prim_size]);
    h.n_c_code_blocks = obj.objectDatum(raw[fasl_offset_c_length]);
    h.c_code_table_size = obj.objectDatum(raw[fasl_offset_c_size]);

    const ruv = raw[fasl_offset_ut_base];
    if (ruv == obj.sharp_f) {
        h.utilities_vector = obj.sharp_f;
        h.utilities_start = null;
    } else {
        const fuv_addr = fasl_object_address(ruv, h).?;
        const fuv = obj.makePointerObject(obj.objectType(ruv), fuv_addr);
        h.utilities_vector = fuv;
        h.utilities_start = obj.objectAddress(fuv);
    }
    h.utilities_end = null;

    if (h.version >= fasl_version_ephemerons) {
        h.ephemeron_count = obj.objectDatum(raw[fasl_offset_ephemerons]);
    } else {
        h.ephemeron_count = 0;
    }

    if (h.version >= fasl_version_code_space) {
        h.code_start = fasl_object_address(raw[fasl_offset_code_base], h);
        h.code_end = ptrAddWords(h.code_start, obj.objectDatum(raw[fasl_offset_code_size]));
    } else {
        h.code_start = null;
        h.code_end = null;
    }

    return true;
}

pub export fn fasl_object_address(o: obj.SchemeObject, h: *FaslHeader) callconv(.c) ?[*]obj.SchemeObject {
    const datum = obj.objectDatum(o);
    if (h.memory_base) |mb| {
        return mb + @as(usize, @intCast(datum));
    }
    if (h.arch == currentFaslArch()) {
        return if (obj.heap_in_low_memory)
            @ptrFromInt(@as(usize, @intCast(datum)))
        else
            obj.datumToAddress(datum);
    }
    abort();
}

pub export fn fasl_cc_address(o: obj.SchemeObject, h: *FaslHeader) callconv(.c) ?[*]Insn {
    const datum = obj.objectDatum(o);
    if (h.memory_base) |mb| {
        const base_insn: [*]Insn = @ptrCast(@alignCast(mb));
        return base_insn + @as(usize, @intCast(datum));
    }
    if (h.arch == currentFaslArch()) {
        std.debug.assert(obj.objectType(o) == obj.tc_compiled_entry);
        return @ptrCast(@alignCast(obj.datumToAddress(datum)));
    }
    abort();
}

pub export fn fasl_cc_return(o: obj.SchemeObject, h: *FaslHeader) callconv(.c) ?[*]Insn {
    const datum = obj.objectDatum(o);
    if (h.memory_base) |mb| {
        const base_insn: [*]Insn = @ptrCast(@alignCast(mb));
        return base_insn + @as(usize, @intCast(datum));
    }
    if (h.arch == currentFaslArch()) {
        std.debug.assert(obj.ccReturnP(o));
        return @ptrCast(@alignCast(obj.datumToAddress(datum)));
    }
    abort();
}

pub export fn fasl_raw_address_to_object(
    type_code: c_uint,
    address: ?[*]obj.SchemeObject,
    h: *FaslHeader,
) callconv(.c) obj.SchemeObject {
    if (h.memory_base) |mb| {
        const datum: c_ulong = @intCast((@intFromPtr(address) -% @intFromPtr(mb)) / @sizeOf(obj.SchemeObject));
        return obj.makeObject(@intCast(type_code), datum);
    }
    if (h.arch == currentFaslArch()) {
        const datum: c_ulong = if (obj.heap_in_low_memory)
            @intCast(@intFromPtr(address))
        else
            obj.addressToDatum(address.?);
        return obj.makeObject(@intCast(type_code), datum);
    }
    abort();
}

pub export fn fasl_raw_address_to_cc_entry(address: ?[*]Insn, h: *FaslHeader) callconv(.c) obj.SchemeObject {
    if (h.memory_base) |mb| {
        const datum: c_ulong = @intCast((@intFromPtr(address) -% @intFromPtr(mb)) / @sizeOf(Insn));
        return obj.makeObject(obj.tc_compiled_entry, datum);
    }
    if (h.arch == currentFaslArch()) {
        const datum: c_ulong = if (obj.heap_in_low_memory)
            @intCast(@intFromPtr(address))
        else
            obj.addressToDatum(@ptrCast(@alignCast(address.?)));
        return obj.makeObject(obj.tc_compiled_entry, datum);
    }
    abort();
}

pub export fn faslhdr_utilities_end(h: *FaslHeader) callconv(.c) ?[*]obj.SchemeObject {
    if (h.utilities_end == null) {
        if (h.utilities_start) |ustart| {
            if (obj.ccBlockP(compiler_utilities)) {
                const len = obj.objectDatum(obj.memoryRef(compiler_utilities, 0));
                h.utilities_end = ustart + 1 + @as(usize, @intCast(len));
            } else if (obj.vectorP(compiler_utilities)) {
                const len = obj.vectorLength(compiler_utilities);
                h.utilities_end = ustart + 1 + @as(usize, @intCast(len));
            }
        }
    }
    return h.utilities_end;
}

extern "c" fn tmpfile() FaslFileHandle;
extern "c" fn rewind(FaslFileHandle) void;

test "fasl header encode/decode roundtrip, version checks, addressing, and utilities_end" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    var arena: [64]obj.SchemeObject = @splat(0);
    arena[16] = obj.makeObject(obj.tc_manifest_nm_vector, 3);
    compiler_utilities = obj.makePointerObject(obj.tc_compiled_code_block, arena[16..].ptr);

    var h: FaslHeader = .{
        .version = fasl_version_code_space,
        .arch = currentFaslArch(),
        .cc_version = 42,
        .cc_arch = 15,
        .band_p = true,
        .memory_base = null,
        .root_pointer = arena[2..].ptr,
        .heap_start = arena[0..].ptr,
        .heap_end = arena[10..].ptr,
        .heap_reserved = 77,
        .constant_start = arena[10..].ptr,
        .constant_end = arena[16..].ptr,
        .code_start = arena[20..].ptr,
        .code_end = arena[28..].ptr,
        .stack_start = arena[30..].ptr,
        .stack_end = arena[40..].ptr,
        .n_primitives = 5,
        .primitive_table_size = 12,
        .n_c_code_blocks = 1,
        .c_code_table_size = 4,
        .utilities_vector = obj.makePointerObject(obj.tc_compiled_code_block, arena[16..].ptr),
        .utilities_start = arena[16..].ptr,
        .utilities_end = arena[20..].ptr,
        .ephemeron_count = 3,
    };

    try std.testing.expectEqual(fasl_file_fine, check_fasl_version(&h));
    try std.testing.expectEqual(fasl_file_fine, check_fasl_cc_version(&h, 42, 15));
    try std.testing.expectEqual(fasl_file_bad_processor, check_fasl_cc_version(&h, 42, 14));
    try std.testing.expectEqual(fasl_file_bad_interface, check_fasl_cc_version(&h, 99, 15));

    const f = tmpfile();
    try std.testing.expect(f != null);
    defer _ = close_fasl_input_file(f);

    try std.testing.expect(write_fasl_header(&h, f));
    rewind(f);

    var decoded: FaslHeader = std.mem.zeroes(FaslHeader);
    try std.testing.expect(read_fasl_header(&decoded, f));
    try std.testing.expectEqual(fasl_version_code_space, decoded.version);
    try std.testing.expectEqual(currentFaslArch(), decoded.arch);
    try std.testing.expectEqual(@as(c_uint, 42), decoded.cc_version);
    try std.testing.expectEqual(@as(c_uint, 15), decoded.cc_arch);
    try std.testing.expect(decoded.band_p);
    try std.testing.expectEqual(h.root_pointer, decoded.root_pointer);
    try std.testing.expectEqual(h.heap_start, decoded.heap_start);
    try std.testing.expectEqual(h.heap_end, decoded.heap_end);
    try std.testing.expectEqual(h.heap_reserved, decoded.heap_reserved);
    try std.testing.expectEqual(h.constant_start, decoded.constant_start);
    try std.testing.expectEqual(h.constant_end, decoded.constant_end);
    try std.testing.expectEqual(h.code_start, decoded.code_start);
    try std.testing.expectEqual(h.code_end, decoded.code_end);
    try std.testing.expectEqual(h.stack_start, decoded.stack_start);
    try std.testing.expectEqual(h.stack_end, decoded.stack_end);
    try std.testing.expectEqual(@as(c_ulong, 3), decoded.ephemeron_count);
    try std.testing.expectEqual(arena[20..].ptr, faslhdr_utilities_end(&decoded).?);

    // Relocation mode when memory_base is non-null
    decoded.memory_base = arena[0..].ptr;
    const raw_obj = fasl_raw_address_to_object(@intCast(obj.tc_pair), arena[5..].ptr, &decoded);
    try std.testing.expectEqual(@as(obj.SchemeObject, 5), obj.objectDatum(raw_obj));
    try std.testing.expectEqual(arena[5..].ptr, fasl_object_address(raw_obj, &decoded).?);

    const insn_ptr: [*]Insn = @ptrCast(&arena[8]);
    const cc_obj = fasl_raw_address_to_cc_entry(insn_ptr + 3, &decoded);
    try std.testing.expectEqual(insn_ptr + 3, fasl_cc_address(cc_obj, &decoded).?);
}
