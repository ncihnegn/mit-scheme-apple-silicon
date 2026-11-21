// Derived from MIT/GNU Scheme C sources (`src/microcode/prchacha.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const chacha = @import("chacha.zig");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");

var chacha8_selftested: bool = false;
var chacha12_selftested: bool = false;
var chacha20_selftested: bool = false;

fn doChachaCore(
    comptime core_fn: fn (
        *[chacha.output_bytes]u8,
        *const [chacha.input_bytes]u8,
        *const [chacha.key_bytes]u8,
        *const [chacha.const_bytes]u8,
    ) callconv(.c) void,
    comptime selftest_fn: fn () callconv(.c) c_int,
    selftestedp: *bool,
) void {
    var noutput: c_ulong = 0;
    const output = abi.arg_bytevector(1, &noutput);
    if (noutput < chacha.output_bytes) abi.error_bad_range_arg(1);

    const offset: usize = @intCast(abi.arg_ulong_index_integer(2, noutput - chacha.output_bytes + 1));

    var ninput: c_ulong = 0;
    const input = abi.arg_bytevector(3, &ninput);
    if (ninput != chacha.input_bytes) abi.error_bad_range_arg(3);

    var nkey: c_ulong = 0;
    const key = abi.arg_bytevector(4, &nkey);
    if (nkey != chacha.key_bytes) abi.error_bad_range_arg(4);

    var nconstant: c_ulong = 0;
    const constant = abi.arg_bytevector(5, &nconstant);
    if (nconstant != chacha.const_bytes) abi.error_bad_range_arg(5);

    if (!selftestedp.*) {
        if (selftest_fn() != 0) abi.error_external_return();
        selftestedp.* = true;
    }

    core_fn(
        @ptrCast(output + offset),
        @ptrCast(input),
        @ptrCast(key),
        @ptrCast(constant),
    );
}

// DEFINE_PRIMITIVE ("CHACHA8-CORE", Prim_chacha8_core, 5, 5,
//   "(OUTPUT OFFSET INPUT KEY CONSTANT)\n\
// Compute the ChaCha8 core hash function:\n\
// OUTPUT[OFFSET, OFFSET+1, ..., OFFSET+63] := ChaCha8(INPUT, KEY, CONST).")
pub export fn Prim_chacha8_core() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    doChachaCore(chacha.chacha8_core, chacha.chacha8_core_selftest, &chacha8_selftested);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CHACHA12-CORE", Prim_chacha12_core, 5, 5,
//   "(OUTPUT OFFSET INPUT KEY CONSTANT)\n\
// Compute the ChaCha12 core hash function:\n\
// OUTPUT[OFFSET, OFFSET+1, ..., OFFSET+63] := ChaCha12(INPUT, KEY, CONST).")
pub export fn Prim_chacha12_core() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    doChachaCore(chacha.chacha12_core, chacha.chacha12_core_selftest, &chacha12_selftested);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CHACHA20-CORE", Prim_chacha20_core, 5, 5,
//   "(OUTPUT OFFSET INPUT KEY CONSTANT)\n\
// Compute the ChaCha20 core hash function:\n\
// OUTPUT[OFFSET, OFFSET+1, ..., OFFSET+63] := ChaCha20(INPUT, KEY, CONST).")
pub export fn Prim_chacha20_core() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    doChachaCore(chacha.chacha20_core, chacha.chacha20_core_selftest, &chacha20_selftested);
    return obj.unspecific;
}

test "prchacha primitives compute expected zero-key vectors at offset" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    const output_bv = stubs.allocate_bytevector(70);
    const input_bv = stubs.allocate_bytevector(16);
    const key_bv = stubs.allocate_bytevector(32);
    const const_bv = stubs.memory_to_bytevector(16, "expand 32-byte k");

    stubs.setArgs(&.{ output_bv, obj.ulongToFixnum(4), input_bv, key_bv, const_bv });
    try std.testing.expectEqual(obj.unspecific, Prim_chacha8_core());
    try std.testing.expect(chacha8_selftested);

    var expected8: [64]u8 = undefined;
    var expected12: [64]u8 = undefined;
    var expected20: [64]u8 = undefined;
    const zero16: [16]u8 = @splat(0);
    const zero32: [32]u8 = @splat(0);
    chacha.chacha8_core(&expected8, &zero16, &zero32, "expand 32-byte k");
    chacha.chacha12_core(&expected12, &zero16, &zero32, "expand 32-byte k");
    chacha.chacha20_core(&expected20, &zero16, &zero32, "expand 32-byte k");

    const out_slice = obj.bytevectorData(output_bv)[4..68];
    try std.testing.expectEqualSlices(u8, &expected8, out_slice);

    try std.testing.expectEqual(obj.unspecific, Prim_chacha12_core());
    try std.testing.expectEqualSlices(u8, &expected12, out_slice);

    try std.testing.expectEqual(obj.unspecific, Prim_chacha20_core());
    try std.testing.expectEqualSlices(u8, &expected20, out_slice);
}
