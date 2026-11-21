// Derived from MIT/GNU Scheme C sources (`src/microcode/hooks.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

// DEFINE_PRIMITIVE ("APPLY", Prim_apply, 2, 2,
//   "(PROCEDURE ARG-LIST)\n\
// Invokes PROCEDURE on the arguments in ARG-LIST.")
pub export fn Prim_apply() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const procedure = abi.argRef(1);
    const args = abi.argRef(2);
    var n_args: usize = 0;

    // Validate list length & detect cycles before popping our frame.
    {
        var p1 = args;
        var p2 = p1;
        while (obj.pairP(p1)) {
            p1 = obj.pairCdr(p1);
            n_args += 1;
            if (p1 == p2) abi.error_bad_range_arg(2);
            if (!obj.pairP(p1)) break;

            p1 = obj.pairCdr(p1);
            n_args += 1;
            if (p1 == p2) abi.error_bad_range_arg(2);
            if (!obj.pairP(p1)) break;

            p2 = obj.pairCdr(p2);
        }
        if (!obj.emptyListP(p1)) abi.error_wrong_type_arg(2);
    }

    const n_args_usize: usize = @intCast(n_args);
    if (!abi.stackCanPushP(n_args_usize + 2)) abi.error_bad_range_arg(2);
    abi.popPrimitiveFrame(2);

    {
        var p1 = args;
        var s1 = abi.stack_pointer - n_args_usize;
        while (@intFromPtr(s1) < @intFromPtr(abi.stack_pointer)) {
            s1[0] = obj.pairCar(p1);
            s1 += 1;
            p1 = obj.pairCdr(p1);
        }
        abi.decrementSp(n_args_usize);
    }

    if (build_options.cc_support) {
        if (obj.ccReturnP(abi.stackRef(n_args_usize))) {
            abi.apply_compiled_from_primitive(n_args, procedure);
            abi.decrementSp(2); // un_pop_primitive_frame
            return obj.unspecific;
        } else {
            std.debug.assert(obj.returnCodeP(abi.stackRef(n_args_usize)));
        }
    }

    abi.stackPush(procedure);
    abi.stackPush(abi.makeApplyFrameHeader(n_args + 1));
    abi.abort_to_interpreter(abi.prim_apply);
}

fn allocateControlPoint(n: usize, gc_p: bool) obj.SchemeObject {
    const cp = abi.allocate_marked_vector(obj.tc_control_point, n + 2, gc_p);
    obj.vectorSet(cp, 0, obj.sharp_f);
    obj.vectorSet(cp, 1, obj.ulongToFixnum(0));
    return cp;
}

pub export fn control_point_start(cp: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return obj.vectorLoc(cp, 2);
}

pub export fn control_point_end(cp: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return obj.vectorLoc(cp, @intCast(obj.vectorLength(cp)));
}

pub export fn unpack_control_point(cp: obj.SchemeObject) callconv(.c) void {
    if (build_options.debugging) {
        if (!obj.controlPointP(cp)) {
            abi.Microcode_Termination(abi.term_bad_stack);
        }
    }
    var scan_from = control_point_end(cp);
    const end_from = control_point_start(cp);

    abi.stack_pointer = abi.stack_end;
    abi.clearInterrupt(abi.int_stack_overflow);
    const n_words: usize = (@intFromPtr(scan_from) - @intFromPtr(end_from)) / @sizeOf(obj.SchemeObject);
    abi.stackCheck(n_words);

    while (@intFromPtr(scan_from) > @intFromPtr(end_from)) {
        scan_from -= 1;
        abi.stackPush(scan_from[0]);
    }
}

// DEFINE_PRIMITIVE ("CALL-WITH-CURRENT-CONTINUATION", Prim_catch, 1, 1,
//   "(PROCEDURE)\n\
// Invoke PROCEDURE with a copy of the current control stack.")
pub export fn Prim_catch() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    const procedure = abi.argRef(1);
    var cp: obj.SchemeObject = undefined;

    if (abi.stackLoc(1 + abi.cont_size) == abi.stack_end and
        abi.contFrameRet(abi.stackLoc(1)) == obj.makeObject(obj.tc_return_code, abi.rc_join_stacklets) and
        obj.controlPointP(abi.contFrameExp(abi.stackLoc(1))))
    {
        cp = abi.contFrameExp(abi.stackLoc(1));
        abi.history_register = obj.objectAddress(obj.vectorRef(abi.fixed_objects, abi.fixobj_dummy_history));
        abi.popPrimitiveFrame(1);
    } else {
        const n_words = abi.cont_size + abi.history_cont_size + (@as(usize, @intCast(abi.stackNPushed())) - 1);
        cp = allocateControlPoint(@intCast(n_words), true);
        abi.popPrimitiveFrame(1);

        abi.save_history(abi.rc_restore_history);
        abi.preserve_interrupt_mask();
        abi.prev_restore_history_offset = 0;

        var scan = control_point_start(cp);
        while (abi.stackNPushed() > 0) {
            scan[0] = abi.stackPop();
            scan += 1;
        }
        if (build_options.debugging) {
            if (abi.stackNPushed() != 0) {
                abi.Microcode_Termination(abi.term_bad_stack);
            }
        }
        abi.clearInterrupt(abi.int_stack_overflow);
        abi.pushCont(abi.rc_join_stacklets, cp);
    }

    abi.stackPush(cp);
    abi.stackPush(procedure);
    abi.stackPush(abi.makeApplyFrameHeader(2));
    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("WITHIN-CONTROL-POINT", Prim_within_control_point, 2, 2,
//   "(CONTROL-POINT THUNK)\n\
// Invoke THUNK with CONTROL-POINT as its control stack.")
pub export fn Prim_within_control_point() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    abi.checkArg(1, obj.controlPointP);
    const control_point = abi.argRef(1);
    const thunk = abi.argRef(2);

    abi.stack_pointer = abi.stack_end;
    abi.prev_restore_history_offset = 0;
    abi.clearInterrupt(abi.int_stack_overflow);

    abi.stackCheck(abi.cont_size + 2);
    abi.pushCont(abi.rc_join_stacklets, control_point);
    abi.stackPush(thunk);
    abi.stackPush(abi.makeApplyFrameHeader(1));

    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("ERROR-PROCEDURE", Prim_error_procedure, 3, 3,
//   "(MESSAGE IRRITANTS ENVIRONMENT)\n\
// Signal an error.")
pub export fn Prim_error_procedure() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();

    const message = abi.argRef(1);
    const irritants = abi.argRef(2);
    const environment = abi.argRef(3);
    abi.back_out_of_primitive();
    abi.stackCheck(abi.history_cont_size + 5);
    abi.stop_history();
    abi.stackPush(environment);
    abi.stackPush(irritants);
    abi.stackPush(message);
    abi.stackPush(obj.vectorRef(abi.fixed_objects, abi.fixobj_error_procedure));
    abi.stackPush(abi.makeApplyFrameHeader(4));

    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("SCODE-EVAL", Prim_scode_eval, 2, 2,
//   "(SCODE-EXPRESSION ENVIRONMENT)\n\
// Evaluate SCODE-EXPRESSION in ENVIRONMENT.")
pub export fn Prim_scode_eval() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    abi.checkArg(2, obj.environmentP);
    const expression = abi.argRef(1);
    const environment = abi.argRef(2);
    abi.popPrimitiveFrame(2);
    abi.Registers[abi.regblock_env] = environment;
    abi.Registers[abi.regblock_expr] = expression;
    abi.abort_to_interpreter(abi.prim_do_expression);
}

// DEFINE_PRIMITIVE ("FORCE", Prim_force, 1, 1,
//   "(PROMISE)\n\
// Return the value memoized in PROMISE, computing it if it has not been\n\
// memoized yet.")
pub export fn Prim_force() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.promiseP);
    const delayed = abi.argRef(1);
    const state = obj.delayedSnapped(delayed);
    if (state == obj.sharp_t) {
        return obj.delayedValue(delayed);
    } else if (state == obj.fixnum_zero) {
        abi.canonicalize_primitive_context();
        abi.popPrimitiveFrame(1);

        abi.stackCheck(abi.cont_size + 2);
        abi.pushCont(abi.rc_snap_need_thunk, delayed);
        abi.stackPush(obj.delayedValue(delayed));
        abi.stackPush(abi.makeApplyFrameHeader(1));

        abi.abort_to_interpreter(abi.prim_apply);
    } else {
        abi.canonicalize_primitive_context();
        abi.popPrimitiveFrame(1);

        abi.stackCheck(abi.cont_size);
        abi.pushCont(abi.rc_snap_need_thunk, delayed);
        abi.Registers[abi.regblock_env] = obj.delayedEnv(delayed);
        abi.Registers[abi.regblock_expr] = obj.delayedProc(delayed);

        abi.abort_to_interpreter(abi.prim_do_expression);
    }
}

// DEFINE_PRIMITIVE ("GET-INTERRUPT-ENABLES", Prim_get_interrupt_enables, 0, 0,
//   "()\n\
// Returns the current interrupt mask.\n\
// There are two interrupt bit masks:\n\
// - The interrupt mask has a one bit for every enabled interrupt.\n\
// - The interrupt code has a one bit for every interrupt pending service.\n\
// Interrupts are prioritized according to their bit position (LSB is highest).\n\
// At any interrupt polling point, the highest enabled pending interrupt is\n\
// serviced.  The interrupt handler is a two-argument Scheme procedure\n\
// invoked with all interrupts disabled and with the interrupt code and mask\n\
// as arguments.  The interrupt mask is restored on return from the interrupt\n\
// handler.  To prevent re-servicing the interrupt, the interrupt handler\n\
// should clear the corresponding interrupt bit.")
pub export fn Prim_get_interrupt_enables() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.ulongToFixnum(abi.Registers[abi.regblock_int_mask]);
}

// DEFINE_PRIMITIVE ("SET-INTERRUPT-ENABLES!", Prim_set_interrupt_enables, 1, 1,
//   "(INTERRUPT-MASK)\n\
// Sets the interrupt mask to INTERRUPT-MASK; returns previous mask value.\n\
// See `get-interrupt-enables' for more information on interrupts.")
pub export fn Prim_set_interrupt_enables() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const previous = abi.Registers[abi.regblock_int_mask];
    abi.setInterruptMask(abi.arg_ulong_integer(1) & abi.int_mask);
    return obj.ulongToFixnum(previous);
}

// DEFINE_PRIMITIVE ("CLEAR-INTERRUPTS!", Prim_clear_interrupts, 1, 1,
//   "(INTERRUPT-MASK)\n\
// Clears the interrupt bits in INTERRUPT-MASK by clearing the\n\
// corresponding bits in the interrupt code.\n\
// See `get-interrupt-enables' for more information on interrupts.")
pub export fn Prim_clear_interrupts() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.clearInterrupt(abi.arg_ulong_integer(1) & abi.int_mask);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("DISABLE-INTERRUPTS!", Prim_disable_interrupts, 1, 1,
//   "(INTERRUPT-MASK)\n\
// Disables the interrupts specified in INTERRUPT-MASK by clearing the\n\
// corresponding bits in the interrupt mask. Returns previous mask value.\n\
// See `get-interrupt-enables' for more information on interrupts.")
pub export fn Prim_disable_interrupts() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const previous = abi.Registers[abi.regblock_int_mask];
    abi.setInterruptMask(previous & ~(abi.arg_ulong_integer(1) & abi.int_mask));
    return obj.ulongToFixnum(previous);
}

// DEFINE_PRIMITIVE ("ENABLE-INTERRUPTS!", Prim_enable_interrupts, 1, 1,
//   "(INTERRUPT-MASK)\n\
// Enables the interrupts specified in INTERRUPT-MASK by setting the\n\
// corresponding bits in the interrupt mask. Returns previous mask value.\n\
// See `get-interrupt-enables' for more information on interrupts.")
pub export fn Prim_enable_interrupts() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const previous = abi.Registers[abi.regblock_int_mask];
    abi.setInterruptMask(previous | (abi.arg_ulong_integer(1) & abi.int_mask));
    return obj.ulongToFixnum(previous);
}

// DEFINE_PRIMITIVE ("REQUEST-INTERRUPTS!", Prim_request_interrupts, 1, 1,
//   "(INTERRUPT-MASK)\n\
// Requests the interrupt bits in INTERRUPT-MASK by setting the\n\
// corresponding bits in the interrupt code.\n\
// See `get-interrupt-enables' for more information on interrupts.")
pub export fn Prim_request_interrupts() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.requestInterrupt(abi.arg_ulong_integer(1) & abi.int_mask);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("RETURN-TO-APPLICATION", Prim_return_to_application, 2, LEXPR,
//   "(THUNK PROCEDURE . ARGS)\n\
// Invokes THUNK with no arguments and a special return address.\n\
// The return address calls PROCEDURE on ARGS.\n\
// This is used by the runtime system to create stack frames that can be\n\
// identified by the continuation parser.")
pub export fn Prim_return_to_application() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();

    const nargs = abi.getLexprActuals();
    if (nargs < 2) abi.signal_error_from_primitive(abi.err_wrong_number_of_arguments);

    const thunk = abi.stackPop();
    abi.stackPush(abi.makeApplyFrameHeader(nargs - 1));
    abi.Registers[abi.regblock_env] = obj.the_null_env;
    abi.pushCont(abi.rc_internal_apply, obj.sharp_f);

    abi.stackCheck(2);
    abi.stackPush(thunk);
    abi.stackPush(abi.makeApplyFrameHeader(1));

    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("WITH-STACK-MARKER", Prim_with_stack_marker, 3, 3,
//   "(THUNK MARKER1 MARKER2)\n\
// Call THUNK with a continuation that has a special marker.\n\
// When THUNK returns, the marker is discarded.\n\
// The value of THUNK is returned to the continuation of this primitive.\n\
// The marker consists of MARKER1 and MARKER2.\n\
// By convention, MARKER1 is a tag identifying the kind of marker,\n\
// and MARKER2 is data identifying the marker instance.")
pub export fn Prim_with_stack_marker() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const thunk = abi.argRef(1);
    if (build_options.cc_support) {
        if (obj.ccReturnP(abi.stackRef(3)) and obj.ccEntryP(thunk)) {
            abi.incrementSp(1);
            abi.compiled_with_stack_marker(thunk);
            abi.decrementSp(3);
            return obj.unspecific;
        }
    }
    abi.canonicalize_primitive_context();
    abi.incrementSp(1);
    abi.stackPush(obj.makeObject(obj.tc_return_code, abi.rc_stack_marker));
    abi.stackCheck(2);
    abi.stackPush(thunk);
    abi.stackPush(abi.makeApplyFrameHeader(1));

    abi.abort_to_interpreter(abi.prim_apply);
}

fn withNewInterruptMask(new_mask: usize) obj.SchemeObject {
    const receiver = abi.argRef(2);
    if (build_options.cc_support) {
        if (obj.ccReturnP(abi.stackRef(2)) and obj.ccEntryP(receiver)) {
            const current_mask = abi.Registers[abi.regblock_int_mask];
            abi.popPrimitiveFrame(2);
            abi.compiled_with_interrupt_mask(current_mask, receiver, new_mask);
            abi.decrementSp(2);
            abi.setInterruptMask(new_mask);
            return obj.unspecific;
        }
    }
    abi.canonicalize_primitive_context();
    abi.popPrimitiveFrame(2);
    abi.preserve_interrupt_mask();

    abi.stackCheck(3);
    abi.stackPush(obj.ulongToFixnum(abi.Registers[abi.regblock_int_mask]));
    abi.stackPush(receiver);
    abi.stackPush(abi.makeApplyFrameHeader(2));

    abi.setInterruptMask(new_mask);
    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("WITH-INTERRUPT-MASK", Prim_with_interrupt_mask, 2, 2,
//   "(MASK RECEIVER)\n\
// Set the interrupt mask to MASK for the duration of the call to RECEIVER.\n\
// RECEIVER is passed the old interrupt mask as its argument.")
pub export fn Prim_with_interrupt_mask() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const raw_mask: usize = @bitCast(abi.arg_integer(1));
    return withNewInterruptMask(abi.int_mask & raw_mask);
}

// DEFINE_PRIMITIVE ("WITH-INTERRUPTS-REDUCED", Prim_with_interrupts_reduced, 2, 2,
//   "(MASK RECEIVER)\n\
// Like WITH-INTERRUPT-MASK, but only disables interrupts.")
pub export fn Prim_with_interrupts_reduced() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const old_mask = abi.Registers[abi.regblock_int_mask];
    const new_mask = abi.int_mask & abi.arg_ulong_integer(1);
    return withNewInterruptMask(if (new_mask > old_mask) new_mask else (new_mask & old_mask));
}

pub export fn initialize_history() callconv(.c) obj.SchemeObject {
    abi.history_register = abi.make_dummy_history();
    return obj.makePointerObject(obj.tc_history_unmarked, abi.make_dummy_history());
}

// DEFINE_PRIMITIVE ("SET-CURRENT-HISTORY!", Prim_set_current_history, 1, 1,
//   "(HISTORY)\n\
// Set the interpreter's history object to HISTORY.")
pub export fn Prim_set_current_history() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    abi.checkArg(1, obj.hunk3P);
    abi.Registers[abi.regblock_val] = abi.history_register[0];
    abi.history_register = obj.objectAddress(abi.argRef(1));
    abi.popPrimitiveFrame(1);
    abi.abort_to_interpreter(abi.prim_pop_return);
}

// DEFINE_PRIMITIVE ("WITH-HISTORY-DISABLED", Prim_with_history_disabled, 1, 1,
//   "(THUNK)\n\
// Execute THUNK with the interpreter's history OFF.")
pub export fn Prim_with_history_disabled() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    const thunk = abi.argRef(1);
    const first_rib = obj.objectAddress(abi.history_register[abi.hist_rib]);
    const second_rib = obj.objectAddress(first_rib[abi.rib_next_reduction]);
    if (first_rib != second_rib and !obj.historyMarkedP(first_rib[abi.rib_mark])) {
        obj.historyMark(&second_rib[abi.rib_mark]);
        var rib = first_rib;
        while (true) {
            const next_rib = obj.objectAddress(rib[abi.rib_next_reduction]);
            if (next_rib == first_rib) break;
            rib = next_rib;
        }
        abi.history_register[abi.hist_rib] = obj.makePointerObject(
            obj.objectType(abi.history_register[abi.hist_rib]),
            rib,
        );
    }
    abi.popPrimitiveFrame(1);
    abi.stop_history();
    abi.stackCheck(2);
    abi.stackPush(thunk);
    abi.stackPush(abi.makeApplyFrameHeader(1));
    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("GET-FIXED-OBJECTS-VECTOR", Prim_get_fixed_objects_vector, 0, 0,
//   "()\n\
// Return the fixed objects vector (TM).")
pub export fn Prim_get_fixed_objects_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.fixed_objects;
}

// DEFINE_PRIMITIVE ("SET-FIXED-OBJECTS-VECTOR!", Prim_set_fixed_objects_vector, 1, 1,
//   "(NEW-FOV)\n\
// Set the fixed objects vector (TM) to NEW-FOV.")
pub export fn Prim_set_fixed_objects_vector() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.vectorP);
    const old = abi.fixed_objects;
    const new_fov = abi.argRef(1);
    if (obj.vectorLength(new_fov) < abi.n_fixed_objects) abi.error_bad_range_arg(1);
    abi.fixed_objects = new_fov;
    return old;
}

test "hooks interrupt masks, fixed objects, control points, force, and compiled fast paths" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    // Interrupt enables, disable, enable, request, clear
    abi.Registers[abi.regblock_int_mask] = 0x05;
    try std.testing.expectEqual(obj.ulongToFixnum(0x05), Prim_get_interrupt_enables());

    stubs.setArgs(&.{obj.ulongToFixnum(0x13)});
    try std.testing.expectEqual(obj.ulongToFixnum(0x05), Prim_set_interrupt_enables());
    try std.testing.expectEqual(@as(usize, 0x13), abi.Registers[abi.regblock_int_mask]);

    stubs.setArgs(&.{obj.ulongToFixnum(0x02)});
    try std.testing.expectEqual(obj.ulongToFixnum(0x13), Prim_disable_interrupts());
    try std.testing.expectEqual(@as(usize, 0x11), abi.Registers[abi.regblock_int_mask]);

    stubs.setArgs(&.{obj.ulongToFixnum(0x08)});
    try std.testing.expectEqual(obj.ulongToFixnum(0x11), Prim_enable_interrupts());
    try std.testing.expectEqual(@as(usize, 0x19), abi.Registers[abi.regblock_int_mask]);

    stubs.setArgs(&.{obj.ulongToFixnum(0x21)});
    try std.testing.expectEqual(obj.unspecific, Prim_request_interrupts());
    try std.testing.expectEqual(@as(usize, 0x21), abi.Registers[abi.regblock_int_code]);

    stubs.setArgs(&.{obj.ulongToFixnum(0x01)});
    try std.testing.expectEqual(obj.unspecific, Prim_clear_interrupts());
    try std.testing.expectEqual(@as(usize, 0x20), abi.Registers[abi.regblock_int_code]);

    // GET/SET-FIXED-OBJECTS-VECTOR
    const old_fov = abi.make_vector(abi.n_fixed_objects, obj.sharp_f, false);
    const new_fov = abi.make_vector(abi.n_fixed_objects, obj.sharp_t, false);
    abi.fixed_objects = old_fov;
    try std.testing.expectEqual(old_fov, Prim_get_fixed_objects_vector());
    stubs.setArgs(&.{new_fov});
    try std.testing.expectEqual(old_fov, Prim_set_fixed_objects_vector());
    try std.testing.expectEqual(new_fov, abi.fixed_objects);

    // control_point_start / end / unpack_control_point
    const cp = allocateControlPoint(3, false);
    obj.vectorSet(cp, 2, obj.ulongToFixnum(10));
    obj.vectorSet(cp, 3, obj.ulongToFixnum(20));
    obj.vectorSet(cp, 4, obj.ulongToFixnum(30));
    try std.testing.expectEqual(@intFromPtr(control_point_start(cp)) + 3 * @sizeOf(obj.SchemeObject), @intFromPtr(control_point_end(cp)));
    unpack_control_point(cp);
    try std.testing.expectEqual(@as(usize, 3), abi.stackNPushed());
    try std.testing.expectEqual(obj.ulongToFixnum(10), abi.stackPop());
    try std.testing.expectEqual(obj.ulongToFixnum(20), abi.stackPop());
    try std.testing.expectEqual(obj.ulongToFixnum(30), abi.stackPop());

    // initialize_history
    const hist = initialize_history();
    try std.testing.expectEqual(obj.tc_history_unmarked, obj.objectType(hist));

    // FORCE on already-snapped promise
    const snapped = abi.system_pair_cons(@intCast(obj.tc_delayed), obj.sharp_t, obj.ulongToFixnum(777));
    stubs.setArgs(&.{snapped});
    try std.testing.expectEqual(obj.ulongToFixnum(777), Prim_force());

    // Compiled-return fast paths (APPLY, WITH-STACK-MARKER, WITH-INTERRUPT-MASK, WITH-INTERRUPTS-REDUCED)
    if (build_options.cc_support) {
        const cc_ret = obj.makeObject(obj.tc_compiled_return, 0x10);
        const cc_proc = obj.makeObject(obj.tc_compiled_entry, 0x20);

        const arg_list = abi.cons(obj.ulongToFixnum(11), abi.cons(obj.ulongToFixnum(22), obj.empty_list));
        stubs.setArgs(&.{ cc_proc, arg_list, cc_ret });
        // Back up stack_pointer so arg1, arg2 are at index 0,1 and cc_ret is at index 2 (stackRef(n_args=2) after popPrimitiveFrame(2) + decrementSp(2))
        try std.testing.expectEqual(obj.unspecific, Prim_apply());
        try std.testing.expectEqual(@as(usize, 1), stubs.mock_apply_compiled_calls);
        try std.testing.expectEqual(@as(usize, 2), stubs.mock_last_compiled_nargs);
        try std.testing.expectEqual(cc_proc, stubs.mock_last_compiled_proc);

        stubs.setArgs(&.{ cc_proc, obj.ulongToFixnum(1), obj.ulongToFixnum(2), cc_ret });
        try std.testing.expectEqual(obj.unspecific, Prim_with_stack_marker());
        try std.testing.expectEqual(@as(usize, 1), stubs.mock_stack_marker_calls);
        try std.testing.expectEqual(cc_proc, stubs.mock_last_marker_thunk);

        abi.Registers[abi.regblock_int_mask] = 0x0A;
        stubs.setArgs(&.{ obj.ulongToFixnum(0x03), cc_proc, cc_ret });
        try std.testing.expectEqual(obj.unspecific, Prim_with_interrupt_mask());
        try std.testing.expectEqual(@as(usize, 1), stubs.mock_int_mask_calls);
        try std.testing.expectEqual(@as(usize, 0x0A), stubs.mock_last_compiled_mask);
        try std.testing.expectEqual(@as(usize, 0x03), stubs.mock_last_compiled_new_mask);
        try std.testing.expectEqual(@as(usize, 0x03), abi.Registers[abi.regblock_int_mask]);

        // WITH-INTERRUPTS-REDUCED with new_mask < old_mask uses (new_mask & old_mask)
        stubs.setArgs(&.{ obj.ulongToFixnum(0x05), cc_proc, cc_ret });
        abi.Registers[abi.regblock_int_mask] = 0x0A;
        try std.testing.expectEqual(obj.unspecific, Prim_with_interrupts_reduced());
        try std.testing.expectEqual(@as(usize, 0x00), abi.Registers[abi.regblock_int_mask]);
    }
}
