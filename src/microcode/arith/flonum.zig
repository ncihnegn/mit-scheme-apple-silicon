// Derived from MIT/GNU Scheme C sources (`src/microcode/flonum.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const artutl = @import("artutl.zig");
const fenv = @import("fenv_plat.zig");

const m_ln2: f64 = 0.693147180559945309417232121458176568;
const m_sqrt1_2: f64 = 0.707106781186547524400844362104849039;

const sign_bit: u64 = 0x8000_0000_0000_0000;
const abs_mask: u64 = 0x7fff_ffff_ffff_ffff;
const exp_mask: u64 = 0x7ff0_0000_0000_0000;
const quiet_bit: u64 = 0x0008_0000_0000_0000;
const sig_mask: u64 = 0x000f_ffff_ffff_ffff;
const payload_mask: u64 = 0x0007_ffff_ffff_ffff;

const fast_fma_p: bool = switch (builtin.cpu.arch) {
    .aarch64 => true,
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    else => false,
};

extern "c" fn fmod(f64, f64) f64;
extern "c" fn fma(f64, f64, f64) f64;
extern "c" fn expm1(f64) f64;
extern "c" fn log1p(f64) f64;
extern "c" fn log(f64) f64;
extern "c" fn log2(f64) f64;
extern "c" fn exp(f64) f64;
extern "c" fn exp2(f64) f64;
extern "c" fn sinh(f64) f64;
extern "c" fn cosh(f64) f64;
extern "c" fn tanh(f64) f64;
extern "c" fn asinh(f64) f64;
extern "c" fn acosh(f64) f64;
extern "c" fn atanh(f64) f64;
extern "c" fn sin(f64) f64;
extern "c" fn cos(f64) f64;
extern "c" fn tan(f64) f64;
extern "c" fn asin(f64) f64;
extern "c" fn acos(f64) f64;
extern "c" fn atan(f64) f64;
extern "c" fn atan2(f64, f64) f64;
extern "c" fn sqrt(f64) f64;
extern "c" fn cbrt(f64) f64;
extern "c" fn hypot(f64, f64) f64;
extern "c" fn pow(f64, f64) f64;
extern "c" fn tgamma(f64) f64;

fn lgammaWithSign(x: f64, signp: *c_int) f64 {
    if (comptime builtin.os.tag == .windows) {
        const WinLgamma = struct {
            extern "c" fn lgamma(f64) f64;
        };
        const res = WinLgamma.lgamma(x);
        const bits: u64 = @bitCast(x);
        if (std.math.isNan(x) or !std.math.isFinite(x)) {
            signp.* = 1;
        } else if (x > 0.0 or bits == 0) {
            signp.* = 1;
        } else if (bits == sign_bit) {
            signp.* = -1;
        } else {
            const ax = -x;
            const fl = @floor(ax);
            if (ax == fl) {
                signp.* = 1;
            } else {
                signp.* = if (@mod(fl, 2.0) == 0.0) -1 else 1;
            }
        }
        return res;
    } else {
        const PosixLgamma = struct {
            extern "c" fn lgamma_r(f64, *c_int) f64;
        };
        return PosixLgamma.lgamma_r(x, signp);
    }
}
extern "c" fn erf(f64) f64;
extern "c" fn erfc(f64) f64;
extern "c" fn j0(f64) f64;
extern "c" fn j1(f64) f64;
extern "c" fn y0(f64) f64;
extern "c" fn y1(f64) f64;
extern "c" fn jn(c_int, f64) f64;
extern "c" fn yn(c_int, f64) f64;
extern "c" fn nextafter(f64, f64) f64;

inline fn fwait() void {
    _ = fenv.feraiseexcept(0);
}

inline fn isNanBits(bits: u64) bool {
    return (bits & exp_mask) == exp_mask and (bits & sig_mask) != 0;
}

inline fn isSnanBits(bits: u64) bool {
    return isNanBits(bits) and (bits & quiet_bit) == 0;
}

pub export fn arg_flonum(arg_number: c_int) callconv(.c) f64 {
    const argument = abi.argRef(@intCast(arg_number));
    if (!obj.flonumP(argument)) abi.error_wrong_type_arg(arg_number);
    return obj.flonumToDouble(argument);
}

pub export fn arg_flonum_binary64(arg_number: c_int) callconv(.c) u64 {
    const argument = abi.argRef(@intCast(arg_number));
    if (!obj.flonumP(argument)) abi.error_wrong_type_arg(arg_number);
    const ptr: *const u64 = @ptrCast(@alignCast(obj.memoryLoc(argument, 1)));
    return ptr.*;
}

pub export fn double_to_flonum(value: f64) callconv(.c) obj.SchemeObject {
    return binary64_to_flonum(@bitCast(value));
}

pub export fn binary64_to_flonum(value: u64) callconv(.c) obj.SchemeObject {
    obj.alignFloat(&abi.Free);
    abi.primitiveGcIfNeeded(obj.flonum_size + 1);
    const result = obj.makePointerObject(obj.tc_big_flonum, abi.Free);
    abi.Free[0] = obj.makeNmvHeader(obj.flonum_size);
    abi.Free += 1;
    const ptr: *u64 = @ptrCast(@alignCast(abi.Free));
    ptr.* = value;
    abi.Free += @as(usize, @intCast(obj.flonum_size));
    return result;
}

inline fn simpleTranscendental(comptime func: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    const result = func(arg_flonum(1));
    fwait();
    return double_to_flonum(result);
}

inline fn orderedBinary(comptime cmpFn: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    const xb = arg_flonum_binary64(1);
    const yb = arg_flonum_binary64(2);
    if (isNanBits(xb) or isNanBits(yb)) {
        _ = fenv.feraiseexcept(fenv.fe_invalid);
        return obj.sharp_f;
    }
    return obj.booleanToObject(cmpFn(@as(f64, @bitCast(xb)), @as(f64, @bitCast(yb))));
}

inline fn orderedUnary(comptime cmpFn: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    const xb = arg_flonum_binary64(1);
    if (isNanBits(xb)) {
        _ = fenv.feraiseexcept(fenv.fe_invalid);
        return obj.sharp_f;
    }
    return obj.booleanToObject(cmpFn(@as(f64, @bitCast(xb)), 0.0));
}

inline fn quietBinary(comptime unordered_res: bool, comptime cmpFn: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    const xb = arg_flonum_binary64(1);
    const yb = arg_flonum_binary64(2);
    if (isSnanBits(xb) or isSnanBits(yb)) {
        _ = fenv.feraiseexcept(fenv.fe_invalid);
    }
    if (isNanBits(xb) or isNanBits(yb)) {
        return obj.booleanToObject(unordered_res);
    }
    return obj.booleanToObject(cmpFn(@as(f64, @bitCast(xb)), @as(f64, @bitCast(yb))));
}

inline fn cmpEq(x: f64, y: f64) bool {
    return x == y;
}
inline fn cmpLt(x: f64, y: f64) bool {
    return x < y;
}
inline fn cmpLe(x: f64, y: f64) bool {
    return x <= y;
}
inline fn cmpGt(x: f64, y: f64) bool {
    return x > y;
}
inline fn cmpGe(x: f64, y: f64) bool {
    return x >= y;
}
inline fn cmpNe(x: f64, y: f64) bool {
    return x != y;
}

inline fn flonumConversion(comptime converter: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.flonumP);
    const arg = abi.argRef(1);
    return if (artutl.flonum_is_finite_p(arg)) converter(arg) else arg;
}

inline fn flonumExactConversion(comptime converter: anytype) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, artutl.finite_flonum_p);
    return artutl.double_to_integer(obj.flonumToDouble(converter(abi.argRef(1))));
}

// DEFINE_PRIMITIVE ("FLONUM-ADD", Prim_flonum_add, 2, 2, 0)
pub export fn Prim_flonum_add() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(arg_flonum(1) + arg_flonum(2));
}

// DEFINE_PRIMITIVE ("FLONUM-SUBTRACT", Prim_flonum_subtract, 2, 2, 0)
pub export fn Prim_flonum_subtract() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(arg_flonum(1) - arg_flonum(2));
}

// DEFINE_PRIMITIVE ("FLONUM-MULTIPLY", Prim_flonum_multiply, 2, 2, 0)
pub export fn Prim_flonum_multiply() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(arg_flonum(1) * arg_flonum(2));
}

// DEFINE_PRIMITIVE ("FLONUM-DIVIDE", Prim_flonum_divide, 2, 2, 0)
pub export fn Prim_flonum_divide() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(arg_flonum(1) / arg_flonum(2));
}

// DEFINE_PRIMITIVE ("FLONUM-MODULO", Prim_flonum_modulo, 2, 2, 0)
pub export fn Prim_flonum_modulo() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const denominator = arg_flonum(2);
    if (denominator == 0.0) abi.error_bad_range_arg(2);
    return double_to_flonum(fmod(arg_flonum(1), denominator));
}

// DEFINE_PRIMITIVE ("FLONUM-NEGATE", Prim_flonum_negate, 1, 1, 0)
pub export fn Prim_flonum_negate() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return binary64_to_flonum(sign_bit ^ arg_flonum_binary64(1));
}

// DEFINE_PRIMITIVE ("FLONUM-ABS", Prim_flonum_abs, 1, 1, 0)
pub export fn Prim_flonum_abs() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return binary64_to_flonum(abs_mask & arg_flonum_binary64(1));
}

// DEFINE_PRIMITIVE ("FLONUM-FMA", Prim_flonum_fma, 3, 3, 0)
pub export fn Prim_flonum_fma() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(fma(arg_flonum(1), arg_flonum(2), arg_flonum(3)));
}

// DEFINE_PRIMITIVE ("FLONUM-FAST-FMA?", Prim_flonum_fast_fma_p, 0, 0, 0)
pub export fn Prim_flonum_fast_fma_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(fast_fma_p);
}

// DEFINE_PRIMITIVE ("FLONUM-EQUAL?", Prim_flonum_equal_p, 2, 2, 0)
pub export fn Prim_flonum_equal_p() callconv(.c) obj.SchemeObject {
    return orderedBinary(cmpEq);
}

// DEFINE_PRIMITIVE ("FLONUM-LESS?", Prim_flonum_less_p, 2, 2, 0)
pub export fn Prim_flonum_less_p() callconv(.c) obj.SchemeObject {
    return orderedBinary(cmpLt);
}

// DEFINE_PRIMITIVE ("FLONUM-GREATER?", Prim_flonum_greater_p, 2, 2, 0)
pub export fn Prim_flonum_greater_p() callconv(.c) obj.SchemeObject {
    return orderedBinary(cmpGt);
}

// DEFINE_PRIMITIVE ("FLONUM-ZERO?", Prim_flonum_zero_p, 1, 1, 0)
pub export fn Prim_flonum_zero_p() callconv(.c) obj.SchemeObject {
    return orderedUnary(cmpEq);
}

// DEFINE_PRIMITIVE ("FLONUM-POSITIVE?", Prim_flonum_positive_p, 1, 1, 0)
pub export fn Prim_flonum_positive_p() callconv(.c) obj.SchemeObject {
    return orderedUnary(cmpGt);
}

// DEFINE_PRIMITIVE ("FLONUM-NEGATIVE?", Prim_flonum_negative_p, 1, 1, 0)
pub export fn Prim_flonum_negative_p() callconv(.c) obj.SchemeObject {
    return orderedUnary(cmpLt);
}

// DEFINE_PRIMITIVE ("FLONUM-EXPM1", Prim_flonum_expm1, 1, 1, 0)
pub export fn Prim_flonum_expm1() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = arg_flonum(1);
    if (!(x >= -m_ln2 and x <= m_ln2)) abi.error_bad_range_arg(1);
    return double_to_flonum(expm1(x));
}

// DEFINE_PRIMITIVE ("FLONUM-LOG1P", Prim_flonum_log1p, 1, 1, 0)
pub export fn Prim_flonum_log1p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const x = arg_flonum(1);
    if (!(x >= (m_sqrt1_2 - 1.0) and x <= (1.0 - m_sqrt1_2))) abi.error_bad_range_arg(1);
    return double_to_flonum(log1p(x));
}

// DEFINE_PRIMITIVE ("FLONUM-LOG", Prim_flonum_log, 1, 1, 0)
pub export fn Prim_flonum_log() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(log);
}

// DEFINE_PRIMITIVE ("FLONUM-LOG2", Prim_flonum_log2, 1, 1, 0)
pub export fn Prim_flonum_log2() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(log2);
}

// DEFINE_PRIMITIVE ("FLONUM-EXP", Prim_flonum_exp, 1, 1, 0)
pub export fn Prim_flonum_exp() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(exp);
}

// DEFINE_PRIMITIVE ("FLONUM-EXP2", Prim_flonum_exp2, 1, 1, 0)
pub export fn Prim_flonum_exp2() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(exp2);
}

// DEFINE_PRIMITIVE ("FLONUM-SINH", Prim_flonum_sinh, 1, 1, 0)
pub export fn Prim_flonum_sinh() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(sinh);
}

// DEFINE_PRIMITIVE ("FLONUM-COSH", Prim_flonum_cosh, 1, 1, 0)
pub export fn Prim_flonum_cosh() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(cosh);
}

// DEFINE_PRIMITIVE ("FLONUM-TANH", Prim_flonum_tanh, 1, 1, 0)
pub export fn Prim_flonum_tanh() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(tanh);
}

// DEFINE_PRIMITIVE ("FLONUM-ASINH", Prim_flonum_asinh, 1, 1, 0)
pub export fn Prim_flonum_asinh() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(asinh);
}

// DEFINE_PRIMITIVE ("FLONUM-ACOSH", Prim_flonum_acosh, 1, 1, 0)
pub export fn Prim_flonum_acosh() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(acosh);
}

// DEFINE_PRIMITIVE ("FLONUM-ATANH", Prim_flonum_atanh, 1, 1, 0)
pub export fn Prim_flonum_atanh() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(atanh);
}

// DEFINE_PRIMITIVE ("FLONUM-SIN", Prim_flonum_sin, 1, 1, 0)
pub export fn Prim_flonum_sin() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(sin);
}

// DEFINE_PRIMITIVE ("FLONUM-COS", Prim_flonum_cos, 1, 1, 0)
pub export fn Prim_flonum_cos() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(cos);
}

// DEFINE_PRIMITIVE ("FLONUM-TAN", Prim_flonum_tan, 1, 1, 0)
pub export fn Prim_flonum_tan() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(tan);
}

// DEFINE_PRIMITIVE ("FLONUM-ASIN", Prim_flonum_asin, 1, 1, 0)
pub export fn Prim_flonum_asin() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(asin);
}

// DEFINE_PRIMITIVE ("FLONUM-ACOS", Prim_flonum_acos, 1, 1, 0)
pub export fn Prim_flonum_acos() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(acos);
}

// DEFINE_PRIMITIVE ("FLONUM-ATAN", Prim_flonum_atan, 1, 1, 0)
pub export fn Prim_flonum_atan() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(atan);
}

// DEFINE_PRIMITIVE ("FLONUM-ATAN2", Prim_flonum_atan2, 2, 2, 0)
pub export fn Prim_flonum_atan2() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const y = arg_flonum(1);
    const x = arg_flonum(2);
    return double_to_flonum(atan2(y, x));
}

// DEFINE_PRIMITIVE ("FLONUM-SQRT", Prim_flonum_sqrt, 1, 1, 0)
pub export fn Prim_flonum_sqrt() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(sqrt);
}

// DEFINE_PRIMITIVE ("FLONUM-CBRT", Prim_flonum_cbrt, 1, 1, 0)
pub export fn Prim_flonum_cbrt() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(cbrt);
}

// DEFINE_PRIMITIVE ("FLONUM-HYPOT", Prim_flonum_hypot, 2, 2, 0)
pub export fn Prim_flonum_hypot() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(hypot(arg_flonum(1), arg_flonum(2)));
}

// DEFINE_PRIMITIVE ("FLONUM-EXPT", Prim_flonum_expt, 2, 2, 0)
pub export fn Prim_flonum_expt() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(pow(arg_flonum(1), arg_flonum(2)));
}

// DEFINE_PRIMITIVE ("FLONUM-LGAMMA", Prim_flonum_lgamma, 1, 1, 0)
pub export fn Prim_flonum_lgamma() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var sign: c_int = undefined;
    return double_to_flonum(lgammaWithSign(arg_flonum(1), &sign));
}

// DEFINE_PRIMITIVE ("FLONUM-SIGNED-LGAMMA", Prim_flonum_signed_lgamma, 1, 1, 0)
pub export fn Prim_flonum_signed_lgamma() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var sign: c_int = undefined;
    const result = lgammaWithSign(arg_flonum(1), &sign);
    std.debug.assert(obj.longToFixnumP(@as(isize, sign)));
    return abi.cons(double_to_flonum(result), obj.longToFixnum(@as(isize, sign)));
}

// DEFINE_PRIMITIVE ("FLONUM-GAMMA", Prim_flonum_gamma, 1, 1, 0)
pub export fn Prim_flonum_gamma() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(tgamma);
}

// DEFINE_PRIMITIVE ("FLONUM-ERF", Prim_flonum_erf, 1, 1, 0)
pub export fn Prim_flonum_erf() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(erf);
}

// DEFINE_PRIMITIVE ("FLONUM-ERFC", Prim_flonum_erfc, 1, 1, 0)
pub export fn Prim_flonum_erfc() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(erfc);
}

// DEFINE_PRIMITIVE ("FLONUM-J0", Prim_flonum_j0, 1, 1, 0)
pub export fn Prim_flonum_j0() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(j0);
}

// DEFINE_PRIMITIVE ("FLONUM-J1", Prim_flonum_j1, 1, 1, 0)
pub export fn Prim_flonum_j1() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(j1);
}

// DEFINE_PRIMITIVE ("FLONUM-Y0", Prim_flonum_y0, 1, 1, 0)
pub export fn Prim_flonum_y0() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(y0);
}

// DEFINE_PRIMITIVE ("FLONUM-Y1", Prim_flonum_y1, 1, 1, 0)
pub export fn Prim_flonum_y1() callconv(.c) obj.SchemeObject {
    return simpleTranscendental(y1);
}

// DEFINE_PRIMITIVE ("FLONUM-JN", Prim_flonum_jn, 2, 2, 0)
pub export fn Prim_flonum_jn() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n: c_int = @intCast(abi.arg_integer_in_range(1, std.math.minInt(c_int), std.math.maxInt(c_int)));
    const x = arg_flonum(2);
    return double_to_flonum(jn(n, x));
}

// DEFINE_PRIMITIVE ("FLONUM-YN", Prim_flonum_yn, 2, 2, 0)
pub export fn Prim_flonum_yn() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const n: c_int = @intCast(abi.arg_integer_in_range(1, std.math.minInt(c_int), std.math.maxInt(c_int)));
    const x = arg_flonum(2);
    return double_to_flonum(yn(n, x));
}

// DEFINE_PRIMITIVE ("FLONUM?", Prim_flonum_p, 1, 1, 0)
pub export fn Prim_flonum_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.flonumP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("FLONUM-INTEGER?", Prim_flonum_integer_p, 1, 1, 0)
pub export fn Prim_flonum_integer_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.flonumP);
    const arg = abi.argRef(1);
    return if (artutl.flonum_is_finite_p(arg))
        obj.booleanToObject(artutl.flonum_integer_p(arg))
    else
        obj.sharp_f;
}

fn flonumTruncate(arg: obj.SchemeObject) obj.SchemeObject {
    return double_to_flonum(artutl.double_truncate(obj.flonumToDouble(arg)));
}

// DEFINE_PRIMITIVE ("FLONUM-FLOOR", Prim_flonum_floor, 1, 1, 0)
pub export fn Prim_flonum_floor() callconv(.c) obj.SchemeObject {
    return flonumConversion(artutl.flonum_floor);
}

// DEFINE_PRIMITIVE ("FLONUM-CEILING", Prim_flonum_ceiling, 1, 1, 0)
pub export fn Prim_flonum_ceiling() callconv(.c) obj.SchemeObject {
    return flonumConversion(artutl.flonum_ceiling);
}

// DEFINE_PRIMITIVE ("FLONUM-TRUNCATE", Prim_flonum_truncate, 1, 1, 0)
pub export fn Prim_flonum_truncate() callconv(.c) obj.SchemeObject {
    return flonumConversion(flonumTruncate);
}

// DEFINE_PRIMITIVE ("FLONUM-ROUND", Prim_flonum_round, 1, 1, 0)
pub export fn Prim_flonum_round() callconv(.c) obj.SchemeObject {
    return flonumConversion(artutl.flonum_round);
}

// DEFINE_PRIMITIVE ("FLONUM-TRUNCATE->EXACT", Prim_flonum_truncate_to_exact, 1, 1, 0)
pub export fn Prim_flonum_truncate_to_exact() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, artutl.finite_flonum_p);
    return artutl.double_to_integer(obj.flonumToDouble(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("FLONUM-FLOOR->EXACT", Prim_flonum_floor_to_exact, 1, 1, 0)
pub export fn Prim_flonum_floor_to_exact() callconv(.c) obj.SchemeObject {
    return flonumExactConversion(artutl.flonum_floor);
}

// DEFINE_PRIMITIVE ("FLONUM-CEILING->EXACT", Prim_flonum_ceiling_to_exact, 1, 1, 0)
pub export fn Prim_flonum_ceiling_to_exact() callconv(.c) obj.SchemeObject {
    return flonumExactConversion(artutl.flonum_ceiling);
}

// DEFINE_PRIMITIVE ("FLONUM-ROUND->EXACT", Prim_flonum_round_to_exact, 1, 1, 0)
pub export fn Prim_flonum_round_to_exact() callconv(.c) obj.SchemeObject {
    return flonumExactConversion(artutl.flonum_round);
}

// DEFINE_PRIMITIVE ("FLONUM-NORMALIZE", Prim_flonum_normalize, 1, 1, 0)
pub export fn Prim_flonum_normalize() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, artutl.finite_flonum_p);
    return artutl.flonum_normalize(abi.argRef(1));
}

// DEFINE_PRIMITIVE ("FLONUM-DENORMALIZE", Prim_flonum_denormalize, 2, 2, 0)
pub export fn Prim_flonum_denormalize() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, artutl.finite_flonum_p);
    abi.checkArg(2, obj.integerP);
    return artutl.flonum_denormalize(abi.argRef(1), abi.argRef(2));
}

// DEFINE_PRIMITIVE ("CAST-IEEE754-DOUBLE-TO-INTEGER", Prim_cast_ieee754_double_to_integer, 1, 1, 0)
pub export fn Prim_cast_ieee754_double_to_integer() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.uintmax_to_integer(arg_flonum_binary64(1));
}

// DEFINE_PRIMITIVE ("CAST-INTEGER-TO-IEEE754-DOUBLE", Prim_cast_integer_to_ieee754_double, 1, 1, 0)
pub export fn Prim_cast_integer_to_ieee754_double() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    return binary64_to_flonum(artutl.integer_to_uintmax(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("CAST-IEEE754-SINGLE-TO-INTEGER", Prim_cast_ieee754_single_to_integer, 1, 1, 0)
pub export fn Prim_cast_ieee754_single_to_integer() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const f: f32 = @floatCast(arg_flonum(1));
    const bits: u32 = @bitCast(f);
    return artutl.uintmax_to_integer(bits);
}

// DEFINE_PRIMITIVE ("CAST-INTEGER-TO-IEEE754-SINGLE", Prim_cast_integer_to_ieee754_single, 1, 1, 0)
pub export fn Prim_cast_integer_to_ieee754_single() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.integerP);
    const bits: u32 = @truncate(artutl.integer_to_uintmax(abi.argRef(1)));
    const f: f32 = @bitCast(bits);
    return double_to_flonum(@floatCast(f));
}

// IEEE 754 quiet predicates (pure bit-pattern inspection for unary, zero FP instructions on NaNs)

// DEFINE_PRIMITIVE ("FLONUM-IS-FINITE?", Prim_flonum_is_finite_p, 1, 1, 0)
pub export fn Prim_flonum_is_finite_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject((arg_flonum_binary64(1) & exp_mask) != exp_mask);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-INFINITE?", Prim_flonum_is_infinite_p, 1, 1, 0)
pub export fn Prim_flonum_is_infinite_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject((arg_flonum_binary64(1) & abs_mask) == exp_mask);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-NAN?", Prim_flonum_is_nan_p, 1, 1, 0)
pub export fn Prim_flonum_is_nan_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(isNanBits(arg_flonum_binary64(1)));
}

// DEFINE_PRIMITIVE ("FLONUM-IS-NORMAL?", Prim_flonum_is_normal_p, 1, 1, 0)
pub export fn Prim_flonum_is_normal_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const e = arg_flonum_binary64(1) & exp_mask;
    return obj.booleanToObject(e != 0 and e != exp_mask);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-NEGATIVE?", Prim_flonum_is_negative_p, 1, 1, 0)
pub export fn Prim_flonum_is_negative_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject((arg_flonum_binary64(1) & sign_bit) != 0);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-GREATER?", Prim_flonum_is_greater_p, 2, 2, 0)
pub export fn Prim_flonum_is_greater_p() callconv(.c) obj.SchemeObject {
    return quietBinary(false, cmpGt);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-GREATER-OR-EQUAL?", Prim_flonum_is_greater_or_equal_p, 2, 2, 0)
pub export fn Prim_flonum_is_greater_or_equal_p() callconv(.c) obj.SchemeObject {
    return quietBinary(false, cmpGe);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-LESS-OR-EQUAL?", Prim_flonum_is_less_or_equal_p, 2, 2, 0)
pub export fn Prim_flonum_is_less_or_equal_p() callconv(.c) obj.SchemeObject {
    return quietBinary(false, cmpLe);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-LESS?", Prim_flonum_is_less_p, 2, 2, 0)
pub export fn Prim_flonum_is_less_p() callconv(.c) obj.SchemeObject {
    return quietBinary(false, cmpLt);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-LESS-OR-GREATER?", Prim_flonum_is_less_or_greater_p, 2, 2, 0)
pub export fn Prim_flonum_is_less_or_greater_p() callconv(.c) obj.SchemeObject {
    return quietBinary(false, cmpNe);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-UNORDERED?", Prim_flonum_is_unordered_p, 2, 2, 0)
pub export fn Prim_flonum_is_unordered_p() callconv(.c) obj.SchemeObject {
    return quietBinary(true, struct {
        inline fn orderedFalse(_: f64, _: f64) bool {
            return false;
        }
    }.orderedFalse);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-EQUAL?", Prim_flonum_is_equal_p, 2, 2, 0)
pub export fn Prim_flonum_is_equal_p() callconv(.c) obj.SchemeObject {
    return quietBinary(false, cmpEq);
}

// DEFINE_PRIMITIVE ("FLONUM-IS-ZERO?", Prim_flonum_is_zero_p, 1, 1, 0)
pub export fn Prim_flonum_is_zero_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject((arg_flonum_binary64(1) & abs_mask) == 0);
}

// NaN utilities

// DEFINE_PRIMITIVE ("FLONUM-MAKE-NAN", Prim_flonum_make_nan, 3, 3, 0)
pub export fn Prim_flonum_make_nan() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const sign: u64 = @intFromBool(obj.objectToBoolean(abi.argRef(1)));
    const quiet: u64 = @intFromBool(obj.objectToBoolean(abi.argRef(2)));
    const payload: u64 = @intCast(abi.arg_index_integer_to_intmax(3, @as(i64, 1) << 51));
    if (quiet == 0 and payload == 0) abi.error_bad_range_arg(3);
    const bits: u64 = (sign << 63) | exp_mask | (quiet << 51) | payload;
    return binary64_to_flonum(bits);
}

// DEFINE_PRIMITIVE ("FLONUM-NAN-QUIET?", Prim_flonum_nan_quiet_p, 1, 1, 0)
pub export fn Prim_flonum_nan_quiet_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const bits = arg_flonum_binary64(1);
    if ((bits & exp_mask) != exp_mask) abi.error_bad_range_arg(1);
    return obj.booleanToObject((bits & quiet_bit) != 0);
}

// DEFINE_PRIMITIVE ("FLONUM-NAN-PAYLOAD", Prim_flonum_nan_payload, 1, 1, 0)
pub export fn Prim_flonum_nan_payload() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const bits = arg_flonum_binary64(1);
    if ((bits & exp_mask) != exp_mask) abi.error_bad_range_arg(1);
    return artutl.uintmax_to_integer(bits & payload_mask);
}

// Miscellaneous floating-point operations

// DEFINE_PRIMITIVE ("FLONUM-COPYSIGN", Prim_flonum_copysign, 2, 2, 0)
pub export fn Prim_flonum_copysign() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const magnitude = arg_flonum_binary64(1);
    const sign = arg_flonum_binary64(2);
    return binary64_to_flonum((magnitude & abs_mask) | (sign & sign_bit));
}

// DEFINE_PRIMITIVE ("FLONUM-NEXTAFTER", Prim_flonum_nextafter, 2, 2, 0)
pub export fn Prim_flonum_nextafter() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return double_to_flonum(nextafter(arg_flonum(1), arg_flonum(2)));
}

test "flonum binary64 casts, NaN constructors/predicates, quiet vs ordered exceptions" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();

    var saved: fenv.FenvT = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fenv.fegetenv(&saved));
    defer _ = fenv.fesetenv(&saved);

    // binary64 round trip & copysign/negate/abs on -0.0
    const neg_zero = binary64_to_flonum(sign_bit);
    stubs.setArgs(&.{neg_zero});
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_is_negative_p());
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_is_zero_p());
    try std.testing.expectEqual(sign_bit, artutl.integer_to_uintmax(Prim_cast_ieee754_double_to_integer()));

    stubs.setArgs(&.{neg_zero});
    const pos_zero = Prim_flonum_abs();
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(obj.flonumToDouble(pos_zero))));

    stubs.setArgs(&.{pos_zero});
    const negated = Prim_flonum_negate();
    try std.testing.expectEqual(sign_bit, @as(u64, @bitCast(obj.flonumToDouble(negated))));

    const one = double_to_flonum(1.0);
    stubs.setArgs(&.{ one, neg_zero });
    try std.testing.expectEqual(@as(f64, -1.0), obj.flonumToDouble(Prim_flonum_copysign()));

    // NaN construction, payload, and quiet/ordered FE_INVALID separation
    stubs.setArgs(&.{ obj.sharp_t, obj.sharp_t, obj.longToFixnum(0x1234) });
    const qnan = Prim_flonum_make_nan();
    stubs.setArgs(&.{qnan});
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_is_nan_p());
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_is_negative_p());
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_nan_quiet_p());
    try std.testing.expectEqual(obj.longToFixnum(0x1234), Prim_flonum_nan_payload());

    stubs.setArgs(&.{ obj.sharp_f, obj.sharp_f, obj.longToFixnum(0x55) });
    const snan = Prim_flonum_make_nan();
    stubs.setArgs(&.{snan});
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_is_nan_p());
    try std.testing.expectEqual(obj.sharp_f, Prim_flonum_nan_quiet_p());
    try std.testing.expectEqual(obj.longToFixnum(0x55), Prim_flonum_nan_payload());

    // Quiet predicate on qNaN must NOT raise FE_INVALID
    _ = fenv.feclearexcept(fenv.fe_all_except);
    stubs.setArgs(&.{ qnan, one });
    try std.testing.expectEqual(obj.sharp_f, Prim_flonum_is_less_p());
    try std.testing.expectEqual(obj.sharp_t, Prim_flonum_is_unordered_p());
    try std.testing.expectEqual(@as(c_int, 0), fenv.fetestexcept(fenv.fe_invalid));

    // Ordered predicate on qNaN MUST raise FE_INVALID
    stubs.setArgs(&.{ qnan, one });
    try std.testing.expectEqual(obj.sharp_f, Prim_flonum_less_p());
    try std.testing.expectEqual(fenv.fe_invalid, fenv.fetestexcept(fenv.fe_invalid));

    // Quiet predicate on sNaN MUST raise FE_INVALID
    _ = fenv.feclearexcept(fenv.fe_all_except);
    stubs.setArgs(&.{ snan, one });
    try std.testing.expectEqual(obj.sharp_f, Prim_flonum_is_equal_p());
    try std.testing.expectEqual(fenv.fe_invalid, fenv.fetestexcept(fenv.fe_invalid));

    // Signed lgamma(-1.5) = (log|Gamma(-1.5)| . +1)
    stubs.setArgs(&.{double_to_flonum(-1.5)});
    const lg = Prim_flonum_signed_lgamma();
    try std.testing.expect(obj.pairCar(lg) != obj.sharp_f);
    try std.testing.expectEqual(obj.longToFixnum(1), obj.pairCdr(lg));

    // Rounding primitives on NaN preserve argument
    stubs.setArgs(&.{qnan});
    try std.testing.expectEqual(qnan, Prim_flonum_truncate());
    try std.testing.expectEqual(qnan, Prim_flonum_floor());
    try std.testing.expectEqual(qnan, Prim_flonum_ceiling());
    try std.testing.expectEqual(qnan, Prim_flonum_round());
    try std.testing.expectEqual(obj.sharp_f, Prim_flonum_integer_p());
}
