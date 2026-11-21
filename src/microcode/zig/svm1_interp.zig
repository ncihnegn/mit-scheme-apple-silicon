// Derived from MIT/GNU Scheme C sources (`src/microcode/svm1-interp.c`, `src/microcode/svm1-defns.h`, `src/microcode/cmpintmd/svm1.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const cmpintmd_svm1 = @import("cmpintmd_svm1.zig");
const artutl = @import("artutl.zig");

pub const WordT = obj.SchemeObject;
pub const WregT = u8;
pub const FregT = u8;
pub const TcT = u8;

pub const n_word_registers: usize = 256;
pub const n_float_registers: usize = 256;

pub const reg_interpreter_register_block: WregT = 0;
pub const reg_stack_pointer: WregT = 1;
pub const reg_free_pointer: WregT = 2;
pub const reg_value: WregT = 3;
pub const reg_dynamic_link: WregT = 4;

pub const SvmUtilityResult = extern struct {
    scheme_p: bool,
    arg: extern union {
        interpreter_code: isize,
        new_pc: ?*anyopaque,
    },
};

comptime {
    std.debug.assert(@sizeOf(SvmUtilityResult) == 16);
}

const sbyte: WordT = @sizeOf(u8);
const sword: WordT = @sizeOf(WordT);
const sfloat: WordT = @sizeOf(f64);

const sbyte_s: isize = @intCast(@sizeOf(u8));
const sword_s: isize = @intCast(@sizeOf(WordT));
const sfloat_s: isize = @intCast(@sizeOf(f64));

const type_code_mask_low: WordT = obj.n_type_codes - 1;

const svm_fasl_arch_value: c_uint = blk: {
    const endian = builtin.cpu.arch.endian();
    if (@sizeOf(usize) == 8) {
        break :blk if (endian == .little) 29 else 28; // FASL_SVM1_64LE : FASL_SVM1_64BE
    }
    break :blk if (endian == .little) 27 else 26; // FASL_SVM1_32LE : FASL_SVM1_32BE
};

var svm_fasl_arch_storage: c_uint = svm_fasl_arch_value;

var word_registers: [n_word_registers]WordT = @splat(0);
var float_registers: [n_float_registers]f64 = @splat(0.0);
var svm1_result: isize = 0;
var running_p: bool = false;
var instruction_pointer: ?[*]u8 = null;

extern "c" fn ldexp(f64, c_int) f64;
extern "c" fn fabs(f64) f64;
extern "c" fn sqrt(f64) f64;
extern "c" fn ceil(f64) f64;
extern "c" fn floor(f64) f64;
extern "c" fn log(f64) f64;
extern "c" fn exp(f64) f64;
extern "c" fn cos(f64) f64;
extern "c" fn sin(f64) f64;
extern "c" fn tan(f64) f64;
extern "c" fn acos(f64) f64;
extern "c" fn asin(f64) f64;
extern "c" fn atan(f64) f64;
extern "c" fn atan2(f64, f64) f64;

const UtilId = enum {
    plus,
    decrement,
    divide,
    equal,
    greater,
    increment,
    less,
    modulo,
    multiply,
    negative,
    positive,
    quotient,
    remainder,
    minus,
    zero,
    operator_1_0_trap,
    operator_2_0_trap,
    operator_2_1_trap,
    operator_3_0_trap,
    operator_3_1_trap,
    operator_3_2_trap,
    operator_4_0_trap,
    operator_4_1_trap,
    operator_4_2_trap,
    operator_4_3_trap,
    operator_apply_trap,
    operator_lexpr_trap,
    operator_lookup_trap,
    operator_primitive_trap,
    reflect_to_interface,
    return_to_interpreter,
    @"error",
    primitive_apply,
    primitive_lexpr_apply,
    lookup_trap,
    safe_lookup_trap,
    unassigned_p_trap,
    apply,
    lexpr_apply,
    assignment_trap,
    primitive_error,
    cache_lookup_apply,
    link,
};

const TestMockState = struct {
    var util_calls: usize = 0;
    var last_util: ?UtilId = null;
    var last_args: [4]usize = .{ 0, 0, 0, 0 };
    var next_util_result: SvmUtilityResult = .{
        .scheme_p = false,
        .arg = .{ .interpreter_code = abi.prim_done },
    };
    var interrupt_calls: usize = 0;
    var last_interrupt_entry: ?*anyopaque = null;
    var last_interrupt_state: obj.SchemeObject = 0;
    var next_interrupt_result: SvmUtilityResult = .{
        .scheme_p = false,
        .arg = .{ .interpreter_code = abi.prim_interrupt },
    };
    var mock_trampoline_block: [6]obj.SchemeObject align(16) = @splat(0);

    fn reset() void {
        util_calls = 0;
        last_util = null;
        last_args = .{ 0, 0, 0, 0 };
        next_util_result = .{
            .scheme_p = false,
            .arg = .{ .interpreter_code = abi.prim_done },
        };
        interrupt_calls = 0;
        last_interrupt_entry = null;
        last_interrupt_state = 0;
        next_interrupt_result = .{
            .scheme_p = false,
            .arg = .{ .interpreter_code = abi.prim_interrupt },
        };
        mock_trampoline_block = @splat(0);
    }
};

const SvmRuntime = if (!builtin.is_test and build_options.cc_is_svm) struct {
    extern "c" fn comutil_plus(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_decrement(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_divide(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_equal(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_greater(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_increment(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_less(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_modulo(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_multiply(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_negative(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_positive(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_quotient(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_remainder(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_minus(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_zero(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_1_0_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_2_0_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_2_1_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_3_0_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_3_1_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_3_2_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_4_0_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_4_1_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_4_2_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_4_3_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_apply_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_lexpr_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_lookup_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_operator_primitive_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_reflect_to_interface(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_return_to_interpreter(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_error(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_primitive_apply(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_primitive_lexpr_apply(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_lookup_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_safe_lookup_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_unassigned_p_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_apply(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_lexpr_apply(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_assignment_trap(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_primitive_error(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_cache_lookup_apply(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn comutil_link(*SvmUtilityResult, usize, usize, usize, usize) void;
    extern "c" fn compiler_interrupt_common(*SvmUtilityResult, ?*anyopaque, obj.SchemeObject) void;
    extern "c" fn trampoline_storage([*]obj.SchemeObject) [*]obj.SchemeObject;

    fn callUtil(comptime id: UtilId, result: *SvmUtilityResult, a1: usize, a2: usize, a3: usize, a4: usize) void {
        const proc = comptime switch (id) {
            .plus => comutil_plus,
            .decrement => comutil_decrement,
            .divide => comutil_divide,
            .equal => comutil_equal,
            .greater => comutil_greater,
            .increment => comutil_increment,
            .less => comutil_less,
            .modulo => comutil_modulo,
            .multiply => comutil_multiply,
            .negative => comutil_negative,
            .positive => comutil_positive,
            .quotient => comutil_quotient,
            .remainder => comutil_remainder,
            .minus => comutil_minus,
            .zero => comutil_zero,
            .operator_1_0_trap => comutil_operator_1_0_trap,
            .operator_2_0_trap => comutil_operator_2_0_trap,
            .operator_2_1_trap => comutil_operator_2_1_trap,
            .operator_3_0_trap => comutil_operator_3_0_trap,
            .operator_3_1_trap => comutil_operator_3_1_trap,
            .operator_3_2_trap => comutil_operator_3_2_trap,
            .operator_4_0_trap => comutil_operator_4_0_trap,
            .operator_4_1_trap => comutil_operator_4_1_trap,
            .operator_4_2_trap => comutil_operator_4_2_trap,
            .operator_4_3_trap => comutil_operator_4_3_trap,
            .operator_apply_trap => comutil_operator_apply_trap,
            .operator_lexpr_trap => comutil_operator_lexpr_trap,
            .operator_lookup_trap => comutil_operator_lookup_trap,
            .operator_primitive_trap => comutil_operator_primitive_trap,
            .reflect_to_interface => comutil_reflect_to_interface,
            .return_to_interpreter => comutil_return_to_interpreter,
            .@"error" => comutil_error,
            .primitive_apply => comutil_primitive_apply,
            .primitive_lexpr_apply => comutil_primitive_lexpr_apply,
            .lookup_trap => comutil_lookup_trap,
            .safe_lookup_trap => comutil_safe_lookup_trap,
            .unassigned_p_trap => comutil_unassigned_p_trap,
            .apply => comutil_apply,
            .lexpr_apply => comutil_lexpr_apply,
            .assignment_trap => comutil_assignment_trap,
            .primitive_error => comutil_primitive_error,
            .cache_lookup_apply => comutil_cache_lookup_apply,
            .link => comutil_link,
        };
        proc(result, a1, a2, a3, a4);
    }

    fn callInterruptCommon(result: *SvmUtilityResult, entry_addr: ?*anyopaque, state: obj.SchemeObject) void {
        compiler_interrupt_common(result, entry_addr, state);
    }

    fn callTrampolineStorage(entry_addr: [*]u8) usize {
        const block = abi.cc_entry_address_to_block_address(@ptrCast(entry_addr));
        return @intCast(@intFromPtr(trampoline_storage(block)));
    }
} else struct {
    fn callUtil(comptime id: UtilId, result: *SvmUtilityResult, a1: usize, a2: usize, a3: usize, a4: usize) void {
        TestMockState.util_calls += 1;
        TestMockState.last_util = id;
        TestMockState.last_args = .{ a1, a2, a3, a4 };
        result.* = TestMockState.next_util_result;
    }

    fn callInterruptCommon(result: *SvmUtilityResult, entry_addr: ?*anyopaque, state: obj.SchemeObject) void {
        TestMockState.interrupt_calls += 1;
        TestMockState.last_interrupt_entry = entry_addr;
        TestMockState.last_interrupt_state = state;
        result.* = TestMockState.next_interrupt_result;
    }

    fn callTrampolineStorage(entry_addr: [*]u8) usize {
        TestMockState.mock_trampoline_block[0] = @intFromPtr(entry_addr);
        return @intCast(@intFromPtr(&TestMockState.mock_trampoline_block[2]));
    }
};

inline fn wregRef(wr: WregT) WordT {
    return word_registers[wr];
}

inline fn wregSet(wr: WregT, w: WordT) void {
    word_registers[wr] = w;
}

inline fn fregRef(fr: FregT) f64 {
    return float_registers[fr];
}

inline fn fregSet(fr: FregT, f: f64) void {
    float_registers[fr] = f;
}

inline fn importRegs() void {
    wregSet(reg_stack_pointer, @intFromPtr(abi.stack_pointer));
    wregSet(reg_free_pointer, @intFromPtr(abi.Free));
    const val = abi.Registers[abi.regblock_val];
    wregSet(reg_value, val);
    wregSet(reg_dynamic_link, obj.datumToRawAddress(obj.objectDatum(val)));
}

inline fn exportRegs() void {
    abi.stack_pointer = @ptrFromInt(wregRef(reg_stack_pointer));
    abi.Free = @ptrFromInt(wregRef(reg_free_pointer));
    abi.Registers[abi.regblock_val] = wregRef(reg_value);
}

/// Initialize SVM1 interpreter register banks and point register 0 at `Registers`.
pub fn initializeSvm1() callconv(.c) void {
    word_registers = @splat(0);
    float_registers = @splat(0.0);
    wregSet(reg_interpreter_register_block, @intFromPtr(&abi.Registers));
}

/// Execute SVM1 bytecode starting at `address` until returning to C/interpreter.
pub fn cToInterface(address: ?*anyopaque) callconv(.c) isize {
    instruction_pointer = if (address) |a| @ptrCast(a) else null;
    importRegs();
    running_p = true;
    while (instruction_pointer) |ip| {
        const opcode = ip[0];
        instruction_pointer = inst_defns[opcode](ip + 1);
    }
    exportRegs();
    running_p = false;
    return svm1_result;
}

/// Export SVM1 VM registers and return the active bytecode IP when running, else `pc`.
pub fn svmExportInstructionPointer(pc: usize) callconv(.c) usize {
    if (running_p) {
        exportRegs();
        return @intFromPtr(instruction_pointer);
    }
    return pc;
}

inline fn exitVm(code: isize) ?[*]u8 {
    svm1_result = code;
    return null;
}

inline fn ill() ?[*]u8 {
    return exitVm(abi.err_compiled_code_error);
}

inline fn offsetPc(pc: [*]u8, offset: isize) [*]u8 {
    const addr = @intFromPtr(pc) +% @as(usize, @bitCast(offset));
    return @ptrFromInt(addr);
}

fn illegalInstruction(pc: [*]u8) ?[*]u8 {
    _ = pc;
    return ill();
}

fn illegalAddress(pc: [*]u8, address: *WordT) ?[*]u8 {
    _ = pc;
    _ = address;
    return null;
}

fn illegalTrap0(pc: [*]u8) ?[*]u8 {
    _ = pc;
    return ill();
}

fn illegalTrap1(pc: [*]u8, r1: WregT) ?[*]u8 {
    _ = pc;
    _ = r1;
    return ill();
}

fn illegalTrap2(pc: [*]u8, r1: WregT, r2: WregT) ?[*]u8 {
    _ = pc;
    _ = r1;
    _ = r2;
    return ill();
}

fn illegalTrap3(pc: [*]u8, r1: WregT, r2: WregT, r3: WregT) ?[*]u8 {
    _ = pc;
    _ = r1;
    _ = r2;
    _ = r3;
    return ill();
}

// Primitive operand decoders

inline fn decodeTypeWord(pc: [*]u8, tc: *TcT) ?[*]u8 {
    const b = pc[0];
    if (!(b <= obj.n_type_codes)) return null;
    tc.* = b;
    return pc + 1;
}

inline fn readU16Le(pc: [*]const u8) u16 {
    return @as(u16, pc[0]) | (@as(u16, pc[1]) << 8);
}

inline fn readU32Le(pc: [*]const u8) u32 {
    return @as(u32, pc[0]) |
        (@as(u32, pc[1]) << 8) |
        (@as(u32, pc[2]) << 16) |
        (@as(u32, pc[3]) << 24);
}

inline fn readU64Le(pc: [*]const u8) u64 {
    return @as(u64, pc[0]) |
        (@as(u64, pc[1]) << 8) |
        (@as(u64, pc[2]) << 16) |
        (@as(u64, pc[3]) << 24) |
        (@as(u64, pc[4]) << 32) |
        (@as(u64, pc[5]) << 40) |
        (@as(u64, pc[6]) << 48) |
        (@as(u64, pc[7]) << 56);
}

inline fn decodeS8(pc: [*]const u8) struct { pc: [*]u8, val: isize } {
    const signed: i8 = @bitCast(pc[0]);
    return .{ .pc = @constCast(pc + 1), .val = signed };
}

inline fn decodeS16(pc: [*]const u8) struct { pc: [*]u8, val: isize } {
    const signed: i16 = @bitCast(readU16Le(pc));
    return .{ .pc = @constCast(pc + 2), .val = signed };
}

inline fn decodeS32(pc: [*]const u8) struct { pc: [*]u8, val: isize } {
    const signed: i32 = @bitCast(readU32Le(pc));
    return .{ .pc = @constCast(pc + 4), .val = signed };
}

inline fn decodeFloat(pc: [*]const u8) struct { pc: [*]u8, val: f64 } {
    const sig: i64 = @bitCast(readU64Le(pc));
    const exp_signed: i16 = @bitCast(readU16Le(pc + 8));
    const val = ldexp(@floatFromInt(sig), @intCast(exp_signed));
    return .{ .pc = @constCast(pc + 10), .val = val };
}

const ImmKind = enum { s8, s16, s32, u8, u16, u32 };
const SignedWidth = enum { s8, s16, s32 };
const UnsignedWidth = enum { u8, u16, u32 };

inline fn decodeImmWord(pc: [*]u8, comptime kind: ImmKind) struct { pc: [*]u8, val: WordT } {
    return switch (kind) {
        .s8 => blk: {
            const d = decodeS8(pc);
            break :blk .{ .pc = d.pc, .val = @bitCast(d.val) };
        },
        .s16 => blk: {
            const d = decodeS16(pc);
            break :blk .{ .pc = d.pc, .val = @bitCast(d.val) };
        },
        .s32 => blk: {
            const d = decodeS32(pc);
            break :blk .{ .pc = d.pc, .val = @bitCast(d.val) };
        },
        .u8 => .{ .pc = pc + 1, .val = pc[0] },
        .u16 => .{ .pc = pc + 2, .val = readU16Le(pc) },
        .u32 => .{ .pc = pc + 4, .val = readU32Le(pc) },
    };
}

inline fn decodeSignedOffset(pc: [*]u8, comptime kind: SignedWidth) struct { pc: [*]u8, val: isize } {
    return switch (kind) {
        .s8 => blk: {
            const d = decodeS8(pc);
            break :blk .{ .pc = d.pc, .val = @intCast(d.val) };
        },
        .s16 => blk: {
            const d = decodeS16(pc);
            break :blk .{ .pc = d.pc, .val = @intCast(d.val) };
        },
        .s32 => blk: {
            const d = decodeS32(pc);
            break :blk .{ .pc = d.pc, .val = @intCast(d.val) };
        },
    };
}

inline fn decodeUnsignedOffset(pc: [*]u8, comptime kind: UnsignedWidth) struct { pc: [*]u8, val: isize } {
    return switch (kind) {
        .u8 => .{ .pc = pc + 1, .val = pc[0] },
        .u16 => .{ .pc = pc + 2, .val = readU16Le(pc) },
        .u32 => .{ .pc = pc + 4, .val = readU32Le(pc) },
    };
}

// Address decoding

inline fn decodeAddress(pc: [*]u8, address: *WordT) ?[*]u8 {
    const code = pc[0];
    return address_decoders[code](pc + 1, address);
}

fn decodeAddrIndir(pc: [*]u8, address: *WordT) ?[*]u8 {
    const base = pc[0];
    address.* = wregRef(base);
    return pc + 1;
}

fn makeOffsetAddrDecoder(comptime width: ImmKind, comptime scale: WordT) AddrFn {
    return struct {
        fn decode(pc: [*]u8, address: *WordT) ?[*]u8 {
            const base = pc[0];
            const off = decodeImmWord(pc + 1, width);
            address.* = wregRef(base) +% (off.val *% scale);
            return off.pc;
        }
    }.decode;
}

fn makeIndexAddrDecoder(comptime oscale: WordT, comptime iscale: WordT) AddrFn {
    return struct {
        fn decode(pc: [*]u8, address: *WordT) ?[*]u8 {
            const base = pc[0];
            const offset: WordT = pc[1];
            const index = pc[2];
            address.* = wregRef(base) +% (offset *% oscale) +% (wregRef(index) *% iscale);
            return pc + 3;
        }
    }.decode;
}

fn makePreincAddrDecoder(comptime incr: isize) AddrFn {
    return struct {
        fn decode(pc: [*]u8, address: *WordT) ?[*]u8 {
            const base = pc[0];
            const updated = wregRef(base) +% @as(WordT, @bitCast(incr));
            wregSet(base, updated);
            address.* = updated;
            return pc + 1;
        }
    }.decode;
}

fn makePostincAddrDecoder(comptime incr: isize) AddrFn {
    return struct {
        fn decode(pc: [*]u8, address: *WordT) ?[*]u8 {
            const base = pc[0];
            const val = wregRef(base);
            wregSet(base, val +% @as(WordT, @bitCast(incr)));
            address.* = val;
            return pc + 1;
        }
    }.decode;
}

fn makePcrAddrDecoder(comptime width: ImmKind) AddrFn {
    return struct {
        fn decode(pc: [*]u8, address: *WordT) ?[*]u8 {
            const off = decodeImmWord(pc, width);
            address.* = @as(WordT, @intFromPtr(off.pc)) +% off.val;
            return off.pc;
        }
    }.decode;
}

// Memory access & immediate instructions

fn insnStoreBWrAddr(pc_in: [*]u8) ?[*]u8 {
    const source = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    @as(*u8, @ptrFromInt(addr)).* = @truncate(wregRef(source) & 0xFF);
    return pc;
}

fn insnStoreWWrAddr(pc_in: [*]u8) ?[*]u8 {
    const source = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    @as(*align(1) WordT, @ptrFromInt(addr)).* = wregRef(source);
    return pc;
}

fn insnStoreFFrAddr(pc_in: [*]u8) ?[*]u8 {
    const source = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    @as(*align(1) f64, @ptrFromInt(addr)).* = fregRef(source);
    return pc;
}

fn insnLoadBWrAddr(pc_in: [*]u8) ?[*]u8 {
    const target = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    wregSet(target, @as(*const u8, @ptrFromInt(addr)).*);
    return pc;
}

fn insnLoadWWrAddr(pc_in: [*]u8) ?[*]u8 {
    const target = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    wregSet(target, @as(*align(1) const WordT, @ptrFromInt(addr)).*);
    return pc;
}

fn insnLoadFFrAddr(pc_in: [*]u8) ?[*]u8 {
    const target = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    fregSet(target, @as(*align(1) const f64, @ptrFromInt(addr)).*);
    return pc;
}

fn insnLoadAddressAddr(pc_in: [*]u8) ?[*]u8 {
    const target = pc_in[0];
    var addr: WordT = 0;
    const pc = decodeAddress(pc_in + 1, &addr) orelse return ill();
    wregSet(target, addr);
    return pc;
}

fn makeLoadImmediateWr(comptime width: ImmKind) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const d = decodeImmWord(pc + 1, width);
            wregSet(target, d.val);
            return d.pc;
        }
    }.exec;
}

fn insnLoadImmediateFrFlt(pc: [*]u8) ?[*]u8 {
    const target = pc[0];
    const d = decodeFloat(pc + 1);
    fregSet(target, d.val);
    return d.pc;
}

// Scheme object construction

inline fn xMakeObject(t: WordT, d: WordT) WordT {
    return obj.makeObject(t & type_code_mask_low, d & obj.datum_mask);
}

inline fn xMakePtr(t: WordT, addr: WordT) WordT {
    return xMakeObject(t, obj.rawAddressToDatum(@intCast(addr)));
}

inline fn xObjectAddress(o: WordT) WordT {
    return obj.datumToRawAddress(obj.objectDatum(o));
}

inline fn xFixnumToLong(o: WordT) WordT {
    const shifted: isize = @bitCast(o << obj.type_code_length);
    return @bitCast(shifted >> obj.type_code_length);
}

fn makeLoadNonPointerTcImm(comptime width: ImmKind) InstFn {
    return struct {
        fn exec(pc_in: [*]u8) ?[*]u8 {
            const target = pc_in[0];
            var tc: TcT = 0;
            const pc = decodeTypeWord(pc_in + 1, &tc) orelse return ill();
            const d = decodeImmWord(pc, width);
            wregSet(target, xMakeObject(tc, d.val));
            return d.pc;
        }
    }.exec;
}

fn makeLoadNonPointerWrImm(comptime width: ImmKind) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const src = pc[1];
            const d = decodeImmWord(pc + 2, width);
            wregSet(target, xMakeObject(wregRef(src), d.val));
            return d.pc;
        }
    }.exec;
}

fn insnLoadNonPointerTcWr(pc_in: [*]u8) ?[*]u8 {
    const target = pc_in[0];
    var tc: TcT = 0;
    const pc = decodeTypeWord(pc_in + 1, &tc) orelse return ill();
    const datum_reg = pc[0];
    wregSet(target, xMakeObject(tc, wregRef(datum_reg)));
    return pc + 1;
}

fn insnLoadNonPointer(pc: [*]u8) ?[*]u8 {
    const target = pc[0];
    const tc_reg = pc[1];
    const datum_reg = pc[2];
    wregSet(target, xMakeObject(wregRef(tc_reg), wregRef(datum_reg)));
    return pc + 3;
}

fn insnLoadPointerTcWr(pc_in: [*]u8) ?[*]u8 {
    const target = pc_in[0];
    var tc: TcT = 0;
    const pc = decodeTypeWord(pc_in + 1, &tc) orelse return ill();
    const addr_reg = pc[0];
    wregSet(target, xMakePtr(tc, wregRef(addr_reg)));
    return pc + 1;
}

fn insnLoadPointer(pc: [*]u8) ?[*]u8 {
    const target = pc[0];
    const tc_reg = pc[1];
    const addr_reg = pc[2];
    wregSet(target, xMakePtr(wregRef(tc_reg), wregRef(addr_reg)));
    return pc + 3;
}

// Block copy

fn copyBlock(to_addr: WordT, from_addr: WordT, n_words: WordT) void {
    const count: usize = @intCast(n_words);
    if (count == 0 or to_addr == from_addr) return;
    const to_ptr: [*]align(1) WordT = @ptrFromInt(to_addr);
    const from_ptr: [*]align(1) const WordT = @ptrFromInt(from_addr);
    if (to_addr > from_addr) {
        var i = count;
        while (i > 0) {
            i -= 1;
            to_ptr[i] = from_ptr[i];
        }
    } else {
        for (0..count) |i| {
            to_ptr[i] = from_ptr[i];
        }
    }
}

fn insnCopyBlockU8W(pc: [*]u8) ?[*]u8 {
    copyBlock(wregRef(pc[0]), wregRef(pc[1]), pc[2]);
    return pc + 3;
}

fn insnCopyBlockWrW(pc: [*]u8) ?[*]u8 {
    copyBlock(wregRef(pc[0]), wregRef(pc[1]), wregRef(pc[2]));
    return pc + 3;
}

// Unconditional jumps and stack helpers

fn makeJumpPcr(comptime width: SignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const off = decodeSignedOffset(pc, width);
            return offsetPc(off.pc, off.val);
        }
    }.exec;
}

fn insnJumpIndirWr(pc: [*]u8) ?[*]u8 {
    return @ptrFromInt(wregRef(pc[0]));
}

inline fn ijumpTarget(pc: [*]u8, offset: isize) [*]u8 {
    const slot_ptr: *align(1) const obj.SchemeObject = @ptrCast(offsetPc(pc, offset));
    return @ptrFromInt(obj.datumToRawAddress(obj.objectDatum(slot_ptr.*)));
}

inline fn pushObject(object: obj.SchemeObject) void {
    var sp: [*]obj.SchemeObject = @ptrFromInt(wregRef(reg_stack_pointer));
    sp -= 1;
    sp[0] = object;
    wregSet(reg_stack_pointer, @intFromPtr(sp));
}

inline fn popObject() obj.SchemeObject {
    var sp: [*]obj.SchemeObject = @ptrFromInt(wregRef(reg_stack_pointer));
    const object = sp[0];
    sp += 1;
    wregSet(reg_stack_pointer, @intFromPtr(sp));
    return object;
}

inline fn makeCcEntryAddr(addr: [*]const u8) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(@intFromPtr(addr)));
}

fn makeIjump(comptime width: UnsignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const off = decodeUnsignedOffset(pc, width);
            return ijumpTarget(off.pc, off.val);
        }
    }.exec;
}

fn makeIcall(comptime width: UnsignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const off = decodeUnsignedOffset(pc, width);
            pushObject(makeCcEntryAddr(off.pc + cmpintmd_svm1.cc_entry_header_size));
            return ijumpTarget(off.pc, off.val);
        }
    }.exec;
}

fn insnPopReturn(pc: [*]u8) ?[*]u8 {
    _ = pc;
    return @ptrFromInt(obj.datumToRawAddress(obj.objectDatum(popObject())));
}

// Conditional jumps

const WrCmpOp = enum { eq, neq, lt, le, gt, ge, slt, sle, sgt, sge };
const FrCmpOp = enum { eq, neq, lt, le, gt, ge, cmp, ncmp };
const FixCmpOp = enum { fix, nfix, ifix, nifix };

inline fn evalWrCmp(comptime op: WrCmpOp, a: WordT, b: WordT) bool {
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        .slt => @as(isize, @bitCast(a)) < @as(isize, @bitCast(b)),
        .sle => @as(isize, @bitCast(a)) <= @as(isize, @bitCast(b)),
        .sgt => @as(isize, @bitCast(a)) > @as(isize, @bitCast(b)),
        .sge => @as(isize, @bitCast(a)) >= @as(isize, @bitCast(b)),
    };
}

inline fn evalFrCmp(comptime op: FrCmpOp, a: f64, b: f64) bool {
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        .cmp => (a < b) or (a > b) or (a == b),
        .ncmp => !((a < b) or (a > b) or (a == b)),
    };
}

inline fn evalFixCmp(comptime op: FixCmpOp, a: WordT) bool {
    const fix_p = obj.longToFixnumP(@bitCast(a));
    const ifix_p = (a & obj.sign_mask) == obj.makeObject(obj.tc_fixnum, 0);
    return switch (op) {
        .fix => fix_p,
        .nfix => !fix_p,
        .ifix => ifix_p,
        .nifix => !ifix_p,
    };
}

fn makeCjumpWrWr(comptime op: WrCmpOp, comptime width: SignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const s1 = pc[0];
            const s2 = pc[1];
            const off = decodeSignedOffset(pc + 2, width);
            return if (evalWrCmp(op, wregRef(s1), wregRef(s2))) offsetPc(off.pc, off.val) else off.pc;
        }
    }.exec;
}

fn makeCjumpWr(comptime op: WrCmpOp, comptime width: SignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const s1 = pc[0];
            const off = decodeSignedOffset(pc + 1, width);
            return if (evalWrCmp(op, wregRef(s1), 0)) offsetPc(off.pc, off.val) else off.pc;
        }
    }.exec;
}

fn makeCjumpFixWr(comptime op: FixCmpOp, comptime width: SignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const s1 = pc[0];
            const off = decodeSignedOffset(pc + 1, width);
            return if (evalFixCmp(op, wregRef(s1))) offsetPc(off.pc, off.val) else off.pc;
        }
    }.exec;
}

fn makeCjumpFrFr(comptime op: FrCmpOp, comptime width: SignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const s1 = pc[0];
            const s2 = pc[1];
            const off = decodeSignedOffset(pc + 2, width);
            return if (evalFrCmp(op, fregRef(s1), fregRef(s2))) offsetPc(off.pc, off.val) else off.pc;
        }
    }.exec;
}

fn makeCjumpFr(comptime op: FrCmpOp, comptime width: SignedWidth) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const s1 = pc[0];
            const off = decodeSignedOffset(pc + 1, width);
            return if (evalFrCmp(op, fregRef(s1), 0.0)) offsetPc(off.pc, off.val) else off.pc;
        }
    }.exec;
}

// Traps and interrupt tests

inline fn dispatchTrapResult(result: *const SvmUtilityResult) ?[*]u8 {
    importRegs();
    running_p = true;
    if (result.scheme_p) {
        return @ptrCast(result.arg.new_pc);
    }
    return exitVm(result.arg.interpreter_code);
}

fn insnTrapTrap0(pc: [*]u8) ?[*]u8 {
    const code = pc[0];
    return traps_0[code](pc + 1);
}

fn insnTrapTrap1Wr(pc: [*]u8) ?[*]u8 {
    const code = pc[0];
    const r1 = pc[1];
    return traps_1[code](pc + 2, r1);
}

fn insnTrapTrap2Wr(pc: [*]u8) ?[*]u8 {
    const code = pc[0];
    const r1 = pc[1];
    const r2 = pc[2];
    return traps_2[code](pc + 3, r1, r2);
}

fn insnTrapTrap3Wr(pc: [*]u8) ?[*]u8 {
    const code = pc[0];
    const r1 = pc[1];
    const r2 = pc[2];
    const r3 = pc[3];
    return traps_3[code](pc + 4, r1, r2, r3);
}

fn makeTrap0(comptime id: UtilId) Trap0Fn {
    return struct {
        fn trap(pc: [*]u8) ?[*]u8 {
            _ = pc;
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(id, &result, 0, 0, 0, 0);
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrampoline(comptime id: UtilId) Trap0Fn {
    return struct {
        fn trap(pc: [*]u8) ?[*]u8 {
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            const store = SvmRuntime.callTrampolineStorage(pc - 2);
            SvmRuntime.callUtil(id, &result, store, 0, 0, 0);
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrap1(comptime id: UtilId) Trap1Fn {
    return struct {
        fn trap(pc: [*]u8, source1: WregT) ?[*]u8 {
            _ = pc;
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(id, &result, @intCast(wregRef(source1)), 0, 0, 0);
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrapR1(comptime id: UtilId) Trap1Fn {
    return struct {
        fn trap(pc: [*]u8, source1: WregT) ?[*]u8 {
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(
                id,
                &result,
                @intCast(@intFromPtr(pc + cmpintmd_svm1.cc_entry_header_size)),
                @intCast(wregRef(source1)),
                0,
                0,
            );
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrap2(comptime id: UtilId) Trap2Fn {
    return struct {
        fn trap(pc: [*]u8, source1: WregT, source2: WregT) ?[*]u8 {
            _ = pc;
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(id, &result, @intCast(wregRef(source1)), @intCast(wregRef(source2)), 0, 0);
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrapR2(comptime id: UtilId) Trap2Fn {
    return struct {
        fn trap(pc: [*]u8, source1: WregT, source2: WregT) ?[*]u8 {
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(
                id,
                &result,
                @intCast(@intFromPtr(pc + cmpintmd_svm1.cc_entry_header_size)),
                @intCast(wregRef(source1)),
                @intCast(wregRef(source2)),
                0,
            );
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrap3(comptime id: UtilId) Trap3Fn {
    return struct {
        fn trap(pc: [*]u8, source1: WregT, source2: WregT, source3: WregT) ?[*]u8 {
            _ = pc;
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(
                id,
                &result,
                @intCast(wregRef(source1)),
                @intCast(wregRef(source2)),
                @intCast(wregRef(source3)),
                0,
            );
            return dispatchTrapResult(&result);
        }
    }.trap;
}

fn makeTrapR3(comptime id: UtilId) Trap3Fn {
    return struct {
        fn trap(pc: [*]u8, source1: WregT, source2: WregT, source3: WregT) ?[*]u8 {
            var result: SvmUtilityResult = undefined;
            exportRegs();
            running_p = false;
            SvmRuntime.callUtil(
                id,
                &result,
                @intCast(@intFromPtr(pc + cmpintmd_svm1.cc_entry_header_size)),
                @intCast(wregRef(source1)),
                @intCast(wregRef(source2)),
                @intCast(wregRef(source3)),
            );
            return dispatchTrapResult(&result);
        }
    }.trap;
}

inline fn interruptTest() bool {
    return wregRef(reg_free_pointer) >= abi.Registers[abi.regblock_memtop] or
        wregRef(reg_stack_pointer) < abi.Registers[abi.regblock_stack_guard];
}

const InterruptTestKind = enum { procedure, ic_procedure, continuation, dynamic_link };

fn makeInterruptTest(comptime kind: InterruptTestKind) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            if (interruptTest()) {
                var result: SvmUtilityResult = undefined;
                exportRegs();
                running_p = false;
                const entry_arg: ?*anyopaque = switch (kind) {
                    .procedure, .ic_procedure, .dynamic_link => @ptrCast(pc - 1),
                    .continuation => null,
                };
                const state_arg: obj.SchemeObject = switch (kind) {
                    .procedure => obj.sharp_f,
                    .ic_procedure => abi.Registers[abi.regblock_env],
                    .continuation => abi.Registers[abi.regblock_val],
                    .dynamic_link => obj.makeObject(
                        obj.tc_stack_environment,
                        obj.rawAddressToDatum(wregRef(reg_dynamic_link)),
                    ),
                };
                SvmRuntime.callInterruptCommon(&result, entry_arg, state_arg);
                return dispatchTrapResult(&result);
            }
            return pc;
        }
    }.exec;
}

fn insnEnterClosure(pc_in: [*]u8) ?[*]u8 {
    const index: usize = readU16Le(pc_in);
    const pc = pc_in + 2;
    if (interruptTest()) {
        var result: SvmUtilityResult = undefined;
        exportRegs();
        running_p = false;
        SvmRuntime.callInterruptCommon(&result, @ptrCast(pc - 3), obj.sharp_f);
        return dispatchTrapResult(&result);
    }
    const block = pc - (cmpintmd_svm1.closure_entry_start + ((index + 1) * cmpintmd_svm1.closure_entry_size));
    const count: usize = @intCast(cmpintmd_svm1.readU16(block));
    const targets = cmpintmd_svm1.skipCompiledClosurePadding(
        block + (cmpintmd_svm1.closure_entry_start + (count * cmpintmd_svm1.closure_entry_size)),
    );
    pushObject(makeCcEntryAddr(block + cmpintmd_svm1.closure_entry_offset));
    return @ptrFromInt(obj.datumToRawAddress(obj.objectDatum(targets[index])));
}

// Flonum headers and alignment

fn makeFlonumHeaderImm(comptime width: ImmKind) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const d = decodeImmWord(pc + 1, width);
            wregSet(target, xMakeObject(obj.tc_manifest_nm_vector, obj.flonum_size *% d.val));
            return d.pc;
        }
    }.exec;
}

fn insnFlonumHeader(pc: [*]u8) ?[*]u8 {
    const target = pc[0];
    const source = pc[1];
    wregSet(target, xMakeObject(obj.tc_manifest_nm_vector, obj.flonum_size *% wregRef(source)));
    return pc + 2;
}

fn insnFlonumAlign(pc: [*]u8) ?[*]u8 {
    const target = pc[0];
    const source = pc[1];
    if (comptime obj.floating_alignment == 0) {
        wregSet(target, wregRef(source));
    } else {
        var p: [*]obj.SchemeObject = @ptrFromInt(wregRef(source));
        obj.alignFloat(&p);
        wregSet(target, @intFromPtr(p));
    }
    return pc + 2;
}

// Word & float ALU operations

fn opNegateWr(x: WordT) WordT {
    const s: isize = @bitCast(x);
    return @bitCast(-%s);
}

fn opIncrementWr(x: WordT) WordT {
    return x +% 1;
}

fn opDecrementWr(x: WordT) WordT {
    return x -% 1;
}

fn opAbsWr(x: WordT) WordT {
    const s: isize = @bitCast(x);
    return if (s < 0) @bitCast(-%s) else x;
}

fn opNot(x: WordT) WordT {
    return ~x;
}

fn opIntegerToFixnum(x: WordT) WordT {
    return obj.longToFixnum(@bitCast(x));
}

fn opAddWr(a: WordT, b: WordT) WordT {
    return a +% b;
}

fn opSubtractWr(a: WordT, b: WordT) WordT {
    return a -% b;
}

fn opMultiplyWr(a: WordT, b: WordT) WordT {
    return a *% b;
}

fn opProductWr(a: WordT, b: WordT) WordT {
    const x: isize = @bitCast(a);
    const y: isize = @bitCast(b);
    const ans = abi.Mul(obj.longToFixnum(x), obj.longToFixnum(y));
    if (ans == obj.sharp_f) return obj.sharp_t;
    return @bitCast(obj.fixnumToLong(ans));
}

fn opQuotientWr(a: WordT, b: WordT) WordT {
    const n1: isize = @bitCast(a);
    const n2: isize = @bitCast(b);
    if (n1 == std.math.minInt(isize) and n2 == -1) return @bitCast(n1);
    return @bitCast(@divTrunc(n1, n2));
}

fn opRemainderWr(a: WordT, b: WordT) WordT {
    const n1: isize = @bitCast(a);
    const n2: isize = @bitCast(b);
    if (n1 == std.math.minInt(isize) and n2 == -1) return 0;
    return @bitCast(@rem(n1, n2));
}

fn opLshWr(a: WordT, b: WordT) WordT {
    const source: isize = @bitCast(a);
    const number: isize = @bitCast(b);
    if (number >= 0) {
        const shift: u64 = @intCast(number);
        if (shift > obj.datum_length) return 0;
        return a << @intCast(shift);
    }
    const shift = @abs(number);
    if (shift > obj.datum_length) return 0;
    const sh: std.math.Log2Int(WordT) = @intCast(shift);
    return if (source < 0) ~((~a) >> sh) else (a >> sh);
}

fn opAndWr(a: WordT, b: WordT) WordT {
    return a & b;
}

fn opAndcWr(a: WordT, b: WordT) WordT {
    return a & ~b;
}

fn opOrWr(a: WordT, b: WordT) WordT {
    return a | b;
}

fn opXorWr(a: WordT, b: WordT) WordT {
    return a ^ b;
}

fn opMaxUnsigned(a: WordT, b: WordT) WordT {
    return if (a > b) a else b;
}

fn opMinUnsigned(a: WordT, b: WordT) WordT {
    return if (a < b) a else b;
}

fn opCopyFr(x: f64) f64 {
    return x;
}

fn opNegateFr(x: f64) f64 {
    return -x;
}

fn opIncrementFr(x: f64) f64 {
    return x + 1.0;
}

fn opDecrementFr(x: f64) f64 {
    return x - 1.0;
}

fn opAddFr(a: f64, b: f64) f64 {
    return a + b;
}

fn opSubtractFr(a: f64, b: f64) f64 {
    return a - b;
}

fn opMultiplyFr(a: f64, b: f64) f64 {
    return a * b;
}

fn opDivideFr(a: f64, b: f64) f64 {
    return a / b;
}

fn makeUnaryWr(comptime op: fn (WordT) callconv(.@"inline") WordT) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source = pc[1];
            wregSet(target, op(wregRef(source)));
            return pc + 2;
        }
    }.exec;
}

fn makeUnaryWrFn(comptime op: *const fn (WordT) WordT) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source = pc[1];
            wregSet(target, op(wregRef(source)));
            return pc + 2;
        }
    }.exec;
}

fn makeUnaryFr(comptime op: *const fn (f64) f64) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source = pc[1];
            fregSet(target, op(fregRef(source)));
            return pc + 2;
        }
    }.exec;
}

fn makeUnaryFrC(comptime op: *const fn (f64) callconv(.c) f64) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source = pc[1];
            fregSet(target, op(fregRef(source)));
            return pc + 2;
        }
    }.exec;
}

fn makeBinaryWr(comptime op: *const fn (WordT, WordT) WordT) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source1 = pc[1];
            const source2 = pc[2];
            wregSet(target, op(wregRef(source1), wregRef(source2)));
            return pc + 3;
        }
    }.exec;
}

fn makeBinaryFr(comptime op: *const fn (f64, f64) f64) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source1 = pc[1];
            const source2 = pc[2];
            fregSet(target, op(fregRef(source1), fregRef(source2)));
            return pc + 3;
        }
    }.exec;
}

fn makeBinaryFrC(comptime op: *const fn (f64, f64) callconv(.c) f64) InstFn {
    return struct {
        fn exec(pc: [*]u8) ?[*]u8 {
            const target = pc[0];
            const source1 = pc[1];
            const source2 = pc[2];
            fregSet(target, op(fregRef(source1), fregRef(source2)));
            return pc + 3;
        }
    }.exec;
}

fn insnCopyWr(pc: [*]u8) ?[*]u8 {
    wregSet(pc[0], wregRef(pc[1]));
    return pc + 2;
}

// Dispatch tables (comptime initialized matching src/microcode/svm1-defns.h)

const InstFn = *const fn ([*]u8) ?[*]u8;
const AddrFn = *const fn ([*]u8, *WordT) ?[*]u8;
const Trap0Fn = *const fn ([*]u8) ?[*]u8;
const Trap1Fn = *const fn ([*]u8, WregT) ?[*]u8;
const Trap2Fn = *const fn ([*]u8, WregT, WregT) ?[*]u8;
const Trap3Fn = *const fn ([*]u8, WregT, WregT, WregT) ?[*]u8;

const address_decoders: [256]AddrFn = blk: {
    var t: [256]AddrFn = @splat(illegalAddress);
    t[0x01] = decodeAddrIndir;
    t[0x02] = makeOffsetAddrDecoder(.s8, sbyte);
    t[0x03] = makeOffsetAddrDecoder(.s8, sword);
    t[0x04] = makeOffsetAddrDecoder(.s8, sfloat);
    t[0x05] = makeOffsetAddrDecoder(.s16, sbyte);
    t[0x06] = makeOffsetAddrDecoder(.s16, sword);
    t[0x07] = makeOffsetAddrDecoder(.s16, sfloat);
    t[0x08] = makeOffsetAddrDecoder(.s32, sbyte);
    t[0x09] = makeOffsetAddrDecoder(.s32, sword);
    t[0x0a] = makeOffsetAddrDecoder(.s32, sfloat);
    t[0x0b] = makeIndexAddrDecoder(sbyte, sbyte);
    t[0x0c] = makeIndexAddrDecoder(sbyte, sword);
    t[0x0d] = makeIndexAddrDecoder(sbyte, sfloat);
    t[0x0e] = makeIndexAddrDecoder(sword, sbyte);
    t[0x0f] = makeIndexAddrDecoder(sword, sword);
    t[0x10] = makeIndexAddrDecoder(sword, sfloat);
    t[0x11] = makeIndexAddrDecoder(sfloat, sbyte);
    t[0x12] = makeIndexAddrDecoder(sfloat, sword);
    t[0x13] = makeIndexAddrDecoder(sfloat, sfloat);
    t[0x14] = makePreincAddrDecoder(-sbyte_s);
    t[0x15] = makePreincAddrDecoder(-sword_s);
    t[0x16] = makePreincAddrDecoder(-sfloat_s);
    t[0x17] = makePreincAddrDecoder(sbyte_s);
    t[0x18] = makePreincAddrDecoder(sword_s);
    t[0x19] = makePreincAddrDecoder(sfloat_s);
    t[0x1a] = makePostincAddrDecoder(-sbyte_s);
    t[0x1b] = makePostincAddrDecoder(-sword_s);
    t[0x1c] = makePostincAddrDecoder(-sfloat_s);
    t[0x1d] = makePostincAddrDecoder(sbyte_s);
    t[0x1e] = makePostincAddrDecoder(sword_s);
    t[0x1f] = makePostincAddrDecoder(sfloat_s);
    t[0x20] = makePcrAddrDecoder(.s8);
    t[0x21] = makePcrAddrDecoder(.s16);
    t[0x22] = makePcrAddrDecoder(.s32);
    break :blk t;
};

const traps_0: [256]Trap0Fn = blk: {
    var t: [256]Trap0Fn = @splat(illegalTrap0);
    t[0x01] = makeTrap0(.plus);
    t[0x02] = makeTrap0(.decrement);
    t[0x03] = makeTrap0(.divide);
    t[0x04] = makeTrap0(.equal);
    t[0x05] = makeTrap0(.greater);
    t[0x06] = makeTrap0(.increment);
    t[0x07] = makeTrap0(.less);
    t[0x08] = makeTrap0(.modulo);
    t[0x09] = makeTrap0(.multiply);
    t[0x0a] = makeTrap0(.negative);
    t[0x0b] = makeTrampoline(.operator_1_0_trap);
    t[0x0c] = makeTrampoline(.operator_2_0_trap);
    t[0x0d] = makeTrampoline(.operator_2_1_trap);
    t[0x0e] = makeTrampoline(.operator_3_0_trap);
    t[0x0f] = makeTrampoline(.operator_3_1_trap);
    t[0x10] = makeTrampoline(.operator_3_2_trap);
    t[0x11] = makeTrampoline(.operator_4_0_trap);
    t[0x12] = makeTrampoline(.operator_4_1_trap);
    t[0x13] = makeTrampoline(.operator_4_2_trap);
    t[0x14] = makeTrampoline(.operator_4_3_trap);
    t[0x15] = makeTrampoline(.operator_apply_trap);
    t[0x16] = makeTrampoline(.operator_lexpr_trap);
    t[0x17] = makeTrampoline(.operator_lookup_trap);
    t[0x18] = makeTrampoline(.operator_primitive_trap);
    t[0x19] = makeTrap0(.positive);
    t[0x1a] = makeTrap0(.quotient);
    t[0x1b] = makeTrampoline(.reflect_to_interface);
    t[0x1c] = makeTrap0(.remainder);
    t[0x1d] = makeTrampoline(.return_to_interpreter);
    t[0x1e] = makeTrap0(.minus);
    t[0x1f] = makeTrap0(.zero);
    break :blk t;
};

const traps_1: [256]Trap1Fn = blk: {
    var t: [256]Trap1Fn = @splat(illegalTrap1);
    t[0x01] = makeTrap1(.@"error");
    t[0x02] = makeTrapR1(.lookup_trap);
    t[0x03] = makeTrap1(.primitive_apply);
    t[0x04] = makeTrap1(.primitive_lexpr_apply);
    t[0x05] = makeTrapR1(.safe_lookup_trap);
    t[0x06] = makeTrapR1(.unassigned_p_trap);
    break :blk t;
};

const traps_2: [256]Trap2Fn = blk: {
    var t: [256]Trap2Fn = @splat(illegalTrap2);
    t[0x01] = makeTrap2(.apply);
    t[0x02] = makeTrapR2(.assignment_trap);
    t[0x03] = makeTrap2(.lexpr_apply);
    t[0x04] = makeTrapR2(.primitive_error);
    break :blk t;
};

const traps_3: [256]Trap3Fn = blk: {
    var t: [256]Trap3Fn = @splat(illegalTrap3);
    t[0x01] = makeTrap3(.cache_lookup_apply);
    t[0x02] = makeTrapR3(.link);
    break :blk t;
};

const inst_defns: [256]InstFn = blk: {
    var t: [256]InstFn = @splat(illegalInstruction);
    t[0x01] = insnStoreBWrAddr;
    t[0x02] = insnStoreWWrAddr;
    t[0x03] = insnStoreFFrAddr;
    t[0x04] = insnLoadBWrAddr;
    t[0x05] = insnLoadWWrAddr;
    t[0x06] = insnLoadFFrAddr;
    t[0x07] = insnLoadAddressAddr;
    t[0x08] = makeLoadImmediateWr(.s8);
    t[0x09] = makeLoadImmediateWr(.s16);
    t[0x0a] = makeLoadImmediateWr(.s32);
    t[0x0b] = insnLoadImmediateFrFlt;
    t[0x0c] = insnCopyBlockU8W;
    t[0x0d] = insnCopyBlockWrW;
    t[0x0e] = makeLoadNonPointerTcImm(.s8);
    t[0x0f] = makeLoadNonPointerWrImm(.s8);
    t[0x10] = makeLoadNonPointerTcImm(.s16);
    t[0x11] = makeLoadNonPointerWrImm(.s16);
    t[0x12] = makeLoadNonPointerTcImm(.s32);
    t[0x13] = makeLoadNonPointerWrImm(.s32);
    t[0x14] = insnLoadNonPointerTcWr;
    t[0x15] = insnLoadNonPointer;
    t[0x16] = insnLoadPointerTcWr;
    t[0x17] = insnLoadPointer;
    t[0x18] = makeJumpPcr(.s8);
    t[0x19] = makeJumpPcr(.s16);
    t[0x1a] = makeJumpPcr(.s32);
    t[0x1b] = insnJumpIndirWr;
    t[0x1c] = makeIjump(.u8);
    t[0x1d] = makeIjump(.u16);
    t[0x1e] = makeIjump(.u32);
    t[0x1f] = makeIcall(.u8);
    t[0x20] = makeIcall(.u16);
    t[0x21] = makeIcall(.u32);
    t[0x22] = insnEnterClosure;

    t[0x23] = makeCjumpWrWr(.eq, .s8);
    t[0x24] = makeCjumpWrWr(.neq, .s8);
    t[0x25] = makeCjumpWrWr(.lt, .s8);
    t[0x26] = makeCjumpWrWr(.ge, .s8);
    t[0x27] = makeCjumpWrWr(.gt, .s8);
    t[0x28] = makeCjumpWrWr(.le, .s8);
    t[0x29] = makeCjumpWrWr(.slt, .s8);
    t[0x2a] = makeCjumpWrWr(.sge, .s8);
    t[0x2b] = makeCjumpWrWr(.sgt, .s8);
    t[0x2c] = makeCjumpWrWr(.sle, .s8);

    t[0x2d] = makeCjumpWrWr(.eq, .s16);
    t[0x2e] = makeCjumpWrWr(.neq, .s16);
    t[0x2f] = makeCjumpWrWr(.lt, .s16);
    t[0x30] = makeCjumpWrWr(.ge, .s16);
    t[0x31] = makeCjumpWrWr(.gt, .s16);
    t[0x32] = makeCjumpWrWr(.le, .s16);
    t[0x33] = makeCjumpWrWr(.slt, .s16);
    t[0x34] = makeCjumpWrWr(.sge, .s16);
    t[0x35] = makeCjumpWrWr(.sgt, .s16);
    t[0x36] = makeCjumpWrWr(.sle, .s16);

    t[0x37] = makeCjumpWrWr(.eq, .s32);
    t[0x38] = makeCjumpWrWr(.neq, .s32);
    t[0x39] = makeCjumpWrWr(.lt, .s32);
    t[0x3a] = makeCjumpWrWr(.ge, .s32);
    t[0x3b] = makeCjumpWrWr(.gt, .s32);
    t[0x3c] = makeCjumpWrWr(.le, .s32);
    t[0x3d] = makeCjumpWrWr(.slt, .s32);
    t[0x3e] = makeCjumpWrWr(.sge, .s32);
    t[0x3f] = makeCjumpWrWr(.sgt, .s32);
    t[0x40] = makeCjumpWrWr(.sle, .s32);

    t[0x41] = makeCjumpWr(.eq, .s8);
    t[0x42] = makeCjumpWr(.neq, .s8);
    t[0x43] = makeCjumpWr(.slt, .s8);
    t[0x44] = makeCjumpWr(.sge, .s8);
    t[0x45] = makeCjumpWr(.sgt, .s8);
    t[0x46] = makeCjumpWr(.sle, .s8);

    t[0x47] = makeCjumpWr(.eq, .s16);
    t[0x48] = makeCjumpWr(.neq, .s16);
    t[0x49] = makeCjumpWr(.slt, .s16);
    t[0x4a] = makeCjumpWr(.sge, .s16);
    t[0x4b] = makeCjumpWr(.sgt, .s16);
    t[0x4c] = makeCjumpWr(.sle, .s16);

    t[0x4d] = makeCjumpWr(.eq, .s32);
    t[0x4e] = makeCjumpWr(.neq, .s32);
    t[0x4f] = makeCjumpWr(.slt, .s32);
    t[0x50] = makeCjumpWr(.sge, .s32);
    t[0x51] = makeCjumpWr(.sgt, .s32);
    t[0x52] = makeCjumpWr(.sle, .s32);

    t[0x53] = makeCjumpFixWr(.fix, .s8);
    t[0x54] = makeCjumpFixWr(.nfix, .s8);
    t[0x55] = makeCjumpFixWr(.ifix, .s8);
    t[0x56] = makeCjumpFixWr(.nifix, .s8);
    t[0x57] = makeCjumpFixWr(.fix, .s16);
    t[0x58] = makeCjumpFixWr(.nfix, .s16);
    t[0x59] = makeCjumpFixWr(.ifix, .s16);
    t[0x5a] = makeCjumpFixWr(.nifix, .s16);
    t[0x5b] = makeCjumpFixWr(.fix, .s32);
    t[0x5c] = makeCjumpFixWr(.nfix, .s32);
    t[0x5d] = makeCjumpFixWr(.ifix, .s32);
    t[0x5e] = makeCjumpFixWr(.nifix, .s32);

    t[0x5f] = makeCjumpFrFr(.eq, .s8);
    t[0x60] = makeCjumpFrFr(.neq, .s8);
    t[0x61] = makeCjumpFrFr(.lt, .s8);
    t[0x62] = makeCjumpFrFr(.gt, .s8);
    t[0x63] = makeCjumpFrFr(.le, .s8);
    t[0x64] = makeCjumpFrFr(.ge, .s8);
    t[0x65] = makeCjumpFrFr(.cmp, .s8);
    t[0x66] = makeCjumpFrFr(.ncmp, .s8);

    t[0x67] = makeCjumpFrFr(.eq, .s16);
    t[0x68] = makeCjumpFrFr(.neq, .s16);
    t[0x69] = makeCjumpFrFr(.lt, .s16);
    t[0x6a] = makeCjumpFrFr(.gt, .s16);
    t[0x6b] = makeCjumpFrFr(.le, .s16);
    t[0x6c] = makeCjumpFrFr(.ge, .s16);
    t[0x6d] = makeCjumpFrFr(.cmp, .s16);
    t[0x6e] = makeCjumpFrFr(.ncmp, .s16);

    t[0x6f] = makeCjumpFrFr(.eq, .s32);
    t[0x70] = makeCjumpFrFr(.neq, .s32);
    t[0x71] = makeCjumpFrFr(.lt, .s32);
    t[0x72] = makeCjumpFrFr(.gt, .s32);
    t[0x73] = makeCjumpFrFr(.le, .s32);
    t[0x74] = makeCjumpFrFr(.ge, .s32);
    t[0x75] = makeCjumpFrFr(.cmp, .s32);
    t[0x76] = makeCjumpFrFr(.ncmp, .s32);

    t[0x77] = makeCjumpFr(.eq, .s8);
    t[0x78] = makeCjumpFr(.neq, .s8);
    t[0x79] = makeCjumpFr(.lt, .s8);
    t[0x7a] = makeCjumpFr(.gt, .s8);
    t[0x7b] = makeCjumpFr(.le, .s8);
    t[0x7c] = makeCjumpFr(.ge, .s8);
    t[0x7d] = makeCjumpFr(.cmp, .s8);
    t[0x7e] = makeCjumpFr(.ncmp, .s8);

    t[0x7f] = makeCjumpFr(.eq, .s16);
    t[0x80] = makeCjumpFr(.neq, .s16);
    t[0x81] = makeCjumpFr(.lt, .s16);
    t[0x82] = makeCjumpFr(.gt, .s16);
    t[0x83] = makeCjumpFr(.le, .s16);
    t[0x84] = makeCjumpFr(.ge, .s16);
    t[0x85] = makeCjumpFr(.cmp, .s16);
    t[0x86] = makeCjumpFr(.ncmp, .s16);

    t[0x87] = makeCjumpFr(.eq, .s32);
    t[0x88] = makeCjumpFr(.neq, .s32);
    t[0x89] = makeCjumpFr(.lt, .s32);
    t[0x8a] = makeCjumpFr(.gt, .s32);
    t[0x8b] = makeCjumpFr(.le, .s32);
    t[0x8c] = makeCjumpFr(.ge, .s32);
    t[0x8d] = makeCjumpFr(.cmp, .s32);
    t[0x8e] = makeCjumpFr(.ncmp, .s32);

    t[0x8f] = insnTrapTrap0;
    t[0x90] = insnTrapTrap1Wr;
    t[0x91] = insnTrapTrap2Wr;
    t[0x92] = insnTrapTrap3Wr;

    t[0x93] = makeInterruptTest(.procedure);
    t[0x94] = makeInterruptTest(.dynamic_link);
    t[0x95] = makeInterruptTest(.ic_procedure);
    t[0x96] = makeInterruptTest(.continuation);

    t[0x97] = insnPopReturn;

    t[0x98] = makeFlonumHeaderImm(.u8);
    t[0x99] = makeFlonumHeaderImm(.u16);
    t[0x9a] = makeFlonumHeaderImm(.u32);
    t[0x9b] = insnFlonumHeader;

    t[0x9c] = insnCopyWr;
    t[0x9d] = makeUnaryFr(opCopyFr);
    t[0x9e] = makeUnaryWrFn(opNegateWr);
    t[0x9f] = makeUnaryFr(opNegateFr);
    t[0xa0] = makeUnaryWrFn(opIncrementWr);
    t[0xa1] = makeUnaryFr(opIncrementFr);
    t[0xa2] = makeUnaryWrFn(opDecrementWr);
    t[0xa3] = makeUnaryFr(opDecrementFr);
    t[0xa4] = makeUnaryWrFn(opAbsWr);
    t[0xa5] = makeUnaryFrC(fabs);
    t[0xa6] = makeUnaryWr(obj.objectType);
    t[0xa7] = makeUnaryWr(obj.objectDatum);
    t[0xa8] = makeUnaryWr(xObjectAddress);
    t[0xa9] = makeUnaryWr(xFixnumToLong);
    t[0xaa] = makeUnaryWrFn(opIntegerToFixnum);
    t[0xab] = makeUnaryWrFn(opNot);
    t[0xac] = insnFlonumAlign;
    t[0xad] = makeUnaryWr(obj.floatingVectorLength);
    t[0xae] = makeUnaryFrC(sqrt);
    t[0xaf] = makeUnaryFrC(artutl.double_round);
    t[0xb0] = makeUnaryFrC(ceil);
    t[0xb1] = makeUnaryFrC(floor);
    t[0xb2] = makeUnaryFrC(artutl.double_truncate);
    t[0xb3] = makeUnaryFrC(log);
    t[0xb4] = makeUnaryFrC(exp);
    t[0xb5] = makeUnaryFrC(cos);
    t[0xb6] = makeUnaryFrC(sin);
    t[0xb7] = makeUnaryFrC(tan);
    t[0xb8] = makeUnaryFrC(acos);
    t[0xb9] = makeUnaryFrC(asin);
    t[0xba] = makeUnaryFrC(atan);

    t[0xbb] = makeBinaryWr(opAddWr);
    t[0xbc] = makeBinaryFr(opAddFr);
    t[0xbd] = makeBinaryWr(opSubtractWr);
    t[0xbe] = makeBinaryFr(opSubtractFr);
    t[0xbf] = makeBinaryWr(opMultiplyWr);
    t[0xc0] = makeBinaryFr(opMultiplyFr);
    t[0xc1] = makeBinaryWr(opProductWr);
    t[0xc2] = makeBinaryWr(opQuotientWr);
    t[0xc3] = makeBinaryWr(opRemainderWr);
    t[0xc4] = makeBinaryWr(opLshWr);
    t[0xc5] = makeBinaryWr(opAndWr);
    t[0xc6] = makeBinaryWr(opAndcWr);
    t[0xc7] = makeBinaryWr(opOrWr);
    t[0xc8] = makeBinaryWr(opXorWr);
    t[0xc9] = makeBinaryWr(opMaxUnsigned);
    t[0xca] = makeBinaryWr(opMinUnsigned);
    t[0xcb] = makeBinaryFr(opDivideFr);
    t[0xcc] = makeBinaryFrC(atan2);
    break :blk t;
};

comptime {
    @setEvalBranchQuota(5000);
    if (build_options.cc_is_svm and @sizeOf(WordT) > 0) {
        std.debug.assert((@sizeOf(f64) / @sizeOf(obj.SchemeObject)) <= 2);
    }

    // Validate full population of all 6 dispatch tables against svm1-defns.h bounds.
    std.debug.assert(inst_defns[0] == illegalInstruction);
    for (0x01..0xcd) |i| std.debug.assert(inst_defns[i] != illegalInstruction);
    for (0xcd..256) |i| std.debug.assert(inst_defns[i] == illegalInstruction);

    std.debug.assert(address_decoders[0] == illegalAddress);
    for (0x01..0x23) |i| std.debug.assert(address_decoders[i] != illegalAddress);
    for (0x23..256) |i| std.debug.assert(address_decoders[i] == illegalAddress);

    std.debug.assert(traps_0[0] == illegalTrap0);
    for (0x01..0x20) |i| std.debug.assert(traps_0[i] != illegalTrap0);
    for (0x20..256) |i| std.debug.assert(traps_0[i] == illegalTrap0);

    std.debug.assert(traps_1[0] == illegalTrap1);
    for (0x01..0x07) |i| std.debug.assert(traps_1[i] != illegalTrap1);
    for (0x07..256) |i| std.debug.assert(traps_1[i] == illegalTrap1);

    std.debug.assert(traps_2[0] == illegalTrap2);
    for (0x01..0x05) |i| std.debug.assert(traps_2[i] != illegalTrap2);
    for (0x05..256) |i| std.debug.assert(traps_2[i] == illegalTrap2);

    std.debug.assert(traps_3[0] == illegalTrap3);
    for (0x01..0x03) |i| std.debug.assert(traps_3[i] != illegalTrap3);
    for (0x03..256) |i| std.debug.assert(traps_3[i] == illegalTrap3);

    if (!builtin.is_test and build_options.cc_is_svm) {
        @export(&svm_fasl_arch_storage, .{ .name = "svm_fasl_arch" });
        @export(&initializeSvm1, .{ .name = "initialize_svm1" });
        @export(&cToInterface, .{ .name = "C_to_interface" });
        @export(&svmExportInstructionPointer, .{ .name = "svm_export_instruction_pointer" });
    }
}

fn putU16(buf: []u8, pos: *usize, v: u16) void {
    buf[pos.*] = @truncate(v & 0xff);
    buf[pos.* + 1] = @truncate(v >> 8);
    pos.* += 2;
}

fn putU32(buf: []u8, pos: *usize, v: u32) void {
    buf[pos.*] = @truncate(v & 0xff);
    buf[pos.* + 1] = @truncate((v >> 8) & 0xff);
    buf[pos.* + 2] = @truncate((v >> 16) & 0xff);
    buf[pos.* + 3] = @truncate(v >> 24);
    pos.* += 4;
}

fn putU64(buf: []u8, pos: *usize, v: u64) void {
    for (0..8) |i| {
        buf[pos.* + i] = @truncate(v >> @intCast(i * 8));
    }
    pos.* += 8;
}

test "svm1 immediates, memory addressing modes, non-pointer, and block copy" {
    const test_stubs = @import("test_stubs.zig");
    test_stubs.resetMockRuntime();
    TestMockState.reset();
    initializeSvm1();

    try std.testing.expectEqual(@intFromPtr(&abi.Registers), wregRef(reg_interpreter_register_block));

    var scratch_words: [16]WordT align(16) = @splat(0);
    var scratch_bytes: [64]u8 align(16) = @splat(0);
    wregSet(5, @intFromPtr(&scratch_words));
    wregSet(6, @intFromPtr(&scratch_bytes));
    wregSet(7, 2); // index register

    var code: [256]u8 align(16) = @splat(0);
    var p: usize = 0;

    // 1. load_immediate_wr_s8 r8, -5
    code[p] = 0x08;
    code[p + 1] = 8;
    code[p + 2] = @bitCast(@as(i8, -5));
    p += 3;
    // 2. load_immediate_wr_s16 r9, -1000
    code[p] = 0x09;
    code[p + 1] = 9;
    p += 2;
    putU16(&code, &p, @bitCast(@as(i16, -1000)));
    // 3. load_immediate_wr_s32 r10, -70000
    code[p] = 0x0a;
    code[p + 1] = 10;
    p += 2;
    putU32(&code, &p, @bitCast(@as(i32, -70000)));
    // 4. load_immediate_fr_flt f1, (3 * 2^2 = 12.0)
    code[p] = 0x0b;
    code[p + 1] = 1;
    p += 2;
    putU64(&code, &p, 3);
    putU16(&code, &p, 2);
    // 5. store_w_wr_addr r8, offset_s8_w(r5, 3) -> scratch_words[3] = -5
    code[p] = 0x02;
    code[p + 1] = 8;
    code[p + 2] = 0x03;
    code[p + 3] = 5;
    code[p + 4] = 3;
    p += 5;
    // 6. load_w_wr_addr r11, index_w_w(r5, offset=1, index=r7=2) -> scratch_words[3]
    code[p] = 0x05;
    code[p + 1] = 11;
    code[p + 2] = 0x0f;
    code[p + 3] = 5;
    code[p + 4] = 1;
    code[p + 5] = 7;
    p += 6;
    // 7. store_b_wr_addr r11, postinc_b(r6); load_b_wr_addr r12, predec_b(r6)
    code[p] = 0x01;
    code[p + 1] = 11;
    code[p + 2] = 0x1d;
    code[p + 3] = 6;
    p += 4;
    code[p] = 0x04;
    code[p + 1] = 12;
    code[p + 2] = 0x14;
    code[p + 3] = 6;
    p += 4;
    // 8. store_f_fr_addr f1, offset_s8_f(r5, 5); load_f_fr_addr f2, offset_s8_f(r5, 5)
    code[p] = 0x03;
    code[p + 1] = 1;
    code[p + 2] = 0x04;
    code[p + 3] = 5;
    code[p + 4] = 5;
    p += 5;
    code[p] = 0x06;
    code[p + 1] = 2;
    code[p + 2] = 0x04;
    code[p + 3] = 5;
    code[p + 4] = 5;
    p += 5;
    // 9. load_address_addr r13, pcr_s8(+4) then load_non_pointer_tc_s8 r14, tc_fixnum, -1
    code[p] = 0x07;
    code[p + 1] = 13;
    code[p + 2] = 0x20;
    code[p + 3] = 4;
    p += 4;
    const expected_pcr_addr = @intFromPtr(&code[p]) + 4;
    code[p] = 0x0e;
    code[p + 1] = 14;
    code[p + 2] = @intCast(obj.tc_fixnum);
    code[p + 3] = @bitCast(@as(i8, -1));
    p += 4;
    // 10. load_pointer_tc_wr r15, tc_pair, r5
    code[p] = 0x16;
    code[p + 1] = 15;
    code[p + 2] = @intCast(obj.tc_pair);
    code[p + 3] = 5;
    p += 4;
    // 11. halt via trap_0 return_to_interpreter (0x8f, 0x1d)
    code[p] = 0x8f;
    code[p + 1] = 0x1d;
    p += 2;

    TestMockState.next_util_result = .{ .scheme_p = false, .arg = .{ .interpreter_code = abi.prim_done } };
    const rc = cToInterface(&code);
    try std.testing.expectEqual(abi.prim_done, rc);
    try std.testing.expectEqual(@as(isize, -5), @as(isize, @bitCast(wregRef(8))));
    try std.testing.expectEqual(@as(isize, -1000), @as(isize, @bitCast(wregRef(9))));
    try std.testing.expectEqual(@as(isize, -70000), @as(isize, @bitCast(wregRef(10))));
    try std.testing.expectEqual(@as(f64, 12.0), fregRef(1));
    try std.testing.expectEqual(@as(f64, 12.0), fregRef(2));
    try std.testing.expectEqual(@as(isize, -5), @as(isize, @bitCast(wregRef(11))));
    try std.testing.expectEqual(@as(WordT, 0xfb), wregRef(12));
    try std.testing.expectEqual(@intFromPtr(&scratch_bytes), wregRef(6));
    try std.testing.expectEqual(expected_pcr_addr, wregRef(13));
    try std.testing.expectEqual(obj.longToFixnum(-1), wregRef(14));
    try std.testing.expectEqual(obj.makePointerObject(obj.tc_pair, &scratch_words), wregRef(15));
    try std.testing.expectEqual(@as(usize, 1), TestMockState.util_calls);
    try std.testing.expectEqual(UtilId.return_to_interpreter, TestMockState.last_util.?);

    // Test overlapping copy_block (to > from and to < from)
    var arr: [8]WordT = .{ 10, 20, 30, 40, 50, 60, 0, 0 };
    wregSet(5, @intFromPtr(&arr[2]));
    wregSet(6, @intFromPtr(&arr[0]));
    p = 0;
    code[p] = 0x0c; // copy_block_u8_w r5, r6, 4
    code[p + 1] = 5;
    code[p + 2] = 6;
    code[p + 3] = 4;
    p += 4;
    code[p] = 0x8f;
    code[p + 1] = 0x1d;
    _ = cToInterface(&code);
    try std.testing.expectEqualSlices(WordT, &.{ 10, 20, 10, 20, 30, 40, 0, 0 }, &arr);

    // Illegal type code in load_non_pointer_tc_s8 (type = 65 > 64)
    p = 0;
    code[p] = 0x0e;
    code[p + 1] = 8;
    code[p + 2] = 65;
    code[p + 3] = 0;
    try std.testing.expectEqual(abi.err_compiled_code_error, cToInterface(&code));

    // Illegal opcode 0x00 and illegal address mode 0xff
    code[0] = 0x00;
    try std.testing.expectEqual(abi.err_compiled_code_error, cToInterface(&code));
    code[0] = 0x05;
    code[1] = 8;
    code[2] = 0xff;
    try std.testing.expectEqual(abi.err_compiled_code_error, cToInterface(&code));
}

test "svm1 word/float ALU, jumps, icall/pop_return, closure, traps, and interrupts" {
    const test_stubs = @import("test_stubs.zig");
    test_stubs.resetMockRuntime();
    TestMockState.reset();
    initializeSvm1();

    var code: [256]u8 align(16) = @splat(0);
    var p: usize = 0;

    // ALU setup: r5 = -17, r6 = 5, r7 = 0x3F (tc_fixnum? test)
    wregSet(5, @bitCast(@as(isize, -17)));
    wregSet(6, 5);
    wregSet(7, @bitCast(@as(isize, obj.smallest_fixnum - 1))); // non-fixnum for cjump_nfix

    // quotient r8 = r5 / r6 (-3); remainder r9 = r5 % r6 (-2); abs r10 = |r5| (17)
    code[p] = 0xc2;
    code[p + 1] = 8;
    code[p + 2] = 5;
    code[p + 3] = 6;
    p += 4;
    code[p] = 0xc3;
    code[p + 1] = 9;
    code[p + 2] = 5;
    code[p + 3] = 6;
    p += 4;
    code[p] = 0xa4;
    code[p + 1] = 10;
    code[p + 2] = 5;
    p += 3;
    // lsh: r11 = r6 << 3 (40), r12 = r5 >> 2 (-5 via -2 => s=-17, n=-2 => -5)
    wregSet(13, 3);
    wregSet(14, @bitCast(@as(isize, -2)));
    code[p] = 0xc4;
    code[p + 1] = 11;
    code[p + 2] = 6;
    code[p + 3] = 13;
    p += 4;
    code[p] = 0xc4;
    code[p + 1] = 12;
    code[p + 2] = 5;
    code[p + 3] = 14;
    p += 4;
    // product: fit (5 * -17) vs overflow
    code[p] = 0xc1;
    code[p + 1] = 15;
    code[p + 2] = 5;
    code[p + 3] = 6;
    p += 4;
    wregSet(16, @as(WordT, 1) << 40);
    code[p] = 0xc1;
    code[p + 1] = 17;
    code[p + 2] = 16;
    code[p + 3] = 16;
    p += 4;

    // cjump_nfix r7, +3 (skip an illegal opcode 0x00)
    code[p] = 0x54;
    code[p + 1] = 7;
    code[p + 2] = 1; // skip 1 byte (0x00)
    p += 3;
    code[p] = 0x00;
    p += 1;

    // Float ops & cjump_ncmp on NaN
    fregSet(1, 2.5);
    fregSet(2, std.math.nan(f64)); // NaN
    code[p] = 0xaf; // round f3 = double_round(2.5) -> 2.0
    code[p + 1] = 3;
    code[p + 2] = 1;
    p += 3;
    code[p] = 0x66; // cjump_ncmp_fr_fr_pcr_s8 f1, f2, +1
    code[p + 1] = 1;
    code[p + 2] = 2;
    code[p + 3] = 1;
    p += 4;
    code[p] = 0x00;
    p += 1;

    // icall_u8: jump over 4-byte continuation header + return slot to callee, callee executes pop_return
    const callee_offset: usize = p + 3 + 4 + @sizeOf(WordT) + 2; // + icall(3)? No: +2 op/arg -> PC after decode, +4 cont_hdr + 2 halt + word slot
    _ = callee_offset;
    code[p] = 0x1f; // icall_u8
    // After icall_u8 (2 bytes), PC is at (p + 2):
    //   PC+0..PC+3: 4-byte cc_entry header (dummy)
    //   PC+4..PC+5: trap_0(return_to_interpreter) (continuation body)
    //   PC+6..PC+13: SchemeObject target (offset = 6 from PC)
    //   PC+14: callee -> pop_return (0x97)
    code[p + 1] = 6; // IJUMP reads *(PC + 6)
    p += 2;
    p += 4; // cc_entry_header
    code[p] = 0x8f;
    code[p + 1] = 0x1d;
    p += 2;
    const callee_ptr = code[p + @sizeOf(WordT) ..].ptr;
    const target_entry = makeCcEntryAddr(callee_ptr);
    @as(*align(1) obj.SchemeObject, @ptrCast(&code[p])).* = target_entry;
    p += @sizeOf(WordT);
    code[p] = 0x97; // pop_return -> jumps back to continuation body (trap_0 return_to_interpreter)!

    const rc = cToInterface(&code);
    try std.testing.expectEqual(abi.prim_done, rc);
    try std.testing.expectEqual(@as(isize, -3), @as(isize, @bitCast(wregRef(8))));
    try std.testing.expectEqual(@as(isize, -2), @as(isize, @bitCast(wregRef(9))));
    try std.testing.expectEqual(@as(WordT, 17), wregRef(10));
    try std.testing.expectEqual(@as(WordT, 40), wregRef(11));
    try std.testing.expectEqual(@as(isize, -5), @as(isize, @bitCast(wregRef(12))));
    try std.testing.expectEqual(@as(isize, -85), @as(isize, @bitCast(wregRef(15))));
    try std.testing.expectEqual(obj.sharp_t, wregRef(17));
    try std.testing.expectEqual(@as(f64, 2.0), fregRef(3));

    // Test enter_closure with 2 entries and target return
    test_stubs.resetMockRuntime();
    abi.compilerSetupInterrupt();
    TestMockState.reset();
    initializeSvm1();

    var closure_mem: [12]obj.SchemeObject align(16) = @splat(0);
    const block: [*]u8 = @ptrCast(closure_mem[1..].ptr);
    // Write count = 2 at block[0..2]
    block[0] = 2;
    block[1] = 0;
    // Entry 0 at closure_entry_offset (8), entry 1 at 8 + 5 = 13
    const entry1 = block + cmpintmd_svm1.closure_entry_offset + cmpintmd_svm1.closure_entry_size;
    entry1[0] = cmpintmd_svm1.svm1_inst_enter_closure;
    entry1[1] = 1; // index 1
    entry1[2] = 0;
    var target_code: [4]u8 = .{ 0x8f, 0x1d, 0, 0 };
    const targets = cmpintmd_svm1.skipCompiledClosurePadding(
        block + (cmpintmd_svm1.closure_entry_start + (2 * cmpintmd_svm1.closure_entry_size)),
    );
    targets[1] = makeCcEntryAddr(&target_code);
    try std.testing.expectEqual(abi.prim_done, cToInterface(entry1));
    try std.testing.expectEqual(makeCcEntryAddr(block + cmpintmd_svm1.closure_entry_offset), abi.stackRef(0));

    // Interrupt test on enter_closure (entry_arg = entry1) and interrupt_test_procedure
    abi.Registers[abi.regblock_memtop] = @intFromPtr(abi.Free);
    try std.testing.expectEqual(abi.prim_interrupt, cToInterface(entry1));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(entry1)), TestMockState.last_interrupt_entry);

    TestMockState.reset();
    code[0] = 0x93; // interrupt_test_procedure
    try std.testing.expectEqual(abi.prim_interrupt, cToInterface(&code));
    try std.testing.expectEqual(@as(usize, 1), TestMockState.interrupt_calls);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&code)), TestMockState.last_interrupt_entry);

    test_stubs.resetMockRuntime();
    abi.compilerSetupInterrupt();
    TestMockState.reset();
    initializeSvm1();
    wregSet(5, 0x1234);
    code[0] = 0x90; // trap_trap_1_wr
    code[1] = 0x02; // lookup (TrapR1)
    code[2] = 5;
    try std.testing.expectEqual(abi.prim_done, cToInterface(&code));
    try std.testing.expectEqual(UtilId.lookup_trap, TestMockState.last_util.?);
    try std.testing.expectEqual(@intFromPtr(&code[3]) + 4, TestMockState.last_args[0]);
    try std.testing.expectEqual(@as(usize, 0x1234), TestMockState.last_args[1]);

    // svm_export_instruction_pointer idle vs active
    try std.testing.expectEqual(@as(usize, 0xfeed), svmExportInstructionPointer(0xfeed));
    running_p = true;
    instruction_pointer = &code;
    defer {
        running_p = false;
        instruction_pointer = null;
    }
    wregSet(reg_value, obj.ulongToFixnum(77));
    try std.testing.expectEqual(@intFromPtr(&code), svmExportInstructionPointer(0xfeed));
    try std.testing.expectEqual(obj.ulongToFixnum(77), abi.Registers[abi.regblock_val]);
}
