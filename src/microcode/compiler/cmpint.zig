// Derived from MIT/GNU Scheme C sources (`src/microcode/cmpint.c`, `src/microcode/cmpint.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const outf = @import("../support/outf.zig");

pub const compiler_interface_version_value: c_uint = 4;

const insn_size: usize = switch (build_options.compiler_processor_type) {
    abi.compiler_aarch64_type => 4,
    abi.compiler_x86_64_type, abi.compiler_svm_type => 1,
    else => 1,
};

const cc_entry_padding_size: usize = switch (build_options.compiler_processor_type) {
    abi.compiler_aarch64_type => 1,
    else => 0,
};

const cc_entry_header_size: usize = switch (build_options.compiler_processor_type) {
    abi.compiler_aarch64_type => 3,
    abi.compiler_x86_64_type => 12,
    abi.compiler_svm_type => 4,
    else => 0,
};

const cc_entry_gc_trap_size: usize = switch (build_options.compiler_processor_type) {
    abi.compiler_x86_64_type => 6,
    else => 0,
};

const uuo_link_size: usize = switch (build_options.compiler_processor_type) {
    abi.compiler_svm_type => 2,
    else => 4,
};

const have_trampoline_to_interface: bool =
    build_options.compiler_processor_type == abi.compiler_aarch64_type;

const has_flush_icache_region: bool =
    build_options.compiler_processor_type == abi.compiler_aarch64_type;

const compiler_utilities_n_entries: usize = if (have_trampoline_to_interface) 3 else 2;

const tc_trampoline_header: usize = obj.tc_fixnum;
const trampoline_table_size: usize = 4;

const trampoline_arity_table = [trampoline_table_size * trampoline_table_size]u8{
    abi.trampoline_k_1_0,
    abi.trampoline_k_apply,
    abi.trampoline_k_apply,
    abi.trampoline_k_apply,
    abi.trampoline_k_2_0,
    abi.trampoline_k_2_1,
    abi.trampoline_k_apply,
    abi.trampoline_k_apply,
    abi.trampoline_k_3_0,
    abi.trampoline_k_3_1,
    abi.trampoline_k_3_2,
    abi.trampoline_k_apply,
    abi.trampoline_k_4_0,
    abi.trampoline_k_4_1,
    abi.trampoline_k_4_2,
    abi.trampoline_k_4_3,
};

const reflect_code_internal_apply: usize = 0;
const reflect_code_restore_interrupt_mask: usize = 1;
const reflect_code_stack_marker: usize = 2;
const reflect_code_cc_bkpt: usize = 3;
const reflect_code_compiled_invocation: usize = 8;
const reflect_code_limit: usize = 9;

pub const UtilityResult = if (build_options.cc_is_svm) extern struct {
    scheme_p: bool,
    arg: extern union {
        interpreter_code: isize,
        new_pc: ?*anyopaque,
    },
} else extern struct {
    interface_dispatch: ?*const anyopaque,
    extra: extern union {
        code_to_interpreter: isize,
        compiled_code: extern struct {
            ptr: ?*anyopaque,
            pc: ?*anyopaque,
        },
    },
};

comptime {
    if (build_options.cc_is_svm) {
        std.debug.assert(@sizeOf(UtilityResult) == 16);
    } else if (build_options.cc_support) {
        std.debug.assert(@sizeOf(UtilityResult) == 24);
    }
}

pub const UtilityProc = *const fn (*UtilityResult, usize, usize, usize, usize) callconv(.c) void;

const NativeInterface = struct {
    extern "c" fn interface_to_C() void;
    extern "c" fn interface_to_scheme() void;
    extern "c" fn interface_to_scheme_return() void;
    extern "c" fn C_to_interface(?*anyopaque, ?*anyopaque) isize;
};

const SvmInterface = struct {
    extern "c" fn C_to_interface(?*anyopaque) isize;
};

const LinkCcState = struct {
    block_address: [*]obj.SchemeObject,
    scan: [*]obj.SchemeObject,
    n_sections: usize,
    return_address: ?*anyopaque,
    n_linked_sections: usize,
    scan0: [*]obj.SchemeObject,
    type: abi.LinkageSectionType,
    n_entries: usize,
    n_linked_entries: usize,
};

var registers_storage: [abi.regblock_length]obj.SchemeObject = @splat(0);
var compiler_processor_type_storage: c_uint = build_options.compiler_processor_type;
var compiler_interface_version_storage: c_uint = compiler_interface_version_value;
var compiler_utilities_storage: obj.SchemeObject = obj.sharp_f;
var return_to_interpreter_storage: obj.SchemeObject = obj.sharp_f;
var reflect_to_interface_storage: obj.SchemeObject = obj.sharp_f;
var trampoline_to_interface: ?*anyopaque = null;
var linking_cc_block_p: bool = false;

var n_builtins: c_uint = 0;
var s_builtins: c_uint = 0;
var builtins: ?[*]usize = null;
var builtin_names: ?[*][*:0]const u8 = null;

pub var utility_table = [62]?UtilityProc{
    comutilReturnToInterpreter, // 0x00
    comutilOperatorApplyTrap, // 0x01
    comutilOperatorApplyTrap, // 0x02
    comutilOperatorApplyTrap, // 0x03
    comutilOperatorApplyTrap, // 0x04
    comutilOperatorLexprTrap, // 0x05
    comutilOperatorPrimitiveTrap, // 0x06
    comutilOperatorLookupTrap, // 0x07
    comutilOperator10Trap, // 0x08
    comutilOperator21Trap, // 0x09
    comutilOperator20Trap, // 0x0a
    comutilOperator32Trap, // 0x0b
    comutilOperator31Trap, // 0x0c
    comutilOperator30Trap, // 0x0d
    comutilOperator43Trap, // 0x0e
    comutilOperator42Trap, // 0x0f
    comutilOperator41Trap, // 0x10
    comutilOperator40Trap, // 0x11
    comutilPrimitiveApply, // 0x12
    comutilPrimitiveLexprApply, // 0x13
    comutilApply, // 0x14
    comutilError, // 0x15
    comutilLexprApply, // 0x16
    comutilLink, // 0x17
    comutilInterruptClosure, // 0x18
    comutilInterruptDlink, // 0x19
    comutilInterruptProcedure, // 0x1a
    comutilInterruptContinuation, // 0x1b
    comutilInterruptIcProcedure, // 0x1c
    comutilAssignmentTrap, // 0x1d
    comutilCacheLookupApply, // 0x1e
    comutilLookupTrap, // 0x1f
    comutilSafeLookupTrap, // 0x20
    comutilUnassignedPTrap, // 0x21
    comutilDecrement, // 0x22
    comutilDivide, // 0x23
    comutilEqual, // 0x24
    comutilGreater, // 0x25
    comutilIncrement, // 0x26
    comutilLess, // 0x27
    comutilMinus, // 0x28
    comutilMultiply, // 0x29
    comutilNegative, // 0x2a
    comutilPlus, // 0x2b
    comutilPositive, // 0x2c
    comutilZero, // 0x2d
    null, // 0x2e
    null, // 0x2f
    null, // 0x30
    null, // 0x31
    null, // 0x32
    null, // 0x33
    null, // 0x34
    null, // 0x35
    comutilPrimitiveError, // 0x36
    comutilQuotient, // 0x37
    comutilRemainder, // 0x38
    comutilModulo, // 0x39
    comutilReflectToInterface, // 0x3a
    comutilInterruptContinuation2, // 0x3b
    comutilCompiledCodeBkpt, // 0x3c
    comutilCompiledClosureBkpt, // 0x3d
};

var max_trampoline_storage: usize = utility_table.len;

inline fn loadRawGlobalPtr(ptr_to_global: anytype) usize {
    return @intFromPtr(@as(*const ?*const anyopaque, @ptrCast(ptr_to_global)).*);
}

inline fn readUnalignedI64(addr: usize) i64 {
    return @as(*align(1) const i64, @ptrFromInt(addr)).*;
}

inline fn ptrAddBytes(p: *anyopaque, byte_offset: usize) *anyopaque {
    return @ptrFromInt(@intFromPtr(p) + byte_offset);
}

inline fn ptrSubBytes(p: *anyopaque, byte_offset: usize) *anyopaque {
    return @ptrFromInt(@intFromPtr(p) - byte_offset);
}

inline fn insnDiff(hi: *const anyopaque, lo: *const anyopaque) usize {
    return @intCast((@intFromPtr(hi) - @intFromPtr(lo)) / insn_size);
}

inline fn makeCcBlock(addr: [*]const obj.SchemeObject) obj.SchemeObject {
    return obj.makePointerObject(obj.tc_compiled_code_block, addr);
}

inline fn makeCcStackEnv(addr: [*]const obj.SchemeObject) obj.SchemeObject {
    return obj.makePointerObject(obj.tc_stack_environment, addr);
}

inline fn ccBlockAddrLength(addr: [*]const obj.SchemeObject) usize {
    return obj.objectDatum(addr[0]) + 1;
}

inline fn ccBlockAddrEnd(addr: [*]obj.SchemeObject) [*]obj.SchemeObject {
    return addr + @as(usize, @intCast(ccBlockAddrLength(addr)));
}

inline fn ccEntryP(o: obj.SchemeObject) bool {
    return obj.objectType(o) == obj.tc_compiled_entry;
}

inline fn ccReturnP(o: obj.SchemeObject) bool {
    return obj.objectType(o) == obj.tc_compiled_return;
}

inline fn ccBlockP(o: obj.SchemeObject) bool {
    return obj.objectType(o) == obj.tc_compiled_code_block;
}

inline fn ccStackEnvP(o: obj.SchemeObject) bool {
    return obj.objectType(o) == obj.tc_stack_environment;
}

inline fn ccEntryAddress(o: obj.SchemeObject) *anyopaque {
    std.debug.assert(ccEntryP(o));
    return obj.objectRawAddress(o).?;
}

inline fn makeCcEntry(addr: *const anyopaque) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(@intFromPtr(addr)));
}

inline fn ccReturnAddress(o: obj.SchemeObject) *anyopaque {
    std.debug.assert(ccReturnP(o));
    return obj.objectRawAddress(o).?;
}

inline fn makeCcReturn(addr: *const anyopaque) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_return, obj.rawAddressToDatum(@intFromPtr(addr)));
}

inline fn ccEntryToAddress(o: obj.SchemeObject) ?*anyopaque {
    if (ccEntryP(o)) return ccEntryAddress(o);
    if (ccReturnP(o)) return ccReturnAddressToEntryAddressPtr(ccReturnAddress(o));
    return null;
}

inline fn ccEntryAddressPc(ep: *anyopaque) ?*anyopaque {
    if (build_options.cc_is_svm) return null;
    const off: isize = @intCast(readUnalignedI64(@intFromPtr(ep) - @sizeOf(i64)));
    const base: isize = @bitCast(@intFromPtr(ep));
    return @ptrFromInt(@as(usize, @bitCast(base +% off)));
}

inline fn ccReturnAddressPc(_: *anyopaque) ?*anyopaque {
    if (build_options.cc_is_svm) return null;
    return @ptrCast(@constCast(&NativeInterface.interface_to_scheme_return));
}

inline fn ccReturnAddressToEntryAddressPtr(r: *anyopaque) *anyopaque {
    if (build_options.cc_is_svm) return r;
    return abi.cc_return_address_to_entry_address(r).?;
}

inline fn returnToC(dsu_result: *UtilityResult, code: isize) void {
    if (build_options.cc_is_svm) {
        dsu_result.scheme_p = false;
        dsu_result.arg = .{ .interpreter_code = code };
    } else {
        dsu_result.interface_dispatch = @ptrCast(&NativeInterface.interface_to_C);
        dsu_result.extra = .{ .code_to_interpreter = code };
    }
}

inline fn returnToSchemeEntry(dsu_result: *UtilityResult, ep: *anyopaque) void {
    if (build_options.cc_is_svm) {
        dsu_result.scheme_p = true;
        dsu_result.arg = .{ .new_pc = ep };
    } else {
        dsu_result.interface_dispatch = @ptrCast(&NativeInterface.interface_to_scheme);
        dsu_result.extra = .{ .compiled_code = .{
            .ptr = ep,
            .pc = ccEntryAddressPc(ep),
        } };
    }
}

inline fn returnToSchemeContinuation(dsu_result: *UtilityResult, c: *anyopaque) void {
    if (build_options.cc_is_svm) {
        dsu_result.scheme_p = true;
        dsu_result.arg = .{ .new_pc = c };
    } else {
        dsu_result.interface_dispatch = @ptrCast(&NativeInterface.interface_to_scheme);
        dsu_result.extra = .{ .compiled_code = .{
            .ptr = c,
            .pc = ccReturnAddressPc(c),
        } };
    }
}

inline fn enterSchemeEntry(ep: *anyopaque) isize {
    if (build_options.cc_is_svm) {
        return SvmInterface.C_to_interface(ep);
    }
    return NativeInterface.C_to_interface(ep, ccEntryAddressPc(ep));
}

inline fn enterSchemeContinuation(c: *anyopaque) isize {
    if (build_options.cc_is_svm) {
        return SvmInterface.C_to_interface(c);
    }
    return NativeInterface.C_to_interface(c, ccReturnAddressPc(c));
}

inline fn pushReflection(code: usize) void {
    abi.stackPush(obj.ulongToFixnum(code));
    abi.stackPush(abi.reflect_to_interface);
}

inline fn rePushCont() void {
    abi.stackPush(abi.Registers[abi.regblock_expr]);
    abi.stackPush(abi.Registers[abi.regblock_return]);
}

inline fn primitiveArity(prim: obj.SchemeObject) c_int {
    return abi.Primitive_Arity_Table.?[@intCast(obj.primitiveNumber(prim))];
}

inline fn primitiveImplementedP(prim: obj.SchemeObject) bool {
    return abi.Primitive_Procedure_Table.?[@intCast(obj.primitiveNumber(prim))] != &abi.Prim_unimplemented;
}

inline fn checkLastReturnCode() void {
    const lrc = abi.last_return_code.?;
    std.debug.assert(@intFromPtr(lrc) > @intFromPtr(abi.stack_start));
    std.debug.assert(@intFromPtr(lrc) <= @intFromPtr(abi.stack_end));
    if (@intFromPtr(lrc) < @intFromPtr(abi.stack_end)) {
        std.debug.assert(obj.returnCodeP(lrc[0]));
    }
}

inline fn saveLastReturnCode(code: usize) void {
    checkLastReturnCode();
    const offset: usize = @intCast((@intFromPtr(abi.last_return_code.?) - @intFromPtr(abi.stack_pointer)) / @sizeOf(obj.SchemeObject));
    std.debug.assert(offset > 0);
    abi.pushCont(code, obj.ulongToFixnum(offset + abi.cont_size));
    abi.compiler_new_subproblem();
}

inline fn restoreLastReturnCode() void {
    const exp_val = abi.Registers[abi.regblock_expr];
    abi.last_return_code = abi.stackLoc(@intCast(obj.fixnumToUlong(exp_val) - abi.cont_size));
    checkLastReturnCode();
    abi.end_subproblem();
}

inline fn asmResetHook() void {
    switch (build_options.compiler_processor_type) {
        abi.compiler_aarch64_type => abi.aarch64_reset_hook(),
        abi.compiler_x86_64_type => abi.x86_64_reset_hook(),
        abi.compiler_svm_type => abi.initialize_svm1(),
        else => {},
    }
}

pub fn compilerInitialize(fasl_p: bool) callconv(.c) void {
    abi.Registers[abi.regblock_primitive] = obj.sharp_f;
    abi.compiler_processor_type = build_options.compiler_processor_type;
    abi.compiler_interface_version = compiler_interface_version_value;
    if (fasl_p) {
        compilerReset(makeCompilerUtilities());
    } else {
        abi.compiler_utilities = obj.sharp_f;
        abi.return_to_interpreter = obj.sharp_f;
        if (comptime have_trampoline_to_interface) {
            trampoline_to_interface = null;
        }
    }
}

fn makeCompilerUtilities() obj.SchemeObject {
    var h1: obj.SchemeObject = 0;
    var h2: obj.SchemeObject = 0;
    var n_words: usize = 0;

    makeTrampolineHeaders(compiler_utilities_n_entries, 2, &h1, &h2, &n_words);
    h1 = obj.objectNewType(obj.tc_manifest_vector, h1);

    const block = abi.code_arena_alloc(n_words) orelse {
        outf.fatal("Can't allocate compiler_utilities.\n", .{});
        abi.Microcode_Termination(abi.term_no_space);
    };

    const write_scope = abi.code_arena_write_scope_begin();
    const block_slice = block[0..@intCast(n_words)];
    @memset(block_slice, 0);
    block[0] = h1;
    block[1] = h2;

    var cet: abi.CcEntryType = undefined;
    makeCcEntryType(&cet, .return_to_interpreter);
    if (fillTrampoline(block, 0, &cet, abi.trampoline_k_return_to_interpreter) or
        fillTrampoline(block, 1, &cet, abi.trampoline_k_reflect_to_interface))
    {
        outf.fatal("\nError in make_compiler_utilities\n", .{});
        abi.Microcode_Termination(abi.term_compiler_death);
    }

    if (comptime have_trampoline_to_interface) {
        makeCcEntryType(&cet, .trampoline);
        const addr = abi.trampoline_entry_addr(block, 2).?;
        var ceo = abi.CcEntryOffset{
            .offset = insnDiff(addr, block),
            .continued_p = false,
        };
        if (abi.write_cc_entry_type(&cet, addr) or
            abi.write_cc_entry_offset(&ceo, addr) or
            abi.store_trampoline_to_interface_insns(addr))
        {
            outf.fatal("\nError in make_compiler_utilities\n", .{});
            abi.Microcode_Termination(abi.term_compiler_death);
        }
    }

    const store = trampolineStorage(block);
    store[0] = insnDiff(abi.trampoline_entry_addr(block, 0).?, block);
    store[1] = insnDiff(abi.trampoline_entry_addr(block, 1).?, block);

    abi.code_arena_write_scope_end(write_scope);
    abi.jit_flush_icache(@ptrCast(block), @as(usize, @intCast(n_words)) * @sizeOf(obj.SchemeObject));
    return makeCcBlock(block);
}

pub fn compilerReset(new_block: obj.SchemeObject) callconv(.c) void {
    var h1: obj.SchemeObject = 0;
    var h2: obj.SchemeObject = 0;
    var n_words: usize = 0;

    makeTrampolineHeaders(compiler_utilities_n_entries, 2, &h1, &h2, &n_words);
    h1 = obj.objectNewType(obj.tc_manifest_vector, h1);
    if (!(ccBlockP(new_block) and
        obj.memoryRef(new_block, 0) == h1 and
        obj.memoryRef(new_block, 1) == h2))
    {
        outf.fatal("\nThe world image being restored is incompatible with this microcode.\n", .{});
        abi.Microcode_Termination(abi.term_compiler_death);
    }

    const nbp = obj.objectAddress(new_block);
    abi.compiler_utilities = new_block;
    abi.return_to_interpreter = makeCcReturn(abi.trampoline_return_addr(nbp, 0).?);
    abi.reflect_to_interface = makeCcReturn(abi.trampoline_return_addr(nbp, 1).?);
    if (comptime have_trampoline_to_interface) {
        trampoline_to_interface = abi.trampoline_entry_addr(nbp, 2);
    }
    abi.Registers[abi.regblock_closure_free] = 0;
    abi.Registers[abi.regblock_closure_space] = 0;
    abi.Registers[abi.regblock_reflect_to_interface] = abi.reflect_to_interface;
    asmResetHook();
}

pub fn enterCompiledExpression() callconv(.c) isize {
    const entry = abi.Registers[abi.regblock_expr];
    var cet: abi.CcEntryType = undefined;
    if (abi.read_cc_entry_type(&cet, ccEntryAddress(entry))) {
        return abi.err_compiled_code_error;
    }
    if (cet.marker != .expression) {
        abi.Registers[abi.regblock_val] = entry;
        return abi.prim_done;
    }
    guaranteeCcReturn(0);
    return enterSchemeEntry(ccEntryAddress(entry));
}

pub fn applyCompiledProcedure() callconv(.c) isize {
    const n_args = abi.applyFrameHeaderNArgs(abi.stackPop());
    const procedure = abi.stackPop();
    const code = setupCompiledInvocation(procedure, n_args);
    if (code != abi.prim_done) return code;
    return enterSchemeEntry(ccEntryAddress(procedure));
}

fn compiledContinuationP(entry_addr: *anyopaque) bool {
    var cet: abi.CcEntryType = undefined;
    if (abi.read_cc_entry_type(&cet, entry_addr)) return false;
    return cet.marker == .continuation or
        cet.marker == .internal_continuation or
        cet.marker == .return_to_interpreter;
}

pub fn ccReturnAddressP(object: obj.SchemeObject) callconv(.c) bool {
    const addr = ccEntryToAddress(object) orelse return false;
    return compiledContinuationP(addr);
}

pub fn returnToCompiledCode() callconv(.c) isize {
    restoreLastReturnCode();
    const cont = abi.stackPop();
    if (ccReturnP(cont)) {
        const ret_addr = ccReturnAddress(cont);
        const entry_addr = ccReturnAddressToEntryAddressPtr(ret_addr);
        if (compiledContinuationP(entry_addr)) {
            return enterSchemeContinuation(ret_addr);
        }
    } else if (ccEntryP(cont)) {
        const entry_addr = ccEntryAddress(cont);
        if (compiledContinuationP(entry_addr)) {
            return enterSchemeEntry(entry_addr);
        }
    }
    abi.stackPush(cont);
    rePushCont();
    return abi.err_inapplicable_object;
}

pub fn guaranteeCcReturn(offset: usize) callconv(.c) void {
    const off_u: usize = @intCast(offset);
    const frame = abi.stackLoc(off_u);
    const ret = abi.contFrameRet(frame);
    if (ccReturnP(ret)) return;
    std.debug.assert(obj.returnCodeP(ret));
    if (obj.objectDatum(ret) == abi.rc_reenter_compiled_code) {
        const lrc: usize = @intCast(obj.fixnumToUlong(abi.contFrameExp(frame)) - abi.cont_size);
        closeStackGap(off_u, abi.cont_size);
        abi.last_return_code = abi.stackLoc(off_u + lrc);
        checkLastReturnCode();
        abi.end_subproblem();
    } else {
        abi.last_return_code = frame;
        checkLastReturnCode();
        openStackGap(off_u, 1);
        abi.stack_pointer[off_u] = abi.return_to_interpreter;
    }
}

pub fn guaranteeInterpReturn() callconv(.c) void {
    const offset: usize = 1 + @as(usize, @intCast(obj.objectDatum(abi.stack_pointer[0])));
    const frame = abi.stackLoc(offset);
    if (obj.returnCodeP(abi.contFrameRet(frame))) return;
    std.debug.assert(ccReturnP(abi.contFrameRet(frame)));
    if (abi.contFrameRet(frame) == abi.return_to_interpreter) {
        std.debug.assert(obj.returnCodeP(abi.contFrameRet(abi.stackLoc(offset + 1))));
        closeStackGap(offset, 1);
        abi.compiler_new_reduction();
    } else {
        openStackGap(offset, abi.cont_size);
        const sp = abi.stack_pointer;
        abi.stack_pointer = abi.stackLoc(offset + abi.cont_size);
        saveLastReturnCode(abi.rc_reenter_compiled_code);
        abi.stack_pointer = sp;
    }
}

fn openStackGap(offset: usize, n_words: usize) void {
    const sp = abi.stack_pointer;
    const dst = sp - n_words;
    for (0..offset) |i| {
        dst[i] = sp[i];
    }
    abi.stack_pointer = dst;
}

fn closeStackGap(offset: usize, n_words: usize) void {
    const sp = abi.stack_pointer;
    var i: usize = offset;
    while (i > 0) {
        i -= 1;
        sp[i + n_words] = sp[i];
    }
    abi.stack_pointer = sp + n_words;
}

fn recoverFromApplyError(procedure: obj.SchemeObject, n_args: usize) void {
    abi.stackPush(procedure);
    abi.stackPush(abi.makeApplyFrameHeader(n_args + 1));
    guaranteeInterpReturn();
}

inline fn invokeReturnAddress(dsu_result: *UtilityResult) void {
    if (@intFromPtr(abi.Free) >= abi.Registers[abi.regblock_memtop]) {
        compilerInterruptReturnToEntry();
        compilerInterruptCommon(dsu_result, null, abi.Registers[abi.regblock_val]);
        return;
    }
    std.debug.assert(ccReturnP(abi.stackRef(0)));
    returnToSchemeContinuation(dsu_result, ccReturnAddress(abi.stackPop()));
}

pub fn comutilApply(
    dsu_result: *UtilityResult,
    procedure_raw: usize,
    frame_size_raw: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    var procedure: obj.SchemeObject = @intCast(procedure_raw);
    var frame_size: usize = frame_size_raw;

    while (true) {
        switch (obj.objectType(procedure)) {
            obj.tc_entity => {
                const data = obj.entityData(procedure);
                if (obj.vectorP(data) and
                    obj.vectorLength(data) > frame_size and
                    obj.vectorRef(data, 0) == obj.vectorRef(abi.fixed_objects, abi.fixobj_arity_dispatcher_tag) and
                    obj.vectorRef(data, @intCast(frame_size)) != obj.sharp_f)
                {
                    procedure = obj.vectorRef(data, @intCast(frame_size));
                    continue;
                }
                const operator = obj.entityOperator(procedure);
                if (!ccEntryP(operator)) {
                    recoverFromApplyError(procedure, frame_size - 1);
                    returnToC(dsu_result, abi.prim_apply);
                    return;
                }
                abi.stackPush(procedure);
                procedure = operator;
                frame_size += 1;
                const code = setupCompiledInvocation(procedure, frame_size - 1);
                if (code != abi.prim_done) {
                    returnToC(dsu_result, code);
                    return;
                }
                returnToSchemeEntry(dsu_result, ccEntryAddress(procedure));
                return;
            },
            obj.tc_record => {
                const applicator = abi.record_applicator(procedure);
                if (!ccEntryP(applicator)) {
                    recoverFromApplyError(procedure, frame_size - 1);
                    returnToC(dsu_result, abi.prim_apply);
                    return;
                }
                abi.stackPush(procedure);
                procedure = applicator;
                frame_size += 1;
                const code = setupCompiledInvocation(procedure, frame_size - 1);
                if (code != abi.prim_done) {
                    returnToC(dsu_result, code);
                    return;
                }
                returnToSchemeEntry(dsu_result, ccEntryAddress(procedure));
                return;
            },
            obj.tc_compiled_entry => {
                const code = setupCompiledInvocation(procedure, frame_size - 1);
                if (code != abi.prim_done) {
                    returnToC(dsu_result, code);
                    return;
                }
                returnToSchemeEntry(dsu_result, ccEntryAddress(procedure));
                return;
            },
            obj.tc_primitive => {
                if (primitiveImplementedP(procedure)) {
                    const arity = primitiveArity(procedure);
                    if (arity >= 0 and @as(usize, @intCast(arity)) == (frame_size - 1)) {
                        comutilPrimitiveApply(dsu_result, @intCast(procedure), 0, 0, 0);
                        return;
                    } else if (arity == abi.lexpr_primitive_arity) {
                        abi.Registers[abi.regblock_lexpr_actuals] = frame_size - 1;
                        comutilPrimitiveLexprApply(dsu_result, @intCast(procedure), 0, 0, 0);
                        return;
                    } else {
                        recoverFromApplyError(procedure, frame_size - 1);
                        returnToC(dsu_result, abi.err_wrong_number_of_arguments);
                        return;
                    }
                }
                recoverFromApplyError(procedure, frame_size - 1);
                returnToC(dsu_result, abi.prim_apply);
                return;
            },
            else => {
                recoverFromApplyError(procedure, frame_size - 1);
                returnToC(dsu_result, abi.prim_apply);
                return;
            },
        }
    }
}

pub fn comutilLexprApply(
    dsu_result: *UtilityResult,
    address_raw: usize,
    n_args: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const address: *anyopaque = @ptrFromInt(@as(usize, @intCast(address_raw)));
    var cet: abi.CcEntryType = undefined;
    if (!(!abi.read_cc_entry_type(&cet, address) and
        cet.marker == .procedure and
        cet.args.for_procedure.rest_p and
        n_args >= cet.args.for_procedure.n_required))
    {
        recoverFromApplyError(makeCcEntry(address), n_args);
        returnToC(dsu_result, abi.err_compiled_code_error);
        return;
    }
    const code = setupLexprInvocation(
        makeCcEntry(address),
        n_args,
        @intCast(cet.args.for_procedure.n_required + cet.args.for_procedure.n_optional),
    );
    if (code != abi.prim_done) {
        returnToC(dsu_result, code);
        return;
    }
    returnToSchemeEntry(dsu_result, address);
}

pub fn comutilPrimitiveApply(
    dsu_result: *UtilityResult,
    primitive_raw: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const primitive: obj.SchemeObject = @intCast(primitive_raw);
    abi.apply_primitive_external(primitive);
    abi.popPrimitiveFrame(@intCast(primitiveArity(primitive)));
    invokeReturnAddress(dsu_result);
}

pub fn comutilPrimitiveLexprApply(
    dsu_result: *UtilityResult,
    primitive_raw: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const primitive: obj.SchemeObject = @intCast(primitive_raw);
    abi.apply_primitive_external(primitive);
    abi.popPrimitiveFrame(@intCast(abi.getLexprActuals()));
    invokeReturnAddress(dsu_result);
}

pub fn comutilError(
    dsu_result: *UtilityResult,
    frame_size: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    comutilApply(
        dsu_result,
        @intCast(obj.vectorRef(abi.fixed_objects, abi.fixobj_cc_error_procedure)),
        frame_size,
        0,
        0,
    );
}

pub fn comutilLink(
    dsu_result: *UtilityResult,
    return_addr_raw: usize,
    block_addr_raw: usize,
    constant_addr_raw: usize,
    n_sections: usize,
) callconv(.c) void {
    const block_addr: [*]obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(block_addr_raw)));
    var s = LinkCcState{
        .block_address = block_addr,
        .scan = @ptrFromInt(@as(usize, @intCast(constant_addr_raw))),
        .n_sections = n_sections,
        .return_address = @ptrFromInt(@as(usize, @intCast(return_addr_raw))),
        .n_linked_sections = 0,
        .scan0 = undefined,
        .type = undefined,
        .n_entries = 0,
        .n_linked_entries = 0,
    };

    if (abi.compiler_processor_type == abi.compiler_aarch64_type) {
        const env_slot = ccBlockAddrEnd(block_addr) - 1;
        if (abi.code_address_p(@ptrCast(block_addr))) {
            abi.code_arena_write_begin();
            env_slot[0] = abi.Registers[abi.regblock_env];
            abi.code_arena_write_end();
        } else {
            env_slot[0] = abi.Registers[abi.regblock_env];
        }
    }

    startLinkingCcBlock();
    const result = linkRemainingSections(&s);
    endLinkingCcBlock(&s);
    if (result != abi.prim_done) {
        returnToC(dsu_result, result);
        return;
    }
    returnToSchemeContinuation(dsu_result, s.return_address.?);
}

pub fn compLinkCachesRestart() callconv(.c) isize {
    var s: LinkCcState = undefined;
    restoreLinkCcState(&s);
    abi.Registers[abi.regblock_env] = ccBlockEnvironment(makeCcBlock(s.block_address));

    startLinkingCcBlock();
    var result = linkSection(&s);
    if (result == abi.prim_done) {
        result = linkRemainingSections(&s);
    }
    endLinkingCcBlock(&s);
    if (result != abi.prim_done) return result;
    return enterSchemeContinuation(s.return_address.?);
}

fn linkRemainingSections(s: *LinkCcState) isize {
    while (s.n_linked_sections < s.n_sections) {
        startLinkingSection(s);
        const result = linkSection(s);
        if (result != abi.prim_done) return result;
    }
    return abi.prim_done;
}

fn startLinkingCcBlock() void {
    const ap: *bool = @ptrCast(@alignCast(abi.dstack_alloc(@sizeOf(bool)).?));
    ap.* = linking_cc_block_p;
    abi.transaction_begin();
    abi.transaction_record_action(abi.tat_always, abortLinkingCcBlock, @ptrCast(ap));
    linking_cc_block_p = true;
}

fn endLinkingCcBlock(s: *LinkCcState) void {
    abi.transaction_commit();
    updateCacheAfterLink(s);
}

fn abortLinkingCcBlock(ap: ?*anyopaque) callconv(.c) void {
    const p: *const bool = @ptrCast(@alignCast(ap.?));
    linking_cc_block_p = p.*;
}

fn updateCacheAfterLink(s: *LinkCcState) void {
    if (comptime has_flush_icache_region) {
        const addr = s.block_address;
        _ = ccReturnAddressToBlockAddress(s.return_address.?) == addr;
        abi.aarch64_flush_i_cache_region(addr, @intCast(ccBlockAddrLength(addr)));
    }
}

fn startLinkingSection(s: *LinkCcState) void {
    s.scan0 = s.scan;
    s.n_linked_entries = 0;
    const header = s.scan[0];
    s.scan += 1;
    s.type = linkageSectionTypeEnum(header);
    s.n_entries = linkageSectionCount(header);
}

const CacheHandlerFn = *const fn (obj.SchemeObject, obj.SchemeObject, usize) callconv(.c) isize;

fn linkSectionHandler(
    sec_type: abi.LinkageSectionType,
    handler_r: *CacheHandlerFn,
    execute_p_r: *bool,
) bool {
    switch (sec_type) {
        .operator => {
            handler_r.* = abi.compiler_cache_operator;
            execute_p_r.* = true;
            return true;
        },
        .global_operator => {
            handler_r.* = abi.compiler_cache_global_operator;
            execute_p_r.* = true;
            return true;
        },
        .reference => {
            handler_r.* = abi.compiler_cache_lookup;
            execute_p_r.* = false;
            return true;
        },
        .assignment => {
            handler_r.* = abi.compiler_cache_assignment;
            execute_p_r.* = false;
            return true;
        },
    }
}

fn linkSection(s: *LinkCcState) isize {
    const scan1 = s.scan0 + 1;
    var scan = s.scan;
    const block_address = s.block_address;
    var n_linked = s.n_linked_entries;
    const n_entries = s.n_entries;
    var handler: CacheHandlerFn = undefined;
    var execute_p: bool = false;
    var result: isize = abi.prim_done;

    if (!linkSectionHandler(s.type, &handler, &execute_p)) {
        result = abi.err_compiled_code_error;
    } else {
        const entry_size: usize = if (execute_p) uuo_link_size else 1;
        while (n_linked < n_entries) {
            const sym = if (execute_p) abi.read_uuo_symbol(scan) else scan[0];
            const offset: usize = @intCast((@intFromPtr(scan) - @intFromPtr(block_address)) / @sizeOf(obj.SchemeObject));
            result = handler(sym, makeCcBlock(block_address), offset);
            if (result != abi.prim_done) break;
            scan += entry_size;
            n_linked += 1;
        }
    }

    s.scan = if (n_linked == 0) scan1 else scan;
    s.n_linked_entries = n_linked;
    const marker = makeLinkageSectionMarker(s.type, n_linked);
    if (abi.code_address_p(@ptrCast(block_address))) {
        abi.code_arena_write_begin();
        s.scan0[0] = marker;
        abi.code_arena_write_end();
    } else {
        s.scan0[0] = marker;
    }
    if (result == abi.prim_done) {
        s.n_linked_sections += 1;
    } else {
        backOutOfLinkSection(s);
    }
    return result;
}

fn backOutOfLinkSection(s: *LinkCcState) void {
    abi.stackPush(makeCcReturn(s.return_address.?));
    abi.stackPush(obj.ulongToFixnum(s.n_sections - s.n_linked_sections));
    abi.stackPush(obj.ulongToFixnum(@intCast((@intFromPtr(s.scan0) - @intFromPtr(s.block_address)) / @sizeOf(obj.SchemeObject))));
    abi.stackPush(obj.ulongToFixnum(@intCast((@intFromPtr(s.scan) - @intFromPtr(s.block_address)) / @sizeOf(obj.SchemeObject))));
    abi.stackPush(makeCcBlock(s.block_address));
    abi.stackPush(obj.ulongToFixnum(s.n_entries - s.n_linked_entries));
    abi.stackPush(obj.ulongToFixnum(s.n_entries));
    saveLastReturnCode(abi.rc_comp_link_caches_restart);
}

fn restoreLinkCcState(s: *LinkCcState) void {
    restoreLastReturnCode();
    s.n_entries = obj.objectDatum(abi.stackPop());
    s.n_linked_entries = s.n_entries - obj.objectDatum(abi.stackPop());
    s.block_address = obj.objectAddress(abi.stackPop());
    s.scan = s.block_address + @as(usize, @intCast(obj.objectDatum(abi.stackPop())));
    s.scan0 = s.block_address + @as(usize, @intCast(obj.objectDatum(abi.stackPop())));
    s.n_sections = obj.objectDatum(abi.stackPop());
    s.return_address = ccReturnAddress(abi.stackPop());
    s.n_linked_sections = 0;
    s.type = linkageSectionTypeEnum(s.scan0[0]);
}

pub fn ccBlockLinkageInfo(block: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const header_ptr = obj.vectorLoc(block, 0);
    const const_offset: usize = 1 + @as(usize, @intCast(obj.vectorLength(obj.makePointerObject(obj.tc_vector, header_ptr))));
    const const_addr = obj.vectorLoc(block, const_offset);
    const block_end = obj.memoryLoc(block, @intCast(ccBlockAddrLength(obj.objectAddress(block))));
    var n_sections: usize = 0;
    var n_words: usize = 0;

    countLinkageSections(const_addr, block_end, &n_sections, &n_words);
    abi.primitiveGcIfNeeded(n_words);
    return readLinkageSections(const_addr, block_end, n_sections, n_words);
}

fn unlinkedSectionStartP(mp: [*]const obj.SchemeObject, end: [*]const obj.SchemeObject) bool {
    const marker = mp[0];
    return obj.fixnumP(marker) and
        (obj.objectDatum(marker) >> 16) < 4 and
        (@intFromPtr(mp) + (1 + @as(usize, @intCast(obj.objectDatum(marker) & 0xFFFF))) * @sizeOf(obj.SchemeObject)) < @intFromPtr(end);
}

fn sectionExecuteP(h: obj.SchemeObject) bool {
    const t = linkageSectionTypeEnum(h);
    return t == .operator or t == .global_operator;
}

fn countLinkageSections(
    const_addr: [*]const obj.SchemeObject,
    block_end: [*]const obj.SchemeObject,
    n_sections: *usize,
    n_words: *usize,
) void {
    var scan = const_addr;
    n_sections.* = 0;
    n_words.* = 1;
    while (unlinkedSectionStartP(scan, block_end)) {
        const h = scan[0];
        scan += 1;
        const count = linkageSectionCount(h);
        n_sections.* += 1;
        n_words.* += 3 + count;
        scan += @as(usize, @intCast(if (sectionExecuteP(h)) count * uuo_link_size else count));
    }
}

fn readLinkageSections(
    const_addr: [*]const obj.SchemeObject,
    _: [*]const obj.SchemeObject,
    n_sections: usize,
    _: usize,
) obj.SchemeObject {
    var scan = const_addr;
    const sections = abi.make_vector(n_sections, obj.sharp_f, false);
    var sp = obj.vectorLoc(sections, 0);
    const spe = obj.vectorLoc(sections, obj.vectorLength(sections));
    while (@intFromPtr(sp) < @intFromPtr(spe)) {
        const h = scan[0];
        scan += 1;
        const section = abi.make_vector(1 + linkageSectionCount(h), obj.sharp_f, false);
        var p = obj.vectorLoc(section, 0);
        const pe = obj.vectorLoc(section, obj.vectorLength(section));
        p[0] = obj.ulongToFixnum(linkageSectionType(h));
        p += 1;
        if (sectionExecuteP(h)) {
            while (@intFromPtr(p) < @intFromPtr(pe)) {
                p[0] = abi.read_uuo_symbol(@constCast(scan));
                p += 1;
                scan += uuo_link_size;
            }
        } else {
            while (@intFromPtr(p) < @intFromPtr(pe)) {
                p[0] = scan[0];
                p += 1;
                scan += 1;
            }
        }
        sp[0] = section;
        sp += 1;
    }
    return sections;
}

pub fn comutilInterruptClosure(
    dsu_result: *UtilityResult,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    compilerInterruptCommon(dsu_result, null, obj.sharp_f);
}

pub fn comutilInterruptDlink(
    dsu_result: *UtilityResult,
    entry_point_raw: usize,
    dlink_raw: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const entry_point: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(entry_point_raw)));
    const dlink: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(dlink_raw)));
    compilerInterruptCommon(dsu_result, entry_point, makeCcStackEnv(dlink));
}

pub fn comutilInterruptProcedure(
    dsu_result: *UtilityResult,
    entry_point_raw: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const entry_point: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(entry_point_raw)));
    compilerInterruptCommon(dsu_result, entry_point, obj.sharp_f);
}

pub fn comutilInterruptContinuation(
    dsu_result: *UtilityResult,
    entry_point_raw: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const entry_point: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(entry_point_raw)));
    compilerInterruptCommon(dsu_result, entry_point, abi.Registers[abi.regblock_val]);
}

pub fn comutilInterruptIcProcedure(
    dsu_result: *UtilityResult,
    entry_point_raw: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const entry_point: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(entry_point_raw)));
    compilerInterruptCommon(dsu_result, entry_point, abi.Registers[abi.regblock_env]);
}

pub fn comutilInterruptContinuation2(
    dsu_result: *UtilityResult,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    compilerInterruptReturnToEntry();
    compilerInterruptCommon(dsu_result, null, abi.Registers[abi.regblock_val]);
}

fn compilerInterruptReturnToEntry() void {
    const ret = abi.stackPop();
    const ret_addr = ccReturnAddress(ret);
    const entry_addr = ccReturnAddressToEntryAddressPtr(ret_addr);
    abi.stackPush(makeCcEntry(entry_addr));
}

pub fn compilerInterruptCommon(
    dsu_result: *UtilityResult,
    entry_address: ?*anyopaque,
    state: obj.SchemeObject,
) callconv(.c) void {
    if (!abi.freeOkP(abi.Free)) {
        const diff_words: usize = @intCast((@intFromPtr(abi.Free) -% @intFromPtr(abi.heap_alloc_limit)) / @sizeOf(obj.SchemeObject));
        abi.requestGc(diff_words);
    }
    abi.stackCheck(0);
    if (entry_address) |ea| {
        abi.stackPush(makeCcEntry(ea));
    } else {
        std.debug.assert(ccEntryP(abi.stackRef(0)));
    }
    abi.stackPush(state);
    saveLastReturnCode(abi.rc_comp_interrupt_restart);
    returnToC(dsu_result, abi.prim_interrupt);
}

pub fn compInterruptRestart() callconv(.c) isize {
    restoreLastReturnCode();
    const state = abi.stackPop();
    abi.Registers[abi.regblock_env] = state;
    abi.Registers[abi.regblock_val] = state;
    return enterSchemeEntry(ccEntryAddress(abi.stackPop()));
}

pub fn comutilAssignmentTrap(
    dsu_result: *UtilityResult,
    ret_addr_raw: usize,
    cache_addr_raw: usize,
    new_val_raw: usize,
    _: usize,
) callconv(.c) void {
    const ret_addr: *anyopaque = @ptrFromInt(@as(usize, @intCast(ret_addr_raw)));
    const cache_addr: [*]obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(cache_addr_raw)));
    const new_val: obj.SchemeObject = @intCast(new_val_raw);
    const cache = obj.makePointerObject(obj.tc_hunk3, cache_addr);
    var old_val: obj.SchemeObject = 0;
    const code = abi.compiler_assignment_trap(cache, new_val, &old_val);
    if (code != abi.prim_done) {
        const sra = makeCcReturn(ret_addr);
        const block = ccReturnToBlock(sra);
        abi.stackPush(sra);
        abi.stackPush(new_val);
        abi.stackPush(ccBlockEnvironment(block));
        abi.stackPush(abi.compiler_var_error(cache, block, .assignment_cache));
        saveLastReturnCode(abi.rc_comp_assignment_trap_restart);
        returnToC(dsu_result, code);
        return;
    }
    abi.Registers[abi.regblock_val] = old_val;
    returnToSchemeContinuation(dsu_result, ret_addr);
}

pub fn compAssignmentTrapRestart() callconv(.c) isize {
    restoreLastReturnCode();
    const name = abi.stackPop();
    const environment = abi.stackPop();
    const new_val = abi.stackPop();
    var old_val: obj.SchemeObject = 0;
    const code = abi.assign_variable(environment, name, new_val, &old_val);
    if (code != abi.prim_done) {
        abi.stackPush(new_val);
        abi.stackPush(environment);
        abi.stackPush(name);
        saveLastReturnCode(abi.rc_comp_assignment_trap_restart);
        return code;
    }
    abi.Registers[abi.regblock_val] = old_val;
    return enterSchemeContinuation(ccReturnAddress(abi.stackPop()));
}

pub fn comutilCacheLookupApply(
    dsu_result: *UtilityResult,
    cache_addr_raw: usize,
    block_addr_raw: usize,
    frame_size: usize,
    _: usize,
) callconv(.c) void {
    const cache_addr: [*]obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(cache_addr_raw)));
    const block_addr: [*]obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(block_addr_raw)));
    const cache = obj.makePointerObject(obj.tc_hunk3, cache_addr);
    var value: obj.SchemeObject = 0;
    const code = abi.compiler_lookup_trap(cache, &value);
    if (code != abi.prim_done) {
        const block = makeCcBlock(block_addr);
        abi.stackPush(block);
        abi.stackPush(obj.ulongToFixnum(frame_size));
        abi.stackPush(ccBlockEnvironment(block));
        abi.stackPush(abi.compiler_var_error(cache, block, .operator_cache));
        saveLastReturnCode(abi.rc_comp_cache_ref_apply_restart);
        returnToC(dsu_result, code);
        return;
    }
    comutilApply(dsu_result, @intCast(value), frame_size, 0, 0);
}

pub fn compCacheLookupApplyRestart() callconv(.c) isize {
    restoreLastReturnCode();
    const name = abi.stackPop();
    const environment = abi.stackPop();
    const frame_size = abi.stackPop();
    const block = abi.stackPop();
    var value: obj.SchemeObject = 0;
    const code = abi.lookup_variable(environment, name, &value);
    if (code != abi.prim_done) {
        abi.stackPush(block);
        abi.stackPush(frame_size);
        abi.stackPush(environment);
        abi.stackPush(name);
        saveLastReturnCode(abi.rc_comp_cache_ref_apply_restart);
        return code;
    }
    abi.stackPush(value);
    abi.stackPush(abi.makeApplyFrameHeader(obj.fixnumToUlong(frame_size)));
    if (ccEntryP(value)) return applyCompiledProcedure();
    guaranteeInterpReturn();
    return abi.prim_apply;
}

fn commonLookupTrap(
    dsu_result: *UtilityResult,
    ret_addr_raw: usize,
    cache_addr_raw: usize,
    trap_fn: *const fn (obj.SchemeObject, *obj.SchemeObject) callconv(.c) isize,
    restart_rc: usize,
) void {
    const ret_addr: *anyopaque = @ptrFromInt(@as(usize, @intCast(ret_addr_raw)));
    const cache_addr: [*]obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(cache_addr_raw)));
    const cache = obj.makePointerObject(obj.tc_hunk3, cache_addr);
    var val: obj.SchemeObject = 0;
    const code = trap_fn(cache, &val);
    if (code != abi.prim_done) {
        const sra = makeCcReturn(ret_addr);
        const block = ccReturnToBlock(sra);
        abi.stackPush(sra);
        abi.stackPush(ccBlockEnvironment(block));
        abi.stackPush(abi.compiler_var_error(cache, block, .lookup_cache));
        saveLastReturnCode(restart_rc);
        returnToC(dsu_result, code);
        return;
    }
    abi.Registers[abi.regblock_val] = val;
    returnToSchemeContinuation(dsu_result, ret_addr);
}

fn commonLookupTrapRestart(
    lookup_fn: *const fn (obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) callconv(.c) isize,
    restart_rc: usize,
) isize {
    restoreLastReturnCode();
    const name = abi.stackPop();
    const environment = abi.stackPop();
    var val: obj.SchemeObject = 0;
    const code = lookup_fn(environment, name, &val);
    if (code != abi.prim_done) {
        abi.stackPush(environment);
        abi.stackPush(name);
        saveLastReturnCode(restart_rc);
        return code;
    }
    abi.Registers[abi.regblock_val] = val;
    return enterSchemeContinuation(ccReturnAddress(abi.stackPop()));
}

pub fn comutilLookupTrap(dsu_result: *UtilityResult, ret_addr_raw: usize, cache_addr_raw: usize, _: usize, _: usize) callconv(.c) void {
    commonLookupTrap(dsu_result, ret_addr_raw, cache_addr_raw, abi.compiler_lookup_trap, abi.rc_comp_lookup_trap_restart);
}

pub fn compLookupTrapRestart() callconv(.c) isize {
    return commonLookupTrapRestart(abi.lookup_variable, abi.rc_comp_lookup_trap_restart);
}

pub fn comutilSafeLookupTrap(dsu_result: *UtilityResult, ret_addr_raw: usize, cache_addr_raw: usize, _: usize, _: usize) callconv(.c) void {
    commonLookupTrap(dsu_result, ret_addr_raw, cache_addr_raw, abi.compiler_safe_lookup_trap, abi.rc_comp_safe_ref_trap_restart);
}

pub fn compSafeLookupTrapRestart() callconv(.c) isize {
    return commonLookupTrapRestart(abi.safe_lookup_variable, abi.rc_comp_safe_ref_trap_restart);
}

pub fn comutilUnassignedPTrap(dsu_result: *UtilityResult, ret_addr_raw: usize, cache_addr_raw: usize, _: usize, _: usize) callconv(.c) void {
    commonLookupTrap(dsu_result, ret_addr_raw, cache_addr_raw, abi.compiler_unassigned_p_trap, abi.rc_comp_unassigned_trap_restart);
}

pub fn compUnassignedPTrapRestart() callconv(.c) isize {
    return commonLookupTrapRestart(abi.variable_unassigned_p, abi.rc_comp_unassigned_trap_restart);
}

fn arithTrampoline(dsu_result: *UtilityResult, fobj_index: usize, arity: usize) void {
    comutilApply(dsu_result, @intCast(obj.vectorRef(abi.fixed_objects, fobj_index)), arity, 0, 0);
}

pub fn comutilDecrement(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_predecessor, 2);
}
pub fn comutilDivide(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_divide, 3);
}
pub fn comutilEqual(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_equal_p, 3);
}
pub fn comutilGreater(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_greater_p, 3);
}
pub fn comutilIncrement(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_successor, 2);
}
pub fn comutilLess(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_less_p, 3);
}
pub fn comutilMinus(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_subtract, 3);
}
pub fn comutilModulo(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_modulo, 3);
}
pub fn comutilMultiply(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_multiply, 3);
}
pub fn comutilNegative(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_negative_p, 2);
}
pub fn comutilPlus(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_add, 3);
}
pub fn comutilPositive(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_positive_p, 2);
}
pub fn comutilQuotient(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_quotient, 3);
}
pub fn comutilRemainder(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_remainder, 3);
}
pub fn comutilZero(r: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    arithTrampoline(r, abi.fixobj_generic_trampoline_zero_p, 2);
}

pub fn comutilPrimitiveError(
    dsu_result: *UtilityResult,
    ret_addr_raw: usize,
    primitive_raw: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const ret_addr: *anyopaque = @ptrFromInt(@as(usize, @intCast(ret_addr_raw)));
    const primitive: obj.SchemeObject = @intCast(primitive_raw);
    abi.stackPush(makeCcEntry(ret_addr));
    abi.stackPush(primitive);
    saveLastReturnCode(abi.rc_comp_error_restart);
    returnToC(dsu_result, abi.err_compiled_code_error);
}

pub fn compErrorRestart() callconv(.c) isize {
    restoreLastReturnCode();
    _ = abi.stackPop();
    return enterSchemeEntry(ccEntryAddress(abi.stackPop()));
}

pub fn applyCompiledFromPrimitive(n_args_in: usize, proc_in: obj.SchemeObject) callconv(.c) void {
    var n_args = n_args_in;
    var procedure = proc_in;
    while (true) {
        switch (obj.objectType(procedure)) {
            obj.tc_compiled_entry => {
                setupCompiledInvocationFromPrimitive(procedure, n_args);
                return;
            },
            obj.tc_entity => {
                const frame_size = n_args + 1;
                const data = obj.entityData(procedure);
                if (obj.vectorP(data) and
                    frame_size < obj.vectorLength(data) and
                    obj.vectorRef(data, 0) == obj.vectorRef(abi.fixed_objects, abi.fixobj_arity_dispatcher_tag))
                {
                    procedure = obj.vectorRef(data, @intCast(frame_size));
                } else {
                    abi.stackPush(procedure);
                    n_args += 1;
                    procedure = obj.entityOperator(procedure);
                }
            },
            obj.tc_record => {
                const applicator = abi.record_applicator(procedure);
                if (applicator == obj.sharp_f) {
                    abi.stackPush(procedure);
                    abi.stackPush(abi.makeApplyFrameHeader(n_args + 1));
                    pushReflection(reflect_code_internal_apply);
                    return;
                }
                abi.stackPush(procedure);
                n_args += 1;
                procedure = applicator;
            },
            else => {
                abi.stackPush(procedure);
                abi.stackPush(abi.makeApplyFrameHeader(n_args + 1));
                pushReflection(reflect_code_internal_apply);
                return;
            },
        }
    }
}

pub fn compiledWithInterruptMask(old_mask: usize, receiver: obj.SchemeObject, new_mask: usize) callconv(.c) void {
    abi.stackPush(obj.ulongToFixnum(old_mask));
    pushReflection(reflect_code_restore_interrupt_mask);
    abi.stackPush(obj.ulongToFixnum(new_mask));
    setupCompiledInvocationFromPrimitive(receiver, 1);
}

pub fn compiledWithStackMarker(thunk: obj.SchemeObject) callconv(.c) void {
    pushReflection(reflect_code_stack_marker);
    setupCompiledInvocationFromPrimitive(thunk, 0);
}

fn setupCompiledInvocationFromPrimitive(procedure: obj.SchemeObject, n_args: usize) void {
    var code = setupCompiledInvocation(procedure, n_args);
    if (code != abi.prim_done) {
        if (code != abi.prim_apply_interrupt) {
            abi.prim_apply_error_code = code;
            code = abi.prim_apply_error;
        }
        abi.abort_to_interpreter(code);
    }
    abi.stackPush(procedure);
    pushReflection(reflect_code_compiled_invocation);
}

pub fn reflectToInterfaceFrameType(frame: [*]obj.SchemeObject) callconv(.c) c_int {
    const code_object = frame[1];
    std.debug.assert(obj.fixnumP(code_object) and obj.fixnumToUlongP(code_object));
    const code = obj.fixnumToUlong(code_object);
    return @backingInt(switch (code) {
        reflect_code_internal_apply => abi.ReturnFrameType.cc_internal_apply,
        reflect_code_restore_interrupt_mask => abi.ReturnFrameType.cc_restore_interrupt_mask,
        reflect_code_stack_marker => abi.ReturnFrameType.cc_stack_marker,
        reflect_code_cc_bkpt => abi.ReturnFrameType.cc_bkpt,
        reflect_code_compiled_invocation => abi.ReturnFrameType.cc_invocation,
        else => abi.ReturnFrameType.undefined,
    });
}

pub fn cpointReflectToInterfaceNext(cpoint: obj.SchemeObject, index: usize) callconv(.c) usize {
    const code_object = obj.vectorRef(cpoint, @intCast(index + 1));
    std.debug.assert(obj.fixnumP(code_object) and obj.fixnumToUlongP(code_object));
    const code = obj.fixnumToUlong(code_object);
    return switch (code) {
        reflect_code_internal_apply => index + 3 + obj.objectDatum(obj.vectorRef(cpoint, @intCast(index + 2))),
        reflect_code_restore_interrupt_mask => index + 3,
        reflect_code_stack_marker => index + 4,
        reflect_code_cc_bkpt, reflect_code_compiled_invocation => cpointCompiledAddressNext(cpoint, index + 2),
        else => std.math.maxInt(usize),
    };
}

pub fn makeReflectCodeTable() callconv(.c) obj.SchemeObject {
    const table = abi.make_vector(reflect_code_limit, obj.sharp_f, true);
    obj.vectorSet(table, reflect_code_internal_apply, abi.char_pointer_to_string("internal-apply"));
    obj.vectorSet(table, reflect_code_restore_interrupt_mask, abi.char_pointer_to_string("restore-interrupt-mask"));
    obj.vectorSet(table, reflect_code_stack_marker, abi.char_pointer_to_string("stack-marker"));
    obj.vectorSet(table, reflect_code_cc_bkpt, abi.char_pointer_to_string("cc-bkpt"));
    obj.vectorSet(table, reflect_code_compiled_invocation, abi.char_pointer_to_string("comiled-invocation"));
    return table;
}

pub fn ccEntryTypeMarkerGroup(marker: abi.CcEntryTypeMarker) callconv(.c) abi.CcEntryTypeGroup {
    return switch (marker) {
        .procedure => .procedure,
        .continuation, .internal_continuation, .return_to_interpreter => .continuation,
        .expression => .expression,
        .internal_procedure, .trampoline, .closure => .internal_procedure,
    };
}

pub fn ccEntryTypeGroup(entry: obj.SchemeObject) callconv(.c) abi.CcEntryTypeGroup {
    var cet: abi.CcEntryType = undefined;
    const addr = ccEntryToAddress(entry) orelse return .unknown;
    if (abi.read_cc_entry_type(&cet, addr)) return .unknown;
    return ccEntryTypeMarkerGroup(cet.marker);
}

fn compiledEntryFrameSize(cet: *const abi.CcEntryType) usize {
    return switch (ccEntryTypeMarkerGroup(cet.marker)) {
        .procedure => @as(usize, 1) +
            @as(usize, cet.args.for_procedure.n_required) +
            @as(usize, cet.args.for_procedure.n_optional) +
            @as(usize, @intFromBool(cet.args.for_procedure.rest_p)),
        .continuation => if (cet.marker == .continuation)
            1 + cet.args.for_continuation.offset
        else
            std.math.maxInt(usize),
        .expression, .internal_procedure => 1,
        .unknown => std.math.maxInt(usize),
    };
}

pub fn cpointCompiledAddressNext(cpoint: obj.SchemeObject, index: usize) callconv(.c) usize {
    const entry = obj.vectorRef(cpoint, @intCast(index));
    var cet: abi.CcEntryType = undefined;
    const addr = ccEntryToAddress(entry) orelse return std.math.maxInt(usize);
    if (abi.read_cc_entry_type(&cet, addr)) return std.math.maxInt(usize);
    const size = compiledEntryFrameSize(&cet);
    return if (size == std.math.maxInt(usize)) size else index + size;
}

pub fn cpointCompiledCodeNext(cpoint: obj.SchemeObject, index: usize) callconv(.c) usize {
    const rc = obj.objectDatum(obj.vectorRef(cpoint, @intCast(index)));
    return switch (rc) {
        abi.rc_reenter_compiled_code => index + abi.cont_size,
        abi.rc_comp_link_caches_restart => index + abi.cont_size + 7,
        abi.rc_comp_interrupt_restart => blk: {
            const idx2 = index + abi.cont_size + 1;
            const entry = obj.vectorRef(cpoint, @intCast(idx2));
            if (ccEntryP(entry)) {
                var cet: abi.CcEntryType = undefined;
                const addr = ccEntryToAddress(entry) orelse break :blk idx2;
                if (abi.read_cc_entry_type(&cet, addr)) {
                    break :blk std.math.maxInt(usize);
                }
                switch (ccEntryTypeMarkerGroup(cet.marker)) {
                    .internal_procedure => {
                        const dlink = obj.vectorRef(cpoint, @intCast(index + abi.cont_size));
                        if (ccStackEnvP(dlink)) {
                            const se_addr = obj.objectAddress(dlink);
                            const end_diff: usize = @intCast((@intFromPtr(abi.stack_end) - @intFromPtr(se_addr)) / @sizeOf(obj.SchemeObject));
                            break :blk obj.vectorLength(cpoint) - end_diff;
                        }
                    },
                    .procedure => {
                        const size = compiledEntryFrameSize(&cet);
                        break :blk if (size == std.math.maxInt(usize)) size else idx2 + size;
                    },
                    else => {},
                }
            }
            break :blk idx2;
        },
        abi.rc_comp_lookup_trap_restart,
        abi.rc_comp_safe_ref_trap_restart,
        abi.rc_comp_unassigned_trap_restart,
        => index + abi.cont_size + 2,
        abi.rc_comp_assignment_trap_restart => index + abi.cont_size + 3,
        abi.rc_comp_cache_ref_apply_restart, abi.rc_comp_op_ref_trap_restart => blk: {
            const frame_size = obj.fixnumToUlong(obj.vectorRef(cpoint, @intCast(index + abi.cont_size + 2)));
            break :blk index + abi.cont_size + 4 + (frame_size - 1);
        },
        abi.rc_comp_error_restart => index + abi.cont_size + 1,
        else => std.math.maxInt(usize),
    };
}

fn setupCompiledInvocation(procedure: obj.SchemeObject, n_args: usize) isize {
    var cet: abi.CcEntryType = undefined;
    if (abi.read_cc_entry_type(&cet, ccEntryAddress(procedure))) {
        recoverFromApplyError(procedure, n_args);
        return abi.err_compiled_code_error;
    }
    if (cet.marker != .procedure) {
        recoverFromApplyError(procedure, n_args);
        return abi.err_inapplicable_object;
    }
    const n_min: usize = cet.args.for_procedure.n_required;
    if (n_args < n_min) {
        recoverFromApplyError(procedure, n_args);
        return abi.err_wrong_number_of_arguments;
    }
    const n_max: usize = n_min + cet.args.for_procedure.n_optional;
    if (cet.args.for_procedure.rest_p) {
        return setupLexprInvocation(procedure, n_args, n_max);
    }
    if (n_args == n_max) return abi.prim_done;
    if (n_args > n_max) {
        recoverFromApplyError(procedure, n_args);
        return abi.err_wrong_number_of_arguments;
    }
    if (openGap(@intCast(n_args), @intCast(n_max))) {
        recoverFromApplyError(procedure, n_args);
        return abi.prim_apply_interrupt;
    }
    return abi.prim_done;
}

fn setupLexprInvocation(procedure: obj.SchemeObject, n_args: usize, n_max: usize) isize {
    if (n_args <= n_max) {
        if (openGap(@intCast(n_args), @intCast(n_max + 1))) {
            recoverFromApplyError(procedure, n_args);
            return abi.prim_apply_interrupt;
        }
        abi.stack_pointer[@intCast(n_max)] = obj.empty_list;
        return abi.prim_done;
    }
    const n_words = (n_args - n_max) * 2;
    if (abi.gcNeededP(n_words)) {
        abi.requestGc(n_words);
        recoverFromApplyError(procedure, n_args);
        return abi.prim_apply_interrupt;
    }
    const rest_arg = obj.makePointerObject(obj.tc_list, abi.Free);
    const n_max_u: usize = @intCast(n_max);
    const n_args_u: usize = @intCast(n_args);
    var p1 = abi.stackLoc(n_max_u);
    for (n_max_u..n_args_u) |_| {
        abi.Free[0] = p1[0];
        p1 += 1;
        abi.Free[1] = obj.makePointerObject(obj.tc_list, abi.Free + 2);
        abi.Free += 2;
    }
    (abi.Free - 1)[0] = obj.empty_list;
    p1 -= 1;
    p1[0] = rest_arg;
    var p2 = abi.stackLoc(n_max_u);
    for (0..n_max_u) |_| {
        p2 -= 1;
        p1 -= 1;
        p1[0] = p2[0];
    }
    abi.stack_pointer = p1;
    return abi.prim_done;
}

fn openGap(n_args: usize, n_needed: usize) bool {
    const n_defaults = n_needed - n_args;
    abi.stackCheck(n_defaults);
    if (abi.pendingInterrupts() != 0) return true;
    openStackGap(n_args, n_defaults);
    var scan = abi.stackLoc(n_args);
    const end = abi.stackLoc(n_needed);
    while (@intFromPtr(scan) != @intFromPtr(end)) : (scan += 1) {
        scan[0] = obj.default_object;
    }
    return false;
}

pub fn makeCompiledProcedureType(
    cet: *abi.CcEntryType,
    n_required: c_uint,
    n_optional: c_uint,
    rest_p: bool,
) callconv(.c) void {
    cet.marker = .procedure;
    cet.args = .{ .for_procedure = .{
        .n_required = n_required,
        .n_optional = n_optional,
        .rest_p = rest_p,
    } };
}

pub fn makeCompiledContinuationType(cet: *abi.CcEntryType, offset: usize) callconv(.c) void {
    cet.marker = .continuation;
    cet.args = .{ .for_continuation = .{ .offset = offset } };
}

pub fn makeCcEntryType(cet: *abi.CcEntryType, marker: abi.CcEntryTypeMarker) callconv(.c) void {
    std.debug.assert(marker != .procedure and marker != .continuation);
    cet.* = std.mem.zeroes(abi.CcEntryType);
    cet.marker = marker;
}

pub fn ccEntryToBlock(entry: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return makeCcBlock(ccEntryToBlockAddress(entry));
}

pub fn ccEntryToBlockAddress(entry: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return ccEntryAddressToBlockAddress(ccEntryAddress(entry));
}

pub fn ccEntryAddressToBlockAddress(entry: *anyopaque) callconv(.c) [*]obj.SchemeObject {
    var p = entry;
    while (true) {
        var ceo: abi.CcEntryOffset = undefined;
        _ = abi.read_cc_entry_offset(&ceo, p);
        p = ptrSubBytes(p, @as(usize, @intCast(ceo.offset)) * insn_size);
        if (!ceo.continued_p) {
            std.debug.assert((@intFromPtr(p) % @sizeOf(obj.SchemeObject)) == 0);
            const block: [*]obj.SchemeObject = @ptrCast(@alignCast(p));
            std.debug.assert(@intFromPtr(entry) < @intFromPtr(ccBlockAddrEnd(block)));
            return block;
        }
    }
}

pub fn ccReturnToBlock(ret: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return makeCcBlock(ccReturnToBlockAddress(ret));
}

pub fn ccReturnToBlockAddress(ret: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return ccReturnAddressToBlockAddress(ccReturnAddress(ret));
}

pub fn ccReturnAddressToBlockAddress(addr: *anyopaque) callconv(.c) [*]obj.SchemeObject {
    return ccEntryAddressToBlockAddress(ccReturnAddressToEntryAddressPtr(addr));
}

fn plausibleFirstCcEntryP(entry: *anyopaque, zero: *const anyopaque) bool {
    var cet: abi.CcEntryType = undefined;
    var ceo: abi.CcEntryOffset = undefined;
    if (abi.read_cc_entry_type(&cet, entry)) return false;
    if (abi.read_cc_entry_offset(&ceo, entry)) return false;
    return ceo.offset == insnDiff(entry, zero);
}

pub fn plausibleCcBlockP(block: [*]obj.SchemeObject) callconv(.c) c_int {
    var entry = ptrAddBytes(@ptrCast(block + 2), (cc_entry_padding_size + cc_entry_header_size) * insn_size);
    if (!plausibleFirstCcEntryP(entry, block)) {
        entry = ptrAddBytes(entry, cc_entry_gc_trap_size * insn_size);
        if (!plausibleFirstCcEntryP(entry, block)) return 0;
    }
    const block_end = ccBlockAddrEnd(block) - 1;
    const b_addr = @intFromPtr(block);
    const e_addr = @intFromPtr(block_end);
    const h_start = loadRawGlobalPtr(&abi.heap_start);
    const free_p = loadRawGlobalPtr(&abi.Free);
    const c_start = loadRawGlobalPtr(&abi.constant_start);
    const c_end = loadRawGlobalPtr(&abi.constant_end);
    const in_heap = (b_addr >= h_start and b_addr < free_p) and (e_addr >= h_start and e_addr < free_p);
    const in_const = (b_addr >= c_start and b_addr < c_end) and (e_addr >= c_start and e_addr < c_end);
    const in_code = abi.code_address_p(@ptrCast(block)) and abi.code_address_p(@ptrCast(block_end));
    return if ((in_heap or in_const or in_code) and obj.environmentP(block_end[0])) 1 else 0;
}

inline fn linkageSectionTypeEnum(marker: obj.SchemeObject) abi.LinkageSectionType {
    const t = obj.objectDatum(marker) >> 16;
    std.debug.assert(t < 4);
    return @fromBackingInt(@intCast(@as(c_uint, @intCast(t))));
}

pub fn linkageSectionType(marker: obj.SchemeObject) callconv(.c) c_uint {
    return @backingInt(linkageSectionTypeEnum(marker));
}

pub fn linkageSectionCount(marker: obj.SchemeObject) callconv(.c) usize {
    const t = linkageSectionTypeEnum(marker);
    const n_words = obj.objectDatum(marker) & 0xFFFF;
    return if (t == .operator or t == .global_operator) n_words / uuo_link_size else n_words;
}

pub fn makeLinkageSectionMarker(sec_type: abi.LinkageSectionType, count: usize) callconv(.c) obj.SchemeObject {
    const t_val = @backingInt(sec_type);
    std.debug.assert(t_val < 4);
    const n_words = if (sec_type == .operator or sec_type == .global_operator) count * uuo_link_size else count;
    std.debug.assert(n_words < 0x10000);
    return obj.makeObject(obj.tc_linkage_section, (@as(usize, t_val) << 16) | n_words);
}

pub fn ccBlockDebuggingInfo(block: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return obj.vectorRef(block, @intCast(obj.vectorLength(block) - 2));
}

pub fn ccBlockEnvironment(block: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return obj.vectorRef(block, @intCast(obj.vectorLength(block) - 1));
}

pub fn ccEntryToBlockOffset(entry: obj.SchemeObject) callconv(.c) usize {
    return @intCast(@intFromPtr(ccEntryAddress(entry)) - @intFromPtr(ccEntryToBlockAddress(entry)));
}

pub fn ccReturnToBlockOffset(ret: obj.SchemeObject) callconv(.c) usize {
    const entry_addr = ccReturnAddressToEntryAddressPtr(ccReturnAddress(ret));
    return @intCast(@intFromPtr(entry_addr) - @intFromPtr(ccReturnToBlockAddress(ret)));
}

fn ccBlockAddressClosureP(block_addr: [*]const obj.SchemeObject) bool {
    return obj.objectType(block_addr[0]) == obj.tc_manifest_closure;
}

pub fn ccBlockClosureP(block: obj.SchemeObject) callconv(.c) bool {
    return ccBlockAddressClosureP(obj.objectAddress(block));
}

pub fn ccEntryClosureP(entry: obj.SchemeObject) callconv(.c) bool {
    return ccBlockAddressClosureP(ccEntryToBlockAddress(entry));
}

pub fn ccClosureToEntry(entry: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return abi.compiled_closure_entry_to_target(ccEntryAddress(entry));
}

pub fn declareCompiledCodeBlock(block: obj.SchemeObject) callconv(.c) void {
    if (comptime has_flush_icache_region) {
        const addr = obj.objectAddress(block);
        abi.aarch64_flush_i_cache_region(addr, @intCast(ccBlockAddrLength(addr)));
    }
}

pub fn writeVariableCache(cache: obj.SchemeObject, block: obj.SchemeObject, offset: usize) callconv(.c) void {
    const val: obj.SchemeObject = @intCast(@intFromPtr(obj.objectAddress(cache)));
    if (abi.code_address_p(@ptrCast(obj.objectAddress(block)))) {
        abi.code_arena_write_begin();
        obj.memorySet(block, @intCast(offset), val);
        abi.code_arena_write_end();
    } else {
        obj.memorySet(block, @intCast(offset), val);
    }
}

pub fn readUuoLink(block: obj.SchemeObject, offset: usize) callconv(.c) obj.SchemeObject {
    return makeCcEntry(abi.read_uuo_target_no_reloc(obj.memoryLoc(block, @intCast(offset))).?);
}

fn writeUuoLink(target: obj.SchemeObject, cache_address: [*]obj.SchemeObject) void {
    const entry = ccEntryAddress(target);
    if (abi.code_address_p(@ptrCast(cache_address))) {
        abi.code_arena_write_begin();
        abi.write_uuo_target(entry, cache_address);
        abi.code_arena_write_end();
    } else {
        abi.write_uuo_target(entry, cache_address);
    }
    if (comptime has_flush_icache_region) {
        if (!linking_cc_block_p) {
            abi.aarch64_flush_i_cache_region(cache_address, uuo_link_size);
        }
    }
}

pub fn compiledClosureObjects(block: [*]obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    var start = abi.compiled_closure_start(block);
    var count = abi.compiled_closure_count(block);
    while (count > 0) : (count -= 1) {
        start = abi.compiled_closure_next(start);
    }
    return abi.skip_compiled_closure_padding(start);
}

pub fn decodeOldStyleFormatWord(cet: *abi.CcEntryType, fw: u16) callconv(.c) bool {
    var low: u16 = fw & 0x00FF;
    const high: u16 = (fw & 0xFF00) >> 8;
    var rest_p = false;

    if (high < 0x80) {
        if (high == 0x00 or low == 0x00 or low == 0x80) return true;
        if (low > 0x80) {
            low = 0xFF - low;
            rest_p = true;
        }
        if (!(high <= low)) return true;
        makeCompiledProcedureType(cet, high - 1, low - high, rest_p);
        return false;
    }
    if (low < 0x80) return true;
    if (low < 0xE0) {
        makeCompiledContinuationType(cet, @as(usize, ((low & 0x7F) << 7) | (high & 0x7F)));
        return false;
    }
    if (high != 0xFF) return true;
    const marker: abi.CcEntryTypeMarker = switch (low) {
        0xFF => .expression,
        0xFE => .internal_procedure,
        0xFD => .trampoline,
        0xFC => .internal_continuation,
        0xFB => .return_to_interpreter,
        0xFA => .closure,
        else => return true,
    };
    makeCcEntryType(cet, marker);
    return false;
}

pub fn encodeOldStyleFormatWord(cet: *abi.CcEntryType, fw_r: *u16) callconv(.c) bool {
    var low: u16 = 0;
    var high: u16 = 0;
    switch (cet.marker) {
        .procedure => {
            high = @intCast(cet.args.for_procedure.n_required + 1);
            low = @intCast(high + cet.args.for_procedure.n_optional);
            if (!(low < 0x80)) return true;
            if (cet.args.for_procedure.rest_p) {
                low = 0xFF - low;
            }
        },
        .continuation => {
            const n = cet.args.for_continuation.offset;
            if (!(n < 0x3000)) return true;
            high = @intCast((n & 0x7F) | 0x80);
            low = @intCast((n >> 7) | 0x80);
        },
        .expression => {
            low = 0xFF;
            high = 0xFF;
        },
        .internal_procedure => {
            low = 0xFE;
            high = 0xFF;
        },
        .trampoline => {
            low = 0xFD;
            high = 0xFF;
        },
        .internal_continuation => {
            low = 0xFC;
            high = 0xFF;
        },
        .return_to_interpreter => {
            low = 0xFB;
            high = 0xFF;
        },
        .closure => {
            low = 0xFA;
            high = 0xFF;
        },
    }
    fw_r.* = (high << 8) | low;
    return false;
}

pub fn comutilReturnToInterpreter(dsu_result: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    returnToC(dsu_result, abi.prim_done);
}

pub fn comutilReflectToInterface(dsu_result: *UtilityResult, _: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const code = abi.stackPop();
    switch (obj.objectDatum(code)) {
        reflect_code_compiled_invocation => {
            const procedure = abi.stackPop();
            returnToSchemeEntry(dsu_result, ccEntryAddress(procedure));
        },
        reflect_code_internal_apply => {
            const frame_size = obj.objectDatum(abi.stackPop());
            const procedure = abi.stackPop();
            comutilApply(dsu_result, @intCast(procedure), frame_size, 0, 0);
        },
        reflect_code_restore_interrupt_mask => {
            abi.setInterruptMask(obj.objectDatum(abi.stackPop()));
            invokeReturnAddress(dsu_result);
        },
        reflect_code_stack_marker => {
            _ = abi.stackPop();
            _ = abi.stackPop();
            invokeReturnAddress(dsu_result);
        },
        reflect_code_cc_bkpt => {
            if (@intFromPtr(abi.Free) >= abi.Registers[abi.regblock_memtop]) {
                pushReflection(reflect_code_cc_bkpt);
                compilerInterruptCommon(dsu_result, null, obj.sharp_f);
                return;
            }
            var addr: ?*anyopaque = null;
            const bcode = doBkptProceed(&addr);
            if (bcode != abi.prim_done) {
                abi.stackPush(@bitCast(bcode));
                returnToC(dsu_result, bcode);
                return;
            }
            returnToSchemeEntry(dsu_result, addr.?);
        },
        else => {
            abi.stackPush(code);
            returnToC(dsu_result, abi.err_external_return);
        },
    }
}

pub fn comutilOperatorApplyTrap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    comutilApply(dsu_result, @intCast(store[0]), obj.objectDatum(store[1]), 0, 0);
}

pub fn comutilOperatorPrimitiveTrap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    comutilPrimitiveApply(dsu_result, @intCast(store[0]), 0, 0, 0);
}

pub fn comutilOperatorLexprTrap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    abi.Registers[abi.regblock_lexpr_actuals] = abi.applyFrameHeaderNArgs(store[1]);
    comutilPrimitiveLexprApply(dsu_result, @intCast(store[0]), 0, 0, 0);
}

pub fn comutilOperator10Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    abi.stackPush(obj.default_object);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator20Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator21Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const a1 = abi.stackPop();
    abi.stackPush(obj.default_object);
    abi.stackPush(a1);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator30Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator31Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const a1 = abi.stackPop();
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(a1);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator32Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const a1 = abi.stackPop();
    const a2 = abi.stackPop();
    abi.stackPush(obj.default_object);
    abi.stackPush(a2);
    abi.stackPush(a1);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator40Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator41Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const a1 = abi.stackPop();
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(a1);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator42Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const a1 = abi.stackPop();
    const a2 = abi.stackPop();
    abi.stackPush(obj.default_object);
    abi.stackPush(obj.default_object);
    abi.stackPush(a2);
    abi.stackPush(a1);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperator43Trap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const a1 = abi.stackPop();
    const a2 = abi.stackPop();
    const a3 = abi.stackPop();
    abi.stackPush(obj.default_object);
    abi.stackPush(a3);
    abi.stackPush(a2);
    abi.stackPush(a1);
    returnToSchemeEntry(dsu_result, ccEntryAddress(store[0]));
}

pub fn comutilOperatorLookupTrap(dsu_result: *UtilityResult, tramp_store_raw: usize, _: usize, _: usize, _: usize) callconv(.c) void {
    const store: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(tramp_store_raw)));
    const cache = store[0];
    const block = store[1];
    const offset = store[2];
    const cache_addr = obj.memoryLoc(block, @intCast(obj.objectDatum(offset)));
    const frame_size: usize = abi.read_uuo_frame_size(cache_addr);
    var procedure: obj.SchemeObject = 0;
    const code = abi.compiler_operator_reference_trap(cache, &procedure);
    if (code != abi.prim_done) {
        abi.stackPush(makeCcEntry(abi.read_uuo_target_no_reloc(cache_addr).?));
        abi.stackPush(obj.ulongToFixnum(frame_size));
        abi.stackPush(ccBlockEnvironment(block));
        abi.stackPush(abi.compiler_var_error(cache, block, .operator_cache));
        saveLastReturnCode(abi.rc_comp_op_ref_trap_restart);
        returnToC(dsu_result, code);
        return;
    }
    comutilApply(dsu_result, @intCast(procedure), frame_size, 0, 0);
}

pub fn compOpLookupTrapRestart() callconv(.c) isize {
    restoreLastReturnCode();
    abi.stack_pointer = abi.stackLoc(3);
    const store = trampolineStorage(ccEntryToBlockAddress(abi.stackPop()));
    const block = store[1];
    const offset = obj.objectDatum(store[2]);
    return enterSchemeEntry(abi.read_uuo_target_no_reloc(obj.memoryLoc(block, @intCast(offset))).?);
}

pub fn makeUuoLink(
    proc_in: obj.SchemeObject,
    cache: obj.SchemeObject,
    block: obj.SchemeObject,
    offset: usize,
) callconv(.c) isize {
    const cache_address = obj.memoryLoc(block, @intCast(offset));
    var frame_size: usize = abi.read_uuo_frame_size(cache_address);
    if (obj.referenceTrapP(proc_in)) {
        return makeFakeUuoLink(cache, block, offset);
    }
    var procedure = proc_in;
    var kind: u8 = abi.trampoline_k_apply;

    while (true) {
        switch (obj.objectType(procedure)) {
            obj.tc_compiled_entry => {
                const entry = ccEntryAddress(procedure);
                const nargs = frame_size - 1;
                var cet: abi.CcEntryType = undefined;
                if (abi.read_cc_entry_type(&cet, entry) or cet.marker != .procedure) {
                    return abi.err_compiled_code_error;
                }
                const nmin: usize = cet.args.for_procedure.n_required;
                const nmax: usize = nmin + cet.args.for_procedure.n_optional;
                if (cet.args.for_procedure.rest_p) {
                    kind = abi.trampoline_k_apply;
                } else if (nargs == nmax) {
                    writeUuoLink(procedure, cache_address);
                    return abi.prim_done;
                } else if (nargs < nmax and nargs >= nmin and nmin < nmax and nmax <= trampoline_table_size) {
                    kind = trampoline_arity_table[@as(usize, @intCast(((nmax - 1) * trampoline_table_size) + nargs))];
                    std.debug.assert(kind != abi.trampoline_k_apply);
                    frame_size = 0;
                } else {
                    kind = abi.trampoline_k_apply;
                }
                break;
            },
            obj.tc_entity => {
                const data = obj.entityData(procedure);
                if (obj.vectorP(data) and
                    frame_size < obj.vectorLength(data) and
                    obj.vectorRef(data, @intCast(frame_size)) != obj.sharp_f and
                    obj.vectorRef(data, 0) == obj.vectorRef(abi.fixed_objects, abi.fixobj_arity_dispatcher_tag))
                {
                    procedure = obj.vectorRef(data, @intCast(frame_size));
                    continue;
                }
                kind = abi.trampoline_k_apply;
                break;
            },
            obj.tc_primitive => {
                const arity = primitiveArity(procedure);
                if (arity == @as(isize, @intCast(frame_size - 1))) {
                    kind = abi.trampoline_k_primitive;
                    frame_size = 0;
                } else if (arity == abi.lexpr_primitive_arity) {
                    kind = abi.trampoline_k_lexpr_primitive;
                } else {
                    kind = abi.trampoline_k_apply;
                }
                break;
            },
            else => {
                kind = abi.trampoline_k_apply;
                break;
            },
        }
    }

    var trampoline: obj.SchemeObject = 0;
    const result = if (frame_size == 0)
        makeRedirectionTrampoline(&trampoline, kind, procedure)
    else
        makeApplyTrampoline(&trampoline, kind, procedure, frame_size);
    if (result == abi.prim_done) {
        writeUuoLink(trampoline, cache_address);
    }
    return result;
}

fn makeFakeUuoLink(cache: obj.SchemeObject, block: obj.SchemeObject, offset: usize) isize {
    var cet: abi.CcEntryType = undefined;
    var trampoline: obj.SchemeObject = 0;
    makeCcEntryType(&cet, .trampoline);
    const result = makeTrampoline(&trampoline, &cet, abi.trampoline_k_lookup, &.{
        cache,
        block,
        obj.ulongToFixnum(offset),
    });
    if (result != abi.prim_done) return result;
    writeUuoLink(trampoline, obj.memoryLoc(block, @intCast(offset)));
    return abi.prim_done;
}

pub fn coerceToCompiled(procedure: obj.SchemeObject, arity: c_uint, location: *obj.SchemeObject) callconv(.c) isize {
    var cet: abi.CcEntryType = undefined;
    if (ccEntryP(procedure)) {
        if (abi.read_cc_entry_type(&cet, ccEntryAddress(procedure))) {
            return abi.err_compiled_code_error;
        }
        if (cet.marker == .procedure) {
            location.* = procedure;
            return abi.prim_done;
        }
    }
    makeCompiledProcedureType(&cet, arity, 0, false);
    return makeTrampoline(location, &cet, abi.trampoline_k_apply, &.{
        procedure,
        obj.ulongToFixnum(@as(usize, arity) + 1),
    });
}

fn makeTrampoline(
    slot: *obj.SchemeObject,
    cet: *abi.CcEntryType,
    kind: u8,
    values: []const obj.SchemeObject,
) isize {
    if (comptime have_trampoline_to_interface) {
        const tti = trampoline_to_interface orelse return abi.err_compiled_code_error;
        const n_words: usize = 5 + @as(usize, @intCast(values.len));
        if (abi.gcNeededP(n_words)) {
            abi.requestGc(n_words);
            return abi.prim_interrupt;
        }
        const block = abi.Free;
        abi.Free += @as(usize, @intCast(n_words));
        block[0] = obj.makeObject(obj.tc_manifest_closure, n_words - 1);
        block[1] = 0;
        @as(*u32, @ptrCast(block + 1)).* = 1;
        block[2] = 0;

        const start = abi.compiled_closure_start(block + 1).?;
        const entry0 = abi.compiled_closure_entry(start).?;
        if (@intFromPtr(entry0) != @intFromPtr(block + 3) or abi.write_cc_entry_type(cet, entry0)) {
            return abi.err_compiled_code_error;
        }
        var ceo = abi.CcEntryOffset{
            .offset = insnDiff(entry0, block),
            .continued_p = false,
        };
        if (abi.write_cc_entry_offset(&ceo, entry0)) {
            return abi.err_compiled_code_error;
        }
        abi.write_compiled_closure_target(tti, start);
        block[3] = obj.ulongToFixnum(kind);
        for (values, 0..) |v, i| {
            block[4 + i] = v;
        }
        const tagged = makeCcEntry(entry0);
        block[@as(usize, @intCast(n_words)) - 1] = tagged;
        slot.* = tagged;
        return abi.prim_done;
    } else {
        var h1: obj.SchemeObject = 0;
        var h2: obj.SchemeObject = 0;
        var n_words: usize = 0;
        makeTrampolineHeaders(1, @intCast(values.len), &h1, &h2, &n_words);
        if (abi.gcNeededP(n_words)) {
            abi.requestGc(n_words);
            return abi.prim_interrupt;
        }
        const block = abi.Free;
        abi.Free += @as(usize, @intCast(n_words));
        block[0] = h1;
        block[1] = h2;
        if (fillTrampoline(block, 0, cet, kind)) {
            return abi.err_compiled_code_error;
        }
        const store = trampolineStorage(block);
        for (values, 0..) |v, i| {
            store[i] = v;
        }
        slot.* = makeCcEntry(abi.trampoline_entry_addr(block, 0).?);
        return abi.prim_done;
    }
}

fn makeTrampolineHeaders(
    n_entries: usize,
    n_store: usize,
    h1_r: *obj.SchemeObject,
    h2_r: *obj.SchemeObject,
    n_words_r: *usize,
) void {
    const n1 = abi.trampoline_entry_size(n_entries);
    const n2 = 1 + n1 + n_store;
    h1_r.* = obj.makeObject(tc_trampoline_header, n2);
    h2_r.* = obj.makeNmvHeader(n1);
    n_words_r.* = 1 + n2;
}

fn fillTrampoline(
    block: [*]obj.SchemeObject,
    index: usize,
    cet: *abi.CcEntryType,
    kind: u8,
) bool {
    const addr = abi.trampoline_entry_addr(block, index).?;
    if (abi.write_cc_entry_type(cet, addr)) return true;
    var ceo = abi.CcEntryOffset{
        .offset = insnDiff(addr, block),
        .continued_p = false,
    };
    if (abi.write_cc_entry_offset(&ceo, addr)) return true;
    if (abi.store_trampoline_insns(addr, kind)) return true;
    if (comptime has_flush_icache_region) {
        abi.aarch64_flush_i_cache_region(block, @intCast(ccBlockAddrLength(block)));
    }
    return false;
}

pub fn trampolineStorage(block: [*]obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    if (obj.objectType(block[0]) == obj.tc_manifest_closure) {
        return block + 4;
    }
    return block + 2 + @as(usize, @intCast(obj.objectDatum(block[1])));
}

fn makeRedirectionTrampoline(slot: *obj.SchemeObject, kind: u8, procedure: obj.SchemeObject) isize {
    var cet: abi.CcEntryType = undefined;
    makeCcEntryType(&cet, .trampoline);
    return makeTrampoline(slot, &cet, kind, &.{procedure});
}

fn makeApplyTrampoline(slot: *obj.SchemeObject, kind: u8, procedure: obj.SchemeObject, frame_size: usize) isize {
    var cet: abi.CcEntryType = undefined;
    makeCcEntryType(&cet, .trampoline);
    return makeTrampoline(slot, &cet, kind, &.{ procedure, obj.ulongToFixnum(frame_size) });
}

pub fn bkptInstall(_: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return obj.sharp_f;
}

pub fn bkptClosureInstall(_: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return obj.sharp_f;
}

pub fn bkptRemove(_: ?*anyopaque, _: obj.SchemeObject) callconv(.c) void {
    abi.error_external_return();
}

pub fn bkptP(_: ?*anyopaque) callconv(.c) bool {
    return false;
}

pub fn bkptProceed(_: ?*anyopaque, _: obj.SchemeObject, _: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    abi.error_external_return();
}

pub fn doBkptProceed(_: *?*anyopaque) callconv(.c) isize {
    return abi.err_external_return;
}

pub fn comutilCompiledCodeBkpt(
    dsu_result: *UtilityResult,
    entry_addr_raw: usize,
    state_raw: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const entry_addr: *anyopaque = @ptrFromInt(@as(usize, @intCast(entry_addr_raw)));
    const entry = makeCcEntry(entry_addr);
    var cet: abi.CcEntryType = undefined;
    const to_save: obj.SchemeObject = if (abi.read_cc_entry_type(&cet, entry_addr))
        obj.sharp_f
    else switch (cet.marker) {
        .continuation, .return_to_interpreter => abi.Registers[abi.regblock_val],
        .internal_continuation => blk: {
            const state_ptr: [*]const obj.SchemeObject = @ptrFromInt(@as(usize, @intCast(state_raw)));
            break :blk makeCcStackEnv(state_ptr);
        },
        .closure => makeCcEntry(@ptrFromInt(@as(usize, @intCast(state_raw)))),
        else => obj.sharp_f,
    };

    abi.stackPush(entry);
    const stack_ptr = makeCcStackEnv(abi.stack_pointer);
    abi.stackPush(to_save);
    abi.stackPush(stack_ptr);
    abi.stackPush(entry);
    comutilApply(dsu_result, @intCast(obj.vectorRef(abi.fixed_objects, abi.fixobj_cc_bkpt_procedure)), 4, 0, 0);
}

pub fn comutilCompiledClosureBkpt(
    dsu_result: *UtilityResult,
    entry_addr_raw: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(.c) void {
    const entry_addr: *anyopaque = @ptrFromInt(@as(usize, @intCast(entry_addr_raw)));
    const entry = makeCcEntry(entry_addr);
    abi.stackPush(entry);
    const stack_ptr = makeCcStackEnv(abi.stack_pointer);
    abi.stackPush(obj.sharp_f);
    abi.stackPush(stack_ptr);
    abi.stackPush(entry);
    comutilApply(dsu_result, @intCast(obj.vectorRef(abi.fixed_objects, abi.fixobj_cc_bkpt_procedure)), 4, 0, 0);
}

pub fn utilityIndexToName(_: c_uint) callconv(.c) ?[*:0]const u8 {
    return null;
}

pub fn pcToUtilityIndex(_: usize) callconv(.c) c_int {
    return -1;
}

pub fn declareBuiltin(builtin_addr: usize, name: [*:0]const u8) callconv(.c) void {
    if (n_builtins == s_builtins) {
        if (s_builtins == 0) {
            s_builtins = 30;
            const b_ptr = std.c.malloc(@as(usize, s_builtins) * @sizeOf(usize));
            const n_ptr = std.c.malloc(@as(usize, s_builtins) * @sizeOf([*:0]const u8));
            builtins = if (b_ptr) |p| @ptrCast(@alignCast(p)) else null;
            builtin_names = if (n_ptr) |p| @ptrCast(@alignCast(p)) else null;
        } else {
            s_builtins += s_builtins;
            const b_ptr = std.c.realloc(@ptrCast(builtins), @as(usize, s_builtins) * @sizeOf(usize));
            const n_ptr = std.c.realloc(@ptrCast(builtin_names), @as(usize, s_builtins) * @sizeOf([*:0]const u8));
            builtins = if (b_ptr) |p| @ptrCast(@alignCast(p)) else null;
            builtin_names = if (n_ptr) |p| @ptrCast(@alignCast(p)) else null;
        }
        if (builtins == null or builtin_names == null) {
            outf.fatal("declare_builtin: malloc/realloc failed (size = {d}).\n", .{s_builtins});
            abi.termination_init_error();
        }
    }

    const bs = builtins.?;
    const names = builtin_names.?;
    var low: c_uint = 0;
    var high: c_uint = n_builtins;
    while (true) {
        if (low < high) {
            const middle = (low + high) / 2;
            if (builtin_addr < bs[middle]) {
                high = middle;
            } else if (builtin_addr > bs[middle]) {
                low = middle + 1;
            } else {
                names[middle] = name;
                return;
            }
        } else {
            var scan = n_builtins;
            n_builtins += 1;
            while (low < scan) {
                bs[scan] = bs[scan - 1];
                names[scan] = names[scan - 1];
                scan -= 1;
            }
            bs[low] = builtin_addr;
            names[low] = name;
            return;
        }
    }
}

pub fn builtinIndexToName(index: c_uint) callconv(.c) ?[*:0]const u8 {
    return if (index < n_builtins) builtin_names.?[index] else null;
}

pub fn pcToBuiltinIndex(pc: usize) callconv(.c) c_int {
    const bs = builtins orelse return -1;
    if (!(n_builtins > 0 and pc >= bs[0] and pc < bs[n_builtins - 1])) return -1;
    var low: c_uint = 0;
    var high: c_uint = n_builtins - 1;
    while ((low + 1) < high) {
        const middle = (low + high) / 2;
        if (pc < bs[middle]) {
            high = middle;
        } else if (pc > bs[middle]) {
            low = middle;
        } else {
            return @intCast(middle);
        }
    }
    return @intCast(if (pc == bs[high]) high else low);
}

comptime {
    if (!builtin.is_test and build_options.cc_support) {
        @export(&registers_storage, .{ .name = "Registers" });
        @export(&compiler_processor_type_storage, .{ .name = "compiler_processor_type" });
        @export(&compiler_interface_version_storage, .{ .name = "compiler_interface_version" });
        @export(&compiler_utilities_storage, .{ .name = "compiler_utilities" });
        @export(&return_to_interpreter_storage, .{ .name = "return_to_interpreter" });
        @export(&reflect_to_interface_storage, .{ .name = "reflect_to_interface" });
        @export(&utility_table, .{ .name = "utility_table" });
        @export(&max_trampoline_storage, .{ .name = "max_trampoline" });

        @export(&compilerInitialize, .{ .name = "compiler_initialize" });
        @export(&compilerReset, .{ .name = "compiler_reset" });
        @export(&enterCompiledExpression, .{ .name = "enter_compiled_expression" });
        @export(&applyCompiledProcedure, .{ .name = "apply_compiled_procedure" });
        @export(&ccReturnAddressP, .{ .name = "cc_return_address_p" });
        @export(&returnToCompiledCode, .{ .name = "return_to_compiled_code" });
        @export(&guaranteeCcReturn, .{ .name = "guarantee_cc_return" });
        @export(&guaranteeInterpReturn, .{ .name = "guarantee_interp_return" });

        @export(&comutilApply, .{ .name = "comutil_apply" });
        @export(&comutilLexprApply, .{ .name = "comutil_lexpr_apply" });
        @export(&comutilPrimitiveApply, .{ .name = "comutil_primitive_apply" });
        @export(&comutilPrimitiveLexprApply, .{ .name = "comutil_primitive_lexpr_apply" });
        @export(&comutilError, .{ .name = "comutil_error" });
        @export(&comutilLink, .{ .name = "comutil_link" });
        @export(&compLinkCachesRestart, .{ .name = "comp_link_caches_restart" });
        @export(&ccBlockLinkageInfo, .{ .name = "cc_block_linkage_info" });

        @export(&comutilInterruptClosure, .{ .name = "comutil_interrupt_closure" });
        @export(&comutilInterruptDlink, .{ .name = "comutil_interrupt_dlink" });
        @export(&comutilInterruptProcedure, .{ .name = "comutil_interrupt_procedure" });
        @export(&comutilInterruptContinuation, .{ .name = "comutil_interrupt_continuation" });
        @export(&comutilInterruptIcProcedure, .{ .name = "comutil_interrupt_ic_procedure" });
        @export(&comutilInterruptContinuation2, .{ .name = "comutil_interrupt_continuation_2" });
        @export(&compilerInterruptCommon, .{ .name = "compiler_interrupt_common" });
        @export(&compInterruptRestart, .{ .name = "comp_interrupt_restart" });

        @export(&comutilAssignmentTrap, .{ .name = "comutil_assignment_trap" });
        @export(&compAssignmentTrapRestart, .{ .name = "comp_assignment_trap_restart" });
        @export(&comutilCacheLookupApply, .{ .name = "comutil_cache_lookup_apply" });
        @export(&compCacheLookupApplyRestart, .{ .name = "comp_cache_lookup_apply_restart" });
        @export(&comutilLookupTrap, .{ .name = "comutil_lookup_trap" });
        @export(&compLookupTrapRestart, .{ .name = "comp_lookup_trap_restart" });
        @export(&comutilSafeLookupTrap, .{ .name = "comutil_safe_lookup_trap" });
        @export(&compSafeLookupTrapRestart, .{ .name = "comp_safe_lookup_trap_restart" });
        @export(&comutilUnassignedPTrap, .{ .name = "comutil_unassigned_p_trap" });
        @export(&compUnassignedPTrapRestart, .{ .name = "comp_unassigned_p_trap_restart" });

        @export(&comutilDecrement, .{ .name = "comutil_decrement" });
        @export(&comutilDivide, .{ .name = "comutil_divide" });
        @export(&comutilEqual, .{ .name = "comutil_equal" });
        @export(&comutilGreater, .{ .name = "comutil_greater" });
        @export(&comutilIncrement, .{ .name = "comutil_increment" });
        @export(&comutilLess, .{ .name = "comutil_less" });
        @export(&comutilMinus, .{ .name = "comutil_minus" });
        @export(&comutilModulo, .{ .name = "comutil_modulo" });
        @export(&comutilMultiply, .{ .name = "comutil_multiply" });
        @export(&comutilNegative, .{ .name = "comutil_negative" });
        @export(&comutilPlus, .{ .name = "comutil_plus" });
        @export(&comutilPositive, .{ .name = "comutil_positive" });
        @export(&comutilQuotient, .{ .name = "comutil_quotient" });
        @export(&comutilRemainder, .{ .name = "comutil_remainder" });
        @export(&comutilZero, .{ .name = "comutil_zero" });
        @export(&comutilPrimitiveError, .{ .name = "comutil_primitive_error" });
        @export(&compErrorRestart, .{ .name = "comp_error_restart" });

        @export(&applyCompiledFromPrimitive, .{ .name = "apply_compiled_from_primitive" });
        @export(&compiledWithInterruptMask, .{ .name = "compiled_with_interrupt_mask" });
        @export(&compiledWithStackMarker, .{ .name = "compiled_with_stack_marker" });
        @export(&reflectToInterfaceFrameType, .{ .name = "reflect_to_interface_frame_type" });
        @export(&cpointReflectToInterfaceNext, .{ .name = "cpoint_reflect_to_interface_next" });
        @export(&makeReflectCodeTable, .{ .name = "make_reflect_code_table" });
        @export(&ccEntryTypeMarkerGroup, .{ .name = "cc_entry_type_marker_group" });
        @export(&ccEntryTypeGroup, .{ .name = "cc_entry_type_group" });
        @export(&cpointCompiledAddressNext, .{ .name = "cpoint_compiled_address_next" });
        @export(&cpointCompiledCodeNext, .{ .name = "cpoint_compiled_code_next" });

        @export(&makeCompiledProcedureType, .{ .name = "make_compiled_procedure_type" });
        @export(&makeCompiledContinuationType, .{ .name = "make_compiled_continuation_type" });
        @export(&makeCcEntryType, .{ .name = "make_cc_entry_type" });
        @export(&ccEntryToBlock, .{ .name = "cc_entry_to_block" });
        @export(&ccEntryToBlockAddress, .{ .name = "cc_entry_to_block_address" });
        @export(&ccEntryAddressToBlockAddress, .{ .name = "cc_entry_address_to_block_address" });
        @export(&ccReturnToBlock, .{ .name = "cc_return_to_block" });
        @export(&ccReturnToBlockAddress, .{ .name = "cc_return_to_block_address" });
        @export(&ccReturnAddressToBlockAddress, .{ .name = "cc_return_address_to_block_address" });
        @export(&plausibleCcBlockP, .{ .name = "plausible_cc_block_p" });
        @export(&linkageSectionType, .{ .name = "linkage_section_type" });
        @export(&linkageSectionCount, .{ .name = "linkage_section_count" });
        @export(&makeLinkageSectionMarker, .{ .name = "make_linkage_section_marker" });
        @export(&ccBlockDebuggingInfo, .{ .name = "cc_block_debugging_info" });
        @export(&ccBlockEnvironment, .{ .name = "cc_block_environment" });
        @export(&ccEntryToBlockOffset, .{ .name = "cc_entry_to_block_offset" });
        @export(&ccReturnToBlockOffset, .{ .name = "cc_return_to_block_offset" });
        @export(&ccBlockClosureP, .{ .name = "cc_block_closure_p" });
        @export(&ccEntryClosureP, .{ .name = "cc_entry_closure_p" });
        @export(&ccClosureToEntry, .{ .name = "cc_closure_to_entry" });
        @export(&declareCompiledCodeBlock, .{ .name = "declare_compiled_code_block" });
        @export(&writeVariableCache, .{ .name = "write_variable_cache" });
        @export(&readUuoLink, .{ .name = "read_uuo_link" });
        @export(&compiledClosureObjects, .{ .name = "compiled_closure_objects" });
        @export(&decodeOldStyleFormatWord, .{ .name = "decode_old_style_format_word" });
        @export(&encodeOldStyleFormatWord, .{ .name = "encode_old_style_format_word" });

        @export(&comutilReturnToInterpreter, .{ .name = "comutil_return_to_interpreter" });
        @export(&comutilReflectToInterface, .{ .name = "comutil_reflect_to_interface" });
        @export(&comutilOperatorApplyTrap, .{ .name = "comutil_operator_apply_trap" });
        @export(&comutilOperatorPrimitiveTrap, .{ .name = "comutil_operator_primitive_trap" });
        @export(&comutilOperatorLexprTrap, .{ .name = "comutil_operator_lexpr_trap" });
        @export(&comutilOperator10Trap, .{ .name = "comutil_operator_1_0_trap" });
        @export(&comutilOperator20Trap, .{ .name = "comutil_operator_2_0_trap" });
        @export(&comutilOperator21Trap, .{ .name = "comutil_operator_2_1_trap" });
        @export(&comutilOperator30Trap, .{ .name = "comutil_operator_3_0_trap" });
        @export(&comutilOperator31Trap, .{ .name = "comutil_operator_3_1_trap" });
        @export(&comutilOperator32Trap, .{ .name = "comutil_operator_3_2_trap" });
        @export(&comutilOperator40Trap, .{ .name = "comutil_operator_4_0_trap" });
        @export(&comutilOperator41Trap, .{ .name = "comutil_operator_4_1_trap" });
        @export(&comutilOperator42Trap, .{ .name = "comutil_operator_4_2_trap" });
        @export(&comutilOperator43Trap, .{ .name = "comutil_operator_4_3_trap" });
        @export(&comutilOperatorLookupTrap, .{ .name = "comutil_operator_lookup_trap" });
        @export(&compOpLookupTrapRestart, .{ .name = "comp_op_lookup_trap_restart" });
        @export(&makeUuoLink, .{ .name = "make_uuo_link" });
        @export(&coerceToCompiled, .{ .name = "coerce_to_compiled" });
        @export(&trampolineStorage, .{ .name = "trampoline_storage" });

        @export(&bkptInstall, .{ .name = "bkpt_install" });
        @export(&bkptClosureInstall, .{ .name = "bkpt_closure_install" });
        @export(&bkptRemove, .{ .name = "bkpt_remove" });
        @export(&bkptP, .{ .name = "bkpt_p" });
        @export(&bkptProceed, .{ .name = "bkpt_proceed" });
        @export(&doBkptProceed, .{ .name = "do_bkpt_proceed" });
        @export(&comutilCompiledCodeBkpt, .{ .name = "comutil_compiled_code_bkpt" });
        @export(&comutilCompiledClosureBkpt, .{ .name = "comutil_compiled_closure_bkpt" });

        @export(&utilityIndexToName, .{ .name = "utility_index_to_name" });
        @export(&pcToUtilityIndex, .{ .name = "pc_to_utility_index" });
        @export(&declareBuiltin, .{ .name = "declare_builtin" });
        @export(&builtinIndexToName, .{ .name = "builtin_index_to_name" });
        @export(&pcToBuiltinIndex, .{ .name = "pc_to_builtin_index" });
    }
}

test "cmpint format word encode/decode and entry groups" {
    var cet: abi.CcEntryType = undefined;
    var got: abi.CcEntryType = undefined;
    var fw: u16 = 0;

    // Procedures: required, optional, rest_p
    makeCompiledProcedureType(&cet, 2, 3, true);
    try std.testing.expect(!encodeOldStyleFormatWord(&cet, &fw));
    try std.testing.expect(!decodeOldStyleFormatWord(&got, fw));
    try std.testing.expectEqual(abi.CcEntryTypeMarker.procedure, got.marker);
    try std.testing.expectEqual(@as(c_uint, 2), got.args.for_procedure.n_required);
    try std.testing.expectEqual(@as(c_uint, 3), got.args.for_procedure.n_optional);
    try std.testing.expect(got.args.for_procedure.rest_p);
    try std.testing.expectEqual(abi.CcEntryTypeGroup.procedure, ccEntryTypeMarkerGroup(got.marker));

    // Continuation
    makeCompiledContinuationType(&cet, 0x1234);
    try std.testing.expect(!encodeOldStyleFormatWord(&cet, &fw));
    try std.testing.expect(!decodeOldStyleFormatWord(&got, fw));
    try std.testing.expectEqual(abi.CcEntryTypeMarker.continuation, got.marker);
    try std.testing.expectEqual(@as(usize, 0x1234), got.args.for_continuation.offset);
    try std.testing.expectEqual(abi.CcEntryTypeGroup.continuation, ccEntryTypeMarkerGroup(got.marker));

    // All 6 special markers
    const markers = [_]abi.CcEntryTypeMarker{
        .expression,
        .internal_procedure,
        .trampoline,
        .internal_continuation,
        .return_to_interpreter,
        .closure,
    };
    for (markers) |m| {
        makeCcEntryType(&cet, m);
        try std.testing.expect(!encodeOldStyleFormatWord(&cet, &fw));
        try std.testing.expect(!decodeOldStyleFormatWord(&got, fw));
        try std.testing.expectEqual(m, got.marker);
    }

    // Out of range / invalid
    makeCompiledProcedureType(&cet, 0x80, 0, false);
    try std.testing.expect(encodeOldStyleFormatWord(&cet, &fw));
    makeCompiledContinuationType(&cet, 0x3000);
    try std.testing.expect(encodeOldStyleFormatWord(&cet, &fw));
    try std.testing.expect(decodeOldStyleFormatWord(&got, 0x0001));
    try std.testing.expect(decodeOldStyleFormatWord(&got, 0xFE01));
}

test "cmpint linkage markers, reflect frame types, and cpoint offsets" {
    const types = [_]abi.LinkageSectionType{
        .operator,
        .reference,
        .assignment,
        .global_operator,
    };
    for (types) |t| {
        const m = makeLinkageSectionMarker(t, 7);
        try std.testing.expectEqual(@backingInt(t), linkageSectionType(m));
        try std.testing.expectEqual(@as(usize, 7), linkageSectionCount(m));
    }

    var frame: [3]obj.SchemeObject = .{
        obj.makeReturnCode(abi.rc_internal_apply),
        obj.ulongToFixnum(reflect_code_compiled_invocation),
        obj.sharp_f,
    };
    try std.testing.expectEqual(@backingInt(abi.ReturnFrameType.cc_invocation), reflectToInterfaceFrameType(&frame));
    frame[1] = obj.ulongToFixnum(reflect_code_internal_apply);
    try std.testing.expectEqual(@backingInt(abi.ReturnFrameType.cc_internal_apply), reflectToInterfaceFrameType(&frame));
    frame[1] = obj.ulongToFixnum(99);
    try std.testing.expectEqual(@backingInt(abi.ReturnFrameType.undefined), reflectToInterfaceFrameType(&frame));

    var cpoint_words: [12]obj.SchemeObject align(16) = @splat(0);
    cpoint_words[0] = obj.makeVectorHeader(11);
    const cpoint = obj.makePointerObject(obj.tc_control_point, &cpoint_words);
    obj.vectorSet(cpoint, 0, obj.makeReturnCode(abi.rc_reenter_compiled_code));
    try std.testing.expectEqual(@as(usize, abi.cont_size), cpointCompiledCodeNext(cpoint, 0));
    obj.vectorSet(cpoint, 1, obj.makeReturnCode(abi.rc_comp_link_caches_restart));
    try std.testing.expectEqual(@as(usize, 1 + abi.cont_size + 7), cpointCompiledCodeNext(cpoint, 1));
    obj.vectorSet(cpoint, 2, obj.makeReturnCode(abi.rc_comp_assignment_trap_restart));
    try std.testing.expectEqual(@as(usize, 2 + abi.cont_size + 3), cpointCompiledCodeNext(cpoint, 2));
}

test "cmpint stack gaps, lexpr setup, trampoline storage, utilities, and builtins" {
    const test_stubs = @import("../core/test_stubs.zig");
    test_stubs.resetMockRuntime();

    // Test openStackGap & closeStackGap
    abi.stackPush(obj.ulongToFixnum(30));
    abi.stackPush(obj.ulongToFixnum(20));
    abi.stackPush(obj.ulongToFixnum(10));
    openStackGap(2, 1);
    abi.stack_pointer[2] = obj.ulongToFixnum(99);
    try std.testing.expectEqual(obj.ulongToFixnum(10), abi.stackRef(0));
    try std.testing.expectEqual(obj.ulongToFixnum(20), abi.stackRef(1));
    try std.testing.expectEqual(obj.ulongToFixnum(99), abi.stackRef(2));
    try std.testing.expectEqual(obj.ulongToFixnum(30), abi.stackRef(3));
    closeStackGap(2, 1);
    try std.testing.expectEqual(obj.ulongToFixnum(10), abi.stackRef(0));
    try std.testing.expectEqual(obj.ulongToFixnum(20), abi.stackRef(1));
    try std.testing.expectEqual(obj.ulongToFixnum(30), abi.stackRef(2));

    // Test setupLexprInvocation (rest empty + rest consing)
    test_stubs.resetMockRuntime();
    abi.stackPush(obj.ulongToFixnum(2));
    abi.stackPush(obj.ulongToFixnum(1));
    try std.testing.expectEqual(abi.prim_done, setupLexprInvocation(obj.sharp_f, 2, 2));
    try std.testing.expectEqual(obj.ulongToFixnum(1), abi.stackRef(0));
    try std.testing.expectEqual(obj.ulongToFixnum(2), abi.stackRef(1));
    try std.testing.expectEqual(obj.empty_list, abi.stackRef(2));

    test_stubs.resetMockRuntime();
    abi.stackPush(obj.ulongToFixnum(4));
    abi.stackPush(obj.ulongToFixnum(3));
    abi.stackPush(obj.ulongToFixnum(2));
    abi.stackPush(obj.ulongToFixnum(1));
    try std.testing.expectEqual(abi.prim_done, setupLexprInvocation(obj.sharp_f, 4, 2));
    try std.testing.expectEqual(obj.ulongToFixnum(1), abi.stackRef(0));
    try std.testing.expectEqual(obj.ulongToFixnum(2), abi.stackRef(1));
    const rest = abi.stackRef(2);
    try std.testing.expect(obj.pairP(rest));
    try std.testing.expectEqual(obj.ulongToFixnum(3), obj.pairCar(rest));
    const rest2 = obj.pairCdr(rest);
    try std.testing.expectEqual(obj.ulongToFixnum(4), obj.pairCar(rest2));
    try std.testing.expectEqual(obj.empty_list, obj.pairCdr(rest2));

    // Test trampolineStorage on both manifest closure and standard trampoline
    var closure_blk: [7]obj.SchemeObject align(16) = @splat(0);
    closure_blk[0] = obj.makeObject(obj.tc_manifest_closure, 6);
    try std.testing.expectEqual(&closure_blk[4], @as(*obj.SchemeObject, @ptrCast(trampolineStorage(&closure_blk))));
    var std_tramp: [6]obj.SchemeObject align(16) = @splat(0);
    std_tramp[0] = obj.makeObject(tc_trampoline_header, 5);
    std_tramp[1] = obj.makeNmvHeader(2);
    try std.testing.expectEqual(&std_tramp[4], @as(*obj.SchemeObject, @ptrCast(trampolineStorage(&std_tramp))));

    // Test comutil_return_to_interpreter & arity traps
    var res: UtilityResult = std.mem.zeroes(UtilityResult);
    comutilReturnToInterpreter(&res, 0, 0, 0, 0);
    if (!build_options.cc_is_svm) {
        try std.testing.expectEqual(abi.prim_done, res.extra.code_to_interpreter);
    } else {
        try std.testing.expect(!res.scheme_p);
        try std.testing.expectEqual(abi.prim_done, res.arg.interpreter_code);
    }

    var fake_proc_buf: [8]obj.SchemeObject align(16) = @splat(0);
    const fake_entry = makeCcEntry(&fake_proc_buf[4]);
    var trap_store = [2]obj.SchemeObject{ fake_entry, 0 };
    test_stubs.resetMockRuntime();
    abi.stackPush(obj.ulongToFixnum(200));
    abi.stackPush(obj.ulongToFixnum(100));
    comutilOperator32Trap(&res, @intCast(@intFromPtr(&trap_store)), 0, 0, 0);
    try std.testing.expectEqual(obj.ulongToFixnum(100), abi.stackRef(0));
    try std.testing.expectEqual(obj.ulongToFixnum(200), abi.stackRef(1));
    try std.testing.expectEqual(obj.default_object, abi.stackRef(2));

    // Test declare_builtin / builtin_index_to_name / pc_to_builtin_index
    if (builtins) |p| {
        std.c.free(@ptrCast(p));
        builtins = null;
    }
    if (builtin_names) |p| {
        std.c.free(@ptrCast(p));
        builtin_names = null;
    }
    n_builtins = 0;
    s_builtins = 0;

    declareBuiltin(0x3000, "b3");
    declareBuiltin(0x1000, "b1");
    declareBuiltin(0x2000, "b2");
    declareBuiltin(0x2000, "b2_updated");
    try std.testing.expectEqual(@as(c_uint, 3), n_builtins);
    try std.testing.expectEqualStrings("b1", std.mem.span(builtinIndexToName(0).?));
    try std.testing.expectEqualStrings("b2_updated", std.mem.span(builtinIndexToName(1).?));
    try std.testing.expectEqualStrings("b3", std.mem.span(builtinIndexToName(2).?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), builtinIndexToName(3));
    try std.testing.expectEqual(@as(c_int, 0), pcToBuiltinIndex(0x1000));
    try std.testing.expectEqual(@as(c_int, 0), pcToBuiltinIndex(0x1500));
    try std.testing.expectEqual(@as(c_int, 1), pcToBuiltinIndex(0x2000));
    try std.testing.expectEqual(@as(c_int, -1), pcToBuiltinIndex(0x3000));
    try std.testing.expectEqual(@as(c_int, -1), pcToBuiltinIndex(0x0999));

    if (builtins) |p| {
        std.c.free(@ptrCast(p));
        builtins = null;
    }
    if (builtin_names) |p| {
        std.c.free(@ptrCast(p));
        builtin_names = null;
    }
    n_builtins = 0;
    s_builtins = 0;
}
