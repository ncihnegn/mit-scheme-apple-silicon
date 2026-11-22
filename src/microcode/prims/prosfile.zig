// Derived from MIT/GNU Scheme C sources (`src/microcode/prosfile.c`, `src/microcode/osfile.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const artutl = @import("../arith/artutl.zig");
const string = @import("../data/string.zig");

const OpenFileFn = *const fn ([*:0]const u8) callconv(.c) abi.Tchannel;

inline fn newOpenFilePrimitive(comptime open_fn: OpenFileFn) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.weakPairP);
    const channel = open_fn(abi.stringArg(1));
    obj.setPairCdr(abi.argRef(2), abi.long_to_integer(@intCast(channel)));
    return obj.sharp_t;
}

inline fn openFilePrimitive(comptime open_fn: OpenFileFn) obj.SchemeObject {
    abi.primitiveHeader();
    const channel = open_fn(abi.stringArg(1));
    return abi.long_to_integer(@intCast(channel));
}

// DEFINE_PRIMITIVE ("NEW-FILE-OPEN-INPUT-CHANNEL",
//                   Prim_new_file_open_input_channel, 2, 2,
//   "Open an input file called FILENAME.\n\
// The channel number is saved in the cdr of WEAK-PAIR.")
pub export fn Prim_new_file_open_input_channel() callconv(.c) obj.SchemeObject {
    return newOpenFilePrimitive(&abi.OS_open_input_file);
}

// DEFINE_PRIMITIVE ("NEW-FILE-OPEN-OUTPUT-CHANNEL",
//                   Prim_new_file_open_output_channel, 2, 2,
//   "Open an output file called FILENAME.\n\
// The channel number is saved in the cdr of WEAK-PAIR.\n\
// If the file exists, it is rewritten.")
pub export fn Prim_new_file_open_output_channel() callconv(.c) obj.SchemeObject {
    return newOpenFilePrimitive(&abi.OS_open_output_file);
}

// DEFINE_PRIMITIVE ("NEW-FILE-OPEN-EXCLUSIVE-OUTPUT-CHANNEL",
//                   Prim_new_file_open_exclusive_output_channel, 2, 2,
//   "Open an output file called FILENAME.\n\
// The channel number is saved in the cdr of WEAK-PAIR.\n\
// If the file exists, an error is signalled.")
pub export fn Prim_new_file_open_exclusive_output_channel() callconv(.c) obj.SchemeObject {
    return newOpenFilePrimitive(&abi.OS_open_exclusive_output_file);
}

// DEFINE_PRIMITIVE ("NEW-FILE-OPEN-IO-CHANNEL", Prim_new_file_open_io_channel,
//                   2, 2,
//   "Open a file called FILENAME.\n\
// The channel number is saved in the cdr of WEAK-PAIR.\n\
// The file is opened for both input and output.\n\
// If the file exists, its contents are not disturbed.")
pub export fn Prim_new_file_open_io_channel() callconv(.c) obj.SchemeObject {
    return newOpenFilePrimitive(&abi.OS_open_io_file);
}

// DEFINE_PRIMITIVE ("NEW-FILE-OPEN-APPEND-CHANNEL",
//                   Prim_new_file_open_append_channel, 2, 2,
//   "Open an output file called FILENAME.\n\
// The channel number is saved in the cdr of WEAK-PAIR.\n\
// If the file exists, output is appended to its contents.")
pub export fn Prim_new_file_open_append_channel() callconv(.c) obj.SchemeObject {
    return newOpenFilePrimitive(&abi.OS_open_append_file);
}

// DEFINE_PRIMITIVE ("FILE-OPEN-INPUT-CHANNEL", Prim_file_open_input_channel,
//                   1, 1,
//   "Open an input file called FILENAME, returning a channel number.")
pub export fn Prim_file_open_input_channel() callconv(.c) obj.SchemeObject {
    return openFilePrimitive(&abi.OS_open_input_file);
}

// DEFINE_PRIMITIVE ("FILE-OPEN-OUTPUT-CHANNEL", Prim_file_open_output_channel,
//                   1, 1,
//   "Open an output file called FILENAME, returning a channel number.\n\
// If the file exists, it is rewritten.")
pub export fn Prim_file_open_output_channel() callconv(.c) obj.SchemeObject {
    return openFilePrimitive(&abi.OS_open_output_file);
}

// DEFINE_PRIMITIVE ("FILE-OPEN-EXCLUSIVE-OUTPUT-CHANNEL",
//                   Prim_file_open_exclusive_output_channel, 2, 2,
//   "Open an output file called FILENAME, returning a channel number.\n\
// If the file exists, an error is signalled.")
pub export fn Prim_file_open_exclusive_output_channel() callconv(.c) obj.SchemeObject {
    return openFilePrimitive(&abi.OS_open_exclusive_output_file);
}

// DEFINE_PRIMITIVE ("FILE-OPEN-IO-CHANNEL", Prim_file_open_io_channel, 1, 1,
//   "Open a file called FILENAME, returning a channel number.\n\
// The file is opened for both input and output.\n\
// If the file exists, its contents are not disturbed.")
pub export fn Prim_file_open_io_channel() callconv(.c) obj.SchemeObject {
    return openFilePrimitive(&abi.OS_open_io_file);
}

// DEFINE_PRIMITIVE ("FILE-OPEN-APPEND-CHANNEL", Prim_file_open_append_channel,
//                   1, 1,
//   "Open an output file called FILENAME, returning a channel number.\n\
// If the file exists, output is appended to its contents.")
pub export fn Prim_file_open_append_channel() callconv(.c) obj.SchemeObject {
    return openFilePrimitive(&abi.OS_open_append_file);
}

// DEFINE_PRIMITIVE ("FILE-LENGTH-NEW", Prim_file_length_new, 1, 1,
//   "Return the length of CHANNEL in characters.")
pub export fn Prim_file_length_new() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.intmax_to_integer(@intCast(abi.OS_file_length(abi.arg_channel(1))));
}

// DEFINE_PRIMITIVE ("FILE-POSITION", Prim_file_position, 1, 1,
//   "Return the position of CHANNEL's file-pointer.\n\
// This is a non-negative number strictly less than the file's length.")
pub export fn Prim_file_position() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.intmax_to_integer(@intCast(abi.OS_file_position(abi.arg_channel(1))));
}

// DEFINE_PRIMITIVE ("FILE-SET-POSITION", Prim_file_set_position, 2, 2,
//   "Set the file-pointer of CHANNEL to POSITION.\n\
// POSITION must be a non-negative number strictly less than the file's length.")
pub export fn Prim_file_set_position() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_set_position(abi.arg_channel(1), @intCast(abi.arg_index_integer_to_intmax(2, abi.off_t_max)));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("FILE-TRUNCATE", Prim_file_truncate, 2, 2,
//   "Set the length of CHANNEL to LENGTH.\n\
// LENGTH must be a non-negative number.")
pub export fn Prim_file_truncate() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_file_truncate(abi.arg_channel(1), @intCast(abi.arg_index_integer_to_intmax(2, abi.off_t_max)));
    return obj.unspecific;
}

test "prosfile open, length, position, set-position, and truncate primitives" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    const fname = string.char_pointer_to_string("/tmp/mock-file.dat");
    const wc = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ fname, wc });
    try std.testing.expectEqual(obj.sharp_t, Prim_new_file_open_input_channel());
    const ch = obj.pairCdr(wc);
    try std.testing.expect(obj.fixnumP(ch));

    stubs.setArgs(&.{ fname, wc });
    _ = Prim_new_file_open_output_channel();
    stubs.setArgs(&.{ fname, wc });
    _ = Prim_new_file_open_exclusive_output_channel();
    stubs.setArgs(&.{ fname, wc });
    _ = Prim_new_file_open_io_channel();
    stubs.setArgs(&.{ fname, wc });
    _ = Prim_new_file_open_append_channel();

    stubs.setArgs(&.{fname});
    const ch1 = Prim_file_open_input_channel();
    _ = Prim_file_open_output_channel();
    stubs.setArgs(&.{ fname, obj.sharp_f });
    _ = Prim_file_open_exclusive_output_channel();
    stubs.setArgs(&.{fname});
    _ = Prim_file_open_io_channel();
    _ = Prim_file_open_append_channel();

    stubs.setMockFileMetrics(@intCast(obj.fixnumToUlong(ch1)), 128, 0);
    stubs.setArgs(&.{ch1});
    try std.testing.expectEqual(obj.ulongToFixnum(128), Prim_file_length_new());
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_file_position());

    stubs.setArgs(&.{ ch1, obj.ulongToFixnum(64) });
    try std.testing.expectEqual(obj.unspecific, Prim_file_set_position());
    stubs.setArgs(&.{ch1});
    try std.testing.expectEqual(obj.ulongToFixnum(64), Prim_file_position());

    stubs.setArgs(&.{ ch1, obj.ulongToFixnum(32) });
    try std.testing.expectEqual(obj.unspecific, Prim_file_truncate());
    stubs.setArgs(&.{ch1});
    try std.testing.expectEqual(obj.ulongToFixnum(32), Prim_file_length_new());
}
