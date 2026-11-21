// Derived from MIT/GNU Scheme C sources (`src/microcode/step.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

fn installTraps(state: obj.SchemeObject) void {
    obj.vectorSet(abi.fixed_objects, abi.fixobj_stepper_state, state);
    abi.trapping = obj.objectToBoolean(obj.memoryRef(state, 0)) or
        obj.objectToBoolean(obj.memoryRef(state, 1)) or
        obj.objectToBoolean(obj.memoryRef(state, 2));
}

// DEFINE_PRIMITIVE ("PRIMITIVE-EVAL-STEP", Prim_eval_step, 3, 3, 0)
pub export fn Prim_eval_step() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(3, obj.hunk3P);
    const expression = abi.argRef(1);
    const environment = abi.argRef(2);
    const hooks = abi.argRef(3);
    abi.canonicalize_primitive_context();
    abi.popPrimitiveFrame(3);
    installTraps(hooks);
    abi.Registers[abi.regblock_expr] = expression;
    abi.Registers[abi.regblock_env] = environment;
    abi.abort_to_interpreter(abi.prim_no_trap_eval);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-APPLY-STEP", Prim_apply_step, 3, 3, 0)
pub export fn Prim_apply_step() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    abi.checkArg(3, obj.hunk3P);

    const procedure = abi.argRef(1);
    const argument_list = abi.argRef(2);
    const hooks = abi.argRef(3);

    var scan_list = argument_list;
    var number_of_args: usize = 0;
    while (obj.pairP(scan_list)) {
        number_of_args += 1;
        scan_list = obj.pairCdr(scan_list);
    }
    if (!obj.emptyListP(scan_list)) {
        abi.error_wrong_type_arg(2);
    }

    abi.popPrimitiveFrame(3);
    installTraps(hooks);

    abi.stackCheck(number_of_args + 2);
    abi.decrementSp(number_of_args);
    scan_list = argument_list;
    var scan_stack = abi.stack_pointer;
    while (obj.pairP(scan_list)) {
        scan_stack[0] = obj.pairCar(scan_list);
        scan_stack += 1;
        scan_list = obj.pairCdr(scan_list);
    }
    abi.stackPush(procedure);
    abi.stackPush(obj.makeVectorHeader(@intCast(number_of_args + 1)));
    abi.abort_to_interpreter(abi.prim_no_trap_apply);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-RETURN-STEP", Prim_return_step, 2, 2, 0)
pub export fn Prim_return_step() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.canonicalize_primitive_context();
    abi.checkArg(2, obj.hunk3P);

    const value = abi.argRef(1);
    const hooks = abi.argRef(2);
    abi.popPrimitiveFrame(2);
    installTraps(hooks);
    abi.Registers[abi.regblock_val] = value;
    abi.abort_to_interpreter(abi.prim_no_trap_pop_return);
}

test "step installTraps updates fixed_objects and trapping flag" {
    const stubs = @import("test_stubs.zig");
    const hunk = @import("hunk.zig");
    stubs.resetMockRuntime();

    abi.fixed_objects = abi.make_vector(0x20, obj.sharp_f, true);
    const inactive = hunk.hunk3_cons(obj.sharp_f, obj.sharp_f, obj.sharp_f);
    installTraps(inactive);
    try std.testing.expectEqual(inactive, obj.vectorRef(abi.fixed_objects, abi.fixobj_stepper_state));
    try std.testing.expect(!abi.trapping);

    const active = hunk.hunk3_cons(obj.sharp_f, obj.sharp_t, obj.sharp_f);
    installTraps(active);
    try std.testing.expectEqual(active, obj.vectorRef(abi.fixed_objects, abi.fixobj_stepper_state));
    try std.testing.expect(abi.trapping);
}
