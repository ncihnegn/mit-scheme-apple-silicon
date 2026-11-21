// Derived from MIT/GNU Scheme C sources (`src/microcode/generic.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

fn indirect(slot: usize, arity: c_ulong) noreturn {
    abi.canonicalize_primitive_context();
    abi.stackCheck(2);
    abi.stackPush(obj.vectorRef(abi.fixed_objects, slot));
    abi.stackPush(obj.makeVectorHeader(arity + 1));
    abi.abort_to_interpreter(abi.prim_apply);
}

// DEFINE_PRIMITIVE ("ZERO?", Prim_zero, 1, 1, 0)
pub export fn Prim_zero() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    if (obj.fixnumP(x)) return obj.booleanToObject(obj.fixnumZeroP(x));
    indirect(abi.fixobj_generic_trampoline_zero_p, 1);
}

// DEFINE_PRIMITIVE ("POSITIVE?", Prim_positive, 1, 1, 0)
pub export fn Prim_positive() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    if (obj.fixnumP(x)) return obj.booleanToObject(obj.fixnumPositiveP(x));
    indirect(abi.fixobj_generic_trampoline_positive_p, 1);
}

// DEFINE_PRIMITIVE ("NEGATIVE?", Prim_negative, 1, 1, 0)
pub export fn Prim_negative() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    if (obj.fixnumP(x)) return obj.booleanToObject(obj.fixnumNegativeP(x));
    indirect(abi.fixobj_generic_trampoline_negative_p, 1);
}

// DEFINE_PRIMITIVE ("1+", Prim_add_one, 1, 1, 0)
pub export fn Prim_add_one() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    if (obj.fixnumP(x)) return abi.long_to_integer(obj.fixnumToLong(x) + 1);
    indirect(abi.fixobj_generic_trampoline_successor, 1);
}

// DEFINE_PRIMITIVE ("-1+", Prim_subtract_one, 1, 1, 0)
pub export fn Prim_subtract_one() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    if (obj.fixnumP(x)) return abi.long_to_integer(obj.fixnumToLong(x) - 1);
    indirect(abi.fixobj_generic_trampoline_predecessor, 1);
}

// DEFINE_PRIMITIVE ("&=", Prim_equal_number, 2, 2, 0)
pub export fn Prim_equal_number() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    const y = abi.argRef(2);
    if (obj.fixnumP(x) and obj.fixnumP(y)) return obj.booleanToObject(obj.fixnumEqualP(x, y));
    indirect(abi.fixobj_generic_trampoline_equal_p, 2);
}

// DEFINE_PRIMITIVE ("&<", Prim_less, 2, 2, 0)
pub export fn Prim_less() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    const y = abi.argRef(2);
    if (obj.fixnumP(x) and obj.fixnumP(y)) return obj.booleanToObject(obj.fixnumLessP(x, y));
    indirect(abi.fixobj_generic_trampoline_less_p, 2);
}

// DEFINE_PRIMITIVE ("&>", Prim_greater, 2, 2, 0)
pub export fn Prim_greater() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    const y = abi.argRef(2);
    if (obj.fixnumP(x) and obj.fixnumP(y)) return obj.booleanToObject(obj.fixnumLessP(y, x));
    indirect(abi.fixobj_generic_trampoline_greater_p, 2);
}

// DEFINE_PRIMITIVE ("&+", Prim_add, 2, 2, 0)
pub export fn Prim_add() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    const y = abi.argRef(2);
    if (obj.fixnumP(x) and obj.fixnumP(y)) return abi.long_to_integer(obj.fixnumToLong(x) + obj.fixnumToLong(y));
    indirect(abi.fixobj_generic_trampoline_add, 2);
}

// DEFINE_PRIMITIVE ("&-", Prim_subtract, 2, 2, 0)
pub export fn Prim_subtract() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = abi.argRef(1);
    const y = abi.argRef(2);
    if (obj.fixnumP(x) and obj.fixnumP(y)) return abi.long_to_integer(obj.fixnumToLong(x) - obj.fixnumToLong(y));
    indirect(abi.fixobj_generic_trampoline_subtract, 2);
}

// DEFINE_PRIMITIVE ("&*", Prim_multiply, 2, 2, 0)
pub export fn Prim_multiply() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    indirect(abi.fixobj_generic_trampoline_multiply, 2);
}

// DEFINE_PRIMITIVE ("&/", Prim_divide, 2, 2, 0)
pub export fn Prim_divide() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    indirect(abi.fixobj_generic_trampoline_divide, 2);
}

// DEFINE_PRIMITIVE ("QUOTIENT", Prim_quotient, 2, 2, 0)
pub export fn Prim_quotient() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    indirect(abi.fixobj_generic_trampoline_quotient, 2);
}

// DEFINE_PRIMITIVE ("REMAINDER", Prim_remainder, 2, 2, 0)
pub export fn Prim_remainder() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    indirect(abi.fixobj_generic_trampoline_remainder, 2);
}

// DEFINE_PRIMITIVE ("MODULO", Prim_modulo, 2, 2, 0)
pub export fn Prim_modulo() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    indirect(abi.fixobj_generic_trampoline_modulo, 2);
}

test "generic arithmetic fixnum fast paths" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    stubs.setArgs(&.{obj.longToFixnum(0)});
    try std.testing.expectEqual(obj.sharp_t, Prim_zero());
    try std.testing.expectEqual(obj.sharp_f, Prim_positive());
    try std.testing.expectEqual(obj.sharp_f, Prim_negative());
    try std.testing.expectEqual(obj.longToFixnum(1), Prim_add_one());
    try std.testing.expectEqual(obj.longToFixnum(-1), Prim_subtract_one());

    stubs.setArgs(&.{ obj.longToFixnum(-3), obj.longToFixnum(5) });
    try std.testing.expectEqual(obj.sharp_f, Prim_equal_number());
    try std.testing.expectEqual(obj.sharp_t, Prim_less());
    try std.testing.expectEqual(obj.sharp_f, Prim_greater());
    try std.testing.expectEqual(obj.longToFixnum(2), Prim_add());
    try std.testing.expectEqual(obj.longToFixnum(-8), Prim_subtract());
}
