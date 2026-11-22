// Derived from MIT/GNU Scheme C sources (`src/microcode/floenv.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const artutl = @import("artutl.zig");
const fenv = @import("fenv_plat.zig");

const frmode_nearest: usize = 0;
const frmode_toward_zero: usize = 1;
const frmode_downward: usize = 2;
const frmode_upward: usize = 3;

const non_trappable_exceptions: c_int = fenv.fe_inexact;

comptime {
    std.debug.assert(obj.ulongToFixnumP(@as(usize, @intCast(fenv.fe_all_except))));
}

var scheme_fenv_p: bool = false;
var scheme_fenv: fenv.FenvT = undefined;

fn cacheFloatEnvironment() void {
    if (fenv.fegetenv(&scheme_fenv) != 0) abi.error_external_return();
    scheme_fenv_p = true;
    // Work around pre-2014-04 glibc lossage: fegetenv masked traps on amd64.
    if (fenv.fesetenv(&scheme_fenv) != 0) abi.error_external_return();
}

pub export fn fixup_float_environment() callconv(.c) void {
    if (scheme_fenv_p) {
        _ = fenv.fesetenv(&scheme_fenv);
    }
}

pub export fn clear_float_exceptions() callconv(.c) void {
    _ = fenv.feclearexcept(fenv.fe_all_except);
    cacheFloatEnvironment();
}

fn allocStructBytes(comptime T: type, val: *const T) obj.SchemeObject {
    const res = abi.allocate_string(@sizeOf(T));
    const dst = obj.legacyStringData(res)[0..@sizeOf(T)];
    @memcpy(dst, std.mem.asBytes(val));
    return res;
}

fn argStructBytes(comptime T: type, n: c_int) T {
    abi.checkArg(n, abi.string_p);
    const s = abi.argRef(@intCast(n));
    if (obj.legacyStringLength(s) != @sizeOf(T)) abi.error_bad_range_arg(n);
    var out: T = undefined;
    @memcpy(std.mem.asBytes(&out), obj.legacyStringData(s)[0..@sizeOf(T)]);
    return out;
}

inline fn exceptionsMachineToScheme(except_machine: c_int) usize {
    return @intCast(except_machine);
}

inline fn exceptionsResult(except_machine: c_int) obj.SchemeObject {
    return obj.ulongToFixnum(exceptionsMachineToScheme(except_machine));
}

fn argFloatExceptions(n: c_int) c_int {
    abi.checkArg(n, obj.unsignedFixnumP);
    const scheme_exceptions = obj.fixnumToUlong(abi.argRef(@intCast(n)));
    if ((scheme_exceptions & ~exceptionsMachineToScheme(fenv.fe_all_except)) != 0) {
        abi.error_bad_range_arg(n);
    }
    return @intCast(scheme_exceptions);
}

// DEFINE_PRIMITIVE ("FLOAT-ENVIRONMENT", Prim_float_environment, 0, 0, 0)
pub export fn Prim_float_environment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var env: fenv.FenvT = undefined;
    if (fenv.fegetenv(&env) != 0) abi.error_external_return();
    // Work around glibc lossage.
    if (fenv.fesetenv(&env) != 0) abi.error_external_return();
    return allocStructBytes(fenv.FenvT, &env);
}

// DEFINE_PRIMITIVE ("SET-FLOAT-ENVIRONMENT", Prim_set_float_environment, 1, 1, 0)
pub export fn Prim_set_float_environment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const env = argStructBytes(fenv.FenvT, 1);
    if (fenv.fesetenv(&env) != 0) abi.error_external_return();
    cacheFloatEnvironment();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("DEFER-FLOAT-EXCEPTION-TRAPS", Prim_defer_float_exception_traps, 0, 0, 0)
pub export fn Prim_defer_float_exception_traps() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var env: fenv.FenvT = undefined;
    if (fenv.feholdexcept(&env) != 0) abi.error_external_return();
    cacheFloatEnvironment();
    return allocStructBytes(fenv.FenvT, &env);
}

// DEFINE_PRIMITIVE ("UPDATE-FLOAT-ENVIRONMENT", Prim_update_float_environment, 1, 1, 0)
pub export fn Prim_update_float_environment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const env = argStructBytes(fenv.FenvT, 1);
    if (fenv.feupdateenv(&env) != 0) abi.error_external_return();
    cacheFloatEnvironment();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FLOAT-ROUNDING-MODES", Prim_float_rounding_modes, 0, 0, 0)
pub export fn Prim_float_rounding_modes() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const modes: usize =
        (@as(usize, 1) << @intCast(frmode_nearest)) |
        (@as(usize, 1) << @intCast(frmode_toward_zero)) |
        (@as(usize, 1) << @intCast(frmode_downward)) |
        (@as(usize, 1) << @intCast(frmode_upward));
    return artutl.ulong_to_integer(modes);
}

// DEFINE_PRIMITIVE ("GET-FLOAT-ROUNDING-MODE", Prim_get_float_rounding_mode, 0, 0, 0)
pub export fn Prim_get_float_rounding_mode() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const mode = fenv.fegetround();
    if (mode < 0) abi.error_external_return();
    return switch (mode) {
        fenv.fe_tonearest => artutl.ulong_to_integer(frmode_nearest),
        fenv.fe_towardzero => artutl.ulong_to_integer(frmode_toward_zero),
        fenv.fe_downward => artutl.ulong_to_integer(frmode_downward),
        fenv.fe_upward => artutl.ulong_to_integer(frmode_upward),
        else => obj.sharp_f,
    };
}

// DEFINE_PRIMITIVE ("SET-FLOAT-ROUNDING-MODE", Prim_set_float_rounding_mode, 1, 1, 0)
pub export fn Prim_set_float_rounding_mode() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const mode: c_int = switch (abi.arg_ulong_integer(1)) {
        frmode_nearest => fenv.fe_tonearest,
        frmode_toward_zero => fenv.fe_towardzero,
        frmode_downward => fenv.fe_downward,
        frmode_upward => fenv.fe_upward,
        else => abi.error_bad_range_arg(1),
    };
    if (fenv.fesetround(mode) != 0) abi.error_external_return();
    cacheFloatEnvironment();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FLOAT-INVALID-OPERATION-EXCEPTION", Prim_float_invalid_operation_exception, 0, 0, 0)
pub export fn Prim_float_invalid_operation_exception() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_invalid & fenv.fe_all_except);
}

// DEFINE_PRIMITIVE ("FLOAT-DIVIDE-BY-ZERO-EXCEPTION", Prim_float_divide_by_zero_exception, 0, 0, 0)
pub export fn Prim_float_divide_by_zero_exception() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_divbyzero & fenv.fe_all_except);
}

// DEFINE_PRIMITIVE ("FLOAT-OVERFLOW-EXCEPTION", Prim_float_overflow_exception, 0, 0, 0)
pub export fn Prim_float_overflow_exception() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_overflow & fenv.fe_all_except);
}

// DEFINE_PRIMITIVE ("FLOAT-UNDERFLOW-EXCEPTION", Prim_float_underflow_exception, 0, 0, 0)
pub export fn Prim_float_underflow_exception() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_underflow & fenv.fe_all_except);
}

// DEFINE_PRIMITIVE ("FLOAT-INEXACT-RESULT-EXCEPTION", Prim_float_inexact_result_exception, 0, 0, 0)
pub export fn Prim_float_inexact_result_exception() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_inexact & fenv.fe_all_except);
}

// DEFINE_PRIMITIVE ("FLOAT-SUBNORMAL-OPERAND-EXCEPTION", Prim_float_subnormal_operand_exception, 0, 0, 0)
pub export fn Prim_float_subnormal_operand_exception() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (fenv.fe_denormal) |denorm| {
        return exceptionsResult(denorm & fenv.fe_all_except);
    }
    return exceptionsResult(0);
}

// DEFINE_PRIMITIVE ("FLOAT-EXCEPTIONS", Prim_float_exceptions, 0, 0, 0)
pub export fn Prim_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_all_except);
}

// DEFINE_PRIMITIVE ("TRAPPABLE-FLOAT-EXCEPTIONS", Prim_trappable_float_exceptions, 0, 0, 0)
pub export fn Prim_trappable_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fe_all_except & ~non_trappable_exceptions);
}

// DEFINE_PRIMITIVE ("TEST-FLOAT-EXCEPTIONS", Prim_test_float_exceptions, 1, 1, 0)
pub export fn Prim_test_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return exceptionsResult(fenv.fetestexcept(argFloatExceptions(1)));
}

// DEFINE_PRIMITIVE ("CLEAR-FLOAT-EXCEPTIONS", Prim_clear_float_exceptions, 1, 1, 0)
pub export fn Prim_clear_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (fenv.feclearexcept(argFloatExceptions(1)) != 0) abi.error_external_return();
    cacheFloatEnvironment();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("RAISE-FLOAT-EXCEPTIONS", Prim_raise_float_exceptions, 1, 1, 0)
pub export fn Prim_raise_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (fenv.feraiseexcept(argFloatExceptions(1)) != 0) abi.error_external_return();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SAVE-FLOAT-EXCEPTION-FLAGS", Prim_save_float_exception_flags, 1, 1, 0)
pub export fn Prim_save_float_exception_flags() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var flags: fenv.FexceptT = undefined;
    if (fenv.fegetexceptflag(&flags, argFloatExceptions(1)) != 0) abi.error_external_return();
    return allocStructBytes(fenv.FexceptT, &flags);
}

// DEFINE_PRIMITIVE ("TEST-FLOAT-EXCEPTION-FLAGS", Prim_test_float_exception_flags, 2, 2, 0)
pub export fn Prim_test_float_exception_flags() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.error_unimplemented_primitive();
}

// DEFINE_PRIMITIVE ("RESTORE-FLOAT-EXCEPTION-FLAGS", Prim_restore_float_exception_flags, 2, 2, 0)
pub export fn Prim_restore_float_exception_flags() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const flags = argStructBytes(fenv.FexceptT, 1);
    if (fenv.fesetexceptflag(&flags, argFloatExceptions(2)) < 0) abi.error_external_return();
    cacheFloatEnvironment();
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("TRAPPED-FLOAT-EXCEPTIONS", Prim_trapped_float_exceptions, 0, 0, 0)
pub export fn Prim_trapped_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (comptime fenv.have_feexcept_traps) {
        const exceptions = fenv.getExcept();
        if (exceptions < 0) abi.error_external_return();
        return exceptionsResult(exceptions);
    }
    return obj.ulongToFixnum(0);
}

// DEFINE_PRIMITIVE ("SET-TRAPPED-FLOAT-EXCEPTIONS", Prim_set_trapped_float_exceptions, 1, 1, 0)
pub export fn Prim_set_trapped_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (comptime fenv.have_feexcept_traps) {
        const exceptions = argFloatExceptions(1);
        if ((exceptions & non_trappable_exceptions) != 0) abi.error_bad_range_arg(1);
        const previous_exceptions = fenv.enableExcept(exceptions);
        if (previous_exceptions < 0 or fenv.disableExcept(fenv.fe_all_except & ~exceptions) < 0) {
            abi.error_external_return();
        }
        cacheFloatEnvironment();
        return exceptionsResult(previous_exceptions);
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("UNTRAP-FLOAT-EXCEPTIONS", Prim_untrap_float_exceptions, 1, 1, 0)
pub export fn Prim_untrap_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (comptime fenv.have_feexcept_traps) {
        const exceptions = non_trappable_exceptions | argFloatExceptions(1);
        const previous_exceptions = fenv.disableExcept(exceptions);
        if (previous_exceptions < 0) abi.error_external_return();
        cacheFloatEnvironment();
        return exceptionsResult(previous_exceptions);
    }
    abi.error_unimplemented_primitive();
}

// DEFINE_PRIMITIVE ("TRAP-FLOAT-EXCEPTIONS", Prim_trap_float_exceptions, 1, 1, 0)
pub export fn Prim_trap_float_exceptions() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (comptime fenv.have_feexcept_traps) {
        const exceptions = argFloatExceptions(1);
        if ((exceptions & non_trappable_exceptions) != 0) abi.error_bad_range_arg(1);
        const previous_exceptions = fenv.enableExcept(exceptions);
        if (previous_exceptions < 0) abi.error_external_return();
        cacheFloatEnvironment();
        return exceptionsResult(previous_exceptions);
    }
    abi.error_unimplemented_primitive();
}

// DEFINE_PRIMITIVE ("HAVE-FLOAT-ENVIRONMENT?", Prim_have_float_environment, 0, 0, 0)
pub export fn Prim_have_float_environment() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("HAVE-FLOAT-TRAP-ENABLE/DISABLE?", Prim_have_float_trap_enable_disable, 0, 0, 0)
pub export fn Prim_have_float_trap_enable_disable() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (comptime fenv.have_feexcept_traps) {
        const Probe = struct {
            var have: c_int = -1;
        };
        if (Probe.have == -1) {
            var env: fenv.FenvT = undefined;
            const excepts = fenv.getExcept();
            _ = fenv.feholdexcept(&env);
            _ = fenv.enableExcept(fenv.fe_all_except & ~excepts);
            _ = fenv.disableExcept(excepts);
            Probe.have = @intFromBool(fenv.getExcept() != excepts);
            _ = fenv.fesetenv(&env);
        }
        return obj.booleanToObject(Probe.have != 0);
    }
    return obj.sharp_f;
}

test "floenv primitives round mode, exception flags, and environment save/restore" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    var saved: fenv.FenvT = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fenv.fegetenv(&saved));
    defer {
        _ = fenv.fesetenv(&saved);
        scheme_fenv_p = false;
    }

    try std.testing.expectEqual(obj.sharp_t, Prim_have_float_environment());
    try std.testing.expectEqual(obj.longToFixnum(15), Prim_float_rounding_modes());

    const orig_mode = Prim_get_float_rounding_mode();
    stubs.setArgs(&.{obj.ulongToFixnum(frmode_toward_zero)});
    try std.testing.expectEqual(obj.unspecific, Prim_set_float_rounding_mode());
    try std.testing.expectEqual(obj.ulongToFixnum(frmode_toward_zero), Prim_get_float_rounding_mode());
    stubs.setArgs(&.{orig_mode});
    _ = Prim_set_float_rounding_mode();

    // Exception flags clear/raise/test/save/restore
    const inv = Prim_float_invalid_operation_exception();
    const all = Prim_float_exceptions();
    stubs.setArgs(&.{all});
    _ = Prim_clear_float_exceptions();
    stubs.setArgs(&.{all});
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_test_float_exceptions());

    stubs.setArgs(&.{inv});
    _ = Prim_raise_float_exceptions();
    stubs.setArgs(&.{inv});
    try std.testing.expectEqual(inv, Prim_test_float_exceptions());

    stubs.setArgs(&.{all});
    const saved_flags = Prim_save_float_exception_flags();
    stubs.setArgs(&.{all});
    _ = Prim_clear_float_exceptions();
    stubs.setArgs(&.{ saved_flags, inv });
    _ = Prim_restore_float_exception_flags();
    stubs.setArgs(&.{inv});
    try std.testing.expectEqual(inv, Prim_test_float_exceptions());

    const trappable = Prim_trappable_float_exceptions();
    const inexact = Prim_float_inexact_result_exception();
    try std.testing.expectEqual(@as(usize, 0), obj.fixnumToUlong(trappable) & obj.fixnumToUlong(inexact));
}
