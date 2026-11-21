// Derived from MIT/GNU Scheme C sources (`src/microcode/interp.c`, `src/microcode/interp.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const boot = @import("boot.zig");
const obstack = @import("obstack.zig");
const wind = @import("wind.zig");
const storage = @import("storage.zig");
const jit = @import("jit.zig");
const floenv = @import("floenv.zig");
const primutl = @import("primutl.zig");
const vector = @import("vector.zig");
const hooks = @import("hooks.zig");
const lookup = @import("lookup.zig");
const utils = @import("utils.zig");
const debug = @import("debug.zig");
const bkpt = @import("bkpt.zig");
const term = @import("term.zig");

pub const InterpreterState = extern struct {
    previous_state: ?*InterpreterState = null,
    nesting_level: c_uint = 0,
    dstack_position: ?*anyopaque = null,
    catch_env: ?*anyopaque = null,
    throw_argument: c_int = 0,
};

pub extern "c" fn scm_setjmp_loop(
    env_slot: *?*anyopaque,
    body: *const fn (c_int, ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) void;
pub extern "c" fn scm_setjmp_try(
    env_slot: *?*anyopaque,
    body: *const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) c_int;
pub extern "c" fn scm_longjmp(env: *anyopaque, code: c_int) noreturn;

extern "c" fn preserve_signal_mask() void;
extern "c" fn enter_compiled_expression() c_long;
extern "c" fn apply_compiled_procedure() c_long;
extern "c" fn guarantee_cc_return(c_ulong) void;
extern "c" fn return_to_compiled_code() c_long;
extern "c" fn comp_interrupt_restart() c_long;
extern "c" fn comp_lookup_trap_restart() c_long;
extern "c" fn comp_assignment_trap_restart() c_long;
extern "c" fn comp_op_lookup_trap_restart() c_long;
extern "c" fn comp_cache_lookup_apply_restart() c_long;
extern "c" fn comp_safe_lookup_trap_restart() c_long;
extern "c" fn comp_unassigned_p_trap_restart() c_long;
extern "c" fn comp_link_caches_restart() c_long;
extern "c" fn comp_error_restart() c_long;

const Action = enum {
    apply,
    apply_no_trap,
    apply_no_interrupt,
    eval,
    eval_no_trap,
    @"return",
    return_no_trap,
    done,
};

const Variant = enum {
    trap,
    no_trap,
    no_interrupt,

    inline fn trapP(self: Variant) bool {
        return self == .trap;
    }

    inline fn interruptP(self: Variant) bool {
        return self != .no_interrupt;
    }
};

var interpreter_state: ?*InterpreterState = null;
pub var prim_apply_error_code_storage: c_long = 0;

inline fn getVal() obj.SchemeObject {
    return abi.Registers[abi.regblock_val];
}
inline fn setVal(val: obj.SchemeObject) void {
    abi.Registers[abi.regblock_val] = val;
}
inline fn getEnv() obj.SchemeObject {
    return abi.Registers[abi.regblock_env];
}
inline fn setEnv(env: obj.SchemeObject) void {
    abi.Registers[abi.regblock_env] = env;
}
inline fn getExp() obj.SchemeObject {
    return abi.Registers[abi.regblock_expr];
}
inline fn setExp(exp: obj.SchemeObject) void {
    abi.Registers[abi.regblock_expr] = exp;
}
inline fn getRet() obj.SchemeObject {
    return abi.Registers[abi.regblock_return];
}
inline fn setRet(ret: obj.SchemeObject) void {
    abi.Registers[abi.regblock_return] = ret;
}
inline fn setPrimitive(prim: obj.SchemeObject) void {
    abi.Registers[abi.regblock_primitive] = prim;
}
inline fn setLexprActuals(n: c_ulong) void {
    abi.Registers[abi.regblock_lexpr_actuals] = n;
}
inline fn getIntMask() c_ulong {
    return abi.Registers[abi.regblock_int_mask];
}

inline fn rePushCont() void {
    abi.stackPush(getExp());
    abi.stackPush(getRet());
}

inline fn applyFrameHeader() obj.SchemeObject {
    return abi.stack_pointer[0];
}
inline fn applyFrameProc() obj.SchemeObject {
    return abi.stack_pointer[1];
}
inline fn setApplyFrameProc(proc: obj.SchemeObject) void {
    abi.stack_pointer[1] = proc;
}
inline fn applyFrameArgs() [*]obj.SchemeObject {
    return abi.stack_pointer + 2;
}
inline fn applyFrameSize() c_ulong {
    return obj.objectDatum(applyFrameHeader());
}
inline fn applyFrameNArgs() c_ulong {
    return applyFrameSize() - 1;
}

inline fn fetchStepperTrapper(slot: usize) obj.SchemeObject {
    return obj.memoryRef(obj.vectorRef(abi.fixed_objects, abi.fixobj_stepper_state), slot);
}

pub fn bindInterpreterState(s: *InterpreterState) callconv(.c) void {
    s.previous_state = interpreter_state;
    s.nesting_level = if (interpreter_state) |prev| 1 + prev.nesting_level else 0;
    s.dstack_position = wind.dstack_position;
    interpreter_state = s;
}

pub fn unbindInterpreterState(s: *InterpreterState) callconv(.c) void {
    interpreter_state = s;
    const old_mask = getIntMask();
    abi.setInterruptMask(0);
    wind.dstack_set_position(s.dstack_position);
    abi.setInterruptMask(old_mask);
    interpreter_state = s.previous_state;
}

pub fn abortToInterpreter(argument: c_long) callconv(.c) noreturn {
    std.debug.assert(argument != 0);
    const state = interpreter_state orelse {
        abi.outf_fatal("abort_to_interpreter: Interpreter not set up.\n");
        term.terminationInitError();
    };
    const arg_cint: c_int = @intCast(argument);
    state.throw_argument = arg_cint;
    const old_mask = getIntMask();
    abi.setInterruptMask(0);
    wind.dstack_set_position(state.dstack_position);
    jit.jit_force_execute_mode();
    abi.setInterruptMask(old_mask);
    obstack.obstack_free(&boot.scratch_obstack, null);
    boot.scratch_obstack.init(&boot.obstack_chunk_alloc, &std.c.free);
    scm_longjmp(state.catch_env.?, arg_cint);
}

pub fn abortToInterpreterArgument() callconv(.c) c_int {
    return interpreter_state.?.throw_argument;
}

inline fn handleInterrupt() Action {
    utils.setup_interrupt(abi.pendingInterrupts());
    return .apply_no_interrupt;
}

inline fn handleError(code: c_long, from_return: bool) Action {
    utils.Do_Micro_Error(code, from_return);
    return .apply;
}

inline fn immediateGc(n: c_ulong) Action {
    abi.requestGc(n);
    return handleInterrupt();
}

inline fn reEval(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    setExp(exp);
    setEnv(env);
    return .eval;
}

inline fn evalSubproblem(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    utils.new_subproblem(exp, env);
    return reEval(exp, env);
}

inline fn evalReduction(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    utils.new_reduction(exp, env);
    return reEval(exp, env);
}

inline fn singleVal(val: obj.SchemeObject) Action {
    setVal(val);
    return .@"return";
}

inline fn evalError(code: c_long, exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    if (code == abi.prim_interrupt) {
        abi.stackCheck(3);
        abi.pushEnvCont(abi.rc_eval_error, exp, env);
        return handleInterrupt();
    }
    setExp(exp);
    setEnv(env);
    return handleError(code, false);
}

inline fn applyError(code: c_long) Action {
    setVal(applyFrameProc());
    abi.pushCont(abi.rc_internal_apply_val, obj.sharp_f);
    return handleError(code, true);
}

inline fn prepareApplyInterrupt() void {
    const value = applyFrameProc();
    abi.pushCont(abi.rc_internal_apply_val, obj.sharp_f);
    abi.pushCont(abi.rc_restore_value, value);
}

inline fn applyImmediateGc(n: c_ulong) Action {
    prepareApplyInterrupt();
    return immediateGc(n);
}

inline fn applyInterrupt() Action {
    prepareApplyInterrupt();
    return handleInterrupt();
}

inline fn prepareReturnInterrupt() void {
    rePushCont();
    abi.pushCont(abi.rc_restore_value, getVal());
}

inline fn returnError(code: c_long) Action {
    if (code == abi.prim_interrupt) {
        prepareReturnInterrupt();
        return handleInterrupt();
    }
    rePushCont();
    return handleError(code, true);
}

inline fn returnImmediateGc(n: c_ulong) Action {
    prepareReturnInterrupt();
    return immediateGc(n);
}

inline fn returnFromCompiledCode(code: c_long) Action {
    return switch (code) {
        abi.prim_done => .@"return",
        abi.prim_apply => .apply,
        abi.prim_interrupt => handleInterrupt(),
        abi.prim_apply_interrupt => applyInterrupt(),
        abi.err_inapplicable_object, abi.err_wrong_number_of_arguments => applyError(code),
        else => handleError(code, true),
    };
}

// Eval

inline fn evalAccess(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    abi.stackCheck(2);
    abi.pushCont(abi.rc_execute_access_finish, exp);
    return evalSubproblem(obj.memoryRef(exp, 0), env);
}

inline fn evalAssignment(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    abi.stackCheck(3);
    abi.pushEnvCont(abi.rc_execute_assignment_finish, exp, env);
    return evalSubproblem(obj.memoryRef(exp, 1), env);
}

inline fn evalCombination(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    const nargs = obj.combinationSize(exp) - 1;
    const nargs_usize: usize = @intCast(nargs);
    abi.stackCheck(4 + nargs_usize);
    abi.decrementSp(nargs_usize);
    abi.stackPush(obj.makeNmvHeader(nargs));
    if (nargs == 0) {
        abi.stackPush(abi.makeApplyFrameHeader(1));
        abi.pushCont(abi.rc_comb_apply_function, exp);
    } else {
        abi.pushEnvCont(abi.rc_comb_save_value, exp, env);
    }
    return evalSubproblem(obj.combinationExpr(exp, nargs_usize), env);
}

inline fn evalComment(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    return evalReduction(obj.memoryRef(exp, 0), env);
}

inline fn evalCompiledEntry(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    setExp(exp);
    setEnv(env);
    return returnFromCompiledCode(enter_compiled_expression());
}

inline fn evalConditional(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    abi.stackCheck(3);
    abi.pushEnvCont(abi.rc_conditional_decide, exp, env);
    return evalSubproblem(obj.memoryRef(exp, 0), env);
}

inline fn evalDefinition(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    abi.stackCheck(3);
    abi.pushEnvCont(abi.rc_execute_definition_finish, exp, env);
    return evalSubproblem(obj.memoryRef(exp, 1), env);
}

inline fn evalDelay(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    const delayed = obj.makePointerObject(obj.tc_delayed, abi.Free);
    abi.Free[0] = obj.memoryRef(exp, 0);
    abi.Free[1] = env;
    abi.Free += 2;
    return singleVal(delayed);
}

inline fn evalDisjunction(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    abi.stackCheck(3);
    abi.pushEnvCont(abi.rc_disjunction_decide, exp, env);
    return evalSubproblem(obj.memoryRef(exp, 0), env);
}

inline fn evalExtendedLambda(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    const proc = obj.makePointerObject(obj.tc_extended_procedure, abi.Free);
    abi.Free[0] = exp;
    abi.Free[1] = env;
    abi.Free += 2;
    return singleVal(proc);
}

inline fn evalLambda(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    const proc = obj.makePointerObject(obj.tc_procedure, abi.Free);
    abi.Free[0] = exp;
    abi.Free[1] = env;
    abi.Free += 2;
    return singleVal(proc);
}

inline fn evalScodeQuote(exp: obj.SchemeObject) Action {
    return singleVal(obj.memoryRef(exp, 0));
}

inline fn evalSequence(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    abi.stackCheck(3);
    abi.pushEnvCont(abi.rc_execute_sequence_finish, exp, env);
    return evalSubproblem(obj.memoryRef(exp, 0), env);
}

inline fn evalVariable(exp: obj.SchemeObject, env: obj.SchemeObject) Action {
    var val: obj.SchemeObject = undefined;
    const code = lookup.lookup_variable(env, obj.variableName(exp), &val);
    if (code == abi.prim_done) return singleVal(val);
    if (code == abi.err_unassigned_variable and obj.variableSafeP(exp)) {
        return singleVal(obj.unassigned_object);
    }
    return evalError(code, exp, env);
}

fn eval(exp: obj.SchemeObject, env: obj.SchemeObject, variant: Variant) Action {
    if (variant.trapP() and
        storage.trapping and
        boot.critical_section_name == null and
        fetchStepperTrapper(0) != obj.sharp_f)
    {
        storage.trapping = false;
        abi.stackCheck(4);
        abi.stackPush(getEnv());
        abi.stackPush(getExp());
        abi.stackPush(fetchStepperTrapper(0));
        abi.stackPush(abi.makeApplyFrameHeader(3));
        return .apply_no_trap;
    }

    if (build_options.debugging) {
        storage.local_circle_storage[storage.local_slotno_storage] = @truncate(getExp());
        storage.local_slotno_storage += 1;
        if (storage.local_slotno_storage >= 100) {
            storage.local_slotno_storage = 0;
        }
        if (storage.local_nslots_storage < 100) {
            storage.local_nslots_storage += 1;
        }
    }

    return switch (obj.objectType(exp)) {
        obj.tc_access => evalAccess(exp, env),
        obj.tc_assignment => evalAssignment(exp, env),
        obj.tc_broken_heart => abi.Microcode_Termination(abi.term_broken_heart),
        obj.tc_combination => evalCombination(exp, env),
        obj.tc_comment => evalComment(exp, env),
        obj.tc_compiled_entry => if (comptime build_options.cc_support)
            evalCompiledEntry(exp, env)
        else
            singleVal(exp),
        obj.tc_conditional => evalConditional(exp, env),
        obj.tc_definition => evalDefinition(exp, env),
        obj.tc_delay => evalDelay(exp, env),
        obj.tc_disjunction => evalDisjunction(exp, env),
        obj.tc_extended_lambda => evalExtendedLambda(exp, env),
        obj.tc_lambda => evalLambda(exp, env),
        obj.tc_manifest_nm_vector => evalError(abi.err_execute_manifest_vector, exp, env),
        obj.tc_scode_quote => evalScodeQuote(exp),
        obj.tc_sequence => evalSequence(exp, env),
        obj.tc_syntax_error => evalError(abi.err_syntax_error, exp, env),
        obj.tc_the_environment => singleVal(env),
        obj.tc_variable => evalVariable(exp, env),
        else => singleVal(exp),
    };
}

// Apply

inline fn primitiveImplementedP(proc: obj.SchemeObject) bool {
    return primutl.Primitive_Procedure_Table.?[@intCast(obj.primitiveNumber(proc))] != &primutl.Prim_unimplemented;
}

inline fn primitiveArity(proc: obj.SchemeObject) c_int {
    return primutl.Primitive_Arity_Table.?[@intCast(obj.primitiveNumber(proc))];
}

inline fn primitiveName(proc: obj.SchemeObject) [*:0]const u8 {
    return primutl.Primitive_Name_Table.?[@intCast(obj.primitiveNumber(proc))] orelse "?";
}

inline fn applyPrimitive(proc: obj.SchemeObject) Action {
    if (!primitiveImplementedP(proc)) {
        return applyError(abi.err_unimplemented_primitive);
    }
    const n_args = applyFrameNArgs();
    const arity = primitiveArity(proc);
    if (arity == abi.lexpr_primitive_arity) {
        setLexprActuals(n_args);
    } else if (arity < 0 or @as(c_ulong, @intCast(arity)) != n_args) {
        return applyError(abi.err_wrong_number_of_arguments);
    }

    abi.incrementSp(2);
    setExp(proc);
    if (build_options.debugging and storage.primitive_debug) {
        debug.debug_print_primitive(proc);
    }
    applyPrimitiveExternal(proc);
    if (build_options.debugging and storage.primitive_debug) {
        debug.debug_print_expr(getVal(), "Primitive Result");
        abi.outf_error("\n");
        abi.outf_flush_error();
    }
    abi.popPrimitiveFrame(@intCast(n_args));
    return .@"return";
}

pub fn applyPrimitiveExternal(proc: obj.SchemeObject) callconv(.c) void {
    const position = wind.dstack_position;
    setPrimitive(proc);
    abi.Free_primitive = abi.Free;
    setVal(primutl.Primitive_Procedure_Table.?[@intCast(obj.primitiveNumber(proc))]());
    if (position != wind.dstack_position) {
        abi.outf_fatal("\nPrimitive slipped the dynamic stack: %s\n", primitiveName(proc));
        abi.Microcode_Termination(abi.term_exit);
    }
    setPrimitive(obj.sharp_f);
    abi.Free_primitive = null;
}

inline fn applyProcedure(proc: obj.SchemeObject) Action {
    const frame_size = applyFrameSize();
    const lambda = obj.procLambda(proc);
    const names = obj.lambdaNames(lambda);
    if (!(frame_size == obj.vectorLength(names) or
        (obj.objectType(lambda) == obj.tc_lexpr and frame_size < obj.vectorLength(names))))
    {
        return applyError(abi.err_wrong_number_of_arguments);
    }
    const nwords = frame_size + 1;
    if (abi.gcNeededP(nwords)) {
        return applyImmediateGc(nwords);
    }
    var scan = abi.Free;
    const end_addr = @intFromPtr(scan + @as(usize, @intCast(nwords)));
    const env = obj.makePointerObject(obj.tc_environment, scan);
    scan[0] = obj.makeVectorHeader(frame_size);
    scan += 1;
    abi.incrementSp(1);
    while (@intFromPtr(scan) < end_addr) : (scan += 1) {
        scan[0] = abi.stackPop();
    }
    abi.Free = scan;
    return evalReduction(obj.memoryRef(lambda, 0), env);
}

inline fn applyExtendedProcedure(proc: obj.SchemeObject) Action {
    const lambda = obj.procLambda(proc);
    const reqs = obj.elambdaReqs(lambda);
    const opts = obj.elambdaOpts(lambda);
    const rest = obj.elambdaRest(lambda);
    const nfixed = reqs + opts;
    const nargs = applyFrameNArgs();

    if (nargs < reqs or (rest == 0 and nargs > nfixed)) {
        return applyError(abi.err_wrong_number_of_arguments);
    }

    const size = 1 + nfixed + rest;
    const rest_words: c_ulong = if (nargs > nfixed) 2 * (nargs - nfixed) else 0;
    const nwords = 1 + size + rest_words;
    if (abi.gcNeededP(nwords)) {
        return applyImmediateGc(nwords);
    }
    abi.incrementSp(1);
    var scan = abi.Free;
    const env = obj.makePointerObject(obj.tc_environment, scan);
    scan[0] = obj.makeVectorHeader(size);
    scan += 1;
    if (nargs <= nfixed) {
        scan[0] = abi.stackPop();
        scan += 1;
        var i: c_ulong = 0;
        while (i < nargs) : (i += 1) {
            scan[0] = abi.stackPop();
            scan += 1;
        }
        while (i < nfixed) : (i += 1) {
            scan[0] = obj.default_object;
            scan += 1;
        }
        if (rest == 1) {
            scan[0] = obj.empty_list;
            scan += 1;
        }
    } else {
        const rest_list = obj.makePointerObject(obj.tc_list, scan + @as(usize, @intCast(size)));
        scan[0] = abi.stackPop();
        scan += 1;
        var i: c_ulong = 0;
        while (i < nfixed) : (i += 1) {
            scan[0] = abi.stackPop();
            scan += 1;
        }
        scan[0] = rest_list;
        scan += 1;
        while (i < nargs) : (i += 1) {
            scan[0] = abi.stackPop();
            scan += 1;
            scan[0] = obj.makePointerObject(obj.tc_list, scan + 1);
            scan += 1;
        }
        (scan - 1)[0] = obj.empty_list;
    }
    abi.Free = scan;
    return evalReduction(obj.memoryRef(lambda, 0), env);
}

inline fn applyControlPoint(proc: obj.SchemeObject) Action {
    if (applyFrameSize() != 2) {
        return applyError(abi.err_wrong_number_of_arguments);
    }
    setVal(applyFrameArgs()[0]);
    hooks.unpack_control_point(proc);
    utils.reset_history();
    return .@"return";
}

inline fn applyEntity(proc: obj.SchemeObject) Action {
    const frame_size = applyFrameSize();
    const data = obj.entityData(proc);
    if (obj.vectorP(data) and
        frame_size < obj.vectorLength(data) and
        obj.vectorRef(data, @intCast(frame_size)) != obj.sharp_f and
        obj.vectorRef(data, 0) == obj.vectorRef(abi.fixed_objects, abi.fixobj_arity_dispatcher_tag))
    {
        setApplyFrameProc(obj.vectorRef(data, @intCast(frame_size)));
        return .apply_no_interrupt;
    }
    abi.stack_pointer[0] = obj.entityOperator(proc);
    abi.stackCheck(1);
    abi.stackPush(abi.makeApplyFrameHeader(frame_size + 1));
    return .apply;
}

inline fn applyApplyHook(proc: obj.SchemeObject) Action {
    const frame_size = applyFrameSize();
    const data = obj.memoryRef(proc, 1);
    if (obj.vectorP(data) and
        frame_size < obj.vectorLength(data) and
        obj.vectorRef(data, @intCast(frame_size)) != obj.sharp_f and
        obj.vectorRef(data, 0) == obj.vectorRef(abi.fixed_objects, abi.fixobj_arity_dispatcher_tag))
    {
        setApplyFrameProc(obj.vectorRef(data, @intCast(frame_size)));
        return .apply_no_interrupt;
    }
    setApplyFrameProc(obj.memoryRef(proc, 0));
    return .apply;
}

inline fn applyRecord(proc: obj.SchemeObject) Action {
    const applicator = vector.record_applicator(proc);
    if (applicator == obj.sharp_f) {
        return applyError(abi.err_inapplicable_object);
    }
    const frame_size = applyFrameSize();
    abi.stack_pointer[0] = applicator;
    abi.stackCheck(1);
    abi.stackPush(abi.makeApplyFrameHeader(frame_size + 1));
    return .apply;
}

inline fn applyCompiledEntry() Action {
    guarantee_cc_return(1 + applyFrameSize());
    return returnFromCompiledCode(apply_compiled_procedure());
}

fn apply(variant: Variant) Action {
    if (variant.trapP() and
        storage.trapping and
        boot.critical_section_name == null and
        fetchStepperTrapper(1) != obj.sharp_f)
    {
        const frame_size = applyFrameSize();
        abi.stack_pointer[0] = fetchStepperTrapper(1);
        abi.stackPush(abi.makeApplyFrameHeader(frame_size + 1));
        storage.trapping = false;
    }

    if (variant.interruptP() and abi.pendingInterrupts() != 0) {
        const interrupts = abi.pendingInterrupts();
        prepareApplyInterrupt();
        utils.setup_interrupt(interrupts);
    }

    const proc = applyFrameProc();
    return switch (obj.objectType(proc)) {
        obj.tc_entity => applyEntity(proc),
        obj.tc_apply_hook => applyApplyHook(proc),
        obj.tc_record => applyRecord(proc),
        obj.tc_procedure => applyProcedure(proc),
        obj.tc_control_point => applyControlPoint(proc),
        obj.tc_primitive => applyPrimitive(proc),
        obj.tc_extended_procedure => applyExtendedProcedure(proc),
        obj.tc_compiled_entry => if (comptime build_options.cc_support)
            applyCompiledEntry()
        else
            applyError(abi.err_inapplicable_object),
        else => applyError(abi.err_inapplicable_object),
    };
}

inline fn returnCombApplyFunction() Action {
    utils.end_subproblem();
    setApplyFrameProc(getVal());
    return .apply;
}

inline fn returnCombSaveValue() Action {
    const env = abi.stackPop();
    const exp = getExp();
    const arg = obj.objectDatum(abi.stackRef(0)) - 1;
    abi.stack_pointer[@intCast(1 + arg)] = getVal();
    abi.stack_pointer[0] = obj.makeNmvHeader(arg);
    if (arg > 0) {
        abi.pushEnvCont(abi.rc_comb_save_value, exp, env);
    } else {
        abi.stackPush(abi.makeApplyFrameHeader(obj.combinationSize(exp)));
        abi.pushCont(abi.rc_comb_apply_function, exp);
    }
    const new_exp = obj.combinationExpr(exp, @intCast(arg));
    utils.reuse_subproblem(new_exp, env);
    return reEval(new_exp, env);
}

inline fn returnConditionalDecide() Action {
    utils.end_subproblem();
    const env = abi.stackPop();
    const exp = if (getVal() == obj.sharp_f)
        obj.memoryRef(getExp(), 2)
    else
        obj.memoryRef(getExp(), 1);
    return reEval(exp, env);
}

inline fn returnDisjunctionDecide() Action {
    utils.end_subproblem();
    const env = abi.stackPop();
    return if (getVal() != obj.sharp_f)
        .@"return"
    else
        evalReduction(obj.memoryRef(getExp(), 1), env);
}

inline fn returnEndOfComputation() Action {
    const state = interpreter_state.?;
    const prev = state.previous_state orelse term.terminationEndOfComputation();
    wind.dstack_position = state.dstack_position;
    interpreter_state = prev;
    return .done;
}

inline fn returnRedoEvaluation() Action {
    const env = abi.stackPop();
    return evalReduction(getExp(), env);
}

inline fn returnAccessFinish() Action {
    var val: obj.SchemeObject = undefined;
    const code = lookup.lookup_variable(getVal(), obj.accessName(getExp()), &val);
    if (code == abi.prim_done) {
        utils.end_subproblem();
        return singleVal(val);
    }
    return returnError(code);
}

inline fn returnAssignmentFinish() Action {
    const env = abi.stackPop();
    const variable = obj.assignmentName(getExp());
    var old_val: obj.SchemeObject = undefined;
    const code: c_long = if (obj.objectType(variable) == obj.tc_variable)
        lookup.assign_variable(env, obj.variableName(variable), getVal(), &old_val)
    else
        abi.err_bad_frame;
    if (code == abi.prim_done) {
        utils.end_subproblem();
        return singleVal(old_val);
    }
    abi.stackPush(env);
    return returnError(code);
}

inline fn returnDefinitionFinish() Action {
    const env = abi.stackPop();
    const name = obj.definitionName(getExp());
    const code = lookup.define_variable(env, name, getVal());
    if (code == abi.prim_done) {
        utils.end_subproblem();
        return singleVal(name);
    }
    abi.stackPush(env);
    return returnError(code);
}

inline fn returnHardwareTrap() Action {
    const info = abi.stackRef(0);
    rePushCont();
    const handler = if (obj.vectorP(abi.fixed_objects))
        obj.vectorRef(abi.fixed_objects, abi.fixobj_trap_handler)
    else
        obj.sharp_f;
    if (handler == obj.sharp_f) {
        abi.outf_fatal("There is no trap handler for recovery!\n");
        term.terminationTrap();
    }
    abi.stackCheck(3);
    abi.stackPush(info);
    abi.stackPush(handler);
    abi.stackPush(abi.makeApplyFrameHeader(2));
    return .apply;
}

inline fn returnNormalGcDone() Action {
    setVal(getExp());
    if (abi.gcNeededP(abi.gc_space_needed)) {
        term.terminationGcOutOfSpace();
    }
    abi.gc_space_needed = 0;
    if (boot.critical_section_hook_p) {
        rePushCont();
        const name = boot.critical_section_name;
        boot.critical_section_hook_p = false;
        boot.critical_section_name = null;
        boot.critical_section_hook.?(name);
    } else {
        boot.critical_section_name = null;
    }
    return .@"return";
}

inline fn returnRestoreDontCopyHistory() Action {
    utils.prev_restore_history_offset = obj.objectDatum(abi.stackPop());
    abi.incrementSp(1);
    utils.history_register = obj.objectAddress(getExp());
    return .@"return";
}

inline fn returnRestoreHistory() Action {
    if (!utils.restore_history(getExp())) {
        return returnImmediateGc(abi.heapAvailable());
    }
    utils.prev_restore_history_offset = obj.objectDatum(abi.stackPop());
    abi.incrementSp(1);
    if (utils.prev_restore_history_offset > 0) {
        (abi.stack_end - @as(usize, @intCast(utils.prev_restore_history_offset)))[0] =
            obj.makeReturnCode(abi.rc_restore_history);
    }
    return .@"return";
}

inline fn returnRestoreIntMask() Action {
    abi.setInterruptMask(@intCast(obj.unsignedFixnumToLong(getExp())));
    if (abi.gcNeededP(0)) {
        abi.requestGc(0);
    }
    if (abi.pendingInterrupts() != 0) {
        abi.pushCont(abi.rc_restore_value, getVal());
        return handleInterrupt();
    }
    return .@"return";
}

inline fn returnStackMarker() Action {
    abi.incrementSp(1);
    return .@"return";
}

inline fn returnSequenceFinish() Action {
    utils.end_subproblem();
    const env = abi.stackPop();
    return evalReduction(obj.memoryRef(getExp(), 1), env);
}

inline fn snapDelayed(delayed: obj.SchemeObject, val: obj.SchemeObject) obj.SchemeObject {
    if (obj.memoryRef(delayed, 0) == obj.sharp_t) {
        return obj.memoryRef(delayed, 1);
    }
    obj.memorySet(delayed, 0, obj.sharp_t);
    obj.memorySet(delayed, 1, val);
    return val;
}

fn applyCont(variant: Variant) Action {
    if (variant.trapP() and
        storage.trapping and
        boot.critical_section_name == null and
        fetchStepperTrapper(2) != obj.sharp_f)
    {
        abi.stackCheck(3);
        abi.stackPush(getVal());
        abi.stackPush(fetchStepperTrapper(2));
        abi.stackPush(abi.makeApplyFrameHeader(2));
        storage.trapping = false;
    }

    if (build_options.debugging) {
        if (bkpt.sp_list != null) {
            bkpt.popReturnBreakPoint();
        }
    }

    setRet(abi.stackPop());
    setExp(abi.stackPop());

    if (build_options.debugging) {
        if (!obj.returnCodeP(getRet())) {
            abi.stackPush(getVal());
            rePushCont();
            abi.Microcode_Termination(abi.term_bad_stack);
        }
    }

    return switch (obj.objectDatum(getRet())) {
        abi.rc_comb_apply_function => returnCombApplyFunction(),
        abi.rc_comb_save_value => returnCombSaveValue(),
        abi.rc_conditional_decide => returnConditionalDecide(),
        abi.rc_disjunction_decide => returnDisjunctionDecide(),
        abi.rc_end_of_computation => returnEndOfComputation(),
        abi.rc_eval_error => returnRedoEvaluation(),
        abi.rc_execute_access_finish => returnAccessFinish(),
        abi.rc_execute_assignment_finish => returnAssignmentFinish(),
        abi.rc_execute_definition_finish => returnDefinitionFinish(),
        abi.rc_halt => abi.Microcode_Termination(abi.term_term_handler),
        abi.rc_hardware_trap => returnHardwareTrap(),
        abi.rc_internal_apply => .apply,
        abi.rc_internal_apply_val => blk: {
            setApplyFrameProc(getVal());
            break :blk .apply;
        },
        abi.rc_join_stacklets => blk: {
            hooks.unpack_control_point(getExp());
            break :blk .@"return";
        },
        abi.rc_normal_gc_done => returnNormalGcDone(),
        abi.rc_pop_return_error, abi.rc_restore_value => singleVal(getExp()),
        abi.rc_restore_dont_copy_history => returnRestoreDontCopyHistory(),
        abi.rc_restore_history => returnRestoreHistory(),
        abi.rc_restore_int_mask => returnRestoreIntMask(),
        abi.rc_stack_marker => returnStackMarker(),
        abi.rc_execute_sequence_finish => returnSequenceFinish(),
        abi.rc_snap_need_thunk => singleVal(snapDelayed(getExp(), getVal())),

        abi.rc_comp_interrupt_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_interrupt_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_lookup_trap_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_lookup_trap_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_assignment_trap_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_assignment_trap_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_op_ref_trap_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_op_lookup_trap_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_cache_ref_apply_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_cache_lookup_apply_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_safe_ref_trap_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_safe_lookup_trap_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_unassigned_trap_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_unassigned_p_trap_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_link_caches_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_link_caches_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_comp_error_restart => if (comptime build_options.cc_support)
            returnFromCompiledCode(comp_error_restart())
        else
            returnError(abi.err_inapplicable_continuation),
        abi.rc_reenter_compiled_code => if (comptime build_options.cc_support)
            returnFromCompiledCode(return_to_compiled_code())
        else
            returnError(abi.err_inapplicable_continuation),

        else => returnError(abi.err_inapplicable_continuation),
    };
}

fn handleThrow(code: c_long) Action {
    return switch (code) {
        abi.prim_apply => blk: {
            setPrimitive(obj.sharp_f);
            break :blk .apply;
        },
        abi.prim_no_trap_apply => blk: {
            setPrimitive(obj.sharp_f);
            break :blk .apply_no_trap;
        },
        abi.prim_apply_interrupt => blk: {
            setPrimitive(obj.sharp_f);
            break :blk applyInterrupt();
        },
        abi.prim_apply_error => blk: {
            setPrimitive(obj.sharp_f);
            break :blk applyError(prim_apply_error_code_storage);
        },
        abi.prim_do_expression => blk: {
            setPrimitive(obj.sharp_f);
            setVal(getExp());
            break :blk evalReduction(getExp(), getEnv());
        },
        abi.prim_no_trap_eval => blk: {
            setPrimitive(obj.sharp_f);
            setVal(getExp());
            utils.new_reduction(getExp(), getEnv());
            break :blk .eval_no_trap;
        },
        abi.prim_pop_return => blk: {
            setPrimitive(obj.sharp_f);
            break :blk .@"return";
        },
        abi.prim_return_to_c => blk: {
            setPrimitive(obj.sharp_f);
            unbindInterpreterState(interpreter_state.?);
            break :blk .done;
        },
        abi.prim_no_trap_pop_return => blk: {
            setPrimitive(obj.sharp_f);
            break :blk .return_no_trap;
        },
        abi.prim_interrupt => blk: {
            utils.back_out_of_primitive();
            break :blk handleInterrupt();
        },
        else => blk: {
            utils.back_out_of_primitive();
            break :blk handleError(code, true);
        },
    };
}

fn interpretBody(code: c_int, ctx: ?*anyopaque) callconv(.c) void {
    const state: *InterpreterState = @ptrCast(@alignCast(ctx.?));
    preserve_signal_mask();
    floenv.fixup_float_environment();

    var action: Action = if (code == 0) .eval else handleThrow(code);
    while (true) {
        action = switch (action) {
            .apply => apply(.trap),
            .apply_no_trap => apply(.no_trap),
            .apply_no_interrupt => apply(.no_interrupt),
            .eval => eval(getExp(), getEnv(), .trap),
            .eval_no_trap => eval(getExp(), getEnv(), .no_trap),
            .@"return" => applyCont(.trap),
            .return_no_trap => applyCont(.no_trap),
            .done => {
                unbindInterpreterState(state);
                return;
            },
        };
    }
}

pub fn interpret() callconv(.c) void {
    var new_state: InterpreterState = .{};
    bindInterpreterState(&new_state);
    scm_setjmp_loop(&new_state.catch_env, &interpretBody, &new_state);
}

comptime {
    if (!builtin.is_test) {
        @export(&bindInterpreterState, .{ .name = "bind_interpreter_state" });
        @export(&unbindInterpreterState, .{ .name = "unbind_interpreter_state" });
        @export(&abortToInterpreter, .{ .name = "abort_to_interpreter" });
        @export(&abortToInterpreterArgument, .{ .name = "abort_to_interpreter_argument" });
        @export(&prim_apply_error_code_storage, .{ .name = "prim_apply_error_code" });
        @export(&applyPrimitiveExternal, .{ .name = "apply_primitive_external" });
        @export(&interpret, .{ .name = "Interpret" });
    }
}

fn testLoopBody(code: c_int, ctx: ?*anyopaque) callconv(.c) void {
    const StateCtx = struct {
        catch_env: ?*anyopaque,
        seen: c_int,
    };
    const st: *StateCtx = @ptrCast(@alignCast(ctx.?));
    if (code == 0) {
        scm_longjmp(st.catch_env.?, 7);
    }
    st.seen = code;
}

fn testTryThrowBody(ctx: ?*anyopaque) callconv(.c) void {
    const slot: *?*anyopaque = @ptrCast(@alignCast(ctx.?));
    scm_longjmp(slot.*.?, 13);
}

test "interp scm_setjmp_loop, scm_setjmp_try, and bindInterpreterState nesting" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const LoopCtx = struct {
        catch_env: ?*anyopaque = null,
        seen: c_int = 0,
    };
    var loop_ctx = LoopCtx{};
    scm_setjmp_loop(&loop_ctx.catch_env, &testLoopBody, &loop_ctx);
    try std.testing.expectEqual(@as(c_int, 7), loop_ctx.seen);

    var try_env: ?*anyopaque = null;
    const rc = scm_setjmp_try(&try_env, &testTryThrowBody, @ptrCast(&try_env));
    try std.testing.expectEqual(@as(c_int, 13), rc);

    var outer: InterpreterState = .{};
    var inner: InterpreterState = .{};
    bindInterpreterState(&outer);
    try std.testing.expectEqual(@as(c_uint, 0), outer.nesting_level);
    try std.testing.expectEqual(&outer, interpreter_state.?);
    bindInterpreterState(&inner);
    try std.testing.expectEqual(@as(c_uint, 1), inner.nesting_level);
    try std.testing.expectEqual(&outer, inner.previous_state.?);
    unbindInterpreterState(&inner);
    try std.testing.expectEqual(&outer, interpreter_state.?);
    unbindInterpreterState(&outer);
    try std.testing.expectEqual(@as(?*InterpreterState, null), interpreter_state);
}
