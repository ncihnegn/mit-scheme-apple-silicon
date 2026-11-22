const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const osscheme = @import("osscheme.zig");
const transact = @import("transact.zig");
const utils = @import("utils.zig");
const stubs = if (builtin.is_test) @import("test_stubs.zig") else struct {};

const socket_listen_backlog: c_uint = 1024;
const hostname_size: usize = 1024;

const Servent = extern struct {
    s_name: ?[*:0]u8,
    s_aliases: ?[*]?[*:0]u8,
    s_port: c_int,
    s_proto: ?[*:0]u8,
};

const Hostent = extern struct {
    h_name: ?[*:0]u8,
    h_aliases: ?[*]?[*:0]u8,
    h_addrtype: c_int,
    h_length: c_int,
    h_addr_list: ?[*]?[*]u8,
};

extern "c" fn getservbyname(name: [*:0]const u8, proto: ?[*:0]const u8) ?*Servent;
extern "c" fn gethostbyname(name: [*:0]const u8) ?*Hostent;
extern "c" fn gethostbyaddr(addr: ?*const anyopaque, len: std.c.socklen_t, addr_type: c_int) ?*Hostent;

fn socketRetry(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int {
    var s = std.c.socket(domain, sock_type, protocol);
    while (s < 0) {
        abi.UX_prim_check_fd_errno(abi.syscall_socket);
        s = std.c.socket(domain, sock_type, protocol);
    }
    abi.UX_out_of_files_p = false;
    return s;
}

fn initInetSockaddr(host: ?*const anyopaque, port: c_uint) std.c.sockaddr.in {
    var address = std.mem.zeroes(std.c.sockaddr.in);
    if (@hasField(std.c.sockaddr.in, "len")) {
        address.len = @sizeOf(std.c.sockaddr.in);
    }
    address.family = std.c.AF.INET;
    if (host) |src_raw| {
        const src: [*]const u8 = @ptrCast(src_raw);
        const dst: [*]u8 = @ptrCast(&address.addr);
        @memcpy(dst[0..@sizeOf(@TypeOf(address.addr))], src[0..@sizeOf(@TypeOf(address.addr))]);
    }
    address.port = @truncate(port);
    return address;
}

fn initUnixSockaddr(filename: [*:0]const u8, argno: c_int) std.c.sockaddr.un {
    var address = std.mem.zeroes(std.c.sockaddr.un);
    const name_slice = std.mem.span(filename);
    if (name_slice.len > address.path.len) {
        abi.error_bad_range_arg(argno);
    }
    if (@hasField(std.c.sockaddr.un, "len")) {
        address.len = @sizeOf(std.c.sockaddr.un);
    }
    address.family = std.c.AF.UNIX;
    @memcpy(address.path[0..name_slice.len], name_slice);
    return address;
}

fn dupCStringOsMalloc(src: [*:0]const u8) [*:0]const u8 {
    const slice = std.mem.span(src);
    const dst_raw = abi.OS_malloc(slice.len + 1) orelse @panic("OS_malloc failed");
    const dst: [*]u8 = @ptrCast(dst_raw);
    @memcpy(dst[0..slice.len], slice);
    dst[slice.len] = 0;
    return @ptrCast(dst);
}

fn doConnect(s: c_int, address: *const std.c.sockaddr, addr_len: std.c.socklen_t) void {
    if (std.c.connect(s, address, addr_len) < 0) {
        const err = std.c._errno().*;
        if (err != @backingInt(std.c.E.INTR)) {
            utils.error_system_call(err, abi.syscall_connect);
        }
        while (true) {
            osscheme.deliver_pending_interrupts();
            var fds = [1]std.c.pollfd{.{
                .fd = s,
                .events = std.c.POLL.IN | std.c.POLL.OUT,
                .revents = 0,
            }};
            const nfds = std.c.poll(&fds, 1, 0);
            if (nfds > 0 and (fds[0].revents & (std.c.POLL.IN | std.c.POLL.OUT)) != 0) {
                break;
            }
            if (nfds < 0) {
                const poll_err = std.c._errno().*;
                if (poll_err != @backingInt(std.c.E.INTR)) {
                    utils.error_system_call(poll_err, abi.syscall_select);
                }
            }
        }
        var so_err: c_int = 0;
        var opt_len: std.c.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(s, std.c.SOL.SOCKET, std.c.SO.ERROR, @ptrCast(&so_err), &opt_len) < 0 or so_err != 0) {
            utils.error_system_call(so_err, abi.syscall_connect);
        }
    }
}

fn isWouldBlock(err: c_int) bool {
    if (err == @backingInt(std.c.E.AGAIN)) return true;
    if (@hasDecl(std.c.E, "WOULDBLOCK") and err == @backingInt(std.c.E.WOULDBLOCK)) return true;
    return false;
}

fn acceptRetry(
    channel: abi.Tchannel,
    addr: ?*std.c.sockaddr,
    addr_len: ?*std.c.socklen_t,
) ?c_int {
    const listen_fd = abi.channel_table[channel].descriptor;
    while (true) {
        const s = std.c.accept(listen_fd, addr, addr_len);
        if (s >= 0) {
            abi.UX_out_of_files_p = false;
            return s;
        }
        if (isWouldBlock(std.c._errno().*)) {
            return null;
        }
        abi.UX_prim_check_fd_errno(abi.syscall_accept);
    }
}

/// Open a connected TCP stream socket channel to `host:port` (network byte order).
pub fn osOpenTcpStreamSocket(host: ?*anyopaque, port: c_uint) callconv(.c) abi.Tchannel {
    transact.transaction_begin();
    const s = socketRetry(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    const channel = abi.makeChannel(s, .tcp_stream_socket);
    abi.OS_channel_close_on_abort(channel);
    const address = initInetSockaddr(host, port);
    doConnect(s, @ptrCast(&address), @sizeOf(std.c.sockaddr.in));
    transact.transaction_commit();
    return channel;
}

/// Shut down read, write, or both halves of a socket channel.
pub fn osShutdownSocket(channel: abi.Tchannel, stype: usize) callconv(.c) void {
    const how: c_int = switch (stype & 0x3) {
        0x1 => std.c.SHUT.RD,
        0x2 => std.c.SHUT.WR,
        else => std.c.SHUT.RDWR,
    };
    const fd = abi.channel_table[channel].descriptor;
    while (std.c.shutdown(fd, how) < 0) {
        abi.UX_prim_check_errno(abi.syscall_shutdown);
    }
}

/// Look up a network service port by name and protocol, returning `-1` if unknown.
pub fn osGetServiceByName(service_name: [*:0]const u8, protocol_name: ?[*:0]const u8) callconv(.c) c_int {
    const entry = getservbyname(service_name, protocol_name) orelse return -1;
    return entry.s_port;
}

/// Convert a host-order port number to network byte order.
pub fn osGetServiceByNumber(port_number: usize) callconv(.c) usize {
    return @as(usize, std.mem.nativeToBig(u16, @truncate(port_number)));
}

/// Return byte length of an IPv4 host address (`sizeof(struct in_addr)`).
pub fn osHostAddressLength() callconv(.c) c_uint {
    return @sizeOf(u32);
}

/// Resolve a hostname via `gethostbyname` and return its null-terminated address vector.
pub fn osGetHostByName(host_name: [*:0]const u8) callconv(.c) ?[*]?[*]u8 {
    const entry = gethostbyname(host_name) orelse return null;
    return entry.h_addr_list;
}

/// Return the local machine hostname in an `OS_malloc`-allocated string.
pub fn osGetHostName() callconv(.c) [*:0]const u8 {
    var host_name: [hostname_size]u8 = @splat(0);
    while (std.c.gethostname(&host_name, hostname_size) < 0) {
        abi.UX_prim_check_errno(abi.syscall_gethostname);
    }
    host_name[hostname_size - 1] = 0;
    return dupCStringOsMalloc(@ptrCast(&host_name));
}

/// Return the canonical FQDN for `host_name` in `OS_malloc` storage, or `null`.
pub fn osCanonicalHostName(host_name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const entry = gethostbyname(host_name) orelse return null;
    const cname = entry.h_name orelse return null;
    return dupCStringOsMalloc(cname);
}

/// Reverse-lookup an IPv4 address via `gethostbyaddr` and return `OS_malloc`-allocated name or `null`.
pub fn osGetHostByAddress(host_addr: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const entry = gethostbyaddr(@ptrCast(host_addr), osHostAddressLength(), std.c.AF.INET) orelse return null;
    const hname = entry.h_name orelse return null;
    return dupCStringOsMalloc(hname);
}

/// Write `INADDR_ANY` (`0.0.0.0`) into `addr`.
pub fn osHostAddressAny(addr: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(addr.?);
    @memset(dst[0..4], 0);
}

/// Write `INADDR_LOOPBACK` (`127.0.0.1` in network byte order) into `addr`.
pub fn osHostAddressLoopback(addr: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(addr.?);
    const loopback_be = std.mem.nativeToBig(u32, 0x7f000001);
    @memcpy(dst[0..4], std.mem.asBytes(&loopback_be));
}

/// Open a connected Unix-domain stream socket channel to `filename`.
pub fn osOpenUnixStreamSocket(filename: [*:0]const u8, argno: c_int) callconv(.c) abi.Tchannel {
    const address = initUnixSockaddr(filename, argno);
    transact.transaction_begin();
    const s = socketRetry(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    const channel = abi.makeChannel(s, .unix_stream_socket);
    abi.OS_channel_close_on_abort(channel);
    doConnect(s, @ptrCast(&address), @sizeOf(std.c.sockaddr.un));
    transact.transaction_commit();
    return channel;
}

/// Allocate an unbound TCP server socket channel.
pub fn osCreateTcpServerSocket() callconv(.c) abi.Tchannel {
    const s = socketRetry(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    return abi.makeChannel(s, .tcp_server_socket);
}

/// Enable `SO_REUSEADDR` and bind a TCP server socket channel to `host:port`.
pub fn osBindTcpServerSocket(channel: abi.Tchannel, host: ?*anyopaque, port: c_uint) callconv(.c) void {
    const address = initInetSockaddr(host, port);
    const fd = abi.channel_table[channel].descriptor;
    const one: c_int = 1;
    while (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int)) < 0) {
        abi.UX_prim_check_errno(abi.syscall_setsockopt);
    }
    while (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) < 0) {
        abi.UX_prim_check_errno(abi.syscall_bind);
    }
}

/// Mark a bound TCP server socket channel passive with backlog `1024`.
pub fn osListenTcpServerSocket(channel: abi.Tchannel) callconv(.c) void {
    const fd = abi.channel_table[channel].descriptor;
    while (std.c.listen(fd, socket_listen_backlog) < 0) {
        abi.UX_prim_check_errno(abi.syscall_listen);
    }
}

/// Create, bind, and start listening on a Unix-domain stream server socket channel.
pub fn osCreateUnixServerSocket(filename: [*:0]const u8, argno: c_int) callconv(.c) abi.Tchannel {
    const address = initUnixSockaddr(filename, argno);
    transact.transaction_begin();
    const s = socketRetry(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    const channel = abi.makeChannel(s, .unix_server_socket);
    abi.OS_channel_close_on_abort(channel);
    const fd = abi.channel_table[channel].descriptor;
    while (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.un)) < 0) {
        abi.UX_prim_check_errno(abi.syscall_bind);
    }
    while (std.c.listen(fd, socket_listen_backlog) < 0) {
        abi.UX_prim_check_errno(abi.syscall_listen);
    }
    transact.transaction_commit();
    return channel;
}

/// Accept a pending TCP connection on `channel`, optionally storing peer IPv4 addr and port.
pub fn osTcpServerConnectionAccept(
    channel: abi.Tchannel,
    peer_host: ?*anyopaque,
    peer_port: ?*c_uint,
) callconv(.c) abi.Tchannel {
    const State = struct {
        var address: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
    };
    State.address = std.mem.zeroes(std.c.sockaddr.in);
    var addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    const s = acceptRetry(channel, @ptrCast(&State.address), &addr_len) orelse return abi.no_channel;
    if (peer_host) |dst_raw| {
        const dst: [*]u8 = @ptrCast(dst_raw);
        const src: [*]const u8 = @ptrCast(&State.address.addr);
        @memcpy(dst[0..4], src[0..4]);
    }
    if (peer_port) |p_port| {
        p_port.* = State.address.port;
    }
    return abi.makeChannel(s, .tcp_stream_socket);
}

/// Accept a pending Unix-domain connection on `channel`.
pub fn osUnixServerConnectionAccept(channel: abi.Tchannel) callconv(.c) abi.Tchannel {
    const s = acceptRetry(channel, null, null) orelse return abi.no_channel;
    return abi.makeChannel(s, .unix_stream_socket);
}

comptime {
    if (!builtin.is_test) {
        @export(&osOpenTcpStreamSocket, .{ .name = "OS_open_tcp_stream_socket" });
        @export(&osShutdownSocket, .{ .name = "OS_shutdown_socket" });
        @export(&osGetServiceByName, .{ .name = "OS_get_service_by_name" });
        @export(&osGetServiceByNumber, .{ .name = "OS_get_service_by_number" });
        @export(&osHostAddressLength, .{ .name = "OS_host_address_length" });
        @export(&osGetHostByName, .{ .name = "OS_get_host_by_name" });
        @export(&osGetHostName, .{ .name = "OS_get_host_name" });
        @export(&osCanonicalHostName, .{ .name = "OS_canonical_host_name" });
        @export(&osGetHostByAddress, .{ .name = "OS_get_host_by_address" });
        @export(&osHostAddressAny, .{ .name = "OS_host_address_any" });
        @export(&osHostAddressLoopback, .{ .name = "OS_host_address_loopback" });
        @export(&osOpenUnixStreamSocket, .{ .name = "OS_open_unix_stream_socket" });
        @export(&osCreateTcpServerSocket, .{ .name = "OS_create_tcp_server_socket" });
        @export(&osBindTcpServerSocket, .{ .name = "OS_bind_tcp_server_socket" });
        @export(&osListenTcpServerSocket, .{ .name = "OS_listen_tcp_server_socket" });
        @export(&osCreateUnixServerSocket, .{ .name = "OS_create_unix_server_socket" });
        @export(&osTcpServerConnectionAccept, .{ .name = "OS_tcp_server_connection_accept" });
        @export(&osUnixServerConnectionAccept, .{ .name = "OS_unix_server_connection_accept" });
    }
}

fn closeSocketTestChannel(ch: abi.Tchannel) void {
    const fd = abi.channel_table[ch].descriptor;
    if (fd >= 0) {
        _ = std.c.close(fd);
        abi.channel_table[ch].descriptor = -1;
    }
}

test "uxsock loopback TCP and Unix sockets plus host/service helpers" {
    stubs.resetMockRuntime();

    try std.testing.expectEqual(@as(c_uint, 4), osHostAddressLength());

    var any_buf: [4]u8 = .{ 1, 2, 3, 4 };
    osHostAddressAny(&any_buf);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &any_buf);

    var loopback_buf: [4]u8 = @splat(0);
    osHostAddressLoopback(&loopback_buf);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &loopback_buf);

    try std.testing.expectEqual(@as(usize, 0x5000), osGetServiceByNumber(80));
    const hname = osGetHostName();
    defer abi.OS_free(@ptrCast(@constCast(hname)));
    try std.testing.expect(std.mem.span(hname).len > 0);

    // Loopback TCP server + client + accept
    const srv_ch = osCreateTcpServerSocket();
    defer closeSocketTestChannel(srv_ch);
    try std.testing.expectEqual(abi.ChannelType.tcp_server_socket, abi.channel_table[srv_ch].type);

    osBindTcpServerSocket(srv_ch, &loopback_buf, 0);
    osListenTcpServerSocket(srv_ch);

    var bound_addr = std.mem.zeroes(std.c.sockaddr.in);
    var bound_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.getsockname(abi.channel_table[srv_ch].descriptor, @ptrCast(&bound_addr), &bound_len),
    );
    try std.testing.expect(bound_addr.port != 0);

    const cli_ch = osOpenTcpStreamSocket(&loopback_buf, bound_addr.port);
    defer closeSocketTestChannel(cli_ch);
    try std.testing.expectEqual(abi.ChannelType.tcp_stream_socket, abi.channel_table[cli_ch].type);

    var peer_host: [4]u8 = @splat(0);
    var peer_port: c_uint = 0;
    const acc_ch = osTcpServerConnectionAccept(srv_ch, &peer_host, &peer_port);
    defer closeSocketTestChannel(acc_ch);
    try std.testing.expect(acc_ch != abi.no_channel);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &peer_host);
    try std.testing.expect(peer_port != 0);
    osShutdownSocket(cli_ch, 0x3);

    // Loopback Unix domain server + client + accept
    const sock_path: [*:0]const u8 = "/tmp/zig-m3-uxsock.sock";
    _ = std.c.unlink(sock_path);
    defer _ = std.c.unlink(sock_path);

    const usrv_ch = osCreateUnixServerSocket(sock_path, 1);
    defer closeSocketTestChannel(usrv_ch);
    try std.testing.expectEqual(abi.ChannelType.unix_server_socket, abi.channel_table[usrv_ch].type);

    const ucli_ch = osOpenUnixStreamSocket(sock_path, 1);
    defer closeSocketTestChannel(ucli_ch);
    try std.testing.expectEqual(abi.ChannelType.unix_stream_socket, abi.channel_table[ucli_ch].type);

    const uacc_ch = osUnixServerConnectionAccept(usrv_ch);
    defer closeSocketTestChannel(uacc_ch);
    try std.testing.expect(uacc_ch != abi.no_channel);
    try std.testing.expectEqual(abi.ChannelType.unix_stream_socket, abi.channel_table[uacc_ch].type);
}
