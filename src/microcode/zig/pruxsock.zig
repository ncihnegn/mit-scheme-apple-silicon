// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxsock.c`, `src/microcode/uxsock.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");
const utils = @import("utils.zig");

fn argHost(arg: c_int) ?*anyopaque {
    abi.checkArg(arg, abi.string_p);
    const val = abi.argRef(@intCast(arg));
    if (obj.legacyStringLength(val) != abi.OS_host_address_length()) {
        abi.error_bad_range_arg(arg);
    }
    return @ptrCast(obj.legacyStringData(val));
}

fn argClientSocket(arg: c_int) abi.Tchannel {
    const raw = abi.arg_ulong_integer(arg);
    if (raw > std.math.maxInt(abi.Tchannel)) {
        abi.error_bad_range_arg(arg);
    }
    const socket: abi.Tchannel = @intCast(raw);
    const ch_type = abi.OS_channel_type(socket);
    if (ch_type != @intFromEnum(abi.ChannelType.tcp_stream_socket) and
        ch_type != @intFromEnum(abi.ChannelType.unix_stream_socket))
    {
        abi.error_bad_range_arg(arg);
    }
    return socket;
}

fn argServerSocket(arg: c_int, expected_type: abi.ChannelType) abi.Tchannel {
    const raw = abi.arg_nonnegative_integer(arg);
    if (raw > std.math.maxInt(abi.Tchannel)) {
        abi.error_bad_range_arg(arg);
    }
    const server_socket: abi.Tchannel = @intCast(raw);
    if (abi.OS_channel_type(server_socket) != @intFromEnum(expected_type)) {
        abi.error_bad_range_arg(arg);
    }
    return server_socket;
}

fn argTcpServerSocket(arg: c_int) abi.Tchannel {
    return argServerSocket(arg, .tcp_server_socket);
}

fn argUnixServerSocket(arg: c_int) abi.Tchannel {
    return argServerSocket(arg, .unix_server_socket);
}

fn stringAndFree(host_name_opt: ?[*:0]const u8) obj.SchemeObject {
    const host_name = host_name_opt orelse return obj.sharp_f;
    const result = string.char_pointer_to_string(host_name);
    abi.OS_free(@constCast(@ptrCast(host_name)));
    return result;
}

// DEFINE_PRIMITIVE ("GET-SERVICE-BY-NAME", Prim_get_service_by_name, 2, 2,
//   "Given SERVICE-NAME and PROTOCOL-NAME, return a port number.\n\
// The result is a nonnegative integer, or #F if no such service exists.")
pub export fn Prim_get_service_by_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.OS_get_service_by_name(abi.stringArg(1), abi.stringArg(2));
    return if (result < 0) obj.sharp_f else abi.long_to_integer(result);
}

// DEFINE_PRIMITIVE ("GET-SERVICE-BY-NUMBER", Prim_get_service_by_number, 1, 1,
//   "Given PORT-NUMBER, return it in the network encoding.")
pub export fn Prim_get_service_by_number() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.ulong_to_integer(abi.OS_get_service_by_number(abi.arg_ulong_integer(1)));
}

// DEFINE_PRIMITIVE ("HOST-ADDRESS-LENGTH", Prim_host_address_length, 0, 0,
//   "The length of a host address string, in characters.")
pub export fn Prim_host_address_length() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_host_address_length()));
}

// DEFINE_PRIMITIVE ("GET-HOST-BY-NAME", Prim_get_host_by_name, 1, 1,
//   "Given HOST-NAME, return its internet host numbers.\n\
// The result is a vector of strings, or #F if no such host exists.")
pub export fn Prim_get_host_by_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const addresses = abi.OS_get_host_by_name(abi.stringArg(1)) orelse return obj.sharp_f;
    var count: usize = 0;
    while (addresses[count] != null) : (count += 1) {}
    const result = abi.allocate_vector(@intCast(count), true);
    const scan_result = obj.vectorLoc(result, 0);
    const length = abi.OS_host_address_length();
    for (0..count) |i| {
        scan_result[i] = string.memory_to_string(length, addresses[i]);
    }
    return result;
}

// DEFINE_PRIMITIVE ("GET-HOST-NAME", Prim_get_host_name, 0, 0, 0)
pub export fn Prim_get_host_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return stringAndFree(abi.OS_get_host_name());
}

// DEFINE_PRIMITIVE ("CANONICAL-HOST-NAME", Prim_canonical_host_name, 1, 1, 0)
pub export fn Prim_canonical_host_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return stringAndFree(abi.OS_canonical_host_name(abi.stringArg(1)));
}

// DEFINE_PRIMITIVE ("GET-HOST-BY-ADDRESS", Prim_get_host_by_address, 1, 1, 0)
pub export fn Prim_get_host_by_address() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return stringAndFree(abi.OS_get_host_by_address(abi.stringArg(1)));
}

// DEFINE_PRIMITIVE ("HOST-ADDRESS-ANY", Prim_host_address_any, 0, 0, 0)
pub export fn Prim_host_address_any() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.allocate_string(abi.OS_host_address_length());
    abi.OS_host_address_any(@ptrCast(obj.legacyStringData(result)));
    return result;
}

// DEFINE_PRIMITIVE ("HOST-ADDRESS-LOOPBACK", Prim_host_address_loopback, 0, 0, 0)
pub export fn Prim_host_address_loopback() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const result = abi.allocate_string(abi.OS_host_address_length());
    abi.OS_host_address_loopback(@ptrCast(obj.legacyStringData(result)));
    return result;
}

// DEFINE_PRIMITIVE ("NEW-OPEN-TCP-STREAM-SOCKET", Prim_new_open_tcp_stream_socket, 3, 3,
//   "Given HOST-ADDRESS and PORT-NUMBER, open a TCP stream socket.\n\
// The opened socket is stored in the cdr of WEAK-PAIR.")
pub export fn Prim_new_open_tcp_stream_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(3, obj.weakPairP);
    const host = argHost(1);
    const port: c_uint = @truncate(@as(u64, @intCast(abi.arg_nonnegative_integer(2))));
    obj.setPairCdr(abi.argRef(3), abi.long_to_integer(@intCast(abi.OS_open_tcp_stream_socket(host, port))));
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("NEW-OPEN-UNIX-STREAM-SOCKET", Prim_new_open_unix_stream_socket, 2, 2,
//   "Open the unix stream socket FILENAME.\n\
// The opened socket is stored in the cdr of WEAK-PAIR.")
pub export fn Prim_new_open_unix_stream_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.weakPairP);
    obj.setPairCdr(abi.argRef(2), abi.long_to_integer(@intCast(abi.OS_open_unix_stream_socket(abi.stringArg(1), 1))));
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("SHUTDOWN-SOCKET", Prim_shutdown_socket, 2, 2, "")
pub export fn Prim_shutdown_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const socket = argClientSocket(1);
    const action = utils.arg_ulong_integer_in_range(2, 1, 4);
    abi.OS_shutdown_socket(socket, action);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("NEW-OPEN-TCP-SERVER-SOCKET", Prim_new_open_tcp_server_socket, 2, 2,
//   "Given PORT-NUMBER, open TCP server socket.\n\
// The opened socket is stored in the cdr of WEAK-PAIR.")
pub export fn Prim_new_open_tcp_server_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.weakPairP);
    const channel = abi.OS_create_tcp_server_socket();
    const address = abi.OS_malloc(abi.OS_host_address_length());
    abi.OS_host_address_any(address);
    const port: c_uint = @truncate(@as(u64, @intCast(abi.arg_nonnegative_integer(1))));
    abi.OS_bind_tcp_server_socket(channel, address, port);
    abi.OS_free(address);
    abi.OS_listen_tcp_server_socket(channel);
    obj.setPairCdr(abi.argRef(2), abi.long_to_integer(@intCast(channel)));
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("CREATE-TCP-SERVER-SOCKET", Prim_create_tcp_server_socket, 0, 0, 0)
pub export fn Prim_create_tcp_server_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return abi.long_to_integer(@intCast(abi.OS_create_tcp_server_socket()));
}

// DEFINE_PRIMITIVE ("CREATE-UNIX-SERVER-SOCKET", Prim_create_unix_server_socket, 2, 2, 0)
pub export fn Prim_create_unix_server_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.weakPairP);
    const channel = abi.OS_create_unix_server_socket(abi.stringArg(1), 1);
    if (channel == abi.no_channel) return obj.sharp_f;
    obj.setPairCdr(abi.argRef(2), abi.long_to_integer(@intCast(channel)));
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("BIND-TCP-SERVER-SOCKET", Prim_bind_tcp_server_socket, 3, 3, 0)
pub export fn Prim_bind_tcp_server_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const socket = argTcpServerSocket(1);
    const host = argHost(2);
    const port: c_uint = @truncate(@as(u64, @intCast(abi.arg_nonnegative_integer(3))));
    abi.OS_bind_tcp_server_socket(socket, host, port);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("LISTEN-TCP-SERVER-SOCKET", Prim_listen_tcp_server_socket, 1, 1, 0)
pub export fn Prim_listen_tcp_server_socket() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.OS_listen_tcp_server_socket(argTcpServerSocket(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("NEW-TCP-SERVER-CONNECTION-ACCEPT", Prim_new_tcp_server_connection_accept, 3, 3,
//   "Poll SERVER-SOCKET for a connection.\n\
// If a connection is available, it is opened and #T is returned;\n\
// the opened socket is stored in the cdr of WEAK-PAIR.\n\
// Otherwise, if SERVER-SOCKET is non-blocking, returns #F.\n\
// Second argument PEER-ADDRESS, if not #F, must be a host address string.\n\
// It is filled with the peer's address if given.")
pub export fn Prim_new_tcp_server_connection_accept() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(3, obj.weakPairP);
    const server_socket = argTcpServerSocket(1);
    const peer_host = if (abi.argRef(2) == obj.sharp_f) null else argHost(2);
    const connection = abi.OS_tcp_server_connection_accept(server_socket, peer_host, null);
    if (connection == abi.no_channel) return obj.sharp_f;
    obj.setPairCdr(abi.argRef(3), abi.long_to_integer(@intCast(connection)));
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("NEW-UNIX-SERVER-CONNECTION-ACCEPT",
//   Prim_new_unix_server_connection_accept, 2, 2,
//   "Poll SERVER-SOCKET for a connection.\n\
// If a connection is available, it is opened and #T is returned;\n\
// the opened socket is stored in the cdr of WEAK-PAIR.\n\
// Otherwise, if SERVER-SOCKET is non-blocking, returns #F.")
pub export fn Prim_new_unix_server_connection_accept() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.weakPairP);
    const server_socket = argUnixServerSocket(1);
    const connection = abi.OS_unix_server_connection_accept(server_socket);
    if (connection == abi.no_channel) return obj.sharp_f;
    obj.setPairCdr(abi.argRef(2), abi.long_to_integer(@intCast(connection)));
    return obj.sharp_t;
}

test "pruxsock host, service, client, and server primitives" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.ulongToFixnum(4), Prim_host_address_length());

    const any_addr = Prim_host_address_any();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, obj.legacyStringData(any_addr)[0..4]);

    const lo_addr = Prim_host_address_loopback();
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, obj.legacyStringData(lo_addr)[0..4]);

    const hn = Prim_get_host_name();
    try std.testing.expectEqualStrings("mock-host", std.mem.span(@as([*:0]const u8, @ptrCast(obj.legacyStringData(hn)))));

    stubs.setArgs(&.{string.char_pointer_to_string("http"), string.char_pointer_to_string("tcp")});
    try std.testing.expectEqual(obj.ulongToFixnum(80 << 8), Prim_get_service_by_name());
    stubs.setArgs(&.{string.char_pointer_to_string("missing"), string.char_pointer_to_string("tcp")});
    try std.testing.expectEqual(obj.sharp_f, Prim_get_service_by_name());
    stubs.setArgs(&.{obj.ulongToFixnum(80)});
    try std.testing.expectEqual(obj.ulongToFixnum(80 << 8), Prim_get_service_by_number());

    stubs.setArgs(&.{string.char_pointer_to_string("localhost")});
    const addrs = Prim_get_host_by_name();
    try std.testing.expect(obj.vectorP(addrs));
    try std.testing.expectEqual(@as(usize, 2), obj.vectorLength(addrs));
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, obj.legacyStringData(obj.vectorRef(addrs, 0))[0..4]);
    stubs.setArgs(&.{string.char_pointer_to_string("missing.invalid")});
    try std.testing.expectEqual(obj.sharp_f, Prim_get_host_by_name());

    stubs.setArgs(&.{string.char_pointer_to_string("localhost")});
    const canon = Prim_canonical_host_name();
    try std.testing.expectEqualStrings("mock-host.local", std.mem.span(@as([*:0]const u8, @ptrCast(obj.legacyStringData(canon)))));
    stubs.setArgs(&.{lo_addr});
    const by_addr = Prim_get_host_by_address();
    try std.testing.expectEqualStrings("localhost", std.mem.span(@as([*:0]const u8, @ptrCast(obj.legacyStringData(by_addr)))));

    const wc_tcp = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ lo_addr, obj.ulongToFixnum(8080), wc_tcp });
    try std.testing.expectEqual(obj.sharp_t, Prim_new_open_tcp_stream_socket());
    try std.testing.expectEqual(obj.ulongToFixnum(7), obj.pairCdr(wc_tcp));

    const wc_unix = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ string.char_pointer_to_string("/tmp/mock.sock"), wc_unix });
    try std.testing.expectEqual(obj.sharp_t, Prim_new_open_unix_stream_socket());
    try std.testing.expectEqual(obj.ulongToFixnum(8), obj.pairCdr(wc_unix));

    stubs.setArgs(&.{ obj.ulongToFixnum(7), obj.ulongToFixnum(3) });
    _ = Prim_shutdown_socket();
    try std.testing.expectEqual(@as(usize, 3), stubs.mock_last_sock_shutdown);

    const wc_srv = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ obj.ulongToFixnum(9000), wc_srv });
    try std.testing.expectEqual(obj.sharp_t, Prim_new_open_tcp_server_socket());
    const tcp_srv = obj.pairCdr(wc_srv);
    try std.testing.expectEqual(obj.ulongToFixnum(11), tcp_srv);
    try std.testing.expectEqual(@as(usize, 1), stubs.mock_sock_listen_calls);

    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.ulongToFixnum(11), Prim_create_tcp_server_socket());
    stubs.setArgs(&.{ tcp_srv, any_addr, obj.ulongToFixnum(9001) });
    _ = Prim_bind_tcp_server_socket();
    stubs.setArgs(&.{tcp_srv});
    _ = Prim_listen_tcp_server_socket();
    try std.testing.expectEqual(@as(usize, 2), stubs.mock_sock_listen_calls);

    const peer_buf = abi.allocate_string(4);
    const wc_acc = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ tcp_srv, peer_buf, wc_acc });
    try std.testing.expectEqual(obj.sharp_t, Prim_new_tcp_server_connection_accept());
    try std.testing.expectEqual(obj.ulongToFixnum(12), obj.pairCdr(wc_acc));
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, obj.legacyStringData(peer_buf)[0..4]);

    const wc_usrv = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ string.char_pointer_to_string("/tmp/srv.sock"), wc_usrv });
    try std.testing.expectEqual(obj.sharp_t, Prim_create_unix_server_socket());
    const unix_srv = obj.pairCdr(wc_usrv);

    const wc_uacc = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ unix_srv, wc_uacc });
    try std.testing.expectEqual(obj.sharp_t, Prim_new_unix_server_connection_accept());
    try std.testing.expectEqual(obj.ulongToFixnum(10), obj.pairCdr(wc_uacc));

    stubs.mock_sock_accept_none = true;
    stubs.setArgs(&.{ unix_srv, wc_uacc });
    try std.testing.expectEqual(obj.sharp_f, Prim_new_unix_server_connection_accept());
}
