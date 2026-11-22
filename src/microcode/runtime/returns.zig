// Derived from MIT/GNU Scheme C sources (`src/microcode/returns.c`, `src/microcode/returns.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const intern = @import("intern.zig");

const RFT = abi.ReturnFrameType;

const return_code_names_table = [abi.max_return_code + 1]?[*:0]const u8{
    "end-of-computation", // 0x00
    "join-stacklets", // 0x01
    null, // 0x02
    "internal-apply", // 0x03
    null, // 0x04
    "restore-history", // 0x05
    null, // 0x06
    null, // 0x07
    "assignment-continue", // 0x08
    "definition-continue", // 0x09
    "access-continue", // 0x0a
    null, // 0x0b
    "sequence-continue", // 0x0c
    null, // 0x0d
    null, // 0x0e
    "conditional-decide", // 0x0f
    "disjunction-decide", // 0x10
    null, // 0x11
    "combination-apply", // 0x12
    null, // 0x13
    null, // 0x14
    "combination-save-value", // 0x15
    null, // 0x16
    null, // 0x17
    null, // 0x18
    null, // 0x19
    null, // 0x1a
    null, // 0x1b
    "force-snap-thunk", // 0x1c
    "reenter-compiled-code", // 0x1d
    null, // 0x1e
    null, // 0x1f
    "normal-garbage-collect-done", // 0x20
    null, // 0x21
    null, // 0x22
    null, // 0x23
    null, // 0x24
    null, // 0x25
    null, // 0x26
    null, // 0x27
    null, // 0x28
    "pop-from-compiled-code", // 0x29
    null, // 0x2a
    null, // 0x2b
    null, // 0x2c
    null, // 0x2d
    "restore-value", // 0x2e
    "restore-dont-copy-history", // 0x2f
    null, // 0x30
    null, // 0x31
    null, // 0x32
    null, // 0x33
    null, // 0x34
    null, // 0x35
    null, // 0x36
    null, // 0x37
    null, // 0x38
    null, // 0x39
    null, // 0x3a
    null, // 0x3b
    null, // 0x3c
    null, // 0x3d
    null, // 0x3e
    null, // 0x3f
    "pop-return-error", // 0x40
    "eval-error", // 0x41
    "stack-marker", // 0x42
    "compiler-interrupt-restart", // 0x43
    null, // 0x44
    "restore-interrupt-mask", // 0x45
    "halt", // 0x46
    null, // 0x47
    null, // 0x48
    null, // 0x49
    null, // 0x4a
    null, // 0x4b
    null, // 0x4c
    null, // 0x4d
    null, // 0x4e
    null, // 0x4f
    null, // 0x50
    null, // 0x51
    null, // 0x52
    "compiler-reference-trap-restart", // 0x53
    "compiler-assignment-trap-restart", // 0x54
    null, // 0x55
    "compiler-operator-lookup-trap-restart", // 0x56
    "compiler-lookup-apply-trap-restart", // 0x57
    "compiler-safe-reference-trap-restart", // 0x58
    "compiler-unassigned?-trap-restart", // 0x59
    null, // 0x5a
    "compiler-link-caches-restart", // 0x5b
    "hardware-trap", // 0x5c
    "internal-apply-val", // 0x5d
    "compiler-error-restart", // 0x5e
};

const return_frame_type_names_table = [@backingInt(RFT.limit)]?[*:0]const u8{
    null,
    "with-arg",
    "with-arg-subproblem",
    "exp+env",
    "history",
    "apply",
    "combination-apply",
    "return-to-compiled-code",
    "return-to-compiled-code-subproblem",
    "compiled-address",
    "combination-save",
    "stack-marker",
    "hardware-trap",
    "return-to-interpreter",
    "cc-internal-apply",
    "cc-restore-interrupt-mask",
    "cc-stack-marker",
    "cc-bpkt",
    "cc-invocation",
};

const return_frame_types_table = [abi.max_return_code + 1]RFT{
    .with_arg, // 0x00 arg: ignored?
    .with_arg, // 0x01 arg: control point
    .undefined, // 0x02
    .apply, // 0x03
    .undefined, // 0x04
    .history, // 0x05
    .undefined, // 0x06
    .undefined, // 0x07
    .exp_env, // 0x08
    .exp_env, // 0x09
    .with_arg_subproblem, // 0x0a arg: expression
    .undefined, // 0x0b
    .exp_env, // 0x0c
    .undefined, // 0x0d
    .undefined, // 0x0e
    .exp_env, // 0x0f
    .exp_env, // 0x10
    .undefined, // 0x11
    .combination_apply, // 0x12
    .undefined, // 0x13
    .undefined, // 0x14
    .combination_save, // 0x15
    .undefined, // 0x16
    .undefined, // 0x17
    .undefined, // 0x18
    .undefined, // 0x19
    .undefined, // 0x1a
    .undefined, // 0x1b
    .with_arg_subproblem, // 0x1c arg: delayed
    .compiled_code, // 0x1d
    .undefined, // 0x1e
    .undefined, // 0x1f
    .with_arg, // 0x20 arg: GC result
    .undefined, // 0x21
    .undefined, // 0x22
    .undefined, // 0x23
    .undefined, // 0x24
    .undefined, // 0x25
    .undefined, // 0x26
    .undefined, // 0x27
    .undefined, // 0x28
    .undefined, // 0x29
    .undefined, // 0x2a
    .undefined, // 0x2b
    .undefined, // 0x2c
    .undefined, // 0x2d
    .with_arg, // 0x2e arg: value
    .history, // 0x2f
    .undefined, // 0x30
    .undefined, // 0x31
    .undefined, // 0x32
    .undefined, // 0x33
    .undefined, // 0x34
    .undefined, // 0x35
    .undefined, // 0x36
    .undefined, // 0x37
    .undefined, // 0x38
    .undefined, // 0x39
    .undefined, // 0x3a
    .undefined, // 0x3b
    .undefined, // 0x3c
    .undefined, // 0x3d
    .undefined, // 0x3e
    .undefined, // 0x3f
    .with_arg, // 0x40 arg: value
    .exp_env, // 0x41
    .stack_marker, // 0x42
    .compiled_code_subproblem, // 0x43
    .undefined, // 0x44
    .with_arg, // 0x45 arg: interrupt mask
    .with_arg, // 0x46 arg: termination code
    .undefined, // 0x47
    .undefined, // 0x48
    .undefined, // 0x49
    .undefined, // 0x4a
    .undefined, // 0x4b
    .undefined, // 0x4c
    .undefined, // 0x4d
    .undefined, // 0x4e
    .undefined, // 0x4f
    .undefined, // 0x50
    .undefined, // 0x51
    .undefined, // 0x52
    .compiled_code_subproblem, // 0x53
    .compiled_code_subproblem, // 0x54
    .undefined, // 0x55
    .compiled_code_subproblem, // 0x56
    .compiled_code_subproblem, // 0x57
    .compiled_code_subproblem, // 0x58
    .compiled_code_subproblem, // 0x59
    .undefined, // 0x5a
    .compiled_code, // 0x5b
    .hardware_trap, // 0x5c
    .apply, // 0x5d
    .compiled_code_subproblem, // 0x5e
};

pub export var MAX_RETURN: usize = abi.max_return_code;

pub export fn make_return_code_names_table() callconv(.c) obj.SchemeObject {
    const table = abi.allocate_vector(abi.max_return_code + 1, true);
    for (0..(abi.max_return_code + 1)) |rc| {
        const val = if (return_code_names_table[rc]) |name|
            intern.char_pointer_to_symbol(name)
        else
            obj.sharp_f;
        obj.vectorSet(table, rc, val);
    }
    return table;
}

pub export fn return_code_name(ret: obj.SchemeObject) callconv(.c) ?[*:0]const u8 {
    std.debug.assert(obj.returnCodeP(ret));
    const index = obj.objectDatum(ret);
    std.debug.assert(index <= abi.max_return_code);
    return return_code_names_table[@intCast(index)];
}

pub export fn return_address_p(object: obj.SchemeObject) callconv(.c) bool {
    if (build_options.cc_support) {
        return obj.returnCodeP(object) or abi.cc_return_address_p(object);
    }
    return obj.returnCodeP(object);
}

pub export fn return_frame_type(frame: [*]obj.SchemeObject) callconv(.c) c_int {
    const ret = frame[0];
    std.debug.assert(return_address_p(ret));
    if (build_options.cc_support) {
        if (obj.ccReturnP(ret)) {
            if (ret == abi.return_to_interpreter) {
                return @backingInt(RFT.return_to_interpreter);
            }
            if (ret == abi.reflect_to_interface) {
                return abi.reflect_to_interface_frame_type(frame);
            }
            return @backingInt(RFT.compiled_address);
        }
        if (obj.ccEntryP(ret)) {
            return @backingInt(RFT.compiled_address);
        }
    }
    return return_code_frame_type(ret);
}

pub export fn return_code_frame_type(ret: obj.SchemeObject) callconv(.c) c_int {
    const rc = obj.objectDatum(ret);
    std.debug.assert(rc <= abi.max_return_code);
    return @backingInt(return_frame_types_table[@intCast(rc)]);
}

const FieldDefn = struct {
    index: c_uint,
    name: ?[*:0]const u8,
};

const with_arg_fields = [_]FieldDefn{
    .{ .index = 1, .name = null },
};

const exp_env_fields = [_]FieldDefn{
    .{ .index = 1, .name = "expression" },
    .{ .index = abi.cont_size, .name = "environment" },
};

const history_fields = [_]FieldDefn{
    .{ .index = 1, .name = "history" },
    .{ .index = abi.cont_size, .name = "previous-restore-history-offset" },
};

const apply_fields = [_]FieldDefn{
    .{ .index = abi.cont_size + 1, .name = "procedure" },
    .{ .index = abi.cont_size + 2, .name = "arguments" },
};

const compiled_code_fields = [_]FieldDefn{
    .{ .index = 1, .name = "last-return-code" },
};

const combination_apply_fields = [_]FieldDefn{
    .{ .index = 1, .name = "expression" },
    .{ .index = abi.cont_size + 2, .name = "arguments" },
};

const combination_save_fields = [_]FieldDefn{
    .{ .index = 1, .name = "expression" },
    .{ .index = abi.cont_size, .name = "environment" },
    .{ .index = abi.cont_size + 1, .name = "number-of-blanks" },
    .{ .index = abi.cont_size + 2, .name = "saved-args" },
};

const stack_marker_fields = [_]FieldDefn{
    .{ .index = 1, .name = "marker-type" },
    .{ .index = abi.cont_size, .name = "marker-instance" },
};

const hardware_trap_fields = [_]FieldDefn{
    .{ .index = 1, .name = "signal-number" },
    .{ .index = abi.cont_size, .name = "signal-name" },
    .{ .index = abi.cont_size + 1, .name = "code-name" },
    .{ .index = abi.cont_size + 2, .name = "sp-valid?" },
    .{ .index = abi.cont_size + 3, .name = "recovery-state" },
    .{ .index = abi.cont_size + 4, .name = "pc-info-1" },
    .{ .index = abi.cont_size + 5, .name = "pc-info-2" },
    .{ .index = abi.cont_size + 6, .name = "extra-info" },
};

const cc_int_mask_fields = [_]FieldDefn{
    .{ .index = abi.cont_size, .name = "interrupt-mask" },
};

const cc_stack_marker_fields = [_]FieldDefn{
    .{ .index = abi.cont_size, .name = "marker-type" },
    .{ .index = abi.cont_size + 1, .name = "marker-instance" },
};

const cc_invocation_fields = [_]FieldDefn{
    .{ .index = abi.cont_size, .name = "procedure" },
    .{ .index = abi.cont_size + 1, .name = "arguments" },
};

const cc_ref_trap_fields = [_]FieldDefn{
    .{ .index = 1, .name = "last-return-code" },
    .{ .index = abi.cont_size, .name = "variable" },
    .{ .index = abi.cont_size + 1, .name = "environment" },
};

const cc_set_trap_fields = [_]FieldDefn{
    .{ .index = 1, .name = "last-return-code" },
    .{ .index = abi.cont_size, .name = "variable" },
    .{ .index = abi.cont_size + 1, .name = "environment" },
    .{ .index = abi.cont_size + 2, .name = "value" },
};

const cc_ref_apply_trap_fields = [_]FieldDefn{
    .{ .index = 1, .name = "last-return-code" },
    .{ .index = abi.cont_size, .name = "variable" },
    .{ .index = abi.cont_size + 1, .name = "environment" },
    .{ .index = abi.cont_size + 4, .name = "arguments" },
};

const cc_error_restart_fields = [_]FieldDefn{
    .{ .index = 1, .name = "last-return-code" },
    .{ .index = abi.cont_size, .name = "primitive" },
};

const cc_interrupt_restart_fields = [_]FieldDefn{
    .{ .index = 1, .name = "last-return-code" },
    .{ .index = abi.cont_size, .name = "state" },
    .{ .index = abi.cont_size + 1, .name = null },
};

fn fillFieldInfo(v: obj.SchemeObject, start_idx: usize, fields: []const FieldDefn) void {
    var i = start_idx;
    for (fields) |field| {
        const name_val = if (field.name) |name|
            intern.char_pointer_to_symbol(name)
        else
            obj.sharp_f;
        obj.vectorSet(v, i, name_val);
        i += 1;
        obj.vectorSet(v, i, obj.ulongToFixnum(field.index));
        i += 1;
    }
}

fn makeFtitEntry(rft: RFT, subp: bool, history_subp: bool, fields: []const FieldDefn) obj.SchemeObject {
    const entry = abi.allocate_vector((2 * fields.len) + 3, true);
    const type_idx: usize = @intCast(@backingInt(rft));
    obj.vectorSet(entry, 0, intern.char_pointer_to_symbol(return_frame_type_names_table[type_idx].?));
    obj.vectorSet(entry, 1, obj.booleanToObject(subp));
    obj.vectorSet(entry, 2, obj.booleanToObject(history_subp));
    fillFieldInfo(entry, 3, fields);
    return entry;
}

fn setFtitEntry(table: obj.SchemeObject, rft: RFT, subp: bool, history_subp: bool, fields: []const FieldDefn) void {
    obj.vectorSet(table, @intCast(@backingInt(rft)), makeFtitEntry(rft, subp, history_subp, fields));
}

pub export fn make_frame_type_info_table() callconv(.c) obj.SchemeObject {
    const table = abi.allocate_vector(@intCast(@backingInt(RFT.limit)), true);
    obj.vectorSet(table, @intCast(@backingInt(RFT.undefined)), obj.sharp_f);
    setFtitEntry(table, .with_arg, false, false, &with_arg_fields);
    setFtitEntry(table, .with_arg_subproblem, true, true, &with_arg_fields);
    setFtitEntry(table, .exp_env, true, true, &exp_env_fields);
    setFtitEntry(table, .history, false, false, &history_fields);
    setFtitEntry(table, .apply, true, false, &apply_fields);
    setFtitEntry(table, .combination_apply, true, true, &combination_apply_fields);
    setFtitEntry(table, .compiled_code, false, true, &compiled_code_fields);
    setFtitEntry(table, .compiled_code_subproblem, true, true, &compiled_code_fields);
    setFtitEntry(table, .compiled_address, true, false, &.{});
    setFtitEntry(table, .combination_save, true, true, &combination_save_fields);
    setFtitEntry(table, .stack_marker, false, false, &stack_marker_fields);
    setFtitEntry(table, .hardware_trap, true, false, &hardware_trap_fields);
    setFtitEntry(table, .return_to_interpreter, false, true, &.{});
    setFtitEntry(table, .cc_internal_apply, false, false, &apply_fields);
    setFtitEntry(table, .cc_restore_interrupt_mask, false, false, &cc_int_mask_fields);
    setFtitEntry(table, .cc_stack_marker, false, false, &cc_stack_marker_fields);
    setFtitEntry(table, .cc_bkpt, true, false, &cc_invocation_fields);
    setFtitEntry(table, .cc_invocation, false, false, &cc_invocation_fields);
    return table;
}

fn makeFcitEntry(fields: []const FieldDefn) obj.SchemeObject {
    const entry = abi.allocate_vector(2 * fields.len, true);
    fillFieldInfo(entry, 0, fields);
    return entry;
}

pub export fn make_frame_code_info_table() callconv(.c) obj.SchemeObject {
    const table = abi.make_vector(abi.max_return_code + 1, obj.sharp_f, true);

    const e1 = makeFcitEntry(&cc_ref_trap_fields);
    obj.vectorSet(table, abi.rc_comp_lookup_trap_restart, e1);
    obj.vectorSet(table, abi.rc_comp_safe_ref_trap_restart, e1);
    obj.vectorSet(table, abi.rc_comp_unassigned_trap_restart, e1);

    const e2 = makeFcitEntry(&cc_ref_apply_trap_fields);
    obj.vectorSet(table, abi.rc_comp_op_ref_trap_restart, e2);
    obj.vectorSet(table, abi.rc_comp_cache_ref_apply_restart, e2);

    obj.vectorSet(table, abi.rc_comp_assignment_trap_restart, makeFcitEntry(&cc_set_trap_fields));
    obj.vectorSet(table, abi.rc_comp_error_restart, makeFcitEntry(&cc_error_restart_fields));
    obj.vectorSet(table, abi.rc_comp_interrupt_restart, makeFcitEntry(&cc_interrupt_restart_fields));
    return table;
}

pub export fn cpoint_next_frame(cpoint: obj.SchemeObject, index: usize) callconv(.c) usize {
    const frame = obj.vectorLoc(cpoint, @intCast(index));
    const rft = return_frame_type(frame);
    switch (rft) {
        @backingInt(RFT.with_arg), @backingInt(RFT.with_arg_subproblem) => return index + abi.cont_size,
        @backingInt(RFT.exp_env) => return index + abi.env_cont_size,
        @backingInt(RFT.history) => return index + abi.history_cont_size,
        @backingInt(RFT.stack_marker) => return index + abi.cont_size + 1,
        @backingInt(RFT.hardware_trap) => return index + abi.cont_size + 7,
        @backingInt(RFT.apply),
        @backingInt(RFT.combination_apply),
        @backingInt(RFT.cc_internal_apply),
        => {
            const header = frame[abi.cont_size];
            std.debug.assert(obj.vectorHeaderP(header));
            return index + abi.cont_size + 1 + obj.objectDatum(header);
        },
        @backingInt(RFT.combination_save) => {
            const exp = frame[1];
            std.debug.assert(obj.combinationP(exp));
            return index + abi.env_cont_size + obj.vectorLength(exp);
        },
        @backingInt(RFT.compiled_code),
        @backingInt(RFT.compiled_code_subproblem),
        => if (build_options.cc_support) {
            return abi.cpoint_compiled_code_next(cpoint, index);
        },
        @backingInt(RFT.compiled_address) => if (build_options.cc_support) {
            return abi.cpoint_compiled_address_next(cpoint, index);
        },
        @backingInt(RFT.return_to_interpreter) => if (build_options.cc_support) {
            return index + 1;
        },
        @backingInt(RFT.cc_restore_interrupt_mask),
        @backingInt(RFT.cc_stack_marker),
        @backingInt(RFT.cc_bkpt),
        @backingInt(RFT.cc_invocation),
        => if (build_options.cc_support) {
            return abi.cpoint_reflect_to_interface_next(cpoint, index);
        },
        else => {},
    }
    return std.math.maxInt(usize);
}

test "returns tables, frame types, and cpoint_next_frame" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    // Set up obarray in fixed_objects so char_pointer_to_symbol works
    const obarray = abi.make_vector(31, obj.empty_list, true);
    const fixobjs = abi.make_vector(0x10, obj.sharp_f, true);
    obj.vectorSet(fixobjs, abi.fixobj_obarray, obarray);
    abi.fixed_objects = fixobjs;

    try std.testing.expectEqual(@as(usize, 0x5E), MAX_RETURN);

    // return_code_name & return_code_frame_type
    const rc_eval_err = obj.makeObject(obj.tc_return_code, 0x41);
    try std.testing.expectEqualStrings("eval-error", std.mem.span(return_code_name(rc_eval_err).?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), return_code_name(obj.makeObject(obj.tc_return_code, 0x02)));
    try std.testing.expectEqual(@backingInt(RFT.exp_env), return_code_frame_type(rc_eval_err));
    try std.testing.expectEqual(@backingInt(RFT.compiled_code_subproblem), return_code_frame_type(obj.makeObject(obj.tc_return_code, abi.rc_comp_error_restart)));

    // make_return_code_names_table
    const rc_names = make_return_code_names_table();
    try std.testing.expectEqual(@as(usize, 95), obj.vectorLength(rc_names));
    try std.testing.expect(obj.internedSymbolP(obj.vectorRef(rc_names, 0x00)));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(rc_names, 0x02));
    try std.testing.expectEqual(intern.char_pointer_to_symbol("compiler-error-restart"), obj.vectorRef(rc_names, 0x5E));

    // make_frame_type_info_table (preserving upstream "cc-bpkt" spelling)
    const fti = make_frame_type_info_table();
    try std.testing.expectEqual(@as(usize, @backingInt(RFT.limit)), obj.vectorLength(fti));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(fti, 0));
    const cc_bkpt_entry = obj.vectorRef(fti, @backingInt(RFT.cc_bkpt));
    try std.testing.expectEqual(intern.char_pointer_to_symbol("cc-bpkt"), obj.vectorRef(cc_bkpt_entry, 0));
    try std.testing.expectEqual(obj.sharp_t, obj.vectorRef(cc_bkpt_entry, 1));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(cc_bkpt_entry, 2));

    // make_frame_code_info_table shares entries as in C
    const fci = make_frame_code_info_table();
    try std.testing.expectEqual(@as(usize, 95), obj.vectorLength(fci));
    try std.testing.expectEqual(obj.sharp_f, obj.vectorRef(fci, 0x00));
    const e1 = obj.vectorRef(fci, abi.rc_comp_lookup_trap_restart);
    try std.testing.expectEqual(e1, obj.vectorRef(fci, abi.rc_comp_safe_ref_trap_restart));
    try std.testing.expectEqual(e1, obj.vectorRef(fci, abi.rc_comp_unassigned_trap_restart));
    const e2 = obj.vectorRef(fci, abi.rc_comp_op_ref_trap_restart);
    try std.testing.expectEqual(e2, obj.vectorRef(fci, abi.rc_comp_cache_ref_apply_restart));

    // Build synthetic combination object for RFT_COMBINATION_SAVE test
    const comb = abi.allocate_marked_vector(obj.tc_combination, 4, true);

    // cpoint_next_frame across interpreter and compiled-code frames
    const cpoint = abi.allocate_vector(40, true);
    // 0: WITH_ARG (0x20) -> 0 + 2 = 2
    obj.vectorSet(cpoint, 0, obj.makeObject(obj.tc_return_code, 0x20));
    try std.testing.expectEqual(@as(usize, 2), cpoint_next_frame(cpoint, 0));
    // 2: EXP_ENV (0x08) -> 2 + 3 = 5
    obj.vectorSet(cpoint, 2, obj.makeObject(obj.tc_return_code, 0x08));
    try std.testing.expectEqual(@as(usize, 5), cpoint_next_frame(cpoint, 2));
    // 5: HISTORY (0x05) -> 5 + 4 = 9
    obj.vectorSet(cpoint, 5, obj.makeObject(obj.tc_return_code, 0x05));
    try std.testing.expectEqual(@as(usize, 9), cpoint_next_frame(cpoint, 5));
    // 9: STACK_MARKER (0x42) -> 9 + 3 = 12
    obj.vectorSet(cpoint, 9, obj.makeObject(obj.tc_return_code, 0x42));
    try std.testing.expectEqual(@as(usize, 12), cpoint_next_frame(cpoint, 9));
    // 12: HARDWARE_TRAP (0x5C) -> 12 + 9 = 21
    obj.vectorSet(cpoint, 12, obj.makeObject(obj.tc_return_code, abi.rc_hardware_trap));
    try std.testing.expectEqual(@as(usize, 21), cpoint_next_frame(cpoint, 12));
    // 21: APPLY (0x03) with AF header size 3 -> 21 + 2 + 1 + 3 = 27
    obj.vectorSet(cpoint, 21, obj.makeObject(obj.tc_return_code, 0x03));
    obj.vectorSet(cpoint, 23, obj.makeObject(obj.tc_manifest_vector, 3));
    try std.testing.expectEqual(@as(usize, 27), cpoint_next_frame(cpoint, 21));
    // 27: COMBINATION_SAVE (0x15) with comb length 4 -> 27 + 3 + 4 = 34
    obj.vectorSet(cpoint, 27, obj.makeObject(obj.tc_return_code, 0x15));
    obj.vectorSet(cpoint, 28, comb);
    try std.testing.expectEqual(@as(usize, 34), cpoint_next_frame(cpoint, 27));

    try std.testing.expect(return_address_p(obj.makeObject(obj.tc_return_code, 0x00)));
    if (build_options.cc_support) {
        obj.vectorSet(cpoint, 34, abi.return_to_interpreter);
        try std.testing.expectEqual(@backingInt(RFT.return_to_interpreter), return_frame_type(obj.vectorLoc(cpoint, 34)));
        try std.testing.expectEqual(@as(usize, 35), cpoint_next_frame(cpoint, 34));

        obj.vectorSet(cpoint, 35, abi.reflect_to_interface);
        obj.vectorSet(cpoint, 36, obj.ulongToFixnum(2));
        try std.testing.expectEqual(@backingInt(RFT.cc_stack_marker), return_frame_type(obj.vectorLoc(cpoint, 35)));
        try std.testing.expectEqual(@as(usize, 40), cpoint_next_frame(cpoint, 35));

        obj.vectorSet(cpoint, 37, obj.makeObject(obj.tc_compiled_entry, 0x10));
        try std.testing.expectEqual(@backingInt(RFT.compiled_address), return_frame_type(obj.vectorLoc(cpoint, 37)));
        try std.testing.expectEqual(@as(usize, 41), cpoint_next_frame(cpoint, 37));
    }
}
