// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxffi.c`, `src/microcode/pruxffi.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const outf = @import("../support/outf.zig");
const boot = @import("../core/boot.zig");
const utils = @import("../core/utils.zig");
const artutl = @import("../arith/artutl.zig");
const string = @import("../data/string.zig");
const primutl = @import("../runtime/primutl.zig");
const fenv_plat = @import("../arith/fenv_plat.zig");

pub const SCM = obj.SchemeObject;
pub const CalloutTrampOut = *const fn () callconv(.c) SCM;
pub const CalloutTrampIn = *const fn () callconv(.c) SCM;
pub const CallbackKernel = *const fn () callconv(.c) void;

fn copyCStringZ(dst: [*]u8, src: [*]const u8, n: usize) void {
    const src_slice = src[0..n];
    const len = std.mem.indexOfScalar(u8, src_slice, 0) orelse n;
    @memcpy(dst[0..len], src_slice[0..len]);
    @memset(dst[len..n], 0);
}

const CChar = if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) u8 else i8;

const half_word_shift: std.math.Log2Int(usize) = (@sizeOf(?*anyopaque) * 8) / 2;
const half_word_mask: usize = (@as(usize, 1) << half_word_shift) - 1;
const ustring_flags_all: usize = 0x7;

pub export var cstack_depth: c_int = 0;
var c_call_continue: SCM = obj.sharp_f;
var run_callback: SCM = obj.sharp_f;

fn argRecord(argument_number: c_int) SCM {
    const val = abi.argRef(@intCast(argument_number));
    if (!obj.recordP(val)) {
        abi.error_wrong_type_arg(argument_number);
    }
    return val;
}

fn unsignedFixnumArg(arg: c_int) usize {
    const val = abi.argRef(@intCast(arg));
    if (!obj.fixnumP(val)) {
        abi.error_wrong_type_arg(arg);
    }
    return obj.fixnumToUlong(val);
}

fn alienAddressLoc() [*]u8 {
    return @ptrFromInt(@intFromPtr(arg_address(1)) +% @as(usize, @intCast(unsignedFixnumArg(2))));
}

fn readUnaligned(comptime T: type, ptr: [*]const u8) T {
    const p: *align(1) const T = @ptrCast(ptr);
    return p.*;
}

fn writeUnaligned(comptime T: type, ptr: [*]u8, val: T) void {
    const p: *align(1) T = @ptrCast(ptr);
    p.* = val;
}

fn truncateFromArgInt(comptime T: type, n: c_int) T {
    const bits: u64 = @bitCast(@as(i64, abi.arg_integer(n)));
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            const U = @Int(.unsigned, info.bits);
            const uval: U = @truncate(bits);
            break :blk @bitCast(uval);
        },
        else => @compileError("expected integer type"),
    };
}

inline fn cPeeker(comptime T: type, comptime conv: fn (T) SCM) SCM {
    abi.primitiveHeader();
    return conv(readUnaligned(T, alienAddressLoc()));
}

inline fn cPoker(comptime T: type, val: T) SCM {
    abi.primitiveHeader();
    writeUnaligned(T, alienAddressLoc(), val);
    return obj.unspecific;
}

fn peekCharConv(v: CChar) SCM {
    return obj.longToFixnum(@as(isize, v));
}

fn peekUCharConv(v: u8) SCM {
    return obj.longToFixnum(@as(isize, v));
}

fn peekShortConv(v: c_short) SCM {
    return obj.longToFixnum(@as(isize, v));
}

fn peekUShortConv(v: c_ushort) SCM {
    return obj.longToFixnum(@as(isize, v));
}

fn peekIntConv(v: c_int) SCM {
    return abi.long_to_integer(@as(isize, v));
}

fn peekUIntConv(v: c_uint) SCM {
    return abi.ulong_to_integer(@as(usize, v));
}

fn peekLongConv(v: isize) SCM {
    return abi.long_to_integer(v);
}

fn peekULongConv(v: usize) SCM {
    return abi.ulong_to_integer(v);
}

fn peekFloatConv(v: f32) SCM {
    return abi.double_to_flonum(@floatCast(v));
}

fn peekDoubleConv(v: f64) SCM {
    return abi.double_to_flonum(v);
}

// Alien Addresses

pub export fn is_alien(alien: SCM) callconv(.c) c_int {
    if (obj.recordP(alien) and obj.vectorLength(alien) == 4) {
        const high = obj.vectorRef(alien, 1);
        const low = obj.vectorRef(alien, 2);
        if (obj.unsignedFixnumP(high) and obj.unsignedFixnumP(low)) {
            return 1;
        }
    }
    return 0;
}

pub export fn alien_address(alien: SCM) callconv(.c) ?*anyopaque {
    const high = obj.fixnumToUlong(obj.vectorRef(alien, 1));
    const low = obj.fixnumToUlong(obj.vectorRef(alien, 2));
    return @ptrFromInt(@as(usize, @intCast((high << half_word_shift) + low)));
}

pub export fn set_alien_address(alien: SCM, ptr: ?*const anyopaque) callconv(.c) void {
    const addr: usize = @intCast(@intFromPtr(ptr));
    obj.vectorSet(alien, 1, obj.ulongToFixnum(addr >> half_word_shift));
    obj.vectorSet(alien, 2, obj.ulongToFixnum(addr & half_word_mask));
}

pub export fn arg_alien(argn: c_int) callconv(.c) SCM {
    const alien = abi.argRef(@intCast(argn));
    if (is_alien(alien) != 0) {
        return alien;
    }
    abi.error_wrong_type_arg(argn);
}

pub export fn arg_address(argn: c_int) callconv(.c) ?*anyopaque {
    const alien = abi.argRef(@intCast(argn));
    if (is_alien(alien) != 0) {
        return alien_address(alien);
    }
    abi.error_wrong_type_arg(argn);
}

// Peek the Basic Types

// DEFINE_PRIMITIVE ("C-PEEK-CHAR", Prim_peek_char, 2, 2, 0)
pub export fn Prim_peek_char() callconv(.c) SCM {
    return cPeeker(CChar, peekCharConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-UCHAR", Prim_peek_uchar, 2, 2, 0)
pub export fn Prim_peek_uchar() callconv(.c) SCM {
    return cPeeker(u8, peekUCharConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-SHORT", Prim_peek_short, 2, 2, 0)
pub export fn Prim_peek_short() callconv(.c) SCM {
    return cPeeker(c_short, peekShortConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-USHORT", Prim_peek_ushort, 2, 2, 0)
pub export fn Prim_peek_ushort() callconv(.c) SCM {
    return cPeeker(c_ushort, peekUShortConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-INT", Prim_peek_int, 2, 2, 0)
pub export fn Prim_peek_int() callconv(.c) SCM {
    return cPeeker(c_int, peekIntConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-UINT", Prim_peek_uint, 2, 2, 0)
pub export fn Prim_peek_uint() callconv(.c) SCM {
    return cPeeker(c_uint, peekUIntConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-LONG", Prim_peek_long, 2, 2, 0)
pub export fn Prim_peek_long() callconv(.c) SCM {
    return cPeeker(isize, peekLongConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-ULONG", Prim_peek_ulong, 2, 2, 0)
pub export fn Prim_peek_ulong() callconv(.c) SCM {
    return cPeeker(usize, peekULongConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-FLOAT", Prim_peek_float, 2, 2, 0)
pub export fn Prim_peek_float() callconv(.c) SCM {
    return cPeeker(f32, peekFloatConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-DOUBLE", Prim_peek_double, 2, 2, 0)
pub export fn Prim_peek_double() callconv(.c) SCM {
    return cPeeker(f64, peekDoubleConv);
}

// DEFINE_PRIMITIVE ("C-PEEK-POINTER", Prim_peek_pointer, 3, 3, 0)
pub export fn Prim_peek_pointer() callconv(.c) SCM {
    abi.primitiveHeader();
    const alien = argRecord(3);
    set_alien_address(alien, readUnaligned(?*const anyopaque, alienAddressLoc()));
    return alien;
}

pub export fn bytes_to_ustring(bytes: [*]u8, n_bytes: c_int) callconv(.c) SCM {
    const n: usize = @intCast(n_bytes);
    const result = abi.allocate_non_marked_vector(
        @intCast(obj.tc_unicode_string),
        obj.bytevectorLengthToGcLength(n),
        true,
    );
    obj.setNmVectorSubheader(result, obj.makeObject(ustring_flags_all << 2 | 1, n));
    const dest = obj.bytevectorData(result);
    @memcpy(dest[0 .. @as(usize, @intCast(n)) + 1], bytes[0 .. @as(usize, @intCast(n)) + 1]);
    return result;
}

// DEFINE_PRIMITIVE ("C-PEEK-CSTRING", Prim_peek_cstring, 2, 2, 0)
pub export fn Prim_peek_cstring() callconv(.c) SCM {
    abi.primitiveHeader();
    const ptr: [*:0]u8 = @ptrCast(alienAddressLoc());
    const count: c_int = @intCast(std.mem.len(ptr));
    return bytes_to_ustring(ptr, count);
}

// DEFINE_PRIMITIVE ("C-PEEK-CSTRING!", Prim_peek_cstring_bang, 2, 2, 0)
pub export fn Prim_peek_cstring_bang() callconv(.c) SCM {
    abi.primitiveHeader();
    const ptr: [*:0]u8 = @ptrCast(alienAddressLoc());
    const count = std.mem.len(ptr);
    const s = bytes_to_ustring(ptr, @intCast(count));
    set_alien_address(abi.argRef(1), ptr + count + 1);
    return s;
}

// DEFINE_PRIMITIVE ("C-PEEK-CSTRINGP", Prim_peek_cstringp, 2, 2, 0)
pub export fn Prim_peek_cstringp() callconv(.c) SCM {
    abi.primitiveHeader();
    const ptr = readUnaligned(?[*:0]u8, alienAddressLoc()) orelse return obj.empty_list;
    const count: c_int = @intCast(std.mem.len(ptr));
    return bytes_to_ustring(ptr, count);
}

// DEFINE_PRIMITIVE ("C-PEEK-CSTRINGP!", Prim_peek_cstringp_bang, 2, 2, 0)
pub export fn Prim_peek_cstringp_bang() callconv(.c) SCM {
    abi.primitiveHeader();
    const loc = alienAddressLoc();
    const ptr = readUnaligned(?[*:0]u8, loc) orelse return obj.empty_list;
    const count: c_int = @intCast(std.mem.len(ptr));
    const s = bytes_to_ustring(ptr, count);
    set_alien_address(abi.argRef(1), @as(?*const anyopaque, @ptrFromInt(@intFromPtr(loc) + @sizeOf(?*u8))));
    return s;
}

// DEFINE_PRIMITIVE ("C-PEEK-CSUBSTRING", Prim_peek_csubstring, 3, 3, 0)
pub export fn Prim_peek_csubstring() callconv(.c) SCM {
    abi.primitiveHeader();
    const ptr = alienAddressLoc();
    const count: c_int = @intCast(unsignedFixnumArg(3));
    return bytes_to_ustring(ptr, count);
}

// DEFINE_PRIMITIVE ("C-PEEK-BYTES", Prim_peek_bytes, 5, 5, 0)
pub export fn Prim_peek_bytes() callconv(.c) SCM {
    abi.primitiveHeader();
    const src = alienAddressLoc();
    const count: usize = @intCast(unsignedFixnumArg(3));
    const bv = abi.argRef(4);
    const index: usize = @intCast(abi.arg_index_integer(5, @intCast(obj.bytevectorLength(bv))));
    if (count > 0) {
        const dest = obj.bytevectorLoc(bv, index);
        @memcpy(dest[0..count], src[0..count]);
    }
    return obj.unspecific;
}

// Poke the Basic Types

// DEFINE_PRIMITIVE ("C-POKE-CHAR", Prim_poke_char, 3, 3, 0)
pub export fn Prim_poke_char() callconv(.c) SCM {
    return cPoker(CChar, truncateFromArgInt(CChar, 3));
}

// DEFINE_PRIMITIVE ("C-POKE-UCHAR", Prim_poke_uchar, 3, 3, 0)
pub export fn Prim_poke_uchar() callconv(.c) SCM {
    return cPoker(u8, truncateFromArgInt(u8, 3));
}

// DEFINE_PRIMITIVE ("C-POKE-SHORT", Prim_poke_short, 3, 3, 0)
pub export fn Prim_poke_short() callconv(.c) SCM {
    return cPoker(c_short, truncateFromArgInt(c_short, 3));
}

// DEFINE_PRIMITIVE ("C-POKE-USHORT", Prim_poke_ushort, 3, 3, 0)
pub export fn Prim_poke_ushort() callconv(.c) SCM {
    return cPoker(c_ushort, truncateFromArgInt(c_ushort, 3));
}

// DEFINE_PRIMITIVE ("C-POKE-INT", Prim_poke_int, 3, 3, 0)
pub export fn Prim_poke_int() callconv(.c) SCM {
    return cPoker(c_int, truncateFromArgInt(c_int, 3));
}

// DEFINE_PRIMITIVE ("C-POKE-UINT", Prim_poke_uint, 3, 3, 0)
pub export fn Prim_poke_uint() callconv(.c) SCM {
    return cPoker(c_uint, truncateFromArgInt(c_uint, 3));
}

// DEFINE_PRIMITIVE ("C-POKE-LONG", Prim_poke_long, 3, 3, 0)
pub export fn Prim_poke_long() callconv(.c) SCM {
    return cPoker(isize, abi.arg_integer(3));
}

// DEFINE_PRIMITIVE ("C-POKE-ULONG", Prim_poke_ulong, 3, 3, 0)
pub export fn Prim_poke_ulong() callconv(.c) SCM {
    return cPoker(usize, abi.arg_ulong_integer(3));
}

// DEFINE_PRIMITIVE ("C-POKE-FLOAT", Prim_poke_float, 3, 3, 0)
pub export fn Prim_poke_float() callconv(.c) SCM {
    return cPoker(f32, @floatCast(utils.arg_real_number(3)));
}

// DEFINE_PRIMITIVE ("C-POKE-DOUBLE", Prim_poke_double, 3, 3, 0)
pub export fn Prim_poke_double() callconv(.c) SCM {
    return cPoker(f64, utils.arg_real_number(3));
}

// DEFINE_PRIMITIVE ("C-POKE-POINTER", Prim_poke_pointer, 3, 3, 0)
pub export fn Prim_poke_pointer() callconv(.c) SCM {
    abi.primitiveHeader();
    writeUnaligned(?*anyopaque, alienAddressLoc(), arg_pointer(3));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("C-POKE-POINTER!", Prim_poke_pointer_bang, 3, 3, 0)
pub export fn Prim_poke_pointer_bang() callconv(.c) SCM {
    abi.primitiveHeader();
    const loc = alienAddressLoc();
    writeUnaligned(?*anyopaque, loc, arg_pointer(3));
    set_alien_address(abi.argRef(1), @as(?*const anyopaque, @ptrFromInt(@intFromPtr(loc) + @sizeOf(?*anyopaque))));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("C-POKE-STRING", Prim_poke_string, 3, 3, 0)
pub export fn Prim_poke_string() callconv(.c) SCM {
    abi.primitiveHeader();
    abi.checkArg(3, abi.string_p);
    const s = abi.argRef(3);
    copyCStringZ(alienAddressLoc(), obj.legacyStringData(s), @intCast(obj.legacyStringLength(s) + 1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("C-POKE-STRING!", Prim_poke_string_bang, 3, 3, 0)
pub export fn Prim_poke_string_bang() callconv(.c) SCM {
    abi.primitiveHeader();
    abi.checkArg(3, abi.string_p);
    const ptr = alienAddressLoc();
    const s = abi.argRef(3);
    const n_chars: usize = @intCast(obj.legacyStringLength(s) + 1);
    copyCStringZ(ptr, obj.legacyStringData(s), n_chars);
    set_alien_address(abi.argRef(1), ptr + n_chars);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("C-POKE-BYTES", Prim_poke_bytes, 5, 5, 0)
pub export fn Prim_poke_bytes() callconv(.c) SCM {
    abi.primitiveHeader();
    abi.checkArg(4, abi.string_p);
    const dest = alienAddressLoc();
    const count: usize = @intCast(unsignedFixnumArg(3));
    const s = abi.argRef(4);
    const index: usize = @intCast(abi.arg_index_integer(5, @intCast(obj.legacyStringLength(s))));
    if (count > 0) {
        const src = obj.legacyStringLoc(s, index);
        @memcpy(dest[0..count], src[0..count]);
    }
    return obj.unspecific;
}

// Malloc/Free

// DEFINE_PRIMITIVE ("C-MALLOC", Prim_c_malloc, 2, 2, 0)
pub export fn Prim_c_malloc() callconv(.c) SCM {
    abi.primitiveHeader();
    const alien = arg_alien(1);
    const ptr = std.c.malloc(@intCast(abi.arg_ulong_integer(2)));
    set_alien_address(alien, ptr);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("C-FREE", Prim_c_free, 1, 1, 0)
pub export fn Prim_c_free() callconv(.c) SCM {
    abi.primitiveHeader();
    const addr = arg_address(1);
    if (addr != null) {
        std.c.free(addr);
    }
    return obj.unspecific;
}

// The CStack

pub export fn cstack_top() callconv(.c) [*]u8 {
    return boot.ffi_obstack.next_free.?;
}

pub export fn cstack_push(addr: ?*anyopaque, bytes: c_int) callconv(.c) void {
    if (bytes > 0) {
        const src: [*]const u8 = @ptrCast(addr.?);
        boot.ffi_obstack.grow(src[0..@intCast(bytes)]);
    }
}

pub export fn cstack_lpop(tos: [*]u8, bytes: c_int) callconv(.c) [*]u8 {
    const tos_addr = @intFromPtr(tos);
    const base_addr = @intFromPtr(boot.ffi_obstack.object_base.?);
    const n: usize = @intCast(bytes);
    if (tos_addr < base_addr + n) {
        outf.errLine("\ninternal error: C stack exhausted.\tCould not pop {d} bytes.", .{bytes});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    return @ptrFromInt(tos_addr - n);
}

pub export fn cstack_pop(tos: [*]u8) callconv(.c) void {
    if (@intFromPtr(tos) < @intFromPtr(boot.ffi_obstack.object_base.?)) {
        outf.errLine("\ninternal error: C stack over-popped.", .{});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    boot.ffi_obstack.next_free = tos;
}

fn cstackPushVal(comptime T: type, val: T) void {
    boot.ffi_obstack.grow(std.mem.asBytes(&val));
}

fn cstackLpopVal(comptime T: type, tos: *[*]u8) T {
    const popped = cstack_lpop(tos.*, @sizeOf(T));
    tos.* = popped;
    return std.mem.bytesToValue(T, popped[0..@sizeOf(T)]);
}

// Callouts

// DEFINE_PRIMITIVE ("C-CALL", Prim_c_call, 1, LEXPR, 0)
pub export fn Prim_c_call() callconv(.c) SCM {
    abi.primitiveHeader();
    const tramp: CalloutTrampOut = @ptrCast(@alignCast(arg_alien_entry(1).?));
    return tramp();
}

pub export fn alienate_float_environment() callconv(.c) void {
    const s = fenv_plat.setDefaultEnv();
    if (s != 0) {
        outf.errLine("\nError status from fesetenv: {d}", .{s});
    }
}

pub export fn callout_seal(tramp: CalloutTrampIn) callconv(.c) void {
    if (c_call_continue == obj.sharp_f) {
        c_call_continue = primutl.find_primitive_cname("C-CALL-CONTINUE", false, false, abi.lexpr_primitive_arity);
        if (c_call_continue == obj.sharp_f) {
            outf.errLine("\nNo C-CALL-CONTINUE primitive!", .{});
            abi.signal_error_from_primitive(abi.err_external_return);
        }
    }
    cstack_depth += 1;
    cstackPushVal(c_int, cstack_depth);
    cstackPushVal(CalloutTrampIn, tramp);

    abi.Registers[abi.regblock_primitive] = c_call_continue;
    alienate_float_environment();
}

pub export fn callout_unseal(expected: CalloutTrampIn) callconv(.c) void {
    var tos = cstack_top();
    const found = cstackLpopVal(CalloutTrampIn, &tos);
    const depth = cstackLpopVal(c_int, &tos);
    if (found != expected or depth != cstack_depth) {
        outf.errLine("\ninternal error: slipped in 1st part of callout", .{});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    cstack_pop(tos);
}

pub export fn callout_continue(tramp: CalloutTrampIn) callconv(.c) SCM {
    cstackPushVal(c_int, cstack_depth);
    cstackPushVal(CalloutTrampIn, tramp);
    return tramp();
}

// DEFINE_PRIMITIVE ("C-CALL-CONTINUE", Prim_c_call_continue, 1, LEXPR, 0)
pub export fn Prim_c_call_continue() callconv(.c) SCM {
    abi.primitiveHeader();
    var tos = cstack_top();
    const tramp = cstackLpopVal(CalloutTrampIn, &tos);
    const depth = cstackLpopVal(c_int, &tos);
    if (depth != cstack_depth) {
        outf.errLine("\ninternal error: slipped in 2nd part of callout", .{});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    return tramp();
}

pub export fn callout_lunseal(expected: CalloutTrampIn) callconv(.c) [*]u8 {
    var tos = cstack_top();
    const found = cstackLpopVal(CalloutTrampIn, &tos);
    const depth = cstackLpopVal(c_int, &tos);
    if (depth != cstack_depth or found != expected) {
        outf.errLine("\ninternal error: slipped in 2nd tramp of callout", .{});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    return tos;
}

pub export fn callout_pop(tos: [*]u8) callconv(.c) void {
    cstack_depth -= 1;
    cstack_pop(tos);
}

// Callbacks

pub export fn callback_run_kernel(callback_id: c_long, kernel: CallbackKernel) callconv(.c) void {
    const nargs = abi.getLexprActuals();

    if (run_callback == obj.sharp_f) {
        run_callback = primutl.find_primitive_cname("RUN-CALLBACK", false, false, 0);
        if (run_callback == obj.sharp_f) {
            outf.errLine("\nWarning: punted callback #{d}.  Missing primitive!", .{callback_id});
            abi.Registers[abi.regblock_val] = obj.ulongToFixnum(0);
            return;
        }
    }

    if (abi.Registers[abi.regblock_primitive] != c_call_continue) {
        abi.abort_to_interpreter(abi.err_cannot_recurse);
    }

    cstack_depth += 1;
    cstackPushVal(c_int, cstack_depth);
    cstackPushVal(CallbackKernel, kernel);

    // For a traceable stack...
    abi.stackPush(c_call_continue);
    abi.stackPush(abi.makeApplyFrameHeader(nargs + 1));
    abi.pushCont(abi.rc_internal_apply, c_call_continue);

    const saved_stack_pointer = abi.stack_pointer;
    const saved_last_return_code = abi.last_return_code;
    abi.stackCheck(2 * abi.cont_size + 2);
    abi.pushCont(abi.rc_end_of_computation, run_callback);
    abi.stackPush(run_callback);
    abi.stackPush(abi.makeApplyFrameHeader(1));
    abi.pushCont(abi.rc_internal_apply, run_callback);
    abi.last_return_code = abi.stack_pointer;
    abi.Registers[abi.regblock_expr] = obj.sharp_f;
    _ = boot.Re_Enter_Interpreter();

    const frame_slipped = abi.stack_pointer != saved_stack_pointer or
        (build_options.debugging and
            (abi.stackRef(0) != obj.makeObject(obj.tc_return_code, abi.rc_internal_apply) or
                abi.stackRef(1) != c_call_continue or
                abi.stackRef(2) != obj.makeObject(0, nargs + 1) or
                abi.stackRef(3) != c_call_continue));
    if (frame_slipped) {
        abi.Registers[abi.regblock_primitive] = c_call_continue;
        abi.Registers[abi.regblock_lexpr_actuals] = 0;
        outf.errLine("\nWarning: stack slipped in callback.", .{});
        abi.signal_error_from_primitive(abi.err_stack_has_slipped);
    }

    abi.stack_pointer = abi.stackLoc(4);
    abi.last_return_code = saved_last_return_code;
    abi.Registers[abi.regblock_primitive] = c_call_continue;
    abi.Registers[abi.regblock_lexpr_actuals] = @intCast(nargs);

    cstack_depth -= 1;
    alienate_float_environment();
}

// DEFINE_PRIMITIVE ("RUN-CALLBACK", Prim_run_callback, 0, 0, 0)
pub export fn Prim_run_callback() callconv(.c) SCM {
    abi.primitiveHeader();
    var tos = cstack_top();
    const kernel = cstackLpopVal(CallbackKernel, &tos);
    const depth = cstackLpopVal(c_int, &tos);
    if (depth != cstack_depth) {
        outf.errLine("\nWarning: C data stack slipped in run-callback!", .{});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    kernel();
    return obj.unspecific;
}

pub export fn callback_lunseal(expected: CallbackKernel) callconv(.c) [*]u8 {
    var tos = cstack_top();
    const found = cstackLpopVal(CallbackKernel, &tos);
    const depth = cstackLpopVal(c_int, &tos);
    if (depth != cstack_depth or found != expected) {
        outf.errLine("\ninternal error: slipped in callback kernel", .{});
        abi.signal_error_from_primitive(abi.err_external_return);
    }
    return tos;
}

fn validCallbackHandler() SCM {
    const handler = obj.vectorRef(abi.fixed_objects, abi.fixobj_callback_handler);
    if (!utils.interpreter_applicable_p(handler)) {
        outf.errLine("\nWarning: bogus callback handler: 0x{x}.", .{@as(c_uint, @truncate(@as(u64, @intCast(handler))))});
        utils.Do_Micro_Error(abi.err_inapplicable_object, true);
        abi.abort_to_interpreter(abi.prim_apply);
    }
    return handler;
}

fn validCallbackId(id: isize) SCM {
    if (id >= 0 and obj.ulongToFixnumP(@intCast(id))) {
        return obj.ulongToFixnum(@intCast(id));
    }
    abi.signal_error_from_primitive(abi.err_arg_1_bad_range);
}

pub export fn callback_run_handler(callback_id: c_long, arglist: SCM) callconv(.c) void {
    const handler = validCallbackHandler();
    const fixnum_id = validCallbackId(@as(isize, callback_id));

    abi.stackCheck(4 + abi.cont_size);
    abi.stackPush(arglist);
    abi.stackPush(fixnum_id);
    abi.stackPush(handler);
    abi.stackPush(abi.makeApplyFrameHeader(3));
    abi.pushCont(abi.rc_internal_apply, run_callback);
}

pub export fn callback_return(tos: [*]u8) callconv(.c) void {
    cstack_pop(tos);
}

// Converters

pub export fn arg_long(argn: c_int) callconv(.c) c_long {
    const v = abi.arg_integer(argn);
    if (v < std.math.minInt(c_long) or v > std.math.maxInt(c_long)) {
        abi.error_bad_range_arg(argn);
    }
    return @intCast(v);
}

pub export fn arg_ulong(argn: c_int) callconv(.c) c_ulong {
    const v = abi.arg_ulong_integer(argn);
    if (v > std.math.maxInt(c_ulong)) {
        abi.error_bad_range_arg(argn);
    }
    return @intCast(v);
}

pub export fn arg_double(argn: c_int) callconv(.c) f64 {
    return utils.arg_real_number(argn);
}

pub export fn arg_alien_entry(argn: c_int) callconv(.c) ?*anyopaque {
    const alienf = abi.vectorArg(argn);
    if (obj.vectorLength(alienf) < 3) {
        abi.error_wrong_type_arg(argn);
    }
    return alien_address(alienf);
}

pub export fn arg_pointer(argn: c_int) callconv(.c) ?*anyopaque {
    const arg = abi.argRef(@intCast(argn));
    if (obj.integerP(arg) and artutl.integer_zero_p(arg)) {
        return null;
    }
    if (abi.string_p(arg)) {
        return @ptrCast(obj.legacyStringData(arg));
    }
    if (obj.integerP(arg) and artutl.integer_to_ulong_p(arg)) {
        const result = string.lookup_external_string(arg, null) orelse abi.error_wrong_type_arg(argn);
        return @ptrCast(result);
    }
    if (is_alien(arg) != 0) {
        return alien_address(arg);
    }
    if (obj.flonumP(arg)) {
        return @ptrCast(obj.memoryLoc(arg, 1));
    }
    abi.error_wrong_type_arg(argn);
}

pub export fn long_to_scm(i: c_long) callconv(.c) SCM {
    return abi.long_to_integer(@as(isize, i));
}

pub export fn ulong_to_scm(i: c_ulong) callconv(.c) SCM {
    return abi.ulong_to_integer(@as(usize, i));
}

pub export fn double_to_scm(d: f64) callconv(.c) SCM {
    return abi.double_to_flonum(d);
}

pub export fn pointer_to_scm(p: ?*const anyopaque) callconv(.c) SCM {
    const arg = abi.argRef(2);
    if (arg == obj.sharp_f) {
        return obj.unspecific;
    }
    if (is_alien(arg) != 0) {
        set_alien_address(arg, p);
        return arg;
    }
    abi.error_wrong_type_arg(2);
}

pub export fn struct_to_scm(p: ?*const anyopaque, size: c_int) callconv(.c) SCM {
    const arg = abi.argRef(2);
    if (arg == obj.sharp_f) {
        return obj.unspecific;
    }
    if (is_alien(arg) != 0) {
        if (size > 0) {
            const dst: [*]u8 = @ptrCast(alien_address(arg).?);
            const src: [*]const u8 = @ptrCast(p.?);
            @memcpy(dst[0..@intCast(size)], src[0..@intCast(size)]);
        }
        return arg;
    }
    abi.error_wrong_type_arg(2);
}

pub export fn cons_alien(addr: ?*const anyopaque) callconv(.c) SCM {
    abi.primitiveGcIfNeeded(5);
    const alien = obj.makePointerObject(obj.tc_record, abi.Free);
    abi.Free[0] = obj.makeVectorHeader(4);
    abi.Free[1] = obj.sharp_f;
    abi.Free[2] = obj.ulongToFixnum(0);
    abi.Free[3] = obj.ulongToFixnum(0);
    abi.Free[4] = obj.sharp_f;
    abi.Free += 5;
    set_alien_address(alien, addr);
    return alien;
}

pub export fn long_value() callconv(.c) c_long {
    const value = abi.Registers[abi.regblock_val];
    if (obj.characterP(value)) {
        return @intCast(obj.charToAscii(value));
    }
    if (!obj.integerP(value)) {
        outf.errLine("\nWarning: Callback did not return an integer!", .{});
        return 0;
    }
    if (!artutl.integer_to_long_p(value)) {
        outf.errLine("\nWarning: Callback returned an integer larger than a C long!", .{});
        return 0;
    }
    const v = artutl.integer_to_long(value);
    if (v < std.math.minInt(c_long) or v > std.math.maxInt(c_long)) {
        outf.errLine("\nWarning: Callback returned an integer larger than a C long!", .{});
        return 0;
    }
    return @intCast(v);
}

pub export fn ulong_value() callconv(.c) c_ulong {
    const value = abi.Registers[abi.regblock_val];
    if (obj.characterP(value)) {
        return @intCast(obj.charToAscii(value));
    }
    if (!obj.integerP(value)) {
        outf.errLine("\nWarning: Callback did not return an integer!", .{});
        return 0;
    }
    if (!artutl.integer_to_ulong_p(value)) {
        outf.errLine("\nWarning: Callback returned an integer larger than a C unsigned long!", .{});
        return 0;
    }
    const v = artutl.integer_to_ulong(value);
    if (v > std.math.maxInt(c_ulong)) {
        outf.errLine("\nWarning: Callback returned an integer larger than a C unsigned long!", .{});
        return 0;
    }
    return @intCast(v);
}

pub export fn double_value() callconv(.c) f64 {
    const value = abi.Registers[abi.regblock_val];
    if (!obj.realP(value)) {
        outf.errLine("\nWarning: Callback did not return a real.", .{});
        return 0.0;
    }
    if (!utils.real_number_to_double_p(value)) {
        outf.errLine("\nWarning: Callback returned a real larger than a C double!", .{});
        return 0.0;
    }
    return utils.real_number_to_double(value);
}

pub export fn pointer_value() callconv(.c) ?*anyopaque {
    const value = abi.Registers[abi.regblock_val];
    if (obj.integerP(value) and artutl.integer_zero_p(value)) {
        return null;
    }
    if (is_alien(value) != 0) {
        return alien_address(value);
    }
    outf.errLine("\nWarning: Callback did not return a pointer.", .{});
    return null;
}

// Utilities

pub export fn check_number_of_args(num: c_int) callconv(.c) void {
    if (num < 0 or abi.getLexprActuals() < @as(usize, @intCast(num))) {
        abi.signal_error_from_primitive(abi.err_wrong_number_of_arguments);
    }
}

pub export fn unspecific() callconv(.c) SCM {
    return obj.unspecific;
}

pub export fn empty_list() callconv(.c) SCM {
    return obj.empty_list;
}

pub export fn flovec_length(first: [*]f64) callconv(.c) c_int {
    const vec_mem: [*]obj.SchemeObject = @as([*]obj.SchemeObject, @ptrCast(@alignCast(first))) - 1;
    const vector = obj.makePointerObject(obj.tc_big_flonum, vec_mem);
    return @intCast(obj.floatingVectorLength(vector));
}

// DEFINE_PRIMITIVE ("OUTF-ERROR", Prim_outf_error, 1, 1, 0)
pub export fn Prim_outf_error() callconv(.c) SCM {
    abi.primitiveHeader();
    const arg = abi.argRef(1);
    if (abi.string_p(arg)) {
        const cstr: [*:0]const u8 = @ptrCast(obj.legacyStringLoc(arg, 0));
        outf.err("{s}", .{cstr});
        outf.flushError();
    } else {
        abi.error_wrong_type_arg(1);
    }
    return obj.unspecific;
}

// Re-Entering the Interpreter

pub export fn re_enter_scheme() callconv(.c) void {
    std.debug.assert(abi.Registers[abi.regblock_primitive] == c_call_continue);
    abi.back_out_of_primitive();
    _ = boot.Re_Enter_Interpreter();

    std.debug.assert(abi.Registers[abi.regblock_primitive] == obj.sharp_f);
    std.debug.assert(abi.Registers[abi.regblock_expr] == obj.sharp_f);
    std.debug.assert(abi.stackRef(0) == obj.makeObject(obj.tc_return_code, abi.rc_internal_apply));
    std.debug.assert(abi.stackRef(1) == obj.sharp_f);
    std.debug.assert(obj.objectType(abi.stackRef(2)) == obj.tc_false);
    std.debug.assert(abi.stackRef(3) == c_call_continue);

    abi.Registers[abi.regblock_primitive] = c_call_continue;
    abi.Registers[abi.regblock_lexpr_actuals] = @intCast(abi.applyFrameHeaderNArgs(abi.stackRef(2)));
    abi.stack_pointer = abi.stackLoc(4);
    alienate_float_environment();
}

pub export fn abort_to_c() callconv(.c) void {
    std.debug.assert(abi.Registers[abi.regblock_primitive] == c_call_continue);
    abi.back_out_of_primitive();
    abi.abort_to_interpreter(abi.prim_return_to_c);
}

pub export fn interrupts_p() callconv(.c) c_int {
    return @bitCast(@as(u32, @truncate(@as(u64, @intCast(abi.Registers[abi.regblock_int_code])))));
}

var test_callout_stage: u32 = 0;

fn testCalloutPart2() callconv(.c) SCM {
    var tos = callout_lunseal(&testCalloutPart2);
    const val = cstackLpopVal(u32, &tos);
    callout_pop(tos);
    test_callout_stage += 1;
    return abi.ulong_to_integer(@as(usize, val) + 1);
}

fn testCalloutPart1() callconv(.c) SCM {
    callout_unseal(&testCalloutPart1);
    const arg = abi.arg_ulong_integer(2);
    const next_val: u32 = @intCast(arg * 2);
    cstackPushVal(u32, next_val);
    return callout_continue(&testCalloutPart2);
}

fn testCalloutOut() callconv(.c) SCM {
    callout_seal(&testCalloutPart1);
    return testCalloutPart1();
}

test "pruxffi alien peek/poke unaligned, cstack/callout seal-unseal, and converters" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    boot.ffi_obstack.init(&boot.obstack_chunk_alloc, &std.c.free);
    defer {
        boot.ffi_obstack.freeObj(null);
        cstack_depth = 0;
        c_call_continue = obj.sharp_f;
        run_callback = obj.sharp_f;
        stubs.resetMockRuntime();
    }

    // 1. Alien construction & address round-trip
    var backing: [64]u8 = @splat(0);
    const alien = cons_alien(&backing);
    try std.testing.expectEqual(@as(c_int, 1), is_alien(alien));
    try std.testing.expectEqual(@intFromPtr(&backing), @intFromPtr(alien_address(alien)));

    // 2. Unaligned integer, float, double, pointer, C-string & byte pokes/peeks
    stubs.setArgs(&.{ alien, obj.ulongToFixnum(1), obj.longToFixnum(-42) });
    _ = Prim_poke_int();
    stubs.setArgs(&.{ alien, obj.ulongToFixnum(1) });
    try std.testing.expectEqual(obj.longToFixnum(-42), Prim_peek_int());

    stubs.setArgs(&.{ alien, obj.ulongToFixnum(5), abi.double_to_flonum(3.5) });
    _ = Prim_poke_float();
    _ = Prim_poke_double();
    stubs.setArgs(&.{ alien, obj.ulongToFixnum(5) });
    try std.testing.expectEqual(@as(f64, 3.5), obj.flonumToDouble(Prim_peek_double()));

    const s_hello = string.char_pointer_to_string("hi!");
    stubs.setArgs(&.{ alien, obj.ulongToFixnum(16), s_hello });
    _ = Prim_poke_string_bang();
    try std.testing.expectEqual(@intFromPtr(&backing[20]), @intFromPtr(alien_address(alien)));
    set_alien_address(alien, &backing);
    stubs.setArgs(&.{ alien, obj.ulongToFixnum(16) });
    const ustr = Prim_peek_cstring();
    try std.testing.expectEqual(@as(usize, 3), obj.objectDatum(obj.nmVectorSubheader(ustr)));
    try std.testing.expectEqualStrings("hi!", obj.bytevectorData(ustr)[0..3]);

    // 3. C-MALLOC / C-FREE
    stubs.setArgs(&.{ alien, obj.ulongToFixnum(32) });
    _ = Prim_c_malloc();
    const mallocd = alien_address(alien);
    try std.testing.expect(mallocd != null);
    stubs.setArgs(&.{alien});
    _ = Prim_c_free();

    // 4. Callout seal -> unseal -> continue -> lunseal -> pop + unaligned CStack round-trip
    c_call_continue = obj.makePrimitiveObject(1);
    test_callout_stage = 0;
    const alienf = abi.allocate_vector(4, false);
    set_alien_address(alienf, &testCalloutOut);
    stubs.setArgs(&.{ alienf, obj.ulongToFixnum(21) });
    const call_res = Prim_c_call();
    try std.testing.expectEqual(obj.ulongToFixnum(43), call_res);
    try std.testing.expectEqual(@as(u32, 1), test_callout_stage);
    try std.testing.expectEqual(@as(c_int, 0), cstack_depth);

    // 5. Converters, flovec_length, and value readers
    const fval = abi.double_to_flonum(7.25);
    const fptr: [*]f64 = @ptrCast(@alignCast(obj.memoryLoc(fval, 1)));
    try std.testing.expectEqual(@as(c_int, 1), flovec_length(fptr));

    abi.Registers[abi.regblock_val] = obj.makeObject(obj.tc_character, 'Z');
    try std.testing.expectEqual(@as(isize, 'Z'), long_value());
    try std.testing.expectEqual(@as(usize, 'Z'), ulong_value());
    abi.Registers[abi.regblock_val] = fval;
    try std.testing.expectEqual(@as(f64, 7.25), double_value());
    abi.Registers[abi.regblock_val] = obj.ulongToFixnum(0);
    try std.testing.expectEqual(@as(?*anyopaque, null), pointer_value());

    abi.Registers[abi.regblock_int_code] = 0x15;
    try std.testing.expectEqual(@as(c_int, 0x15), interrupts_p());
}
