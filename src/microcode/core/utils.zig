// Derived from MIT/GNU Scheme C sources (`src/microcode/utils.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const outf = @import("../support/outf.zig");
const artutl = @import("../arith/artutl.zig");
const bignum = @import("../arith/bignum.zig");
const storage = @import("storage.zig");

pub export var history_register: ?[*]obj.SchemeObject = null;
pub export var prev_restore_history_offset: usize = 0;
pub export var death_blow: isize = 0;

var error_argument: obj.SchemeObject = 0;

fn computeInterruptNumber(masked_interrupts: usize) usize {
    var interrupt_number: usize = 0;
    var bit_mask: usize = 1;
    while (interrupt_number <= abi.max_interrupt_number and (masked_interrupts & bit_mask) == 0) {
        interrupt_number += 1;
        bit_mask <<= 1;
    }
    return interrupt_number;
}

fn computeInterruptHandlerMask(interrupt_masks: obj.SchemeObject, interrupt_number: usize) usize {
    if (obj.vectorP(interrupt_masks) and interrupt_number < obj.vectorLength(interrupt_masks)) {
        const mask = obj.vectorRef(interrupt_masks, @intCast(interrupt_number));
        if (obj.integerP(mask) and artutl.integer_to_ulong_p(mask)) {
            const bit: usize = if (interrupt_number < @bitSizeOf(usize))
                (@as(usize, 1) << @intCast(interrupt_number))
            else
                0;
            return artutl.integer_to_ulong(mask) & ~bit;
        }
    }
    if (interrupt_number <= abi.max_interrupt_number) {
        return (@as(usize, 1) << @intCast(interrupt_number)) - 1;
    }
    return abi.Registers[abi.regblock_int_mask];
}

fn terminateNoInterruptHandler(masked_interrupts: usize) noreturn {
    outf.fatal(
        "\nInterrupts = 0x{x:0>8}, Mask = 0x{x:0>8}, Masked = 0x{x:0>8}\n",
        .{
            abi.Registers[abi.regblock_int_code],
            abi.Registers[abi.regblock_int_mask],
            masked_interrupts,
        },
    );
    abi.Microcode_Termination(abi.term_no_interrupt_handler);
}

pub export fn initialize_interrupt_handler_vector() callconv(.c) obj.SchemeObject {
    return abi.make_vector(abi.max_interrupt_number + 2, obj.sharp_f, false);
}

pub export fn initialize_interrupt_mask_vector() callconv(.c) obj.SchemeObject {
    const v = abi.make_vector(abi.max_interrupt_number + 2, obj.sharp_f, false);
    var interrupt_number: usize = 0;
    while (interrupt_number <= abi.max_interrupt_number) : (interrupt_number += 1) {
        obj.vectorSet(
            v,
            @intCast(interrupt_number),
            artutl.ulong_to_integer((@as(usize, 1) << @intCast(interrupt_number)) - 1),
        );
    }
    return v;
}

pub export fn setup_interrupt(masked_interrupts: usize) callconv(.c) void {
    const interrupt_number = computeInterruptNumber(masked_interrupts);

    if (!obj.vectorP(abi.fixed_objects)) {
        outf.fatal("\nInvalid fixed-objects vector", .{});
        terminateNoInterruptHandler(masked_interrupts);
    }
    const interrupt_handlers = obj.vectorRef(abi.fixed_objects, abi.fixobj_system_interrupt_vector);
    const interrupt_masks = obj.vectorRef(abi.fixed_objects, abi.fixobj_interrupt_mask_vector);
    if (!(obj.vectorP(interrupt_handlers) and interrupt_number < obj.vectorLength(interrupt_handlers))) {
        outf.fatal("\nUnable to get interrupt handler.", .{});
        terminateNoInterruptHandler(masked_interrupts);
    }
    const interrupt_mask = computeInterruptHandlerMask(interrupt_masks, interrupt_number);
    const interrupt_handler = obj.vectorRef(interrupt_handlers, @intCast(interrupt_number));

    stop_history();
    preserve_interrupt_mask();
    abi.stackCheck(4);

    abi.stackPush(obj.ulongToFixnum(abi.Registers[abi.regblock_int_mask]));
    abi.stackPush(obj.ulongToFixnum(abi.Registers[abi.regblock_int_code]));
    abi.stackPush(interrupt_handler);
    abi.stackPush(abi.makeApplyFrameHeader(3));
    abi.setInterruptMask(interrupt_mask);
}

pub export fn err_print(error_code: isize, where: abi.OutfChannel) callconv(.c) void {
    const message: ?[*:0]const u8 = if (error_code >= 0 and error_code <= abi.err_process_terminated)
        storage.Error_Names[@intCast(error_code)]
    else
        null;
    if (message) |msg| {
        outf.print(where, "Error code 0x{x} ({s}).\n", .{ @as(usize, @bitCast(error_code)), msg });
    } else {
        outf.print(where, "Unknown error code 0x{x}.\n", .{@as(usize, @bitCast(error_code))});
    }
}

fn errorDeath(code: isize, message: [*:0]const u8) noreturn {
    death_blow = code;
    outf.fatal("Microcode Error: {s}.\n", .{message});
    err_print(code, outf.fatal_output);
    outf.err("\n**** Stack Trace ****\n\n", .{});
    abi.debug_stack_trace(outf.error_output);
    abi.termination_no_error_handler();
}

pub export fn preserve_interrupt_mask() callconv(.c) void {
    abi.stackCheck(abi.cont_size);
    abi.pushCont(abi.rc_restore_int_mask, obj.ulongToFixnum(abi.Registers[abi.regblock_int_mask]));
}

pub export fn canonicalize_primitive_context() callconv(.c) void {
    const primitive = abi.Registers[abi.regblock_primitive];
    std.debug.assert(obj.primitiveP(primitive));
    const n_args: usize = @intCast(abi.primitiveNArgs(primitive));

    if (build_options.cc_support) {
        if (obj.ccReturnP(abi.stackRef(n_args))) {
            abi.stackPush(primitive);
            abi.stackPush(abi.makeApplyFrameHeader(@intCast(n_args + 1)));
            abi.guarantee_interp_return();
            abi.Registers[abi.regblock_primitive] = obj.sharp_f;
            abi.abort_to_interpreter(abi.prim_apply);
        }
    }

    std.debug.assert(obj.returnCodeP(abi.stackRef(n_args)));
}

pub export fn back_out_of_primitive() callconv(.c) void {
    const primitive = abi.Registers[abi.regblock_primitive];
    std.debug.assert(obj.primitiveP(primitive));
    abi.stackPush(primitive);
    abi.stackPush(abi.makeApplyFrameHeader(abi.primitiveNArgs(primitive) + 1));
    abi.guarantee_interp_return();
    abi.Registers[abi.regblock_primitive] = obj.sharp_f;
    abi.pushCont(abi.rc_internal_apply, obj.sharp_f);
    abi.Registers[abi.regblock_env] = obj.the_null_env;
    abi.Registers[abi.regblock_val] = obj.sharp_f;
}

pub export fn signal_error_from_primitive(error_code: isize) callconv(.c) noreturn {
    abi.abort_to_interpreter(error_code);
}

pub export fn signal_interrupt_from_primitive() callconv(.c) noreturn {
    abi.abort_to_interpreter(abi.prim_interrupt);
}

pub export fn error_wrong_type_arg(n: c_int) callconv(.c) noreturn {
    const error_code: isize = switch (n) {
        1 => abi.err_arg_1_wrong_type,
        2 => abi.err_arg_2_wrong_type,
        3 => abi.err_arg_3_wrong_type,
        4 => abi.err_arg_4_wrong_type,
        5 => abi.err_arg_5_wrong_type,
        6 => abi.err_arg_6_wrong_type,
        7 => abi.err_arg_7_wrong_type,
        8 => abi.err_arg_8_wrong_type,
        9 => abi.err_arg_9_wrong_type,
        10 => abi.err_arg_10_wrong_type,
        else => abi.err_external_return,
    };
    signal_error_from_primitive(error_code);
}

pub export fn error_bad_range_arg(n: c_int) callconv(.c) noreturn {
    const error_code: isize = switch (n) {
        1 => abi.err_arg_1_bad_range,
        2 => abi.err_arg_2_bad_range,
        3 => abi.err_arg_3_bad_range,
        4 => abi.err_arg_4_bad_range,
        5 => abi.err_arg_5_bad_range,
        6 => abi.err_arg_6_bad_range,
        7 => abi.err_arg_7_bad_range,
        8 => abi.err_arg_8_bad_range,
        9 => abi.err_arg_9_bad_range,
        10 => abi.err_arg_10_bad_range,
        else => abi.err_external_return,
    };
    signal_error_from_primitive(error_code);
}

pub export fn error_external_return() callconv(.c) noreturn {
    signal_error_from_primitive(abi.err_external_return);
}

pub export fn error_with_argument(argument: obj.SchemeObject) callconv(.c) noreturn {
    error_argument = argument;
    const is_syscall = obj.vectorP(argument) and
        obj.vectorLength(argument) > 0 and
        obj.vectorRef(argument, 0) == obj.ulongToFixnum(@as(usize, @bitCast(abi.err_in_system_call)));
    signal_error_from_primitive(if (is_syscall) abi.err_in_system_call else abi.err_with_argument);
}

pub export fn error_in_system_call(err: c_int, name: c_int) callconv(.c) noreturn {
    const v = abi.allocate_vector(3, false);
    obj.vectorSet(v, 0, obj.ulongToFixnum(@as(usize, @bitCast(abi.err_in_system_call))));
    obj.vectorSet(v, 1, obj.ulongToFixnum(@as(c_uint, @bitCast(err))));
    obj.vectorSet(v, 2, obj.ulongToFixnum(@as(c_uint, @bitCast(name))));
    error_argument = v;
    signal_error_from_primitive(abi.err_in_system_call);
}

pub export fn error_system_call(code: c_int, name: c_int) callconv(.c) noreturn {
    error_in_system_call(abi.OS_error_code_to_syserr(code), name);
}

pub export fn arg_integer(arg_number: c_int) callconv(.c) isize {
    const object = abi.argRef(@intCast(arg_number));
    if (!obj.integerP(object)) error_wrong_type_arg(arg_number);
    if (!artutl.integer_to_long_p(object)) error_bad_range_arg(arg_number);
    return artutl.integer_to_long(object);
}

pub export fn arg_integer_to_intmax(arg_number: c_int) callconv(.c) i64 {
    const object = abi.argRef(@intCast(arg_number));
    if (!obj.integerP(object)) error_wrong_type_arg(arg_number);
    if (!artutl.integer_to_intmax_p(object)) error_bad_range_arg(arg_number);
    return artutl.integer_to_intmax(object);
}

pub export fn arg_nonnegative_integer(arg_number: c_int) callconv(.c) isize {
    const result = arg_integer(arg_number);
    if (result < 0) error_bad_range_arg(arg_number);
    return result;
}

pub export fn arg_index_integer(arg_number: c_int, upper_limit: isize) callconv(.c) isize {
    const result = arg_integer(arg_number);
    if (result < 0 or result >= upper_limit) error_bad_range_arg(arg_number);
    return result;
}

pub export fn arg_index_integer_to_intmax(arg_number: c_int, upper_limit: i64) callconv(.c) i64 {
    const result = arg_integer_to_intmax(arg_number);
    if (result < 0 or result >= upper_limit) error_bad_range_arg(arg_number);
    return result;
}

pub export fn arg_integer_in_range(arg_number: c_int, lower_limit: isize, upper_limit: isize) callconv(.c) isize {
    const result = arg_integer(arg_number);
    if (result < lower_limit or result >= upper_limit) error_bad_range_arg(arg_number);
    return result;
}

pub export fn arg_ulong_integer(arg_number: c_int) callconv(.c) usize {
    const object = abi.argRef(@intCast(arg_number));
    if (!obj.integerP(object)) error_wrong_type_arg(arg_number);
    if (!artutl.integer_to_ulong_p(object)) error_bad_range_arg(arg_number);
    return artutl.integer_to_ulong(object);
}

pub export fn arg_ulong_index_integer(arg_number: c_int, upper_limit: usize) callconv(.c) usize {
    const result = arg_ulong_integer(arg_number);
    if (result >= upper_limit) error_bad_range_arg(arg_number);
    return result;
}

pub export fn arg_ulong_integer_in_range(arg_number: c_int, lower_limit: usize, upper_limit: usize) callconv(.c) usize {
    const result = arg_ulong_integer(arg_number);
    if (!(result >= lower_limit and result < upper_limit)) error_bad_range_arg(arg_number);
    return result;
}

pub export fn real_number_to_double_p(x: obj.SchemeObject) callconv(.c) bool {
    if (obj.bignumP(x)) return abi.bignumToDoubleP(x);
    if (obj.flonumP(x)) return artutl.flonum_is_finite_p(x);
    return true;
}

pub export fn real_number_to_double(x: obj.SchemeObject) callconv(.c) f64 {
    if (obj.fixnumP(x)) return obj.fixnumToDouble(x);
    if (obj.bignumP(x)) return abi.bignum_to_double(x);
    return obj.flonumToDouble(x);
}

pub export fn arg_real_number(arg_number: c_int) callconv(.c) f64 {
    const number = abi.argRef(@intCast(arg_number));
    if (!obj.realP(number)) error_wrong_type_arg(arg_number);
    if (!real_number_to_double_p(number)) error_bad_range_arg(arg_number);
    return real_number_to_double(number);
}

pub export fn arg_real_in_range(arg_number: c_int, lower_limit: f64, upper_limit: f64) callconv(.c) f64 {
    const result = arg_real_number(arg_number);
    if (result < lower_limit or result > upper_limit) error_bad_range_arg(arg_number);
    return result;
}

// The 32-bit FNV-1a hash.
pub export fn memory_hash(length: usize, vp: ?*const anyopaque) callconv(.c) u32 {
    var result: u32 = 2166136261;
    if (length == 0) return result;
    const scan: [*]const u8 = @ptrCast(vp.?);
    for (scan[0..@intCast(length)]) |b| {
        result ^= @as(u32, b);
        result *%= 16777619;
    }
    return result;
}

pub export fn hashable_object_p(object: obj.SchemeObject) callconv(.c) bool {
    return switch (obj.objectType(object)) {
        obj.tc_bytevector,
        obj.tc_character_string,
        obj.tc_interned_symbol,
        obj.tc_uninterned_symbol,
        obj.tc_big_fixnum,
        obj.tc_big_flonum,
        obj.tc_ratnum,
        obj.tc_complex,
        obj.tc_list,
        obj.tc_weak_cons,
        obj.tc_vector,
        obj.tc_cell,
        => true,
        else => false,
    };
}

pub export fn hash_object(object: obj.SchemeObject) callconv(.c) u32 {
    switch (obj.objectType(object)) {
        obj.tc_bytevector, obj.tc_character_string => {
            return memory_hash(obj.bytevectorLength(object), obj.bytevectorData(object));
        },
        obj.tc_interned_symbol, obj.tc_uninterned_symbol => {
            const name = obj.symbolName(object);
            return memory_hash(obj.bytevectorLength(name), obj.bytevectorData(name));
        },
        obj.tc_big_fixnum => {
            const n_digits: usize = @intCast(bignum.bignumLength(object));
            return memory_hash(n_digits * @sizeOf(isize), bignum.bignumStartPtr(object));
        },
        obj.tc_big_flonum => {
            return memory_hash(obj.floatingVectorLength(object) * @sizeOf(f64), obj.floatingVectorLoc(object, 0));
        },
        obj.tc_ratnum, obj.tc_complex => {
            return combine_hashes(hash_object(obj.memoryRef(object, 0)), hash_object(obj.memoryRef(object, 1)));
        },
        obj.tc_list, obj.tc_weak_cons => {
            return combine_hashes(hash_object(obj.pairCar(object)), hash_object(obj.pairCdr(object)));
        },
        obj.tc_vector => {
            const len: usize = @intCast(obj.vectorLength(object));
            const elems = obj.vectorLoc(object, 0);
            var result = initial_hash();
            for (elems[0..len]) |elem| {
                result = combine_hashes(result, hash_object(elem));
            }
            return result;
        },
        obj.tc_cell => {
            return hash_object(obj.memoryRef(object, 0));
        },
        else => return 0,
    }
}

pub export fn initial_hash() callconv(.c) u32 {
    if (!obj.vectorP(abi.fixed_objects)) return 0;
    const object = obj.vectorRef(abi.fixed_objects, abi.fixobj_initial_hash);
    if (obj.fixnumP(object) and obj.fixnumToUlongP(object)) {
        const value = obj.fixnumToUlong(object);
        if (value <= std.math.maxInt(u32)) {
            return @intCast(value);
        }
    }
    return 0;
}

pub export fn combine_hashes(hash1: u32, hash2: u32) callconv(.c) u32 {
    return (hash1 *% 31) +% hash2;
}

pub export fn interpreter_applicable_p(object_arg: obj.SchemeObject) callconv(.c) bool {
    var object = object_arg;
    while (true) {
        switch (obj.objectType(object)) {
            obj.tc_primitive,
            obj.tc_procedure,
            obj.tc_extended_procedure,
            obj.tc_control_point,
            => return true,
            obj.tc_entity => {
                object = obj.entityOperator(object);
            },
            obj.tc_record => {
                const applicator = abi.record_applicator(object);
                if (applicator == obj.sharp_f) return false;
                object = applicator;
            },
            obj.tc_compiled_entry => {
                if (build_options.cc_support) {
                    var cet: abi.CcEntryType = undefined;
                    return if (abi.read_cc_entry_type(&cet, obj.objectRawAddress(object)))
                        false
                    else
                        (cet.marker == .procedure);
                }
                return false;
            },
            else => return false,
        }
    }
}

pub export fn Do_Micro_Error(error_code: isize, from_pop_return_p: bool) callconv(.c) void {
    var handler: obj.SchemeObject = obj.sharp_f;

    if (build_options.debugging) {
        if (storage.print_errors) {
            err_print(error_code, outf.error_output);
            const ret = abi.Registers[abi.regblock_return];
            if (obj.objectDatum(ret) == abi.rc_internal_apply or
                obj.objectDatum(ret) == abi.rc_internal_apply_val)
            {
                const next_frame = abi.stackLoc(abi.cont_size);
                abi.debug_print_expr(next_frame[1], "Procedure");
                outf.err("\n", .{});

                const args = next_frame + 2;
                const n_args: usize = @intCast(obj.objectDatum(next_frame[0]) - 1);
                var buf: [64]u8 = undefined;
                for (0..n_args) |idx| {
                    const label: [*:0]const u8 = if (std.fmt.bufPrint(buf[0 .. buf.len - 1], "Argument {d}: ", .{idx})) |s| blk: {
                        buf[s.len] = 0;
                        break :blk @ptrCast(&buf);
                    } else |_| "Argument: ";
                    outf.err("{s}", .{label});
                    abi.debug_print_expr(args[idx], "");
                    outf.err("\n", .{});
                }
            } else {
                abi.debug_print_expr(abi.Registers[abi.regblock_expr], "Expression");
                outf.err("\n", .{});
                abi.debug_print_expr(abi.Registers[abi.regblock_env], "Environment");
                outf.err("\n", .{});
            }
            abi.debug_print_expr(ret, "Return code");
            outf.err("\n", .{});
        }
        if (storage.trace_on_error) {
            outf.err("\n\n**** Stack Trace ****\n\n", .{});
            abi.debug_stack_trace(outf.error_output);
        }
        const n_slots: usize = @intCast(storage.local_nslots_storage);
        for (0..n_slots) |idx| {
            storage.debug_circle_storage[idx] = storage.local_circle_storage[idx];
        }
        storage.debug_nslots_storage = storage.local_nslots_storage;
        storage.debug_slotno_storage = storage.local_slotno_storage;
    }

    if (from_pop_return_p) {
        abi.stackCheck(abi.cont_size);
        abi.pushCont(abi.rc_pop_return_error, abi.Registers[abi.regblock_val]);
    } else {
        abi.stackCheck(abi.env_cont_size);
        abi.pushEnvCont(abi.rc_eval_error, abi.Registers[abi.regblock_expr], abi.Registers[abi.regblock_env]);
    }

    var error_vector: obj.SchemeObject = obj.sharp_f;
    if (obj.vectorP(abi.fixed_objects)) {
        error_vector = obj.vectorRef(abi.fixed_objects, abi.fixobj_system_error_vector);
    }
    if (!obj.vectorP(error_vector)) {
        errorDeath(error_code, "No error handlers");
    }
    const err_len = obj.vectorLength(error_vector);
    if (error_code >= 0 and @as(usize, @intCast(error_code)) < err_len) {
        handler = obj.vectorRef(error_vector, @intCast(error_code));
    } else if (abi.err_bad_error_code < @as(isize, @intCast(err_len))) {
        handler = obj.vectorRef(error_vector, @intCast(abi.err_bad_error_code));
    } else {
        errorDeath(error_code, "No error handlers");
    }

    stop_history();
    preserve_interrupt_mask();

    abi.stackCheck(4);
    abi.stackPush(obj.ulongToFixnum(abi.Registers[abi.regblock_int_mask]));
    if (error_code == abi.err_with_argument or error_code == abi.err_in_system_call) {
        abi.stackPush(error_argument);
    } else {
        abi.stackPush(artutl.long_to_integer(error_code));
    }
    abi.stackPush(handler);
    abi.stackPush(abi.makeApplyFrameHeader(3));

    abi.setInterruptMask(0);
}

// History
pub export fn reset_history() callconv(.c) void {
    prev_restore_history_offset = 0;
    history_register = if (obj.vectorP(abi.fixed_objects) and
        obj.vectorRef(abi.fixed_objects, abi.fixobj_dummy_history) != obj.sharp_f)
        obj.objectAddress(obj.vectorRef(abi.fixed_objects, abi.fixobj_dummy_history))
    else
        make_dummy_history();
}

pub export fn make_dummy_history() callconv(.c) [*]obj.SchemeObject {
    const rib = abi.Free;
    rib[abi.rib_exp] = obj.sharp_f;
    rib[abi.rib_env] = obj.sharp_f;
    rib[abi.rib_next_reduction] = obj.makePointerObject(obj.tc_history_unmarked, rib);
    abi.Free += 3;

    const history = abi.Free;
    history[abi.hist_rib] = obj.makePointerObject(obj.tc_history_unmarked, rib);
    history[abi.hist_next_subproblem] = obj.makePointerObject(obj.tc_history_unmarked, history);
    history[abi.hist_prev_subproblem] = obj.makePointerObject(obj.tc_history_unmarked, history);
    abi.Free += 3;
    return history;
}

pub export fn save_history(rc: usize) callconv(.c) void {
    abi.stackCheck(abi.history_cont_size);
    abi.stackPush(obj.sharp_f);
    abi.stackPush(obj.ulongToFixnum(prev_restore_history_offset));
    abi.pushCont(rc, obj.makePointerObject(obj.tc_history_unmarked, history_register.?));
    history_register = obj.objectAddress(obj.vectorRef(abi.fixed_objects, abi.fixobj_dummy_history));
}

pub export fn restore_history(hist_obj: obj.SchemeObject) callconv(.c) bool {
    const new_hist = copyHistory(hist_obj);
    if (new_hist == obj.sharp_f) return false;
    history_register = obj.objectAddress(new_hist);
    return true;
}

pub export fn stop_history() callconv(.c) void {
    const exp = abi.Registers[abi.regblock_expr];
    const ret = abi.Registers[abi.regblock_return];
    save_history(abi.rc_restore_dont_copy_history);
    prev_restore_history_offset = abi.stackNPushed();
    abi.Registers[abi.regblock_return] = ret;
    abi.Registers[abi.regblock_expr] = exp;
}

pub export fn new_subproblem(expression: obj.SchemeObject, environment: obj.SchemeObject) callconv(.c) void {
    const hr = obj.objectAddress(history_register.?[abi.hist_next_subproblem]);
    history_register = hr;
    obj.historyMark(&hr[abi.hist_mark]);
    const rib = obj.objectAddress(hr[abi.hist_rib]);
    obj.historyMark(&rib[abi.rib_mark]);
    rib[abi.rib_env] = environment;
    rib[abi.rib_exp] = expression;
}

pub export fn reuse_subproblem(expression: obj.SchemeObject, environment: obj.SchemeObject) callconv(.c) void {
    const rib = obj.objectAddress(history_register.?[abi.hist_rib]);
    obj.historyMark(&rib[abi.rib_mark]);
    rib[abi.rib_env] = environment;
    rib[abi.rib_exp] = expression;
}

pub export fn new_reduction(expression: obj.SchemeObject, environment: obj.SchemeObject) callconv(.c) void {
    const hr = history_register.?;
    const rib = obj.objectAddress(obj.memoryRef(hr[abi.hist_rib], abi.rib_next_reduction));
    hr[abi.hist_rib] = obj.makePointerObject(obj.tc_history_unmarked, rib);
    rib[abi.rib_env] = environment;
    rib[abi.rib_exp] = expression;
    abi.historyUnmark(&rib[abi.rib_mark]);
}

pub export fn end_subproblem() callconv(.c) void {
    const hr = history_register.?;
    abi.historyUnmark(&hr[abi.hist_mark]);
    history_register = obj.objectAddress(hr[abi.hist_prev_subproblem]);
}

pub export fn compiler_new_subproblem() callconv(.c) void {
    new_subproblem(obj.sharp_f, obj.makeObject(obj.tc_return_code, abi.rc_pop_from_compiled_code));
}

pub export fn compiler_new_reduction() callconv(.c) void {
    new_reduction(obj.sharp_f, obj.makeObject(obj.tc_return_code, abi.rc_pop_from_compiled_code));
}

fn copyHistory(hist_obj: obj.SchemeObject) obj.SchemeObject {
    std.debug.assert(obj.hunk3P(hist_obj));

    var space_left = abi.spaceBeforeGc();
    if (space_left < 3) return obj.sharp_f;
    space_left -= 3;

    var vert_type = obj.objectType(hist_obj);
    const orig_hist = obj.objectAddress(hist_obj);
    var hist_ptr = orig_hist;
    var last_hunk = abi.heap_end - 3;
    var free = abi.Free;

    while (true) {
        if (space_left < 3) return obj.sharp_f;
        space_left -= 3;

        const new_hunk = obj.makePointerObject(vert_type, free);
        last_hunk[abi.hist_next_subproblem] = new_hunk;
        free[abi.hist_prev_subproblem] = obj.makePointerObject(
            obj.objectType(hist_ptr[abi.hist_prev_subproblem]),
            last_hunk,
        );
        last_hunk = free;
        free += 3;

        var temp = hist_ptr[abi.hist_rib];
        var rib_type = obj.objectType(temp);
        const orig_rib = obj.objectAddress(temp);
        var rib_slot: *obj.SchemeObject = &last_hunk[abi.hist_rib];
        var source_rib = orig_rib;

        while (true) {
            if (space_left < 3) return obj.sharp_f;
            space_left -= 3;

            rib_slot.* = obj.makePointerObject(rib_type, free);
            free[abi.rib_exp] = source_rib[abi.rib_exp];
            free[abi.rib_env] = source_rib[abi.rib_env];
            rib_slot = &free[abi.rib_next_reduction];
            free += 3;
            temp = source_rib[abi.rib_next_reduction];
            rib_type = obj.objectType(temp);
            source_rib = obj.objectAddress(temp);
            if (source_rib == orig_rib) break;
        }

        rib_slot.* = obj.objectNewType(rib_type, last_hunk[abi.hist_rib]);

        temp = hist_ptr[abi.hist_next_subproblem];
        vert_type = obj.objectType(temp);
        hist_ptr = obj.objectAddress(temp);
        if (hist_ptr == orig_hist) break;
    }

    const result_hunk = (abi.heap_end - 3)[abi.hist_next_subproblem];
    last_hunk[abi.hist_next_subproblem] = obj.objectNewType(vert_type, result_hunk);
    obj.memorySet(
        result_hunk,
        abi.hist_prev_subproblem,
        obj.makePointerObject(obj.objectType(hist_ptr[abi.hist_prev_subproblem]), last_hunk),
    );
    abi.Free = free;
    return result_hunk;
}

fn recordPrimitiveEntry(primitive: obj.SchemeObject) callconv(.c) void {
    if (obj.vectorP(abi.fixed_objects)) {
        const table = obj.vectorRef(abi.fixed_objects, abi.fixobj_primitive_profiling_table);
        if (obj.vectorP(table)) {
            const index: usize = @intCast(obj.objectDatum(primitive));
            obj.vectorSet(
                table,
                index,
                artutl.ulong_to_integer(1 + artutl.integer_to_ulong(obj.vectorRef(table, index))),
            );
        }
    }
}

comptime {
    if (build_options.debugging) {
        @export(&recordPrimitiveEntry, .{ .name = "record_primitive_entry" });
    }
}

test "utils interrupt vectors, arg validation, hashing, applicability, and history" {
    const stubs = @import("test_stubs.zig");
    const str = @import("../data/string.zig");
    const list = @import("../data/list.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    // Interrupt vectors & setup_interrupt
    const handlers = initialize_interrupt_handler_vector();
    const masks = initialize_interrupt_mask_vector();
    try std.testing.expectEqual(@as(usize, 17), obj.vectorLength(handlers));
    try std.testing.expectEqual(@as(usize, 17), obj.vectorLength(masks));
    try std.testing.expectEqual(@as(usize, 0x0F), artutl.integer_to_ulong(obj.vectorRef(masks, 4)));

    const fov = abi.make_vector(0x28, obj.sharp_f, false);
    const dummy_hist = obj.makePointerObject(obj.tc_history_unmarked, make_dummy_history());
    obj.vectorSet(fov, abi.fixobj_system_interrupt_vector, handlers);
    obj.vectorSet(fov, abi.fixobj_interrupt_mask_vector, masks);
    obj.vectorSet(fov, abi.fixobj_dummy_history, dummy_hist);
    obj.vectorSet(fov, abi.fixobj_initial_hash, obj.ulongToFixnum(12345));
    const handler_proc = obj.makeObject(obj.tc_primitive, 0);
    obj.vectorSet(handlers, 2, handler_proc);
    abi.fixed_objects = fov;
    reset_history();

    abi.Registers[abi.regblock_int_mask] = 0xFFFF;
    abi.Registers[abi.regblock_int_code] = 0x04;
    setup_interrupt(0x04);
    try std.testing.expectEqual(@as(usize, 0x03), abi.Registers[abi.regblock_int_mask]);
    // Stack has apply frame(3): [header, handler_proc, int_code, prev_mask], RC_RESTORE_INT_MASK frame, RC_RESTORE_DONT_COPY_HISTORY frame
    try std.testing.expectEqual(abi.makeApplyFrameHeader(3), abi.stackPop());
    try std.testing.expectEqual(handler_proc, abi.stackPop());
    try std.testing.expectEqual(obj.ulongToFixnum(0x04), abi.stackPop());
    try std.testing.expectEqual(obj.ulongToFixnum(0xFFFF), abi.stackPop());
    try std.testing.expectEqual(obj.makeObject(obj.tc_return_code, abi.rc_restore_int_mask), abi.stackPop());
    try std.testing.expectEqual(obj.ulongToFixnum(0xFFFF), abi.stackPop());

    // Arg helpers & real_number_to_double*
    stubs.setArgs(&.{ obj.longToFixnum(-5), artutl.ulong_to_integer(300), abi.double_to_flonum(2.5) });
    try std.testing.expectEqual(@as(isize, -5), arg_integer(-1 + 2)); // arg 1
    try std.testing.expectEqual(@as(isize, -5), arg_integer_in_range(1, -10, 0));
    try std.testing.expectEqual(@as(i64, -5), arg_integer_to_intmax(1));
    try std.testing.expectEqual(@as(usize, 300), arg_ulong_integer(2));
    try std.testing.expectEqual(@as(usize, 300), arg_ulong_index_integer(2, 500));
    try std.testing.expectEqual(@as(usize, 300), arg_ulong_integer_in_range(2, 100, 400));
    try std.testing.expectEqual(@as(f64, 2.5), arg_real_number(3));
    try std.testing.expectEqual(@as(f64, 2.5), arg_real_in_range(3, 1.0, 3.0));
    try std.testing.expect(real_number_to_double_p(abi.argRef(3)));
    try std.testing.expect(!real_number_to_double_p(abi.double_to_flonum(std.math.inf(f64))));

    // Hashing & applicability
    const bv = abi.memory_to_bytevector(3, "abc");
    const sym = abi.system_pair_cons(@intCast(obj.tc_uninterned_symbol), str.char_pointer_to_string("abc"), obj.unbound_object);
    const p = list.cons(bv, sym);
    const vec = abi.make_vector(2, bv, false);
    try std.testing.expect(hashable_object_p(bv));
    try std.testing.expect(hashable_object_p(sym));
    try std.testing.expect(hashable_object_p(p));
    try std.testing.expect(hashable_object_p(vec));
    try std.testing.expect(!hashable_object_p(obj.sharp_f));
    try std.testing.expectEqual(@as(u32, 12345), initial_hash());
    try std.testing.expectEqual(combine_hashes(10, 20), 10 * 31 + 20);
    try std.testing.expectEqual(combine_hashes(hash_object(bv), hash_object(sym)), hash_object(p));

    try std.testing.expect(interpreter_applicable_p(handler_proc));
    try std.testing.expect(!interpreter_applicable_p(bv));
    const ent = list.cons(handler_proc, obj.sharp_f);
    try std.testing.expect(interpreter_applicable_p(obj.objectNewType(obj.tc_entity, ent)));
    if (build_options.cc_support) {
        const cc_entry = obj.makeObject(obj.tc_compiled_entry, 0x10);
        stubs.mock_cc_entry_type.marker = .procedure;
        try std.testing.expect(interpreter_applicable_p(cc_entry));
        stubs.mock_cc_entry_type.marker = .continuation;
        try std.testing.expect(!interpreter_applicable_p(cc_entry));
    }

    // History copy/restore
    const h0 = obj.makePointerObject(obj.tc_history_unmarked, make_dummy_history());
    try std.testing.expect(restore_history(h0));
    new_subproblem(obj.ulongToFixnum(1), obj.the_global_env);
    new_reduction(obj.ulongToFixnum(2), obj.the_global_env);
    end_subproblem();
    if (build_options.debugging) {
        const prof_tbl = abi.make_vector(4, obj.ulongToFixnum(0), false);
        obj.vectorSet(fov, abi.fixobj_primitive_profiling_table, prof_tbl);
        recordPrimitiveEntry(obj.makeObject(obj.tc_primitive, 2));
        try std.testing.expectEqual(obj.ulongToFixnum(1), obj.vectorRef(prof_tbl, 2));
    }
}
