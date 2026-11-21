// Derived from MIT/GNU Scheme C sources (`src/microcode/findprim.c`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");

const lexpr_arity_string = "-1";

const Descriptor = struct {
    c_name: []const u8,
    arity: []const u8,
    scheme_name: []const u8,
    documentation: []const u8,
    file_name: []const u8,
};

const inexistent_entry = Descriptor{
    .c_name = "Prim_inexistent",
    .arity = lexpr_arity_string,
    .scheme_name = "INEXISTENT-PRIMITIVE",
    .documentation = "",
    .file_name = "Findprim.c",
};

const TokenType = enum {
    integer,
    identifier,
    string,
    string_upcase,
};

const TokenKind = enum {
    normal,
    alternate,
    builtin,
};

const State = struct {
    allocator: std.mem.Allocator,
    prog_name: []const u8,
    built_in_p: bool = false,
    the_kind: []const u8 = "Static_Primitive",
    the_variable: []const u8 = "MAX_STATIC_PRIMITIVE",
    tokens: []const struct { name: []const u8, kind: TokenKind } = &.{
        .{ .name = "Define_Primitive", .kind = .normal },
        .{ .name = "DEFINE_PRIMITIVE", .kind = .alternate },
    },

    descriptors: std.ArrayList(Descriptor) = .empty,
    slots: std.ArrayList(?Descriptor) = .empty,

    max_scheme_name_length: usize = 0,
    max_c_name_length: usize = 0,
    max_arity_length: usize = 0,
    max_documentation_length: usize = 0,
    max_file_name_length: usize = 0,
    max_index_length: usize = 0,

    fn init(allocator: std.mem.Allocator, prog_name: []const u8) State {
        var s = State{
            .allocator = allocator,
            .prog_name = prog_name,
        };
        s.updateMaxFromEntry(inexistent_entry);
        return s;
    }

    fn updateMaxFromEntry(self: *State, desc: Descriptor) void {
        self.max_scheme_name_length = @max(self.max_scheme_name_length, desc.scheme_name.len);
        self.max_c_name_length = @max(self.max_c_name_length, desc.c_name.len);
        self.max_arity_length = @max(self.max_arity_length, desc.arity.len);
        self.max_documentation_length = @max(self.max_documentation_length, desc.documentation.len);
        self.max_file_name_length = @max(self.max_file_name_length, desc.file_name.len);
    }

    fn initBuiltin(self: *State, size_arg: []const u8) !void {
        const len = try readIndex(size_arg, "built_in_table_size");
        self.built_in_p = true;
        self.the_kind = "Primitive";
        self.the_variable = "MAX_PRIMITIVE";
        self.tokens = &.{.{ .name = "Built_In_Primitive", .kind = .builtin }};
        try self.slots.resize(self.allocator, len);
        @memset(self.slots.items, null);
    }

    fn initExternal(self: *State) void {
        self.built_in_p = false;
        self.the_kind = "External";
        self.the_variable = "MAX_EXTERNAL_PRIMITIVE";
        self.tokens = &.{.{ .name = "Define_Primitive", .kind = .normal }};
    }

    fn processSource(self: *State, file_name: []const u8, source: []const u8) !void {
        const is_zig = std.mem.endsWith(u8, file_name, ".zig");
        var pos: usize = 0;

        while (true) {
            const match = try self.scanNextToken(file_name, source, &pos, is_zig) orelse break;
            switch (match) {
                .normal => {
                    const c_name = try self.copyToken(source, &pos, .identifier, false, &self.max_c_name_length);
                    const arity = try self.copyToken(source, &pos, .integer, false, &self.max_arity_length);
                    const scheme_name = try self.copyToken(source, &pos, .string_upcase, false, &self.max_scheme_name_length);
                    self.max_file_name_length = @max(self.max_file_name_length, file_name.len);
                    const desc = Descriptor{
                        .c_name = c_name,
                        .arity = arity,
                        .scheme_name = scheme_name,
                        .documentation = "",
                        .file_name = file_name,
                    };
                    try self.descriptors.append(self.allocator, desc);
                    try self.slots.append(self.allocator, desc);
                },
                .alternate => {
                    const zig_comment = is_zig;
                    const scheme_name = try self.copyToken(source, &pos, .string_upcase, zig_comment, &self.max_scheme_name_length);
                    const c_name = try self.copyToken(source, &pos, .identifier, zig_comment, &self.max_c_name_length);
                    skipToTokenStart(source, &pos, zig_comment);
                    skipToken(source, &pos); // min_args
                    const arity = try self.copyToken(source, &pos, .integer, zig_comment, &self.max_arity_length);
                    const doc = try self.copyToken(source, &pos, .string, zig_comment, &self.max_documentation_length);
                    self.max_file_name_length = @max(self.max_file_name_length, file_name.len);
                    const desc = Descriptor{
                        .c_name = c_name,
                        .arity = arity,
                        .scheme_name = scheme_name,
                        .documentation = doc,
                        .file_name = file_name,
                    };
                    try self.descriptors.append(self.allocator, desc);
                    try self.slots.append(self.allocator, desc);
                },
                .builtin => {
                    const c_name = try self.copyToken(source, &pos, .identifier, false, &self.max_c_name_length);
                    const arity = try self.copyToken(source, &pos, .integer, false, &self.max_arity_length);
                    const scheme_name = try self.copyToken(source, &pos, .string_upcase, false, &self.max_scheme_name_length);
                    self.max_file_name_length = @max(self.max_file_name_length, file_name.len);
                    var dummy_idx_len: usize = 0;
                    const idx_tok = try self.copyToken(source, &pos, .integer, false, &dummy_idx_len);
                    const idx = try readIndex(idx_tok, "index");
                    if (idx >= self.slots.items.len) {
                        const old_len = self.slots.items.len;
                        try self.slots.resize(self.allocator, idx + 1);
                        @memset(self.slots.items[old_len..], null);
                    }
                    if (self.slots.items[idx] != null) {
                        return error.DuplicatePrimitiveIndex;
                    }
                    const desc = Descriptor{
                        .c_name = c_name,
                        .arity = arity,
                        .scheme_name = scheme_name,
                        .documentation = "",
                        .file_name = file_name,
                    };
                    self.slots.items[idx] = desc;
                },
            }
        }
    }

    fn scanNextToken(
        self: *const State,
        file_name: []const u8,
        source: []const u8,
        pos: *usize,
        is_zig: bool,
    ) !?TokenKind {
        var c_opt: ?u8 = '\n';
        while (c_opt) |ch| {
            switch (ch) {
                '/' => {
                    if (pos.* >= source.len) return null;
                    const next = source[pos.*];
                    pos.* += 1;
                    if (next == '*') {
                        var inner: u8 = if (pos.* < source.len) source[pos.*] else return error.UnterminatedComment;
                        pos.* += 1;
                        while (true) {
                            while (inner != '*') {
                                if (pos.* >= source.len) {
                                    std.debug.print("Error: EOF in comment in file {s}, or {s} confused\n", .{ file_name, self.prog_name });
                                    return error.UnterminatedComment;
                                }
                                inner = source[pos.*];
                                pos.* += 1;
                            }
                            if (pos.* >= source.len) return error.UnterminatedComment;
                            inner = source[pos.*];
                            pos.* += 1;
                            if (inner == '/') break;
                        }
                    } else if (next == '\n') {
                        if (try self.matchAtLineStart(source, pos, is_zig)) |kind| {
                            return kind;
                        }
                    }
                },
                '\n' => {
                    if (try self.matchAtLineStart(source, pos, is_zig)) |kind| {
                        return kind;
                    }
                },
                else => {},
            }
            if (pos.* >= source.len) return null;
            c_opt = source[pos.*];
            pos.* += 1;
        }
        return null;
    }

    fn matchAtLineStart(
        self: *const State,
        source: []const u8,
        pos: *usize,
        is_zig: bool,
    ) !?TokenKind {
        if (pos.* >= source.len) return null;

        if (is_zig) {
            var zpos = pos.*;
            while (zpos < source.len and (source[zpos] == ' ' or source[zpos] == '\t')) : (zpos += 1) {}
            if (zpos + 1 < source.len and source[zpos] == '/' and source[zpos + 1] == '/') {
                zpos += 2;
                while (zpos < source.len and (source[zpos] == ' ' or source[zpos] == '\t')) : (zpos += 1) {}
                const start = zpos;
                while (zpos < source.len and (std.ascii.isAlphanumeric(source[zpos]) or source[zpos] == '_')) : (zpos += 1) {}
                const ident = source[start..zpos];
                for (self.tokens) |tok| {
                    if (tok.kind == .alternate and std.mem.eql(u8, ident, tok.name)) {
                        pos.* = zpos;
                        return tok.kind;
                    }
                }
            }
        }

        const start = pos.*;
        while (pos.* < source.len) {
            const b = source[pos.*];
            if (std.ascii.isAlphanumeric(b) or b == '_') {
                pos.* += 1;
            } else {
                break;
            }
        }
        if (pos.* == start and pos.* >= source.len) return null;
        const ident = source[start..pos.*];
        for (self.tokens) |tok| {
            if (std.mem.eql(u8, ident, tok.name)) {
                return tok.kind;
            }
        }
        return null;
    }

    fn copyToken(
        self: *const State,
        source: []const u8,
        pos: *usize,
        token_type: TokenType,
        zig_comment: bool,
        max_len: *usize,
    ) ![]const u8 {
        skipToTokenStart(source, pos, zig_comment);
        if (pos.* >= source.len) return error.UnexpectedEof;

        var buf: std.ArrayList(u8) = .empty;
        const first = source[pos.*];
        pos.* += 1;
        if (first == '"') {
            while (true) {
                if (pos.* >= source.len) return error.UnterminatedString;
                const ch = source[pos.*];
                pos.* += 1;
                if (ch == '"') break;
                if (ch == '\\') {
                    try buf.append(self.allocator, ch);
                    if (pos.* >= source.len) return error.UnterminatedString;
                    const esc = source[pos.*];
                    pos.* += 1;
                    try buf.append(self.allocator, esc);
                    if (zig_comment and esc == '\n') {
                        skipZigCommentPrefix(source, pos);
                    }
                } else {
                    const out_ch = if (token_type == .string_upcase and std.ascii.isAscii(ch) and std.ascii.isLower(ch))
                        std.ascii.toUpper(ch)
                    else
                        ch;
                    try buf.append(self.allocator, out_ch);
                }
            }
        } else {
            try buf.append(self.allocator, first);
            while (pos.* < source.len) {
                const ch = source[pos.*];
                if (isWhitespace(ch)) break;
                pos.* += 1;
                try buf.append(self.allocator, ch);
            }
            if (std.mem.eql(u8, buf.items, "LEXPR")) {
                buf.clearRetainingCapacity();
                try buf.appendSlice(self.allocator, lexpr_arity_string);
            } else if (token_type == .string and std.mem.eql(u8, buf.items, "0")) {
                buf.clearRetainingCapacity();
            }
        }
        max_len.* = @max(max_len.*, buf.items.len);
        return try buf.toOwnedSlice(self.allocator);
    }

    fn sortAndCheckDuplicates(self: *State) !void {
        if (self.built_in_p or self.slots.items.len <= 1) return;

        // Sort slots cleanly using stable merge/timsort from std.sort.
        const Context = struct {};
        std.mem.sort(
            ?Descriptor,
            self.slots.items,
            Context{},
            struct {
                fn lessThan(_: Context, a: ?Descriptor, b: ?Descriptor) bool {
                    return strcmpCi(a.?.scheme_name, b.?.scheme_name) < 0;
                }
            }.lessThan,
        );

        for (0..self.slots.items.len - 1) |i| {
            const a = self.slots.items[i].?;
            const b = self.slots.items[i + 1].?;
            if (strcmpCi(a.scheme_name, b.scheme_name) == 0) {
                std.debug.print(
                    "Error: repeated primitive: {s} ({s}) vs {s} ({s})\n",
                    .{ a.scheme_name, a.file_name, b.scheme_name, b.file_name },
                );
                return error.DuplicatePrimitive;
            }
        }
    }

    fn emit(self: *State, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        const count = self.slots.items.len;
        self.max_index_length = hexLength(count);
        const max_index: isize = @as(isize, @intCast(count)) - 1;

        try out.print(gpa, "/* Emacs: This is -*- C -*- code. */\n\n", .{});
        try out.print(
            gpa,
            "/* {s} primitive declarations. */\n\n",
            .{if (self.built_in_p) "Built in" else "User defined"},
        );
        try out.print(gpa, "#include \"usrdef.h\"\n\n", .{});
        if (max_index >= 0) {
            try out.print(
                gpa,
                "long {s} = {d}; /* = 0x{x} */\n\n",
                .{ self.the_variable, max_index, @as(usize, @intCast(max_index)) },
            );
        } else {
            try out.print(
                gpa,
                "long {s} = -1; /* = 0xffffffff */\n\n",
                .{self.the_variable},
            );
        }

        if (self.built_in_p) {
            try out.print(gpa, "/* The number of implemented primitives is {d}. */\n\n", .{count});
        }

        if (count == 0) {
            try out.print(gpa, "/* C does not understand empty arrays, thus it must be faked. */\n\n", .{});
        } else {
            try out.print(gpa, "extern SCHEME_OBJECT\n", .{});
            for (self.descriptors.items, 0..) |desc, idx| {
                try out.print(gpa, "  {s} (void)", .{desc.c_name});
                if (idx + 1 == self.descriptors.items.len) {
                    try out.print(gpa, ";\n\n", .{});
                } else {
                    try out.print(gpa, ",\n", .{});
                }
            }
        }

        // Emit Prim_inexistent procedure stub.
        try out.print(
            gpa,
            \\SCHEME_OBJECT
            \\{s} (void)
            \\{{
            \\  PRIMITIVE_HEADER ({s});
            \\
            \\  signal_error_from_primitive (ERR_UNIMPLEMENTED_PRIMITIVE);
            \\  /*NOTREACHED*/
            \\  PRIMITIVE_RETURN (UNSPECIFIC);
            \\}}
            \\
        ,
            .{ inexistent_entry.c_name, inexistent_entry.arity },
        );

        // Procedure table
        try out.print(gpa, "\x0c\nSCHEME_OBJECT (* ({s}_Procedure_Table [])) (void) = {{\n", .{self.the_kind});
        for (self.slots.items, 0..) |slot_opt, idx| {
            const desc = slot_opt orelse inexistent_entry;
            try self.emitEntry(out, gpa, @intCast(idx), desc);
            try out.print(gpa, ",\n", .{});
        }
        try self.emitEntry(out, gpa, -1, inexistent_entry);
        try out.print(gpa, "\n}};\n", .{});

        // Name table
        try out.print(gpa, "\x0c\nconst char * {s}_Name_Table [] = {{\n", .{self.the_kind});
        for (self.slots.items) |slot_opt| {
            const desc = slot_opt orelse inexistent_entry;
            try out.print(gpa, "  \"{s}\",\n", .{desc.scheme_name});
        }
        try out.print(gpa, "  \"{s}\"\n}};\n", .{inexistent_entry.scheme_name});

        // Documentation table
        try out.print(gpa, "\x0c\nconst char * {s}_Documentation_Table [] = {{\n", .{self.the_kind});
        for (self.slots.items) |slot_opt| {
            const desc = slot_opt orelse inexistent_entry;
            if (desc.documentation.len == 0) {
                try out.print(gpa, "  0,\n", .{});
            } else {
                try out.print(gpa, "  \"{s}\",\n", .{desc.documentation});
            }
        }
        try out.print(gpa, "  ((char *) 0)\n}};\n", .{});

        // Arity table
        try out.print(gpa, "\x0c\nint {s}_Arity_Table [] = {{\n", .{self.the_kind});
        for (self.slots.items) |slot_opt| {
            const desc = slot_opt orelse inexistent_entry;
            try out.print(gpa, "  {s},\n", .{desc.arity});
        }
        try out.print(gpa, "  {s}\n}};\n", .{inexistent_entry.arity});

        // Count table
        try out.print(gpa, "\x0c\nint {s}_Count_Table [] = {{\n", .{self.the_kind});
        for (self.slots.items) |slot_opt| {
            const desc = slot_opt orelse inexistent_entry;
            try out.print(gpa, "  ({s} * ((int) (sizeof (SCHEME_OBJECT)))),\n", .{desc.arity});
        }
        try out.print(
            gpa,
            "  ({s} * ((int) (sizeof (SCHEME_OBJECT))))\n}};\n",
            .{inexistent_entry.arity},
        );
    }

    fn emitEntry(
        self: *const State,
        out: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        index: isize,
        desc: Descriptor,
    ) !void {
        try out.print(gpa, "  {s}", .{desc.c_name});
        try appendSpaces(out, gpa, self.max_c_name_length -| desc.c_name.len);
        try out.print(gpa, " /* ", .{});
        try appendSpaces(out, gpa, self.max_arity_length -| desc.arity.len);
        try out.print(gpa, "{s} {s}", .{ desc.arity, desc.scheme_name });
        try appendSpaces(out, gpa, self.max_scheme_name_length -| desc.scheme_name.len);
        try out.print(gpa, " {s} ", .{self.the_kind});

        if (index >= 0) {
            const uidx: usize = @intCast(index);
            const idx_len = hexLength(uidx);
            try appendSpaces(out, gpa, self.max_index_length -| idx_len);
            try out.print(gpa, "0x{x}", .{uidx});
        } else {
            try appendSpaces(out, gpa, self.max_index_length -| 1);
            try out.print(gpa, "???", .{});
        }
        try out.print(gpa, " in {s} */", .{desc.file_name});
    }
};

fn appendSpaces(out: *std.ArrayList(u8), gpa: std.mem.Allocator, count: usize) !void {
    for (0..count) |_| {
        try out.append(gpa, ' ');
    }
}

fn hexLength(value: usize) usize {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{x}", .{value}) catch unreachable;
    return s.len;
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '(', ')', ',' => true,
        else => false,
    };
}

fn skipZigCommentPrefix(source: []const u8, pos: *usize) void {
    var p = pos.*;
    while (p < source.len and (source[p] == ' ' or source[p] == '\t')) : (p += 1) {}
    if (p + 1 < source.len and source[p] == '/' and source[p + 1] == '/') {
        p += 2;
        if (p < source.len and source[p] == ' ') p += 1;
        pos.* = p;
    }
}

fn skipToTokenStart(source: []const u8, pos: *usize, zig_comment: bool) void {
    while (pos.* < source.len and isWhitespace(source[pos.*])) {
        const ch = source[pos.*];
        pos.* += 1;
        if (zig_comment and ch == '\n') {
            skipZigCommentPrefix(source, pos);
        }
    }
}

fn skipToken(source: []const u8, pos: *usize) void {
    while (pos.* < source.len and !isWhitespace(source[pos.*])) {
        pos.* += 1;
    }
}

fn readIndex(arg: []const u8, ident: []const u8) !usize {
    if (std.mem.startsWith(u8, arg, "0x")) {
        return std.fmt.parseInt(usize, arg[2..], 16) catch {
            std.debug.print("{s} == invalid hex '{s}'\n", .{ ident, arg });
            return error.InvalidIndex;
        };
    }
    return std.fmt.parseInt(usize, arg, 10) catch {
        std.debug.print("{s} == invalid int '{s}'\n", .{ ident, arg });
        return error.InvalidIndex;
    };
}

fn strcmpCi(s1: []const u8, s2: []const u8) c_int {
    const min_len = @min(s1.len, s2.len);
    for (0..min_len) |i| {
        const c1 = std.ascii.toUpper(s1[i]);
        const c2 = std.ascii.toUpper(s2[i]);
        if (c1 < c2) return -1;
        if (c1 > c2) return 1;
    }
    if (s1.len < s2.len) return -1;
    if (s1.len > s2.len) return 1;
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var idx: usize = 1;
    const prog_name: []const u8 = if (args.len > 0) args[0] else "findprim";

    var out_path: ?[]const u8 = null;
    if (idx + 1 < args.len and std.mem.eql(u8, args[idx], "-o")) {
        out_path = args[idx + 1];
        idx += 2;
    }

    var state = State.init(arena, prog_name);

    if (idx + 1 < args.len and std.mem.eql(u8, args[idx], "-b")) {
        try state.initBuiltin(args[idx + 1]);
        idx += 2;
    } else if (idx < args.len and std.mem.eql(u8, args[idx], "-e")) {
        state.initExternal();
        idx += 1;
    }

    if (idx < args.len) {
        if (idx + 1 < args.len and std.mem.eql(u8, args[idx], "-l")) {
            const list_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[idx + 1], arena, .unlimited);
            var lines = std.mem.splitScalar(u8, list_bytes, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (line.len > 0 and line[0] != ';') {
                    const content = try std.Io.Dir.cwd().readFileAlloc(init.io, line, arena, .unlimited);
                    try state.processSource(line, content);
                }
            }
        } else {
            while (idx < args.len) : (idx += 1) {
                const fn_path = args[idx];
                const content = try std.Io.Dir.cwd().readFileAlloc(init.io, fn_path, arena, .unlimited);
                try state.processSource(fn_path, content);
            }
        }
        try state.sortAndCheckDuplicates();
    }

    var out_buf: std.ArrayList(u8) = .empty;
    try state.emit(&out_buf, arena);

    if (out_path) |path| {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out_buf.items });
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, out_buf.items);
    }
}

test "findprim parses C and Zig primitive definitions, sorts case-insensitively, and emits exact C" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const sample_c =
        \\/*
        \\DEFINE_PRIMITIVE ("IGNORED-IN-COMMENT", Prim_ignored, 0, 0, 0)
        \\*/
        \\DEFINE_PRIMITIVE ("Zebra-Prim", Prim_zebra, 0, LEXPR,
        \\  "(X ...)\n\
        \\Multiline \"quoted\" doc.")
        \\DEFINE_PRIMITIVE ("alpha-prim", Prim_alpha, 1, 1, 0)
        \\
    ;

    const sample_zig =
        \\// DEFINE_PRIMITIVE ("mid-prim", Prim_mid, 2, 2, "Zig doc.")
        \\pub export fn Prim_mid() callconv(.c) c_ulong { return 0; }
        \\
    ;

    var state = State.init(arena, "findprim-test");
    try state.processSource("sample.c", sample_c);
    try state.processSource("sample.zig", sample_zig);
    try state.sortAndCheckDuplicates();

    var out: std.ArrayList(u8) = .empty;
    try state.emit(&out, arena);

    // Externs in discovery order: zebra, alpha, mid.
    const pos_zebra = std.mem.indexOf(u8, out.items, "Prim_zebra (void),").?;
    const pos_alpha = std.mem.indexOf(u8, out.items, "Prim_alpha (void),").?;
    const pos_mid = std.mem.indexOf(u8, out.items, "Prim_mid (void);").?;
    try std.testing.expect(pos_zebra < pos_alpha and pos_alpha < pos_mid);

    // Tables sorted alphabetically: ALPHA-PRIM, MID-PRIM, ZEBRA-PRIM.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "IGNORED-IN-COMMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ALPHA-PRIM\",\n  \"MID-PRIM\",\n  \"ZEBRA-PRIM\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  -1,\n") != null); // LEXPR -> -1
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"Zig doc.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "long MAX_STATIC_PRIMITIVE = 2; /* = 0x2 */") != null);
}
