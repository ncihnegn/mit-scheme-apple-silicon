// Derived from MIT/GNU Scheme C sources (`src/microcode/lookup.c`, `lookup.h`, `trap.h`, `sdata.h`, `scode.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const intern = @import("intern.zig");

const space_per_uuo_link: usize = 10;
const space_per_reference: usize = 8;
const ptr_ref_trap_size: usize = 2;
const cache_size: usize = 3;
const cache_refs_size: usize = 3;
const frame_extension_min_size: usize = 4;

inline fn externalUnassignedObject() obj.SchemeObject {
    return obj.vectorRef(abi.fixed_objects, abi.fixobj_non_object);
}

inline fn mapToUnassigned(value: obj.SchemeObject) obj.SchemeObject {
    return if (value == externalUnassignedObject()) obj.unassigned_object else value;
}

inline fn mapFromUnassigned(value: obj.SchemeObject) obj.SchemeObject {
    return if (value == obj.unassigned_object) externalUnassignedObject() else value;
}

inline fn dieIfError(result: isize) void {
    if (result != abi.prim_done) {
        abi.outf_fatal("\nRan out of guaranteed space!\n");
        abi.Microcode_Termination(abi.term_exit);
    }
}

fn cacheKindRefs(cache: obj.SchemeObject, kind: abi.CacheRefKind) *obj.SchemeObject {
    const loc = switch (kind) {
        .lookup_cache => obj.cacheLookupRefs(cache),
        .assignment_cache => obj.cacheAssignmentRefs(cache),
        .operator_cache => obj.cacheOperatorRefs(cache),
    };
    return @ptrCast(loc);
}

fn makePtrRefTrap(tag: usize, cache: obj.SchemeObject) obj.SchemeObject {
    const free = abi.Free;
    const trap = obj.makePointerObject(obj.tc_reference_trap, free);
    free[0] = obj.ulongToFixnum(tag);
    free[1] = cache;
    abi.Free = free + 2;
    return trap;
}

fn makeCache(value: obj.SchemeObject, clone: obj.SchemeObject, refs: obj.SchemeObject) obj.SchemeObject {
    const free = abi.Free;
    const cache = obj.makePointerObject(obj.tc_hunk3, free);
    free[0] = value;
    free[1] = clone;
    free[2] = refs;
    abi.Free = free + 3;
    return cache;
}

fn makeCacheClone(cache: obj.SchemeObject) obj.SchemeObject {
    return makeCache(obj.expensive_object, cache, obj.cacheRefs(cache));
}

fn makeCacheRefs() obj.SchemeObject {
    const free = abi.Free;
    const refs = obj.makePointerObject(obj.tc_hunk3, free);
    free[0] = obj.empty_list;
    free[1] = obj.empty_list;
    free[2] = obj.empty_list;
    abi.Free = free + 3;
    return refs;
}

fn walkReferences(
    refs_pointer: *obj.SchemeObject,
    ctx: anytype,
    comptime body: fn (@TypeOf(ctx), obj.SchemeObject, *obj.SchemeObject) ?obj.SchemeObject,
) ?obj.SchemeObject {
    var palist = refs_pointer;
    while (obj.pairP(palist.*)) {
        const entry = obj.pairCar(palist.*);
        var prefs: *obj.SchemeObject = @ptrCast(obj.pairCdrLoc(entry));
        while (obj.pairP(prefs.*)) {
            const ref = obj.pairCar(prefs.*);
            if (obj.cacheRefBlock(ref) == obj.gc_reclaimed) {
                prefs.* = obj.pairCdr(prefs.*);
                continue;
            }
            if (body(ctx, ref, palist)) |ret| {
                return ret;
            }
            prefs = @ptrCast(obj.pairCdrLoc(prefs.*));
        }
        if (obj.pairP(obj.pairCdr(entry))) {
            palist = @ptrCast(obj.pairCdrLoc(palist.*));
        } else {
            palist.* = obj.pairCdr(palist.*);
        }
    }
    return null;
}

pub export fn get_trap_kind(object: obj.SchemeObject) callconv(.c) usize {
    if (!obj.referenceTrapP(object)) return obj.non_trap_kind;
    const datum = obj.objectDatum(object);
    return if (datum <= obj.trap_max_immediate)
        datum
    else
        obj.objectDatum(obj.ptrRefTrapTag(object));
}

pub export fn lookup_variable(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    if (!(obj.environmentP(environment) and obj.symbolP(symbol))) {
        return abi.err_bad_frame;
    }
    const cell = findBindingCell(environment, symbol, null) orelse return abi.err_unbound_variable;
    const value = cell[0];
    return switch (get_trap_kind(value)) {
        obj.non_trap_kind => blk: {
            value_ret.* = value;
            break :blk abi.prim_done;
        },
        obj.trap_unassigned => abi.err_unassigned_variable,
        obj.trap_unbound => abi.err_unbound_variable,
        obj.trap_macro => blk: {
            value_ret.* = value;
            break :blk abi.err_macro_binding;
        },
        obj.trap_compiler_cached => lookupVariableCache(obj.ptrRefTrapCache(value), value_ret),
        else => abi.err_illegal_reference_trap,
    };
}

fn lookupVariableCache(cache: obj.SchemeObject, value_ret: *obj.SchemeObject) isize {
    const value = obj.cacheValue(cache);
    return switch (get_trap_kind(value)) {
        obj.non_trap_kind => blk: {
            value_ret.* = value;
            break :blk abi.prim_done;
        },
        obj.trap_unassigned => abi.err_unassigned_variable,
        obj.trap_unbound => abi.err_unbound_variable,
        obj.trap_macro => blk: {
            value_ret.* = value;
            break :blk abi.err_macro_binding;
        },
        else => abi.err_illegal_reference_trap,
    };
}

pub export fn safe_lookup_variable(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    const result = lookup_variable(environment, symbol, value_ret);
    if (result == abi.err_unassigned_variable) {
        value_ret.* = externalUnassignedObject();
        return abi.prim_done;
    }
    return result;
}

pub export fn variable_unassigned_p(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    var dummy: obj.SchemeObject = undefined;
    const result = lookup_variable(environment, symbol, &dummy);
    switch (result) {
        abi.err_unassigned_variable => {
            value_ret.* = obj.sharp_t;
            return abi.prim_done;
        },
        abi.prim_done => {
            value_ret.* = obj.sharp_f;
            return abi.prim_done;
        },
        else => return result,
    }
}

pub export fn variable_unbound_p(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    var dummy: obj.SchemeObject = undefined;
    const result = lookup_variable(environment, symbol, &dummy);
    switch (result) {
        abi.err_unbound_variable => {
            value_ret.* = obj.sharp_t;
            return abi.prim_done;
        },
        abi.err_unassigned_variable, abi.err_macro_binding, abi.prim_done => {
            value_ret.* = obj.sharp_f;
            return abi.prim_done;
        },
        else => return result,
    }
}

pub export fn variable_unreferenceable_p(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    var dummy: obj.SchemeObject = undefined;
    const result = lookup_variable(environment, symbol, &dummy);
    switch (result) {
        abi.err_unbound_variable, abi.err_unassigned_variable, abi.err_macro_binding => {
            value_ret.* = obj.sharp_t;
            return abi.prim_done;
        },
        abi.prim_done => {
            value_ret.* = obj.sharp_f;
            return abi.prim_done;
        },
        else => return result,
    }
}

pub export fn assign_variable(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    if (!(obj.environmentP(environment) and obj.symbolP(symbol))) {
        return abi.err_bad_frame;
    }
    const cell = findBindingCell(environment, symbol, null) orelse return abi.err_unbound_variable;
    return assignVariableEnd(cell, value, value_ret, false);
}

fn assignVariableEnd(
    cell: [*]obj.SchemeObject,
    value: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
    force_p: bool,
) isize {
    const old_value = cell[0];
    switch (get_trap_kind(old_value)) {
        obj.non_trap_kind, obj.trap_unassigned => {},
        obj.trap_unbound => if (!force_p) return abi.err_unbound_variable,
        obj.trap_macro => if (!force_p) return abi.err_macro_binding,
        obj.trap_compiler_cached => return assignVariableCache(obj.ptrRefTrapCache(old_value), value, value_ret, force_p),
        else => return abi.err_illegal_reference_trap,
    }
    value_ret.* = mapFromUnassigned(old_value);
    cell[0] = mapToUnassigned(value);
    return abi.prim_done;
}

fn assignVariableCache(
    cache: obj.SchemeObject,
    value: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
    force_p: bool,
) isize {
    const old_value = obj.cacheValue(cache);
    switch (get_trap_kind(old_value)) {
        obj.non_trap_kind, obj.trap_unassigned => {},
        obj.trap_unbound => if (!force_p) return abi.err_unbound_variable,
        obj.trap_macro => if (!force_p) return abi.err_macro_binding,
        else => return abi.err_illegal_reference_trap,
    }
    value_ret.* = mapFromUnassigned(old_value);
    if (build_options.cc_support) {
        if (obj.pairP(obj.cacheOperatorRefs(cache)[0])) {
            return updateUuoLinks(cache, mapToUnassigned(value));
        }
    }
    obj.setCacheValue(cache, mapToUnassigned(value));
    return abi.prim_done;
}

fn updateUuoLinks(cache: obj.SchemeObject, new_value: obj.SchemeObject) isize {
    const needed = countReferences(cacheKindRefs(cache, .operator_cache)) * space_per_uuo_link + cache_size;
    if (abi.gcNeededP(needed)) {
        abi.requestGc(needed);
        return abi.prim_interrupt;
    }
    obj.setCacheValue(cache, new_value);
    updateClone(cache);
    const Ctx = struct { cache: obj.SchemeObject };
    const ctx: Ctx = .{ .cache = cache };
    _ = walkReferences(cacheKindRefs(cache, .operator_cache), ctx, struct {
        fn f(c: Ctx, ref: obj.SchemeObject, _: *obj.SchemeObject) ?obj.SchemeObject {
            installOperatorCache(c.cache, obj.cacheRefBlock(ref), obj.cacheRefOffset(ref));
            return null;
        }
    }.f);
    return abi.prim_done;
}

pub export fn define_variable(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value: obj.SchemeObject,
) callconv(.c) isize {
    if (!(obj.environmentP(environment) and obj.symbolP(symbol))) {
        return abi.err_bad_frame;
    }

    if (scanFrame(environment, symbol, true)) |cell| {
        if (obj.globalFrameP(environment)) {
            intern.strengthen_symbol(symbol);
        }
        var old_value: obj.SchemeObject = undefined;
        return assignVariableEnd(cell, value, &old_value, true);
    }

    const ext_res = guaranteeExtensionSpace(environment);
    if (ext_res != abi.prim_done) return ext_res;

    const shadowed_cell = findBindingCell(obj.envParent(environment), symbol, null);
    const old_cache: obj.SchemeObject = if (shadowed_cell) |sc|
        if (get_trap_kind(sc[0]) == obj.trap_compiler_cached) obj.ptrRefTrapCache(sc[0]) else obj.sharp_f
    else
        obj.sharp_f;

    const needed: usize = 2 + if (old_cache != obj.sharp_f) updateCacheRefsSpace(old_cache, environment, symbol) else 0;
    if (abi.gcNeededP(needed)) {
        abi.requestGc(needed);
        return abi.prim_interrupt;
    }

    const cell = extendEnvironment(environment, symbol, value);
    return if (old_cache != obj.sharp_f)
        updateCacheReferences(old_cache, cell, environment, symbol)
    else
        abi.prim_done;
}

fn extendEnvironment(environment: obj.SchemeObject, symbol: obj.SchemeObject, value: obj.SchemeObject) [*]obj.SchemeObject {
    const pair = abi.cons(symbol, mapToUnassigned(value));
    const length = obj.extendedFrameLength(environment);
    obj.extendedFrameBindings(environment)[@intCast(length)] = pair;
    obj.setExtendedFrameLength(environment, length + 1);
    return obj.pairCdrLoc(pair);
}

fn guaranteeExtensionSpace(environment: obj.SchemeObject) isize {
    if (obj.extendedFrameP(environment)) {
        const length = obj.extendedFrameLength(environment);
        if (length == obj.extendedFrameMaxLength(environment)) {
            var extension: obj.SchemeObject = undefined;
            const res = allocateFrameExtension(2 * length, obj.extendedFrameProc(environment), &extension);
            if (res != abi.prim_done) return res;
            const n: usize = @intCast(length);
            @memcpy(
                obj.frameExtensionBindings(extension)[0..n],
                obj.extendedFrameBindings(environment)[0..n],
            );
            obj.setFrameExtensionLength(extension, length);
            obj.setEnvExtension(environment, extension);
        }
    } else {
        var extension: obj.SchemeObject = undefined;
        const res = allocateFrameExtension(16, obj.envProc(environment), &extension);
        if (res != abi.prim_done) return res;
        obj.setEnvExtension(environment, extension);
    }
    return abi.prim_done;
}

fn allocateFrameExtension(
    length: usize,
    procedure: obj.SchemeObject,
    extension_ret: *obj.SchemeObject,
) isize {
    const n_words = frame_extension_min_size + length;
    if (abi.gcNeededP(n_words)) {
        abi.requestGc(n_words);
        return abi.prim_interrupt;
    }
    const extension = abi.make_vector(n_words - 1, obj.sharp_f, false);
    obj.setFrameExtensionParent(extension, obj.procEnvironment(procedure));
    obj.setFrameExtensionProc(extension, procedure);
    obj.setFrameExtensionLength(extension, 0);
    extension_ret.* = extension;
    return abi.prim_done;
}

pub export fn link_variables(
    target_environment: obj.SchemeObject,
    target_symbol: obj.SchemeObject,
    source_environment: obj.SchemeObject,
    source_symbol: obj.SchemeObject,
) callconv(.c) isize {
    if (!(obj.environmentP(target_environment) and
        obj.environmentP(source_environment) and
        obj.symbolP(target_symbol) and
        obj.symbolP(source_symbol)))
    {
        return abi.err_bad_frame;
    }

    const source_cell = findBindingCell(source_environment, source_symbol, null) orelse return abi.err_unbound_variable;
    const source_kind = get_trap_kind(source_cell[0]);
    if (source_kind == obj.trap_unbound) return abi.err_unbound_variable;

    const target_cell = scanFrame(target_environment, target_symbol, true);
    if (target_cell) |tc| {
        if (tc == source_cell) return abi.prim_done;
    }

    if (target_cell != null and obj.globalFrameP(target_environment)) {
        intern.strengthen_symbol(target_symbol);
    }

    if (target_cell) |tc| {
        if (get_trap_kind(tc[0]) == obj.trap_compiler_cached) {
            const target_cache = obj.ptrRefTrapCache(tc[0]);
            if (source_kind == obj.trap_compiler_cached) {
                const source_cache = obj.ptrRefTrapCache(source_cell[0]);
                if (source_cache == target_cache) return abi.prim_done;
                const needed = countReferences(cacheKindRefs(target_cache, .operator_cache)) * space_per_uuo_link + 2 * cache_size;
                if (abi.gcNeededP(needed)) {
                    abi.requestGc(needed);
                    return abi.prim_interrupt;
                }
                obj.setCacheValue(target_cache, obj.cacheValue(source_cache));
                if (build_options.cc_support) {
                    moveAllReferences(source_cache, target_cache, .lookup_cache);
                    moveAllReferences(source_cache, target_cache, .assignment_cache);
                    moveAllReferences(source_cache, target_cache, .operator_cache);
                }
                updateClone(source_cache);
                updateClone(target_cache);
                obj.setPtrRefTrapCache(source_cell[0], target_cache);
            } else {
                obj.setCacheValue(target_cache, source_cell[0]);
            }
            source_cell[0] = tc[0];
            return abi.prim_done;
        }
    }

    const cache_res = guaranteeCache(source_cell);
    if (cache_res != abi.prim_done) return cache_res;
    return define_variable(target_environment, target_symbol, source_cell[0]);
}

fn moveAllReferences(from_cache: obj.SchemeObject, to_cache: obj.SchemeObject, kind: abi.CacheRefKind) void {
    const pfrom = cacheKindRefs(from_cache, kind);
    var pto = cacheKindRefs(to_cache, kind);

    const Ctx = struct { to_cache: obj.SchemeObject, kind: abi.CacheRefKind };
    const ctx: Ctx = .{ .to_cache = to_cache, .kind = kind };
    _ = walkReferences(pfrom, ctx, struct {
        fn f(c: Ctx, ref: obj.SchemeObject, _: *obj.SchemeObject) ?obj.SchemeObject {
            installCache(c.to_cache, obj.cacheRefBlock(ref), obj.cacheRefOffset(ref), c.kind);
            return null;
        }
    }.f);

    while (obj.pairP(pto.*)) {
        pto = @ptrCast(obj.pairCdrLoc(pto.*));
    }
    pto.* = pfrom.*;
    pfrom.* = obj.empty_list;
}

pub export fn unbind_variable(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    var frame: obj.SchemeObject = 0;
    const cell = findBindingCell(environment, symbol, &frame);
    if (obj.globalFrameP(frame)) {
        intern.weaken_symbol(symbol);
    }
    const kind = if (cell) |c| get_trap_kind(c[0]) else obj.trap_unbound;
    switch (kind) {
        obj.trap_unbound => {
            value_ret.* = obj.sharp_f;
            return abi.prim_done;
        },
        obj.non_trap_kind, obj.trap_unassigned, obj.trap_macro => {
            unbindVariable1(cell.?, frame, symbol);
            value_ret.* = obj.sharp_t;
            return abi.prim_done;
        },
        obj.trap_compiler_cached => {
            const c = cell.?;
            const cache = obj.ptrRefTrapCache(c[0]);
            switch (get_trap_kind(obj.cacheValue(cache))) {
                obj.trap_unbound => {
                    value_ret.* = obj.sharp_f;
                    return abi.prim_done;
                },
                obj.non_trap_kind, obj.trap_unassigned, obj.trap_macro => {
                    if (obj.procedureFrameP(frame)) {
                        const res = unbindCachedVariable(c, frame, symbol);
                        if (res != abi.prim_done) return res;
                    } else {
                        obj.setCacheValue(cache, obj.unbound_object);
                    }
                    value_ret.* = obj.sharp_t;
                    return abi.prim_done;
                },
                else => return abi.err_illegal_reference_trap,
            }
        },
        else => return abi.err_illegal_reference_trap,
    }
}

fn unbindCachedVariable(
    cell: [*]obj.SchemeObject,
    frame: obj.SchemeObject,
    symbol: obj.SchemeObject,
) isize {
    const cache = obj.ptrRefTrapCache(cell[0]);
    const shadowed_cell = findBindingCell(obj.envParent(frame), symbol, null);
    const needed = updateCacheRefsSpace(cache, frame, symbol);
    if (abi.gcNeededP(needed)) {
        abi.requestGc(needed);
        return abi.prim_interrupt;
    }
    unbindVariable1(cell, frame, symbol);
    return updateCacheReferences(cache, shadowed_cell, frame, symbol);
}

fn unbindVariable1(cell: [*]obj.SchemeObject, frame: obj.SchemeObject, symbol: obj.SchemeObject) void {
    if (obj.procedureFrameP(frame) and obj.extendedFrameP(frame)) {
        const start = obj.extendedFrameBindings(frame);
        const length = obj.extendedFrameLength(frame);
        var idx: usize = 0;
        const len_u: usize = @intCast(length);
        while (idx < len_u) : (idx += 1) {
            if (obj.pairCar(start[idx]) == symbol) {
                if (idx < len_u - 1) {
                    start[idx] = start[len_u - 1];
                }
                obj.setExtendedFrameLength(frame, length - 1);
                start[len_u - 1] = obj.sharp_f;
                return;
            }
        }
    }
    cell[0] = obj.unbound_object;
}

comptime {
    if (build_options.cc_support) {
        @export(&compilerCacheLookup, .{ .name = "compiler_cache_lookup" });
        @export(&compilerCacheAssignment, .{ .name = "compiler_cache_assignment" });
        @export(&compilerCacheOperator, .{ .name = "compiler_cache_operator" });
        @export(&compilerCacheGlobalOperator, .{ .name = "compiler_cache_global_operator" });
        @export(&compilerVarError, .{ .name = "compiler_var_error" });
        @export(&compilerLookupTrap, .{ .name = "compiler_lookup_trap" });
        @export(&compilerSafeLookupTrap, .{ .name = "compiler_safe_lookup_trap" });
        @export(&compilerUnassignedPTrap, .{ .name = "compiler_unassigned_p_trap" });
        @export(&compilerAssignmentTrap, .{ .name = "compiler_assignment_trap" });
        @export(&compilerOperatorReferenceTrap, .{ .name = "compiler_operator_reference_trap" });
    }
}

fn compilerCacheLookup(name: obj.SchemeObject, block: obj.SchemeObject, offset: usize) callconv(.c) isize {
    return addCacheReference(abi.cc_block_environment(block), name, block, offset, .lookup_cache);
}

fn compilerCacheAssignment(name: obj.SchemeObject, block: obj.SchemeObject, offset: usize) callconv(.c) isize {
    return addCacheReference(abi.cc_block_environment(block), name, block, offset, .assignment_cache);
}

fn compilerCacheOperator(name: obj.SchemeObject, block: obj.SchemeObject, offset: usize) callconv(.c) isize {
    return addCacheReference(abi.cc_block_environment(block), name, block, offset, .operator_cache);
}

fn compilerCacheGlobalOperator(name: obj.SchemeObject, block: obj.SchemeObject, offset: usize) callconv(.c) isize {
    return addCacheReference(obj.the_global_env, name, block, offset, .operator_cache);
}

fn compilerVarError(cache: obj.SchemeObject, block: obj.SchemeObject, kind: abi.CacheRefKind) callconv(.c) obj.SchemeObject {
    const Ctx = struct { block: obj.SchemeObject };
    const ctx: Ctx = .{ .block = block };
    return walkReferences(cacheKindRefs(cache, kind), ctx, struct {
        fn f(c: Ctx, ref: obj.SchemeObject, palist: *obj.SchemeObject) ?obj.SchemeObject {
            if (obj.cacheRefBlock(ref) == c.block) {
                return obj.pairCar(obj.pairCar(palist.*));
            }
            return null;
        }
    }.f) orelse obj.sharp_f;
}

fn compilerLookupTrap(cache: obj.SchemeObject, value_ret: *obj.SchemeObject) callconv(.c) isize {
    return lookupVariableCache(cache, value_ret);
}

fn compilerSafeLookupTrap(cache: obj.SchemeObject, value_ret: *obj.SchemeObject) callconv(.c) isize {
    const result = lookupVariableCache(cache, value_ret);
    if (result == abi.err_unassigned_variable) {
        value_ret.* = externalUnassignedObject();
        return abi.prim_done;
    }
    return result;
}

fn compilerUnassignedPTrap(cache: obj.SchemeObject, value_ret: *obj.SchemeObject) callconv(.c) isize {
    var dummy: obj.SchemeObject = undefined;
    const result = lookupVariableCache(cache, &dummy);
    switch (result) {
        abi.err_unassigned_variable => {
            value_ret.* = obj.sharp_t;
            return abi.prim_done;
        },
        abi.prim_done => {
            value_ret.* = obj.sharp_f;
            return abi.prim_done;
        },
        else => return result,
    }
}

fn compilerAssignmentTrap(
    cache: obj.SchemeObject,
    value: obj.SchemeObject,
    value_ret: *obj.SchemeObject,
) callconv(.c) isize {
    const target_cache = if (obj.cacheCloneP(cache)) obj.cacheClone(cache) else cache;
    return assignVariableCache(target_cache, value, value_ret, false);
}

fn compilerOperatorReferenceTrap(cache: obj.SchemeObject, value_ret: *obj.SchemeObject) callconv(.c) isize {
    return lookupVariableCache(cache, value_ret);
}

fn addCacheReference(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    block: obj.SchemeObject,
    offset: usize,
    kind: abi.CacheRefKind,
) isize {
    var frame: obj.SchemeObject = 0;
    var cell = findBindingCell(environment, symbol, &frame);
    if (cell == null) {
        dieIfError(guaranteeExtensionSpace(frame));
        cell = extendEnvironment(frame, symbol, obj.unbound_object);
    } else if (obj.globalFrameP(frame)) {
        intern.strengthen_symbol(symbol);
    }

    const needed = (2 * cache_size) + space_per_reference + space_per_uuo_link;
    if (abi.gcNeededP(needed)) {
        abi.requestGc(needed);
        return abi.prim_interrupt;
    }
    const c = cell.?;
    dieIfError(guaranteeCache(c));
    const cache = obj.ptrRefTrapCache(c[0]);
    addReference(cacheKindRefs(cache, kind), symbol, block, offset);
    updateClone(cache);
    installCache(cache, block, offset, kind);
    return abi.prim_done;
}

fn addReference(
    palist: *obj.SchemeObject,
    symbol: obj.SchemeObject,
    block: obj.SchemeObject,
    offset: usize,
) void {
    if (findReferencesNamed(palist, symbol)) |prefs_init| {
        var prefs = prefs_init;
        while (obj.pairP(prefs.*)) {
            const ref = obj.pairCar(prefs.*);
            if (obj.cacheRefBlock(ref) == obj.gc_reclaimed) {
                obj.setCacheRefBlock(ref, block);
                obj.setCacheRefOffset(ref, offset);
                return;
            }
            prefs = @ptrCast(obj.pairCdrLoc(prefs.*));
        }
        var reference: obj.SchemeObject = undefined;
        dieIfError(makeCacheReference(block, offset, &reference));
        prefs.* = abi.cons(reference, obj.empty_list);
        return;
    }

    var reference: obj.SchemeObject = undefined;
    dieIfError(makeCacheReference(block, offset, &reference));
    const alist = palist.*;
    palist.* = abi.cons(abi.cons(symbol, abi.cons(reference, obj.empty_list)), alist);
}

fn installCache(cache: obj.SchemeObject, block: obj.SchemeObject, offset: usize, kind: abi.CacheRefKind) void {
    switch (kind) {
        .lookup_cache => abi.write_variable_cache(cache, block, offset),
        .assignment_cache => {
            const clone = obj.cacheClone(cache);
            abi.write_variable_cache(if (clone != obj.sharp_f) clone else cache, block, offset);
        },
        .operator_cache => installOperatorCache(cache, block, offset),
    }
}

fn installOperatorCache(cache: obj.SchemeObject, block: obj.SchemeObject, offset: usize) void {
    const value = obj.cacheValue(cache);
    dieIfError(abi.make_uuo_link(value, cache, block, offset));
}

fn updateCacheRefsSpace(
    from_cache: obj.SchemeObject,
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
) usize {
    if (!build_options.cc_support) return 0;
    return updateCacheRefsSpace1(from_cache, .lookup_cache, environment, symbol) +
        updateCacheRefsSpace1(from_cache, .assignment_cache, environment, symbol) +
        updateCacheRefsSpace1(from_cache, .operator_cache, environment, symbol);
}

fn updateCacheRefsSpace1(
    from_cache: obj.SchemeObject,
    kind: abi.CacheRefKind,
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
) usize {
    const from_palist = cacheKindRefs(from_cache, kind);
    const n_refs = refPairsToMove(from_palist, environment, symbol);
    var result: usize = 0;
    if (n_refs > 0) {
        result += cache_size + 4;
        if (kind == .operator_cache) {
            result += n_refs * space_per_uuo_link;
        }
    }
    return result;
}

fn updateCacheReferences(
    from_cache: obj.SchemeObject,
    to_cell: ?[*]obj.SchemeObject,
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
) isize {
    if (to_cell) |tc| {
        dieIfError(guaranteeCache(tc));
        const to_cache = obj.ptrRefTrapCache(tc[0]);
        if (build_options.cc_support) {
            moveRefPairs(from_cache, to_cache, .lookup_cache, environment, symbol);
            moveRefPairs(from_cache, to_cache, .assignment_cache, environment, symbol);
            moveRefPairs(from_cache, to_cache, .operator_cache, environment, symbol);
        }
        updateClone(to_cache);
    } else if (build_options.cc_support) {
        deleteRefPairs(from_cache, .lookup_cache, environment, symbol);
        deleteRefPairs(from_cache, .assignment_cache, environment, symbol);
        deleteRefPairs(from_cache, .operator_cache, environment, symbol);
    }
    updateClone(from_cache);
    return abi.prim_done;
}

fn refPairsToMove(palist: *obj.SchemeObject, environment: obj.SchemeObject, symbol: obj.SchemeObject) usize {
    var prefs = findReferencesNamed(palist, symbol) orelse return 0;
    var n_refs: usize = 0;
    while (obj.pairP(prefs.*)) {
        const ref = obj.pairCar(prefs.*);
        if (obj.cacheRefBlock(ref) == obj.gc_reclaimed) {
            prefs.* = obj.pairCdr(prefs.*);
            continue;
        }
        if (moveRefPairP(ref, environment)) {
            n_refs += 1;
        }
        prefs = @ptrCast(obj.pairCdrLoc(prefs.*));
    }
    return n_refs;
}

fn deleteRefPairs(
    from_cache: obj.SchemeObject,
    kind: abi.CacheRefKind,
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
) void {
    const from_palist = cacheKindRefs(from_cache, kind);
    var from_prefs = findReferencesNamed(from_palist, symbol) orelse return;
    while (obj.pairP(from_prefs.*)) {
        const ref = obj.pairCar(from_prefs.*);
        if (obj.cacheRefBlock(ref) == obj.gc_reclaimed or moveRefPairP(ref, environment)) {
            from_prefs.* = obj.pairCdr(from_prefs.*);
            continue;
        }
        from_prefs = @ptrCast(obj.pairCdrLoc(from_prefs.*));
    }
}

fn moveRefPairs(
    from_cache: obj.SchemeObject,
    to_cache: obj.SchemeObject,
    kind: abi.CacheRefKind,
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
) void {
    const from_palist = cacheKindRefs(from_cache, kind);
    const to_palist = cacheKindRefs(to_cache, kind);
    var from_prefs = findReferencesNamed(from_palist, symbol) orelse return;
    var to_prefs = findReferencesNamed(to_palist, symbol);

    while (obj.pairP(from_prefs.*)) {
        const p = from_prefs.*;
        const ref = obj.pairCar(p);
        if (obj.cacheRefBlock(ref) == obj.gc_reclaimed) {
            from_prefs.* = obj.pairCdr(p);
            continue;
        }
        if (moveRefPairP(ref, environment)) {
            from_prefs.* = obj.pairCdr(p);
            const tp = to_prefs orelse newAlistEntry(to_palist, symbol);
            to_prefs = tp;
            obj.setPairCdr(p, tp.*);
            tp.* = p;
            installCache(to_cache, obj.cacheRefBlock(ref), obj.cacheRefOffset(ref), kind);
            continue;
        }
        from_prefs = @ptrCast(obj.pairCdrLoc(p));
    }
}

fn newAlistEntry(to_palist: *obj.SchemeObject, symbol: obj.SchemeObject) *obj.SchemeObject {
    const entry = abi.cons(symbol, obj.empty_list);
    const head = to_palist.*;
    to_palist.* = abi.cons(entry, head);
    return @ptrCast(obj.pairCdrLoc(entry));
}

fn moveRefPairP(ref_pair: obj.SchemeObject, ancestor: obj.SchemeObject) bool {
    var descendant = abi.cc_block_environment(obj.cacheRefBlock(ref_pair));
    while (obj.procedureFrameP(descendant)) {
        if (descendant == ancestor) return true;
        descendant = obj.envParent(descendant);
    }
    return descendant == ancestor;
}

fn findBindingCell(
    environment: obj.SchemeObject,
    symbol: obj.SchemeObject,
    frame_ret: ?*obj.SchemeObject,
) ?[*]obj.SchemeObject {
    if (obj.nullFrameP(environment)) {
        if (frame_ret) |fr| fr.* = environment;
        return null;
    }
    std.debug.assert(obj.environmentP(environment));
    var frame = environment;
    while (true) {
        const cell = scanFrame(frame, symbol, false);
        if (cell != null or !obj.environmentP(obj.envParent(frame))) {
            if (frame_ret) |fr| fr.* = frame;
            return cell;
        }
        frame = obj.envParent(frame);
    }
}

fn scanFrame(
    frame: obj.SchemeObject,
    symbol: obj.SchemeObject,
    find_unbound_p: bool,
) ?[*]obj.SchemeObject {
    if (obj.procedureFrameP(frame)) {
        if (obj.extendedFrameP(frame)) {
            const start = obj.extendedFrameBindings(frame);
            const len: usize = @intCast(obj.extendedFrameLength(frame));
            for (start[0..len]) |pair| {
                if (obj.pairCar(pair) == symbol) {
                    return obj.pairCdrLoc(pair);
                }
            }
            return scanProcedureBindings(obj.extendedFrameProc(frame), frame, symbol, find_unbound_p);
        }
        return scanProcedureBindings(obj.envProc(frame), frame, symbol, find_unbound_p);
    }
    std.debug.assert(obj.globalFrameP(frame));
    return obj.symbolGlobalValueCell(symbol);
}

fn scanProcedureBindings(
    procedure: obj.SchemeObject,
    frame: obj.SchemeObject,
    name: obj.SchemeObject,
    find_unbound_p: bool,
) ?[*]obj.SchemeObject {
    const lambda = obj.procLambda(procedure);
    const start = obj.lambdaParams(lambda);
    const n_params: usize = @intCast(obj.lambdaNParams(lambda));
    const vals = obj.envVals(frame);
    for (0..n_params) |idx| {
        if (start[idx] == name) {
            const cell = vals + idx;
            if (find_unbound_p or cell[0] != obj.unbound_object) {
                return cell;
            }
        }
    }
    return null;
}

fn countReferences(palist: *obj.SchemeObject) usize {
    var count: usize = 0;
    const Ctx = struct { count: *usize };
    const ctx: Ctx = .{ .count = &count };
    _ = walkReferences(palist, ctx, struct {
        fn f(c: Ctx, _: obj.SchemeObject, _: *obj.SchemeObject) ?obj.SchemeObject {
            c.count.* += 1;
            return null;
        }
    }.f);
    return count;
}

fn findReferencesNamed(palist_init: *obj.SchemeObject, symbol: obj.SchemeObject) ?*obj.SchemeObject {
    var palist = palist_init;
    while (obj.pairP(palist.*)) {
        const entry = obj.pairCar(palist.*);
        if (obj.pairCar(entry) == symbol) {
            return @ptrCast(obj.pairCdrLoc(entry));
        }
        palist = @ptrCast(obj.pairCdrLoc(palist.*));
    }
    return null;
}

fn updateAssignmentReferences(cache: obj.SchemeObject) void {
    if (!build_options.cc_support) return;
    const clone = obj.cacheClone(cache);
    const reference_cache = if (clone != obj.sharp_f) clone else cache;
    const Ctx = struct { ref_cache: obj.SchemeObject };
    const ctx: Ctx = .{ .ref_cache = reference_cache };
    _ = walkReferences(cacheKindRefs(cache, .assignment_cache), ctx, struct {
        fn f(c: Ctx, ref: obj.SchemeObject, _: *obj.SchemeObject) ?obj.SchemeObject {
            abi.write_variable_cache(c.ref_cache, obj.cacheRefBlock(ref), obj.cacheRefOffset(ref));
            return null;
        }
    }.f);
}

fn guaranteeCache(cell: [*]obj.SchemeObject) isize {
    if (get_trap_kind(cell[0]) == obj.trap_compiler_cached) return abi.prim_done;
    const needed = ptr_ref_trap_size + cache_size + cache_refs_size;
    if (abi.gcNeededP(needed)) {
        abi.requestGc(needed);
        return abi.prim_interrupt;
    }
    cell[0] = makePtrRefTrap(
        obj.trap_compiler_cached,
        makeCache(cell[0], obj.sharp_f, makeCacheRefs()),
    );
    return abi.prim_done;
}

fn updateClone(cache: obj.SchemeObject) void {
    if (obj.pairP(obj.cacheAssignmentRefs(cache)[0]) and
        obj.pairP(obj.cacheOperatorRefs(cache)[0]))
    {
        if (obj.cacheClone(cache) == obj.sharp_f) {
            var clone: obj.SchemeObject = undefined;
            dieIfError(makeClone(cache, &clone));
            obj.setCacheClone(cache, clone);
            updateAssignmentReferences(cache);
        }
    } else if (obj.cacheClone(cache) != obj.sharp_f) {
        obj.setCacheClone(cache, obj.sharp_f);
        updateAssignmentReferences(cache);
    }
}

fn makeClone(cache: obj.SchemeObject, cache_ret: *obj.SchemeObject) isize {
    if (abi.gcNeededP(cache_size)) {
        abi.requestGc(cache_size);
        return abi.prim_interrupt;
    }
    cache_ret.* = makeCacheClone(cache);
    return abi.prim_done;
}

fn makeCacheReference(
    block: obj.SchemeObject,
    offset: usize,
    ref_ret: *obj.SchemeObject,
) isize {
    if (abi.gcNeededP(2)) {
        abi.requestGc(2);
        return abi.prim_interrupt;
    }
    const free = abi.Free;
    free[0] = block;
    free[1] = obj.longToUnsignedFixnum(@intCast(offset));
    abi.Free = free + 2;
    ref_ret.* = obj.makePointerObject(obj.tc_weak_cons, free);
    return abi.prim_done;
}

test "lookup global, procedure frame, extension growth, linking, and compiler caches" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    // Set fixed_objects[NON_OBJECT] = unassigned_object and obarray
    const fixobj = abi.make_vector(abi.fixobj_gc_reclaimed + 1, obj.sharp_f, false);
    obj.vectorSet(fixobj, abi.fixobj_non_object, obj.unassigned_object);
    obj.vectorSet(fixobj, abi.fixobj_obarray, abi.make_vector(7, obj.empty_list, false));
    abi.fixed_objects = fixobj;

    const x_sym = intern.char_pointer_to_symbol("x");
    const y_sym = intern.char_pointer_to_symbol("y");

    var val: obj.SchemeObject = undefined;
    try std.testing.expectEqual(abi.err_unbound_variable, lookup_variable(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(abi.prim_done, variable_unbound_p(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(obj.sharp_t, val);

    // Global define, assign, unassigned mapping, unbind
    try std.testing.expectEqual(abi.prim_done, define_variable(obj.the_global_env, x_sym, obj.unassigned_object));
    try std.testing.expectEqual(abi.err_unassigned_variable, lookup_variable(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(abi.prim_done, variable_unassigned_p(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(obj.sharp_t, val);
    try std.testing.expectEqual(abi.prim_done, safe_lookup_variable(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(obj.unassigned_object, val);

    try std.testing.expectEqual(abi.prim_done, assign_variable(obj.the_global_env, x_sym, obj.ulongToFixnum(42), &val));
    try std.testing.expectEqual(obj.unassigned_object, val);
    try std.testing.expectEqual(abi.prim_done, lookup_variable(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(obj.ulongToFixnum(42), val);

    try std.testing.expectEqual(abi.prim_done, unbind_variable(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(obj.sharp_t, val);
    try std.testing.expectEqual(abi.err_unbound_variable, lookup_variable(obj.the_global_env, x_sym, &val));

    // Build a procedure frame with parameter `y` and test extension + shadowing + link
    const names = abi.make_vector(2, obj.sharp_f, false);
    obj.vectorSet(names, 0, obj.sharp_f); // procedure self-name
    obj.vectorSet(names, 1, y_sym);
    const lambda_addr = abi.Free;
    lambda_addr[0] = obj.sharp_f;
    lambda_addr[1] = names;
    abi.Free = lambda_addr + 2;
    const lambda = obj.makePointerObject(obj.tc_pair, lambda_addr);

    const proc_addr = abi.Free;
    proc_addr[0] = lambda;
    proc_addr[1] = obj.the_global_env;
    abi.Free = proc_addr + 2;
    const proc = obj.makePointerObject(obj.tc_procedure, proc_addr);

    const env_addr = abi.Free;
    env_addr[0] = obj.makeVectorHeader(2);
    env_addr[1] = proc;
    env_addr[2] = obj.ulongToFixnum(10);
    abi.Free = env_addr + 3;
    const proc_env = obj.makePointerObject(obj.tc_environment, env_addr);

    try std.testing.expectEqual(abi.prim_done, lookup_variable(proc_env, y_sym, &val));
    try std.testing.expectEqual(obj.ulongToFixnum(10), val);

    // Extending frame with `x` works and unbinding falls back cleanly
    try std.testing.expectEqual(abi.prim_done, define_variable(proc_env, x_sym, obj.ulongToFixnum(20)));
    try std.testing.expect(obj.extendedFrameP(proc_env));
    try std.testing.expectEqual(abi.prim_done, lookup_variable(proc_env, x_sym, &val));
    try std.testing.expectEqual(obj.ulongToFixnum(20), val);

    // Linking global `x` to `proc_env`'s `y` shares the value cell via compiler cache
    try std.testing.expectEqual(abi.prim_done, link_variables(obj.the_global_env, x_sym, proc_env, y_sym));
    try std.testing.expectEqual(abi.prim_done, lookup_variable(obj.the_global_env, x_sym, &val));
    try std.testing.expectEqual(obj.ulongToFixnum(10), val);
    try std.testing.expectEqual(abi.prim_done, assign_variable(obj.the_global_env, x_sym, obj.ulongToFixnum(77), &val));
    try std.testing.expectEqual(abi.prim_done, lookup_variable(proc_env, y_sym, &val));
    try std.testing.expectEqual(obj.ulongToFixnum(77), val);

    // Compiled cache references + clone creation when both assignment and operator refs exist
    if (build_options.cc_support) {
        const block_addr = abi.Free;
        block_addr[0] = obj.makeVectorHeader(3);
        block_addr[1] = obj.makeNmvHeader(0);
        block_addr[2] = obj.sharp_f;
        block_addr[3] = proc_env;
        abi.Free = block_addr + 4;
        const cc_block = obj.makeCcBlock(block_addr);

        try std.testing.expectEqual(abi.prim_done, compilerCacheAssignment(y_sym, cc_block, 1));
        try std.testing.expectEqual(abi.prim_done, compilerCacheOperator(y_sym, cc_block, 2));
        const cache = obj.ptrRefTrapCache(env_addr[2]);
        try std.testing.expect(obj.cacheClone(cache) != obj.sharp_f);
        try std.testing.expect(stubs.mock_write_var_cache_calls >= 2);
        try std.testing.expect(stubs.mock_make_uuo_link_calls >= 1);
    }
}
