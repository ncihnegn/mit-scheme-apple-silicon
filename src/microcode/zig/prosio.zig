// Derived from MIT/GNU Scheme C sources (`src/microcode/prosio.c`, `src/microcode/osio.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const boot = @import("boot.zig");
const string = @import("string.zig");

pub export fn arg_to_channel(argument: obj.SchemeObject, arg_number: c_int) callconv(.c) abi.Tchannel {
    _ = argument;
    const channel = abi.arg_ulong_integer(arg_number);
    if (channel >= abi.OS_channel_table_size) {
        abi.error_wrong_type_arg(arg_number);
    }
    return @intCast(channel);
}

pub export fn arg_channel(arg_number: c_int) callconv(.c) abi.Tchannel {
    const channel = arg_to_channel(abi.argRef(@intCast(arg_number)), arg_number);
    if (abi.OS_channel_open_p(channel) == 0) {
        abi.error_bad_range_arg(arg_number);
    }
    return channel;
}

// DEFINE_PRIMITIVE ("CHANNEL-CLOSE", Prim_channel_close, 1, 1,
//   "Close file CHANNEL-NUMBER.")
pub export fn Prim_channel_close() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const channel = arg_to_channel(abi.argRef(1), 1);
    if (abi.OS_channel_open_p(channel) != 0) {
        abi.OS_channel_close(channel);
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CHANNEL-SYNCHRONIZE", Prim_channel_synchronize, 1, 1,
//   "(CHANNEL)\n\
// Synchronize CHANNEL with any permanent storage associated with it,\n\
// forcing any buffered data to be written permanently.")
pub export fn Prim_channel_synchronize() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_channel_synchronize(arg_channel(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CHANNEL-TABLE", Prim_channel_table, 0, 0,
//   "Return a vector of all channels in the channel table.")
pub export fn Prim_channel_table() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    for (0..abi.OS_channel_table_size) |ch_u| {
        const channel: abi.Tchannel = @intCast(ch_u);
        if (abi.OS_channel_open_p(channel) != 0) {
            boot.scratch_obstack.grow(std.mem.asBytes(&channel));
        }
    }
    const n_channels = boot.scratch_obstack.objectSize() / @sizeOf(abi.Tchannel);
    if (n_channels == 0) {
        return obj.sharp_f;
    }
    const raw = boot.scratch_obstack.finish();
    const channels: [*]const abi.Tchannel = @ptrCast(@alignCast(raw));
    const vector = abi.allocate_vector(@intCast(n_channels), true);
    const vec_loc = obj.vectorLoc(vector, 0);
    for (0..n_channels) |idx| {
        vec_loc[idx] = abi.long_to_integer(@intCast(channels[idx]));
    }
    boot.scratch_obstack.freeObj(@ptrCast(raw));
    return vector;
}

// DEFINE_PRIMITIVE ("CHANNEL-TYPE", Prim_channel_type, 1, 1,
//   "Return (as a nonnegative integer) the type of CHANNEL.")
pub export fn Prim_channel_type() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_channel_type(arg_channel(1))));
}

// Must match definition of `enum channel_type' in "osio.h" (same 17-entry table as prosio.c).
const channel_type_names = [_][*:0]const u8{
    "unknown",
    "file",
    "unix-pipe",
    "unix-fifo",
    "terminal",
    "unix-pty-master",
    "unix-stream-socket",
    "tcp-stream-socket",
    "tcp-server-socket",
    "directory",
    "unix-character-device",
    "unix-block-device",
    "unknown",
    "unknown",
    "unknown",
    "win32-anonymous-pipe",
    "win32-named-pipe",
};

// DEFINE_PRIMITIVE ("CHANNEL-TYPE-NAME", Prim_channel_type_name, 1, 1,
//   "Return (as a string) the type of CHANNEL.")
pub export fn Prim_channel_type_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ch_type = abi.OS_channel_type(arg_channel(1));
    if (ch_type == @backingInt(abi.ChannelType.unknown)) {
        return obj.sharp_f;
    }
    const index: usize = @intCast(ch_type);
    if (index >= channel_type_names.len) {
        return obj.sharp_f;
    }
    return string.char_pointer_to_string(channel_type_names[index]);
}

// DEFINE_PRIMITIVE ("CHANNEL-READ", Prim_channel_read, 4, 4,
//   "Read characters from CHANNEL, storing them in STRING.\n\
// Third and fourth args START and END specify the substring to use.\n\
// Attempt to fill that substring unless end-of-file is reached.\n\
// Return the number of characters actually read from CHANNEL.")
pub export fn Prim_channel_read() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var length: usize = undefined;
    const buffer = abi.arg_extended_string(2, &length);
    const end = abi.arg_ulong_index_integer(4, length + 1);
    const start = abi.arg_ulong_index_integer(3, end + 1);
    const nread = abi.OS_channel_read(
        arg_channel(1),
        @ptrCast(buffer + @as(usize, @intCast(start))),
        @intCast(end - start),
    );
    return if (nread < 0) obj.sharp_f else abi.long_to_integer(nread);
}

// DEFINE_PRIMITIVE ("CHANNEL-WRITE", Prim_channel_write, 4, 4,
//   "Write characters to CHANNEL, reading them from STRING.\n\
// Third and fourth args START and END specify the substring to use.")
pub export fn Prim_channel_write() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    var length: usize = undefined;
    const buffer = abi.arg_extended_string(2, &length);
    const end = abi.arg_ulong_index_integer(4, length + 1);
    const start = abi.arg_ulong_index_integer(3, end + 1);
    const nwritten = abi.OS_channel_write(
        arg_channel(1),
        @ptrCast(buffer + @as(usize, @intCast(start))),
        @intCast(end - start),
    );
    return if (nwritten < 0) obj.sharp_f else abi.long_to_integer(nwritten);
}

// DEFINE_PRIMITIVE ("CHANNEL-BLOCKING?", Prim_channel_blocking_p, 1, 1,
//   "Return #F iff CHANNEL is in non-blocking mode.\n\
// Otherwise, CHANNEL is in blocking mode.\n\
// If CHANNEL can be put in non-blocking mode, #T is returned.\n\
// If it cannot, 0 is returned.")
pub export fn Prim_channel_blocking_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.OS_channel_nonblocking_p(arg_channel(1));
    return if (result < 0) obj.ulongToFixnum(0) else obj.booleanToObject(result == 0);
}

// DEFINE_PRIMITIVE ("CHANNEL-NONBLOCKING", Prim_channel_nonblocking, 1, 1,
//   "Put CHANNEL in non-blocking mode.")
pub export fn Prim_channel_nonblocking() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_channel_nonblocking(arg_channel(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CHANNEL-BLOCKING", Prim_channel_blocking, 1, 1,
//   "Put CHANNEL in blocking mode.")
pub export fn Prim_channel_blocking() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_channel_blocking(arg_channel(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("MAKE-PIPE", Prim_make_pipe, 0, 0,
//   "Return a cons of two channels, the reader and writer of a pipe.")
pub export fn Prim_make_pipe() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.cons(obj.sharp_f, obj.sharp_f);
    var reader: abi.Tchannel = undefined;
    var writer: abi.Tchannel = undefined;
    abi.OS_make_pipe(&reader, &writer);
    obj.setPairCar(result, abi.long_to_integer(@intCast(reader)));
    obj.setPairCdr(result, abi.long_to_integer(@intCast(writer)));
    return result;
}

// DEFINE_PRIMITIVE ("NEW-MAKE-PIPE", Prim_new_make_pipe, 2, 2,
//   "Store the reader and writer of a new pipe in the cdrs of weak pairs.")
pub export fn Prim_new_make_pipe() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.weakPairP);
    abi.checkArg(2, obj.weakPairP);
    var reader: abi.Tchannel = undefined;
    var writer: abi.Tchannel = undefined;
    abi.OS_make_pipe(&reader, &writer);
    obj.setPairCdr(abi.argRef(1), abi.long_to_integer(@intCast(reader)));
    obj.setPairCdr(abi.argRef(2), abi.long_to_integer(@intCast(writer)));
    return obj.unspecific;
}

fn argSelectRegistry(arg_number: c_int) abi.SelectRegistry {
    const val = abi.arg_ulong_integer(arg_number);
    return @ptrFromInt(@as(usize, @intCast(val)));
}

fn argSrMode(arg_number: c_int) c_uint {
    const n = abi.arg_ulong_integer(arg_number);
    if (n < 1 or n > 3) {
        abi.error_bad_range_arg(arg_number);
    }
    return @intCast(n);
}

// DEFINE_PRIMITIVE ("HAVE-SELECT?", Prim_have_select_p, 0, 0, 0)
pub export fn Prim_have_select_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.OS_have_select_p != 0);
}

// DEFINE_PRIMITIVE ("ALLOCATE-SELECT-REGISTRY", Prim_alloc_selreg, 0, 0, 0)
pub export fn Prim_alloc_selreg() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.ulong_to_integer(@intCast(@intFromPtr(abi.OS_allocate_select_registry())));
}

// DEFINE_PRIMITIVE ("DEALLOCATE-SELECT-REGISTRY", Prim_dealloc_selreg, 1, 1, 0)
pub export fn Prim_dealloc_selreg() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_deallocate_select_registry(argSelectRegistry(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("ADD-TO-SELECT-REGISTRY", Prim_add_to_selreg, 3, 3, 0)
pub export fn Prim_add_to_selreg() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_add_to_select_registry(argSelectRegistry(1), @intCast(abi.arg_nonnegative_integer(2)), argSrMode(3));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("REMOVE-FROM-SELECT-REGISTRY", Prim_rem_from_selreg, 3, 3, 0)
pub export fn Prim_rem_from_selreg() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_remove_from_select_registry(argSelectRegistry(1), @intCast(abi.arg_nonnegative_integer(2)), argSrMode(3));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("SELECT-REGISTRY-LENGTH", Prim_selreg_length, 1, 1, 0)
pub export fn Prim_selreg_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.ulong_to_integer(@intCast(abi.OS_select_registry_length(argSelectRegistry(1))));
}

// DEFINE_PRIMITIVE ("TEST-SELECT-REGISTRY", Prim_test_selreg, 4, 4, 0)
pub export fn Prim_test_selreg() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const r = argSelectRegistry(1);
    const rl = abi.OS_select_registry_length(r);
    const blockp = abi.booleanArg(2);
    const vfd = abi.vectorArg(3);
    const vmode = abi.vectorArg(4);
    if (obj.vectorLength(vfd) < rl) abi.error_bad_range_arg(3);
    if (obj.vectorLength(vmode) < rl) abi.error_bad_range_arg(4);
    const result = if (rl == 0)
        abi.OS_pause(blockp, false)
    else
        abi.OS_test_select_registry(r, @intFromBool(blockp));
    if (result > 0) {
        var iv: usize = 0;
        for (0..rl) |i_u| {
            const i: c_uint = @intCast(i_u);
            var fd: c_int = undefined;
            var mode: c_uint = undefined;
            abi.OS_select_registry_result(r, i, &fd, &mode);
            if (mode > 0) {
                obj.vectorSet(vfd, @intCast(iv), abi.long_to_integer(fd));
                obj.vectorSet(vmode, @intCast(iv), abi.ulong_to_integer(@intCast(mode)));
                iv += 1;
            }
        }
    }
    return abi.long_to_integer(result);
}

// DEFINE_PRIMITIVE ("TEST-SELECT-DESCRIPTOR", Prim_test_sel_desc, 3, 3, 0)
pub export fn Prim_test_sel_desc() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(abi.OS_test_select_descriptor(
        @intCast(abi.arg_nonnegative_integer(1)),
        @intFromBool(abi.booleanArg(2)),
        argSrMode(3),
    ));
}

test "prosio channel, pipe, table, and select registry primitives" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();
    boot.scratch_obstack.init(&boot.obstack_chunk_alloc, &std.c.free);
    defer boot.scratch_obstack.freeObj(null);

    // Open channel 2 and check CHANNEL-TYPE / CHANNEL-TYPE-NAME / CHANNEL-BLOCKING?
    stubs.setMockChannel(2, @backingInt(abi.ChannelType.file), false);
    stubs.setArgs(&.{obj.ulongToFixnum(2)});
    try std.testing.expectEqual(@backingInt(abi.ChannelType.file), obj.fixnumToLong(Prim_channel_type()));
    const type_name = Prim_channel_type_name();
    try std.testing.expectEqualStrings("file", obj.legacyStringData(type_name)[0..obj.legacyStringLength(type_name)]);
    try std.testing.expectEqual(obj.sharp_t, Prim_channel_blocking_p());
    _ = Prim_channel_nonblocking();
    try std.testing.expectEqual(obj.sharp_f, Prim_channel_blocking_p());
    _ = Prim_channel_blocking();
    try std.testing.expectEqual(obj.sharp_t, Prim_channel_blocking_p());
    _ = Prim_channel_synchronize();

    // Unknown channel type returns #F for CHANNEL-TYPE-NAME
    stubs.setMockChannel(4, @backingInt(abi.ChannelType.unknown), false);
    stubs.setArgs(&.{obj.ulongToFixnum(4)});
    try std.testing.expectEqual(obj.sharp_f, Prim_channel_type_name());

    // CHANNEL-TABLE lists open channels (2 and 4)
    stubs.setArgs(&.{});
    const tbl = Prim_channel_table();
    try std.testing.expectEqual(@as(usize, 2), obj.vectorLength(tbl));
    try std.testing.expectEqual(obj.ulongToFixnum(2), obj.vectorRef(tbl, 0));
    try std.testing.expectEqual(obj.ulongToFixnum(4), obj.vectorRef(tbl, 1));

    // CHANNEL-WRITE and CHANNEL-READ slice bounds
    const s = string.char_pointer_to_string("hello");
    stubs.setArgs(&.{ obj.ulongToFixnum(2), s, obj.ulongToFixnum(1), obj.ulongToFixnum(4) });
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_channel_write());
    try std.testing.expectEqualStrings("ell", stubs.mock_channel_buf[0..3]);

    const rbuf = string.char_pointer_to_string("xxxxx");
    stubs.setArgs(&.{ obj.ulongToFixnum(2), rbuf, obj.ulongToFixnum(1), obj.ulongToFixnum(4) });
    try std.testing.expectEqual(obj.ulongToFixnum(3), Prim_channel_read());
    try std.testing.expectEqualStrings("xellx", obj.legacyStringData(rbuf)[0..5]);

    // CHANNEL-CLOSE marks closed
    stubs.setArgs(&.{obj.ulongToFixnum(2)});
    _ = Prim_channel_close();
    stubs.setArgs(&.{obj.ulongToFixnum(4)});
    _ = Prim_channel_close();

    // MAKE-PIPE and NEW-MAKE-PIPE
    stubs.setArgs(&.{});
    const pipe_pair = Prim_make_pipe();
    const r_ch = obj.fixnumToUlong(obj.pairCar(pipe_pair));
    const w_ch = obj.fixnumToUlong(obj.pairCdr(pipe_pair));
    try std.testing.expect(r_ch != w_ch);

    const wc1 = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    const wc2 = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ wc1, wc2 });
    try std.testing.expectEqual(obj.unspecific, Prim_new_make_pipe());
    try std.testing.expect(obj.fixnumP(obj.pairCdr(wc1)));
    try std.testing.expect(obj.fixnumP(obj.pairCdr(wc2)));

    // Select registry primitives
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.sharp_t, Prim_have_select_p());
    const reg = Prim_alloc_selreg();
    stubs.setArgs(&.{ reg, obj.ulongToFixnum(7), obj.ulongToFixnum(1) });
    _ = Prim_add_to_selreg();
    stubs.setArgs(&.{reg});
    try std.testing.expectEqual(obj.ulongToFixnum(1), Prim_selreg_length());

    const vfd = abi.allocate_vector(2, true);
    const vmode = abi.allocate_vector(2, true);
    stubs.setArgs(&.{ reg, obj.sharp_f, vfd, vmode });
    try std.testing.expectEqual(obj.ulongToFixnum(1), Prim_test_selreg());
    try std.testing.expectEqual(obj.ulongToFixnum(7), obj.vectorRef(vfd, 0));
    try std.testing.expectEqual(obj.ulongToFixnum(1), obj.vectorRef(vmode, 0));

    stubs.setArgs(&.{ reg, obj.ulongToFixnum(7), obj.ulongToFixnum(1) });
    _ = Prim_rem_from_selreg();
    stubs.setArgs(&.{reg});
    try std.testing.expectEqual(obj.ulongToFixnum(0), Prim_selreg_length());
    _ = Prim_dealloc_selreg();

    stubs.setArgs(&.{ obj.ulongToFixnum(7), obj.sharp_t, obj.ulongToFixnum(2) });
    try std.testing.expectEqual(obj.ulongToFixnum(2), Prim_test_sel_desc());
}
