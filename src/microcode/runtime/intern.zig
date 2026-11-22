// Derived from MIT/GNU Scheme C sources (`src/microcode/intern.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const str = @import("../data/string.zig");

fn findSymbolInternal(length: usize, name: ?[*]const u8) *obj.SchemeObject {
    const obarray = obj.vectorRef(abi.fixed_objects, abi.fixobj_obarray);
    const obarray_len = obj.vectorLength(obarray);
    const hash = abi.memory_hash(length, name);
    var bucket = obj.vectorLoc(obarray, @intCast(@as(usize, hash) % obarray_len));
    while (true) {
        const list = bucket[0];
        if (obj.weakPairP(list) or obj.pairP(list)) {
            const symbol = obj.pairCar(list);
            if (obj.internedSymbolP(symbol)) {
                const name2 = obj.symbolName(symbol);
                if (obj.legacyStringLength(name2) == length) {
                    const n_usize: usize = @intCast(length);
                    if (n_usize == 0 or std.mem.eql(u8, obj.legacyStringData(name2)[0..n_usize], name.?[0..n_usize])) {
                        return &obj.pairCarLoc(list)[0];
                    }
                }
                bucket = obj.pairCdrLoc(list);
            } else {
                bucket[0] = obj.pairCdr(list);
            }
        } else {
            return &bucket[0];
        }
    }
}

fn replaceSymbolBucketType(symbol: obj.SchemeObject, new_tc: usize) void {
    if (obj.uninternedSymbolP(symbol)) return;
    std.debug.assert(obj.internedSymbolP(symbol));

    const obarray = obj.vectorRef(abi.fixed_objects, abi.fixobj_obarray);
    const name = obj.symbolName(symbol);
    const length = obj.legacyStringLength(name);
    const char_pointer = obj.legacyStringData(name);
    const hash = abi.memory_hash(length, char_pointer);
    var bucket = obj.vectorLoc(obarray, @intCast(@as(usize, hash) % obj.vectorLength(obarray)));
    while (true) {
        const list = bucket[0];
        std.debug.assert(obj.weakPairP(list) or obj.pairP(list));
        const element = obj.pairCar(list);
        if (obj.internedSymbolP(element)) {
            if (element == symbol) {
                bucket[0] = obj.objectNewType(new_tc, list);
                return;
            }
            bucket = obj.pairCdrLoc(list);
        } else {
            bucket[0] = obj.pairCdr(list);
        }
    }
}

pub export fn strengthen_symbol(symbol: obj.SchemeObject) callconv(.c) void {
    replaceSymbolBucketType(symbol, obj.tc_list);
}

pub export fn weaken_symbol(symbol: obj.SchemeObject) callconv(.c) void {
    replaceSymbolBucketType(symbol, obj.tc_weak_cons);
}

fn makeSymbol(name: obj.SchemeObject, cell: *obj.SchemeObject) obj.SchemeObject {
    abi.primitiveGcIfNeeded(4);
    const symbol = obj.makePointerObject(obj.tc_interned_symbol, abi.Free);
    abi.Free[0] = name;
    abi.Free[1] = obj.unbound_object;
    abi.Free += 2;
    cell.* = abi.system_pair_cons(@intCast(obj.tc_weak_cons), symbol, obj.empty_list);
    return symbol;
}

pub export fn find_symbol(length: usize, name: ?[*]const u8) callconv(.c) obj.SchemeObject {
    const cell = findSymbolInternal(length, name);
    return if (obj.internedSymbolP(cell.*)) cell.* else obj.sharp_f;
}

pub export fn memory_to_symbol(length: usize, name: ?*const anyopaque) callconv(.c) obj.SchemeObject {
    const cell = findSymbolInternal(length, @ptrCast(name));
    return if (obj.internedSymbolP(cell.*))
        cell.*
    else
        makeSymbol(abi.memory_to_bytevector(length, name), cell);
}

pub export fn char_pointer_to_symbol(name: [*:0]const u8) callconv(.c) obj.SchemeObject {
    return memory_to_symbol(@intCast(std.mem.len(name)), name);
}

pub export fn string_to_symbol(name: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const cell = findSymbolInternal(obj.legacyStringLength(name), obj.legacyStringData(name));
    return if (obj.internedSymbolP(cell.*)) cell.* else makeSymbol(name, cell);
}

pub export fn intern_symbol(symbol: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    var name = obj.symbolName(symbol);
    const cell = findSymbolInternal(obj.legacyStringLength(name), obj.legacyStringData(name));
    if (obj.internedSymbolP(cell.*)) return cell.*;
    // Eliminate legacy strings as names.
    if (obj.legacyStringP(name)) {
        name = obj.objectNewType(obj.tc_bytevector, name);
        obj.setSymbolName(symbol, name);
    }
    const result = obj.objectNewType(obj.tc_interned_symbol, symbol);
    cell.* = abi.system_pair_cons(@intCast(obj.tc_weak_cons), result, obj.empty_list);
    return result;
}

pub export fn arg_symbol(n: c_int) callconv(.c) [*:0]const u8 {
    abi.checkArg(n, obj.symbolP);
    return @ptrCast(obj.legacyStringData(obj.symbolName(abi.argRef(@intCast(n)))));
}

pub export fn arg_interned_symbol(n: c_int) callconv(.c) [*:0]const u8 {
    abi.checkArg(n, obj.internedSymbolP);
    return @ptrCast(obj.legacyStringData(obj.symbolName(abi.argRef(@intCast(n)))));
}

// DEFINE_PRIMITIVE ("FIND-SYMBOL", Prim_find_symbol, 1, 1,
//   "(STRING)\n\
// Returns the symbol named STRING, or #F if no such symbol exists.")
pub export fn Prim_find_symbol() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const string = abi.argRef(1);
    return find_symbol(obj.legacyStringLength(string), obj.legacyStringData(string));
}

// DEFINE_PRIMITIVE ("STRING->SYMBOL", Prim_string_to_symbol, 1, 1,
//   "(STRING)\n\
// Returns the interned symbol named STRING, constructing a new symbol\n\
// if needed.")
pub export fn Prim_string_to_symbol() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    return string_to_symbol(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("STRING-HASH", Prim_string_hash, 1, 1,
//   "(STRING)\n\
// Returns the hash value for STRING, using the hashing algorithm for\n\
// interning symbols.")
pub export fn Prim_string_hash() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const string = abi.argRef(1);
    return obj.hashToFixnum(abi.memory_hash(obj.legacyStringLength(string), obj.legacyStringData(string)));
}

// DEFINE_PRIMITIVE ("STRING-HASH-MOD", Prim_string_hash_mod, 2, 2,
//   "(STRING DENOMINATOR)\n\
// DENOMINATOR must be a nonnegative integer.\n\
// Equivalent to (MODULO (STRING-HASH STRING) DENOMINATOR).")
pub export fn Prim_string_hash_mod() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, str.string_p);
    const string = abi.argRef(1);
    const h: usize = abi.memory_hash(obj.legacyStringLength(string), obj.legacyStringData(string));
    const denom = abi.arg_ulong_integer(2);
    if (denom == 0) abi.error_bad_range_arg(2);
    return obj.hashToFixnum(@intCast(h % denom));
}

test "intern symbol lookup, weak-pair pruning, strengthen/weaken, and string hashing" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    // Build fixed_objects[fixobj_obarray] = 17-slot empty_list vector
    const obarray = abi.make_vector(17, obj.empty_list, true);
    const fixobjs = abi.make_vector(0x33, obj.sharp_f, true);
    obj.vectorSet(fixobjs, abi.fixobj_obarray, obarray);
    abi.fixed_objects = fixobjs;

    const s_foo = str.char_pointer_to_string("foo");
    stubs.setArgs(&.{s_foo});
    try std.testing.expectEqual(obj.sharp_f, Prim_find_symbol());

    stubs.setArgs(&.{s_foo});
    const sym_foo = Prim_string_to_symbol();
    try std.testing.expect(obj.internedSymbolP(sym_foo));
    try std.testing.expectEqual(obj.unbound_object, obj.memoryRef(sym_foo, 1));

    // Repeated lookup returns identical object
    stubs.setArgs(&.{str.char_pointer_to_string("foo")});
    try std.testing.expectEqual(sym_foo, Prim_find_symbol());
    try std.testing.expectEqual(sym_foo, char_pointer_to_symbol("foo"));

    // Strengthen then weaken symbol updates bucket pair tag
    const h = abi.memory_hash(3, "foo");
    const bucket_idx: usize = @intCast(@as(usize, h) % 17);
    try std.testing.expect(obj.weakPairP(obj.vectorRef(obarray, bucket_idx)));
    strengthen_symbol(sym_foo);
    try std.testing.expect(obj.pairP(obj.vectorRef(obarray, bucket_idx)));
    weaken_symbol(sym_foo);
    try std.testing.expect(obj.weakPairP(obj.vectorRef(obarray, bucket_idx)));

    // Dead weak-pair entry gets pruned automatically on lookup
    obj.setPairCar(obj.vectorRef(obarray, bucket_idx), obj.sharp_f);
    stubs.setArgs(&.{s_foo});
    try std.testing.expectEqual(obj.sharp_f, Prim_find_symbol());
    try std.testing.expectEqual(obj.empty_list, obj.vectorRef(obarray, bucket_idx));

    // Uninterned symbol with legacy string gets retagged to bytevector on intern_symbol
    const legacy_name = str.char_pointer_to_string("bar");
    const unint = obj.makePointerObject(obj.tc_uninterned_symbol, abi.Free);
    abi.Free[0] = legacy_name;
    abi.Free[1] = obj.unbound_object;
    abi.Free += 2;
    const interned_bar = intern_symbol(unint);
    try std.testing.expect(obj.internedSymbolP(interned_bar));
    try std.testing.expect(obj.bytevectorP(obj.symbolName(interned_bar)));

    // STRING-HASH / STRING-HASH-MOD
    stubs.setArgs(&.{s_foo});
    const h_fx = Prim_string_hash();
    try std.testing.expectEqual(@as(usize, h), obj.fixnumToUlong(h_fx));
    stubs.setArgs(&.{ s_foo, obj.ulongToFixnum(97) });
    try std.testing.expectEqual(@as(usize, h % 97), obj.fixnumToUlong(Prim_string_hash_mod()));
}
