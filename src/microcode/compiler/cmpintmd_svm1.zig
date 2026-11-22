// Derived from MIT/GNU Scheme C sources (`src/microcode/cmpintmd/svm1.c`, `src/microcode/cmpintmd/svm1.h`, `src/microcode/svm1-defns.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");

pub const cc_entry_type_size: usize = 2;
pub const cc_entry_offset_size: usize = 2;
pub const cc_entry_header_size: usize = cc_entry_type_size + cc_entry_offset_size;

pub const closure_count_size: usize = 2;
pub const closure_entry_offset: usize = @sizeOf(obj.SchemeObject);
pub const closure_entry_start: usize = closure_entry_offset - cc_entry_type_size;
pub const closure_entry_size: usize = 5;

pub const svm1_inst_enter_closure: u8 = 0x22;
pub const svm1_inst_trap_trap_0: u8 = 0x8f;

pub const svm1_trap_0_operator_1_0: u8 = 0x0b;
pub const svm1_trap_0_operator_2_0: u8 = 0x0c;
pub const svm1_trap_0_operator_2_1: u8 = 0x0d;
pub const svm1_trap_0_operator_3_0: u8 = 0x0e;
pub const svm1_trap_0_operator_3_1: u8 = 0x0f;
pub const svm1_trap_0_operator_3_2: u8 = 0x10;
pub const svm1_trap_0_operator_4_0: u8 = 0x11;
pub const svm1_trap_0_operator_4_1: u8 = 0x12;
pub const svm1_trap_0_operator_4_2: u8 = 0x13;
pub const svm1_trap_0_operator_4_3: u8 = 0x14;
pub const svm1_trap_0_operator_apply: u8 = 0x15;
pub const svm1_trap_0_operator_lexpr: u8 = 0x16;
pub const svm1_trap_0_operator_lookup: u8 = 0x17;
pub const svm1_trap_0_operator_primitive: u8 = 0x18;
pub const svm1_trap_0_reflect_to_interface: u8 = 0x1b;
pub const svm1_trap_0_return_to_interpreter: u8 = 0x1d;

pub fn readU16(address: [*]u8) callconv(.c) c_uint {
    return (@as(c_uint, address[1]) << 8) | @as(c_uint, address[0]);
}

fn writeU16(n: c_uint, address: [*]u8) void {
    address[0] = @truncate(n & 0x00FF);
    address[1] = @truncate(n >> 8);
}

pub fn readCcEntryType(cet: *abi.CcEntryType, address: [*]u8) callconv(.c) bool {
    if (address[0] == svm1_inst_enter_closure) {
        const n = readU16(address - 2);
        abi.make_compiled_procedure_type(
            cet,
            @intCast(n & 0x007F),
            @intCast((n & 0x3F80) >> 7),
            (n & 0x4000) != 0,
        );
        return false;
    }
    const n = readU16(address - 4);
    if (n < 0x8000) {
        abi.make_compiled_procedure_type(
            cet,
            @intCast(n & 0x007F),
            @intCast((n & 0x3F80) >> 7),
            (n & 0x4000) != 0,
        );
    } else if (n < 0xFFF8) {
        abi.make_compiled_continuation_type(cet, @intCast(n - 0x8000));
    } else {
        const marker: abi.CcEntryTypeMarker = switch (n - 0xFFF8) {
            6 => .expression,
            5 => .internal_procedure,
            4 => .internal_continuation,
            3 => .trampoline,
            2 => .return_to_interpreter,
            else => return true,
        };
        abi.make_cc_entry_type(cet, marker);
    }
    return false;
}

pub fn writeCcEntryType(cet: *abi.CcEntryType, address: [*]u8) callconv(.c) bool {
    const n: c_uint = switch (cet.marker) {
        .procedure => blk: {
            const req = cet.args.for_procedure.n_required;
            const opt = cet.args.for_procedure.n_optional;
            if (!(req < 0x80 and opt < 0x80)) return true;
            break :blk req | (opt << 7) | (if (cet.args.for_procedure.rest_p) @as(c_uint, 0x4000) else 0);
        },
        .continuation => blk: {
            const off = cet.args.for_continuation.offset;
            if (!(off < 0x7FF8)) return true;
            break :blk @intCast(off + 0x8000);
        },
        .expression => 0xFFF8 + 6,
        .internal_procedure => 0xFFF8 + 5,
        .internal_continuation => 0xFFF8 + 4,
        .trampoline => 0xFFF8 + 3,
        .return_to_interpreter => 0xFFF8 + 2,
        else => return true,
    };
    writeU16(n, address - 4);
    return false;
}

pub fn readCcEntryOffset(ceo: *abi.CcEntryOffset, address: [*]u8) callconv(.c) bool {
    if (address[0] == svm1_inst_enter_closure) {
        const index = readU16(address + 1);
        ceo.offset = @intCast(@sizeOf(obj.SchemeObject) + closure_entry_offset + (@as(usize, @intCast(index)) * closure_entry_size));
        ceo.continued_p = false;
    } else {
        const n = readU16(address - 2);
        ceo.offset = @intCast(n >> 1);
        ceo.continued_p = (n & 1) != 0;
    }
    return false;
}

pub fn writeCcEntryOffset(ceo: *abi.CcEntryOffset, address: [*]u8) callconv(.c) bool {
    const code: c_uint = @truncate(ceo.offset << 1);
    writeU16(code + @as(c_uint, @intFromBool(ceo.continued_p)), address - 2);
    return false;
}

pub fn compiledClosureCount(block: [*]obj.SchemeObject) callconv(.c) usize {
    return @intCast(readU16(@ptrCast(block)));
}

pub fn compiledClosureStart(block: [*]obj.SchemeObject) callconv(.c) [*]u8 {
    return @as([*]u8, @ptrCast(block)) + closure_entry_start;
}

pub fn compiledClosureNext(start: [*]u8) callconv(.c) [*]u8 {
    return start + closure_entry_size;
}

pub fn skipCompiledClosurePadding(start: [*]u8) callconv(.c) [*]obj.SchemeObject {
    const mask: usize = @sizeOf(obj.SchemeObject) - 1;
    return @ptrFromInt((@intFromPtr(start) + mask) & ~mask);
}

pub fn compiledClosureEntryToTarget(entry: [*]u8) callconv(.c) obj.SchemeObject {
    const index: usize = @intCast(readU16(entry + 1));
    const block: [*]u8 = entry - (closure_entry_offset + (index * closure_entry_size));
    const count: usize = @intCast(readU16(block));
    const targets = skipCompiledClosurePadding(block + (closure_entry_start + (count * closure_entry_size)));
    return targets[index];
}

pub fn readUuoFrameSize(saddr: [*]obj.SchemeObject) callconv(.c) c_uint {
    return @intCast(obj.objectDatum(saddr[0]));
}

pub fn readUuoSymbol(saddr: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return saddr[1];
}

pub fn readUuoTarget(saddr: [*]obj.SchemeObject) callconv(.c) [*]u8 {
    return @ptrFromInt(@as(usize, @intCast(saddr[1])));
}

pub fn readUuoTargetNoReloc(saddr: [*]obj.SchemeObject) callconv(.c) [*]u8 {
    return readUuoTarget(saddr);
}

pub fn writeUuoTarget(target: [*]u8, saddr: [*]obj.SchemeObject) callconv(.c) void {
    saddr[1] = @intCast(@intFromPtr(target));
}

pub fn trampolineEntrySize(n_entries: usize) callconv(.c) usize {
    return obj.bytesToWords(n_entries * (cc_entry_header_size + 2));
}

pub fn trampolineEntryAddr(block: [*]obj.SchemeObject, index: usize) callconv(.c) [*]u8 {
    return @as([*]u8, @ptrCast(block + 2)) + (@as(usize, @intCast(index)) * (cc_entry_header_size + 2)) + cc_entry_header_size;
}

pub fn trampolineReturnAddr(block: [*]obj.SchemeObject, index: usize) callconv(.c) [*]u8 {
    return trampolineEntryAddr(block, index);
}

pub fn storeTrampolineInsns(entry: [*]u8, code: u8) callconv(.c) bool {
    entry[0] = svm1_inst_trap_trap_0;
    entry[1] = switch (code) {
        abi.trampoline_k_return_to_interpreter => svm1_trap_0_return_to_interpreter,
        abi.trampoline_k_apply => svm1_trap_0_operator_apply,
        abi.trampoline_k_lexpr_primitive => svm1_trap_0_operator_lexpr,
        abi.trampoline_k_primitive => svm1_trap_0_operator_primitive,
        abi.trampoline_k_lookup => svm1_trap_0_operator_lookup,
        abi.trampoline_k_1_0 => svm1_trap_0_operator_1_0,
        abi.trampoline_k_2_1 => svm1_trap_0_operator_2_1,
        abi.trampoline_k_2_0 => svm1_trap_0_operator_2_0,
        abi.trampoline_k_3_2 => svm1_trap_0_operator_3_2,
        abi.trampoline_k_3_1 => svm1_trap_0_operator_3_1,
        abi.trampoline_k_3_0 => svm1_trap_0_operator_3_0,
        abi.trampoline_k_4_3 => svm1_trap_0_operator_4_3,
        abi.trampoline_k_4_2 => svm1_trap_0_operator_4_2,
        abi.trampoline_k_4_1 => svm1_trap_0_operator_4_1,
        abi.trampoline_k_4_0 => svm1_trap_0_operator_4_0,
        abi.trampoline_k_reflect_to_interface => svm1_trap_0_reflect_to_interface,
        else => return true,
    };
    return false;
}

pub fn exportAll() void {
    @export(&readU16, .{ .name = "read_u16" });
    @export(&readCcEntryType, .{ .name = "read_cc_entry_type" });
    @export(&writeCcEntryType, .{ .name = "write_cc_entry_type" });
    @export(&readCcEntryOffset, .{ .name = "read_cc_entry_offset" });
    @export(&writeCcEntryOffset, .{ .name = "write_cc_entry_offset" });
    @export(&compiledClosureCount, .{ .name = "compiled_closure_count" });
    @export(&compiledClosureStart, .{ .name = "compiled_closure_start" });
    @export(&compiledClosureNext, .{ .name = "compiled_closure_next" });
    @export(&skipCompiledClosurePadding, .{ .name = "skip_compiled_closure_padding" });
    @export(&compiledClosureEntryToTarget, .{ .name = "compiled_closure_entry_to_target" });
    @export(&readUuoFrameSize, .{ .name = "read_uuo_frame_size" });
    @export(&readUuoSymbol, .{ .name = "read_uuo_symbol" });
    @export(&readUuoTarget, .{ .name = "read_uuo_target" });
    @export(&readUuoTargetNoReloc, .{ .name = "read_uuo_target_no_reloc" });
    @export(&writeUuoTarget, .{ .name = "write_uuo_target" });
    @export(&trampolineEntrySize, .{ .name = "trampoline_entry_size" });
    @export(&trampolineEntryAddr, .{ .name = "trampoline_entry_addr" });
    @export(&trampolineReturnAddr, .{ .name = "trampoline_return_addr" });
    @export(&storeTrampolineInsns, .{ .name = "store_trampoline_insns" });
}

test "svm1 cc_entry type/offset, closure layout, uuo links, and trampolines" {
    var buf: [64]u8 align(16) = @splat(0);
    const entry = buf[8..].ptr;

    var cet: abi.CcEntryType = undefined;
    var got_cet: abi.CcEntryType = undefined;

    abi.make_compiled_procedure_type(&cet, 3, 2, true);
    try std.testing.expect(!writeCcEntryType(&cet, entry));
    try std.testing.expect(!readCcEntryType(&got_cet, entry));
    try std.testing.expectEqual(abi.CcEntryTypeMarker.procedure, got_cet.marker);
    try std.testing.expectEqual(@as(c_uint, 3), got_cet.args.for_procedure.n_required);
    try std.testing.expectEqual(@as(c_uint, 2), got_cet.args.for_procedure.n_optional);
    try std.testing.expect(got_cet.args.for_procedure.rest_p);

    // ENTER_CLOSURE special decoding reads 16-bit type at entry - 2
    const closure_entry = buf[32..].ptr;
    closure_entry[0] = svm1_inst_enter_closure;
    writeU16(1 | (4 << 7) | 0x4000, closure_entry - 2);
    writeU16(2, closure_entry + 1);
    try std.testing.expect(!readCcEntryType(&got_cet, closure_entry));
    try std.testing.expectEqual(@as(c_uint, 1), got_cet.args.for_procedure.n_required);
    try std.testing.expectEqual(@as(c_uint, 4), got_cet.args.for_procedure.n_optional);
    try std.testing.expect(got_cet.args.for_procedure.rest_p);

    var closure_ceo: abi.CcEntryOffset = undefined;
    try std.testing.expect(!readCcEntryOffset(&closure_ceo, closure_entry));
    try std.testing.expectEqual(
        @as(usize, @sizeOf(obj.SchemeObject) + closure_entry_offset + 2 * closure_entry_size),
        closure_ceo.offset,
    );
    try std.testing.expect(!closure_ceo.continued_p);

    // Special markers + error case
    const special_markers = [_]abi.CcEntryTypeMarker{
        .expression,
        .internal_procedure,
        .internal_continuation,
        .trampoline,
        .return_to_interpreter,
    };
    for (special_markers) |m| {
        abi.make_cc_entry_type(&cet, m);
        try std.testing.expect(!writeCcEntryType(&cet, entry));
        try std.testing.expect(!readCcEntryType(&got_cet, entry));
        try std.testing.expectEqual(m, got_cet.marker);
    }
    abi.make_cc_entry_type(&cet, .closure);
    try std.testing.expect(writeCcEntryType(&cet, entry));
    writeU16(0xFFFF, entry - 4);
    try std.testing.expect(readCcEntryType(&got_cet, entry));

    var ceo: abi.CcEntryOffset = .{ .offset = 120, .continued_p = true };
    try std.testing.expect(!writeCcEntryOffset(&ceo, entry));
    var got_ceo: abi.CcEntryOffset = undefined;
    try std.testing.expect(!readCcEntryOffset(&got_ceo, entry));
    try std.testing.expectEqual(@as(usize, 120), got_ceo.offset);
    try std.testing.expect(got_ceo.continued_p);

    // 64-bit closure layout matching svm1.c doc comment (lines 220-247)
    var cwords: [12]obj.SchemeObject align(16) = @splat(0);
    const block = cwords[1..].ptr;
    writeU16(3, @ptrCast(block));
    var cur = compiledClosureStart(block);
    try std.testing.expectEqual(@as(usize, 3), compiledClosureCount(block));
    try std.testing.expectEqual(@as(usize, @intFromPtr(&cwords[1])) + closure_entry_start, @intFromPtr(cur));
    // Place ENTER_CLOSURE + index 0, 1, 2
    for (0..3) |i| {
        cur[cc_entry_type_size] = svm1_inst_enter_closure;
        writeU16(@intCast(i), cur + cc_entry_type_size + 1);
        cur = compiledClosureNext(cur);
    }
    const targets = skipCompiledClosurePadding(cur);
    targets[0] = obj.makeObject(obj.tc_compiled_entry, 0x1000);
    targets[1] = obj.makeObject(obj.tc_compiled_entry, 0x2000);
    targets[2] = obj.makeObject(obj.tc_compiled_entry, 0x3000);

    const e0 = @as([*]u8, @ptrCast(block)) + closure_entry_offset;
    const e2 = e0 + 2 * closure_entry_size;
    try std.testing.expectEqual(targets[0], compiledClosureEntryToTarget(e0));
    try std.testing.expectEqual(targets[2], compiledClosureEntryToTarget(e2));

    // UUO link
    var uuo: [2]obj.SchemeObject align(16) = .{
        obj.longToUnsignedFixnum(5),
        obj.makeObject(obj.tc_interned_symbol, 99),
    };
    try std.testing.expectEqual(@as(c_uint, 5), readUuoFrameSize(&uuo));
    try std.testing.expectEqual(uuo[1], readUuoSymbol(&uuo));
    writeUuoTarget(entry, &uuo);
    try std.testing.expectEqual(entry, readUuoTarget(&uuo));
    try std.testing.expectEqual(entry, readUuoTargetNoReloc(&uuo));

    // Trampolines
    var tramp_blk: [8]obj.SchemeObject align(16) = @splat(0);
    try std.testing.expectEqual(obj.bytesToWords(3 * 6), trampolineEntrySize(3));
    const te = trampolineEntryAddr(&tramp_blk, 1);
    try std.testing.expectEqual(te, trampolineReturnAddr(&tramp_blk, 1));
    const pairs = [_]struct { k: u8, trap: u8 }{
        .{ .k = abi.trampoline_k_return_to_interpreter, .trap = svm1_trap_0_return_to_interpreter },
        .{ .k = abi.trampoline_k_apply, .trap = svm1_trap_0_operator_apply },
        .{ .k = abi.trampoline_k_lexpr_primitive, .trap = svm1_trap_0_operator_lexpr },
        .{ .k = abi.trampoline_k_primitive, .trap = svm1_trap_0_operator_primitive },
        .{ .k = abi.trampoline_k_lookup, .trap = svm1_trap_0_operator_lookup },
        .{ .k = abi.trampoline_k_1_0, .trap = svm1_trap_0_operator_1_0 },
        .{ .k = abi.trampoline_k_2_1, .trap = svm1_trap_0_operator_2_1 },
        .{ .k = abi.trampoline_k_2_0, .trap = svm1_trap_0_operator_2_0 },
        .{ .k = abi.trampoline_k_3_2, .trap = svm1_trap_0_operator_3_2 },
        .{ .k = abi.trampoline_k_3_1, .trap = svm1_trap_0_operator_3_1 },
        .{ .k = abi.trampoline_k_3_0, .trap = svm1_trap_0_operator_3_0 },
        .{ .k = abi.trampoline_k_4_3, .trap = svm1_trap_0_operator_4_3 },
        .{ .k = abi.trampoline_k_4_2, .trap = svm1_trap_0_operator_4_2 },
        .{ .k = abi.trampoline_k_4_1, .trap = svm1_trap_0_operator_4_1 },
        .{ .k = abi.trampoline_k_4_0, .trap = svm1_trap_0_operator_4_0 },
        .{ .k = abi.trampoline_k_reflect_to_interface, .trap = svm1_trap_0_reflect_to_interface },
    };
    for (pairs) |p| {
        try std.testing.expect(!storeTrampolineInsns(te, p.k));
        try std.testing.expectEqual(svm1_inst_trap_trap_0, te[0]);
        try std.testing.expectEqual(p.trap, te[1]);
    }
    try std.testing.expect(storeTrampolineInsns(te, abi.trampoline_k_arity));
}
