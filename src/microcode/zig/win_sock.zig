// Derived from MIT/GNU Scheme C sources (`src/microcode/uxsock.c`)
// and Win32 Winsock2 APIs:
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("prim_abi.zig");
const transact = @import("transact.zig");
const utils = @import("utils.zig");
const win = @import("win_api.zig");
const win_io = @import("win_io.zig");

const socket_listen_backlog: c_int = 1024;
const hostname_size: usize = 1024;

fn initInetSockaddr(host: ?*const anyopaque, port: c_uint) win.SockAddrIn {
    var address = std.mem.zeroes(win.SockAddrIn);
    address.sin_family = win.AF_INET;
    if (host) |src_raw| {
        const src: [*]const u8 = @ptrCast(src_raw);
        @memcpy(&address.sin_addr, src[0..4]);
    }
    address.sin_port = @truncate(port);
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

fn socketCreateTcp() win.SOCKET {
    const s = win.ws2_32.socket(win.AF_INET, win.SOCK_STREAM, win.IPPROTO_TCP);
    if (s == win.INVALID_SOCKET) {
        win_io.failWsa(abi.syscall_socket);
    }
    return s;
}

pub fn osOpenTcpStreamSocket(host: ?*anyopaque, port: c_uint) callconv(.c) abi.Tchannel {
    transact.transaction_begin();
    const s = socketCreateTcp();
    const channel = win_io.allocateSocketChannel(s, .tcp_stream_socket);
    win_io.osChannelCloseOnAbort(channel);
    const address = initInetSockaddr(host, port);
    if (win.ws2_32.connect(s, @ptrCast(&address), @sizeOf(win.SockAddrIn)) == win.SOCKET_ERROR) {
        win_io.failWsa(abi.syscall_connect);
    }
    transact.transaction_commit();
    return channel;
}

pub fn osShutdownSocket(channel: abi.Tchannel, stype: usize) callconv(.c) void {
    const how: c_int = switch (stype & 0x3) {
        0x1 => win.SD_RECEIVE,
        0x2 => win.SD_SEND,
        else => win.SD_BOTH,
    };
    const entry = win_io.getOpenChannel(channel) orelse abi.error_bad_range_arg(1);
    if (!entry.is_socket) abi.error_bad_range_arg(1);
    if (win.ws2_32.shutdown(entry.sock, how) == win.SOCKET_ERROR) {
        win_io.failWsa(abi.syscall_shutdown);
    }
}

pub fn osGetServiceByName(service_name: [*:0]const u8, protocol_name: ?[*:0]const u8) callconv(.c) c_int {
    const proto = protocol_name orelse "tcp";
    const entry = win.ws2_32.getservbyname(service_name, proto) orelse return -1;
    return entry.s_port;
}

pub fn osGetServiceByNumber(port_number: usize) callconv(.c) usize {
    return @as(usize, win.ws2_32.htons(@truncate(port_number)));
}

pub fn osHostAddressLength() callconv(.c) c_uint {
    return 4;
}

pub fn osGetHostByName(host_name: [*:0]const u8) callconv(.c) ?[*]?[*]u8 {
    const entry = win.ws2_32.gethostbyname(host_name) orelse return null;
    return entry.h_addr_list;
}

pub fn osGetHostName() callconv(.c) ?[*:0]const u8 {
    var host_name: [hostname_size]u8 = @splat(0);
    if (win.ws2_32.gethostname(&host_name, hostname_size) == win.SOCKET_ERROR) {
        var len: win.DWORD = @intCast(hostname_size - 1);
        if (win.kernel32.GetComputerNameA(&host_name, &len) == 0) {
            win_io.failWsa(abi.syscall_gethostname);
        }
    }
    host_name[hostname_size - 1] = 0;
    return dupCStringOsMalloc(@ptrCast(&host_name));
}

pub fn osCanonicalHostName(host_name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const entry = win.ws2_32.gethostbyname(host_name) orelse return null;
    const cname = entry.h_name orelse return null;
    return dupCStringOsMalloc(cname);
}

pub fn osGetHostByAddress(host_addr: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const entry = win.ws2_32.gethostbyaddr(@ptrCast(host_addr), 4, win.AF_INET) orelse return null;
    const hname = entry.h_name orelse return null;
    return dupCStringOsMalloc(hname);
}

pub fn osHostAddressAny(addr: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(addr.?);
    @memset(dst[0..4], 0);
}

pub fn osHostAddressLoopback(addr: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(addr.?);
    const loopback_be = std.mem.nativeToBig(u32, 0x7f000001);
    @memcpy(dst[0..4], std.mem.asBytes(&loopback_be));
}

pub fn osOpenUnixStreamSocket(_: [*:0]const u8, _: c_int) callconv(.c) abi.Tchannel {
    utils.error_system_call(@intFromEnum(std.c.E.AFNOSUPPORT), abi.syscall_socket);
}

pub fn osCreateTcpServerSocket() callconv(.c) abi.Tchannel {
    return win_io.allocateSocketChannel(socketCreateTcp(), .tcp_server_socket);
}

pub fn osBindTcpServerSocket(channel: abi.Tchannel, host: ?*anyopaque, port: c_uint) callconv(.c) void {
    const address = initInetSockaddr(host, port);
    const entry = win_io.getOpenChannel(channel) orelse abi.error_bad_range_arg(1);
    if (!entry.is_socket) abi.error_bad_range_arg(1);
    const one: c_int = 1;
    if (win.ws2_32.setsockopt(entry.sock, win.SOL_SOCKET, win.SO_REUSEADDR, @ptrCast(&one), @sizeOf(c_int)) == win.SOCKET_ERROR) {
        win_io.failWsa(abi.syscall_setsockopt);
    }
    if (win.ws2_32.bind(entry.sock, @ptrCast(&address), @sizeOf(win.SockAddrIn)) == win.SOCKET_ERROR) {
        win_io.failWsa(abi.syscall_bind);
    }
}

pub fn osListenTcpServerSocket(channel: abi.Tchannel) callconv(.c) void {
    const entry = win_io.getOpenChannel(channel) orelse abi.error_bad_range_arg(1);
    if (!entry.is_socket) abi.error_bad_range_arg(1);
    if (win.ws2_32.listen(entry.sock, socket_listen_backlog) == win.SOCKET_ERROR) {
        win_io.failWsa(abi.syscall_listen);
    }
}

pub fn osCreateUnixServerSocket(_: [*:0]const u8, _: c_int) callconv(.c) abi.Tchannel {
    utils.error_system_call(@intFromEnum(std.c.E.AFNOSUPPORT), abi.syscall_socket);
}

pub fn osTcpServerConnectionAccept(
    channel: abi.Tchannel,
    peer_host: ?*anyopaque,
    peer_port: ?*c_uint,
) callconv(.c) abi.Tchannel {
    const entry = win_io.getOpenChannel(channel) orelse abi.error_bad_range_arg(1);
    if (!entry.is_socket) abi.error_bad_range_arg(1);
    var address = std.mem.zeroes(win.SockAddrIn);
    var addr_len: c_int = @sizeOf(win.SockAddrIn);
    const s = win.ws2_32.accept(entry.sock, @ptrCast(&address), &addr_len);
    if (s == win.INVALID_SOCKET) {
        const err = win.ws2_32.WSAGetLastError();
        if (err == 10035) return abi.no_channel; // WSAEWOULDBLOCK
        utils.error_system_call(win.win32ErrorToErrno(@bitCast(err)), abi.syscall_accept);
    }
    if (peer_host) |dst_raw| {
        const dst: [*]u8 = @ptrCast(dst_raw);
        @memcpy(dst[0..4], &address.sin_addr);
    }
    if (peer_port) |p_port| {
        p_port.* = address.sin_port;
    }
    return win_io.allocateSocketChannel(s, .tcp_stream_socket);
}

pub fn osUnixServerConnectionAccept(_: abi.Tchannel) callconv(.c) abi.Tchannel {
    utils.error_system_call(@intFromEnum(std.c.E.AFNOSUPPORT), abi.syscall_accept);
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
