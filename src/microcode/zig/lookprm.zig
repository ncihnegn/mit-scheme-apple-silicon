// Derived from MIT/GNU Scheme C sources (`src/microcode/lookprm.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

fn stdLookup(result: c_long) void {
    if (result != abi.prim_done) {
        if (result == abi.prim_interrupt) {
            abi.signal_interrupt_from_primitive();
        } else {
            abi.signal_error_from_primitive(result);
        }
    }
}

// DEFINE_PRIMITIVE ("LEXICAL-REFERENCE", Prim_lexical_reference, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Returns the value of the variable in ENVIRONMENT named SYMBOL.\n\
// \n\
// Indistinguishable from evaluating SYMBOL in ENVIRONMENT.")
pub export fn Prim_lexical_reference() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.lookup_variable(abi.argRef(1), abi.argRef(2), &value));
    return value;
}

// DEFINE_PRIMITIVE ("LOCAL-REFERENCE", Prim_local_reference, 2, 2,
//   "(REFERENCE ENVIRONMENT SYMBOL)\n\
// Identical to LEXICAL_REFERENCE, here for hysterical reasons.")
pub export fn Prim_local_reference() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.lookup_variable(abi.argRef(1), abi.argRef(2), &value));
    return value;
}

// DEFINE_PRIMITIVE ("LEXICAL-ASSIGNMENT", Prim_lexical_assignment, 3, 3,
//   "(ASSIGNMENT ENVIRONMENT SYMBOL VALUE)\n\
// Sets the value of the variable in ENVIRONMENT named SYMBOL to VALUE.\n\
// Returns the previous value.\n\
// \n\
// Indistinguishable from evaluating (set! SYMBOL VALUE) in ENVIRONMENT.")
pub export fn Prim_lexical_assignment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.assign_variable(abi.argRef(1), abi.argRef(2), abi.argRef(3), &value));
    return value;
}

// DEFINE_PRIMITIVE ("LOCAL-ASSIGNMENT", Prim_local_assignment, 3, 3,
//   "(ENVIRONMENT SYMBOL VALUE)\n\
//     [Should be called LEXICAL-DEFINE.]\n\
// \n\
// If the variable specified by SYMBOL already exists in the\n\
// lexical ENVIRONMENT, then its value there is changed to VALUE.\n\
// Otherwise a new binding is created in that environment linking\n\
// the specified variable to the value.  Returns SYMBOL.\n\
// \n\
// Indistinguishable from evaluating (define SYMBOL VALUE) in ENVIRONMENT.")
pub export fn Prim_local_assignment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    stdLookup(abi.define_variable(abi.argRef(1), abi.argRef(2), abi.argRef(3)));
    return abi.argRef(2);
}

// DEFINE_PRIMITIVE ("LEXICAL-REFERENCE-TYPE", Prim_lexical_reference_type, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Returns a index integer indicating the type of object stored in the\n\
// binding of SYMBOL within ENVIRONMENT.  The following values are defined:\n\
// \n\
// 0 means unbound\n\
// 1 means unassigned\n\
// 2 means a normal binding\n\
// 3 means a macro binding")
pub export fn Prim_lexical_reference_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    const result = abi.lookup_variable(abi.argRef(1), abi.argRef(2), &value);
    switch (result) {
        abi.err_unbound_variable => return obj.ulongToFixnum(0),
        abi.err_unassigned_variable => return obj.ulongToFixnum(1),
        abi.prim_done => return obj.ulongToFixnum(2),
        abi.err_macro_binding => return obj.ulongToFixnum(3),
        abi.prim_interrupt => abi.signal_interrupt_from_primitive(),
        else => abi.signal_error_from_primitive(result),
    }
}

// DEFINE_PRIMITIVE ("SAFE-LEXICAL-REFERENCE", Prim_safe_lexical_reference, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Looks up SYMBOL in ENVIRONMENT and returns its value.\n\
// If the variable is unbound, signals an error.\n\
// If the variable is unassigned or holds a macro transformer,\n\
//  returns the appropriate trap object.")
pub export fn Prim_safe_lexical_reference() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    const result = abi.lookup_variable(abi.argRef(1), abi.argRef(2), &value);
    switch (result) {
        abi.prim_done, abi.err_macro_binding => return value,
        abi.err_unassigned_variable => return obj.unassigned_object,
        abi.prim_interrupt => abi.signal_interrupt_from_primitive(),
        else => abi.signal_error_from_primitive(result),
    }
}

// DEFINE_PRIMITIVE ("LEXICAL-UNASSIGNED?", Prim_unassigned_test, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Returns #T if the variable corresponding to SYMBOL is bound\n\
// but has the special UNASSIGNED value in ENVIRONMENT.  Returns\n\
// #F otherwise.  Does a complete lexical search for SYMBOL\n\
// starting in ENVIRONMENT.\n\
// The special form (unassigned? <symbol>) is built on top of this.")
pub export fn Prim_unassigned_test() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.variable_unassigned_p(abi.argRef(1), abi.argRef(2), &value));
    return value;
}

// DEFINE_PRIMITIVE ("LEXICAL-UNBOUND?", Prim_unbound_test, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Returns #T if the variable corresponding to SYMBOL has no binding in\n\
// ENVIRONMENT.  Returns #F otherwise.  Does a complete lexical search\n\
// for SYMBOL starting in ENVIRONMENT.")
pub export fn Prim_unbound_test() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.variable_unbound_p(abi.argRef(1), abi.argRef(2), &value));
    return value;
}

// DEFINE_PRIMITIVE ("LEXICAL-UNREFERENCEABLE?", Prim_unreferenceable_test, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Returns #T if looking up SYMBOL in ENVIRONMENT would cause an error.\n\
// Returns #F otherwise.")
pub export fn Prim_unreferenceable_test() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.variable_unreferenceable_p(abi.argRef(1), abi.argRef(2), &value));
    return value;
}

// DEFINE_PRIMITIVE ("ENVIRONMENT-LINK-NAME", Prim_environment_link_name, 3, 3,
//   "(ENV1 ENV2 SYMBOL)\n\
// SYMBOL must be bound in ENV2.  Creates a new binding for SYMBOL in ENV1,\n\
// such that the bindings in ENV1 and ENV2 share the same value cell.\n\
// If SYMBOL is already bound in ENV1, the existing binding is modified.")
pub export fn Prim_environment_link_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.environmentP);
    abi.checkArg(3, obj.symbolP);
    stdLookup(abi.link_variables(abi.argRef(1), abi.argRef(3), abi.argRef(2), abi.argRef(3)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("LINK-VARIABLES", Prim_link_variables, 4, 4,
//   "(TARGET-ENV TARGET-NAME SOURCE-ENV SOURCE-NAME)\n\
// Define a new binding for TARGET-NAME in TARGET-ENV, which shares its\n\
// value cell with the binding for SOURCE-NAME in SOURCE-ENV.\n\
// SOURCE-NAME must be bound in SOURCE-ENV.")
pub export fn Prim_link_variables() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    abi.checkArg(3, obj.environmentP);
    abi.checkArg(4, obj.symbolP);
    stdLookup(abi.link_variables(abi.argRef(1), abi.argRef(2), abi.argRef(3), abi.argRef(4)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("UNBIND-VARIABLE", Prim_unbind_variable, 2, 2,
//   "(ENVIRONMENT SYMBOL)\n\
// Unbind the variable SYMBOL in ENVIRONMENT.\n\
// Returns #F if the variable was not previously bound, otherwise #T.")
pub export fn Prim_unbind_variable() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.environmentP);
    abi.checkArg(2, obj.symbolP);
    var value: obj.SchemeObject = undefined;
    stdLookup(abi.unbind_variable(abi.argRef(1), abi.argRef(2), &value));
    return value;
}

test "lookprm primitives dispatch lookup helpers and map reference codes" {
    const stubs = @import("test_stubs.zig");
    const intern = @import("intern.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    const fixobj = abi.make_vector(abi.fixobj_gc_reclaimed + 1, obj.sharp_f, false);
    obj.vectorSet(fixobj, abi.fixobj_non_object, obj.unassigned_object);
    obj.vectorSet(fixobj, abi.fixobj_obarray, abi.make_vector(7, obj.empty_list, false));
    abi.fixed_objects = fixobj;

    const sym = intern.char_pointer_to_symbol("x");
    const other_sym = intern.char_pointer_to_symbol("y");
    const env = obj.the_global_env;

    // Procedure frame with parameter `other_sym`
    const names = abi.make_vector(2, obj.sharp_f, false);
    obj.vectorSet(names, 1, other_sym);
    const lambda = abi.cons(obj.sharp_f, names);
    const proc_addr = abi.Free;
    proc_addr[0] = lambda;
    proc_addr[1] = env;
    abi.Free = proc_addr + 2;
    const proc = obj.makePointerObject(obj.tc_procedure, proc_addr);
    const env_addr = abi.Free;
    env_addr[0] = obj.makeVectorHeader(2);
    env_addr[1] = proc;
    env_addr[2] = obj.ulongToFixnum(55);
    abi.Free = env_addr + 3;
    const frame_env = obj.makePointerObject(obj.tc_environment, env_addr);

    try std.testing.expect(obj.environmentP(env));
    try std.testing.expect(obj.environmentP(frame_env));
    try std.testing.expect(!obj.environmentP(obj.the_null_env));

    // Unbound (0)
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_lexical_reference_type());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.sharp_t, Prim_unbound_test());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.sharp_t, Prim_unreferenceable_test());

    // Define & lookup in global env and procedure frame
    stubs.setArgs(&.{ env, sym, obj.ulongToFixnum(99) });
    try std.testing.expectEqual(sym, Prim_local_assignment());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(99), Prim_lexical_reference());
    stubs.setArgs(&.{ frame_env, other_sym });
    try std.testing.expectEqual(obj.ulongToFixnum(55), Prim_local_reference());

    // Normal binding (2) & assignment returning previous value
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(2), Prim_lexical_reference_type());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(99), Prim_safe_lexical_reference());
    stubs.setArgs(&.{ env, sym, obj.ulongToFixnum(123) });
    try std.testing.expectEqual(obj.ulongToFixnum(99), Prim_lexical_assignment());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(123), Prim_lexical_reference());

    // Unassigned (1) via LOCAL-ASSIGNMENT with external unassigned object
    stubs.setArgs(&.{ env, sym, obj.unassigned_object });
    _ = Prim_local_assignment();
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(1), Prim_lexical_reference_type());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.unassigned_object, Prim_safe_lexical_reference());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.sharp_t, Prim_unassigned_test());

    // Macro trap (3) via pointer trap {TRAP_MACRO, #t}
    const trap_addr = abi.Free;
    trap_addr[0] = obj.ulongToFixnum(obj.trap_macro);
    trap_addr[1] = obj.sharp_t;
    abi.Free = trap_addr + 2;
    const macro_trap = obj.makePointerObject(obj.tc_reference_trap, trap_addr);
    obj.setSymbolGlobalValue(sym, macro_trap);
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_lexical_reference_type());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(macro_trap, Prim_safe_lexical_reference());
    // LEXICAL-UNREFERENCEABLE? delegates to variable_unreferenceable_p: #t on macro, #f on value, err_bad_frame on invalid env/sym.
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.sharp_t, Prim_unreferenceable_test());
    stubs.setArgs(&.{ frame_env, other_sym });
    try std.testing.expectEqual(obj.sharp_f, Prim_unreferenceable_test());
    var dummy: obj.SchemeObject = undefined;
    try std.testing.expectEqual(abi.err_bad_frame, abi.variable_unreferenceable_p(obj.sharp_f, obj.sharp_f, &dummy));

    // Link & unbind
    stubs.setArgs(&.{ env, frame_env, other_sym });
    try std.testing.expectEqual(obj.unspecific, Prim_environment_link_name());
    stubs.setArgs(&.{ env, other_sym });
    try std.testing.expectEqual(obj.ulongToFixnum(55), Prim_lexical_reference());

    stubs.setArgs(&.{ env, sym, frame_env, other_sym });
    try std.testing.expectEqual(obj.unspecific, Prim_link_variables());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.ulongToFixnum(55), Prim_lexical_reference());

    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.sharp_t, Prim_unbind_variable());
    stubs.setArgs(&.{ env, sym });
    try std.testing.expectEqual(obj.sharp_f, Prim_unbind_variable());
}
