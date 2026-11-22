// Derived from MIT/GNU Scheme C sources (`src/microcode/primutl.c`, `src/microcode/prename.h`, `src/microcode/usrdef.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const obj = @import("../core/scheme_obj.zig");
const abi = @import("../core/prim_abi.zig");
const outf = @import("../support/outf.zig");
const avltree = @import("../support/avltree.zig");
const transact = @import("../support/transact.zig");
const wind = @import("../support/wind.zig");

pub const PrimRenumber = extern struct {
    internal: [*]usize,
    external: [*]usize,
    next_code: usize,
};

const PrimitiveAlias = struct {
    alias: [*:0]const u8,
    name: [*:0]const u8,
};

const primitive_aliases = [_]PrimitiveAlias{
    .{ .alias = "FALSE?", .name = "NOT" },
    .{ .alias = "PRIMITIVE-TYPE", .name = "OBJECT-TYPE" },
    .{ .alias = "PRIMITIVE-TYPE?", .name = "OBJECT-TYPE?" },
    .{ .alias = "&MAKE-OBJECT", .name = "PRIMITIVE-OBJECT-SET-TYPE" },
    .{ .alias = "SYSTEM-MEMORY-REF", .name = "PRIMITIVE-OBJECT-REF" },
    .{ .alias = "PRIMITIVE-OBJECT-NEW-TYPE", .name = "PRIMITIVE-OBJECT-SET-TYPE" },
    .{ .alias = "FILE-CLOSE-CHANNEL", .name = "CHANNEL-CLOSE" },
    .{ .alias = "GET-NEXT-INTERRUPT-CHARACTER", .name = "TTY-NEXT-INTERRUPT-CHAR" },
    .{ .alias = "REMOVE-FILE", .name = "FILE-REMOVE" },
    .{ .alias = "RENAME-FILE", .name = "FILE-RENAME" },
    .{ .alias = "COPY-FILE", .name = "FILE-COPY" },
    .{ .alias = "MAKE-DIRECTORY", .name = "DIRECTORY-MAKE" },
    .{ .alias = "SCREEN-X-SIZE", .name = "TTY-X-SIZE" },
    .{ .alias = "SCREEN-Y-SIZE", .name = "TTY-Y-SIZE" },
    .{ .alias = "FILE-SYMLINK?", .name = "FILE-SOFT-LINK?" },
    .{ .alias = "X-GRAPHICS-SET-CLASS-HINT", .name = "X-WINDOW-SET-CLASS-HINT" },
    .{ .alias = "CURRENT-FILE-TIME", .name = "ENCODED-TIME" },
    .{ .alias = "DUMP-BAND", .name = "DUMP-BAND*" },
};

extern var MAX_STATIC_PRIMITIVE: isize;
extern var Static_Primitive_Procedure_Table: [1]abi.PrimitiveProcedure;
extern var Static_Primitive_Arity_Table: [1]c_int;
extern var Static_Primitive_Count_Table: [1]c_int;
extern var Static_Primitive_Name_Table: [1]?[*:0]const u8;
extern var Static_Primitive_Documentation_Table: [1]?[*:0]const u8;

pub export var MAX_PRIMITIVE: usize = 0;
pub export var Primitive_Procedure_Table: ?[*]abi.PrimitiveProcedure = null;
pub export var Primitive_Arity_Table: ?[*]c_int = null;
pub export var Primitive_Count_Table: ?[*]c_int = null;
pub export var Primitive_Name_Table: ?[*]?[*:0]const u8 = null;
pub export var Primitive_Documentation_Table: ?[*]?[*:0]const u8 = null;
pub export var load_renumber_table: ?[*]obj.SchemeObject = null;

var prim_table_size: usize = 0;
var prim_procedure_tree: ?*avltree.TreeNode = null;

pub export fn strcmp_ci(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (true) : (i += 1) {
        const c1 = s1[i];
        const c2 = s2[i];
        if (c1 == 0) return if (c2 == 0) 0 else -1;
        if (c2 == 0) return 1;
        const ch1 = std.ascii.toUpper(c1);
        const ch2 = std.ascii.toUpper(c2);
        if (ch1 < ch2) return -1;
        if (ch1 > ch2) return 1;
    }
}

pub export fn Prim_unimplemented() callconv(.c) obj.SchemeObject {
    abi.primitiveHeader();
    abi.signal_error_from_primitive(abi.err_unimplemented_primitive);
}

fn initializationError(reason: [*:0]const u8, item: [*:0]const u8) noreturn {
    outf.fatal("initialize_primitives: Error {s} {s}.\n", .{ reason, item });
    abi.termination_init_error();
}

fn printTreeError(chan: outf.OutfChannel, msg: [*:0]const u8, noise: ?[*:0]const u8) void {
    const slice = std.mem.span(msg);
    if (std.mem.indexOf(u8, slice, "%s")) |pos| {
        const arg: [*:0]const u8 = noise orelse "";
        outf.print(chan, "{s}{s}{s}", .{ slice[0..pos], arg, slice[pos + 2 ..] });
    } else {
        outf.print(chan, "{s}", .{slice});
    }
}

fn copyTable(
    comptime Elem: type,
    table: *?[*]Elem,
    static_base: [*]const Elem,
    static_count: usize,
    new_size: usize,
) void {
    const nbytes = new_size * @sizeOf(Elem);
    if (table.*) |existing| {
        const raw = abi.OS_realloc(@ptrCast(existing), nbytes).?;
        table.* = @ptrCast(@alignCast(raw));
    } else {
        const raw = abi.OS_malloc(nbytes).?;
        const dst: [*]Elem = @ptrCast(@alignCast(raw));
        @memcpy(dst[0..static_count], static_base[0..static_count]);
        table.* = dst;
    }
}

fn growPrimitiveTables() void {
    const new_size = MAX_PRIMITIVE + @max(MAX_PRIMITIVE / 10, 1);
    const static_count: usize = @intCast(MAX_STATIC_PRIMITIVE + 1);
    const nsize: usize = @intCast(new_size);
    copyTable(c_int, &Primitive_Arity_Table, @ptrCast(&Static_Primitive_Arity_Table), static_count, nsize);
    copyTable(c_int, &Primitive_Count_Table, @ptrCast(&Static_Primitive_Count_Table), static_count, nsize);
    copyTable(?[*:0]const u8, &Primitive_Name_Table, @ptrCast(&Static_Primitive_Name_Table), static_count, nsize);
    copyTable(?[*:0]const u8, &Primitive_Documentation_Table, @ptrCast(&Static_Primitive_Documentation_Table), static_count, nsize);
    copyTable(abi.PrimitiveProcedure, &Primitive_Procedure_Table, @ptrCast(&Static_Primitive_Procedure_Table), static_count, nsize);
    prim_table_size = new_size;
}

pub export fn initialize_primitives() callconv(.c) void {
    MAX_PRIMITIVE = @as(usize, @intCast(MAX_STATIC_PRIMITIVE)) + 1;
    growPrimitiveTables();

    avltree.tree_error_message = null;
    prim_procedure_tree = avltree.tree_build(MAX_PRIMITIVE, @ptrCast(Primitive_Name_Table.?), 0);
    if (avltree.tree_error_message) |msg| {
        printTreeError(outf.fatal_output, msg, avltree.tree_error_noise);
        initializationError("building", "prim_procedure_tree");
    }

    for (primitive_aliases) |entry| {
        var index: usize = undefined;
        if (avltree.tree_lookup(prim_procedure_tree, entry.name)) |orig| {
            index = orig.value;
        } else {
            const old = make_primitive(entry.name, abi.unknown_primitive_arity);
            if (old == obj.sharp_f) {
                outf.fatal("Error declaring unknown primitive {s}.\n", .{entry.name});
                initializationError("aliasing", entry.alias);
            }
            index = obj.primitiveNumber(old);
        }

        const updated = avltree.tree_insert(prim_procedure_tree, entry.alias, index);
        if (avltree.tree_error_message) |msg| {
            printTreeError(outf.fatal_output, msg, avltree.tree_error_noise);
            initializationError("aliasing", entry.alias);
        }
        prim_procedure_tree = updated;
    }
}

fn declarePrimitiveInternal(
    override_p: bool,
    name: [*:0]const u8,
    code: abi.PrimitiveProcedure,
    _: c_int,
    nargs_hi: c_int,
    docstr: ?[*:0]const u8,
) obj.SchemeObject {
    var index: usize = undefined;
    var primitive: obj.SchemeObject = undefined;
    var ndocstr = docstr;

    if (avltree.tree_lookup(prim_procedure_tree, name)) |prim| {
        index = @intCast(prim.value);
        primitive = obj.makePrimitiveObject(prim.value);
        const cur_arity = Primitive_Arity_Table.?[index];
        const implemented = Primitive_Procedure_Table.?[index] != &Prim_unimplemented;
        if ((cur_arity != nargs_hi and cur_arity != abi.unknown_primitive_arity) or (implemented and !override_p)) {
            return obj.ulongToFixnum(obj.primitiveNumber(primitive));
        }
        if (docstr == null) {
            ndocstr = Primitive_Documentation_Table.?[index];
        }
    } else {
        if (MAX_PRIMITIVE == prim_table_size) {
            growPrimitiveTables();
        }
        const new_idx = MAX_PRIMITIVE;
        index = @intCast(new_idx);
        const inserted = avltree.tree_insert(prim_procedure_tree, name, new_idx);
        if (avltree.tree_error_message) |msg| {
            printTreeError(outf.error_output, msg, avltree.tree_error_noise);
            avltree.tree_error_message = null;
            return obj.sharp_f;
        }
        prim_procedure_tree = inserted;
        MAX_PRIMITIVE += 1;
        primitive = obj.makePrimitiveObject(new_idx);
        Primitive_Name_Table.?[index] = name;
    }

    Primitive_Procedure_Table.?[index] = code;
    Primitive_Arity_Table.?[index] = nargs_hi;
    Primitive_Count_Table.?[index] = nargs_hi * @as(c_int, @intCast(@sizeOf(obj.SchemeObject)));
    Primitive_Documentation_Table.?[index] = ndocstr;
    return primitive;
}

pub export fn declare_primitive(
    name: [*:0]const u8,
    code: abi.PrimitiveProcedure,
    nargs_lo: c_int,
    nargs_hi: c_int,
    docstr: ?[*:0]const u8,
) callconv(.c) obj.SchemeObject {
    return declarePrimitiveInternal(false, name, code, nargs_lo, nargs_hi, docstr);
}

pub export fn install_primitive(
    name: [*:0]const u8,
    code: abi.PrimitiveProcedure,
    nargs_lo: c_int,
    nargs_hi: c_int,
    docstr: ?[*:0]const u8,
) callconv(.c) obj.SchemeObject {
    return declarePrimitiveInternal(true, name, code, nargs_lo, nargs_hi, docstr);
}

pub export fn make_primitive(name: [*:0]const u8, arity: c_int) callconv(.c) obj.SchemeObject {
    const cname: [*:0]const u8 = if (avltree.tree_lookup(prim_procedure_tree, name)) |prim|
        prim.name.?
    else blk: {
        const len = std.mem.len(name);
        const buf: [*]u8 = @ptrCast(abi.OS_malloc(len + 1).?);
        @memcpy(buf[0 .. len + 1], name[0 .. len + 1]);
        break :blk @ptrCast(buf);
    };
    const result = declare_primitive(cname, &Prim_unimplemented, arity, arity, null);
    return if (result == obj.sharp_f) obj.sharp_f else obj.objectNewType(obj.tc_primitive, result);
}

pub export fn find_primitive_cname(
    name: [*:0]const u8,
    intern_p: bool,
    allow_p: bool,
    arity: c_int,
) callconv(.c) obj.SchemeObject {
    if (avltree.tree_lookup(prim_procedure_tree, name)) |prim| {
        const idx: usize = @intCast(prim.value);
        const primitive = obj.makePrimitiveObject(prim.value);
        const implemented = Primitive_Procedure_Table.?[idx] != &Prim_unimplemented;
        if (!allow_p and !implemented) return obj.sharp_f;

        const cur_arity = Primitive_Arity_Table.?[idx];
        if (arity == abi.unknown_primitive_arity or arity == cur_arity) {
            return primitive;
        }
        if (cur_arity == abi.unknown_primitive_arity) {
            Primitive_Arity_Table.?[idx] = arity;
            return primitive;
        }
        return obj.longToFixnum(cur_arity);
    }

    if (!intern_p) return obj.sharp_f;

    const n_bytes = std.mem.len(name) + 1;
    const buf: [*]u8 = @ptrCast(abi.OS_malloc(n_bytes).?);
    @memcpy(buf[0..n_bytes], name[0..n_bytes]);
    const cname: [*:0]const u8 = @ptrCast(buf);
    const primitive = declare_primitive(
        cname,
        &Prim_unimplemented,
        if (arity < 0) 0 else arity,
        arity,
        null,
    );
    if (primitive == obj.sharp_f) {
        abi.error_in_system_call(abi.syserr_not_enough_space, abi.syscall_malloc);
    }
    return primitive;
}

pub export fn find_primitive(
    sname: obj.SchemeObject,
    intern_p: bool,
    allow_p: bool,
    arity: c_int,
) callconv(.c) obj.SchemeObject {
    const ptr: [*:0]const u8 = @ptrCast(obj.legacyStringData(sname));
    return find_primitive_cname(ptr, intern_p, allow_p, arity);
}

fn freePrimRenumber(vpr: ?*anyopaque) callconv(.c) void {
    const pr: *PrimRenumber = @ptrCast(@alignCast(vpr.?));
    abi.OS_free(@ptrCast(pr.internal));
    abi.OS_free(@ptrCast(pr.external));
    abi.OS_free(@ptrCast(pr));
}

pub export fn make_prim_renumber() callconv(.c) *PrimRenumber {
    const n_entries: usize = @intCast(MAX_PRIMITIVE);
    const pr: *PrimRenumber = @ptrCast(@alignCast(abi.OS_malloc(@sizeOf(PrimRenumber)).?));
    const arr_bytes = @max(n_entries, 1) * @sizeOf(usize);
    pr.internal = @ptrCast(@alignCast(abi.OS_malloc(arr_bytes).?));
    pr.external = @ptrCast(@alignCast(abi.OS_malloc(arr_bytes).?));
    pr.next_code = 0;
    const empty_val = std.math.maxInt(usize);
    @memset(pr.internal[0..n_entries], empty_val);
    @memset(pr.external[0..n_entries], empty_val);
    transact.transaction_record_action(.tat_always, &freePrimRenumber, @ptrCast(pr));
    return pr;
}

pub export fn renumber_primitive(primitive: obj.SchemeObject, pr: *PrimRenumber) callconv(.c) obj.SchemeObject {
    const old = obj.objectDatum(primitive);
    const old_idx: usize = @intCast(old);
    var new_code = pr.internal[old_idx];
    if (new_code == std.math.maxInt(usize)) {
        new_code = pr.next_code;
        pr.next_code += 1;
        pr.internal[old_idx] = new_code;
        pr.external[@intCast(new_code)] = old;
    }
    return obj.objectNewDatum(primitive, new_code);
}

fn tableEntryLength(code: usize) usize {
    const source = Primitive_Name_Table.?[@intCast(code)];
    const n_chars: usize = if (source) |s| @intCast(std.mem.len(s)) else 0;
    return obj.bytevectorLengthToGcLength(n_chars) + 2;
}

fn makeTableEntry(code: usize, start_in: [*]obj.SchemeObject) [*]obj.SchemeObject {
    const idx: usize = @intCast(code);
    const source: [*:0]const u8 = Primitive_Name_Table.?[idx] orelse "";
    const n_chars: usize = std.mem.len(source);
    const n_words = obj.bytevectorLengthToGcLength(@intCast(n_chars));
    const n_words_u: usize = @intCast(n_words);

    var start = start_in;
    start[0] = obj.longToFixnum(Primitive_Arity_Table.?[idx]);
    start[1] = obj.makeNmvHeader(n_words);
    start += 2;
    start[0] = obj.makeObject(0, @intCast(n_chars));
    const dst_bytes: [*]u8 = @ptrCast(start + 1);
    @memcpy(dst_bytes[0 .. n_chars + 1], source[0 .. n_chars + 1]);
    return start + n_words_u;
}

pub export fn renumbered_primitives_export_length(pr: *PrimRenumber) callconv(.c) usize {
    var result: usize = 0;
    for (0..@as(usize, @intCast(pr.next_code))) |i| {
        result += tableEntryLength(pr.external[i]);
    }
    return result;
}

pub export fn export_renumbered_primitives(start_in: [*]obj.SchemeObject, pr: *PrimRenumber) callconv(.c) void {
    var start = start_in;
    for (0..@as(usize, @intCast(pr.next_code))) |i| {
        start = makeTableEntry(pr.external[i], start);
    }
}

pub export fn primitive_table_export_length() callconv(.c) usize {
    var result: usize = 0;
    for (0..@as(usize, @intCast(MAX_PRIMITIVE))) |i| {
        result += tableEntryLength(@intCast(i));
    }
    return result;
}

pub export fn export_primitive_table(start_in: [*]obj.SchemeObject) callconv(.c) void {
    var start = start_in;
    for (0..@as(usize, @intCast(MAX_PRIMITIVE))) |i| {
        start = makeTableEntry(@intCast(i), start);
    }
}

pub export fn import_primitive_table(
    entries_in: [*]obj.SchemeObject,
    n_entries: usize,
    primitives: [*]obj.SchemeObject,
) callconv(.c) void {
    var entries = entries_in;
    for (0..@as(usize, @intCast(n_entries))) |i| {
        const arity: c_int = @truncate(obj.fixnumToLong(entries[0]));
        entries += 1;
        const prim = find_primitive(
            obj.makePointerObject(obj.tc_character_string, entries),
            true,
            true,
            arity,
        );
        if (!obj.primitiveP(prim)) {
            abi.signal_error_from_primitive(abi.err_wrong_arity_primitives);
        }
        primitives[i] = prim;
        entries += 1 + @as(usize, @intCast(obj.objectDatum(entries[0])));
    }
}

pub fn resetForTesting() void {
    avltree.tree_free(prim_procedure_tree);
    prim_procedure_tree = null;
    if (Primitive_Arity_Table) |p| abi.OS_free(@ptrCast(p));
    Primitive_Arity_Table = null;
    if (Primitive_Count_Table) |p| abi.OS_free(@ptrCast(p));
    Primitive_Count_Table = null;
    if (Primitive_Name_Table) |p| abi.OS_free(@ptrCast(p));
    Primitive_Name_Table = null;
    if (Primitive_Documentation_Table) |p| abi.OS_free(@ptrCast(p));
    Primitive_Documentation_Table = null;
    if (Primitive_Procedure_Table) |p| abi.OS_free(@ptrCast(p));
    Primitive_Procedure_Table = null;
    MAX_PRIMITIVE = 0;
    prim_table_size = 0;
}

test "primutl initialize, aliases, declare/install, find, and fasl renumber export/import" {
    const stubs = @import("../core/test_stubs.zig");
    const str = @import("../data/string.zig");
    stubs.resetMockRuntime();
    resetForTesting();
    defer resetForTesting();

    try std.testing.expectEqual(@as(c_int, 0), strcmp_ci("Car", "CAR"));
    try std.testing.expect(strcmp_ci("alpha", "beta") < 0);

    initialize_primitives();
    // 2 static primitives ("CAR", "CDR") + 17 distinct targets across 18 aliases
    try std.testing.expectEqual(@as(usize, 19), MAX_PRIMITIVE);

    // Lookup existing static primitive & alias
    const p_car = find_primitive_cname("car", false, false, 1);
    try std.testing.expectEqual(obj.makePrimitiveObject(0), p_car);
    const p_false = find_primitive_cname("FALSE?", false, true, abi.unknown_primitive_arity);
    try std.testing.expect(obj.primitiveP(p_false));
    const p_not = find_primitive_cname("NOT", false, true, abi.unknown_primitive_arity);
    try std.testing.expectEqual(p_false, p_not);

    // Declare & override dynamic primitive
    const Handlers = struct {
        fn p1() callconv(.c) obj.SchemeObject {
            return obj.sharp_t;
        }
        fn p2() callconv(.c) obj.SchemeObject {
            return obj.sharp_f;
        }
    };
    const dyn = declare_primitive("ZIG-TEST-PRIM", &Handlers.p1, 2, 2, "test doc");
    try std.testing.expect(obj.primitiveP(dyn));
    try std.testing.expectEqual(dyn, find_primitive(str.char_pointer_to_string("zig-test-prim"), false, false, 2));
    // Overriding with declare_primitive returns existing index fixnum
    try std.testing.expectEqual(obj.ulongToFixnum(obj.primitiveNumber(dyn)), declare_primitive("ZIG-TEST-PRIM", &Handlers.p2, 2, 2, null));
    // Overriding with install_primitive succeeds and preserves doc when null
    try std.testing.expectEqual(dyn, install_primitive("ZIG-TEST-PRIM", &Handlers.p2, 2, 2, null));
    try std.testing.expectEqual(&Handlers.p2, Primitive_Procedure_Table.?[@intCast(obj.primitiveNumber(dyn))]);

    // Arity mismatch returns fixnum of actual arity
    try std.testing.expectEqual(obj.longToFixnum(2), find_primitive_cname("ZIG-TEST-PRIM", false, true, 3));

    // Renumber, export, and import roundtrip inside transaction
    wind.dstack_initialize();
    defer wind.dstack_reset();
    transact.transaction_initialize();
    transact.transaction_begin();
    const pr = make_prim_renumber();
    const r0 = renumber_primitive(dyn, pr);
    const r1 = renumber_primitive(p_car, pr);
    try std.testing.expectEqual(@as(usize, 0), obj.objectDatum(r0));
    try std.testing.expectEqual(@as(usize, 1), obj.objectDatum(r1));
    try std.testing.expectEqual(@as(usize, 2), pr.next_code);

    const export_len: usize = @intCast(renumbered_primitives_export_length(pr));
    var export_buf: [64]obj.SchemeObject = @splat(0);
    try std.testing.expect(export_len <= export_buf.len);
    export_renumbered_primitives(&export_buf, pr);

    var imported: [2]obj.SchemeObject = undefined;
    import_primitive_table(&export_buf, pr.next_code, &imported);
    try std.testing.expectEqual(dyn, imported[0]);
    try std.testing.expectEqual(p_car, imported[1]);
    transact.transaction_commit();
}
