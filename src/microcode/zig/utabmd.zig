// Derived from MIT/GNU Scheme C sources (`src/microcode/utabmd.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const str = @import("string.zig");
const intern = @import("intern.zig");
const returns = @import("returns.zig");
const storage = @import("storage.zig");
const primutl = @import("primutl.zig");
const bignum = @import("bignum.zig");

const identity_length: c_ulong = 20;
const id_release: usize = 0;
const id_micro_version: usize = 1;
const id_printer_width: usize = 3;
const id_printer_length: usize = 4;
const id_new_line_character: usize = 5;
const id_flonum_precision: usize = 6;
const id_flonum_epsilon: usize = 7;
const id_os_name: usize = 8;
const id_os_variant: usize = 9;
const id_stack_type: usize = 10;
const id_machine_type: usize = 11;
const id_cc_arch: usize = 12;
const id_flonum_exp_min: usize = 13;
const id_flonum_exp_max: usize = 14;
const id_nonneg_fixnum_length: usize = 15;
const id_nonneg_fixnum_mask: usize = 16;

const identity_names = [_]?[*:0]const u8{
    "system-release-string", // 0x00
    "microcode-version", // 0x01
    null, // 0x02
    "console-width", // 0x03
    "console-height", // 0x04
    "newline-char", // 0x05
    "flonum-mantissa-length", // 0x06
    "flonum-epsilon", // 0x07
    "os-name-string", // 0x08
    "os-variant-string", // 0x09
    "stack-type-string", // 0x0A
    "machine-type-string", // 0x0B
    "cc-arch-string", // 0x0C
    "flonum-exponent-min", // 0x0D
    "flonum-exponent-max", // 0x0E
    "nonnegative-fixnum-length", // 0x0F
    "nonnegative-fixnum-mask", // 0x10
};

const package_version_z: [:0]const u8 = blk: {
    var buf: [build_options.package_version.len:0]u8 = undefined;
    @memcpy(&buf, build_options.package_version);
    const frozen = buf;
    break :blk &frozen;
};

const machine_type: [*:0]const u8 = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => "aarch64",
    .x86_64 => "x86-64",
    .x86 => "IA-32",
    .arm, .armeb, .thumb, .thumbeb => "arm",
    .powerpc, .powerpcle => "PowerPC-32",
    .powerpc64, .powerpc64le => "PowerPC-64",
    else => "unknown",
};

fn ccArchName() [*:0]const u8 {
    return switch (abi.compiler_processor_type) {
        abi.compiler_none_type => "none",
        abi.compiler_ia32_type => "i386",
        abi.compiler_c_type => "c",
        abi.compiler_svm_type => "svm1",
        abi.compiler_x86_64_type => "x86-64",
        abi.compiler_aarch64_type => "aarch64",
        else => "unknown",
    };
}

pub export fn make_microcode_identification_vector() callconv(.c) obj.SchemeObject {
    const v = abi.make_vector(identity_length, obj.sharp_f, true);
    obj.vectorSet(v, id_release, obj.sharp_f);
    obj.vectorSet(v, id_micro_version, str.char_pointer_to_string(package_version_z.ptr));
    obj.vectorSet(v, id_printer_width, obj.ulongToFixnum(abi.OS_tty_x_size()));
    obj.vectorSet(v, id_printer_length, obj.ulongToFixnum(abi.OS_tty_y_size()));
    obj.vectorSet(v, id_new_line_character, obj.asciiToChar('\n'));
    obj.vectorSet(v, id_flonum_precision, obj.ulongToFixnum(@intCast(abi.dbl_mant_dig)));
    obj.vectorSet(v, id_flonum_epsilon, abi.double_to_flonum(std.math.floatEps(f64)));
    obj.vectorSet(v, id_os_name, str.char_pointer_to_string(abi.OS_Name));
    obj.vectorSet(v, id_os_variant, str.char_pointer_to_string(abi.OS_Variant));
    obj.vectorSet(v, id_stack_type, str.char_pointer_to_string("standard"));
    obj.vectorSet(v, id_machine_type, str.char_pointer_to_string(machine_type));
    obj.vectorSet(v, id_flonum_exp_min, obj.longToFixnum(abi.dbl_min_exp - 1));
    obj.vectorSet(v, id_flonum_exp_max, obj.longToFixnum(abi.dbl_max_exp - 1));
    obj.vectorSet(v, id_nonneg_fixnum_length, obj.ulongToFixnum(obj.fixnum_length));
    obj.vectorSet(v, id_nonneg_fixnum_mask, obj.ulongToFixnum(obj.fixnum_mask));
    obj.vectorSet(v, id_cc_arch, str.char_pointer_to_string(ccArchName()));
    return v;
}

inline fn fixobjSet(slot: usize, object: obj.SchemeObject) void {
    obj.vectorSet(abi.fixed_objects, slot, object);
}

fn namesToVector(names: []const ?[*:0]const u8) obj.SchemeObject {
    const v = abi.allocate_vector(@intCast(names.len), true);
    for (names, 0..) |name, i| {
        obj.vectorSet(v, i, if (name) |n| intern.char_pointer_to_symbol(n) else obj.sharp_f);
    }
    return v;
}

inline fn fixobjSetNames(slot: usize, names: []const ?[*:0]const u8) void {
    fixobjSet(slot, namesToVector(names));
}

inline fn fixobjSetPrim(slot: usize, name: [*:0]const u8, arity: c_int) void {
    fixobjSet(slot, primutl.make_primitive(name, arity));
}

fn fixedObjectsSyscallNames() obj.SchemeObject {
    var length: c_ulong = 0;
    var names_ptr: [*]?[*:0]const u8 = undefined;
    abi.OS_syscall_names(&length, &names_ptr);
    return namesToVector(if (length == 0) &.{} else names_ptr[0..@intCast(length)]);
}

fn fixedObjectsSyserrNames() obj.SchemeObject {
    var length: c_ulong = 0;
    var names_ptr: [*]?[*:0]const u8 = undefined;
    abi.OS_syserr_names(&length, &names_ptr);
    return namesToVector(if (length == 0) &.{} else names_ptr[0..@intCast(length)]);
}

pub export fn initialize_fixed_objects_vector() callconv(.c) void {
    abi.fixed_objects = abi.make_vector(abi.n_fixed_objects, obj.sharp_f, false);
    fixobjSet(abi.fixobj_non_object, obj.makeObject(obj.tc_constant, 2));
    fixobjSet(abi.fixobj_system_interrupt_vector, abi.initialize_interrupt_handler_vector());
    fixobjSet(abi.fixobj_interrupt_mask_vector, abi.initialize_interrupt_mask_vector());
    // Error vector is not needed at boot time.
    fixobjSet(abi.fixobj_system_error_vector, obj.sharp_f);

    // This must happen before we initialize name vectors.
    fixobjSet(abi.fixobj_obarray, abi.make_vector(abi.obarray_size, obj.empty_list, false));

    fixobjSetNames(abi.fixobj_types_vector, &storage.type_names);
    fixobjSetNames(abi.fixobj_errors_vector, &storage.Error_Names);
    fixobjSetNames(abi.fixobj_termination_vector, &storage.Term_Names);
    fixobjSetNames(abi.fixobj_fixed_objects_slots, &storage.fixed_objects_names);
    fixobjSetNames(abi.fixobj_identification_vector, &identity_names);

    fixobjSet(abi.fixobj_returns_vector, returns.make_return_code_names_table());
    fixobjSet(abi.fixobj_return_frames_vector, returns.make_frame_type_info_table());
    fixobjSet(abi.fixobj_return_codes_vector, returns.make_frame_code_info_table());

    fixobjSet(abi.fixobj_dummy_history, abi.initialize_history());
    fixobjSet(abi.fixobj_bignum_one, bignum.long_to_bignum(1));
    fixobjSet(abi.fixobj_edwin_auto_save, obj.empty_list);
    fixobjSet(abi.fixobj_files_to_delete, obj.empty_list);
    fixobjSet(abi.fixobj_system_call_names, fixedObjectsSyscallNames());
    fixobjSet(abi.fixobj_system_call_errors, fixedObjectsSyserrNames());
    fixobjSet(abi.fixobj_gc_reclaimed, obj.gc_reclaimed);

    fixobjSetPrim(abi.fixobj_generic_trampoline_zero_p, "integer-zero?", 1);
    fixobjSetPrim(abi.fixobj_generic_trampoline_positive_p, "integer-positive?", 1);
    fixobjSetPrim(abi.fixobj_generic_trampoline_negative_p, "integer-negative?", 1);
    fixobjSetPrim(abi.fixobj_generic_trampoline_successor, "integer-add-1", 1);
    fixobjSetPrim(abi.fixobj_generic_trampoline_predecessor, "integer-subtract-1", 1);
    fixobjSetPrim(abi.fixobj_generic_trampoline_equal_p, "integer-equal?", 2);
    fixobjSetPrim(abi.fixobj_generic_trampoline_less_p, "integer-less?", 2);
    fixobjSetPrim(abi.fixobj_generic_trampoline_greater_p, "integer-greater?", 2);
    fixobjSetPrim(abi.fixobj_generic_trampoline_add, "integer-add", 2);
    fixobjSetPrim(abi.fixobj_generic_trampoline_subtract, "integer-subtract", 2);
    fixobjSetPrim(abi.fixobj_generic_trampoline_multiply, "integer-multiply", 2);

    fixobjSet(abi.fixobj_generic_trampoline_divide, obj.sharp_f);
    fixobjSet(abi.fixobj_generic_trampoline_quotient, obj.sharp_f);
    fixobjSet(abi.fixobj_generic_trampoline_remainder, obj.sharp_f);
    fixobjSet(abi.fixobj_generic_trampoline_modulo, obj.sharp_f);

    fixobjSet(
        abi.fixobj_proxied_record_types,
        abi.make_vector(abi.fasdump_record_marker_end - abi.fasdump_record_marker_start, obj.sharp_f, false),
    );
    if (build_options.cc_support) {
        fixobjSet(abi.fixobj_reflect_code_names, abi.make_reflect_code_table());
    }
}

test "utabmd identification vector and initialize_fixed_objects_vector" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    // Test make_microcode_identification_vector
    const id_vec = make_microcode_identification_vector();
    try std.testing.expectEqual(identity_length, obj.vectorLength(id_vec));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(id_vec, id_release));
    try std.testing.expectEqualStrings(
        build_options.package_version,
        std.mem.sliceTo(obj.legacyStringData(obj.vectorRef(id_vec, id_micro_version)), 0),
    );
    try std.testing.expectEqual(@as(c_ulong, 80), obj.fixnumToUlong(obj.vectorRef(id_vec, id_printer_width)));
    try std.testing.expectEqual(@as(c_ulong, 24), obj.fixnumToUlong(obj.vectorRef(id_vec, id_printer_length)));
    try std.testing.expectEqual(obj.asciiToChar('\n'), obj.vectorRef(id_vec, id_new_line_character));
    try std.testing.expectEqual(@as(c_ulong, 53), obj.fixnumToUlong(obj.vectorRef(id_vec, id_flonum_precision)));
    try std.testing.expectEqual(std.math.floatEps(f64), obj.flonumToDouble(obj.vectorRef(id_vec, id_flonum_epsilon)));
    try std.testing.expectEqual(@as(c_long, -1022), obj.fixnumToLong(obj.vectorRef(id_vec, id_flonum_exp_min)));
    try std.testing.expectEqual(@as(c_long, 1023), obj.fixnumToLong(obj.vectorRef(id_vec, id_flonum_exp_max)));
    try std.testing.expectEqualStrings("aarch64", std.mem.sliceTo(obj.legacyStringData(obj.vectorRef(id_vec, id_cc_arch)), 0));

    abi.compiler_processor_type = abi.compiler_svm_type;
    const id_vec_svm = make_microcode_identification_vector();
    try std.testing.expectEqualStrings("svm1", std.mem.sliceTo(obj.legacyStringData(obj.vectorRef(id_vec_svm, id_cc_arch)), 0));

    // Allocate a temporary large heap for OBARRAY_SIZE (32771) + fixed objects tables
    const big_heap = try std.testing.allocator.alloc(obj.SchemeObject, 65536);
    defer std.testing.allocator.free(big_heap);
    @memset(big_heap, 0);
    abi.heap_start = big_heap.ptr;
    abi.heap_end = big_heap.ptr + big_heap.len;
    abi.heap_alloc_limit = big_heap.ptr + big_heap.len - 64;
    abi.Free = abi.heap_start;
    abi.Free_primitive = abi.heap_start;
    abi.memory_block_start = abi.heap_start;

    primutl.initialize_primitives();
    initialize_fixed_objects_vector();

    try std.testing.expect(obj.vectorP(abi.fixed_objects));
    try std.testing.expectEqual(abi.n_fixed_objects, obj.vectorLength(abi.fixed_objects));
    try std.testing.expectEqual(abi.obarray_size, obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_obarray)));
    try std.testing.expectEqual(@as(c_ulong, 64), obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_types_vector)));
    try std.testing.expectEqual(@as(c_ulong, 70), obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_fixed_objects_slots)));
    try std.testing.expectEqual(@as(c_ulong, 17), obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_identification_vector)));
    try std.testing.expectEqual(@as(c_ulong, 3), obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_system_call_names)));
    try std.testing.expectEqual(@as(c_ulong, 2), obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_system_call_errors)));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(obj.vectorRef(abi.fixed_objects, abi.fixobj_system_call_names), 1));
    try std.testing.expectEqual(@as(c_long, 1), bignum.bignum_to_long(obj.vectorRef(abi.fixed_objects, abi.fixobj_bignum_one)));
    try std.testing.expectEqual(obj.gc_reclaimed, obj.vectorRef(abi.fixed_objects, abi.fixobj_gc_reclaimed));
    try std.testing.expect(obj.primitiveP(obj.vectorRef(abi.fixed_objects, abi.fixobj_generic_trampoline_add)));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(abi.fixed_objects, abi.fixobj_generic_trampoline_divide));
    try std.testing.expectEqual(@as(c_ulong, 256), obj.vectorLength(obj.vectorRef(abi.fixed_objects, abi.fixobj_proxied_record_types)));
}
