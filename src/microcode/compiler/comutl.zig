// Derived from MIT/GNU Scheme C sources (`src/microcode/comutl.c`, `cmpint.h`, `stack.h`, `prims.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const artutl = @import("../arith/artutl.zig");
const wind = @import("../support/wind.zig");
const hunk = @import("../data/hunk.zig");
const string = @import("../data/string.zig");
const code_arena = @import("code_arena.zig");
const jit = @import("jit.zig");

const ThunkFn = *const fn () callconv(.c) usize;

var ilof_prefix: ?[*:0]const u8 = null;

inline fn ccEntryOrReturnP(object: obj.SchemeObject) bool {
    return obj.ccEntryP(object) or obj.ccReturnP(object);
}

fn ccEntryToAddress(entry: obj.SchemeObject) ?*anyopaque {
    if (obj.ccEntryP(entry)) {
        return obj.objectRawAddress(entry);
    }
    if (obj.ccReturnP(entry)) {
        const raw = obj.objectRawAddress(entry);
        if (build_options.cc_is_native) {
            return abi.cc_return_address_to_entry_address(raw);
        }
        return raw;
    }
    return null;
}

inline fn stringArg(n: c_int) [*:0]const u8 {
    const val = abi.argRef(@intCast(n));
    if (!string.string_p(val)) {
        abi.error_wrong_type_arg(n);
    }
    return @ptrCast(obj.legacyStringData(val));
}

// DEFINE_PRIMITIVE ("COMPILED-CODE-ADDRESS->BLOCK", Prim_comp_code_address_block, 1, 1,
//   "(ADDRESS)\n\
// Given a compiled-code entry ADDRESS, return its block.")
pub export fn Prim_comp_code_address_block() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, ccEntryOrReturnP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    const arg = abi.argRef(1);
    return if (obj.ccEntryP(arg))
        abi.cc_entry_to_block(arg)
    else
        abi.cc_return_to_block(arg);
}

// DEFINE_PRIMITIVE ("COMPILED-CODE-ADDRESS->OFFSET", Prim_comp_code_address_offset, 1, 1,
//   "(ADDRESS)\n\
// Given a compiled-code entry ADDRESS, return its offset into its block.")
pub export fn Prim_comp_code_address_offset() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, ccEntryOrReturnP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    const arg = abi.argRef(1);
    const off = if (obj.ccEntryP(arg))
        abi.cc_entry_to_block_offset(arg)
    else
        abi.cc_return_to_block_offset(arg);
    return obj.ulongToFixnum(off);
}

// DEFINE_PRIMITIVE ("STACK-TOP-ADDRESS", Prim_stack_top_address, 0, 0, 0)
pub export fn Prim_stack_top_address() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return artutl.ulong_to_integer(obj.addressToDatum(abi.stack_end));
}

// DEFINE_PRIMITIVE ("STACK-ADDRESS-OFFSET", Prim_stack_address_offset, 1, 1, 0)
pub export fn Prim_stack_address_offset() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccStackEnvP);
    const raw_addr = obj.datumToRawAddress(obj.objectDatum(abi.argRef(1)));
    const start_addr = @intFromPtr(abi.stack_start);
    const end_addr = @intFromPtr(abi.stack_end);
    if (raw_addr < start_addr or raw_addr >= end_addr) {
        abi.error_bad_range_arg(1);
    }
    return artutl.ulong_to_integer(@intCast((end_addr - raw_addr) / @sizeOf(obj.SchemeObject)));
}

// DEFINE_PRIMITIVE ("COMPILED-ENTRY-KIND", Prim_compiled_entry_kind, 1, 1, 0)
pub export fn Prim_compiled_entry_kind() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, ccEntryOrReturnP);
    const entry = abi.argRef(1);

    var group: abi.CcEntryTypeGroup = .unknown;
    var field1: usize = 0;
    var field2: isize = 0;

    if (build_options.cc_support) {
        var cet: abi.CcEntryType = undefined;
        if (!abi.read_cc_entry_type(&cet, ccEntryToAddress(entry))) {
            switch (cet.marker) {
                .procedure => {
                    group = .procedure;
                    field1 = 1 + @as(usize, cet.args.for_procedure.n_required);
                    const max_args: isize = @intCast(field1 + @as(usize, cet.args.for_procedure.n_optional));
                    field2 = if (cet.args.for_procedure.rest_p) -(max_args + 1) else max_args;
                },
                .continuation => {
                    group = .continuation;
                    field1 = 0;
                    field2 = @intCast(cet.args.for_continuation.offset);
                },
                .expression => {
                    group = .expression;
                    field1 = 0;
                    field2 = 0;
                },
                .internal_continuation => {
                    group = .continuation;
                    field1 = 1;
                    field2 = -1;
                },
                .internal_procedure, .trampoline => {
                    group = .internal_procedure;
                    field1 = 1;
                    field2 = 0;
                },
                .return_to_interpreter => {
                    group = .continuation;
                    field1 = 2;
                    field2 = if (entry != abi.return_to_interpreter) 1 else 0;
                },
                .closure => {
                    group = .internal_procedure;
                    field1 = 0;
                    field2 = 0;
                },
            }
        }
    }

    return hunk.hunk3_cons(
        obj.ulongToFixnum(@backingInt(group)),
        obj.ulongToFixnum(field1),
        obj.longToFixnum(field2),
    );
}

// DEFINE_PRIMITIVE ("COERCE-TO-COMPILED-PROCEDURE", Prim_coerce_to_closure, 2, 2, 0)
pub export fn Prim_coerce_to_closure() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    var temp: obj.SchemeObject = 0;
    const arity: c_uint = @truncate(abi.arg_ulong_integer(2));
    const result = abi.coerce_to_compiled(abi.argRef(1), arity, &temp);
    switch (result) {
        abi.prim_done => {},
        abi.prim_interrupt => abi.primitiveGc(10),
        else => abi.error_bad_range_arg(2),
    }
    return temp;
}

// DEFINE_PRIMITIVE ("COMPILED-CLOSURE->ENTRY", Prim_cc_closure_to_entry, 1, 1,
//   "Given a compiled closure, return the entry point which it invokes.")
pub export fn Prim_cc_closure_to_entry() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccEntryP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    const arg = abi.argRef(1);
    if (!abi.cc_entry_closure_p(arg)) {
        abi.error_bad_range_arg(1);
    }
    return abi.cc_closure_to_entry(arg);
}

// DEFINE_PRIMITIVE ("UTILITY-INDEX->NAME", Prim_utility_index_to_name, 1, 1, 0)
pub export fn Prim_utility_index_to_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    const idx: c_uint = @truncate(abi.arg_ulong_integer(1));
    const name = abi.utility_index_to_name(idx) orelse return obj.sharp_f;
    return string.char_pointer_to_string(name);
}

// DEFINE_PRIMITIVE ("BUILTIN-INDEX->NAME", Prim_builtin_index_to_name, 1, 1, 0)
pub export fn Prim_builtin_index_to_name() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    const idx: c_uint = @truncate(abi.arg_ulong_integer(1));
    const name = abi.builtin_index_to_name(idx) orelse return obj.sharp_f;
    return string.char_pointer_to_string(name);
}

// DEFINE_PRIMITIVE ("INITIALIZE-C-COMPILED-BLOCK", Prim_initialize_C_compiled_block, 1, 1,
//   "Given the tag of a compiled object, return the object.")
pub export fn Prim_initialize_C_compiled_block() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.sharp_f;
}

// DEFINE_PRIMITIVE ("INITIALIZE-LIARC-OBJECT-FILE", Prim_initialize_liarc_object_file, 2, 2,
//   "(ADDRESS PREFIX)\n\
// Run the object-file initialization thunk specified by ADDRESS,\n\
// using PREFIX as the rewriting prefix for the subparts.")
pub export fn Prim_initialize_liarc_object_file() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const addr_val: usize = @intCast(abi.arg_ulong_integer(1));
    if (addr_val == 0) {
        abi.error_bad_range_arg(1);
    }
    const thunk: ThunkFn = @ptrFromInt(addr_val);
    const prefix = stringArg(2);
    const saved_pos = wind.dstack_position;
    wind.dstack_bind(@ptrCast(&ilof_prefix), @ptrCast(@constCast(prefix)));
    const value = thunk();
    wind.dstack_set_position(saved_pos);
    return artutl.ulong_to_integer(value);
}

pub export fn liarc_object_file_prefix() callconv(.c) ?[*:0]const u8 {
    return ilof_prefix;
}

// DEFINE_PRIMITIVE ("DECLARE-COMPILED-CODE-BLOCK", Prim_declare_compiled_code_block, 1, 1,
//   "Ensure cache coherence for a compiled-code block newly constructed.")
pub export fn Prim_declare_compiled_code_block() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const new_cc_block = abi.argRef(1);
    if (!obj.ccBlockP(new_cc_block)) {
        abi.error_wrong_type_arg(1);
    }
    if (build_options.cc_support) {
        abi.declare_compiled_code_block(new_cc_block);
    }
    return obj.sharp_t;
}

// DEFINE_PRIMITIVE ("INSTALL-COMPILED-CODE-BLOCK", Prim_install_compiled_code_block, 1, 1,
//   "(BLOCK)\n\
// Install a compiled-code block or staged vector into the executable code arena.")
pub export fn Prim_install_compiled_code_block() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const arg = abi.argRef(1);
    var src: [*]const obj.SchemeObject = undefined;

    if (obj.ccBlockP(arg)) {
        if (build_options.cc_support and abi.cc_block_closure_p(arg)) {
            abi.error_bad_range_arg(1);
        }
        src = obj.objectAddress(arg);
        if (code_arena.code_address_p(@ptrCast(src))) {
            if (build_options.cc_support) {
                abi.declare_compiled_code_block(arg);
            }
            return arg;
        }
    } else if (obj.vectorP(arg) and obj.vectorLength(arg) >= 1) {
        src = obj.objectAddress(arg);
    } else {
        abi.error_wrong_type_arg(1);
    }

    const n_words: usize = 1 + obj.objectDatum(src[0]);
    if (n_words < 2 or
        obj.objectType(src[1]) != obj.tc_manifest_nm_vector or
        (2 + obj.objectDatum(src[1])) > n_words)
    {
        abi.error_bad_range_arg(1);
    }

    const dst = code_arena.code_arena_alloc(n_words) orelse abi.error_bad_range_arg(1);
    const tail_words: usize = @intCast(n_words - 1);

    code_arena.code_arena_write_begin();
    dst[0] = obj.makeObject(obj.tc_manifest_vector, n_words - 1);
    @memcpy(dst[1 .. 1 + tail_words], src[1 .. 1 + tail_words]);
    code_arena.code_arena_write_end();

    const result = obj.makeCcBlock(dst);
    if (build_options.cc_support) {
        abi.declare_compiled_code_block(result);
    }
    jit.jit_flush_icache(@ptrCast(dst), @as(usize, @intCast(n_words)) * @sizeOf(obj.SchemeObject));
    return result;
}

// DEFINE_PRIMITIVE ("SET-COMPILED-CODE-BLOCK/DEBUGGING-INFO!", Prim_set_cc_block_debugging_info, 2, 2,
//   "(BLOCK INFO)\n\
// Store debugging INFO into compiled-code BLOCK.")
pub export fn Prim_set_cc_block_debugging_info() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccBlockP);
    const block = abi.argRef(1);
    if (build_options.cc_support and abi.cc_block_closure_p(block)) {
        abi.error_bad_range_arg(1);
    }
    const len = obj.vectorLength(block);
    if (len < 2) {
        abi.error_bad_range_arg(1);
    }

    const info = abi.argRef(2);
    if (code_arena.code_address_p(@ptrCast(obj.objectAddress(block)))) {
        code_arena.code_arena_write_begin();
        obj.vectorSet(block, @intCast(len - 2), info);
        code_arena.code_arena_write_end();
    } else {
        obj.vectorSet(block, @intCast(len - 2), info);
    }
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("CODE-SPACE-BOUNDS", Prim_code_space_bounds, 0, 0,
//   "()\n\
// Return a pair of exact integers (start . alloc-next) for the primary code arena.")
pub export fn Prim_code_space_bounds() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.primitiveGcIfNeeded(16);
    const start_obj = artutl.ulong_to_integer(@intCast(@intFromPtr(code_arena.code_start)));
    const end_obj = artutl.ulong_to_integer(@intCast(@intFromPtr(code_arena.code_alloc_next)));
    return abi.cons(start_obj, end_obj);
}

// DEFINE_PRIMITIVE ("CODE-ADDRESS?", Prim_code_address_p, 1, 1,
//   "(OBJECT)\n\
// Return #T if OBJECT or its machine address lies inside the code arena.")
pub export fn Prim_code_address_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    const arg = abi.argRef(1);
    const addr: ?*const anyopaque = if (obj.ccEntryP(arg))
        obj.objectRawAddress(arg)
    else if (obj.ccReturnP(arg))
        obj.objectRawAddress(arg)
    else if (obj.ccBlockP(arg))
        obj.objectRawAddress(arg)
    else if (obj.integerP(arg) and artutl.integer_to_ulong_p(arg))
        @ptrFromInt(@as(usize, @intCast(artutl.integer_to_ulong(arg))))
    else
        return obj.sharp_f;

    return obj.booleanToObject(code_arena.code_address_p(addr));
}

// DEFINE_PRIMITIVE ("LIARC-COMPILED-BLOCKS", Prim_liarc_compiled_code_blocks, 0, 0,
//   "Return a vector containing the names of registered compiled-code blocks.")
pub export fn Prim_liarc_compiled_code_blocks() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.error_unimplemented_primitive();
}

// DEFINE_PRIMITIVE ("BKPT/INSTALL", Prim_install_bkpt, 1, 1,
//   "(compiled-entry-object)\n\
// Install a breakpoint trap in a compiled code object.\n\
// Returns false or a handled needed by REMOVE-BKPT and ONE-STEP-PROCEED.")
pub export fn Prim_install_bkpt() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccEntryP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();

    const arg = abi.argRef(1);
    const entry = obj.objectRawAddress(arg);
    if (abi.bkpt_p(entry)) {
        abi.error_bad_range_arg(1);
    }
    const block = abi.cc_entry_to_block_address(arg);
    if (obj.objectType(block[0]) == obj.tc_manifest_closure) {
        return abi.bkpt_closure_install(entry);
    }
    return abi.bkpt_install(entry);
}

// DEFINE_PRIMITIVE ("BKPT/REMOVE", Prim_remove_bkpt, 2, 2,
//   "(compiled-entry-object handle)\n\
// Remove a breakpoint trap installed by INSTALL-BKPT.")
pub export fn Prim_remove_bkpt() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccEntryP);
    abi.checkArg(2, obj.nonMarkedVectorP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();

    const entry = obj.objectRawAddress(abi.argRef(1));
    const handle = abi.argRef(2);
    if (!abi.bkpt_p(entry)) {
        abi.error_bad_range_arg(1);
    }
    abi.bkpt_remove(entry, handle);
    return obj.unspecific;
}

// DEFINE_PRIMITIVE ("BKPT?", Prim_bkpt_p, 1, 1,
//   "(compiled-entry-object)\n\
// True if there is a breakpoint trap in compiled-entry-object.")
pub export fn Prim_bkpt_p() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccEntryP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    return obj.booleanToObject(abi.bkpt_p(obj.objectRawAddress(abi.argRef(1))));
}

// DEFINE_PRIMITIVE ("BKPT/PROCEED", Prim_bkpt_proceed, 3, 3,
//   "(compiled-entry-object handle state)\n\
// Proceed the computation from the current breakpoint.")
pub export fn Prim_bkpt_proceed() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.checkArg(1, obj.ccEntryP);
    abi.checkArg(2, obj.nonMarkedVectorP);
    if (!build_options.cc_support) abi.error_unimplemented_primitive();
    return abi.bkpt_proceed(obj.objectRawAddress(abi.argRef(1)), abi.argRef(2), abi.argRef(3));
}

test "comutl stack offset, entry kind, liarc prefix binding, code arena install and bounds" {
    const stubs = @import("../core/test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();
    wind.dstack_initialize();
    defer wind.dstack_reset();

    // STACK-TOP-ADDRESS & STACK-ADDRESS-OFFSET
    const top = Prim_stack_top_address();
    try std.testing.expect(obj.integerP(top));
    try std.testing.expectEqual(obj.addressToDatum(abi.stack_end), artutl.integer_to_ulong(top));

    const stack_env = obj.makeObject(obj.tc_stack_environment, obj.addressToDatum(abi.stack_end - 5));
    stubs.setArgs(&.{stack_env});
    try std.testing.expectEqual(@as(usize, 5), artutl.integer_to_ulong(Prim_stack_address_offset()));

    // COMPILED-ENTRY-KIND across procedure (required/optional/rest), continuation, return_to_interpreter
    if (build_options.cc_support) {
        const entry = obj.makeObject(obj.tc_compiled_entry, 0x10004);
        stubs.mock_cc_entry_bad = false;
        stubs.mock_cc_entry_type = .{
            .marker = .procedure,
            .args = .{ .for_procedure = .{ .n_required = 2, .n_optional = 1, .rest_p = true } },
        };
        stubs.setArgs(&.{entry});
        const k_proc = Prim_compiled_entry_kind();
        try std.testing.expectEqual(obj.ulongToFixnum(@backingInt(abi.CcEntryTypeGroup.procedure)), obj.memoryRef(k_proc, 0));
        try std.testing.expectEqual(obj.ulongToFixnum(3), obj.memoryRef(k_proc, 1));
        try std.testing.expectEqual(obj.longToFixnum(-5), obj.memoryRef(k_proc, 2));

        stubs.mock_cc_entry_type = .{
            .marker = .continuation,
            .args = .{ .for_continuation = .{ .offset = 7 } },
        };
        const ret = obj.makeObject(obj.tc_compiled_return, 0x10004);
        stubs.setArgs(&.{ret});
        const k_cont = Prim_compiled_entry_kind();
        try std.testing.expectEqual(obj.ulongToFixnum(@backingInt(abi.CcEntryTypeGroup.continuation)), obj.memoryRef(k_cont, 0));
        try std.testing.expectEqual(obj.ulongToFixnum(0), obj.memoryRef(k_cont, 1));
        try std.testing.expectEqual(obj.longToFixnum(7), obj.memoryRef(k_cont, 2));

        stubs.mock_cc_entry_type = .{
            .marker = .return_to_interpreter,
            .args = .{ .for_continuation = .{ .offset = 0 } },
        };
        stubs.setArgs(&.{abi.return_to_interpreter});
        const k_rti = Prim_compiled_entry_kind();
        try std.testing.expectEqual(obj.ulongToFixnum(@backingInt(abi.CcEntryTypeGroup.continuation)), obj.memoryRef(k_rti, 0));
        try std.testing.expectEqual(obj.ulongToFixnum(2), obj.memoryRef(k_rti, 1));
        try std.testing.expectEqual(obj.longToFixnum(0), obj.memoryRef(k_rti, 2));
    }

    // INITIALIZE-LIARC-OBJECT-FILE + liarc_object_file_prefix dynamic binding
    const Hook = struct {
        var observed: [16]u8 = @splat(0);
        var observed_len: usize = 0;

        fn run() callconv(.c) usize {
            if (liarc_object_file_prefix()) |p| {
                const s = std.mem.span(p);
                @memcpy(observed[0..s.len], s);
                observed_len = s.len;
            }
            return 77;
        }
    };
    try std.testing.expect(liarc_object_file_prefix() == null);
    const prefix_str = string.char_pointer_to_string("mod_");
    stubs.setArgs(&.{ artutl.ulong_to_integer(@intFromPtr(&Hook.run)), prefix_str });
    const res = Prim_initialize_liarc_object_file();
    try std.testing.expectEqual(@as(usize, 77), artutl.integer_to_ulong(res));
    try std.testing.expectEqualStrings("mod_", Hook.observed[0..Hook.observed_len]);
    try std.testing.expect(liarc_object_file_prefix() == null);

    // INSTALL-COMPILED-CODE-BLOCK + SET-COMPILED-CODE-BLOCK/DEBUGGING-INFO! + CODE-SPACE-BOUNDS + CODE-ADDRESS?
    code_arena.code_arena_setup(2048);
    defer code_arena.code_arena_teardown();

    const bounds = Prim_code_space_bounds();
    try std.testing.expectEqual(@intFromPtr(code_arena.code_start.?), @as(usize, @intCast(artutl.integer_to_ulong(obj.pairCar(bounds)))));
    try std.testing.expectEqual(@intFromPtr(code_arena.code_alloc_next.?), @as(usize, @intCast(artutl.integer_to_ulong(obj.pairCdr(bounds)))));

    const staged = abi.allocate_vector(4, true);
    obj.vectorSet(staged, 0, obj.makeNmvHeader(1));
    obj.vectorSet(staged, 1, 0x12345678);
    obj.vectorSet(staged, 2, obj.sharp_f); // debugging info slot (len - 2)
    obj.vectorSet(staged, 3, obj.sharp_t); // environment slot

    stubs.setArgs(&.{staged});
    const installed = Prim_install_compiled_code_block();
    try std.testing.expect(obj.ccBlockP(installed));

    stubs.setArgs(&.{installed});
    try std.testing.expectEqual(obj.sharp_t, Prim_code_address_p());
    stubs.setArgs(&.{staged});
    try std.testing.expectEqual(obj.sharp_f, Prim_code_address_p());

    const info_sym = obj.ulongToFixnum(99);
    stubs.setArgs(&.{ installed, info_sym });
    _ = Prim_set_cc_block_debugging_info();
    try std.testing.expectEqual(info_sym, obj.vectorRef(installed, 2));
}
