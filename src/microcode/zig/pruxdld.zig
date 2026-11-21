// Derived from MIT/GNU Scheme C sources (`src/microcode/pruxdld.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const string = @import("string.zig");
const utils = @import("utils.zig");
const fasload = @import("fasload.zig");
const artutl = @import("artutl.zig");

extern "c" fn dlclose(?*anyopaque) c_int;

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

fn dldLoad(path: ?[*:0]const u8) *anyopaque {
    if (!cleanup_registered_p) {
        fasload.add_reload_cleanup(&dldUnloadAll);
        cleanup_registered_p = true;
    }

    const handle = std.c.dlopen(path, .{ .NOW = true, .GLOBAL = true }) orelse
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
    if (std.c.dlsym(handle, "dload_finalize_file")) |address| {
        const finalize: *const fn () callconv(.c) void = @ptrCast(@alignCast(address));
        finalize();
    }
}

fn dldUnload(handle: ?*anyopaque) void {
    dldFinalize(handle);
    if (dlclose(handle) != 0) {
        signalDlError("dlclose", std.c.dlerror());
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
        for (0..n_loaded_handles) |i| {
            const handle = handles[i];
            dldFinalize(handle);
            _ = dlclose(handle);
        }
        abi.OS_free(@ptrCast(handles));
        loaded_handles_size = 0;
        n_loaded_handles = 0;
        loaded_handles = null;
    }
}

fn dldLookup(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
    _ = std.c.dlerror(); // discard any outstanding errors
    const address = std.c.dlsym(handle, symbol);
    if (std.c.dlerror()) |error_string| {
        signalDlError("dlsym", error_string);
    }
    return address;
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
    const thunk_ptr: *const fn () callconv(.c) c_ulong = @ptrFromInt(@as(usize, @intCast(abi.arg_ulong_integer(1))));
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

fn testSampleThunk() callconv(.c) c_ulong {
    return 123456;
}

test "pruxdld dlopen self, dlsym, dlclose, invoke-c-thunk, and address-to-string" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer {
        dldUnloadAll();
        stubs.resetMockRuntime();
    }

    const thunk_addr = artutl.ulong_to_integer(@intCast(@intFromPtr(&testSampleThunk)));
    stubs.setArgs(&.{thunk_addr});
    try std.testing.expectEqual(@as(c_ulong, 123456), artutl.integer_to_ulong(Prim_invoke_C_thunk()));

    const msg: [*:0]const u8 = "hello-dld";
    stubs.setArgs(&.{artutl.ulong_to_integer(@intCast(@intFromPtr(msg)))});
    const str_obj = Prim_address_to_string();
    try std.testing.expectEqual(@as(c_ulong, 9), obj.legacyStringLength(str_obj));
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
}
