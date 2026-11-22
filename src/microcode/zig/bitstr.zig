// Derived from MIT/GNU Scheme C sources (`src/microcode/bitstr.c`, `src/microcode/bitstr.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const bits = @import("bits.zig");

comptime {
    if (builtin.cpu.arch.endian() != .little) {
        @compileError("big-endian bit_string layout not implemented");
    }
}

const bit_string_length_offset: usize = 1;
const bit_string_first_word: usize = 2;
const object_length: usize = @bitSizeOf(obj.SchemeObject);

inline fn bitStringLengthToGcLength(n_bits: usize) usize {
    return (n_bits + (object_length - 1)) / object_length;
}

inline fn lowMask(nbits: usize) obj.SchemeObject {
    if (nbits == 0) return 0;
    if (nbits >= object_length) return ~@as(obj.SchemeObject, 0);
    return (@as(obj.SchemeObject, 1) << @intCast(nbits)) - 1;
}

inline fn anyMask(nbits: usize, offset: usize) obj.SchemeObject {
    if (nbits == 0 or offset >= object_length) return 0;
    return lowMask(nbits) << @intCast(offset);
}

inline fn bitStringLength(bs: obj.SchemeObject) usize {
    return obj.memoryRef(bs, bit_string_length_offset);
}

inline fn bitStringHighPtr(bs: obj.SchemeObject) [*]obj.SchemeObject {
    return obj.memoryLoc(bs, @intCast(obj.vectorLength(bs) + 1));
}

inline fn bitStringLowPtr(bs: obj.SchemeObject) [*]obj.SchemeObject {
    return obj.memoryLoc(bs, bit_string_first_word);
}

inline fn bitStringWord(ptr: [*]const obj.SchemeObject) obj.SchemeObject {
    return (ptr - 1)[0];
}

inline fn bitStringWordPtr(ptr: [*]obj.SchemeObject) *obj.SchemeObject {
    return &(ptr - 1)[0];
}

// Off by one so bitStringWord(ptr) reads the indexed word via (ptr - 1)[0].
inline fn bitStringIndexToWord(index: usize) usize {
    return (bit_string_first_word + 1) + @as(usize, @intCast(index / object_length));
}

pub export fn allocate_bit_string(length: usize) callconv(.c) obj.SchemeObject {
    const total_pointers = 1 + bitStringLengthToGcLength(length);
    const result = abi.allocate_non_marked_vector(@intCast(obj.tc_bit_string), total_pointers, true);
    obj.memorySet(result, bit_string_length_offset, length);
    return result;
}

pub export fn fill_bit_string(bit_string: obj.SchemeObject, sense: c_int) callconv(.c) void {
    const filler: obj.SchemeObject = if (sense != 0) ~@as(obj.SchemeObject, 0) else 0;
    var scanner = bitStringHighPtr(bit_string);
    var i = bitStringLengthToGcLength(bitStringLength(bit_string));
    while (i > 0) : (i -= 1) {
        scanner -= 1;
        scanner[0] = filler;
    }
}

pub export fn clear_bit_string(bit_string: obj.SchemeObject) callconv(.c) void {
    fill_bit_string(bit_string, 0);
}

pub export fn bit_string_set(bitstr: obj.SchemeObject, index: isize, value: c_int) callconv(.c) void {
    const idx: usize = @intCast(index);
    const ptr = obj.memoryLoc(bitstr, bitStringIndexToWord(idx));
    const mask: obj.SchemeObject = @as(obj.SchemeObject, 1) << @intCast(idx % object_length);
    if (value == 0) {
        bitStringWordPtr(ptr).* &= ~mask;
    } else {
        bitStringWordPtr(ptr).* |= mask;
    }
}

// DEFINE_PRIMITIVE ("BIT-STRING-ALLOCATE", Prim_bit_string_allocate, 1, 1, 0)
pub export fn Prim_bit_string_allocate() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return allocate_bit_string(abi.arg_ulong_integer(1));
}

// DEFINE_PRIMITIVE ("BIT-STRING?", Prim_bit_string_p, 1, 1, 0)
pub export fn Prim_bit_string_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(obj.bitStringP(abi.argRef(1)));
}

// DEFINE_PRIMITIVE ("MAKE-BIT-STRING", Prim_make_bit_string, 2, 2,
//  "(SIZE INITIALIZATION)\n\
// Returns a bit string of the specified size with all the bits\n\
// set to zero if the initialization is false, one otherwise.")
pub export fn Prim_make_bit_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = allocate_bit_string(abi.arg_ulong_integer(1));
    fill_bit_string(result, @intFromBool(obj.objectToBoolean(abi.argRef(2))));
    return result;
}

// DEFINE_PRIMITIVE ("BIT-STRING-FILL!", Prim_bit_string_fill_x, 2, 2,
//   "(BIT-STRING INITIALIZATION)\n\
// Fills the bit string with zeros if the initialization is false, \
// otherwise fills it with ones.")
pub export fn Prim_bit_string_fill_x() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    fill_bit_string(abi.argRef(1), @intFromBool(obj.objectToBoolean(abi.argRef(2))));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("BIT-STRING-LENGTH", Prim_bit_string_length, 1, 1,
//   "(BIT-STRING)\n\
// Returns the number of bits in BIT-STRING.")
pub export fn Prim_bit_string_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    return obj.longToUnsignedFixnum(@intCast(bitStringLength(abi.argRef(1))));
}

fn refInit() struct { word_ptr: *obj.SchemeObject, mask: obj.SchemeObject } {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    const bit_string = abi.argRef(1);
    const index: usize = @intCast(abi.arg_nonnegative_integer(2));
    if (index >= bitStringLength(bit_string)) abi.error_bad_range_arg(2);
    const ptr = obj.memoryLoc(bit_string, bitStringIndexToWord(index));
    const mask: obj.SchemeObject = @as(obj.SchemeObject, 1) << @intCast(index % object_length);
    return .{ .word_ptr = bitStringWordPtr(ptr), .mask = mask };
}

// DEFINE_PRIMITIVE ("BIT-STRING-REF", Prim_bit_string_ref, 2, 2,
//   "(BIT-STRING INDEX)\n\
// Returns the boolean value of the indexed bit.")
pub export fn Prim_bit_string_ref() callconv(.c) obj.SchemeObject {
    const info = refInit();
    return obj.booleanToObject((info.word_ptr.* & info.mask) != 0);
}

// DEFINE_PRIMITIVE ("BIT-STRING-CLEAR!", Prim_bit_string_clear_x, 2, 2,
//   "(BIT-STRING INDEX)\n\
// Sets the indexed bit to zero, returning its previous value as a boolean.")
pub export fn Prim_bit_string_clear_x() callconv(.c) obj.SchemeObject {
    const info = refInit();
    if ((info.word_ptr.* & info.mask) == 0) return obj.sharp_f;
    info.word_ptr.* &= ~info.mask;
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("BIT-STRING-SET!", Prim_bit_string_set_x, 2, 2,
//   "(BIT-STRING INDEX)\n\
// Sets the indexed bit to one, returning its previous value as a boolean.")
pub export fn Prim_bit_string_set_x() callconv(.c) obj.SchemeObject {
    const info = refInit();
    if ((info.word_ptr.* & info.mask) != 0) return obj.sharp_t;
    info.word_ptr.* |= info.mask;
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("BIT-STRING-ZERO?", Prim_bit_string_zero_p, 1, 1,
//  "(BIT-STRING)\n\
// Returns true the argument has no \"set\" bits.")
pub export fn Prim_bit_string_zero_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    const bit_string = abi.argRef(1);
    const length = bitStringLength(bit_string);
    const odd_bits = length % object_length;
    var scan = bitStringHighPtr(bit_string);
    if (odd_bits != 0) {
        if ((bitStringWord(scan) & lowMask(odd_bits)) != 0) return obj.sharp_f;
        scan -= 1;
    }
    var i = length / object_length;
    while (i > 0) : (i -= 1) {
        scan -= 1;
        if (scan[0] != 0) return obj.sharp_f;
    }
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("BIT-STRING=?", Prim_bit_string_equal_p, 2, 2,
//   "(BIT-STRING-1 BIT-STRING-2)\n\
// Returns true iff the two bit strings contain the same bits.")
pub export fn Prim_bit_string_equal_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    abi.checkArg(2, obj.bitStringP);
    const bs1 = abi.argRef(1);
    const bs2 = abi.argRef(2);
    const length = bitStringLength(bs1);
    if (length != bitStringLength(bs2)) return obj.sharp_f;
    var scan1 = bitStringHighPtr(bs1);
    var scan2 = bitStringHighPtr(bs2);
    const odd_bits = length % object_length;
    if (odd_bits != 0) {
        const mask = lowMask(odd_bits);
        if ((bitStringWord(scan1) & mask) != (bitStringWord(scan2) & mask)) return obj.sharp_f;
        scan1 -= 1;
        scan2 -= 1;
    }
    var i = length / object_length;
    while (i > 0) : (i -= 1) {
        scan1 -= 1;
        scan2 -= 1;
        if (scan1[0] != scan2[0]) return obj.sharp_f;
    }
    return obj.sharp_t;
}

const BitwiseOpKind = enum {
    move,
    movec,
    ior,
    @"and",
    andc,
    xor,
};

fn bitwiseOp(comptime kind: BitwiseOpKind) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    abi.checkArg(2, obj.bitStringP);
    const bs1 = abi.argRef(1);
    const bs2 = abi.argRef(2);
    if (bitStringLength(bs1) != bitStringLength(bs2)) abi.error_bad_range_arg(1);
    var scan1 = bitStringHighPtr(bs1);
    var scan2 = bitStringHighPtr(bs2);
    var i = obj.vectorLength(bs1) - 1;
    while (i > 0) : (i -= 1) {
        scan1 -= 1;
        scan2 -= 1;
        const b = scan2[0];
        scan1[0] = switch (kind) {
            .move => b,
            .movec => ~b,
            .ior => scan1[0] | b,
            .@"and" => scan1[0] & b,
            .andc => scan1[0] & ~b,
            .xor => scan1[0] ^ b,
        };
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("BIT-STRING-MOVE!", Prim_bit_string_move_x, 2, 2, 0)
pub export fn Prim_bit_string_move_x() callconv(.c) obj.SchemeObject {
    return bitwiseOp(.move);
}

// DEFINE_PRIMITIVE ("BIT-STRING-MOVEC!", Prim_bit_string_movec_x, 2, 2, 0)
pub export fn Prim_bit_string_movec_x() callconv(.c) obj.SchemeObject {
    return bitwiseOp(.movec);
}

// DEFINE_PRIMITIVE ("BIT-STRING-OR!", Prim_bit_string_or_x, 2, 2, 0)
pub export fn Prim_bit_string_or_x() callconv(.c) obj.SchemeObject {
    return bitwiseOp(.ior);
}

// DEFINE_PRIMITIVE ("BIT-STRING-AND!", Prim_bit_string_and_x, 2, 2, 0)
pub export fn Prim_bit_string_and_x() callconv(.c) obj.SchemeObject {
    return bitwiseOp(.@"and");
}

// DEFINE_PRIMITIVE ("BIT-STRING-ANDC!", Prim_bit_string_andc_x, 2, 2, 0)
pub export fn Prim_bit_string_andc_x() callconv(.c) obj.SchemeObject {
    return bitwiseOp(.andc);
}

// DEFINE_PRIMITIVE ("BIT-STRING-XOR!", Prim_bit_string_xor_x, 2, 2, 0)
pub export fn Prim_bit_string_xor_x() callconv(.c) obj.SchemeObject {
    return bitwiseOp(.xor);
}

inline fn maskedTransfer(
    source: [*]const obj.SchemeObject,
    destination: [*]obj.SchemeObject,
    nbits: usize,
    offset: usize,
) void {
    const mask = anyMask(nbits, offset);
    const dst = bitStringWordPtr(destination);
    dst.* = (bitStringWord(source) & mask) | (dst.* & ~mask);
}

fn copyBits(
    source_in: [*]const obj.SchemeObject,
    source_offset: usize,
    destination_in: [*]obj.SchemeObject,
    destination_offset: usize,
    nbits_in: usize,
) void {
    if (nbits_in == 0) return;

    var source = source_in;
    var destination = destination_in;
    var nbits = nbits_in;

    if (source_offset == destination_offset) {
        if (source_offset != 0) {
            const head = object_length - source_offset;
            if (nbits <= head) {
                maskedTransfer(source, destination, nbits, head - nbits);
                nbits = 0;
            } else {
                const mask = lowMask(head);
                destination -= 1;
                source -= 1;
                destination[0] = (source[0] & mask) | (destination[0] & ~mask);
                nbits -= head;
            }
        }
        while (nbits >= object_length) : (nbits -= object_length) {
            destination -= 1;
            source -= 1;
            destination[0] = source[0];
        }
        if (nbits > 0) {
            maskedTransfer(source, destination, nbits, object_length - nbits);
        }
    } else if (source_offset < destination_offset) {
        const offset1 = destination_offset - source_offset;
        const offset2 = object_length - offset1;
        const head = object_length - destination_offset;
        if (nbits <= head) {
            const mask = anyMask(nbits, head - nbits);
            const dst = bitStringWordPtr(destination);
            dst.* = ((bitStringWord(source) >> @intCast(offset1)) & mask) | (dst.* & ~mask);
        } else {
            const mask1 = lowMask(offset1);
            const mask2 = lowMask(offset2);
            const mask = lowMask(head);
            destination -= 1;
            destination[0] = ((bitStringWord(source) >> @intCast(offset1)) & mask) | (destination[0] & ~mask);
            nbits -= head;
            while (nbits >= object_length) : (nbits -= object_length) {
                source -= 1;
                const i = (source[0] & mask1) << @intCast(offset2);
                destination -= 1;
                destination[0] = ((bitStringWord(source) >> @intCast(offset1)) & mask2) | i;
            }
            if (nbits > 0) {
                const dest_tail = bitStringWord(destination) & lowMask(object_length - nbits);
                if (nbits <= offset1) {
                    bitStringWordPtr(destination).* =
                        ((bitStringWord(source) & anyMask(nbits, offset1 - nbits)) << @intCast(offset2)) |
                        dest_tail;
                } else {
                    source -= 1;
                    const i = (source[0] & mask1) << @intCast(offset2);
                    const j = nbits - offset1;
                    bitStringWordPtr(destination).* =
                        ((bitStringWord(source) & anyMask(j, object_length - j)) >> @intCast(offset1)) |
                        i |
                        dest_tail;
                }
            }
        }
    } else {
        const offset1 = source_offset - destination_offset;
        const offset2 = object_length - offset1;
        const head = object_length - source_offset;
        if (nbits <= head) {
            const mask = anyMask(nbits, offset1 + (head - nbits));
            const dst = bitStringWordPtr(destination);
            dst.* = ((bitStringWord(source) << @intCast(offset1)) & mask) | (dst.* & ~mask);
        } else {
            const mask1 = lowMask(offset1);
            var dest_buffer: obj.SchemeObject = if ((head + offset1) < object_length)
                (bitStringWord(destination) & ~lowMask(head + offset1))
            else
                0;
            source -= 1;
            dest_buffer |= (source[0] & lowMask(head)) << @intCast(offset1);
            nbits -= head;
            while (nbits >= object_length) : (nbits -= object_length) {
                destination -= 1;
                destination[0] = dest_buffer | ((bitStringWord(source) >> @intCast(offset2)) & mask1);
                source -= 1;
                dest_buffer = source[0] << @intCast(offset1);
            }
            if (nbits == 0) {
                bitStringWordPtr(destination).* = dest_buffer | (bitStringWord(destination) & lowMask(offset1));
            } else if (nbits <= offset1) {
                bitStringWordPtr(destination).* =
                    dest_buffer |
                    (bitStringWord(destination) & lowMask(offset1 - nbits)) |
                    ((bitStringWord(source) >> @intCast(offset2)) & anyMask(nbits, offset1 - nbits));
            } else {
                destination -= 1;
                destination[0] = dest_buffer | ((bitStringWord(source) >> @intCast(offset2)) & mask1);
                nbits -= offset1;
                const mask = lowMask(object_length - nbits);
                const dst = bitStringWordPtr(destination);
                dst.* = (dst.* & mask) | ((bitStringWord(source) << @intCast(offset1)) & ~mask);
            }
        }
    }
}

// DEFINE_PRIMITIVE ("BIT-SUBSTRING-MOVE-RIGHT!", Prim_bit_substring_move_right_x, 5, 5,
//  "(SOURCE START1 END1 DESTINATION START2)\n\
// Destructively copies the substring of SOURCE between START1 and \
// END1 into DESTINATION at START2.  The copying is done from the \
// MSB to the LSB (which only matters when SOURCE and DESTINATION \
// are the same).")
pub export fn Prim_bit_substring_move_right_x() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    const bs1 = abi.argRef(1);
    const start1: usize = @intCast(abi.arg_nonnegative_integer(2));
    const end1: usize = @intCast(abi.arg_nonnegative_integer(3));
    abi.checkArg(4, obj.bitStringP);
    const bs2 = abi.argRef(4);
    const start2: usize = @intCast(abi.arg_nonnegative_integer(5));
    if (start1 > end1) abi.error_bad_range_arg(2);
    if (end1 > bitStringLength(bs1)) abi.error_bad_range_arg(3);
    const nbits = end1 - start1;
    const len2 = bitStringLength(bs2);
    if (start2 > len2 or nbits > (len2 - start2)) abi.error_bad_range_arg(5);
    if (nbits == 0) return obj.unspecific;

    const end2 = start2 + nbits;
    const end1_mod = end1 % object_length;
    const end2_mod = end2 % object_length;
    copyBits(
        obj.memoryLoc(bs1, bitStringIndexToWord(end1 - 1)),
        if (end1_mod == 0) 0 else object_length - end1_mod,
        obj.memoryLoc(bs2, bitStringIndexToWord(end2 - 1)),
        if (end2_mod == 0) 0 else object_length - end2_mod,
        nbits,
    );
    return obj.unspecific;
}

// Integer <-> Bit-string Conversions

inline fn ulongSignificantBits(number: usize) usize {
    return if (number == 0) 1 else bits.ulongLengthInBits(number);
}

fn zeroToBitString(length: usize) obj.SchemeObject {
    const result = allocate_bit_string(length);
    clear_bit_string(result);
    return result;
}

fn ulongToBitString(length: usize, number: usize) obj.SchemeObject {
    if (number == 0) return zeroToBitString(length);
    if (length < ulongSignificantBits(number)) abi.error_bad_range_arg(2);
    const result = zeroToBitString(length);
    bitStringWordPtr(obj.memoryLoc(result, bitStringIndexToWord(0))).* = number;
    return result;
}

fn btbsConsumer(result_ptr_raw: ?*anyopaque, digit: isize) callconv(.c) void {
    const ptr_slot: *[*]u8 = @ptrCast(@alignCast(result_ptr_raw.?));
    ptr_slot.*[0] = @truncate(@as(usize, @bitCast(digit)));
    ptr_slot.* += 1;
}

fn bignumToBitString(length: usize, bignum: obj.SchemeObject) obj.SchemeObject {
    return switch (@as(abi.BignumComparison, @fromBackingInt(@intCast(abi.bignum_test(bignum))))) {
        .equal => zeroToBitString(length),
        .less => abi.error_bad_range_arg(2),
        .greater => blk: {
            if (length == 0 or (length <= std.math.maxInt(isize) and abi.bignum_fits_in_word_p(bignum, @intCast(length), 0) == 0)) {
                abi.error_bad_range_arg(2);
            }
            const result = zeroToBitString(length);
            var result_ptr: [*]u8 = @ptrCast(bitStringLowPtr(result));
            abi.bignum_to_digit_stream(bignum, 1 << 8, &btbsConsumer, @ptrCast(&result_ptr));
            break :blk result;
        },
    };
}

const BitstrToBignumContext = struct {
    source_ptr: [*]u8,
    mask: u8,
};

fn bstbProducer(context_raw: ?*anyopaque) callconv(.c) c_uint {
    const c: *BitstrToBignumContext = @ptrCast(@alignCast(context_raw.?));
    c.source_ptr -= 1;
    const result: c_uint = @as(c_uint, c.mask & c.source_ptr[0]);
    c.mask = 0xff;
    return result;
}

fn bitStringToBignum(nbits: usize, bitstr: obj.SchemeObject) obj.SchemeObject {
    const ndigits = (nbits + 7) / 8;
    const word_bytes: usize = @sizeOf(obj.SchemeObject);
    var context = BitstrToBignumContext{
        .mask = @intCast(lowMask(((nbits - 1) % 8) + 1)),
        .source_ptr = @ptrCast(obj.memoryLoc(bitstr, bitStringIndexToWord(nbits - 1))),
    };
    if (ndigits != 0) {
        const skip = word_bytes - (((ndigits - 1) % word_bytes) + 1);
        context.source_ptr -= @as(usize, @intCast(skip));
    }
    return abi.digit_stream_to_bignum(@intCast(ndigits), &bstbProducer, &context, 1 << 8, 0);
}

// DEFINE_PRIMITIVE ("UNSIGNED-INTEGER->BIT-STRING", Prim_unsigned_to_bit_string, 2, 2,
//  "(LENGTH INTEGER)\n\
// INTEGER, which must be a non-negative integer, is converted to \
// a bit-string of length LENGTH.  If INTEGER is too large, an \
// error is signalled.")
pub export fn Prim_unsigned_to_bit_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const length = abi.arg_ulong_integer(1);
    const object = abi.argRef(2);
    if (obj.fixnumP(object)) {
        if (!obj.fixnumToUlongP(object)) abi.error_bad_range_arg(2);
        return ulongToBitString(length, obj.fixnumToUlong(object));
    }
    if (obj.bignumP(object)) {
        return bignumToBitString(length, object);
    }
    abi.error_wrong_type_arg(2);
}

// DEFINE_PRIMITIVE ("BIT-STRING->UNSIGNED-INTEGER", Prim_bit_string_to_unsigned, 1, 1,
//  "(BIT-STRING)\n\
// BIT-STRING is converted to the appropriate non-negative integer. \
// This operation is the inverse of `unsigned-integer->bit-string'.")
pub export fn Prim_bit_string_to_unsigned() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    const bit_string = abi.argRef(1);
    const total_words = obj.vectorLength(bit_string) - 1;
    if (total_words == 0) return obj.fixnum_zero;

    var scan = bitStringHighPtr(bit_string);
    const rem_bits = bitStringLength(bit_string) % object_length;
    var nwords = total_words;
    var word: obj.SchemeObject = 0;
    while (nwords > 0) : (nwords -= 1) {
        scan -= 1;
        word = if (nwords == total_words and rem_bits > 0)
            scan[0] & lowMask(rem_bits)
        else
            scan[0];
        if (word != 0) break;
    }
    if (nwords == 0) return obj.fixnum_zero;
    const nbits = (nwords - 1) * object_length + ulongSignificantBits(word);
    if (nbits <= obj.fixnum_length) {
        return obj.longToUnsignedFixnum(@intCast(word));
    }
    return bitStringToBignum(nbits, bit_string);
}

// DEFINE_PRIMITIVE ("READ-BITS!", Prim_read_bits_x, 3, 3,
//  "(POINTER OFFSET BIT-STRING)\n\
// Read the contents of memory at the address (POINTER,OFFSET) into BIT-STRING.")
pub export fn Prim_read_bits_x() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(3, obj.bitStringP);
    const bit_string = abi.argRef(3);
    const end = bitStringLength(bit_string);
    const offset: usize = @intCast(abi.arg_nonnegative_integer(2));
    if (end == 0) return obj.unspecific;

    const end_mod = end % object_length;
    const start = obj.memoryLoc(abi.argRef(1), @intCast(bitStringLengthToGcLength((offset + end) - 1)));
    const off_mod = (offset + end) % object_length;
    copyBits(
        start,
        if (off_mod == 0) 0 else object_length - off_mod,
        obj.memoryLoc(bit_string, bitStringIndexToWord(end - 1)),
        if (end_mod == 0) 0 else object_length - end_mod,
        end,
    );
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("WRITE-BITS!", Prim_write_bits_x, 3, 3,
//  "(POINTER OFFSET BIT-STRING)\n\
// Write the contents of BIT-STRING in memory at the address (POINTER,OFFSET).")
pub export fn Prim_write_bits_x() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(3, obj.bitStringP);
    const bit_string = abi.argRef(3);
    const end = bitStringLength(bit_string);
    const offset: usize = @intCast(abi.arg_nonnegative_integer(2));
    if (end == 0) return obj.unspecific;

    const end_mod = end % object_length;
    const start = obj.memoryLoc(abi.argRef(1), @intCast(bitStringLengthToGcLength((offset + end) - 1)));
    const off_mod = (offset + end) % object_length;
    copyBits(
        obj.memoryLoc(bit_string, bitStringIndexToWord(end - 1)),
        if (end_mod == 0) 0 else object_length - end_mod,
        start,
        if (off_mod == 0) 0 else object_length - off_mod,
        end,
    );
    return obj.unspecific;
}

// Search Primitives

// DEFINE_PRIMITIVE ("BIT-SUBSTRING-FIND-NEXT-SET-BIT", Prim_bitstr_find_next_set_bit, 3, 3,
//   "(BIT-STRING START END)")
pub export fn Prim_bitstr_find_next_set_bit() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.bitStringP);
    const bit_string = abi.argRef(1);
    const start: usize = @intCast(abi.arg_nonnegative_integer(2));
    const end: usize = @intCast(abi.arg_nonnegative_integer(3));
    if (end > bitStringLength(bit_string)) abi.error_bad_range_arg(3);
    if (start > end) abi.error_bad_range_arg(2);
    if (start == end) return obj.sharp_f;

    const start_w: usize = @intCast(start / object_length);
    const start_bit: u6 = @intCast(start % object_length);
    const end_m1 = end - 1;
    const end_w: usize = @intCast(end_m1 / object_length);
    const end_bit = (end_m1 % object_length) + 1;

    for (start_w..end_w + 1) |w| {
        var word = obj.memoryRef(bit_string, bit_string_first_word + w);
        if (w == start_w) word &= (~@as(obj.SchemeObject, 0)) << start_bit;
        if (w == end_w) word &= lowMask(end_bit);
        if (word != 0) {
            const idx = @as(usize, @intCast(w)) * object_length + @as(usize, @ctz(word));
            return obj.longToUnsignedFixnum(@intCast(idx));
        }
    }
    return obj.sharp_f;
}

test "bitstr allocation, excess MSB masking, copy_bits alignments, integer conversions, read/write, search" {
    const stubs = @import("test_stubs.zig");
    const artutl = @import("artutl.zig");
    stubs.resetMockRuntime();

    // 0-length bit-string
    stubs.setArgs(&.{ obj.ulongToFixnum(0), obj.sharp_f });
    const bs0 = Prim_make_bit_string();
    try std.testing.expect(obj.bitStringP(bs0));
    stubs.setArgs(&.{bs0});
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_bit_string_length());
    stubs.setArgs(&.{bs0});
    try std.testing.expectEqual(obj.sharp_t, Prim_bit_string_zero_p());
    stubs.setArgs(&.{bs0});
    try std.testing.expectEqual(obj.fixnum_zero, Prim_bit_string_to_unsigned());

    // Excess MSB bits above length must be ignored by zero?, =?, and ->unsigned
    stubs.setArgs(&.{ obj.ulongToFixnum(70), obj.sharp_t });
    const bs70 = Prim_make_bit_string();
    stubs.setArgs(&.{bs70});
    try std.testing.expectEqual(obj.sharp_f, Prim_bit_string_zero_p());
    // Set bit 75 directly in raw MSW past length 70; two copies with cleared low bits remain zero? and =?
    stubs.setArgs(&.{bs70});
    _ = Prim_bit_string_fill_x();
    stubs.setArgs(&.{ bs70, obj.sharp_f });
    _ = Prim_bit_string_fill_x();
    obj.memorySet(bs70, 3, ~@as(obj.SchemeObject, 0) << 6); // only bits >= 6 above bit 64 set (bits 70..127)
    stubs.setArgs(&.{bs70});
    try std.testing.expectEqual(obj.sharp_t, Prim_bit_string_zero_p());
    stubs.setArgs(&.{ obj.ulongToFixnum(70), obj.sharp_f });
    const bs70_clean = Prim_make_bit_string();
    stubs.setArgs(&.{ bs70, bs70_clean });
    try std.testing.expectEqual(obj.sharp_t, Prim_bit_string_equal_p());

    // Test copy_bits across equal, source < dest, source > dest, and exact word-boundary remainder (nbits == 0)
    stubs.setArgs(&.{ obj.ulongToFixnum(150), obj.sharp_f });
    const src = Prim_make_bit_string();
    const set_bits = [_]isize{ 0, 5, 63, 64, 65, 99, 127, 131, 149 };
    for (set_bits) |b| {
        bit_string_set(src, b, 1);
    }

    const src_offsets = [_]usize{ 0, 3, 17, 63, 64 };
    const dst_offsets = [_]usize{ 0, 5, 19, 63, 64 };
    const lengths = [_]usize{ 0, 1, 7, 45, 64, 70 };
    for (src_offsets) |so| {
        for (dst_offsets) |do| {
            for (lengths) |len| {
                if (so + len > 150 or do + len > 150) continue;
                stubs.setArgs(&.{ obj.ulongToFixnum(150), obj.sharp_f });
                const dst = Prim_make_bit_string();
                stubs.setArgs(&.{ src, obj.ulongToFixnum(so), obj.ulongToFixnum(so + len), dst, obj.ulongToFixnum(do) });
                _ = Prim_bit_substring_move_right_x();
                for (0..150) |k| {
                    stubs.setArgs(&.{ dst, obj.ulongToFixnum(k) });
                    const got = Prim_bit_string_ref();
                    if (k >= do and k < do + len) {
                        stubs.setArgs(&.{ src, obj.ulongToFixnum(so + (k - do)) });
                        try std.testing.expectEqual(Prim_bit_string_ref(), got);
                    } else {
                        try std.testing.expectEqual(obj.sharp_f, got);
                    }
                }
            }
        }
    }

    // Integer <-> bit-string round-trip across >57-bit bignum boundary
    const big_val = artutl.integer_add(
        artutl.integer_shift_left(obj.longToFixnum(0x5A5A_1234), 60),
        obj.longToFixnum(0xBEEF),
    );
    stubs.setArgs(&.{ obj.ulongToFixnum(100), big_val });
    const big_bs = Prim_unsigned_to_bit_string();
    stubs.setArgs(&.{big_bs});
    const rt_big = Prim_bit_string_to_unsigned();
    try std.testing.expect(artutl.integer_equal_p(big_val, rt_big));

    // Zero integer fast path on 130-bit zeroed bit-string
    stubs.setArgs(&.{ obj.ulongToFixnum(130), obj.sharp_f });
    const zero130 = Prim_make_bit_string();
    stubs.setArgs(&.{zero130});
    try std.testing.expectEqual(obj.fixnum_zero, Prim_bit_string_to_unsigned());

    // Find next set bit across word boundaries
    stubs.setArgs(&.{ src, obj.ulongToFixnum(6), obj.ulongToFixnum(65) });
    try std.testing.expectEqual(obj.ulongToFixnum(63), Prim_bitstr_find_next_set_bit());
    stubs.setArgs(&.{ src, obj.ulongToFixnum(132), obj.ulongToFixnum(149) });
    try std.testing.expectEqual(obj.sharp_f, Prim_bitstr_find_next_set_bit());

    // READ-BITS! / WRITE-BITS! round trip on raw backing buffer via non-marked vector pointer
    const backing = abi.allocate_vector(4, true);
    const dst_bits = allocate_bit_string(80);
    stubs.setArgs(&.{ backing, obj.ulongToFixnum(9), dst_bits });
    _ = Prim_write_bits_x(); // zero out slice [9..89)
    fill_bit_string(dst_bits, 1);
    stubs.setArgs(&.{ backing, obj.ulongToFixnum(9), dst_bits });
    _ = Prim_write_bits_x();
    clear_bit_string(dst_bits);
    stubs.setArgs(&.{ backing, obj.ulongToFixnum(9), dst_bits });
    _ = Prim_read_bits_x();
    stubs.setArgs(&.{ obj.ulongToFixnum(80), obj.sharp_t });
    const all_ones80 = Prim_make_bit_string();
    stubs.setArgs(&.{ dst_bits, all_ones80 });
    try std.testing.expectEqual(obj.sharp_t, Prim_bit_string_equal_p());
}
