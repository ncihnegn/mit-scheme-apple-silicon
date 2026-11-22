// Derived from MIT/GNU Scheme C sources (`src/microcode/term.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const boot = @import("boot.zig");
const storage = @import("storage.zig");
const edwin = @import("edwin_defs.zig");
const string = @import("string.zig");
const utils = @import("utils.zig");
const memmag = @import("memmag.zig");
const fasload = @import("fasload.zig");
const debug = @import("debug.zig");
const interp = @import("interp.zig");
const outf = @import("outf.zig");

const min_heap_delta: usize = 50;

inline fn bytesToBlocks(n: usize) usize {
    return (n + 1023) / 1024;
}

pub fn initExitScheme() callconv(.c) void {}

fn attemptTerminationBackout(code: c_int) void {
    outf.flushError();
    if (boot.critical_section_name != null or
        code == abi.term_halt or
        !obj.vectorP(abi.fixed_objects))
    {
        return;
    }

    const term_vector = obj.vectorRef(abi.fixed_objects, abi.fixobj_termination_proc_vector);
    if (!(obj.vectorP(term_vector) and
        code >= 0 and
        @as(usize, @intCast(code)) < obj.vectorLength(term_vector)))
    {
        return;
    }
    const handler = obj.vectorRef(term_vector, @intCast(code));
    if (handler == obj.sharp_f) {
        return;
    }

    const frame_size: usize = if (code == abi.term_no_error_handler) 5 else 4;
    abi.stackCheck(2 + @as(usize, @intCast(frame_size)) + 1);
    abi.pushCont(abi.rc_halt, obj.longToUnsignedFixnum(code));
    if (code == abi.term_no_error_handler) {
        abi.stackPush(obj.longToUnsignedFixnum(utils.death_blow));
    }
    abi.stackPush(abi.Registers[abi.regblock_val]);
    abi.stackPush(abi.Registers[abi.regblock_env]);
    abi.stackPush(abi.Registers[abi.regblock_expr]);
    abi.stackPush(handler);
    abi.stackPush(abi.makeApplyFrameHeader(frame_size));
    abi.abort_to_interpreter(abi.prim_no_trap_apply);
}

fn terminationPrefix(code: c_int) void {
    attemptTerminationBackout(code);
    abi.OS_restore_external_state();
    if (code == abi.term_halt) {
        if (!abi.option_batch_mode) {
            const idx: usize = @intCast((@intFromPtr(abi.Free) >> 3) % storage.term_halt_messages.len);
            outf.console("\n{s}\n", .{storage.term_halt_messages[idx]});
            outf.flushConsole();
        }
    } else {
        outf.fatal("\n", .{});
        const msg: ?[*:0]const u8 = if (code >= 0 and code <= abi.max_termination)
            storage.term_messages[@intCast(code)]
        else
            null;
        if (msg) |m| {
            outf.fatal("{s}", .{m});
        } else {
            outf.fatal("Unknown termination code 0x{x}", .{code});
        }
        if (boot.critical_section_name) |cs_name| {
            outf.fatal(" within critical section \"{s}\"", .{cs_name});
        }
        outf.fatal(".\n", .{});
    }
}

fn terminationSuffix(value: c_int) noreturn {
    edwinAutoSave();
    deleteTempFiles();
    outf.flushFatal();
    memmag.reset_memory();
    std.c.exit(value);
}

fn terminationSuffixTrace() noreturn {
    if (build_options.debugging and storage.trace_on_error) {
        outf.err("\n\n**** Stack trace ****\n\n", .{});
        debug.debug_stack_trace(outf.error_output);
    }
    terminationSuffix(1);
}

pub fn microcodeTermination(code: c_int) callconv(.c) noreturn {
    terminationPrefix(code);
    terminationSuffixTrace();
}

pub fn terminationNormal(value: c_int) callconv(.c) noreturn {
    terminationPrefix(abi.term_halt);
    terminationSuffix(value);
}

pub fn terminationInitError() callconv(.c) noreturn {
    terminationPrefix(abi.term_exit);
    terminationSuffix(1);
}

pub fn terminationEndOfComputation() callconv(.c) noreturn {
    terminationPrefix(abi.term_end_of_computation);
    debug.debug_print_expr(abi.Registers[abi.regblock_val], "Final result");
    outf.console("\n", .{});
    terminationSuffix(0);
}

pub fn terminationTrap() callconv(.c) noreturn {
    terminationPrefix(abi.term_trap);
    terminationSuffix(1);
}

pub fn terminationNoErrorHandler() callconv(.c) noreturn {
    terminationPrefix(abi.term_no_error_handler);
    if (utils.death_blow == abi.err_fasl_file_too_big) {
        var heap_size: usize = 0;
        var const_size: usize = 0;
        fasload.get_band_parameters(&heap_size, &const_size);
        outf.fatal("Try again with values at least as large as\n", .{});
        outf.fatal("  --heap {d}\n", .{min_heap_delta + bytesToBlocks(heap_size)});
        outf.fatal("  --constant {d}\n", .{bytesToBlocks(const_size)});
    }
    terminationSuffix(1);
}

pub fn terminationGcOutOfSpace() callconv(.c) noreturn {
    terminationPrefix(abi.term_gc_out_of_space);
    outf.fatal("You are out of space at the end of a garbage collection!\n", .{});
    outf.fatal(
        "Free = 0x{x}; heap_alloc_limit = 0x{x}; heap_end = 0x{x}\n",
        .{
            @intFromPtr(abi.Free),
            @intFromPtr(abi.heap_alloc_limit),
            @intFromPtr(abi.heap_end),
        },
    );
    outf.fatal("# words needed = {d}; # words available = {d}\n", .{ abi.gc_space_needed, abi.heapAvailable() });
    terminationSuffixTrace();
}

pub fn terminationEof() callconv(.c) noreturn {
    microcodeTermination(abi.term_eof);
}

pub fn terminationSignal(signal_name: ?[*:0]const u8) callconv(.c) noreturn {
    if (signal_name) |name| {
        terminationPrefix(abi.term_signal);
        outf.fatal("Killed by {s}.\n", .{name});
    } else {
        attemptTerminationBackout(abi.term_signal);
    }
    terminationSuffixTrace();
}

const AutoSaveCtx = struct {
    namestring: [*:0]const u8,
    start: [*]const u8,
    gap_start: [*]const u8,
    gap_end: [*]const u8,
    end: [*]const u8,
};

fn autoSaveWriteBody(raw: ?*anyopaque) callconv(.c) void {
    const ctx: *const AutoSaveCtx = @ptrCast(@alignCast(raw.?));
    outf.errLine("Auto-saving file \"{s}\"", .{ctx.namestring});
    const channel = abi.OS_open_output_file(ctx.namestring);
    const front_len = @intFromPtr(ctx.gap_start) - @intFromPtr(ctx.start);
    if (front_len > 0) {
        _ = abi.OS_channel_write(channel, ctx.start, front_len);
    }
    const back_len = @intFromPtr(ctx.end) - @intFromPtr(ctx.gap_end);
    if (back_len > 0) {
        _ = abi.OS_channel_write(channel, ctx.gap_end, back_len);
    }
    abi.OS_channel_close(channel);
}

fn edwinAutoSave() void {
    var position: obj.SchemeObject = if (obj.vectorP(abi.fixed_objects))
        obj.vectorRef(abi.fixed_objects, abi.fixobj_edwin_auto_save)
    else
        obj.empty_list;

    while (obj.pairP(position)) {
        const entry = obj.pairCar(position);
        position = obj.pairCdr(position);
        if (obj.pairP(entry) and
            edwin.groupP(obj.pairCar(entry)) and
            string.string_p(obj.pairCdr(entry)) and
            obj.vectorRef(obj.pairCar(entry), 16) == obj.sharp_t)
        {
            const group = obj.pairCar(entry);
            const namestring: [*:0]const u8 = @ptrCast(obj.legacyStringData(obj.pairCdr(entry)));
            var length: usize = 0;
            const start = edwin.groupText(group, &length);
            const end_ptr = start + @as(usize, @intCast(length));
            const gap_start = start + @as(usize, @intCast(edwin.groupGapStart(group)));
            const gap_end = start + @as(usize, @intCast(edwin.groupGapEnd(group)));
            if (@intFromPtr(start) < @intFromPtr(gap_start) or @intFromPtr(gap_end) < @intFromPtr(end_ptr)) {
                var new_state: interp.InterpreterState = .{};
                var ctx = AutoSaveCtx{
                    .namestring = namestring,
                    .start = start,
                    .gap_start = gap_start,
                    .gap_end = gap_end,
                    .end = end_ptr,
                };
                interp.bindInterpreterState(&new_state);
                _ = interp.scm_setjmp_try(&new_state.catch_env, &autoSaveWriteBody, &ctx);
                interp.unbindInterpreterState(&new_state);
            }
        }
    }
}

fn deleteFileBody(raw: ?*anyopaque) callconv(.c) void {
    const filename: [*:0]const u8 = @ptrCast(raw.?);
    abi.OS_file_remove(filename);
}

fn deleteTempFiles() void {
    var position: obj.SchemeObject = if (obj.vectorP(abi.fixed_objects))
        obj.vectorRef(abi.fixed_objects, abi.fixobj_files_to_delete)
    else
        obj.empty_list;

    while (obj.pairP(position)) {
        const entry = obj.pairCar(position);
        position = obj.pairCdr(position);
        if (string.string_p(entry)) {
            const filename: [*:0]const u8 = @ptrCast(obj.legacyStringData(entry));
            var new_state: interp.InterpreterState = .{};
            interp.bindInterpreterState(&new_state);
            _ = interp.scm_setjmp_try(&new_state.catch_env, &deleteFileBody, @ptrCast(@constCast(filename)));
            interp.unbindInterpreterState(&new_state);
        }
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&initExitScheme, .{ .name = "init_exit_scheme" });
        @export(&microcodeTermination, .{ .name = "Microcode_Termination" });
        @export(&terminationNormal, .{ .name = "termination_normal" });
        @export(&terminationInitError, .{ .name = "termination_init_error" });
        @export(&terminationEndOfComputation, .{ .name = "termination_end_of_computation" });
        @export(&terminationTrap, .{ .name = "termination_trap" });
        @export(&terminationNoErrorHandler, .{ .name = "termination_no_error_handler" });
        @export(&terminationGcOutOfSpace, .{ .name = "termination_gc_out_of_space" });
        @export(&terminationEof, .{ .name = "termination_eof" });
        @export(&terminationSignal, .{ .name = "termination_signal" });
    }
}

test "term edwinAutoSave, deleteTempFiles, and attemptTerminationBackout guards" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    abi.fixed_objects = abi.make_vector(0x20, obj.sharp_f, true);
    obj.vectorSet(abi.fixed_objects, abi.fixobj_edwin_auto_save, obj.empty_list);
    obj.vectorSet(abi.fixed_objects, abi.fixobj_files_to_delete, obj.empty_list);

    edwinAutoSave();
    deleteTempFiles();
    attemptTerminationBackout(abi.term_halt);

    boot.critical_section_name = "test";
    defer boot.critical_section_name = null;
    attemptTerminationBackout(abi.term_exit);
}
