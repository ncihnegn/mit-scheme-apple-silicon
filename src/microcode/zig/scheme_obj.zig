// Derived from MIT/GNU Scheme C sources (`src/microcode/object.h`, `src/microcode/types.h`, `src/microcode/sdata.h`, `src/microcode/confshared.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");

pub const SchemeObject = c_ulong;

pub const heap_in_low_memory: bool =
    builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86;

extern var memory_base: [*]SchemeObject;

pub const type_code_length = 6;
pub const datum_length: u6 = @as(comptime_int, @bitSizeOf(SchemeObject) - type_code_length);
pub const datum_mask: SchemeObject = (@as(SchemeObject, 1) << datum_length) - 1;
pub const type_code_mask: SchemeObject = ~datum_mask;

pub const fixnum_length: u6 = datum_length - 1;
pub const fixnum_mask: SchemeObject = (@as(SchemeObject, 1) << fixnum_length) - 1;
pub const fixnum_sign_bit: SchemeObject = @as(SchemeObject, 1) << fixnum_length;
pub const sign_mask: SchemeObject = ~fixnum_mask;
pub const smallest_fixnum: c_long = -(@as(c_long, 1) << fixnum_length);
pub const biggest_fixnum: c_long = (@as(c_long, 1) << fixnum_length) - 1;

// Type codes (`src/microcode/types.h`)
pub const tc_false: c_ulong = 0x00;
pub const tc_pair: c_ulong = 0x01;
pub const tc_list: c_ulong = tc_pair;
pub const tc_character: c_ulong = 0x02;
pub const tc_uninterned_symbol: c_ulong = 0x05;
pub const tc_big_flonum: c_ulong = 0x06;
pub const tc_constant: c_ulong = 0x08;
pub const tc_vector: c_ulong = 0x0A;
pub const tc_return_code: c_ulong = 0x0B;
pub const tc_big_fixnum: c_ulong = 0x0E;
pub const tc_non_marked_vector: c_ulong = 0x16;
pub const tc_primitive: c_ulong = 0x18;
pub const tc_fixnum: c_ulong = 0x1A;
pub const tc_unicode_string: c_ulong = 0x1B;
pub const tc_interned_symbol: c_ulong = 0x1D;
pub const tc_character_string: c_ulong = 0x1E;
pub const tc_hunk3_a: c_ulong = 0x20;
pub const tc_broken_heart: c_ulong = 0x22;
pub const tc_hunk3_b: c_ulong = 0x24;
pub const tc_hunk3: c_ulong = tc_hunk3_b;
pub const tc_tagged_object: c_ulong = 0x25;
pub const tc_manifest_nm_vector: c_ulong = 0x27;
pub const tc_vector_1b: c_ulong = 0x2F;
pub const tc_bit_string: c_ulong = tc_vector_1b;
pub const tc_reference_trap: c_ulong = 0x32;
pub const tc_bytevector: c_ulong = 0x33;
pub const tc_cell: c_ulong = 0x36;
pub const tc_weak_cons: c_ulong = 0x37;
pub const tc_quad: c_ulong = 0x38;
pub const tc_record: c_ulong = 0x3E;

pub const tc_manifest_vector: c_ulong = tc_false;
pub const n_type_codes: c_ulong = 0x40;

pub const floating_alignment: usize = 0;

pub inline fn objectType(obj: SchemeObject) c_ulong {
    return obj >> datum_length;
}

pub inline fn objectDatum(obj: SchemeObject) c_ulong {
    return obj & datum_mask;
}

pub inline fn makeObject(tc: c_ulong, datum: c_ulong) SchemeObject {
    return (tc << datum_length) | datum;
}

pub inline fn objectNewDatum(type_obj: SchemeObject, datum: c_ulong) SchemeObject {
    return makeObject(objectType(type_obj), datum);
}

pub inline fn objectNewType(tc: c_ulong, o: SchemeObject) SchemeObject {
    return makeObject(tc, objectDatum(o));
}

// Constant objects (`src/microcode/object.h`)
pub const sharp_f: SchemeObject = makeObject(tc_false, 0);
pub const sharp_t: SchemeObject = makeObject(tc_constant, 0);
pub const unspecific: SchemeObject = makeObject(tc_constant, 1);
pub const empty_list: SchemeObject = makeObject(tc_constant, 9);
pub const unbound_object: SchemeObject = makeObject(tc_reference_trap, 2);

pub const fasdump_record_marker_start: c_ulong = 0x100;
pub const fasdump_record_marker_end: c_ulong = 0x200;

pub inline fn datumToAddress(datum: c_ulong) [*]SchemeObject {
    if (heap_in_low_memory) {
        return @ptrFromInt(@as(usize, @intCast(datum)));
    }
    return memory_base + @as(usize, @intCast(datum));
}

pub inline fn addressToDatum(addr: [*]const SchemeObject) c_ulong {
    if (heap_in_low_memory) {
        return @intCast(@intFromPtr(addr));
    }
    return @intCast((@intFromPtr(addr) - @intFromPtr(memory_base)) / @sizeOf(SchemeObject));
}

pub inline fn objectAddress(obj: SchemeObject) [*]SchemeObject {
    return datumToAddress(objectDatum(obj));
}

pub inline fn makePointerObject(tc: c_ulong, addr: [*]const SchemeObject) SchemeObject {
    return makeObject(tc, addressToDatum(addr));
}

pub inline fn booleanToObject(cond: bool) SchemeObject {
    return if (cond) sharp_t else sharp_f;
}

pub inline fn objectToBoolean(obj: SchemeObject) bool {
    return obj != sharp_f;
}

// Type predicates
pub inline fn bignumP(obj: SchemeObject) bool {
    return objectType(obj) == tc_big_fixnum;
}

pub inline fn bytevectorP(obj: SchemeObject) bool {
    return objectType(obj) == tc_bytevector;
}

pub inline fn characterP(obj: SchemeObject) bool {
    return objectType(obj) == tc_character;
}

pub inline fn fixnumP(obj: SchemeObject) bool {
    return objectType(obj) == tc_fixnum;
}

pub inline fn flonumP(obj: SchemeObject) bool {
    return objectType(obj) == tc_big_flonum;
}

pub inline fn realP(obj: SchemeObject) bool {
    return integerP(obj) or flonumP(obj);
}

pub inline fn integerP(obj: SchemeObject) bool {
    return fixnumP(obj) or bignumP(obj);
}

pub inline fn bitStringP(obj: SchemeObject) bool {
    return objectType(obj) == tc_bit_string;
}

pub inline fn flonumToDouble(obj: SchemeObject) f64 {
    const ptr: *const f64 = @ptrCast(@alignCast(memoryLoc(obj, 1)));
    return ptr.*;
}

pub inline fn makeBrokenHeart(addr: [*]const SchemeObject) SchemeObject {
    return makePointerObject(tc_broken_heart, addr);
}

pub inline fn pairP(obj: SchemeObject) bool {
    return objectType(obj) == tc_list;
}

pub inline fn weakPairP(obj: SchemeObject) bool {
    return objectType(obj) == tc_weak_cons;
}

pub inline fn taggedObjectP(obj: SchemeObject) bool {
    return objectType(obj) == tc_tagged_object;
}

pub inline fn vectorP(obj: SchemeObject) bool {
    return objectType(obj) == tc_vector;
}

pub inline fn recordP(obj: SchemeObject) bool {
    return objectType(obj) == tc_record;
}

pub inline fn hunk3P(obj: SchemeObject) bool {
    const t = objectType(obj);
    return t == tc_hunk3_a or t == tc_hunk3_b;
}

pub inline fn emptyListP(obj: SchemeObject) bool {
    return obj == empty_list;
}

pub inline fn internedSymbolP(obj: SchemeObject) bool {
    return objectType(obj) == tc_interned_symbol;
}

pub inline fn uninternedSymbolP(obj: SchemeObject) bool {
    return objectType(obj) == tc_uninterned_symbol;
}

pub inline fn symbolP(obj: SchemeObject) bool {
    return internedSymbolP(obj) or uninternedSymbolP(obj);
}

pub inline fn legacyStringP(obj: SchemeObject) bool {
    return objectType(obj) == tc_character_string;
}

pub inline fn unicodeStringP(obj: SchemeObject) bool {
    return objectType(obj) == tc_unicode_string;
}

pub inline fn ustringBytesPerCp(obj: SchemeObject) c_ulong {
    return objectType(nmVectorSubheader(obj)) & 0x3;
}

// Memory operations
pub inline fn memoryRef(obj: SchemeObject, index: usize) SchemeObject {
    return objectAddress(obj)[index];
}

pub inline fn memoryLoc(obj: SchemeObject, index: usize) [*]SchemeObject {
    return objectAddress(obj) + index;
}

pub inline fn memorySet(obj: SchemeObject, index: usize, val: SchemeObject) void {
    objectAddress(obj)[index] = val;
}

// Pair operations
pub inline fn pairCar(pair: SchemeObject) SchemeObject {
    return memoryRef(pair, 0);
}

pub inline fn pairCdr(pair: SchemeObject) SchemeObject {
    return memoryRef(pair, 1);
}

pub inline fn pairCarLoc(pair: SchemeObject) [*]SchemeObject {
    return memoryLoc(pair, 0);
}

pub inline fn pairCdrLoc(pair: SchemeObject) [*]SchemeObject {
    return memoryLoc(pair, 1);
}

pub inline fn setPairCar(pair: SchemeObject, val: SchemeObject) void {
    memorySet(pair, 0, val);
}

pub inline fn setPairCdr(pair: SchemeObject, val: SchemeObject) void {
    memorySet(pair, 1, val);
}

pub inline fn symbolName(sym: SchemeObject) SchemeObject {
    return memoryRef(sym, 0);
}

pub inline fn setSymbolName(sym: SchemeObject, name: SchemeObject) void {
    memorySet(sym, 0, name);
}

// Character operations
pub const ascii_length = 8;
pub const code_length = 21;
pub const bits_length = 4;
pub const mit_ascii_length = 25;

pub const max_ascii: c_ulong = @as(c_ulong, 1) << ascii_length;
pub const max_code: c_ulong = @as(c_ulong, 1) << code_length;
pub const max_bits: c_ulong = @as(c_ulong, 1) << bits_length;
pub const max_mit_ascii: c_ulong = @as(c_ulong, 1) << mit_ascii_length;

pub const mask_ascii: c_ulong = max_ascii - 1;
pub const char_mask_code: c_ulong = max_code - 1;
pub const char_mask_bits: c_ulong = max_bits - 1;
pub const mask_mit_ascii: c_ulong = max_mit_ascii - 1;

pub inline fn asciiToChar(ascii: c_ulong) SchemeObject {
    return makeObject(tc_character, ascii);
}

pub inline fn charToAsciiP(obj: SchemeObject) bool {
    return objectDatum(obj) < max_ascii;
}

pub inline fn charToAscii(obj: SchemeObject) c_ulong {
    return obj & mask_ascii;
}

pub inline fn makeChar(bits: c_ulong, code: c_ulong) SchemeObject {
    return makeObject(tc_character, (bits << code_length) | code);
}

pub inline fn charBits(c: SchemeObject) c_ulong {
    return (objectDatum(c) >> code_length) & char_mask_bits;
}

pub inline fn charCode(c: SchemeObject) c_ulong {
    return objectDatum(c) & char_mask_code;
}

// Fixnum operations
pub const fixnum_zero: SchemeObject = makeObject(tc_fixnum, 0);

pub inline fn fixnumZeroP(fixnum: SchemeObject) bool {
    return objectDatum(fixnum) == 0;
}

pub inline fn fixnumNegativeP(fixnum: SchemeObject) bool {
    return (fixnum & fixnum_sign_bit) != 0;
}

pub inline fn fixnumPositiveP(fixnum: SchemeObject) bool {
    return !(fixnumZeroP(fixnum) or fixnumNegativeP(fixnum));
}

pub inline fn fixnumEqualP(x: SchemeObject, y: SchemeObject) bool {
    return objectDatum(x) == objectDatum(y);
}

pub inline fn fixnumLessP(x: SchemeObject, y: SchemeObject) bool {
    return fixnumToLong(x) < fixnumToLong(y);
}

pub inline fn fixnumToDouble(fixnum: SchemeObject) f64 {
    return @floatFromInt(fixnumToLong(fixnum));
}

pub inline fn doubleToFixnumP(number: f64) bool {
    const lo: f64 = @floatFromInt(smallest_fixnum - 1);
    const hi: f64 = @floatFromInt(biggest_fixnum + 1);
    return number > lo and number < hi;
}

pub inline fn doubleToFixnum(number: f64) SchemeObject {
    return longToFixnum(@intFromFloat(number));
}

pub inline fn unsignedFixnumP(obj: SchemeObject) bool {
    return fixnumP(obj) and !fixnumNegativeP(obj);
}

pub inline fn unsignedFixnumToLong(fixnum: SchemeObject) c_long {
    return @intCast(objectDatum(fixnum));
}

pub inline fn longToUnsignedFixnum(n: c_long) SchemeObject {
    return makeObject(tc_fixnum, @bitCast(n));
}

pub inline fn longToFixnumP(n: c_long) bool {
    const bits: c_ulong = @bitCast(n);
    return (bits & sign_mask) == 0 or (bits & sign_mask) == sign_mask;
}

pub inline fn longToFixnum(n: c_long) SchemeObject {
    const bits: c_ulong = @bitCast(n);
    return makeObject(tc_fixnum, bits & datum_mask);
}

pub inline fn fixnumToLong(fixnum: SchemeObject) c_long {
    const raw = (fixnum ^ fixnum_sign_bit) -% ((tc_fixnum << datum_length) | fixnum_sign_bit);
    return @bitCast(raw);
}

pub inline fn ulongToFixnumP(n: c_ulong) bool {
    return (n & sign_mask) == 0;
}

pub inline fn ulongToFixnum(n: c_ulong) SchemeObject {
    return makeObject(tc_fixnum, n);
}

pub inline fn fixnumToUlongP(fixnum: SchemeObject) bool {
    return (objectDatum(fixnum) & sign_mask) == 0;
}

pub inline fn fixnumToUlong(fixnum: SchemeObject) c_ulong {
    return objectDatum(fixnum);
}

// Vectors, NMVs, Bytevectors, Flonum vectors
pub inline fn makeVectorHeader(length: c_ulong) SchemeObject {
    return makeObject(tc_manifest_vector, length);
}

pub inline fn makeNmvHeader(length: c_ulong) SchemeObject {
    return makeObject(tc_manifest_nm_vector, length);
}

pub inline fn bytesToWords(nbytes: c_ulong) c_ulong {
    const word_bytes: c_ulong = @sizeOf(SchemeObject);
    return (nbytes + word_bytes - 1) / word_bytes;
}

pub inline fn vectorHeader(v: SchemeObject) SchemeObject {
    return memoryRef(v, 0);
}

pub inline fn setVectorHeader(v: SchemeObject, header: SchemeObject) void {
    memorySet(v, 0, header);
}

pub inline fn vectorLength(v: SchemeObject) c_ulong {
    return objectDatum(vectorHeader(v));
}

pub inline fn setVectorLength(v: SchemeObject, new_length: c_ulong) void {
    setVectorHeader(v, objectNewDatum(vectorHeader(v), new_length));
}

pub inline fn vectorRef(v: SchemeObject, index: usize) SchemeObject {
    return memoryRef(v, index + 1);
}

pub inline fn vectorSet(v: SchemeObject, index: usize, val: SchemeObject) void {
    memorySet(v, index + 1, val);
}

pub inline fn vectorLoc(v: SchemeObject, index: usize) [*]SchemeObject {
    return memoryLoc(v, index + 1);
}

pub inline fn nmVectorSubheader(nmv: SchemeObject) SchemeObject {
    return memoryRef(nmv, 1);
}

pub inline fn setNmVectorSubheader(nmv: SchemeObject, subheader: SchemeObject) void {
    memorySet(nmv, 1, subheader);
}

pub inline fn nmVectorData(nmv: SchemeObject) [*]SchemeObject {
    return memoryLoc(nmv, 2);
}

pub inline fn bytevectorData(bv: SchemeObject) [*]u8 {
    return @ptrCast(nmVectorData(bv));
}

pub inline fn bytevectorLoc(bv: SchemeObject, index: usize) [*]u8 {
    return bytevectorData(bv) + index;
}

pub inline fn bytevectorRef(bv: SchemeObject, index: usize) u8 {
    return bytevectorLoc(bv, index)[0];
}

pub inline fn bytevectorSet(bv: SchemeObject, index: usize, b: u8) void {
    bytevectorLoc(bv, index)[0] = b;
}

pub inline fn bytevectorLengthToGcLength(nbytes: c_ulong) c_ulong {
    return 1 + bytesToWords(nbytes + 1);
}

pub inline fn makeBytevectorSubheader(nbytes: c_ulong) SchemeObject {
    return makeObject(0, nbytes);
}

pub inline fn bytevectorLength(bv: SchemeObject) c_ulong {
    return objectDatum(nmVectorSubheader(bv));
}

pub inline fn setBytevectorLength(bv: SchemeObject, nbytes: c_ulong) void {
    setNmVectorSubheader(bv, makeBytevectorSubheader(nbytes));
    bytevectorSet(bv, @intCast(nbytes), 0x00);
}

pub inline fn legacyStringLength(s: SchemeObject) c_ulong {
    return bytevectorLength(s);
}

pub inline fn legacyStringData(s: SchemeObject) [*]u8 {
    return bytevectorData(s);
}

pub inline fn legacyStringLoc(s: SchemeObject, index: usize) [*]u8 {
    return legacyStringData(s) + index;
}

pub inline fn legacyStringRef(s: SchemeObject, index: usize) u8 {
    return legacyStringLoc(s, index)[0];
}

pub inline fn legacyStringSet(s: SchemeObject, index: usize, c: u8) void {
    legacyStringLoc(s, index)[0] = c;
}

pub inline fn setLegacyStringLength(s: SchemeObject, nbytes: c_ulong) void {
    setBytevectorLength(s, nbytes);
}

pub inline fn legacyStringMaxLength(s: SchemeObject) c_ulong {
    return (vectorLength(s) - 1) * @sizeOf(SchemeObject) - 1;
}

pub inline fn setLegacyStringMaxLength(s: SchemeObject, nbytes: c_ulong) void {
    setVectorHeader(s, makeNmvHeader(bytevectorLengthToGcLength(nbytes)));
}

pub inline fn hashToFixnum(h: u32) SchemeObject {
    return ulongToFixnum(@as(c_ulong, h));
}

pub const flonum_size: c_ulong = bytesToWords(@sizeOf(f64));

pub inline fn floatingVectorLength(v: SchemeObject) c_ulong {
    return vectorLength(v) / flonum_size;
}

pub inline fn floatingVectorLoc(v: SchemeObject, index: usize) *f64 {
    return @ptrCast(@alignCast(vectorLoc(v, index * @as(usize, @intCast(flonum_size)))));
}

pub inline fn floatingVectorRef(v: SchemeObject, index: usize) f64 {
    return floatingVectorLoc(v, index).*;
}

pub inline fn floatingVectorSet(v: SchemeObject, index: usize, x: f64) void {
    floatingVectorLoc(v, index).* = x;
}

pub inline fn floatingAlignedP(ptr: [*]const SchemeObject) bool {
    return ((@intFromPtr(ptr + 1)) & floating_alignment) == 0;
}

pub inline fn alignFloat(free_ptr: *[*]SchemeObject) void {
    while (!floatingAlignedP(free_ptr.*)) {
        free_ptr.*[0] = makeNmvHeader(0);
        free_ptr.* += 1;
    }
}

test "scheme_obj bit layout, fixnums, chars, and bytevector gc length" {
    if (@sizeOf(SchemeObject) == 8) {
        try std.testing.expectEqual(@as(u6, 58), datum_length);
        try std.testing.expectEqual(@as(SchemeObject, 0x03FF_FFFF_FFFF_FFFF), datum_mask);
        const v = makeVectorHeader(17);
        try std.testing.expectEqual(tc_manifest_vector, objectType(v));
        try std.testing.expectEqual(@as(c_ulong, 17), objectDatum(v));
        const nmv = makeNmvHeader(42);
        try std.testing.expectEqual(tc_manifest_nm_vector, objectType(nmv));
        try std.testing.expectEqual(@as(c_ulong, 42), objectDatum(nmv));
    }

    // Fixnum sign-extension round trips
    const samples = [_]c_long{ 0, 1, -1, 42, -42, smallest_fixnum, biggest_fixnum };
    for (samples) |s| {
        try std.testing.expect(longToFixnumP(s));
        const fx = longToFixnum(s);
        try std.testing.expect(fixnumP(fx));
        try std.testing.expectEqual(s, fixnumToLong(fx));
        if (s >= 0) {
            try std.testing.expect(fixnumToUlongP(fx));
            try std.testing.expectEqual(@as(c_ulong, @intCast(s)), fixnumToUlong(fx));
        } else {
            try std.testing.expect(!fixnumToUlongP(fx));
        }
    }
    try std.testing.expect(!longToFixnumP(biggest_fixnum + 1));
    try std.testing.expect(!longToFixnumP(smallest_fixnum - 1));

    // Character packing
    const ch = makeChar(0xA, 'Z');
    try std.testing.expect(characterP(ch));
    try std.testing.expectEqual(@as(c_ulong, 0xA), charBits(ch));
    try std.testing.expectEqual(@as(c_ulong, 'Z'), charCode(ch));
    try std.testing.expect(!charToAsciiP(ch));
    const ascii_ch = asciiToChar('a');
    try std.testing.expect(charToAsciiP(ascii_ch));
    try std.testing.expectEqual(@as(c_ulong, 'a'), charToAscii(ascii_ch));

    // Bytevector GC length (subheader + ceil((nbytes + 1) / word_bytes))
    try std.testing.expectEqual(@as(c_ulong, 2), bytevectorLengthToGcLength(0));
    try std.testing.expectEqual(@as(c_ulong, 2), bytevectorLengthToGcLength(7));
    try std.testing.expectEqual(@as(c_ulong, 3), bytevectorLengthToGcLength(8));
    try std.testing.expectEqual(@as(c_ulong, 10), bytevectorLengthToGcLength(64));
}
