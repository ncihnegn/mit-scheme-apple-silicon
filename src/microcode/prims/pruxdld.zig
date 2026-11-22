// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxdld.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const string = @import("../data/string.zig");
const utils = @import("../core/utils.zig");
const fasload = @import("../gc/fasload.zig");
const artutl = @import("../arith/artutl.zig");
const win = @import("../os/win/win_api.zig");

const PosixDl = struct {
    extern "c" fn dlclose(?*anyopaque) c_int;
};

var cleanup_registered_p: bool = false;
var loaded_handles_size: usize = 0;
var n_loaded_handles: usize = 0;
var loaded_handles: ?[*]*anyopaque = null;

fn argHandle(n: c_int) ?*anyopaque {
    return @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(n))));
}

fn signalDlError(op_name: [*:0]const u8, err_msg: ?[*:0]const u8) noreturn {
    const v = abi.allocate_vector(3, true);
    obj.vectorSet(v, 0, obj.longToUnsignedFixnum(abi.err_in_system_call));
    obj.vectorSet(v, 1, string.char_pointer_to_string(op_name));
    obj.vectorSet(v, 2, string.char_pointer_to_string(err_msg));
    utils.error_with_argument(v);
}

fn signalWinDlError(op_name: [*:0]const u8) noreturn {
    var msg_buf: [64]u8 = undefined;
    const msg_ptr: [*:0]const u8 = if (std.fmt.bufPrint(msg_buf[0 .. msg_buf.len - 1], "Win32 error {d}", .{win.kernel32.GetLastError()})) |s| blk: {
        msg_buf[s.len] = 0;
        break :blk @ptrCast(&msg_buf);
    } else |_| "Win32 error";
    signalDlError(op_name, msg_ptr);
}

fn dldLoad(path: ?[*:0]const u8) *anyopaque {
    if (!cleanup_registered_p) {
        fasload.add_reload_cleanup(&dldUnloadAll);
        cleanup_registered_p = true;
    }

    const handle: *anyopaque = if (comptime builtin.os.tag == .windows) blk: {
        const mod: ?win.HMODULE = if (path) |p|
            win.kernel32.LoadLibraryA(p)
        else
            win.kernel32.GetModuleHandleA(null);
        break :blk @ptrCast(mod orelse signalWinDlError("LoadLibraryA"));
    } else std.c.dlopen(path, .{ .NOW = true, .GLOBAL = true }) orelse
        signalDlError("dlopen", std.c.dlerror());

    if (n_loaded_handles == loaded_handles_size) {
        if (loaded_handles_size == 0) {
            loaded_handles_size = 16;
            loaded_handles = @ptrCast(@alignCast(abi.OS_malloc(loaded_handles_size * @sizeOf(*anyopaque)).?));
        } else {
            loaded_handles_size *= 2;
            loaded_handles = @ptrCast(@alignCast(abi.OS_realloc(@ptrCast(loaded_handles), loaded_handles_size * @sizeOf(*anyopaque)).?));
        }
    }
    loaded_handles.?[n_loaded_handles] = handle;
    n_loaded_handles += 1;
    return handle;
}

fn dldFinalize(handle: ?*anyopaque) void {
    const addr: ?*anyopaque = if (comptime builtin.os.tag == .windows) blk: {
        const h = handle orelse break :blk null;
        break :blk win.kernel32.GetProcAddress(@ptrCast(h), "dload_finalize_file");
    } else std.c.dlsym(handle, "dload_finalize_file");

    if (addr) |address| {
        const finalize: *const fn () callconv(.c) void = @ptrCast(@alignCast(address));
        finalize();
    }
}

fn dldUnload(handle: ?*anyopaque) void {
    dldFinalize(handle);
    if (comptime builtin.os.tag == .windows) {
        if (handle) |h| {
            const self_mod = win.kernel32.GetModuleHandleA(null);
            if (@as(?win.HMODULE, @ptrCast(h)) != self_mod) {
                if (win.kernel32.FreeLibrary(@ptrCast(h)) == 0) {
                    signalWinDlError("FreeLibrary");
                }
            }
        }
    } else {
        if (PosixDl.dlclose(handle) != 0) {
            signalDlError("dlclose", std.c.dlerror());
        }
    }
    if (loaded_handles) |handles| {
        for (0..n_loaded_handles) |i| {
            if (@as(?*anyopaque, handles[i]) == handle) {
                handles[i] = handles[n_loaded_handles - 1];
                n_loaded_handles -= 1;
                break;
            }
        }
    }
}

fn dldUnloadAll() callconv(.c) void {
    if (loaded_handles_size > 0) {
        const handles = loaded_handles.?;
        const self_mod = if (comptime builtin.os.tag == .windows) win.kernel32.GetModuleHandleA(null) else null;
        for (0..n_loaded_handles) |i| {
            const handle = handles[i];
            dldFinalize(handle);
            if (comptime builtin.os.tag == .windows) {
                if (@as(?win.HMODULE, @ptrCast(handle)) != self_mod) {
                    _ = win.kernel32.FreeLibrary(@ptrCast(handle));
                }
            } else {
                _ = PosixDl.dlclose(handle);
            }
        }
        abi.OS_free(@ptrCast(handles));
        loaded_handles_size = 0;
        n_loaded_handles = 0;
        loaded_handles = null;
    }
}

fn dldLookup(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
    if (comptime builtin.os.tag == .windows) {
        const h: win.HMODULE = @ptrCast(handle orelse signalWinDlError("GetProcAddress"));
        if (win.kernel32.GetProcAddress(h, symbol)) |addr| {
            return addr;
        }
        // Mirror POSIX dlopen(NULL, RTLD_GLOBAL): when querying the process handle,
        // also search already-loaded dynamic handles and standard CRT/system DLLs.
        if (win.kernel32.GetModuleHandleA(null)) |self_mod| {
            if (h == self_mod) {
                if (loaded_handles) |handles| {
                    for (0..n_loaded_handles) |i| {
                        const mod: win.HMODULE = @ptrCast(handles[i]);
                        if (mod == self_mod) continue;
                        if (win.kernel32.GetProcAddress(mod, symbol)) |addr| {
                            return addr;
                        }
                    }
                }
                const fallback_dlls = [_][*:0]const u8{
                    "ucrtbase.dll",
                    "msvcrt.dll",
                    "kernel32.dll",
                };
                for (fallback_dlls) |dll| {
                    if (win.kernel32.GetModuleHandleA(dll)) |mod| {
                        if (win.kernel32.GetProcAddress(mod, symbol)) |addr| {
                            return addr;
                        }
                    }
                }
            }
        }
        signalWinDlError("GetProcAddress");
    } else {
        _ = std.c.dlerror(); // discard any outstanding errors
        const address = std.c.dlsym(handle, symbol);
        if (std.c.dlerror()) |error_string| {
            signalDlError("dlsym", error_string);
        }
        return address;
    }
}

// DEFINE_PRIMITIVE ("DLD-LOAD-FILE", Prim_dld_load_file, 2, 2,
//   "(FILENAME WEAK-PAIR)\n\
// Load the shared library FILENAME and store its handle\n\
// in the cdr of WEAK-PAIR.")
pub export fn Prim_dld_load_file() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(2, obj.weakPairP);
    const path: ?[*:0]const u8 = if (abi.argRef(1) == obj.sharp_f) null else abi.stringArg(1);
    const handle = dldLoad(path);
    obj.setPairCdr(abi.argRef(2), artutl.ulong_to_integer(@intCast(@intFromPtr(handle))));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("DLD-LOOKUP-SYMBOL", Prim_dld_lookup_symbol, 2, 2,
//   "(HANDLE STRING)\n\
// Look up the symbol named STRING in the shared library specified by HANDLE.\n\
// Return the symbol's address, or #F if no such symbol.")
pub export fn Prim_dld_lookup_symbol() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const addr = dldLookup(argHandle(1), abi.stringArg(2));
    return artutl.ulong_to_integer(@intCast(@intFromPtr(addr)));
}

// DEFINE_PRIMITIVE ("DLD-UNLOAD-FILE", Prim_dld_unload_file, 1, 1,
//   "(HANDLE)\n\
// Unload the shared library specified by HANDLE.\n\
// The file is unmapped from memory, and its symbols become unbound.")
pub export fn Prim_dld_unload_file() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    dldUnload(argHandle(1));
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("INVOKE-C-THUNK", Prim_invoke_C_thunk, 1, 1,
//   "(ADDRESS)\n\
// Treat ADDRESS, a Scheme integer corresponding to a C unsigned long, as\n\
// the address of a C procedure of no arguments that returns an unsigned\n\
// long.  Invoke it, and return the corresponding Scheme integer.")
pub export fn Prim_invoke_C_thunk() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const thunk_ptr: *const fn () callconv(.c) usize = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(1))));
    return artutl.ulong_to_integer(thunk_ptr());
}

// DEFINE_PRIMITIVE ("ADDRESS-TO-STRING", Prim_address_to_string, 1, 1,
//   "(ADDRESS)\n\
// Treat ADDRESS, a Scheme integer corresponding to a C unsigned long, as\n\
// a C char * pointer.  Allocate and return a Scheme string with the same\n\
// contents.")
pub export fn Prim_address_to_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const ptr: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(1))));
    return string.char_pointer_to_string(ptr);
}

fn testSampleThunk() callconv(.c) usize {
    return 123456;
}

test "pruxdld dlopen self, dlsym, dlclose, invoke-c-thunk, and address-to-string" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    defer {
        dldUnloadAll();
        stubs.resetMockRuntime();
    }

    const thunk_addr = artutl.ulong_to_integer(@intCast(@intFromPtr(&testSampleThunk)));
    stubs.setArgs(&.{thunk_addr});
    try std.testing.expectEqual(@as(usize, 123456), artutl.integer_to_ulong(Prim_invoke_C_thunk()));

    const msg: [*:0]const u8 = "hello-dld";
    stubs.setArgs(&.{artutl.ulong_to_integer(@intCast(@intFromPtr(msg)))});
    const str_obj = Prim_address_to_string();
    try std.testing.expectEqual(@as(usize, 9), obj.legacyStringLength(str_obj));
    try std.testing.expectEqualStrings("hello-dld", obj.legacyStringData(str_obj)[0..9]);

    const wc = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
    stubs.setArgs(&.{ obj.sharp_f, wc });
    _ = Prim_dld_load_file();
    const handle = obj.pairCdr(wc);
    try std.testing.expect(handle != obj.sharp_f);
    try std.testing.expectEqual(@as(usize, 1), n_loaded_handles);

    stubs.setArgs(&.{ handle, string.char_pointer_to_string("malloc") });
    const malloc_sym = Prim_dld_lookup_symbol();
    try std.testing.expect(artutl.integer_to_ulong(malloc_sym) != 0);

    stubs.setArgs(&.{handle});
    _ = Prim_dld_unload_file();
    try std.testing.expectEqual(@as(usize, 0), n_loaded_handles);

    if (comptime builtin.os.tag == .windows) {
        const k32_wc = abi.system_pair_cons(@intCast(obj.tc_weak_cons), obj.sharp_f, obj.sharp_f);
        stubs.setArgs(&.{ string.char_pointer_to_string("kernel32.dll"), k32_wc });
        _ = Prim_dld_load_file();
        const k32_handle = obj.pairCdr(k32_wc);
        try std.testing.expect(k32_handle != obj.sharp_f);
        try std.testing.expectEqual(@as(usize, 1), n_loaded_handles);

        stubs.setArgs(&.{ k32_handle, string.char_pointer_to_string("GetCurrentProcessId") });
        const pid_sym = Prim_dld_lookup_symbol();
        try std.testing.expect(artutl.integer_to_ulong(pid_sym) != 0);

        stubs.setArgs(&.{k32_handle});
        _ = Prim_dld_unload_file();
        try std.testing.expectEqual(@as(usize, 0), n_loaded_handles);
    }
}
