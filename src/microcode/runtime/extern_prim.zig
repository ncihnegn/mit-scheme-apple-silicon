// Derived from MIT/GNU Scheme C sources (`src/microcode/extern.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const str = @import("../data/string.zig");

// DEFINE_PRIMITIVE ("MAP-CODE-TO-MACHINE-ADDRESS", Prim_map_code_to_address, 2, 2,
//   "For return codes and primitives, this returns the internal\n\
// representation of the return address or primitive address given the\n\
// external representation.\n\
// \n\
// This accepts two arguments, TYPE-CODE and VALUE-CODE.  TYPE-CODE is\n\
// the microcode type of the object to be returned; it must be either a\n\
// return address or primitive procedure type.  VALUE-CODE is the index\n\
// number (i.e. external representation) of the desired result.")
pub export fn Prim_map_code_to_address() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const tc: usize = @intCast(abi.arg_nonnegative_integer(1));
    const number: usize = @intCast(abi.arg_nonnegative_integer(2));
    switch (tc) {
        obj.tc_return_code => {
            if (number > abi.max_return_code) abi.error_bad_range_arg(2);
            return obj.makeObject(tc, number);
        },
        obj.tc_primitive => {
            if (number > abi.MAX_PRIMITIVE) abi.error_bad_range_arg(2);
            return obj.makePrimitiveObject(number);
        },
        else => abi.error_bad_range_arg(1),
    }
}

// DEFINE_PRIMITIVE ("MAP-MACHINE-ADDRESS-TO-CODE", Prim_map_address_to_code, 2, 2,
//   "This is the inverse operation of `map-code-to-machine-address'.  Given\n\
// a machine ADDRESS and a TYPE-CODE (either return code or primitive\n\
// procedure), it finds the number for the external representation for\n\
// the internal address.")
pub export fn Prim_map_address_to_code() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const tc: usize = @intCast(abi.arg_nonnegative_integer(1));
    const address = abi.argRef(2);
    if (obj.objectType(address) != tc) abi.error_wrong_type_arg(2);
    switch (tc) {
        obj.tc_return_code => {
            const number = obj.objectDatum(address);
            if (number > abi.max_return_code) abi.error_bad_range_arg(2);
            return obj.ulongToFixnum(number);
        },
        obj.tc_primitive => {
            return obj.ulongToFixnum(obj.primitiveNumber(address));
        },
        else => abi.error_bad_range_arg(1),
    }
}

// DEFINE_PRIMITIVE ("PRIMITIVE-PROCEDURE-ARITY", Prim_primitive_procedure_arity, 1, 1,
//   "Given a primitive procedure, returns the number of arguments it requires.")
pub export fn Prim_primitive_procedure_arity() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.primitiveP);
    const prim = abi.argRef(1);
    const num = obj.primitiveNumber(prim);
    if (num > abi.MAX_PRIMITIVE) abi.error_bad_range_arg(1);
    return obj.longToFixnum(abi.Primitive_Arity_Table.?[@intCast(num)]);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-PROCEDURE-DOCUMENTATION", Prim_primitive_procedure_doc, 1, 1,
//   "Given a primitive procedure, return its documentation string.")
pub export fn Prim_primitive_procedure_doc() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.primitiveP);
    const prim = abi.argRef(1);
    const num = obj.primitiveNumber(prim);
    if (num > abi.MAX_PRIMITIVE) abi.error_bad_range_arg(1);
    const answer = abi.Primitive_Documentation_Table.?[@intCast(num)];
    return if (answer) |doc| str.char_pointer_to_string(doc) else obj.sharp_f;
}

// DEFINE_PRIMITIVE ("GET-PRIMITIVE-COUNTS", Prim_get_primitive_counts, 0, 0,
//   "Return a pair of integers which are the number of primitive procedures.\n\
// The car is the count of defined primitives;\n\
// the cdr is the count of undefined primitives that are referenced.")
pub export fn Prim_get_primitive_counts() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.cons(obj.ulongToFixnum(abi.MAX_PRIMITIVE), obj.ulongToFixnum(0));
}

// DEFINE_PRIMITIVE ("GET-PRIMITIVE-NAME", Prim_get_primitive_name, 1, 1,
//   "Return the (string) name of PRIMITIVE-PROCEDURE.")
pub export fn Prim_get_primitive_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const prim = abi.argRef(1);
    if (!(obj.primitiveP(prim) or obj.fixnumP(prim))) abi.error_wrong_type_arg(1);
    const number = obj.primitiveNumber(prim);
    if (number > abi.MAX_PRIMITIVE) abi.error_bad_range_arg(1);
    return str.char_pointer_to_string(abi.Primitive_Name_Table.?[@intCast(number)]);
}

// DEFINE_PRIMITIVE ("GET-PRIMITIVE-ADDRESS", Prim_get_primitive_address, 2, 2,
//   "Given a symbol NAME, return the primitive object of that name.\n\
// ARITY is the number of arguments which the primitive should expect.\n\
// If ARITY is #F, #F is returned if the primitive is not implemented,\n\
// even if the name already exists.\n\
// If ARITY is an integer, a primitive object will always be returned,\n\
// whether the corresponding primitive is implemented or not.")
pub export fn Prim_get_primitive_address() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.symbolP);
    const name = abi.argRef(1);
    const arity_arg = abi.argRef(2);
    var allow_p = false;
    var intern_p = false;
    var arity: c_int = abi.unknown_primitive_arity;
    if (arity_arg == obj.sharp_f) {
        allow_p = false;
        intern_p = false;
        arity = abi.unknown_primitive_arity;
    } else if (arity_arg == obj.sharp_t) {
        allow_p = true;
        intern_p = false;
        arity = abi.unknown_primitive_arity;
    } else {
        abi.checkArg(2, obj.fixnumP);
        allow_p = true;
        intern_p = true;
        arity = @truncate(obj.fixnumToLong(arity_arg));
    }
    return abi.find_primitive(obj.symbolName(name), intern_p, allow_p, arity);
}

// DEFINE_PRIMITIVE ("PRIMITIVE-PROCEDURE-OPEN-CODED?", Prim_primitive_procedure_open_coded, 1, 1,
//   "(PRIMITIVE)\n\
// Returns #t iff PRIMITIVE is open-coded by the compiler.\n\
// Only returns #t if constant-folded by the same compiler.")
pub export fn Prim_primitive_procedure_open_coded() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.primitiveP);
    return obj.sharp_f;
}

test "extern primitive address, metadata, counts, and lookup" {
    const stubs = @import("../core/test_stubs.zig");
    const primutl = @import("primutl.zig");
    stubs.resetMockRuntime();
    primutl.resetForTesting();
    defer primutl.resetForTesting();
    primutl.initialize_primitives();

    // Map return code & primitive roundtrip
    stubs.setArgs(&.{ obj.ulongToFixnum(obj.tc_return_code), obj.ulongToFixnum(5) });
    const rc = Prim_map_code_to_address();
    try std.testing.expectEqual(obj.makeReturnCode(5), rc);
    stubs.setArgs(&.{ obj.ulongToFixnum(obj.tc_return_code), rc });
    try std.testing.expectEqual(obj.ulongToFixnum(5), Prim_map_address_to_code());

    stubs.setArgs(&.{ obj.ulongToFixnum(obj.tc_primitive), obj.ulongToFixnum(0) });
    const p0 = Prim_map_code_to_address();
    try std.testing.expectEqual(obj.makePrimitiveObject(0), p0);

    // Arity, doc, name, counts, open-coded?
    stubs.setArgs(&.{p0});
    try std.testing.expectEqual(obj.longToFixnum(1), Prim_primitive_procedure_arity());
    stubs.setArgs(&.{p0});
    try std.testing.expect(str.string_p(Prim_primitive_procedure_doc()));
    stubs.setArgs(&.{obj.makePrimitiveObject(1)});
    try std.testing.expectEqual(obj.sharp_f, Prim_primitive_procedure_doc());
    stubs.setArgs(&.{obj.ulongToFixnum(1)});
    const p1_name = Prim_get_primitive_name();
    try std.testing.expectEqual(@as(usize, 3), obj.legacyStringLength(p1_name));
    stubs.setArgs(&.{p0});
    try std.testing.expectEqual(obj.sharp_f, Prim_primitive_procedure_open_coded());

    stubs.setArgs(&.{});
    const counts = Prim_get_primitive_counts();
    try std.testing.expectEqual(obj.ulongToFixnum(abi.MAX_PRIMITIVE), obj.pairCar(counts));
    try std.testing.expectEqual(obj.ulongToFixnum(0), obj.pairCdr(counts));

    // GET-PRIMITIVE-ADDRESS
    const sym = abi.system_pair_cons(@intCast(obj.tc_interned_symbol), str.char_pointer_to_string("car"), obj.unbound_object);
    stubs.setArgs(&.{ sym, obj.sharp_t });
    try std.testing.expectEqual(p0, Prim_get_primitive_address());
}
