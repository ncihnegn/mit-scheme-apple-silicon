// Derived from MIT/GNU Scheme C sources (`src/microcode/cmpintmd/aarch64.c`, `src/microcode/cmpintmd/aarch64.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

pub const cc_entry_padding_size: usize = 1;
pub const cc_entry_header_size: usize = 3;
pub const trampoline_entry_padding_size: usize = 1;
pub const objects_per_trampoline_entry: usize = 4;

const type_arity_mask: u32 = 0x0000ffff;
const type_arity_shift: u5 = 0;
const block_offset_mask: u32 = 0xffff0000;
const block_offset_shift: u5 = 16;

const is_big_endian: bool = builtin.cpu.arch.endian() == .big;
const is_apple_jit: bool = builtin.os.tag.isDarwin() and builtin.cpu.arch == .aarch64;

inline fn readUnalignedI64(addr: usize) i64 {
    return @as(*align(1) const i64, @ptrFromInt(addr)).*;
}

inline fn writeUnalignedI64(addr: usize, val: i64) void {
    @as(*align(1) i64, @ptrFromInt(addr)).* = val;
}

inline fn makeCcEntry(addr: [*]const u32) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(@intFromPtr(addr)));
}

pub fn readCcEntryType(cet: *abi.CcEntryType, address: [*]u32) callconv(.c) bool {
    const word: u32 = (address - 3)[0];
    const type_arity: u16 = @intCast((word & type_arity_mask) >> type_arity_shift);
    return abi.decode_old_style_format_word(cet, type_arity);
}

pub fn writeCcEntryType(cet: *abi.CcEntryType, address: [*]u32) callconv(.c) bool {
    var type_arity: u16 = 0;
    if (abi.encode_old_style_format_word(cet, &type_arity)) return true;
    const slot = &(address - 3)[0];
    slot.* &= ~type_arity_mask;
    slot.* |= @as(u32, type_arity) << type_arity_shift;
    return false;
}

pub fn readCcEntryOffset(ceo: *abi.CcEntryOffset, address: [*]u32) callconv(.c) bool {
    const units: usize = @sizeOf(obj.SchemeObject) / @sizeOf(u32);
    std.debug.assert(units == 2);
    const word: u32 = (address - 3)[0];
    const n: u16 = @intCast((word & block_offset_mask) >> block_offset_shift);
    ceo.offset = @intCast(units * @as(usize, n >> 1));
    ceo.continued_p = (n & 1) != 0;
    return false;
}

pub fn writeCcEntryOffset(ceo: *abi.CcEntryOffset, address: [*]u32) callconv(.c) bool {
    const units: usize = @sizeOf(obj.SchemeObject) / @sizeOf(u32);
    std.debug.assert(units == 2);
    std.debug.assert((ceo.offset % units) == 0);
    if (!(ceo.offset < 0x4000)) return true;
    const slot = &(address - 3)[0];
    slot.* &= ~block_offset_mask;
    const encoded: usize = (((@as(usize, @intCast(ceo.offset)) / units) << 1) | @as(usize, @intFromBool(ceo.continued_p)));
    slot.* |= @as(u32, @intCast(encoded)) << block_offset_shift;
    return false;
}

pub fn ccReturnAddressToEntryAddress(pc: [*]u32) callconv(.c) [*]u32 {
    const insn: u32 = pc[0];
    if ((insn & 0xfc000000) == 0x14000000) {
        const delta: isize = @as(i26, @bitCast(@as(u26, @truncate(insn))));
        return if (delta >= 0) pc + @as(usize, @intCast(delta)) else pc - @as(usize, @intCast(-delta));
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

pub fn readCompiledClosureTarget(start: [*]u32, ref: ?*abi.RelocRef) callconv(.c) [*]u32 {
    const addr = start + cc_entry_padding_size + cc_entry_header_size;
    var base_bytes: isize = @bitCast(@intFromPtr(abi.tospace_to_newspace(@ptrCast(addr)).?));
    if (ref) |r| {
        const old_b: isize = @bitCast(@intFromPtr(r.old_addr.?));
        const new_b: isize = @bitCast(@intFromPtr(r.new_addr.?));
        base_bytes +%= old_b -% new_b;
    }
    const offset = readUnalignedI64(@intFromPtr(addr) - @sizeOf(i64));
    std.debug.assert(@rem(offset, @sizeOf(u32)) == 0);
    std.debug.assert(@rem(offset, @sizeOf(obj.SchemeObject)) == 0);
    const to_pc: usize = @bitCast(base_bytes +% @as(isize, @intCast(offset)));
    return @ptrFromInt(to_pc);
}

pub fn writeCompiledClosureTarget(target: [*]u32, start: [*]u32) callconv(.c) void {
    const addr = start + cc_entry_padding_size + cc_entry_header_size;
    const from_pc: isize = @bitCast(@intFromPtr(abi.tospace_to_newspace(@ptrCast(addr)).?));
    const to_pc: isize = @bitCast(@intFromPtr(target));
    const offset: i64 = @intCast(to_pc -% from_pc);
    std.debug.assert(@rem(offset, @sizeOf(u32)) == 0);
    std.debug.assert(@rem(offset, @sizeOf(obj.SchemeObject)) == 0);
    writeUnalignedI64(@intFromPtr(addr) - @sizeOf(i64), offset);
}

pub fn compiledClosureCount(block: [*]obj.SchemeObject) callconv(.c) usize {
    return @intCast(@as(*const u32, @ptrCast(block)).*);
}

pub fn compiledClosureStart(block: [*]obj.SchemeObject) callconv(.c) [*]u32 {
    return @ptrCast(block);
}

pub fn compiledClosureEntry(start: [*]u32) callconv(.c) [*]u32 {
    return start + cc_entry_padding_size + cc_entry_header_size;
}

pub fn compiledClosureNext(start: [*]u32) callconv(.c) [*]u32 {
    return start + cc_entry_padding_size + cc_entry_header_size;
}

pub fn skipCompiledClosurePadding(start: [*]u32) callconv(.c) [*]obj.SchemeObject {
    return @ptrCast(@alignCast(start));
}

pub fn compiledClosureEntryToTarget(entry: [*]u32) callconv(.c) obj.SchemeObject {
    const pc_off = readUnalignedI64(@intFromPtr(entry) - @sizeOf(i64));
    const entry_bytes: isize = @bitCast(@intFromPtr(entry));
    const pc_addr: [*]const u32 = @ptrFromInt(@as(usize, @bitCast(entry_bytes +% @as(isize, @intCast(pc_off)))));
    return makeCcEntry(pc_addr);
}

pub fn readUuoSymbol(saddr: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return saddr[0];
}

pub fn readUuoFrameSize(saddr: [*]obj.SchemeObject) callconv(.c) c_uint {
    if (is_big_endian) {
        return @intCast(saddr[2] & 0xffff);
    }
    return @intCast(saddr[1] & 0xffff);
}

pub fn readUuoTarget(saddr: [*]obj.SchemeObject) callconv(.c) [*]u32 {
    return @ptrFromInt(@as(usize, @intCast(saddr[0])));
}

pub fn readUuoTargetNoReloc(saddr: [*]obj.SchemeObject) callconv(.c) [*]u32 {
    return readUuoTarget(saddr);
}

pub fn writeUuoTarget(target: [*]u32, saddr: [*]obj.SchemeObject) callconv(.c) void {
    saddr[0] = @intCast(@intFromPtr(target));

    const ioff: usize = if (is_big_endian) 2 else 3;
    const iaddr: [*]u32 = @as([*]u32, @ptrCast(saddr)) + ioff;

    // ldr x1, PC-ioff
    const neg_ioff: i32 = -@as(i32, @intCast(ioff));
    iaddr[0] = 0x58000001 | ((@as(u32, @bitCast(neg_ioff)) & 0x7ffff) << 5);

    const target_ts = abi.newspace_to_tospace(@ptrCast(target)).?;
    const target_pc_off = readUnalignedI64(@intFromPtr(target_ts) - @sizeOf(i64));
    if (target_pc_off == 0) {
        const from_pc: isize = @bitCast(@intFromPtr(abi.tospace_to_newspace(@ptrCast(iaddr + 1)).?));
        const to_pc: isize = @bitCast(@intFromPtr(target));
        const offset: isize = to_pc -% from_pc;
        std.debug.assert(@rem(offset, 4) == 0);
        if (offset >= -0x08000000 and offset <= 0x07ffffff) {
            const imm26: u26 = @bitCast(@as(i26, @intCast(offset >> 2)));
            // b target
            iaddr[1] = 0x14000000 | @as(u32, imm26);
        } else {
            // br x1
            iaddr[1] = 0xd61f0020;
        }
    } else {
        iaddr[1] = 0xd1002031; // sub x17, x1, #8
        iaddr[2] = 0xf9400231; // ldr x17, [x17]
        iaddr[3] = 0x8b010231; // add x17, x17, x1
        iaddr[4] = 0xd61f0220; // br x17
    }
}

pub fn trampolineEntrySize(n_entries: usize) callconv(.c) usize {
    return n_entries * objects_per_trampoline_entry;
}

pub fn trampolineEntryAddr(block: [*]obj.SchemeObject, index: usize) callconv(.c) [*]u32 {
    const base: [*]u32 = @ptrCast(block + 2 + (@as(usize, @intCast(index)) * objects_per_trampoline_entry));
    return base + trampoline_entry_padding_size + cc_entry_header_size;
}

pub fn trampolineReturnAddr(block: [*]obj.SchemeObject, index: usize) callconv(.c) [*]u32 {
    return trampolineEntryAddr(block, index);
}

pub fn storeTrampolineInsns(entry: [*]u32, code: u8) callconv(.c) bool {
    (entry - 2)[0] = 0;
    (entry - 1)[0] = 0;
    // movz x17, #code
    entry[0] = 0xd2800011 | (@as(u32, code) << 5);
    // adr x1, storage (pc + 12)
    entry[1] = 0x10000061;
    // br x23
    entry[2] = 0xd61f02e0;
    return false;
}

pub fn storeTrampolineToInterfaceInsns(entry: [*]u32) callconv(.c) bool {
    (entry - 2)[0] = 0;
    (entry - 1)[0] = 0;
    // and x1, x1, #0x03ffffffffffffff
    entry[0] = 0x9240e421;
    // ldr x17, [x1], #8
    entry[1] = 0xf8408431;
    // and x17, x17, #0xff
    entry[2] = 0x92401e31;
    // br x23
    entry[3] = 0xd61f02e0;
    return false;
}

pub fn aarch64ResetHook() callconv(.c) void {
    abi.jit_force_execute_mode();
}

pub fn aarch64FlushICacheRegion(start: ?[*]obj.SchemeObject, nwords: usize) callconv(.c) void {
    abi.jit_flush_icache(@ptrCast(start), nwords * @sizeOf(obj.SchemeObject));
}

pub fn aarch64FlushICache() callconv(.c) void {
    abi.code_arena_flush_icache();
    if (comptime !is_apple_jit) {
        const cs = @as(*const ?[*]obj.SchemeObject, @ptrCast(&abi.constant_start)).*;
        const free = @as(*const ?[*]obj.SchemeObject, @ptrCast(&abi.Free)).*;
        if (cs != null and free != null and @intFromPtr(free.?) > @intFromPtr(cs.?)) {
            aarch64FlushICacheRegion(cs, (@intFromPtr(free.?) - @intFromPtr(cs.?)) / @sizeOf(obj.SchemeObject));
        }
    }
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
    @export(&storeTrampolineToInterfaceInsns, .{ .name = "store_trampoline_to_interface_insns" });
    @export(&aarch64ResetHook, .{ .name = "aarch64_reset_hook" });
    @export(&aarch64FlushICacheRegion, .{ .name = "aarch64_flush_i_cache_region" });
    @export(&aarch64FlushICache, .{ .name = "aarch64_flush_i_cache" });
}

test "aarch64 cc_entry type, offset, and branch target decoding" {
    var words: [16]obj.SchemeObject align(16) = @splat(0);
    const insns: [*]u32 = @ptrCast(&words);
    const entry: [*]u32 = insns + 6;

    var cet: abi.CcEntryType = undefined;
    abi.make_compiled_procedure_type(&cet, 2, 1, true);
    try std.testing.expect(!writeCcEntryType(&cet, entry));

    var decoded_cet: abi.CcEntryType = undefined;
    try std.testing.expect(!readCcEntryType(&decoded_cet, entry));
    try std.testing.expectEqual(abi.CcEntryTypeMarker.procedure, decoded_cet.marker);
    try std.testing.expectEqual(@as(c_uint, 2), decoded_cet.args.for_procedure.n_required);
    try std.testing.expectEqual(@as(c_uint, 1), decoded_cet.args.for_procedure.n_optional);
    try std.testing.expect(decoded_cet.args.for_procedure.rest_p);

    var ceo: abi.CcEntryOffset = .{ .offset = 6, .continued_p = true };
    try std.testing.expect(!writeCcEntryOffset(&ceo, entry));
    var decoded_ceo: abi.CcEntryOffset = undefined;
    try std.testing.expect(!readCcEntryOffset(&decoded_ceo, entry));
    try std.testing.expectEqual(@as(usize, 6), decoded_ceo.offset);
    try std.testing.expect(decoded_ceo.continued_p);

    const too_far: abi.CcEntryOffset = .{ .offset = 0x4000, .continued_p = false };
    var too_far_mut = too_far;
    try std.testing.expect(writeCcEntryOffset(&too_far_mut, entry));

    // Forward B +3 insns, backward B -2 insns, non-B passthrough
    insns[4] = 0x14000003;
    try std.testing.expectEqual(insns + 7, ccReturnAddressToEntryAddress(insns + 4));
    insns[4] = 0x17fffffe;
    try std.testing.expectEqual(insns + 2, ccReturnAddressToEntryAddress(insns + 4));
    insns[4] = 0xd65f03c0; // ret
    try std.testing.expectEqual(insns + 4, ccReturnAddressToEntryAddress(insns + 4));
}

test "aarch64 closures, uuo links, and trampolines" {
    // Layout matching aarch64.h 1-entry closure block (7 words):
    // [0] manifest_closure(6) [1] count=1 + hdr [2] pc_off [3] slot0 [4] pc_off? ...
    // Actually: +1 is start; entry = start + 4 (16 bytes -> word[3]); end word = block[6].
    var closure_block: [12]obj.SchemeObject align(16) = @splat(0);
    closure_block[0] = obj.makeObject(obj.tc_manifest_closure, 6);
    @as(*u32, @ptrCast(&closure_block[1])).* = 1;

    var code_target: [8]obj.SchemeObject align(16) = @splat(0);
    const target_entry: [*]u32 = @as([*]u32, @ptrCast(&code_target)) + 4;
    // Direct entry has pc_offset == 0 at i64[-1]

    const start = compiledClosureStart(closure_block[1..].ptr);
    try std.testing.expectEqual(@as(usize, 1), compiledClosureCount(closure_block[1..].ptr));
    const entry0 = compiledClosureEntry(start);
    try std.testing.expectEqual(@as(usize, @intFromPtr(&closure_block[3])), @intFromPtr(entry0));
    try std.testing.expectEqual(entry0, compiledClosureNext(start));
    try std.testing.expectEqual(closure_block[3..].ptr, skipCompiledClosurePadding(entry0));

    writeCompiledClosureTarget(target_entry, start);
    closure_block[6] = makeCcEntry(entry0);

    var ref: abi.RelocRef = undefined;
    startClosureRelocation(&closure_block, &ref);
    try std.testing.expectEqual(@intFromPtr(entry0), @intFromPtr(ref.old_addr.?));
    try std.testing.expectEqual(@intFromPtr(entry0), @intFromPtr(ref.new_addr.?));
    try std.testing.expectEqual(target_entry, readCompiledClosureTarget(start, &ref));
    try std.testing.expectEqual(target_entry, readCompiledClosureTarget(start, null));
    try std.testing.expectEqual(makeCcEntry(target_entry), compiledClosureEntryToTarget(entry0));

    // UUO link near branch vs closure indirect branch
    var uuo: [8]obj.SchemeObject align(16) = @splat(0);
    uuo[0] = obj.makeObject(obj.tc_interned_symbol, 42);
    uuo[1] = obj.longToUnsignedFixnum(3);
    try std.testing.expectEqual(uuo[0], readUuoSymbol(&uuo));
    try std.testing.expectEqual(@as(c_uint, 3), readUuoFrameSize(&uuo));

    writeUuoTarget(target_entry, &uuo);
    try std.testing.expectEqual(target_entry, readUuoTarget(&uuo));
    try std.testing.expectEqual(target_entry, readUuoTargetNoReloc(&uuo));
    const uuo_insns: [*]u32 = @ptrCast(&uuo);
    try std.testing.expectEqual(@as(u32, 0x58ffffa1), uuo_insns[3]);
    try std.testing.expectEqual(@as(u32, 0x14000000), uuo_insns[4] & 0xfc000000);
    try std.testing.expectEqual(target_entry, ccReturnAddressToEntryAddress(uuo_insns + 4));

    // Closure target has non-zero pc_offset => emits indirect sequence
    writeUuoTarget(entry0, &uuo);
    try std.testing.expectEqual(@as(u32, 0xd1002031), uuo_insns[4]);
    try std.testing.expectEqual(@as(u32, 0xd61f0220), uuo_insns[7]);

    // Trampoline encoding
    var tramp_block: [12]obj.SchemeObject align(16) = @splat(0);
    try std.testing.expectEqual(@as(usize, 8), trampolineEntrySize(2));
    try std.testing.expectEqual(tramp_block[0..].ptr, @as([*]obj.SchemeObject, @ptrCast(&tramp_block)));
    const t0 = trampolineEntryAddr(&tramp_block, 0);
    try std.testing.expectEqual(t0, trampolineReturnAddr(&tramp_block, 0));
    try std.testing.expect(!storeTrampolineInsns(t0, abi.trampoline_k_apply));
    try std.testing.expectEqual(@as(u32, 0xd2800011 | (@as(u32, abi.trampoline_k_apply) << 5)), t0[0]);
    try std.testing.expectEqual(@as(u32, 0x10000061), t0[1]);
    try std.testing.expectEqual(@as(u32, 0xd61f02e0), t0[2]);

    const t1 = trampolineEntryAddr(&tramp_block, 1);
    try std.testing.expect(!storeTrampolineToInterfaceInsns(t1));
    try std.testing.expectEqual(@as(u32, 0x9240e421), t1[0]);
    try std.testing.expectEqual(@as(u32, 0xd61f02e0), t1[3]);
}
