// Derived from MIT/GNU Scheme C sources (`src/microcode/prim.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const artutl = @import("artutl.zig");

inline fn argType(arg: c_int) usize {
    return abi.arg_ulong_index_integer(arg, @as(usize, 1) << obj.type_code_length);
}

inline fn argDatum(arg: c_int) usize {
    return abi.arg_ulong_index_integer(arg, @as(usize, 1) << obj.datum_length);
}

fn safeObjectNewTypeP(object: obj.SchemeObject, type_code: usize) bool {
    const gc_type_old = abi.gcType(object);
    const gc_type_new = abi.gc_type_code(@intCast(type_code));
    if (gc_type_old == @intFromEnum(abi.GcType.undefined) or gc_type_new == @intFromEnum(abi.GcType.undefined)) {
        return false;
    }
    if (obj.objectType(object) == obj.tc_reference_trap) {
        return if (obj.objectDatum(object) < obj.trap_max_immediate)
            gc_type_new == @intFromEnum(abi.GcType.non_pointer)
        else
            type_code == obj.tc_pair;
    }
    if (type_code == obj.tc_reference_trap) {
        return gc_type_old == @intFromEnum(abi.GcType.non_pointer) or obj.pairP(object);
    }
    if (gc_type_old == @intFromEnum(abi.GcType.special) or gc_type_new == @intFromEnum(abi.GcType.special)) {
        return false;
    }
    return gc_type_new == gc_type_old;
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-TYPE", Prim_prim_obj_type, 1, 1,
//   "Return the type code of OBJECT as an unsigned integer.")
pub export fn Prim_prim_obj_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.ulongToFixnum(obj.objectType(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-TYPE?", Prim_prim_obj_type_p, 2, 2,
//   "Return #T if TYPE-CODE is OBJECT's type code, else #F.")
pub export fn Prim_prim_obj_type_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.objectType(abi.argRef(2)) == argType(1));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-DATUM", Prim_prim_obj_datum, 1, 1,
//   "Return the datum part of OBJECT as an unsigned integer.")
pub export fn Prim_prim_obj_datum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.ulong_to_integer(obj.objectDatum(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-ADDRESS", Prim_prim_obj_address, 1, 1,
//   "(OBJECT)\n\
// Return the address part of OBJECT as an unsigned integer.")
pub export fn Prim_prim_obj_address() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.ulong_to_integer(@intCast(obj.datumToRawAddress(obj.objectDatum(abi.argRef(1)))));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-DATUM->ADDRESS", Prim_prim_datum_to_addr, 1, 1,
//   "(DATUM)\n\
// Return the memory address corresponding to DATUM.")
pub export fn Prim_prim_datum_to_addr() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.ulong_to_integer(@intCast(obj.datumToRawAddress(argDatum(1))));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-ADDRESS->DATUM", Prim_prim_addr_to_datum, 1, 1,
//   "(ADDRESS)\n\
// Return the object datum corresponding to ADDRESS.")
pub export fn Prim_prim_addr_to_datum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.ulong_to_integer(obj.rawAddressToDatum(@intCast(abi.arg_ulong_integer(1))));
}

// DEFINE_PRIMITIVE ("MAKE-NON-POINTER-OBJECT", Prim_make_non_ptr_object, 1, 1,
//   "(DATUM)\n\
// Convert the unsigned integer DATUM into a fixnum.\n\
// Assert: (= (OBJECT-DATUM (MAKE-NON-POINTER-OBJECT X)) X).")
pub export fn Prim_make_non_ptr_object() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.ulongToFixnum(argDatum(1));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-SET-TYPE", Prim_prim_obj_set_type, 2, 2,
//   "(TYPE OBJECT)\n\
// Return a new object made from TYPE and the datum part of OBJECT.")
pub export fn Prim_prim_obj_set_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.objectNewType(argType(1), abi.argRef(2));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-EQ?", Prim_prim_obj_eq_p, 2, 2, 0)
pub export fn Prim_prim_obj_eq_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.argRef(1) == abi.argRef(2));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-MAKE-OBJECT", Prim_prim_make_obj, 2, 2,
//   "(TYPE DATUM)\n\
// Return a new object made from TYPE and DATUM.")
pub export fn Prim_prim_make_obj() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.makeObject(argType(1), argDatum(2));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT->INTEGER", Prim_prim_obj_to_integer, 1, 1,
//   "(OBJECT)\n\
// Return the integer representation of OBJECT.")
pub export fn Prim_prim_obj_to_integer() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.ulong_to_integer(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-INTEGER->OBJECT", Prim_prim_integer_to_obj, 1, 1,
//   "(INTEGER)\n\
// Return the object whose representation is INTEGER.")
pub export fn Prim_prim_integer_to_obj() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.arg_ulong_integer(1);
}

fn argAddress(n: c_int) [*]obj.SchemeObject {
    const object = abi.argRef(@intCast(n));
    if (abi.gc_ptr_type(object) != @intFromEnum(abi.GcPtrType.normal)) {
        abi.error_wrong_type_arg(n);
    }
    return obj.objectAddress(object);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-REF", Prim_prim_obj_ref, 2, 2,
//   "(OBJECT INDEX)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// Fetches the object at offset INDEX in OBJECT.")
pub export fn Prim_prim_obj_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const address = argAddress(1);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    return address[index];
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-REF-NEW-TYPE", Prim_prim_obj_ref_new_type, 3, 3,
//   "(OBJECT INDEX TYPE)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// Fetches the object at offset INDEX in OBJECT and replaces its type with TYPE.\n\
// Effectively like the following but memory-safe:\n\
//    (object-set-type (primitive-object-ref OBJECT INDEX) TYPE)")
pub export fn Prim_prim_obj_ref_new_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const address = argAddress(1);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    const type_code = argType(3);
    const object = address[index];
    if (!safeObjectNewTypeP(object, type_code)) abi.error_bad_range_arg(1);
    return obj.objectNewType(type_code, object);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-TYPE-REF", Prim_prim_type_ref, 2, 2,
//   "(OBJECT INDEX)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// Fetches the type of the object at offset INDEX in OBJECT.")
pub export fn Prim_prim_type_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const address = argAddress(1);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    return artutl.ulong_to_integer(obj.objectType(address[index]));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-DATUM-REF", Prim_prim_datum_ref, 2, 2,
//   "(OBJECT INDEX)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// Fetches the datum of the object at offset INDEX in OBJECT.")
pub export fn Prim_prim_datum_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const address = argAddress(1);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    return artutl.ulong_to_integer(obj.objectDatum(address[index]));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-OBJECT-SET!", Prim_prim_obj_set, 3, 3,
//   "(OBJECT INDEX VALUE)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// VALUE may be any object.\n\
// Stores VALUE at offset INDEX in OBJECT.")
pub export fn Prim_prim_obj_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    obj.memorySet(abi.argRef(1), @intCast(abi.arg_ulong_integer(2)), abi.argRef(3));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PRIMITIVE-TYPE-SET!", Prim_prim_type_set, 3, 3,
//   "(OBJECT INDEX TYPE)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// TYPE must be a type code.\n\
// Sets the type of the object at offset INDEX in OBJECT to TYPE.")
pub export fn Prim_prim_type_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const address = argAddress(1);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    const tc = argType(3);
    address[index] = obj.objectNewType(tc, address[index]);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PRIMITIVE-DATUM-SET!", Prim_prim_datum_set, 3, 3,
//   "(OBJECT INDEX DATUM)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// DATUM must be a datum value.\n\
// Sets the datum of the object at offset INDEX in OBJECT to DATUM.")
pub export fn Prim_prim_datum_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const address = argAddress(1);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    const datum = argDatum(3);
    address[index] = obj.objectNewDatum(address[index], datum);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PRIMITIVE-BYTE-REF", Prim_prim_byte_ref, 2, 2,
//   "(OBJECT INDEX)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// Fetches the 8-bit unsigned integer at offset INDEX in OBJECT.")
pub export fn Prim_prim_byte_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: [*]const u8 = @ptrCast(obj.objectRawAddress(abi.argRef(1)).?);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    return artutl.ulong_to_integer(ptr[index]);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-BYTE-SET!", Prim_prim_byte_set, 3, 3,
//   "(OBJECT INDEX VALUE)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// VALUE must be an 8-bit unsigned integer.\n\
// Stores VALUE at offset INDEX in OBJECT.")
pub export fn Prim_prim_byte_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: [*]u8 = @ptrCast(obj.objectRawAddress(abi.argRef(1)).?);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    ptr[index] = @intCast(abi.arg_ulong_index_integer(3, 0x100));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("PRIMITIVE-U16-REF", Prim_prim_u16_ref, 2, 2,
//   "(OBJECT INDEX)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// Fetches the 16-bit unsigned integer at offset INDEX in OBJECT.")
pub export fn Prim_prim_u16_ref() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: [*]align(1) const u16 = @ptrCast(obj.objectRawAddress(abi.argRef(1)).?);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    return artutl.ulong_to_integer(ptr[index]);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-U16-SET!", Prim_prim_u16_set, 3, 3,
//   "(OBJECT INDEX VALUE)\n\
// OBJECT must be a pointer type.\n\
// INDEX must be an unsigned integer.\n\
// VALUE must be a 16-bit unsigned integer.\n\
// Stores VALUE at offset INDEX in OBJECT.")
pub export fn Prim_prim_u16_set() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: [*]align(1) u16 = @ptrCast(obj.objectRawAddress(abi.argRef(1)).?);
    const index: usize = @intCast(abi.arg_ulong_integer(2));
    ptr[index] = @intCast(abi.arg_ulong_index_integer(3, 0x10000));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("OBJECT-TYPE", Prim_object_type, 1, 1, 0)
pub export fn Prim_object_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.ulongToFixnum(obj.objectType(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("OBJECT-GC-TYPE", Prim_object_gc_type, 1, 1, 0)
pub export fn Prim_object_gc_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.longToFixnum(abi.gcType(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("TYPE->GC-TYPE", Prim_type_to_gc_type, 1, 1, 0)
pub export fn Prim_type_to_gc_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.longToFixnum(abi.gc_type_code(@intCast(argType(1))));
}

// DEFINE_PRIMITIVE ("OBJECT-TYPE?", Prim_object_type_p, 2, 2, 0)
pub export fn Prim_object_type_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.objectType(abi.argRef(2)) == argType(1));
}

// DEFINE_PRIMITIVE ("OBJECT-DATUM", Prim_object_datum, 1, 1, 0)
pub export fn Prim_object_datum() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.long_to_integer(@intCast(obj.objectDatum(abi.argRef(1))));
}

// DEFINE_PRIMITIVE ("OBJECT-SET-TYPE", Prim_object_set_type, 2, 2, 0)
pub export fn Prim_object_set_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const type_code = argType(1);
    const object = abi.argRef(2);
    if (!safeObjectNewTypeP(object, type_code)) abi.error_bad_range_arg(1);
    return obj.objectNewType(type_code, object);
}

// DEFINE_PRIMITIVE ("EQ?", Prim_eq, 2, 2, 0)
pub export fn Prim_eq() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.argRef(1) == abi.argRef(2));
}

// DEFINE_PRIMITIVE ("NOT", Prim_not, 1, 1, 0)
pub export fn Prim_not() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.argRef(1) == obj.sharp_f);
}

// DEFINE_PRIMITIVE ("NULL?", Prim_null_p, 1, 1, 0)
pub export fn Prim_null_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.emptyListP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("MAKE-CELL", Prim_make_cell, 1, 1, 0)
pub export fn Prim_make_cell() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.primitiveGcIfNeeded(1);
    const ptr = abi.Free;
    ptr[0] = abi.argRef(1);
    abi.Free = ptr + 1;
    return obj.makePointerObject(obj.tc_cell, ptr);
}

// DEFINE_PRIMITIVE ("CELL?", Prim_cell_p, 1, 1, 0)
pub export fn Prim_cell_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.cellP(abi.argRef(1)));
}

fn cellArg(n: c_int) obj.SchemeObject {
    abi.checkArg(n, obj.cellP);
    return abi.argRef(@intCast(n));
}

// DEFINE_PRIMITIVE ("CELL-CONTENTS", Prim_cell_contents, 1, 1, 0)
pub export fn Prim_cell_contents() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.cellContents(cellArg(1));
}

// DEFINE_PRIMITIVE ("SET-CELL-CONTENTS!", Prim_set_cell_contents, 2, 2, 0)
pub export fn Prim_set_cell_contents() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    obj.setCellContents(cellArg(1), abi.argRef(2));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("primitive-object-hash", Prim_primitive_object_hash, 1, 1, 0)
pub export fn Prim_primitive_object_hash() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const object = abi.argRef(1);
    return if (abi.hashable_object_p(object))
        obj.hashToFixnum(abi.hash_object(object))
    else
        obj.sharp_f;
}

// DEFINE_PRIMITIVE ("primitive-object-hash-2", Prim_primitive_object_hash_2, 2, 2, 0)
pub export fn Prim_primitive_object_hash_2() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const object1 = abi.argRef(1);
    const object2 = abi.argRef(2);
    return if (abi.hashable_object_p(object1) and abi.hashable_object_p(object2))
        obj.hashToFixnum(abi.combine_hashes(abi.hash_object(object1), abi.hash_object(object2)))
    else
        obj.sharp_f;
}

// DEFINE_PRIMITIVE ("primitive-memory-hash", Prim_primitive_memory_hash, 3, 3, 0)
pub export fn Prim_primitive_memory_hash() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const object = abi.argRef(1);
    if (!(abi.gcTypeVector(object) and obj.objectType(obj.memoryRef(object, 0)) == obj.tc_manifest_nm_vector)) {
        abi.error_wrong_type_arg(1);
    }
    const nwords = obj.vectorLength(object);
    const start = abi.arg_ulong_integer(2);
    const end = abi.arg_ulong_integer(3);

    const word_bytes: usize = @sizeOf(obj.SchemeObject);
    const min_index = word_bytes;
    const max_index = min_index + (nwords * word_bytes);

    if (start < min_index or start > max_index) abi.error_bad_range_arg(2);
    if (end < start or end > max_index) abi.error_bad_range_arg(3);

    const bytes: [*]const u8 = @ptrCast(obj.objectAddress(object));
    return obj.hashToFixnum(abi.memory_hash(end - start, bytes + @as(usize, @intCast(start))));
}

test "prim object inspection, safe_object_new_type_p, cells, byte/u16, and memory hash" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // Safe new-type rules including reference trap
    const imm_trap = obj.makeObject(obj.tc_reference_trap, 2);
    try std.testing.expect(safeObjectNewTypeP(imm_trap, obj.tc_fixnum));
    try std.testing.expect(!safeObjectNewTypeP(imm_trap, obj.tc_pair));
    const pair_trap = obj.makeObject(obj.tc_reference_trap, 100);
    try std.testing.expect(safeObjectNewTypeP(pair_trap, obj.tc_pair));
    try std.testing.expect(!safeObjectNewTypeP(pair_trap, obj.tc_fixnum));

    stubs.setArgs(&.{ obj.ulongToFixnum(obj.tc_character), obj.longToFixnum(65) });
    const ch = Prim_object_set_type();
    try std.testing.expectEqual(obj.asciiToChar(65), ch);

    // Cell primitives
    stubs.setArgs(&.{obj.longToFixnum(7)});
    const cell = Prim_make_cell();
    stubs.setArgs(&.{cell});
    try std.testing.expectEqual(obj.sharp_t, Prim_cell_p());
    try std.testing.expectEqual(obj.longToFixnum(7), Prim_cell_contents());
    stubs.setArgs(&.{ cell, obj.longToFixnum(99) });
    _ = Prim_set_cell_contents();
    stubs.setArgs(&.{cell});
    try std.testing.expectEqual(obj.longToFixnum(99), Prim_cell_contents());

    // Vector byte/u16 + memory hash
    const bv = abi.allocate_bytevector(8);
    stubs.setArgs(&.{ bv, obj.ulongToFixnum(16), obj.ulongToFixnum(0x55) });
    _ = Prim_prim_byte_set();
    stubs.setArgs(&.{ bv, obj.ulongToFixnum(16) });
    try std.testing.expectEqual(obj.ulongToFixnum(0x55), Prim_prim_byte_ref());

    stubs.setArgs(&.{ bv, obj.ulongToFixnum(9), obj.ulongToFixnum(0xBEEF) });
    _ = Prim_prim_u16_set();
    stubs.setArgs(&.{ bv, obj.ulongToFixnum(9) });
    try std.testing.expectEqual(obj.ulongToFixnum(0xBEEF), Prim_prim_u16_ref());

    const start_off: usize = @sizeOf(obj.SchemeObject) * 2;
    stubs.setArgs(&.{ bv, obj.ulongToFixnum(start_off), obj.ulongToFixnum(start_off + 8) });
    const h = Prim_primitive_memory_hash();
    try std.testing.expect(obj.fixnumP(h));
}
