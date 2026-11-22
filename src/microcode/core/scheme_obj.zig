// Derived from MIT/GNU Scheme C sources (`src/microcode/object.h`, `src/microcode/types.h`, `src/microcode/sdata.h`, `src/microcode/confshared.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");

pub const SchemeObject = usize;

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
pub const smallest_fixnum: isize = -(@as(isize, 1) << fixnum_length);
pub const biggest_fixnum: isize = (@as(isize, 1) << fixnum_length) - 1;

// Type codes (`src/microcode/types.h`)
pub const tc_false: usize = 0x00;
pub const tc_pair: usize = 0x01;
pub const tc_list: usize = tc_pair;
pub const tc_character: usize = 0x02;
pub const tc_scode_quote: usize = 0x03;
pub const tc_compiled_return: usize = 0x04;
pub const tc_uninterned_symbol: usize = 0x05;
pub const tc_big_flonum: usize = 0x06;
pub const tc_apply_hook: usize = 0x07;
pub const tc_constant: usize = 0x08;
pub const tc_extended_procedure: usize = 0x09;
pub const tc_vector: usize = 0x0A;
pub const tc_return_code: usize = 0x0B;
pub const tc_manifest_closure: usize = 0x0D;
pub const tc_big_fixnum: usize = 0x0E;
pub const tc_procedure: usize = 0x0F;
pub const tc_entity: usize = 0x10;
pub const tc_delay: usize = 0x11;
pub const tc_environment: usize = 0x12;
pub const tc_delayed: usize = 0x13;
pub const tc_extended_lambda: usize = 0x14;
pub const tc_comment: usize = 0x15;
pub const tc_non_marked_vector: usize = 0x16;
pub const tc_lambda: usize = 0x17;
pub const tc_primitive: usize = 0x18;
pub const tc_sequence: usize = 0x19;
pub const tc_fixnum: usize = 0x1A;
pub const tc_unicode_string: usize = 0x1B;
pub const tc_control_point: usize = 0x1C;
pub const tc_interned_symbol: usize = 0x1D;
pub const tc_character_string: usize = 0x1E;
pub const tc_access: usize = 0x1F;
pub const tc_hunk3_a: usize = 0x20;
pub const tc_definition: usize = 0x21;
pub const tc_broken_heart: usize = 0x22;
pub const tc_assignment: usize = 0x23;
pub const tc_hunk3_b: usize = 0x24;
pub const tc_hunk3: usize = tc_hunk3_b;
pub const tc_tagged_object: usize = 0x25;
pub const tc_combination: usize = 0x26;
pub const tc_manifest_nm_vector: usize = 0x27;
pub const tc_compiled_entry: usize = 0x28;
pub const tc_lexpr: usize = 0x29;
pub const tc_ephemeron: usize = 0x2B;
pub const tc_variable: usize = 0x2C;
pub const tc_the_environment: usize = 0x2D;
pub const tc_syntax_error: usize = 0x2E;
pub const tc_vector_1b: usize = 0x2F;
pub const tc_bit_string: usize = tc_vector_1b;
pub const tc_reference_trap: usize = 0x32;
pub const tc_bytevector: usize = 0x33;
pub const tc_conditional: usize = 0x34;
pub const tc_disjunction: usize = 0x35;
pub const tc_cell: usize = 0x36;
pub const tc_weak_cons: usize = 0x37;
pub const tc_quad: usize = 0x38;
pub const tc_linkage_section: usize = 0x39;
pub const tc_ratnum: usize = 0x3A;
pub const tc_stack_environment: usize = 0x3B;
pub const tc_complex: usize = 0x3C;
pub const tc_compiled_code_block: usize = 0x3D;
pub const tc_record: usize = 0x3E;

pub const tc_manifest_vector: usize = tc_false;
pub const n_type_codes: usize = 0x40;

pub const floating_alignment: usize = 0;

pub inline fn objectType(obj: SchemeObject) usize {
    return obj >> datum_length;
}

pub inline fn objectDatum(obj: SchemeObject) usize {
    return obj & datum_mask;
}

pub inline fn makeObject(tc: usize, datum: usize) SchemeObject {
    return (tc << datum_length) | datum;
}

pub inline fn objectNewDatum(type_obj: SchemeObject, datum: usize) SchemeObject {
    return makeObject(objectType(type_obj), datum);
}

pub inline fn objectNewType(tc: usize, o: SchemeObject) SchemeObject {
    return makeObject(tc, objectDatum(o));
}

// Constant objects (`src/microcode/object.h`)
pub const sharp_f: SchemeObject = makeObject(tc_false, 0);
pub const sharp_t: SchemeObject = makeObject(tc_constant, 0);
pub const unspecific: SchemeObject = makeObject(tc_constant, 1);
pub const optional_marker: SchemeObject = makeObject(tc_constant, 3);
pub const rest_marker: SchemeObject = makeObject(tc_constant, 4);
pub const key_marker: SchemeObject = makeObject(tc_constant, 5);
pub const eof_object: SchemeObject = makeObject(tc_constant, 6);
pub const default_object: SchemeObject = makeObject(tc_constant, 7);
pub const empty_list: SchemeObject = makeObject(tc_constant, 9);
pub const gc_reclaimed: SchemeObject = makeObject(tc_constant, 10);
pub const the_global_env: SchemeObject = makeObject(tc_false, 0);
pub const the_null_env: SchemeObject = makeObject(tc_false, 1);
pub const half_datum_length: std.math.Log2Int(SchemeObject) = if (@sizeOf(usize) == 4) 13 else 29;
pub const broken_heart_zero: SchemeObject = makeObject(tc_broken_heart, 0);
pub const unassigned_object: SchemeObject = makeObject(tc_reference_trap, 0);
pub const unbound_object: SchemeObject = makeObject(tc_reference_trap, 2);
pub const trap_max_immediate: usize = 9;
pub const trap_unassigned: usize = 0;
pub const trap_unbound: usize = 2;
pub const trap_expensive: usize = 6;
pub const trap_compiler_cached: usize = 14;
pub const trap_macro: usize = 15;
pub const non_trap_kind: usize = 32;
pub const expensive_object: SchemeObject = makeObject(tc_reference_trap, trap_expensive);

pub const tc_history_unmarked: usize = tc_hunk3_a;
pub const tc_history_marked: usize = tc_hunk3_b;
pub const history_mark_type: usize = tc_history_unmarked ^ tc_history_marked;
pub const history_mark_mask: SchemeObject = @as(SchemeObject, history_mark_type) << datum_length;

pub const fasdump_record_marker_start: usize = 0x100;
pub const fasdump_record_marker_end: usize = 0x200;

pub inline fn datumToAddress(datum: usize) [*]SchemeObject {
    if (heap_in_low_memory) {
        return @ptrFromInt(@as(usize, @intCast(datum)));
    }
    return memory_base + @as(usize, @intCast(datum));
}

pub inline fn addressToDatum(addr: [*]const SchemeObject) usize {
    if (heap_in_low_memory) {
        return @intCast(@intFromPtr(addr));
    }
    return @intCast((@intFromPtr(addr) - @intFromPtr(memory_base)) / @sizeOf(SchemeObject));
}

pub inline fn objectAddress(obj: SchemeObject) [*]SchemeObject {
    return datumToAddress(objectDatum(obj));
}

pub inline fn makePointerObject(tc: usize, addr: [*]const SchemeObject) SchemeObject {
    return makeObject(tc, addressToDatum(addr));
}

pub inline fn makeObjectFromObjects(type_obj: SchemeObject, datum_obj: SchemeObject) SchemeObject {
    return makeObject(objectType(type_obj), objectDatum(datum_obj));
}

pub inline fn objectNewAddress(type_obj: SchemeObject, addr: [*]const SchemeObject) SchemeObject {
    return objectNewDatum(type_obj, addressToDatum(addr));
}

pub inline fn objectNewRawAddress(type_obj: SchemeObject, raw_addr: usize) SchemeObject {
    return objectNewDatum(type_obj, rawAddressToDatum(raw_addr));
}

pub inline fn datumToRawAddress(datum: usize) usize {
    if (heap_in_low_memory) {
        return @intCast(datum);
    }
    return @intFromPtr(memory_base) + @as(usize, @intCast(datum)) * @sizeOf(SchemeObject);
}

pub inline fn rawAddressToDatum(addr: usize) usize {
    if (heap_in_low_memory) {
        return @intCast(addr);
    }
    return @intCast((addr -% @intFromPtr(memory_base)) / @sizeOf(SchemeObject));
}

pub inline fn objectRawAddress(obj: SchemeObject) ?*anyopaque {
    return @ptrFromInt(datumToRawAddress(objectDatum(obj)));
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

pub inline fn makePrimitiveObject(index: usize) SchemeObject {
    return makeObject(tc_primitive, index);
}

pub inline fn primitiveNumber(prim: SchemeObject) usize {
    return objectDatum(prim);
}

pub inline fn makeReturnCode(n: usize) SchemeObject {
    return makeObject(tc_return_code, n);
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

pub inline fn controlPointP(obj: SchemeObject) bool {
    return objectType(obj) == tc_control_point;
}

pub inline fn ccBlockP(obj: SchemeObject) bool {
    return objectType(obj) == tc_compiled_code_block;
}

pub inline fn returnCodeP(obj: SchemeObject) bool {
    return objectType(obj) == tc_return_code;
}

pub inline fn primitiveP(obj: SchemeObject) bool {
    return objectType(obj) == tc_primitive;
}

pub inline fn cellP(obj: SchemeObject) bool {
    return objectType(obj) == tc_cell;
}

pub inline fn vectorHeaderP(obj: SchemeObject) bool {
    return objectType(obj) == tc_manifest_vector;
}

pub inline fn combinationP(obj: SchemeObject) bool {
    return objectType(obj) == tc_combination;
}

pub inline fn ccReturnP(obj: SchemeObject) bool {
    return objectType(obj) == tc_compiled_return;
}

pub inline fn ccEntryP(obj: SchemeObject) bool {
    return objectType(obj) == tc_compiled_entry;
}

pub inline fn ccStackEnvP(obj: SchemeObject) bool {
    return objectType(obj) == tc_stack_environment;
}

pub inline fn nonMarkedVectorP(obj: SchemeObject) bool {
    return objectType(obj) == tc_non_marked_vector;
}

pub inline fn makeCcBlock(addr: [*]const SchemeObject) SchemeObject {
    return makePointerObject(tc_compiled_code_block, addr);
}

pub inline fn environmentP(obj: SchemeObject) bool {
    return objectType(obj) == tc_environment or obj == the_global_env;
}

pub inline fn globalFrameP(o: SchemeObject) bool {
    return o == the_global_env;
}

pub inline fn nullFrameP(o: SchemeObject) bool {
    return o == the_null_env;
}

pub inline fn procedureFrameP(o: SchemeObject) bool {
    return objectType(o) == tc_environment;
}

pub inline fn brokenHeartP(o: SchemeObject) bool {
    return objectType(o) == tc_broken_heart;
}

pub inline fn referenceTrapP(o: SchemeObject) bool {
    return objectType(o) == tc_reference_trap;
}

pub inline fn procLambda(proc: SchemeObject) SchemeObject {
    return memoryRef(proc, 0);
}

pub inline fn procEnvironment(proc: SchemeObject) SchemeObject {
    return memoryRef(proc, 1);
}

pub inline fn envProc(env: SchemeObject) SchemeObject {
    return memoryRef(env, 1);
}

pub inline fn setEnvExtension(env: SchemeObject, ext: SchemeObject) void {
    memorySet(env, 1, ext);
}

pub inline fn envVals(env: SchemeObject) [*]SchemeObject {
    return memoryLoc(env, 2);
}

pub inline fn envParent(env: SchemeObject) SchemeObject {
    return procEnvironment(envProc(env));
}

pub inline fn frameExtensionParent(ext: SchemeObject) SchemeObject {
    return vectorRef(ext, 0);
}

pub inline fn setFrameExtensionParent(ext: SchemeObject, parent: SchemeObject) void {
    vectorSet(ext, 0, parent);
}

pub inline fn frameExtensionProc(ext: SchemeObject) SchemeObject {
    return vectorRef(ext, 1);
}

pub inline fn setFrameExtensionProc(ext: SchemeObject, proc: SchemeObject) void {
    vectorSet(ext, 1, proc);
}

pub inline fn frameExtensionLength(ext: SchemeObject) usize {
    return fixnumToUlong(vectorRef(ext, 2));
}

pub inline fn setFrameExtensionLength(ext: SchemeObject, n: usize) void {
    vectorSet(ext, 2, ulongToFixnum(n));
}

pub inline fn frameExtensionMaxLength(ext: SchemeObject) usize {
    return vectorLength(ext) - 3;
}

pub inline fn frameExtensionBindings(ext: SchemeObject) [*]SchemeObject {
    return vectorLoc(ext, 3);
}

pub inline fn extendedFrameP(frame: SchemeObject) bool {
    return vectorP(envProc(frame));
}

pub inline fn extendedFrameProc(frame: SchemeObject) SchemeObject {
    return frameExtensionProc(envProc(frame));
}

pub inline fn extendedFrameBindings(frame: SchemeObject) [*]SchemeObject {
    return frameExtensionBindings(envProc(frame));
}

pub inline fn extendedFrameLength(frame: SchemeObject) usize {
    return frameExtensionLength(envProc(frame));
}

pub inline fn extendedFrameMaxLength(frame: SchemeObject) usize {
    return frameExtensionMaxLength(envProc(frame));
}

pub inline fn setExtendedFrameLength(frame: SchemeObject, n: usize) void {
    setFrameExtensionLength(envProc(frame), n);
}

pub inline fn lambdaNames(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 1);
}

pub inline fn lambdaParams(exp: SchemeObject) [*]SchemeObject {
    return vectorLoc(lambdaNames(exp), 1);
}

pub inline fn lambdaNParams(exp: SchemeObject) usize {
    return vectorLength(lambdaNames(exp)) - 1;
}

pub inline fn elambdaNames(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 1);
}

pub inline fn elambdaArgCounts(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 2);
}

pub inline fn elambdaReqs(exp: SchemeObject) usize {
    return (elambdaArgCounts(exp) >> 8) & 0xFF;
}

pub inline fn elambdaOpts(exp: SchemeObject) usize {
    return elambdaArgCounts(exp) & 0xFF;
}

pub inline fn elambdaRest(exp: SchemeObject) usize {
    return (elambdaArgCounts(exp) >> 16) & 0x1;
}

pub inline fn accessName(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 1);
}

pub inline fn assignmentName(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 0);
}

pub inline fn definitionName(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 0);
}

pub inline fn variableName(exp: SchemeObject) SchemeObject {
    return memoryRef(exp, 0);
}

pub inline fn variableSafeP(exp: SchemeObject) bool {
    return memoryRef(exp, 1) == sharp_f;
}

pub inline fn combinationSize(exp: SchemeObject) usize {
    return vectorLength(exp);
}

pub inline fn combinationExpr(exp: SchemeObject, idx: usize) SchemeObject {
    return vectorRef(exp, idx);
}

pub inline fn symbolGlobalValue(sym: SchemeObject) SchemeObject {
    return memoryRef(sym, 1);
}

pub inline fn setSymbolGlobalValue(sym: SchemeObject, val: SchemeObject) void {
    memorySet(sym, 1, val);
}

pub inline fn symbolGlobalValueCell(sym: SchemeObject) [*]SchemeObject {
    return memoryLoc(sym, 1);
}

pub inline fn ptrRefTrapTag(trap: SchemeObject) SchemeObject {
    return memoryRef(trap, 0);
}

pub inline fn ptrRefTrapCache(trap: SchemeObject) SchemeObject {
    return memoryRef(trap, 1);
}

pub inline fn setPtrRefTrapCache(trap: SchemeObject, cache: SchemeObject) void {
    memorySet(trap, 1, cache);
}

pub inline fn cacheValue(cache: SchemeObject) SchemeObject {
    return memoryRef(cache, 0);
}

pub inline fn setCacheValue(cache: SchemeObject, val: SchemeObject) void {
    memorySet(cache, 0, val);
}

pub inline fn cacheClone(cache: SchemeObject) SchemeObject {
    return memoryRef(cache, 1);
}

pub inline fn setCacheClone(cache: SchemeObject, clone: SchemeObject) void {
    memorySet(cache, 1, clone);
}

pub inline fn cacheRefs(cache: SchemeObject) SchemeObject {
    return memoryRef(cache, 2);
}

pub inline fn setCacheRefs(cache: SchemeObject, refs: SchemeObject) void {
    memorySet(cache, 2, refs);
}

pub inline fn cacheCloneP(cache: SchemeObject) bool {
    return cacheValue(cache) == expensive_object;
}

pub inline fn cacheLookupRefs(cache: SchemeObject) [*]SchemeObject {
    return memoryLoc(cacheRefs(cache), 0);
}

pub inline fn cacheAssignmentRefs(cache: SchemeObject) [*]SchemeObject {
    return memoryLoc(cacheRefs(cache), 1);
}

pub inline fn cacheOperatorRefs(cache: SchemeObject) [*]SchemeObject {
    return memoryLoc(cacheRefs(cache), 2);
}

pub inline fn cacheRefBlock(ref: SchemeObject) SchemeObject {
    return pairCar(ref);
}

pub inline fn setCacheRefBlock(ref: SchemeObject, block: SchemeObject) void {
    setPairCar(ref, block);
}

pub inline fn cacheRefOffset(ref: SchemeObject) usize {
    return objectDatum(pairCdr(ref));
}

pub inline fn setCacheRefOffset(ref: SchemeObject, offset: usize) void {
    setPairCdr(ref, ulongToFixnum(offset));
}

pub inline fn promiseP(obj: SchemeObject) bool {
    return objectType(obj) == tc_delayed;
}

pub inline fn delayedSnapped(delayed: SchemeObject) SchemeObject {
    return memoryRef(delayed, 0);
}

pub inline fn delayedValue(delayed: SchemeObject) SchemeObject {
    return memoryRef(delayed, 1);
}

pub inline fn delayedEnv(delayed: SchemeObject) SchemeObject {
    return memoryRef(delayed, 0);
}

pub inline fn delayedProc(delayed: SchemeObject) SchemeObject {
    return memoryRef(delayed, 1);
}

pub inline fn historyMarkedP(obj: SchemeObject) bool {
    return (obj & history_mark_mask) != 0;
}

pub inline fn historyMark(slot: *SchemeObject) void {
    slot.* |= history_mark_mask;
}

pub inline fn cellContents(cell: SchemeObject) SchemeObject {
    return memoryRef(cell, 0);
}

pub inline fn setCellContents(cell: SchemeObject, val: SchemeObject) void {
    memorySet(cell, 0, val);
}

pub inline fn entityOperator(o: SchemeObject) SchemeObject {
    return memoryRef(o, 0);
}

pub inline fn entityData(o: SchemeObject) SchemeObject {
    return memoryRef(o, 1);
}

pub inline fn ustringBytesPerCp(obj: SchemeObject) usize {
    return objectType(nmVectorSubheader(obj)) & 0x3;
}

pub inline fn ustringLength(s: SchemeObject) usize {
    return objectDatum(nmVectorSubheader(s));
}

pub inline fn ustringData(s: SchemeObject) [*]u8 {
    return bytevectorData(s);
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

pub const max_ascii: usize = @as(usize, 1) << ascii_length;
pub const max_code: usize = @as(usize, 1) << code_length;
pub const max_bits: usize = @as(usize, 1) << bits_length;
pub const max_mit_ascii: usize = @as(usize, 1) << mit_ascii_length;

pub const mask_ascii: usize = max_ascii - 1;
pub const char_mask_code: usize = max_code - 1;
pub const char_mask_bits: usize = max_bits - 1;
pub const mask_mit_ascii: usize = max_mit_ascii - 1;

pub inline fn asciiToChar(ascii: usize) SchemeObject {
    return makeObject(tc_character, ascii);
}

pub inline fn charToAsciiP(obj: SchemeObject) bool {
    return objectDatum(obj) < max_ascii;
}

pub inline fn charToAscii(obj: SchemeObject) usize {
    return obj & mask_ascii;
}

pub inline fn makeChar(bits: usize, code: usize) SchemeObject {
    return makeObject(tc_character, (bits << code_length) | code);
}

pub inline fn charBits(c: SchemeObject) usize {
    return (objectDatum(c) >> code_length) & char_mask_bits;
}

pub inline fn charCode(c: SchemeObject) usize {
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

pub inline fn unsignedFixnumToLong(fixnum: SchemeObject) isize {
    return @intCast(objectDatum(fixnum));
}

pub inline fn longToUnsignedFixnum(n: isize) SchemeObject {
    return makeObject(tc_fixnum, @bitCast(n));
}

pub inline fn longToFixnumP(n: isize) bool {
    const bits: usize = @bitCast(n);
    return (bits & sign_mask) == 0 or (bits & sign_mask) == sign_mask;
}

pub inline fn longToFixnum(n: isize) SchemeObject {
    const bits: usize = @bitCast(n);
    return makeObject(tc_fixnum, bits & datum_mask);
}

pub inline fn fixnumToLong(fixnum: SchemeObject) isize {
    const raw = (fixnum ^ fixnum_sign_bit) -% ((tc_fixnum << datum_length) | fixnum_sign_bit);
    return @bitCast(raw);
}

pub inline fn ulongToFixnumP(n: usize) bool {
    return (n & sign_mask) == 0;
}

pub inline fn ulongToFixnum(n: usize) SchemeObject {
    return makeObject(tc_fixnum, n);
}

pub inline fn fixnumToUlongP(fixnum: SchemeObject) bool {
    return (objectDatum(fixnum) & sign_mask) == 0;
}

pub inline fn fixnumToUlong(fixnum: SchemeObject) usize {
    return objectDatum(fixnum);
}

// Vectors, NMVs, Bytevectors, Flonum vectors
pub inline fn makeVectorHeader(length: usize) SchemeObject {
    return makeObject(tc_manifest_vector, length);
}

pub inline fn makeNmvHeader(length: usize) SchemeObject {
    return makeObject(tc_manifest_nm_vector, length);
}

pub inline fn bytesToWords(nbytes: usize) usize {
    const word_bytes: usize = @sizeOf(SchemeObject);
    return (nbytes + word_bytes - 1) / word_bytes;
}

pub inline fn vectorHeader(v: SchemeObject) SchemeObject {
    return memoryRef(v, 0);
}

pub inline fn setVectorHeader(v: SchemeObject, header: SchemeObject) void {
    memorySet(v, 0, header);
}

pub inline fn vectorLength(v: SchemeObject) usize {
    return objectDatum(vectorHeader(v));
}

pub inline fn setVectorLength(v: SchemeObject, new_length: usize) void {
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

pub inline fn bytevectorLengthToGcLength(nbytes: usize) usize {
    return 1 + bytesToWords(nbytes + 1);
}

pub inline fn makeBytevectorSubheader(nbytes: usize) SchemeObject {
    return makeObject(0, nbytes);
}

pub inline fn bytevectorLength(bv: SchemeObject) usize {
    return objectDatum(nmVectorSubheader(bv));
}

pub inline fn setBytevectorLength(bv: SchemeObject, nbytes: usize) void {
    setNmVectorSubheader(bv, makeBytevectorSubheader(nbytes));
    bytevectorSet(bv, @intCast(nbytes), 0x00);
}

pub inline fn legacyStringLength(s: SchemeObject) usize {
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

pub inline fn setLegacyStringLength(s: SchemeObject, nbytes: usize) void {
    setBytevectorLength(s, nbytes);
}

pub inline fn legacyStringMaxLength(s: SchemeObject) usize {
    return (vectorLength(s) - 1) * @sizeOf(SchemeObject) - 1;
}

pub inline fn setLegacyStringMaxLength(s: SchemeObject, nbytes: usize) void {
    setVectorHeader(s, makeNmvHeader(bytevectorLengthToGcLength(nbytes)));
}

pub inline fn hashToFixnum(h: u32) SchemeObject {
    if (fixnum_length >= 32) {
        return ulongToFixnum(@as(usize, h));
    }
    return ulongToFixnum((@as(usize, h) >> fixnum_length) ^ (@as(usize, h) & fixnum_mask));
}

pub const flonum_size: usize = bytesToWords(@sizeOf(f64));

pub inline fn floatingVectorLength(v: SchemeObject) usize {
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
        try std.testing.expectEqual(@as(usize, 17), objectDatum(v));
        const nmv = makeNmvHeader(42);
        try std.testing.expectEqual(tc_manifest_nm_vector, objectType(nmv));
        try std.testing.expectEqual(@as(usize, 42), objectDatum(nmv));
    }

    // Fixnum sign-extension round trips
    const samples = [_]isize{ 0, 1, -1, 42, -42, smallest_fixnum, biggest_fixnum };
    for (samples) |s| {
        try std.testing.expect(longToFixnumP(s));
        const fx = longToFixnum(s);
        try std.testing.expect(fixnumP(fx));
        try std.testing.expectEqual(s, fixnumToLong(fx));
        if (s >= 0) {
            try std.testing.expect(fixnumToUlongP(fx));
            try std.testing.expectEqual(@as(usize, @intCast(s)), fixnumToUlong(fx));
        } else {
            try std.testing.expect(!fixnumToUlongP(fx));
        }
    }
    try std.testing.expect(!longToFixnumP(biggest_fixnum + 1));
    try std.testing.expect(!longToFixnumP(smallest_fixnum - 1));

    // Character packing
    const ch = makeChar(0xA, 'Z');
    try std.testing.expect(characterP(ch));
    try std.testing.expectEqual(@as(usize, 0xA), charBits(ch));
    try std.testing.expectEqual(@as(usize, 'Z'), charCode(ch));
    try std.testing.expect(!charToAsciiP(ch));
    const ascii_ch = asciiToChar('a');
    try std.testing.expect(charToAsciiP(ascii_ch));
    try std.testing.expectEqual(@as(usize, 'a'), charToAscii(ascii_ch));

    // Bytevector GC length (subheader + ceil((nbytes + 1) / word_bytes))
    try std.testing.expectEqual(@as(usize, 2), bytevectorLengthToGcLength(0));
    try std.testing.expectEqual(@as(usize, 2), bytevectorLengthToGcLength(7));
    try std.testing.expectEqual(@as(usize, 3), bytevectorLengthToGcLength(8));
    try std.testing.expectEqual(@as(usize, 10), bytevectorLengthToGcLength(64));
}
