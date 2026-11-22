// Derived from MIT/GNU Scheme C sources (`src/microcode/boot.c`, `option.h`, `critsec.h`, `intrpt.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const outf = @import("../support/outf.zig");
const obstack = @import("../support/obstack.zig");
const wind = @import("../support/wind.zig");
const transact = @import("../support/transact.zig");
const storage = @import("storage.zig");
const memmag = @import("../gc/memmag.zig");
const primutl = @import("../runtime/primutl.zig");
const utabmd = @import("utabmd.zig");
const string = @import("../data/string.zig");
const bytevector = @import("../data/bytevector.zig");

pub export var scheme_program_name: ?[*:0]const u8 = null;
pub export var OS_Name: ?[*:0]const u8 = null;
pub export var OS_Variant: ?[*:0]const u8 = null;

pub export var scratch_obstack: obstack.Obstack = initialObstack();
pub export var ffi_obstack: obstack.Obstack = initialObstack();
pub export var initial_C_stack_pointer: ?*anyopaque = null;

pub export var critical_section_name: ?[*:0]const u8 = null;
pub export var critical_section_hook_p: bool = false;
pub export var critical_section_hook: ?*const fn (?[*:0]const u8) callconv(.c) void = null;

var reload_saved_string: ?[*]u8 = null;
var reload_saved_string_length: c_uint = 0;
var reload_saved_legacy_p: bool = false;

fn initialObstack() obstack.Obstack {
    return .{
        .chunk_size = 0,
        .chunk = null,
        .object_base = null,
        .next_free = null,
        .chunk_limit = null,
        .temp = 0,
        .alignment_mask = 0,
        .chunkfun = @ptrCast(&obstack_chunk_alloc),
        .freefun = &std.c.free,
    };
}

pub export fn obstack_chunk_alloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size) orelse {
        const name: [*:0]const u8 = scheme_program_name orelse "mit-scheme";
        const size_int: c_int = @intCast(size);
        outf.fatal("\n{s}: unable to allocate obstack chunk of {d} bytes\n", .{ name, size_int });
        abi.Microcode_Termination(abi.term_exit);
    };
}

inline fn blocksToWords(n: usize) usize {
    return n * 1024;
}

comptime {
    if (!builtin.is_test) {
        @export(&schemeMain, .{ .name = "main" });
    }
}

fn schemeMain(argc: c_int, argv: [*]?[*:0]const u8) callconv(.c) c_int {
    var argc_slot = argc;
    abi.init_exit_scheme();
    scheme_program_name = argv[0];
    initial_C_stack_pointer = @ptrCast(&argc_slot);

    scratch_obstack.init(&obstack_chunk_alloc, &std.c.free);
    ffi_obstack.init(&obstack_chunk_alloc, &std.c.free);
    wind.dstack_initialize();
    transact.transaction_initialize();
    reload_saved_string = null;
    reload_saved_string_length = 0;
    abi.read_command_line_options(argc, argv);

    memmag.setup_memory(
        blocksToWords(abi.option_heap_size),
        blocksToWords(abi.option_stack_size),
        blocksToWords(abi.option_constant_size),
        blocksToWords(abi.option_code_size),
    );

    primutl.initialize_primitives();
    abi.compiler_initialize(abi.option_fasl_file != null);
    abi.OS_initialize();
    startScheme();
    abi.termination_init_error();
}

fn startScheme() void {
    var expr: obj.SchemeObject = undefined;

    if (!abi.option_batch_mode and !abi.option_show_version and !abi.option_show_help) {
        outf.console("MIT/GNU Scheme running under {s}\n", .{OS_Variant orelse ""});
        abi.OS_announcement();
        outf.console("\n", .{});
        outf.flushConsole();
    }
    utabmd.initialize_fixed_objects_vector();

    if (abi.option_fasl_file) |fasl_file| {
        const prim1 = primutl.make_primitive("BINARY-FASLOAD", 1);
        const fn_object = string.char_pointer_to_string(fasl_file);
        const prim2 = primutl.make_primitive("SCODE-EVAL", 2);
        const inner_arg = abi.Free;
        inner_arg[0] = obj.makeVectorHeader(2);
        inner_arg[1] = prim1;
        inner_arg[2] = fn_object;
        const outer_arg = inner_arg + 3;
        expr = obj.makePointerObject(obj.tc_combination, outer_arg);
        outer_arg[0] = obj.makeVectorHeader(3);
        outer_arg[1] = prim2;
        outer_arg[2] = obj.makePointerObject(obj.tc_combination, inner_arg);
        outer_arg[3] = obj.the_global_env;
        abi.Free = outer_arg + 4;
    } else {
        const prim = primutl.make_primitive("LOAD-BAND", 1);
        const fn_object = string.char_pointer_to_string(abi.option_band_file);
        const frame = abi.Free;
        expr = obj.makePointerObject(obj.tc_combination, frame);
        frame[0] = obj.makeVectorHeader(2);
        frame[1] = prim;
        frame[2] = fn_object;
        abi.Free = frame + 3;
    }

    abi.initializeInterrupts(0);
    abi.Registers[abi.regblock_expr] = expr;
    abi.Registers[abi.regblock_env] = obj.the_global_env;
    storage.trapping = false;

    abi.stackCheck(abi.cont_size);
    abi.pushCont(abi.rc_end_of_computation, obj.sharp_f);

    if (!(@intFromPtr(abi.stack_pointer) >= @intFromPtr(abi.stack_guard) and
        @intFromPtr(abi.Free) <= @intFromPtr(abi.heap_alloc_limit)))
    {
        outf.fatal("Configuration won't hold initial data.\n", .{});
        abi.termination_init_error();
    }
    enterInterpreter();
}

fn doEnterInterpreter() noreturn {
    abi.Interpret();
    outf.fatal("\nThe interpreter returned to top level!\n", .{});
    abi.Microcode_Termination(abi.term_exit);
}

fn enterInterpreter() noreturn {
    doEnterInterpreter();
}

pub export fn Re_Enter_Interpreter() callconv(.c) obj.SchemeObject {
    abi.Interpret();
    return abi.Registers[abi.regblock_val];
}

// DEFINE_PRIMITIVE ("MICROCODE-IDENTIFY", Prim_microcode_identify, 0, 0, 0)
pub export fn Prim_microcode_identify() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return utabmd.make_microcode_identification_vector();
}

// DEFINE_PRIMITIVE ("MICROCODE-LIBRARY-PATH", Prim_microcode_library_path, 0, 0, 0)
pub export fn Prim_microcode_library_path() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const scan = abi.option_library_path;
    var count: usize = 0;
    while (scan[count] != null) {
        count += 1;
    }
    const result = abi.allocate_vector(count, true);
    for (0..@as(usize, @intCast(count))) |idx| {
        obj.vectorSet(result, idx, string.char_pointer_to_string(scan[idx]));
    }
    return result;
}

fn argvToObject(argc: c_int, argv: [*]?[*:0]const u8) obj.SchemeObject {
    const count: usize = if (argc > 0) @intCast(argc) else 0;
    const result = abi.allocate_vector(count, true);
    for (0..@as(usize, @intCast(count))) |idx| {
        obj.vectorSet(result, idx, string.char_pointer_to_string(argv[idx]));
    }
    return result;
}

// DEFINE_PRIMITIVE ("GET-COMMAND-LINE", Prim_get_command_line, 0, 0, 0)
pub export fn Prim_get_command_line() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return argvToObject(abi.option_saved_argc, abi.option_saved_argv);
}

// DEFINE_PRIMITIVE ("GET-UNUSED-COMMAND-LINE", Prim_get_unused_command_line, 0, 0, 0)
pub export fn Prim_get_unused_command_line() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const unused = abi.option_unused_argv orelse return obj.sharp_f;
    const result = argvToObject(abi.option_unused_argc, unused);
    abi.option_unused_argv = null;
    return result;
}

pub fn clearReloadSavedString() void {
    if (reload_saved_string) |saved| {
        std.c.free(@ptrCast(saved));
        reload_saved_string = null;
    }
    reload_saved_string_length = 0;
    reload_saved_legacy_p = false;
}

// DEFINE_PRIMITIVE ("RELOAD-SAVE-STRING", Prim_reload_save_string, 1, 1, 0)
pub export fn Prim_reload_save_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    clearReloadSavedString();
    const arg = abi.argRef(1);
    if (arg != obj.sharp_f) {
        abi.checkArg(1, string.string_p);
        const len: c_uint = @intCast(obj.legacyStringLength(arg));
        if (len > 0) {
            reload_saved_legacy_p = obj.legacyStringP(arg);
            const buf: [*]u8 = @ptrCast(abi.OS_malloc(len).?);
            @memcpy(buf[0..len], obj.legacyStringData(arg)[0..len]);
            reload_saved_string = buf;
            reload_saved_string_length = len;
        }
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("RELOAD-RETRIEVE-STRING", Prim_reload_retrieve_string, 0, 0, 0)
pub export fn Prim_reload_retrieve_string() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const saved = reload_saved_string orelse return obj.sharp_f;
    const result = if (reload_saved_legacy_p)
        string.memory_to_string(reload_saved_string_length, @ptrCast(saved))
    else
        bytevector.memory_to_bytevector(reload_saved_string_length, @ptrCast(saved));
    std.c.free(@ptrCast(saved));
    reload_saved_string = null;
    reload_saved_string_length = 0;
    return result;
}

// DEFINE_PRIMITIVE ("BATCH-MODE?", Prim_batch_mode_p, 0, 0, 0)
pub export fn Prim_batch_mode_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(abi.option_batch_mode);
}

test "boot utility primitives, obstack_chunk_alloc, and reload save/retrieve" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    // obstack_chunk_alloc allocates usable memory
    const chunk = obstack_chunk_alloc(64);
    try std.testing.expect(chunk != null);
    std.c.free(chunk);

    // BATCH-MODE?
    abi.option_batch_mode = false;
    try std.testing.expectEqual(obj.sharp_f, Prim_batch_mode_p());
    abi.option_batch_mode = true;
    try std.testing.expectEqual(obj.sharp_t, Prim_batch_mode_p());

    // MICROCODE-LIBRARY-PATH
    const lib_path = Prim_microcode_library_path();
    try std.testing.expect(obj.vectorP(lib_path));
    try std.testing.expectEqual(@as(usize, 2), obj.vectorLength(lib_path));
    try std.testing.expectEqualStrings("/mock/lib1", obj.legacyStringData(obj.vectorRef(lib_path, 0))[0..obj.legacyStringLength(obj.vectorRef(lib_path, 0))]);
    try std.testing.expectEqualStrings("/mock/lib2", obj.legacyStringData(obj.vectorRef(lib_path, 1))[0..obj.legacyStringLength(obj.vectorRef(lib_path, 1))]);

    // GET-COMMAND-LINE
    const cmdline = Prim_get_command_line();
    try std.testing.expectEqual(@as(usize, 2), obj.vectorLength(cmdline));
    try std.testing.expectEqualStrings("scheme", obj.legacyStringData(obj.vectorRef(cmdline, 0))[0..obj.legacyStringLength(obj.vectorRef(cmdline, 0))]);
    try std.testing.expectEqualStrings("--batch-mode", obj.legacyStringData(obj.vectorRef(cmdline, 1))[0..obj.legacyStringLength(obj.vectorRef(cmdline, 1))]);

    // GET-UNUSED-COMMAND-LINE clears option_unused_argv on first call
    const unused1 = Prim_get_unused_command_line();
    try std.testing.expect(obj.vectorP(unused1));
    try std.testing.expectEqual(@as(usize, 1), obj.vectorLength(unused1));
    try std.testing.expectEqualStrings("--extra", obj.legacyStringData(obj.vectorRef(unused1, 0))[0..obj.legacyStringLength(obj.vectorRef(unused1, 0))]);
    try std.testing.expectEqual(obj.sharp_f, Prim_get_unused_command_line());

    // RELOAD-SAVE-STRING / RELOAD-RETRIEVE-STRING round-trip (legacy string and bytevector)
    try std.testing.expectEqual(obj.sharp_f, Prim_reload_retrieve_string());

    const legacy = string.char_pointer_to_string("hello");
    stubs.setArgs(&.{legacy});
    _ = Prim_reload_save_string();
    const restored_legacy = Prim_reload_retrieve_string();
    try std.testing.expect(obj.legacyStringP(restored_legacy));
    try std.testing.expectEqualStrings("hello", obj.legacyStringData(restored_legacy)[0..obj.legacyStringLength(restored_legacy)]);
    try std.testing.expectEqual(obj.sharp_f, Prim_reload_retrieve_string());

    const bv = bytevector.memory_to_bytevector(4, "byte");
    stubs.setArgs(&.{bv});
    _ = Prim_reload_save_string();
    const restored_bv = Prim_reload_retrieve_string();
    try std.testing.expect(obj.bytevectorP(restored_bv));
    try std.testing.expectEqualStrings("byte", obj.bytevectorData(restored_bv)[0..obj.bytevectorLength(restored_bv)]);
    try std.testing.expectEqual(obj.sharp_f, Prim_reload_retrieve_string());
}
