// Derived from MIT/GNU Scheme C sources (`src/microcode/cmpintmd/x86-64.c`, `src/microcode/cmpintmd/x86-64.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const outf = @import("outf.zig");

pub const cc_entry_type_size: usize = 2;
pub const cc_entry_offset_size: usize = 2;
pub const cc_entry_pc_offset_size: usize = 8;
pub const cc_entry_header_size: usize =
    cc_entry_type_size + cc_entry_offset_size + cc_entry_pc_offset_size;

pub const bytes_per_trampoline_entry_padding: usize = 4;
pub const objects_per_trampoline_entry: usize = 4;

pub const compiler_regblock_n_fixed: usize = 16;
pub const compiler_hook_size: usize = 1;
pub const rsi_trampoline_to_interface_offset: usize =
    (compiler_regblock_n_fixed + (2 * compiler_hook_size)) * @sizeOf(obj.SchemeObject);

inline fn readUnaligned(comptime T: type, addr: usize) T {
    return @as(*align(1) const T, @ptrFromInt(addr)).*;
}

inline fn writeUnaligned(comptime T: type, addr: usize, val: T) void {
    @as(*align(1) T, @ptrFromInt(addr)).* = val;
}

inline fn shiftPtr(pc: [*]u8, delta: isize) [*]u8 {
    return if (delta >= 0) pc + @as(usize, @intCast(delta)) else pc - @as(usize, @intCast(-delta));
}

inline fn makeCcEntry(addr: usize) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(addr));
}

pub fn readCcEntryType(cet: *abi.CcEntryType, address: [*]u8) callconv(.c) bool {
    const fw = readUnaligned(u16, @intFromPtr(address) - 12);
    return abi.decode_old_style_format_word(cet, fw);
}

pub fn writeCcEntryType(cet: *abi.CcEntryType, address: [*]u8) callconv(.c) bool {
    var fw: u16 = 0;
    if (abi.encode_old_style_format_word(cet, &fw)) return true;
    writeUnaligned(u16, @intFromPtr(address) - 12, fw);
    return false;
}

pub fn readCcEntryOffset(ceo: *abi.CcEntryOffset, address: [*]u8) callconv(.c) bool {
    const n = readUnaligned(u16, @intFromPtr(address) - 10);
    ceo.offset = @intCast(n >> 1);
    ceo.continued_p = (n & 1) != 0;
    return false;
}

pub fn writeCcEntryOffset(ceo: *abi.CcEntryOffset, address: [*]u8) callconv(.c) bool {
    if (!(ceo.offset < 0x4000)) return true;
    const encoded: u16 = @intCast((ceo.offset << 1) | @as(usize, @intFromBool(ceo.continued_p)));
    writeUnaligned(u16, @intFromPtr(address) - 10, encoded);
    return false;
}

pub fn ccReturnAddressToEntryAddress(pc: [*]u8) callconv(.c) [*]u8 {
    if (pc[0] == 0xeb) {
        const delta: isize = @as(i8, @bitCast(pc[1]));
        return shiftPtr(pc + 2, delta);
    } else if (pc[0] == 0xe9) {
        const delta: isize = readUnaligned(i32, @intFromPtr(pc + 1));
        return shiftPtr(pc + 5, delta);
    }
    return pc;
}

pub fn startClosureRelocation(scan: [*]obj.SchemeObject, ref: *abi.RelocRef) callconv(.c) void {
    const end_idx: usize = @intCast(obj.objectDatum(scan[0]));
    const last_obj = scan[end_idx];
    std.debug.assert(obj.objectType(last_obj) == obj.tc_compiled_entry);
    ref.old_addr = obj.objectRawAddress(last_obj);
    const first_entry = compiledClosureEntry(compiledClosureStart(scan + 1));
    ref.new_addr = abi.tospace_to_newspace(@ptrCast(first_entry));
}

pub fn readCompiledClosureTarget(start: [*]u8, ref: ?*abi.RelocRef) callconv(.c) [*]u8 {
    const addr = start + cc_entry_header_size;
    var base_bytes: isize = @bitCast(@intFromPtr(abi.tospace_to_newspace(@ptrCast(addr)).?));
    if (ref) |r| {
        const old_b: isize = @bitCast(@intFromPtr(r.old_addr.?));
        const new_b: isize = @bitCast(@intFromPtr(r.new_addr.?));
        base_bytes +%= old_b -% new_b;
    }
    const offset: isize = @intCast(readUnaligned(i64, @intFromPtr(addr) - @sizeOf(i64)));
    return @ptrFromInt(@as(usize, @bitCast(base_bytes +% offset)));
}

pub fn writeCompiledClosureTarget(target: [*]u8, start: [*]u8) callconv(.c) void {
    const addr = start + cc_entry_header_size;
    const from_bytes: isize = @bitCast(@intFromPtr(abi.tospace_to_newspace(@ptrCast(addr)).?));
    const to_bytes: isize = @bitCast(@intFromPtr(target));
    writeUnaligned(i64, @intFromPtr(addr) - @sizeOf(i64), @intCast(to_bytes -% from_bytes));
}

pub fn compiledClosureCount(block: [*]obj.SchemeObject) callconv(.c) usize {
    return @intCast(readUnaligned(u32, @intFromPtr(block)));
}

pub fn compiledClosureStart(block: [*]obj.SchemeObject) callconv(.c) [*]u8 {
    return @as([*]u8, @ptrCast(block)) + 4;
}

pub fn compiledClosureEntry(start: [*]u8) callconv(.c) [*]u8 {
    return start + cc_entry_header_size;
}

pub fn compiledClosureNext(start: [*]u8) callconv(.c) [*]u8 {
    return start + cc_entry_header_size + 4;
}

pub fn skipCompiledClosurePadding(start: [*]u8) callconv(.c) [*]obj.SchemeObject {
    return @ptrCast(@alignCast(start - 4));
}

pub fn compiledClosureEntryToTarget(entry: [*]u8) callconv(.c) obj.SchemeObject {
    const offset: isize = @intCast(readUnaligned(i64, @intFromPtr(entry) - @sizeOf(i64)));
    const entry_bytes: isize = @bitCast(@intFromPtr(entry));
    return makeCcEntry(@bitCast(entry_bytes +% offset));
}

pub fn readUuoSymbol(saddr: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return saddr[1];
}

pub fn readUuoFrameSize(saddr: [*]obj.SchemeObject) callconv(.c) c_uint {
    return @intCast(readUnaligned(u16, @intFromPtr(saddr)));
}

pub fn readUuoTarget(saddr: [*]obj.SchemeObject) callconv(.c) [*]u8 {
    const addr: [*]u8 = @ptrCast(saddr + 1);
    std.debug.assert(addr[0] == 0x48);
    std.debug.assert(addr[1] == 0xb9);
    return @ptrFromInt(readUnaligned(usize, @intFromPtr(addr + 2)));
}

pub fn readUuoTargetNoReloc(saddr: [*]obj.SchemeObject) callconv(.c) [*]u8 {
    return readUuoTarget(saddr);
}

pub fn writeUuoTarget(target: [*]u8, saddr: [*]obj.SchemeObject) callconv(.c) void {
    const addr: [*]u8 = @ptrCast(saddr + 1);
    addr[0] = 0x48; // MOV RCX, imm64
    addr[1] = 0xb9;
    writeUnaligned(usize, @intFromPtr(addr + 2), @intFromPtr(target));

    const target_ts = abi.newspace_to_tospace(@ptrCast(target)).?;
    if (readUnaligned(i64, @intFromPtr(target_ts) - @sizeOf(i64)) == 0) {
        const from_bytes: isize = @bitCast(@intFromPtr(abi.tospace_to_newspace(@ptrCast(addr + 15)).?));
        const to_bytes: isize = @bitCast(@intFromPtr(target));
        const jmprel32_offset: isize = to_bytes -% from_bytes;
        if (jmprel32_offset >= std.math.minInt(i32) and jmprel32_offset <= std.math.maxInt(i32)) {
            addr[10] = 0xe9; // JMP rel32
            writeUnaligned(i32, @intFromPtr(addr + 11), @intCast(jmprel32_offset));
        } else {
            addr[10] = 0x48; // MOV RAX, imm64
            addr[11] = 0xb8;
            writeUnaligned(usize, @intFromPtr(addr + 12), @intFromPtr(target));
            addr[20] = 0xff; // JMP RAX
            addr[21] = 0xe0;
        }
    } else {
        addr[10] = 0x48; // MOV RAX, -8(RCX)
        addr[11] = 0x8b;
        addr[12] = 0x41;
        addr[13] = 0xf8;
        addr[14] = 0x48; // ADD RAX, RCX
        addr[15] = 0x01;
        addr[16] = 0xc8;
        addr[17] = 0xff; // JMP RAX
        addr[18] = 0xe0;
    }
}

pub fn trampolineEntrySize(n_entries: usize) callconv(.c) usize {
    return n_entries * objects_per_trampoline_entry;
}

pub fn trampolineEntryAddr(block: [*]obj.SchemeObject, index: usize) callconv(.c) [*]u8 {
    const base: [*]u8 = @ptrCast(block + 2 + (@as(usize, @intCast(index)) * objects_per_trampoline_entry));
    return base + bytes_per_trampoline_entry_padding + cc_entry_header_size;
}

pub fn trampolineReturnAddr(block: [*]obj.SchemeObject, index: usize) callconv(.c) [*]u8 {
    return trampolineEntryAddr(block, index);
}

pub fn storeTrampolineInsns(entry: [*]u8, code: u8) callconv(.c) bool {
    writeUnaligned(i64, @intFromPtr(entry) - @sizeOf(i64), 0);
    entry[0] = 0x41; // MOVB R9, imm8
    entry[1] = 0xb1;
    entry[2] = code;
    entry[3] = 0xff; // JMP r/m64
    entry[4] = 0xa6; // disp32(RSI)
    writeUnaligned(u32, @intFromPtr(entry + 5), @intCast(rsi_trampoline_to_interface_offset));
    return false;
}

pub const HookSpec = struct {
    addr: usize,
    name: [*:0]const u8,
};

pub fn installHooks(
    rsi_value: [*]u8,
    hooks: []const HookSpec,
    declare_fn: *const fn (usize, [*:0]const u8) callconv(.c) void,
) void {
    var offset: usize = compiler_regblock_n_fixed * @sizeOf(obj.SchemeObject);
    for (hooks, 0..) |hook, idx| {
        if (idx == 2 and offset != rsi_trampoline_to_interface_offset) {
            outf.fatal("\nx86_64_reset_hook: RSI_TRAMPOLINE_TO_INTERFACE_OFFSET\n", .{});
            abi.Microcode_Termination(abi.term_exit);
        }
        writeUnaligned(usize, @intFromPtr(rsi_value + offset), @intCast(hook.addr));
        offset += compiler_hook_size * @sizeOf(obj.SchemeObject);
        declare_fn(@intCast(hook.addr), hook.name);
    }
}

const AsmHooks = struct {
    extern "c" fn asm_scheme_to_interface() void;
    extern "c" fn asm_scheme_to_interface_call() void;
    extern "c" fn asm_trampoline_to_interface() void;
    extern "c" fn asm_interrupt_procedure() void;
    extern "c" fn asm_interrupt_continuation() void;
    extern "c" fn asm_interrupt_closure() void;
    extern "c" fn asm_interrupt_dlink() void;
    extern "c" fn asm_primitive_apply() void;
    extern "c" fn asm_primitive_lexpr_apply() void;
    extern "c" fn asm_assignment_trap() void;
    extern "c" fn asm_reference_trap() void;
    extern "c" fn asm_safe_reference_trap() void;
    extern "c" fn asm_link() void;
    extern "c" fn asm_error() void;
    extern "c" fn asm_primitive_error() void;
    extern "c" fn asm_generic_add() void;
    extern "c" fn asm_generic_subtract() void;
    extern "c" fn asm_generic_multiply() void;
    extern "c" fn asm_generic_divide() void;
    extern "c" fn asm_generic_equal() void;
    extern "c" fn asm_generic_less() void;
    extern "c" fn asm_generic_greater() void;
    extern "c" fn asm_generic_increment() void;
    extern "c" fn asm_generic_decrement() void;
    extern "c" fn asm_generic_zero() void;
    extern "c" fn asm_generic_positive() void;
    extern "c" fn asm_generic_negative() void;
    extern "c" fn asm_generic_quotient() void;
    extern "c" fn asm_generic_remainder() void;
    extern "c" fn asm_generic_modulo() void;
    extern "c" fn asm_sc_apply() void;
    extern "c" fn asm_sc_apply_size_1() void;
    extern "c" fn asm_sc_apply_size_2() void;
    extern "c" fn asm_sc_apply_size_3() void;
    extern "c" fn asm_sc_apply_size_4() void;
    extern "c" fn asm_sc_apply_size_5() void;
    extern "c" fn asm_sc_apply_size_6() void;
    extern "c" fn asm_sc_apply_size_7() void;
    extern "c" fn asm_sc_apply_size_8() void;
    extern "c" fn asm_interrupt_continuation_2() void;
    extern "c" fn asm_fixnum_shift() void;
    extern "c" fn asm_apply_setup() void;
    extern "c" fn asm_apply_setup_size_1() void;
    extern "c" fn asm_apply_setup_size_2() void;
    extern "c" fn asm_apply_setup_size_3() void;
    extern "c" fn asm_apply_setup_size_4() void;
    extern "c" fn asm_apply_setup_size_5() void;
    extern "c" fn asm_apply_setup_size_6() void;
    extern "c" fn asm_apply_setup_size_7() void;
    extern "c" fn asm_apply_setup_size_8() void;
    extern "c" fn asm_set_interrupt_enables() void;

    fn specs() [51]HookSpec {
        return .{
            .{ .addr = @intFromPtr(&asm_scheme_to_interface), .name = "asm_scheme_to_interface" },
            .{ .addr = @intFromPtr(&asm_scheme_to_interface_call), .name = "asm_scheme_to_interface_call" },
            .{ .addr = @intFromPtr(&asm_trampoline_to_interface), .name = "asm_trampoline_to_interface" },
            .{ .addr = @intFromPtr(&asm_interrupt_procedure), .name = "asm_interrupt_procedure" },
            .{ .addr = @intFromPtr(&asm_interrupt_continuation), .name = "asm_interrupt_continuation" },
            .{ .addr = @intFromPtr(&asm_interrupt_closure), .name = "asm_interrupt_closure" },
            .{ .addr = @intFromPtr(&asm_interrupt_dlink), .name = "asm_interrupt_dlink" },
            .{ .addr = @intFromPtr(&asm_primitive_apply), .name = "asm_primitive_apply" },
            .{ .addr = @intFromPtr(&asm_primitive_lexpr_apply), .name = "asm_primitive_lexpr_apply" },
            .{ .addr = @intFromPtr(&asm_assignment_trap), .name = "asm_assignment_trap" },
            .{ .addr = @intFromPtr(&asm_reference_trap), .name = "asm_reference_trap" },
            .{ .addr = @intFromPtr(&asm_safe_reference_trap), .name = "asm_safe_reference_trap" },
            .{ .addr = @intFromPtr(&asm_link), .name = "asm_link" },
            .{ .addr = @intFromPtr(&asm_error), .name = "asm_error" },
            .{ .addr = @intFromPtr(&asm_primitive_error), .name = "asm_primitive_error" },
            .{ .addr = @intFromPtr(&asm_generic_add), .name = "asm_generic_add" },
            .{ .addr = @intFromPtr(&asm_generic_subtract), .name = "asm_generic_subtract" },
            .{ .addr = @intFromPtr(&asm_generic_multiply), .name = "asm_generic_multiply" },
            .{ .addr = @intFromPtr(&asm_generic_divide), .name = "asm_generic_divide" },
            .{ .addr = @intFromPtr(&asm_generic_equal), .name = "asm_generic_equal" },
            .{ .addr = @intFromPtr(&asm_generic_less), .name = "asm_generic_less" },
            .{ .addr = @intFromPtr(&asm_generic_greater), .name = "asm_generic_greater" },
            .{ .addr = @intFromPtr(&asm_generic_increment), .name = "asm_generic_increment" },
            .{ .addr = @intFromPtr(&asm_generic_decrement), .name = "asm_generic_decrement" },
            .{ .addr = @intFromPtr(&asm_generic_zero), .name = "asm_generic_zero" },
            .{ .addr = @intFromPtr(&asm_generic_positive), .name = "asm_generic_positive" },
            .{ .addr = @intFromPtr(&asm_generic_negative), .name = "asm_generic_negative" },
            .{ .addr = @intFromPtr(&asm_generic_quotient), .name = "asm_generic_quotient" },
            .{ .addr = @intFromPtr(&asm_generic_remainder), .name = "asm_generic_remainder" },
            .{ .addr = @intFromPtr(&asm_generic_modulo), .name = "asm_generic_modulo" },
            .{ .addr = @intFromPtr(&asm_sc_apply), .name = "asm_sc_apply" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_1), .name = "asm_sc_apply_size_1" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_2), .name = "asm_sc_apply_size_2" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_3), .name = "asm_sc_apply_size_3" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_4), .name = "asm_sc_apply_size_4" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_5), .name = "asm_sc_apply_size_5" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_6), .name = "asm_sc_apply_size_6" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_7), .name = "asm_sc_apply_size_7" },
            .{ .addr = @intFromPtr(&asm_sc_apply_size_8), .name = "asm_sc_apply_size_8" },
            .{ .addr = @intFromPtr(&asm_interrupt_continuation_2), .name = "asm_interrupt_continuation_2" },
            .{ .addr = @intFromPtr(&asm_fixnum_shift), .name = "asm_fixnum_shift" },
            .{ .addr = @intFromPtr(&asm_apply_setup), .name = "asm_apply_setup" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_1), .name = "asm_apply_setup_size_1" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_2), .name = "asm_apply_setup_size_2" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_3), .name = "asm_apply_setup_size_3" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_4), .name = "asm_apply_setup_size_4" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_5), .name = "asm_apply_setup_size_5" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_6), .name = "asm_apply_setup_size_6" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_7), .name = "asm_apply_setup_size_7" },
            .{ .addr = @intFromPtr(&asm_apply_setup_size_8), .name = "asm_apply_setup_size_8" },
            .{ .addr = @intFromPtr(&asm_set_interrupt_enables), .name = "asm_set_interrupt_enables" },
        };
    }
};

pub fn x8664ResetHook() callconv(.c) void {
    const specs = AsmHooks.specs();
    const rsi_value: [*]u8 = @ptrCast(&abi.Registers);
    installHooks(rsi_value, &specs, abi.declare_builtin);
}

pub fn exportAll() void {
    @export(&readCcEntryType, .{ .name = "read_cc_entry_type" });
    @export(&writeCcEntryType, .{ .name = "write_cc_entry_type" });
    @export(&readCcEntryOffset, .{ .name = "read_cc_entry_offset" });
    @export(&writeCcEntryOffset, .{ .name = "write_cc_entry_offset" });
    @export(&ccReturnAddressToEntryAddress, .{ .name = "cc_return_address_to_entry_address" });
    @export(&startClosureRelocation, .{ .name = "start_closure_relocation" });
    @export(&readCompiledClosureTarget, .{ .name = "read_compiled_closure_target" });
    @export(&writeCompiledClosureTarget, .{ .name = "write_compiled_closure_target" });
    @export(&compiledClosureCount, .{ .name = "compiled_closure_count" });
    @export(&compiledClosureStart, .{ .name = "compiled_closure_start" });
    @export(&compiledClosureEntry, .{ .name = "compiled_closure_entry" });
    @export(&compiledClosureNext, .{ .name = "compiled_closure_next" });
    @export(&skipCompiledClosurePadding, .{ .name = "skip_compiled_closure_padding" });
    @export(&compiledClosureEntryToTarget, .{ .name = "compiled_closure_entry_to_target" });
    @export(&readUuoSymbol, .{ .name = "read_uuo_symbol" });
    @export(&readUuoFrameSize, .{ .name = "read_uuo_frame_size" });
    @export(&readUuoTarget, .{ .name = "read_uuo_target" });
    @export(&readUuoTargetNoReloc, .{ .name = "read_uuo_target_no_reloc" });
    @export(&writeUuoTarget, .{ .name = "write_uuo_target" });
    @export(&trampolineEntrySize, .{ .name = "trampoline_entry_size" });
    @export(&trampolineEntryAddr, .{ .name = "trampoline_entry_addr" });
    @export(&trampolineReturnAddr, .{ .name = "trampoline_return_addr" });
    @export(&storeTrampolineInsns, .{ .name = "store_trampoline_insns" });
    @export(&x8664ResetHook, .{ .name = "x86_64_reset_hook" });
}

test "x86_64 cc_entry, jmp target decoding, closures, uuo, trampolines, and hook table" {
    var words: [16]obj.SchemeObject align(16) = @splat(0);
    const bytes: [*]u8 = @ptrCast(&words);
    const entry: [*]u8 = bytes + 16;

    var cet: abi.CcEntryType = undefined;
    abi.make_compiled_continuation_type(&cet, 123);
    try std.testing.expect(!writeCcEntryType(&cet, entry));
    var got_cet: abi.CcEntryType = undefined;
    try std.testing.expect(!readCcEntryType(&got_cet, entry));
    try std.testing.expectEqual(abi.CcEntryTypeMarker.continuation, got_cet.marker);
    try std.testing.expectEqual(@as(usize, 123), got_cet.args.for_continuation.offset);

    var ceo: abi.CcEntryOffset = .{ .offset = 24, .continued_p = true };
    try std.testing.expect(!writeCcEntryOffset(&ceo, entry));
    var got_ceo: abi.CcEntryOffset = undefined;
    try std.testing.expect(!readCcEntryOffset(&got_ceo, entry));
    try std.testing.expectEqual(@as(usize, 24), got_ceo.offset);
    try std.testing.expect(got_ceo.continued_p);

    var bad_ceo: abi.CcEntryOffset = .{ .offset = 0x4000, .continued_p = false };
    try std.testing.expect(writeCcEntryOffset(&bad_ceo, entry));

    // JMP rel8 (+5), JMP rel8 (-4), JMP rel32 (+1000), passthrough
    bytes[20] = 0xeb;
    bytes[21] = 5;
    try std.testing.expectEqual(bytes + 27, ccReturnAddressToEntryAddress(bytes + 20));
    bytes[20] = 0xeb;
    bytes[21] = @bitCast(@as(i8, -4));
    try std.testing.expectEqual(bytes + 18, ccReturnAddressToEntryAddress(bytes + 20));
    bytes[20] = 0xe9;
    writeUnaligned(i32, @intFromPtr(bytes + 21), 1000);
    try std.testing.expectEqual(bytes + 1025, ccReturnAddressToEntryAddress(bytes + 20));
    bytes[20] = 0xc3; // ret
    try std.testing.expectEqual(bytes + 20, ccReturnAddressToEntryAddress(bytes + 20));

    // Closure layout per x86-64.h: count=1, entry0 at +24 (word[3]), 1 slot => 5 words total
    var closure_block: [8]obj.SchemeObject align(16) = @splat(0);
    closure_block[0] = obj.makeObject(obj.tc_manifest_closure, 4);
    @as(*u32, @ptrCast(&closure_block[1])).* = 1;

    var code_target: [8]obj.SchemeObject align(16) = @splat(0);
    const target_entry: [*]u8 = @as([*]u8, @ptrCast(&code_target)) + 24;

    const cstart = compiledClosureStart(closure_block[1..].ptr);
    try std.testing.expectEqual(@as(usize, 1), compiledClosureCount(closure_block[1..].ptr));
    const entry0 = compiledClosureEntry(cstart);
    try std.testing.expectEqual(@as(usize, @intFromPtr(&closure_block[3])), @intFromPtr(entry0));
    const next0 = compiledClosureNext(cstart);
    try std.testing.expectEqual(closure_block[3..].ptr, skipCompiledClosurePadding(next0));

    writeCompiledClosureTarget(target_entry, cstart);
    closure_block[4] = makeCcEntry(@intFromPtr(entry0));

    var ref: abi.RelocRef = undefined;
    startClosureRelocation(&closure_block, &ref);
    try std.testing.expectEqual(target_entry, readCompiledClosureTarget(cstart, &ref));
    try std.testing.expectEqual(target_entry, readCompiledClosureTarget(cstart, null));
    try std.testing.expectEqual(makeCcEntry(@intFromPtr(target_entry)), compiledClosureEntryToTarget(entry0));

    // UUO link near direct rel32 vs indirect closure target
    var uuo: [8]obj.SchemeObject align(16) = @splat(0);
    uuo[0] = obj.longToUnsignedFixnum(4);
    uuo[1] = obj.makeObject(obj.tc_interned_symbol, 77);
    try std.testing.expectEqual(uuo[1], readUuoSymbol(&uuo));
    try std.testing.expectEqual(@as(c_uint, 4), readUuoFrameSize(&uuo));

    writeUuoTarget(target_entry, &uuo);
    try std.testing.expectEqual(target_entry, readUuoTarget(&uuo));
    try std.testing.expectEqual(target_entry, readUuoTargetNoReloc(&uuo));
    const ubytes: [*]u8 = @ptrCast(&uuo[1]);
    try std.testing.expectEqual(@as(u8, 0x48), ubytes[0]);
    try std.testing.expectEqual(@as(u8, 0xb9), ubytes[1]);
    try std.testing.expectEqual(@as(u8, 0xe9), ubytes[10]);
    try std.testing.expectEqual(target_entry, ccReturnAddressToEntryAddress(ubytes + 10));

    // Closure target has non-zero pc_offset => emits MOV RAX,-8(RCX); ADD RAX,RCX; JMP RAX
    writeUuoTarget(entry0, &uuo);
    try std.testing.expectEqual(@as(u8, 0x48), ubytes[10]);
    try std.testing.expectEqual(@as(u8, 0x8b), ubytes[11]);
    try std.testing.expectEqual(@as(u8, 0xe0), ubytes[18]);

    // Trampoline encoding
    var tramp: [8]obj.SchemeObject align(16) = @splat(0);
    try std.testing.expectEqual(@as(usize, 4), trampolineEntrySize(1));
    const te = trampolineEntryAddr(&tramp, 0);
    try std.testing.expectEqual(te, trampolineReturnAddr(&tramp, 0));
    try std.testing.expect(!storeTrampolineInsns(te, abi.trampoline_k_apply));
    try std.testing.expectEqual(@as(i64, 0), readUnaligned(i64, @intFromPtr(te) - 8));
    try std.testing.expectEqual(@as(u8, 0x41), te[0]);
    try std.testing.expectEqual(@as(u8, 0xb1), te[1]);
    try std.testing.expectEqual(abi.trampoline_k_apply, te[2]);
    try std.testing.expectEqual(@as(u32, @intCast(rsi_trampoline_to_interface_offset)), readUnaligned(u32, @intFromPtr(te + 5)));

    // Hook table installation
    var regblock: [96]obj.SchemeObject align(16) = @splat(0);
    var mock_hooks: [51]HookSpec = undefined;
    for (&mock_hooks, 0..) |*h, i| {
        h.* = .{ .addr = 0x10000 + i * 16, .name = "hook" };
    }
    const Ctx = struct {
        var count: usize = 0;
        fn declare(_: usize, _: [*:0]const u8) callconv(.c) void {
            count += 1;
        }
    };
    Ctx.count = 0;
    installHooks(@ptrCast(&regblock), &mock_hooks, Ctx.declare);
    try std.testing.expectEqual(@as(usize, 51), Ctx.count);
    try std.testing.expectEqual(@as(obj.SchemeObject, 0x10020), regblock[compiler_regblock_n_fixed + 2]);
    try std.testing.expectEqual(@as(obj.SchemeObject, 0x10000 + 50 * 16), regblock[compiler_regblock_n_fixed + 50]);
}
