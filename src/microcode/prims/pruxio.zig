// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxio.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const wind = @import("../support/wind.zig");
const string = @import("../data/string.zig");
const prosproc = @import("prosproc.zig");

// DEFINE_PRIMITIVE ("CHANNEL-DESCRIPTOR", Prim_channel_descriptor, 1, 1, 0)
pub export fn Prim_channel_descriptor() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(abi.UX_channel_descriptor(abi.arg_channel(1)));
}

// DEFINE_PRIMITIVE ("UX-MAKE-SUBPROCESS", Prim_UX_make_subprocess, 8, 8,
//   "(FILENAME ARGV ENV WORK-DIR STDIN STDOUT STDERR)\n\
// Create a subprocess.\n\
// FILENAME is the program to run.\n\
// ARGV is a vector of strings to pass to the program as arguments.\n\
// ENV is a vector of strings to pass as the program's environment;\n\
//   #F means inherit Scheme's environment.\n\
// WORK-DIR is a string to pass as the program's working directory;\n\
//   #F means inherit Scheme's working directory.\n\
// CTTY specifies the program's controlling terminal:\n\
//   #F means none;\n\
//   -1 means use Scheme's controlling terminal in background;\n\
//   -2 means use Scheme's controlling terminal in foreground;\n\
//   string means open that terminal.\n\
// STDIN is the input channel for the subprocess.\n\
// STDOUT is the output channel for the subprocess.\n\
// STDERR is the error channel for the subprocess.\n\
//   Each channel arg can take these values:\n\
//   #F means none;\n\
//   -1 means use the corresponding channel from Scheme;\n\
//   -2 means use the controlling terminal (valid only when CTTY is a string);\n\
//   otherwise the argument must be a channel.")
pub export fn Prim_UX_make_subprocess() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const position = wind.dstack_position;
    const filename = abi.stringArg(1);
    const argv = prosproc.stringVectorArg(2);
    const env = if (abi.argRef(3) == obj.sharp_f) null else prosproc.stringVectorArg(3);
    const working_directory: ?[*:0]const u8 = if (abi.argRef(4) == obj.sharp_f) null else abi.stringArg(4);

    var ctty_type: abi.ProcessCttyType = undefined;
    var ctty_name: ?[*:0]u8 = null;
    const ctty_arg = abi.argRef(5);
    if (ctty_arg == obj.sharp_f) {
        ctty_type = .none;
    } else if (ctty_arg == obj.longToFixnum(-1)) {
        ctty_type = .inherit_bg;
    } else if (ctty_arg == obj.longToFixnum(-2)) {
        ctty_type = .inherit_fg;
    } else {
        ctty_type = .explicit;
        ctty_name = abi.stringArg(5);
    }

    const cin = prosproc.processChannelArg(6, ctty_type);
    const cout = prosproc.processChannelArg(7, ctty_type);
    const cerr = prosproc.processChannelArg(8, ctty_type);

    const process = abi.OS_make_subprocess(
        filename,
        argv,
        env,
        working_directory,
        ctty_type,
        ctty_name,
        cin.channel_type,
        cin.channel,
        cout.channel_type,
        cout.channel,
        cerr.channel_type,
        cerr.channel,
    );
    wind.dstack_set_position(position);
    return abi.long_to_integer(@intCast(process));
}

test "pruxio channel-descriptor and ux-make-subprocess" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    wind.dstack_initialize();
    defer wind.dstack_reset();
    defer stubs.resetMockRuntime();

    stubs.setMockChannel(2, @backingInt(abi.ChannelType.unix_pipe), false);
    stubs.setArgs(&.{obj.ulongToFixnum(2)});
    try std.testing.expectEqual(obj.longToFixnum(12), Prim_channel_descriptor());

    const prog = string.char_pointer_to_string("/bin/true");
    const argv_vec = abi.allocate_vector(1, true);
    obj.vectorSet(argv_vec, 0, prog);
    const env_vec = abi.allocate_vector(1, true);
    obj.vectorSet(env_vec, 0, string.char_pointer_to_string("PATH=/bin"));
    const wdir = string.char_pointer_to_string("/tmp");
    const ctty = string.char_pointer_to_string("/dev/ttyp0");

    stubs.setArgs(&.{
        prog,
        argv_vec,
        env_vec,
        wdir,
        ctty,
        obj.longToFixnum(-2),
        obj.ulongToFixnum(2),
        obj.sharp_f,
    });
    const pidx = Prim_UX_make_subprocess();
    try std.testing.expectEqual(obj.ulongToFixnum(0), pidx);
}
