// Derived from MIT/GNU Scheme C sources (`src/microcode/debug.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const fasl = @import("fasl.zig");
const storage = @import("storage.zig");
const returns = @import("returns.zig");
const intern = @import("intern.zig");
const hooks = @import("hooks.zig");
const primutl = @import("primutl.zig");
const string = @import("string.zig");
const list = @import("list.zig");

const max_list_print: usize = 10;

inline fn readStdinByte(ch: *u8) isize {
    if (builtin.os.tag == .windows) {
        const WinRead = struct {
            extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) c_int;
        };
        return @intCast(WinRead._read(0, @ptrCast(ch), 1));
    } else {
        const PosixRead = struct {
            extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
        };
        return PosixRead.read(0, @ptrCast(ch), 1);
    }
}

inline fn ptrAddr(p: anytype) usize {
    return if (@typeInfo(@TypeOf(p)) == .optional)
        (if (p) |nonnull| @intFromPtr(nonnull) else 0)
    else
        @intFromPtr(p);
}

fn compiledEntryFilename(entry: obj.SchemeObject) callconv(.c) [*:0]const u8 {
    const result = compiledEntryDebugFilename(entry);
    if (obj.legacyStringP(result) or string.string_p(result)) {
        return @ptrCast(obj.legacyStringData(result));
    }
    if (obj.pairP(result)) {
        return @ptrCast(obj.legacyStringData(obj.pairCar(result)));
    }
    return "**** filename not known ****";
}

comptime {
    if (build_options.cc_support) {
        @export(&compiledEntryFilename, .{ .name = "compiled_entry_filename" });
    }
}

fn compiledEntryDebugFilename(entry: obj.SchemeObject) obj.SchemeObject {
    const target = if (abi.cc_entry_closure_p(entry))
        abi.cc_closure_to_entry(entry)
    else
        entry;
    return compiledBlockDebugFilename(abi.cc_entry_to_block(target));
}

fn compiledBlockDebugFilename(block: obj.SchemeObject) obj.SchemeObject {
    const info = abi.cc_block_debugging_info(block);
    if (string.string_p(info) or
        (obj.pairP(info) and string.string_p(obj.pairCar(info)) and obj.fixnumP(obj.pairCdr(info))))
    {
        return info;
    }
    return obj.sharp_f;
}

pub export fn debug_print_env(stream: abi.OutfChannel, env: obj.SchemeObject) callconv(.c) void {
    const proc = if (obj.extendedFrameP(env)) obj.extendedFrameProc(env) else obj.envProc(env);
    const proc_type = obj.objectType(proc);
    if (!(proc_type == obj.tc_procedure or proc_type == obj.tc_extended_procedure)) {
        abi.outf(stream, "Not created by a procedure\n");
        return;
    }
    const lambda = obj.procLambda(proc);
    const params = obj.lambdaParams(lambda);
    const n_params: usize = @intCast(obj.lambdaNParams(lambda));
    const vals = obj.envVals(env);
    for (0..n_params) |i| {
        printExpression(stream, params[i], "Name");
        printExpression(stream, vals[i], " Value");
        abi.outf(stream, "\n");
    }
    if (obj.extendedFrameP(env)) {
        abi.outf(stream, "Extra bindings\n");
        const bindings = obj.extendedFrameBindings(env);
        const n_bindings: usize = @intCast(obj.extendedFrameLength(env));
        for (0..n_bindings) |i| {
            printExpression(stream, obj.pairCar(bindings[i]), "Name");
            printExpression(stream, obj.pairCdr(bindings[i]), " Value");
            abi.outf(stream, "\n");
        }
    }
}

fn printList(stream: abi.OutfChannel, pair_in: obj.SchemeObject) void {
    abi.outf(stream, "(");
    var count: usize = 0;
    var pair = pair_in;
    while ((obj.pairP(pair) or obj.weakPairP(pair)) and count < max_list_print) {
        if (count > 0) {
            abi.outf(stream, " ");
        }
        printExpression(stream, obj.pairCar(pair), if (obj.weakPairP(pair)) "{weak}" else "");
        pair = obj.pairCdr(pair);
        count += 1;
    }
    if (pair != obj.empty_list) {
        if (count == max_list_print) {
            abi.outf(stream, " ...");
        } else {
            abi.outf(stream, " . ");
            printExpression(stream, pair, "");
        }
    }
    abi.outf(stream, ")");
}

fn printVector(stream: abi.OutfChannel, vector: obj.SchemeObject) void {
    abi.outf(stream, "#(");
    const length: usize = @intCast(obj.vectorLength(vector));
    const end = @min(length, max_list_print);
    for (0..end) |i| {
        if (i > 0) {
            abi.outf(stream, " ");
        }
        printObject(stream, obj.vectorRef(vector, i));
    }
    if (end < length) {
        abi.outf(stream, "...[%zd more]", @as(isize, @intCast(length - end)));
    }
    abi.outf(stream, ")");
}

fn printBytevector(stream: abi.OutfChannel, bv: obj.SchemeObject) void {
    abi.outf(stream, "#u8(");
    const length: usize = @intCast(obj.bytevectorLength(bv));
    const end = @min(length, 20);
    for (0..end) |i| {
        if (i > 0) {
            abi.outf(stream, " ");
        }
        abi.outf(stream, "%d", @as(c_int, obj.bytevectorRef(bv, i)));
    }
    if (end < length) {
        abi.outf(stream, "...[%zd more]", @as(isize, @intCast(length - end)));
    }
    abi.outf(stream, ")");
}

fn printReturnName(stream: abi.OutfChannel, ret: obj.SchemeObject) void {
    if (returns.return_code_name(ret)) |name| {
        if (name[0] != 0) {
            abi.outf(stream, "%s", name);
            return;
        }
    }
    abi.outf(stream, "[0x%zx]", obj.objectDatum(ret));
}

fn printSimple(stream: abi.OutfChannel, object: obj.SchemeObject) void {
    const tc = obj.objectType(object);
    var name: ?[*:0]const u8 = null;
    if (tc < obj.n_type_codes) {
        name = storage.type_names[@intCast(tc)];
    }
    if (name) |n| {
        abi.outf(stream, "[%s", n);
    } else {
        abi.outf(stream, "[%#02x", @as(c_uint, @intCast(tc)));
    }
    abi.outf(stream, " %#zx]", obj.objectDatum(object));
}

fn printChar(stream: abi.OutfChannel, cp: c_uint) void {
    switch (cp) {
        '\\' => abi.outf(stream, "\\\\"),
        '"' => abi.outf(stream, "\\\""),
        '\t' => abi.outf(stream, "\\t"),
        '\n' => abi.outf(stream, "\\n"),
        0x0C => abi.outf(stream, "\\f"),
        else => {
            if (cp >= ' ' and cp <= '~') {
                abi.outf(stream, "%c", @as(c_int, @intCast(cp)));
            } else {
                abi.outf(stream, "\\x%x;", cp);
            }
        },
    }
}

fn printLegacyString(stream: abi.OutfChannel, str_obj: obj.SchemeObject) void {
    abi.outf(stream, "\"");
    const length: usize = @intCast(obj.legacyStringLength(str_obj));
    const long_enough: usize = if (length < 100) length else 90;
    const next = obj.legacyStringData(str_obj);
    for (0..long_enough) |i| {
        printChar(stream, next[i]);
    }
    if (length != long_enough) {
        abi.outf(stream, "...[%zd total chars]", @as(isize, @intCast(length)));
    }
    abi.outf(stream, "\"");
}

fn printUstring(stream: abi.OutfChannel, str_obj: obj.SchemeObject) void {
    const length: usize = @intCast(obj.ustringLength(str_obj));
    const long_enough: usize = if (length < 100) length else 90;
    var next = obj.ustringData(str_obj);
    const bytes_per_cp = obj.ustringBytesPerCp(str_obj);
    abi.outf(stream, "\"");
    for (0..long_enough) |_| {
        var cp: c_uint = next[0];
        next += 1;
        switch (bytes_per_cp) {
            1 => {},
            2 => {
                cp |= @as(c_uint, next[0]) << 8;
                next += 1;
            },
            0, 3 => {
                cp |= @as(c_uint, next[0]) << 8;
                cp |= @as(c_uint, next[1]) << 16;
                next += 2;
            },
            else => {},
        }
        printChar(stream, cp);
    }
    if (length != long_enough) {
        abi.outf(stream, "...[%zd total chars]", @as(isize, @intCast(length)));
    }
    abi.outf(stream, "\"");
}

fn printSymbol(stream: abi.OutfChannel, symbol: obj.SchemeObject) void {
    const name_str = obj.symbolName(symbol);
    const length: usize = @intCast(obj.legacyStringLength(name_str));
    const limit: usize = @min(length, 64);
    const next = obj.legacyStringData(name_str);
    for (0..limit) |i| {
        const c = next[i];
        if (c < 0x80) {
            abi.outf(stream, "%c", @as(c_int, c));
        } else {
            abi.outf(stream, "\\x%02x", @as(c_int, c));
        }
    }
    if (limit < length) {
        abi.outf(stream, "...");
    }
}

fn printFilename(stream: abi.OutfChannel, filename: obj.SchemeObject) void {
    const length: usize = @intCast(obj.legacyStringLength(filename));
    const data = obj.legacyStringData(filename);
    var slash_idx: usize = 0;
    for (0..length) |i| {
        if (data[i] == '/') {
            slash_idx = i + 1;
        }
    }
    abi.outf(stream, "\"%s\"", @as([*:0]const u8, @ptrCast(data + slash_idx)));
}

// DEFINE_PRIMITIVE ("DEBUGGING-PRINTER", Prim_debugging_printer, 1, 1,
//   "A cheap, built-in printer intended for debugging the interpreter.")
pub export fn Prim_debugging_printer() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    printObject(abi.ERROR_OUTPUT, abi.argRef(1));
    abi.outf_error("\n");
    return obj.sharp_f;
}

fn printExpression(stream: abi.OutfChannel, expr: obj.SchemeObject, prefix: [*:0]const u8) void {
    if (prefix[0] != 0) {
        abi.outf(stream, "%s: ", prefix);
    }
    printObject(stream, expr);
}

pub export fn debug_print_expr(expr: obj.SchemeObject, prefix: [*:0]const u8) callconv(.c) void {
    printExpression(abi.ERROR_OUTPUT, expr, prefix);
}

fn printCompiledEntry(stream: abi.OutfChannel, entry_in: obj.SchemeObject) void {
    var entry = entry_in;
    var closure_p = false;
    var cet: abi.CcEntryType = undefined;
    var original_entry: obj.SchemeObject = 0;

    const type_string: [*:0]const u8 = if (abi.read_cc_entry_type(&cet, obj.objectRawAddress(entry)))
        "UNKNOWN"
    else switch (cet.marker) {
        .procedure, .closure => blk: {
            if (abi.cc_entry_closure_p(entry)) {
                original_entry = entry;
                entry = abi.cc_closure_to_entry(entry);
                closure_p = true;
                break :blk "compiled-closure";
            }
            break :blk "compiled-procedure";
        },
        .continuation, .internal_continuation, .return_to_interpreter => "compiled-return-address",
        .expression => "compiled-expression",
        .internal_procedure, .trampoline => "compiled-entry",
    };

    abi.outf(
        stream,
        "[%s offset: %#zx entry: %#zx",
        type_string,
        abi.cc_entry_to_block_offset(entry),
        obj.objectDatum(entry),
    );
    if (closure_p) {
        abi.outf(stream, " address: %#zx", obj.objectDatum(original_entry));
    }

    const filename = compiledEntryDebugFilename(entry);
    if (string.string_p(filename)) {
        abi.outf(stream, " file: ");
        printFilename(stream, filename);
    } else if (obj.pairP(filename)) {
        abi.outf(stream, " file: ");
        printFilename(stream, obj.pairCar(filename));
        abi.outf(stream, " block: %zd", obj.fixnumToLong(obj.pairCdr(filename)));
    }
    abi.outf(stream, "]");
}

fn constantString(object: obj.SchemeObject) ?[*:0]const u8 {
    return switch (object) {
        obj.sharp_f => "#f",
        obj.sharp_t => "#t",
        obj.unspecific => "#!unspecific",
        obj.optional_marker => "#!optional",
        obj.rest_marker => "#!rest",
        obj.key_marker => "#!key",
        obj.eof_object => "#!eof",
        obj.default_object => "#!default",
        obj.empty_list => "()",
        obj.gc_reclaimed => "#!reclaimed",
        else => null,
    };
}

fn anonymousProcedureNameP(name: obj.SchemeObject) bool {
    const anon = "#[unnamed-procedure]";
    return name == intern.find_symbol(anon.len, anon);
}

fn printLambda(stream: abi.OutfChannel, lambda: obj.SchemeObject) void {
    const names = obj.lambdaNames(lambda);
    var scan = obj.vectorLoc(names, 0);
    const end = obj.vectorLoc(names, @intCast(obj.vectorLength(names)));
    const lambda_name = scan[0];
    scan += 1;
    if (anonymousProcedureNameP(lambda_name)) {
        abi.outf(stream, "[lambda (");
        if (@intFromPtr(scan) < @intFromPtr(end)) {
            printSymbol(stream, scan[0]);
            scan += 1;
        }
    } else {
        abi.outf(stream, "[named-lambda (");
        printSymbol(stream, lambda_name);
    }
    while (@intFromPtr(scan) < @intFromPtr(end)) : (scan += 1) {
        abi.outf(stream, " ");
        printSymbol(stream, scan[0]);
    }
    abi.outf(stream, ") %#zx]", obj.objectDatum(lambda));
}

fn printExtendedLambda(stream: abi.OutfChannel, lambda: obj.SchemeObject) void {
    const names = obj.elambdaNames(lambda);
    var scan = obj.vectorLoc(names, 0);
    const lambda_name = scan[0];
    scan += 1;
    const anon = anonymousProcedureNameP(lambda_name);

    const end_reqs = scan + @as(usize, @intCast(obj.elambdaReqs(lambda)));
    const end_opts = end_reqs + @as(usize, @intCast(obj.elambdaOpts(lambda)));
    const end_rest = end_opts + @as(usize, @intCast(obj.elambdaRest(lambda)));

    if (anon and @intFromPtr(scan) == @intFromPtr(end_opts)) {
        abi.outf(stream, "[lambda ");
        if (@intFromPtr(end_opts) == @intFromPtr(end_rest)) {
            abi.outf(stream, "()");
        } else {
            printSymbol(stream, scan[0]);
        }
    } else {
        if (anon) {
            abi.outf(stream, "[lambda (");
        } else {
            abi.outf(stream, "[named-lambda (");
            printSymbol(stream, lambda_name);
            abi.outf(stream, " ");
        }
        const first = scan;
        while (@intFromPtr(scan) < @intFromPtr(end_rest)) : (scan += 1) {
            if (@intFromPtr(scan) > @intFromPtr(first)) {
                abi.outf(stream, " ");
            }
            if (@intFromPtr(scan) == @intFromPtr(end_reqs) and @intFromPtr(scan) < @intFromPtr(end_opts)) {
                abi.outf(stream, "%s ", constantString(obj.optional_marker).?);
            } else if (@intFromPtr(scan) == @intFromPtr(end_opts) and @intFromPtr(scan) < @intFromPtr(end_rest)) {
                abi.outf(stream, ". ");
            }
            printSymbol(stream, scan[0]);
        }
        abi.outf(stream, ")");
    }
    abi.outf(stream, " %#zx]", obj.objectDatum(lambda));
}

fn printObject(stream: abi.OutfChannel, object: obj.SchemeObject) void {
    if (constantString(object)) |s| {
        abi.outf(stream, "%s", s);
        return;
    }
    if (object == abi.return_to_interpreter) {
        abi.outf(stream, "[return-to-interpreter]");
        return;
    }
    if (object == abi.reflect_to_interface) {
        abi.outf(stream, "[reflect-to-interface]");
        return;
    }

    switch (obj.objectType(object)) {
        obj.tc_access => {
            abi.outf(stream, "[access ");
            printSymbol(stream, obj.accessName(object));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_assignment => {
            abi.outf(stream, "[set! ");
            printSymbol(stream, obj.variableName(obj.assignmentName(object)));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_definition => {
            abi.outf(stream, "[define ");
            printSymbol(stream, obj.definitionName(object));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_character_string => printLegacyString(stream, object),
        obj.tc_bytevector => printBytevector(stream, object),
        obj.tc_unicode_string => printUstring(stream, object),
        obj.tc_fixnum => abi.outf(stream, "%zd", obj.fixnumToLong(object)),
        obj.tc_big_flonum => abi.outf(stream, "%lf", obj.flonumToDouble(object)),
        obj.tc_weak_cons, obj.tc_list => printList(stream, object),
        obj.tc_vector => printVector(stream, object),
        obj.tc_false => printSimple(stream, object),
        obj.tc_uninterned_symbol => {
            abi.outf(stream, "[uninterned ");
            printSymbol(stream, object);
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_interned_symbol => printSymbol(stream, object),
        obj.tc_variable => {
            abi.outf(stream, "[variable ");
            printSymbol(stream, obj.variableName(object));
            if (obj.variableSafeP(object)) {
                abi.outf(stream, " (safe)");
            }
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_combination => {
            abi.outf(stream, "[combination ");
            printObject(stream, obj.combinationExpr(object, 0));
            abi.outf(stream, " ... (%zd args)", @as(isize, @intCast(obj.combinationSize(object) - 1)));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_environment => {
            abi.outf(stream, "[environment from ");
            printObject(stream, if (obj.extendedFrameP(object)) obj.extendedFrameProc(object) else obj.envProc(object));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_extended_lambda => printExtendedLambda(stream, object),
        obj.tc_extended_procedure => {
            abi.outf(stream, "[extended-procedure ");
            printObject(stream, obj.procLambda(object));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_lambda => printLambda(stream, object),
        obj.tc_primitive => {
            abi.outf(stream, "[primitive ");
            _ = printPrimitiveName(stream, object);
            abi.outf(stream, "]");
        },
        obj.tc_procedure => {
            abi.outf(stream, "[procedure ");
            printObject(stream, obj.procLambda(object));
            abi.outf(stream, " %#zx]", obj.objectDatum(object));
        },
        obj.tc_reference_trap => {
            if (obj.objectDatum(object) <= obj.trap_max_immediate) {
                printSimple(stream, object);
            } else {
                abi.outf(stream, "[reference-trap");
                printExpression(stream, obj.ptrRefTrapTag(object), " tag");
                printExpression(stream, obj.ptrRefTrapCache(object), " cache");
                abi.outf(stream, " %#zx]", obj.objectDatum(object));
            }
        },
        obj.tc_return_code => {
            abi.outf(stream, "[return-code ");
            printReturnName(stream, object);
            abi.outf(stream, "]");
        },
        obj.tc_constant => printSimple(stream, object),
        obj.tc_character => {
            const code = obj.objectDatum(object);
            const name: ?[*:0]const u8 = switch (code) {
                0x00 => "null",
                0x07 => "alarm",
                0x08 => "backspace",
                0x09 => "tab",
                0x0A => "newline",
                0x0D => "return",
                0x1B => "escape",
                0x20 => "space",
                0x7F => "delete",
                else => null,
            };
            if (name) |n| {
                abi.outf(stream, "#\\%s", n);
            } else if (code > 0x20 and code < 0x7F) {
                abi.outf(stream, "#\\%c", @as(c_int, @intCast(code)));
            } else {
                abi.outf(stream, "#\\x%zx", code);
            }
        },
        obj.tc_compiled_entry => {
            if (build_options.cc_support) {
                printCompiledEntry(stream, object);
            } else {
                printSimple(stream, object);
            }
        },
        obj.tc_compiled_return => {
            if (build_options.cc_support) {
                const ret_addr = obj.objectRawAddress(object);
                const entry_addr = if (build_options.cc_is_native)
                    abi.cc_return_address_to_entry_address(ret_addr)
                else
                    ret_addr;
                const entry = obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(@intFromPtr(entry_addr)));
                printCompiledEntry(stream, entry);
            } else {
                printSimple(stream, object);
            }
        },
        else => printSimple(stream, object),
    }
}

pub export fn debug_print(object: obj.SchemeObject) callconv(.c) void {
    if (obj.procedureFrameP(object)) {
        debug_print_env(abi.ERROR_OUTPUT, object);
    } else {
        printObject(abi.ERROR_OUTPUT, object);
        abi.outf_error("\n");
    }
    abi.outf_flush_error();
}

fn printOneContinuationFrame(stream: abi.OutfChannel, ret: obj.SchemeObject, sp: *[*]obj.SchemeObject) bool {
    abi.outf(stream, "\n    ");
    printExpression(stream, ret, "Return code");
    abi.outf(stream, "\n    ");
    const expr = sp.*[0];
    sp.* += 1;
    printExpression(stream, expr, "Expression");
    abi.outf(stream, "\n");
    const ret_code = obj.objectDatum(ret);
    if (ret_code == abi.rc_end_of_computation or ret_code == abi.rc_halt) {
        return true;
    }
    if (ret_code == abi.rc_join_stacklets) {
        sp.* = hooks.control_point_start(expr);
    }
    return false;
}

pub export fn Print_One_Continuation_Frame(ret: obj.SchemeObject) callconv(.c) bool {
    var scan = abi.stack_pointer;
    return printOneContinuationFrame(abi.ERROR_OUTPUT, ret, &scan);
}

fn dumpStack(stream: abi.OutfChannel, sp_in: [*]obj.SchemeObject, limit_in: [*]obj.SchemeObject, count: c_int) void {
    var sp = sp_in;
    var limit = limit_in;
    var done: c_int = 0;
    while ((count == 0 or done < count) and @intFromPtr(sp) < @intFromPtr(limit)) {
        abi.outf(stream, "%#zx: ", @as(usize, @intCast(@intFromPtr(sp))));
        const item = sp[0];
        sp += 1;
        printObject(stream, item);
        abi.outf(stream, "\n");
        done += 1;
        if (obj.returnCodeP(item) and obj.objectDatum(item) == abi.rc_join_stacklets) {
            const cp = sp[0];
            sp += 1;
            sp = hooks.control_point_start(cp);
            limit = hooks.control_point_end(cp);
        }
    }
}

pub export fn Stack(count: c_int) callconv(.c) void {
    dumpStack(abi.ERROR_OUTPUT, abi.stack_pointer, abi.stack_end, count);
}

// debug_stack_trace() relies on: (a) only pushCont() puts a return code on the stack;
// (b) pushCont() pushes the expression first.
pub export fn debug_stack_trace(stream: abi.OutfChannel) callconv(.c) void {
    var scan = abi.stack_pointer;
    while (true) {
        abi.outf(stream, "{%#zx}", @as(usize, @intCast(@intFromPtr(scan))));
        const object = scan[0];
        scan += 1;
        if (obj.returnCodeP(object)) {
            if (printOneContinuationFrame(stream, object, &scan)) {
                break;
            }
        } else {
            printExpression(stream, object, "  ...");
            if (obj.objectType(object) == obj.tc_manifest_nm_vector) {
                abi.outf(stream, " (skipping)");
                scan += @as(usize, @intCast(obj.objectDatum(object)));
            }
            abi.outf(stream, "\n");
        }
    }
    abi.outf_flush(stream);
}

pub export fn debug_print_stack() callconv(.c) void {
    debug_stack_trace(abi.ERROR_OUTPUT);
}

fn primitiveNumber(primitive: obj.SchemeObject) usize {
    return obj.objectDatum(primitive);
}

fn primitiveName(primitive: obj.SchemeObject) ?[*:0]const u8 {
    const num = primitiveNumber(primitive);
    if (num >= primutl.MAX_PRIMITIVE) return null;
    const table = primutl.Primitive_Name_Table orelse return null;
    return table[@intCast(num)];
}

fn primitiveArity(primitive: obj.SchemeObject) c_int {
    const num = primitiveNumber(primitive);
    if (num >= primutl.MAX_PRIMITIVE) return abi.unknown_primitive_arity;
    const table = primutl.Primitive_Arity_Table orelse return abi.unknown_primitive_arity;
    return table[@intCast(num)];
}

fn printPrimitiveName(stream: abi.OutfChannel, primitive: obj.SchemeObject) bool {
    if (primitiveName(primitive)) |name| {
        abi.outf(stream, "%s", name);
        return true;
    }
    abi.outf(stream, "Unknown primitive %#08zx", primitiveNumber(primitive));
    return false;
}

// Assumes it's called when LEXPR_ACTUALS is set.
pub export fn debug_print_primitive(primitive: obj.SchemeObject) callconv(.c) void {
    abi.outf_error("Primitive: ");
    const known = printPrimitiveName(abi.ERROR_OUTPUT, primitive);
    abi.outf_error("\n");

    const nargs: usize = if (known) blk: {
        const arity = primitiveArity(primitive);
        break :blk if (arity < 0) @intCast(abi.getLexprActuals()) else @intCast(arity);
    } else 0;

    var buffer: [40]u8 = undefined;
    for (0..nargs) |i| {
        if (std.fmt.bufPrint(buffer[0 .. buffer.len - 1], "...Arg {d}", .{i + 1})) |written| {
            buffer[written.len] = 0;
            printExpression(abi.ERROR_OUTPUT, abi.stackRef(i), @ptrCast(&buffer));
        } else |_| {
            printExpression(abi.ERROR_OUTPUT, abi.stackRef(i), "...Arg");
        }
        abi.outf_error("\n");
    }
}

// Heap verification & inspection tools (active when build_options.debugging is true)

inline fn validAddrUsize(address: usize) bool {
    const const_start = ptrAddr(storage.constant_start);
    const const_next = ptrAddr(storage.constant_alloc_next);
    if (address >= const_start and address < const_next) {
        return true;
    }
    if (abi.code_address_p(@ptrFromInt(address))) {
        return true;
    }
    const h_start = ptrAddr(storage.heap_start);
    const h_free = ptrAddr(storage.Free);
    return address >= h_start and address < h_free;
}

inline fn validAddressP(address: [*]const obj.SchemeObject) bool {
    return validAddrUsize(@intFromPtr(address));
}

fn dumpWord(addr: [*]const obj.SchemeObject) void {
    const bytes: [*]const u8 = @ptrCast(addr);
    abi.outf_error("%#zx: ", @as(usize, @intCast(@intFromPtr(addr))));
    for (0..@sizeOf(obj.SchemeObject)) |i| {
        const b = bytes[i];
        if (b > 0x20 and b < 0x7F) {
            abi.outf_error(" %2c", @as(c_int, b));
        } else {
            abi.outf_error(" %02x", @as(c_int, b));
        }
    }
    abi.outf_error("\n");
}

fn nextAddr(addr: [*]obj.SchemeObject) [*]obj.SchemeObject {
    const object = addr[0];
    switch (obj.objectType(object)) {
        obj.tc_linkage_section => {
            if (build_options.cc_support) {
                const section_type: c_uint = @intCast(obj.objectDatum(object) >> 16);
                switch (section_type) {
                    @intFromEnum(abi.LinkageSectionType.global_operator),
                    @intFromEnum(abi.LinkageSectionType.operator),
                    => {
                        const n_words: usize = @intCast(obj.objectDatum(object) & 0xFFFF);
                        return addr + (1 + n_words);
                    },
                    @intFromEnum(abi.LinkageSectionType.reference),
                    @intFromEnum(abi.LinkageSectionType.assignment),
                    => return addr + 1,
                    else => {
                        abi.outf_error("Invalid linkage section type: %d\n", @as(c_int, @intCast(section_type)));
                        return addr + 1;
                    },
                }
            }
            return addr + 1;
        },
        obj.tc_manifest_closure => {
            if (build_options.cc_support) {
                return abi.compiled_closure_objects(addr + 1);
            }
            return addr + 1;
        },
        obj.tc_manifest_nm_vector => {
            const n_words: usize = @intCast(obj.objectDatum(object));
            return addr + (1 + n_words);
        },
        else => return addr + 1,
    }
}

fn dumpObject(addr_in: [*]obj.SchemeObject) void {
    var addr = addr_in;
    const object = addr[0];
    abi.outf_error("%#zx: ", @as(usize, @intCast(@intFromPtr(addr))));
    printObject(abi.ERROR_OUTPUT, object);
    abi.outf_error("\n");

    const free_addr = ptrAddr(storage.Free);
    var end_addr = @intFromPtr(nextAddr(addr));
    if (end_addr > free_addr) {
        end_addr = free_addr;
    }
    addr += 1;
    while (@intFromPtr(addr) < end_addr) : (addr += 1) {
        dumpWord(addr);
    }
    if (@intFromPtr(addr) == free_addr) {
        abi.outf_error("%#zx: Free\n", @as(usize, @intCast(@intFromPtr(addr))));
    }
}

const save_count: usize = 16;
var saved_addrs: [save_count]?[*]obj.SchemeObject = @splat(null);
var saved_index: usize = 0;

fn dumpHeapAreaAt(addr: [*]obj.SchemeObject, area: [*]obj.SchemeObject, end: [*]obj.SchemeObject) void {
    std.debug.assert(@intFromPtr(area) <= @intFromPtr(addr) and @intFromPtr(addr) < @intFromPtr(end));
    saved_addrs = @splat(null);
    saved_index = 0;

    var scan = area;
    while (@intFromPtr(scan) < @intFromPtr(addr)) {
        saved_addrs[saved_index] = scan;
        saved_index = (saved_index + 1) % save_count;
        scan = nextAddr(scan);
    }
    var i = saved_index;
    while (true) {
        if (saved_addrs[i]) |saved| {
            dumpObject(saved);
        }
        i = (i + 1) % save_count;
        if (i == saved_index) break;
    }
    abi.outf_error("=> ");
    var printed: usize = 0;
    while (printed < save_count and @intFromPtr(scan) < @intFromPtr(end)) {
        dumpObject(scan);
        printed += 1;
        scan = nextAddr(scan);
    }
}

fn dumpHeapAt(addr: ?[*]obj.SchemeObject) callconv(.c) void {
    const a = ptrAddr(addr);
    if (ptrAddr(storage.constant_start) <= a and a < ptrAddr(storage.constant_alloc_next)) {
        abi.outf_error(
            "Scanning constant area (%#zx - %#zx):\n",
            @as(usize, @intCast(ptrAddr(storage.constant_start))),
            @as(usize, @intCast(ptrAddr(storage.constant_alloc_next))),
        );
        dumpHeapAreaAt(addr.?, storage.constant_start.?, storage.constant_alloc_next.?);
    } else if (ptrAddr(storage.heap_start) <= a and a < ptrAddr(storage.Free)) {
        abi.outf_error(
            "Scanning heap area (%#zx - %#zx):\n",
            @as(usize, @intCast(ptrAddr(storage.heap_start))),
            @as(usize, @intCast(ptrAddr(storage.Free))),
        );
        dumpHeapAreaAt(addr.?, storage.heap_start.?, storage.Free.?);
    } else {
        abi.outf_error("%#zx: not a heap address\n", @as(usize, @intCast(a)));
    }
    abi.outf_flush_error();
}

fn verifyObject(object: obj.SchemeObject) bool {
    return abi.gc_type_code(@intCast(obj.objectType(object))) != @intFromEnum(abi.GcType.undefined);
}

fn verifyTuple(object: obj.SchemeObject, size: usize, name: [*:0]const u8, address: usize) bool {
    const location = obj.objectAddress(object);
    if (!validAddressP(location)) {
        abi.outf_error("%#zx: Invalid %s\n", address, name);
        return false;
    }
    for (0..size) |i| {
        const slot = obj.memoryLoc(object, i);
        if (!(validAddressP(slot) and verifyObject(slot[0]))) {
            abi.outf_error("%#zx: Invalid %s (word %d)\n", address, name, @as(c_int, @intCast(i)));
            return false;
        }
    }
    return true;
}

fn verifyVector(object: obj.SchemeObject, address: usize) bool {
    const location = obj.objectAddress(object);
    if (!validAddressP(location)) {
        abi.outf_error("%#zx: Invalid vector\n", address);
        return false;
    }
    const header = obj.memoryRef(object, 0);
    const length = obj.objectDatum(header);
    const header_type = obj.objectType(header);
    if (header_type != obj.tc_manifest_vector and header_type != obj.tc_manifest_nm_vector) {
        abi.outf_error("%#zx: Invalid vector header\n", address);
        return false;
    }
    if (!validAddressP(location + @as(usize, @intCast(length)))) {
        abi.outf_error("%#zx: Invalid vector length\n", address);
        return false;
    }
    if (length > 1000000) {
        abi.outf_error("%#zx: Extraordinary vector size: %zd\n", address, @as(isize, @intCast(length)));
    }
    return true;
}

fn verifyCompiled(object: obj.SchemeObject, address: usize) bool {
    const entry_raw_addr = @intFromPtr(obj.objectRawAddress(object));
    if (!validAddrUsize(entry_raw_addr)) {
        abi.outf_error("%#zx: Invalid entry\n", address);
        return false;
    }
    var block_addr = entry_raw_addr;
    while (true) {
        var ceo: abi.CcEntryOffset = undefined;
        if (abi.read_cc_entry_offset(&ceo, @ptrFromInt(block_addr))) {
            abi.outf_error("%#zx: Invalid entry format\n", address);
            return false;
        }
        std.debug.assert(ceo.offset > 0);
        block_addr -%= @as(usize, @intCast(ceo.offset)) * @sizeOf(fasl.Insn);
        if (!validAddrUsize(block_addr)) {
            abi.outf_error("%#zx: Invalid entry offset\n", address);
            return false;
        }
        if (!ceo.continued_p) {
            if (block_addr % @sizeOf(obj.SchemeObject) != 0) {
                abi.outf_error("%#zx: Invalid block alignment\n", address);
                return false;
            }
            const block_ptr: [*]const obj.SchemeObject = @ptrFromInt(block_addr);
            const block_header = block_ptr[0];
            const block_end_addr = block_addr + @as(usize, @intCast(1 + obj.objectDatum(block_header))) * @sizeOf(obj.SchemeObject);
            if (block_end_addr < entry_raw_addr) {
                abi.outf_error("%#zx: Invalid block size\n", address);
                return false;
            }
            const header_type = obj.objectType(block_header);
            if (!(header_type == obj.tc_manifest_vector or header_type == obj.tc_manifest_closure)) {
                abi.outf_error("%#zx: Invalid block header\n", address);
                return false;
            }
            break;
        }
    }
    return true;
}

fn verifyHeapArea(area_in: [*]obj.SchemeObject, end: [*]obj.SchemeObject) bool {
    var area = area_in;
    var complaints: usize = 0;

    while (@intFromPtr(area) < @intFromPtr(end)) {
        const object = area[0];
        const tc = obj.objectType(object);
        const code = abi.gc_type_code(@intCast(tc));
        const area_addr: usize = @intCast(@intFromPtr(area));
        switch (code) {
            @intFromEnum(abi.GcType.undefined) => {
                abi.outf_error("%#zx: Invalid object type: %#x\n", area_addr, @as(c_uint, @intCast(tc)));
                return false;
            },
            @intFromEnum(abi.GcType.non_pointer) => {
                area += 1;
            },
            @intFromEnum(abi.GcType.cell) => {
                if (!verifyTuple(object, 1, "cell", area_addr)) complaints += 1;
                area += 1;
            },
            @intFromEnum(abi.GcType.pair) => {
                if (!verifyTuple(object, 2, "pair", area_addr)) complaints += 1;
                area += 1;
            },
            @intFromEnum(abi.GcType.triple) => {
                if (!verifyTuple(object, 3, "triple", area_addr)) complaints += 1;
                area += 1;
            },
            @intFromEnum(abi.GcType.quadruple) => {
                if (!verifyTuple(object, 4, "quadruple", area_addr)) complaints += 1;
                area += 1;
            },
            @intFromEnum(abi.GcType.vector) => {
                if (!verifyVector(object, area_addr)) complaints += 1;
                area += 1;
            },
            @intFromEnum(abi.GcType.special) => {
                switch (tc) {
                    obj.tc_broken_heart => {
                        area += 1;
                    },
                    obj.tc_reference_trap => {
                        if (obj.objectDatum(object) > obj.trap_max_immediate) {
                            if (!(verifyObject(obj.memoryRef(object, 0)) and verifyObject(obj.memoryRef(object, 1)))) {
                                abi.outf_error("%#zx: Invalid reference trap\n", area_addr);
                                complaints += 1;
                            }
                        }
                        area += 1;
                    },
                    obj.tc_linkage_section => {
                        const section_type: c_uint = @intCast(obj.objectDatum(object) >> 16);
                        switch (section_type) {
                            @intFromEnum(abi.LinkageSectionType.global_operator),
                            @intFromEnum(abi.LinkageSectionType.operator),
                            => {
                                const n_words: usize = @intCast(obj.objectDatum(object) & 0xFFFF);
                                const next = area + (1 + n_words);
                                if (@intFromPtr(next) > @intFromPtr(end)) {
                                    abi.outf_error("%#zx: Invalid linkage section size: %zd\n", area_addr, @as(isize, @intCast(n_words)));
                                    return false;
                                } else if (n_words > 1000) {
                                    abi.outf_error("%#zx: Extraordinary linkage section size: %zd\n", area_addr, @as(isize, @intCast(n_words)));
                                }
                                area = next;
                            },
                            @intFromEnum(abi.LinkageSectionType.reference),
                            @intFromEnum(abi.LinkageSectionType.assignment),
                            => {
                                area += 1;
                            },
                            else => {
                                abi.outf_error("%#zx: Invalid linkage section type: %#x\n", area_addr, section_type);
                                complaints += 1;
                                area += 1;
                            },
                        }
                    },
                    obj.tc_manifest_closure => {
                        if (build_options.cc_support) {
                            area = abi.compiled_closure_objects(area + 1);
                        } else {
                            abi.outf_error("%#zx: Invalid special\n", area_addr);
                            complaints += 1;
                            area += 1;
                        }
                    },
                    obj.tc_manifest_nm_vector => {
                        const n_words: usize = @intCast(obj.objectDatum(object));
                        const next = area + (1 + n_words);
                        if (@intFromPtr(next) > @intFromPtr(end)) {
                            abi.outf_error("%#zx: Invalid nm-vector size: %zd\n", area_addr, @as(isize, @intCast(n_words)));
                            return false;
                        } else if (n_words > 1000000) {
                            abi.outf_error("%#zx: Extraordinary nm-vector size: %zd\n", area_addr, @as(isize, @intCast(n_words)));
                        }
                        area = next;
                    },
                    else => {
                        abi.outf_error("%#zx: Invalid special\n", area_addr);
                        complaints += 1;
                        area += 1;
                    },
                }
            },
            @intFromEnum(abi.GcType.compiled_entry) => {
                if (build_options.cc_support) {
                    if (!verifyCompiled(object, area_addr)) complaints += 1;
                    area += 1;
                } else {
                    abi.outf_error("%#zx: unknown gc type code: %#x\n", area_addr, @as(c_uint, @intCast(code)));
                    complaints += 1;
                    area += 1;
                }
            },
            @intFromEnum(abi.GcType.compiled_return) => {
                if (build_options.cc_support) {
                    abi.outf_error("%#zx: XXX not implemented", area_addr);
                } else {
                    abi.outf_error("%#zx: unknown gc type code: %#x\n", area_addr, @as(c_uint, @intCast(code)));
                }
                complaints += 1;
                area += 1;
            },
            else => {
                abi.outf_error("%#zx: unknown gc type code: %#x\n", area_addr, @as(c_uint, @intCast(code)));
                complaints += 1;
                area += 1;
            },
        }
    }

    if (@intFromPtr(area) != @intFromPtr(end)) {
        abi.outf_error("%#zx: Invalid end address\n", @as(usize, @intCast(@intFromPtr(area))));
        return false;
    }
    return complaints == 0;
}

fn verifyStack(sp_in: [*]obj.SchemeObject, bottom: [*]obj.SchemeObject) callconv(.c) bool {
    var sp = sp_in;
    var complaints: usize = 0;
    while (@intFromPtr(sp) < @intFromPtr(bottom)) {
        const object = sp[0];
        sp += 1;
        const tc = obj.objectType(object);
        if (tc == obj.tc_manifest_nm_vector) {
            const n_words = obj.objectDatum(object);
            if (n_words > 1000) {
                abi.outf_error("%#zx: Extraordinary finger size: %zd\n", @as(usize, @intCast(@intFromPtr(sp))), @as(isize, @intCast(n_words)));
            }
            sp += @as(usize, @intCast(n_words));
        } else if (tc == obj.tc_manifest_closure or
            tc == obj.tc_broken_heart or
            abi.gc_type_code(@intCast(tc)) == @intFromEnum(abi.GcType.undefined))
        {
            abi.outf_error("%#zx: Invalid stack slot: ", @as(usize, @intCast(@intFromPtr(sp))));
            printObject(abi.ERROR_OUTPUT, object);
            abi.outf_error("\n");
            complaints += 1;
        }
    }
    return complaints == 0;
}

pub export fn debug_verify_heap() callconv(.c) bool {
    if (build_options.debugging) {
        const c = verifyHeapArea(storage.constant_start.?, storage.constant_alloc_next.?);
        const h = verifyHeapArea(storage.heap_start.?, storage.Free.?);
        const s = verifyStack(storage.stack_pointer.?, storage.stack_end.?);
        abi.outf_flush_error();
        return c and h and s;
    }
    return true;
}

comptime {
    if (build_options.debugging) {
        @export(&dumpHeapAt, .{ .name = "dump_heap_at" });
        @export(&verifyStack, .{ .name = "verify_stack" });
    }
}

// DEFINE_PRIMITIVE ("VERIFY-HEAP", Prim_verify_heap, 0, 0,
//   "Validate the heap.\n\
// Complains if a scan of the heap encounters anything unexpected.\n\
// Returns #T if the scan was successful and #F if there were any complaints.")
pub export fn Prim_verify_heap() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    return obj.booleanToObject(debug_verify_heap());
}

// Interactive debug flags

const DebugFlag = struct {
    name: [*:0]const u8,
    ptr: *bool,
};

const debug_flags = [_]DebugFlag{
    .{ .name = "Eval_Debug", .ptr = &storage.eval_debug },
    .{ .name = "Hex_Input_Debug", .ptr = &storage.hex_input_debug },
    .{ .name = "File_Load_Debug", .ptr = &storage.file_load_debug },
    .{ .name = "Reloc_Debug", .ptr = &storage.reloc_debug },
    .{ .name = "Intern_Debug", .ptr = &storage.intern_debug },
    .{ .name = "Cont_Debug", .ptr = &storage.cont_debug },
    .{ .name = "Primitive_Debug", .ptr = &storage.primitive_debug },
    .{ .name = "Lookup_Debug", .ptr = &storage.lookup_debug },
    .{ .name = "Define_Debug", .ptr = &storage.define_debug },
    .{ .name = "GC_Debug", .ptr = &storage.gc_debug },
    .{ .name = "Upgrade_Debug", .ptr = &storage.upgrade_debug },
    .{ .name = "Dump_Debug", .ptr = &storage.dump_debug },
    .{ .name = "Trace_On_Error", .ptr = &storage.trace_on_error },
    .{ .name = "Per_File", .ptr = &storage.per_file },
    .{ .name = "Bignum_Debug", .ptr = &storage.bignum_debug },
    .{ .name = "Print_Errors", .ptr = &storage.print_errors },
};

fn findFlag(flag_number: isize) ?*bool {
    if (flag_number < 0 or @as(usize, @intCast(flag_number)) >= debug_flags.len) {
        return null;
    }
    return debug_flags[@intCast(flag_number)].ptr;
}

fn showFlags(show_all: bool) void {
    for (debug_flags, 0..) |entry, i| {
        const value = entry.ptr.*;
        if (show_all or value) {
            abi.outf_error(
                "Flag %u (%s) is %s.\n",
                @as(c_uint, @intCast(i)),
                entry.name,
                @as([*:0]const u8, if (value) "set" else "clear"),
            );
        }
    }
    abi.outf_flush_error();
}

fn setFlag(flag_number: isize, value: bool) void {
    if (!build_options.debugging) {
        abi.outf_error("Not a debugging version.  No flags to set.\n");
        abi.outf_flush_error();
        return;
    }
    if (findFlag(flag_number)) |flag| {
        flag.* = value;
    } else {
        showFlags(true);
    }
}

fn debugGetDec(line: []const u8) isize {
    var idx: usize = 0;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) {
        idx += 1;
    }
    var neg = false;
    if (idx < line.len and (line[idx] == '-' or line[idx] == '+')) {
        neg = (line[idx] == '-');
        idx += 1;
    }
    var digits: usize = 0;
    var val: isize = 0;
    while (idx < line.len and line[idx] >= '0' and line[idx] <= '9') : (idx += 1) {
        val = val * 10 + @as(isize, line[idx] - '0');
        digits += 1;
    }
    if (digits == 0) return -1;
    return if (neg) -val else val;
}

fn readInteractiveLine(buf: *[256]u8) ?[]const u8 {
    var len: usize = 0;
    while (len + 1 < buf.len) {
        var ch: u8 = 0;
        const n = readStdinByte(&ch);
        if (n <= 0) {
            if (len == 0) return null;
            break;
        }
        buf[len] = ch;
        len += 1;
        if (ch == '\n') break;
    }
    buf[len] = 0;
    return buf[0..len];
}

pub export fn debug_edit_flags() callconv(.c) void {
    if (!build_options.debugging) {
        abi.outf_error("Not a debugging version.  No flags to handle.\n");
        abi.outf_flush_error();
        return;
    }
    showFlags(false);
    var input_line: [256]u8 = undefined;
    while (true) {
        abi.outf_error("Clear<number>, Set<number>, Done, ?, or Halt: ");
        abi.outf_flush_error();
        const line = readInteractiveLine(&input_line) orelse return;
        if (line.len == 0) {
            showFlags(true);
            continue;
        }
        switch (line[0]) {
            'c', 'C' => setFlag(debugGetDec(line[1..]), false),
            's', 'S' => setFlag(debugGetDec(line[1..]), true),
            'd', 'D' => return,
            'h', 'H' => abi.termination_normal(0),
            else => showFlags(true),
        }
    }
}

// DEFINE_PRIMITIVE("SET-DEBUG-FLAGS!", Prim_set_debug_flags, 2, 2,
//   "(FLAG_NUMBER BOOLEAN)")
pub export fn Prim_set_debug_flags() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    setFlag(abi.arg_integer(1), abi.argRef(2) != obj.sharp_f);
    return obj.unspecific;
}

test "debug constantString, printer, stack trace, verify_heap, and debug flags" {
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();
    primutl.resetForTesting();
    defer primutl.resetForTesting();
    primutl.initialize_primitives();

    // 1. constantString mappings
    try std.testing.expectEqualStrings("#f", std.mem.span(constantString(obj.sharp_f).?));
    try std.testing.expectEqualStrings("#t", std.mem.span(constantString(obj.sharp_t).?));
    try std.testing.expectEqualStrings("#!unspecific", std.mem.span(constantString(obj.unspecific).?));
    try std.testing.expectEqualStrings("#!optional", std.mem.span(constantString(obj.optional_marker).?));
    try std.testing.expectEqualStrings("#!rest", std.mem.span(constantString(obj.rest_marker).?));
    try std.testing.expectEqualStrings("#!key", std.mem.span(constantString(obj.key_marker).?));
    try std.testing.expectEqualStrings("#!eof", std.mem.span(constantString(obj.eof_object).?));
    try std.testing.expectEqualStrings("#!default", std.mem.span(constantString(obj.default_object).?));
    try std.testing.expectEqualStrings("()", std.mem.span(constantString(obj.empty_list).?));
    try std.testing.expectEqualStrings("#!reclaimed", std.mem.span(constantString(obj.gc_reclaimed).?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), constantString(obj.ulongToFixnum(0)));

    // 2. Prim_debugging_printer across core Scheme object kinds
    storage.fixed_objects = abi.make_vector(abi.fixobj_gc_reclaimed + 1, obj.sharp_f, false);
    obj.vectorSet(storage.fixed_objects, abi.fixobj_obarray, abi.make_vector(17, obj.empty_list, false));

    const sym = intern.char_pointer_to_symbol("dbg-sym");
    const lstr = string.char_pointer_to_string("hello\\n\"\t");
    const bv = abi.memory_to_bytevector(3, "abc");
    const pr = list.cons(sym, obj.longToFixnum(-7));
    const wp = abi.system_pair_cons(@intCast(obj.tc_weak_cons), lstr, obj.empty_list);
    const vec = abi.make_vector(2, pr, false);
    const fl = abi.double_to_flonum(3.5);
    const ch = obj.makeObject(obj.tc_character, 'Z');
    const rc = obj.makeObject(obj.tc_return_code, abi.rc_eval_error);

    // Build 1-, 2-, and 3-byte ustrings
    const us1 = abi.allocate_non_marked_vector(@intCast(obj.tc_unicode_string), 2, false);
    obj.setNmVectorSubheader(us1, obj.makeObject((0 << 2) | 1, 2));
    obj.ustringData(us1)[0] = 'h';
    obj.ustringData(us1)[1] = 'i';
    const us2 = abi.allocate_non_marked_vector(@intCast(obj.tc_unicode_string), 2, false);
    obj.setNmVectorSubheader(us2, obj.makeObject((0 << 2) | 2, 1));
    obj.ustringData(us2)[0] = 0xBB;
    obj.ustringData(us2)[1] = 0x03;
    const us3 = abi.allocate_non_marked_vector(@intCast(obj.tc_unicode_string), 2, false);
    obj.setNmVectorSubheader(us3, obj.makeObject((0 << 2) | 3, 1));
    obj.ustringData(us3)[0] = 0x00;
    obj.ustringData(us3)[1] = 0xF6;
    obj.ustringData(us3)[2] = 0x01;

    // Lambda, extended lambda, procedure, primitive, reference trap
    const names = abi.make_vector(2, sym, false);
    obj.vectorSet(names, 1, intern.char_pointer_to_symbol("x"));
    const lam = abi.system_pair_cons(@intCast(obj.tc_lambda), obj.sharp_f, names);
    const elam_cell = abi.Free;
    elam_cell[0] = obj.sharp_f;
    elam_cell[1] = names;
    elam_cell[2] = (1 << 8) | 0; // reqs=1, opts=0, rest=0
    abi.Free += 3;
    const elam = obj.makePointerObject(obj.tc_extended_lambda, elam_cell);
    const proc = abi.system_pair_cons(@intCast(obj.tc_procedure), lam, obj.the_global_env);
    const prim0 = obj.makeObject(obj.tc_primitive, 0);
    const trap_imm = obj.unassigned_object;
    const trap_ptr = abi.system_pair_cons(@intCast(obj.tc_reference_trap), obj.ulongToFixnum(obj.trap_macro), obj.sharp_t);

    for ([_]obj.SchemeObject{
        obj.sharp_f,
        abi.return_to_interpreter,
        abi.reflect_to_interface,
        sym,
        lstr,
        bv,
        us1,
        us2,
        us3,
        pr,
        wp,
        vec,
        fl,
        ch,
        rc,
        lam,
        elam,
        proc,
        prim0,
        trap_imm,
        trap_ptr,
    }) |val| {
        stubs.setArgs(&.{val});
        try std.testing.expectEqual(obj.sharp_f, Prim_debugging_printer());
    }

    // 3. debug_stack_trace & Print_One_Continuation_Frame with rc_halt, rc_end_of_computation, nm-vector skip
    abi.stackPush(obj.sharp_f);
    abi.stackPush(obj.makeObject(obj.tc_return_code, abi.rc_halt));
    abi.stackPush(obj.ulongToFixnum(99));
    abi.stackPush(obj.makeNmvHeader(1));
    abi.stackPush(obj.sharp_t);
    abi.stackPush(obj.makeObject(obj.tc_return_code, abi.rc_eval_error));

    const prev_outf = stubs.mock_outf_calls;
    debug_stack_trace(abi.ERROR_OUTPUT);
    try std.testing.expect(stubs.mock_outf_calls > prev_outf);
    try std.testing.expect(Print_One_Continuation_Frame(obj.makeObject(obj.tc_return_code, abi.rc_end_of_computation)));

    // 4. Prim_verify_heap validates clean mock heap and (in debugging mode) flags invalid object
    stubs.setArgs(&.{});
    try std.testing.expectEqual(obj.sharp_t, Prim_verify_heap());
    if (build_options.debugging) {
        const bad_slot = abi.Free;
        bad_slot[0] = obj.makeObject(0x3F, 0); // GC_UNDEFINED type code
        abi.Free += 1;
        storage.Free = abi.Free;
        try std.testing.expect(!debug_verify_heap());
        abi.Free -= 1;
        storage.Free = abi.Free;
        try std.testing.expect(debug_verify_heap());
    }

    // 5. Prim_set_debug_flags & debugGetDec
    try std.testing.expectEqual(@as(isize, 9), debugGetDec("  9\n"));
    try std.testing.expectEqual(@as(isize, -1), debugGetDec("\n"));
    const prev_gc_debug = storage.gc_debug;
    defer storage.gc_debug = prev_gc_debug;
    stubs.setArgs(&.{ obj.ulongToFixnum(9), obj.sharp_t });
    try std.testing.expectEqual(obj.unspecific, Prim_set_debug_flags());
    if (build_options.debugging) {
        try std.testing.expect(storage.gc_debug);
    }
    stubs.setArgs(&.{ obj.ulongToFixnum(9), obj.sharp_f });
    _ = Prim_set_debug_flags();
    if (build_options.debugging) {
        try std.testing.expect(!storage.gc_debug);
    }
}
