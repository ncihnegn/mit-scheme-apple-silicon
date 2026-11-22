// Derived from MIT/GNU Scheme C sources (`src/microcode/option.c`, `option.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("prim_abi.zig");
const boot = @import("boot.zig");
const fasl = @import("../gc/fasl.zig");
const outf = @import("../support/outf.zig");

extern "c" fn strtoull(nptr: [*:0]const u8, endptr: *[*]const u8, base: c_int) c_ulonglong;

const compiler_interface_version: c_uint = 4;

const default_library_path_z: [:0]const u8 = blk: {
    var buf: [build_options.default_library_path.len:0]u8 = undefined;
    @memcpy(&buf, build_options.default_library_path);
    const frozen = buf;
    break :blk &frozen;
};

const package_string_z: [:0]const u8 = blk: {
    const prefix = "MIT/GNU Scheme ";
    var buf: [prefix.len + build_options.package_version.len:0]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], build_options.package_version);
    const frozen = buf;
    break :blk &frozen;
};

const library_path_variable: [*:0]const u8 = "MITSCHEME_LIBRARY_PATH";
const band_variable: [*:0]const u8 = "MITSCHEME_BAND";
const default_std_band: [*:0]const u8 = "all.com";
const heap_size_variable: [*:0]const u8 = "MITSCHEME_HEAP_SIZE";
const stack_size_variable: [*:0]const u8 = "MITSCHEME_STACK_SIZE";
const code_size_variable: [*:0]const u8 = "MITSCHEME_CODE_SIZE";

const default_heap_size: usize = if (@sizeOf(usize) == 8) 16384 else 3072;
const default_constant_size: usize = 1024;
const minimum_fasl_constant: usize = default_constant_size * 2;
const default_stack_size: usize = 1024;
const default_code_size: usize = if (@sizeOf(usize) == 8) 8192 else 4096;

const sub_directory_delimiter: u8 = '/';
const path_delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
const quote_char: u8 = '\\';

inline fn isDirSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

pub export var option_saved_argc: c_int = 0;
pub export var option_saved_argv: ?[*]?[*:0]const u8 = null;
pub export var option_unused_argc: c_int = 0;
pub export var option_unused_argv: ?[*]?[*:0]const u8 = null;

pub export var option_emacs_subprocess: bool = false;
pub export var option_force_interactive: bool = false;
pub export var option_disable_core_dump: bool = false;
pub export var option_batch_mode: bool = false;
pub export var option_show_version: bool = false;
pub export var option_show_help: bool = false;

pub var option_macosx_application_storage: bool = false;
comptime {
    if (builtin.os.tag.isDarwin()) {
        @export(&option_macosx_application_storage, .{ .name = "option_macosx_application" });
    }
}

pub export var option_library_path: ?[*]?[*:0]const u8 = null;
pub export var option_band_file: ?[*:0]const u8 = null;
pub export var option_fasl_file: ?[*:0]const u8 = null;

pub export var option_heap_size: usize = 0;
pub export var option_constant_size: usize = 0;
pub export var option_stack_size: usize = 0;
pub export var option_code_size: usize = 0;

var option_summary: bool = false;
var option_raw_library: ?[*:0]const u8 = null;
var option_raw_band: ?[*:0]const u8 = null;
var option_raw_heap: ?[*:0]const u8 = null;
var option_raw_constant: ?[*:0]const u8 = null;
var option_raw_stack: ?[*:0]const u8 = null;
var option_raw_code: ?[*:0]const u8 = null;
var option_raw_prepend: ?[*:0]const u8 = null;

const OptionDescriptor = extern struct {
    option: [*:0]const u8,
    argument_p: bool,
    value_cell: ?*anyopaque,
};

inline fn fileAbsolute(filename: [*:0]const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        if (isDirSep(filename[0])) return true;
        return filename[0] != 0 and std.ascii.isAlphabetic(filename[0]) and filename[1] == ':';
    }
    return filename[0] == sub_directory_delimiter;
}

inline fn fileReadable(filename: [*:0]const u8) bool {
    return abi.OS_file_access(filename, 4) != 0;
}

inline fn schemeWordsToBlocks(n: usize) usize {
    return (n + 1023) / 1024;
}

pub export fn print_help() callconv(.c) void {
    const macosx_doc: [*:0]const u8 = if (builtin.os.tag.isDarwin())
        "\n--macosx-application\n" ++
            "  Specifies that Scheme is running as a Mac OS X application.\n" ++
            "  This option is automatically supplied when the application is\n" ++
            "  launched from an icon, and should not be given under other\n" ++
            "  circumstances.\n"
    else
        "";

    outf.fatal(
        "Usage: mit-scheme --OPTION ARG ... --OPTION ARG ...\n\n" ++
            "This machine accepts the following command-line options.  The options\n" ++
            "may appear in any order, but they must all appear before any options\n" ++
            "for the band.\n\n" ++
            "--library PATH\n" ++
            "  Sets the library search path to PATH.  This is a colon-separated\n" ++
            "  list of directories that is searched to find various library files,\n" ++
            "  such as bands.  If this option is not given, the value of the\n" ++
            "  environment variable MITSCHEME_LIBRARY_PATH is used; if that isn't\n" ++
            "  defined, \"{s}\" is used.\n\n" ++
            "--band FILENAME\n" ++
            "  Specifies the initial band to be loaded.  Searches for FILENAME in\n" ++
            "  the working directory and the library directories.  If this option\n" ++
            "  is not given, the environment variable MITSCHEME_BAND is used, or\n" ++
            "  if that is not defined, \"{s}\".\n" ++
            "  If this option is not given, the working directory is not searched.\n\n" ++
            "--fasl FILENAME\n" ++
            "  Specifies that a cold load should be performed, using FILENAME as\n" ++
            "  the initial file to be loaded.  If this option isn't given, a normal\n" ++
            "  load is performed instead.  This option may not be used together\n" ++
            "  with the \"--band\" option.\n\n" ++
            "--heap BLOCKS\n" ++
            "  Specifies the size of the heap in 1024-word blocks.  Overrides any\n" ++
            "  default.\n\n" ++
            "--constant BLOCKS\n" ++
            "  Specifies the size of constant space in 1024-word blocks.  Overrides\n" ++
            "  any default.\n\n" ++
            "--stack BLOCKS\n" ++
            "  Specifies the size of the stack in 1024-word blocks.  Overrides any\n" ++
            "  default.\n\n" ++
            "--code BLOCKS\n" ++
            "  Specifies the size of compiled code space in 1024-word blocks.\n" ++
            "  Overrides any default.\n\n" ++
            "--option-summary\n" ++
            "  Causes Scheme to write option values to standard error.\n\n" ++
            "--help\n" ++
            "  Causes Scheme to report the available command line options.\n\n" ++
            "--version\n" ++
            "  Causes Scheme to report versions and copyrights, then exit.\n\n" ++
            "--batch-mode, --quiet, --silent\n" ++
            "  Suppresses the startup report of versions and copyrights, and the\n" ++
            "  valediction.\n\n" ++
            "--emacs\n" ++
            "  Specifies that Scheme is running as a subprocess of GNU Emacs.\n" ++
            "  This option is automatically supplied by GNU Emacs, and should not\n" ++
            "  be given under other circumstances.\n\n" ++
            "--interactive\n" ++
            "  If this option isn't specified, and Scheme's standard I/O is not a\n" ++
            "  terminal, Scheme will detach itself from its controlling terminal.\n" ++
            "  This will prevent it from getting signals sent to the process group\n" ++
            "  of that terminal.  If this option is specified, Scheme will not\n" ++
            "  detach itself from the controlling terminal.\n\n" ++
            "--nocore\n" ++
            "  Specifies that Scheme should not generate a core dump under any\n" ++
            "  circumstances.\n" ++
            "{s}\n" ++
            "--prepend-library DIRNAME\n" ++
            "  Adds DIRNAME to the front of the library search path.  This option\n" ++
            "  takes one value and can be specified once.\n",
        .{
            default_library_path_z.ptr,
            default_std_band,
            macosx_doc,
        },
    );
}

fn stringCompareCi(s1: [*:0]const u8, s2: [*:0]const u8) c_int {
    const a = std.mem.span(s1);
    const b = std.mem.span(s2);
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const c1 = std.ascii.toUpper(a[i]);
        const c2 = std.ascii.toUpper(b[i]);
        if (c1 != c2) return if (c1 < c2) -1 else 1;
    }
    if (a.len == b.len) return 0;
    return if (a.len < b.len) -1 else 1;
}

fn stringCopy(s: [*:0]const u8) [*:0]u8 {
    const slice = std.mem.span(s);
    const buf: [*]u8 = @ptrCast(abi.OS_malloc(slice.len + 1).?);
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf);
}

fn stringCopyLimited(s: [*:0]const u8, e: [*]const u8) [*:0]u8 {
    const n = @intFromPtr(e) - @intFromPtr(s);
    const buf: [*]u8 = @ptrCast(abi.OS_malloc(n + 1).?);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

inline fn mustQuoteCharP(c: u8) bool {
    return c == quote_char or c == path_delimiter;
}

fn quoteString(s: [*:0]const u8) [*:0]u8 {
    if (comptime builtin.os.tag == .windows) {
        return stringCopy(s);
    }
    const slice = std.mem.span(s);
    var n_chars: usize = 0;
    for (slice) |c| {
        if (mustQuoteCharP(c)) n_chars += 1;
        n_chars += 1;
    }
    const buf: [*]u8 = @ptrCast(abi.OS_malloc(n_chars + 1).?);
    var out: usize = 0;
    for (slice) |c| {
        if (mustQuoteCharP(c)) {
            buf[out] = quote_char;
            out += 1;
        }
        buf[out] = c;
        out += 1;
    }
    buf[out] = 0;
    return @ptrCast(buf);
}

fn unquoteString(s: [*:0]const u8) [*:0]u8 {
    if (comptime builtin.os.tag == .windows) {
        return stringCopy(s);
    }
    var scan: [*:0]const u8 = s;
    var n_chars: usize = 0;
    while (true) {
        var c = scan[0];
        scan += 1;
        if (c == quote_char) {
            c = scan[0];
            if (c == 0) break;
            scan += 1;
        }
        if (c == 0) break;
        n_chars += 1;
    }
    const buf: [*]u8 = @ptrCast(abi.OS_malloc(n_chars + 1).?);
    scan = s;
    var out: usize = 0;
    while (true) {
        var c = scan[0];
        scan += 1;
        if (c == quote_char) {
            c = scan[0];
            if (c == 0) break;
            scan += 1;
        }
        if (c == 0) break;
        buf[out] = c;
        out += 1;
    }
    buf[out] = 0;
    return @ptrCast(buf);
}

fn optionArgument(opt: [*:0]const u8, argument_p: bool, value_cell: ?*anyopaque) void {
    var desc: OptionDescriptor = .{
        .option = opt,
        .argument_p = argument_p,
        .value_cell = value_cell,
    };
    const bytes: [*]const u8 = @ptrCast(&desc);
    boot.scratch_obstack.grow(bytes[0..@sizeOf(OptionDescriptor)]);
}

fn parseOptions(argc: c_int, argv: [*]?[*:0]const u8) void {
    const argv_count: usize = if (argc > 0) @intCast(argc) else 0;
    var scan_idx: usize = if (argv_count > 0) 1 else 0;
    const end_idx: usize = argv_count;

    const n_descriptors = boot.scratch_obstack.objectSize() / @sizeOf(OptionDescriptor);
    const desc_raw = boot.scratch_obstack.finish();
    const descriptors: [*]OptionDescriptor = @ptrCast(@alignCast(desc_raw));

    for (0..n_descriptors) |i| {
        const desc = descriptors[i];
        if (desc.value_cell) |vc| {
            if (desc.argument_p) {
                const cell: *?[*:0]const u8 = @ptrCast(@alignCast(vc));
                cell.* = null;
            } else {
                const cell: *bool = @ptrCast(@alignCast(vc));
                cell.* = false;
            }
        }
    }

    while (scan_idx < end_idx) {
        const arg_ptr = argv[scan_idx] orelse break;
        scan_idx += 1;
        const arg_slice = std.mem.span(arg_ptr);
        var opt: [*:0]const u8 = arg_ptr;
        if (std.mem.startsWith(u8, arg_slice, "--")) {
            opt += 2;
        } else if (std.mem.startsWith(u8, arg_slice, "-")) {
            opt += 1;
        } else {
            scan_idx -= 1;
            break;
        }

        var matched = false;
        for (0..n_descriptors) |i| {
            const desc = descriptors[i];
            if (stringCompareCi(opt, desc.option) == 0) {
                matched = true;
                if (desc.argument_p) {
                    if (scan_idx < end_idx) {
                        const val = argv[scan_idx];
                        scan_idx += 1;
                        if (desc.value_cell) |vc| {
                            const cell: *?[*:0]const u8 = @ptrCast(@alignCast(vc));
                            cell.* = val;
                        }
                    } else {
                        const prog = boot.scheme_program_name orelse "mit-scheme";
                        outf.fatal("{s}: option --{s} requires an argument.\n", .{ prog, opt });
                        abi.termination_init_error();
                    }
                } else {
                    if (desc.value_cell) |vc| {
                        const cell: *bool = @ptrCast(@alignCast(vc));
                        cell.* = true;
                    }
                }
                break;
            }
        }
        if (!matched) {
            scan_idx -= 1;
            break;
        }
    }

    boot.scratch_obstack.freeObj(desc_raw);

    // Pass --version and --help through to the band, sort of.
    if (scan_idx > 0) {
        if (argv[scan_idx - 1]) |prev| {
            const s = std.mem.span(prev);
            if (std.mem.startsWith(u8, s, "--version")) {
                scan_idx -= 1;
            } else if (std.mem.startsWith(u8, s, "--help")) {
                scan_idx -= 1;
            }
        }
    }

    option_saved_argc = argc;
    option_saved_argv = argv;
    option_unused_argc = @intCast(end_idx - scan_idx);
    option_unused_argv = argv + scan_idx;
}

fn parseStandardOptions(argc: c_int, argv: [*]?[*:0]const u8) void {
    optionArgument("band", true, @ptrCast(&option_raw_band));
    optionArgument("batch-mode", false, @ptrCast(&option_batch_mode));
    optionArgument("code", true, @ptrCast(&option_raw_code));
    optionArgument("constant", true, @ptrCast(&option_raw_constant));
    optionArgument("emacs", false, @ptrCast(&option_emacs_subprocess));
    optionArgument("fasl", true, @ptrCast(&option_fasl_file));
    optionArgument("heap", true, @ptrCast(&option_raw_heap));
    optionArgument("help", false, @ptrCast(&option_show_help));
    optionArgument("interactive", false, @ptrCast(&option_force_interactive));
    optionArgument("library", true, @ptrCast(&option_raw_library));
    if (builtin.os.tag.isDarwin()) {
        optionArgument("macosx-application", false, @ptrCast(&option_macosx_application_storage));
    }
    optionArgument("nocore", false, @ptrCast(&option_disable_core_dump));
    optionArgument("option-summary", false, @ptrCast(&option_summary));
    optionArgument("prepend-library", true, @ptrCast(&option_raw_prepend));
    optionArgument("quiet", false, @ptrCast(&option_batch_mode));
    optionArgument("silent", false, @ptrCast(&option_batch_mode));
    optionArgument("stack", true, @ptrCast(&option_raw_stack));
    optionArgument("version", false, @ptrCast(&option_show_version));

    // Deprecated options
    optionArgument("compiler", false, null);
    optionArgument("edwin", false, null);
    optionArgument("large", false, null);
    optionArgument("utab", true, null);
    optionArgument("utabmd", true, null);

    parseOptions(argc, argv);
}

fn standardStringOption(option: ?[*:0]const u8, variable: [*:0]const u8, defval: [*:0]const u8) [*:0]const u8 {
    if (option) |opt| return opt;
    return std.c.getenv(variable) orelse defval;
}

fn parseNumericString(
    raw: [*:0]const u8,
    comptime err_fmt: []const u8,
    ctx_name: [*:0]const u8,
) usize {
    var end_ptr: [*]const u8 = undefined;
    const n = strtoull(raw, &end_ptr, 0);
    if (@intFromPtr(end_ptr) == @intFromPtr(raw) or end_ptr[0] != 0) {
        const prog = boot.scheme_program_name orelse "mit-scheme";
        outf.fatal(err_fmt, .{ prog, ctx_name, raw });
        abi.termination_init_error();
    }
    return @intCast(n);
}

fn standardNumericOption(
    option: [*:0]const u8,
    optval: ?[*:0]const u8,
    variable: ?[*:0]const u8,
    defval: usize,
) usize {
    if (optval) |val| {
        return parseNumericString(val, "{s}: illegal argument for option --{s}: {s}\n", option);
    }
    if (variable) |vname| {
        if (std.c.getenv(vname)) |t| {
            return parseNumericString(t, "{s}: illegal value for environment variable {s}: {s}\n", vname);
        }
    }
    return defval;
}

inline fn shouldStripTrailingSep(slice: []const u8) bool {
    if (slice.len == 0) return false;
    if (!isDirSep(slice[slice.len - 1])) return false;
    if (slice.len == 1) return false;
    if (comptime builtin.os.tag == .windows) {
        if (slice.len == 3 and std.ascii.isAlphabetic(slice[0]) and slice[1] == ':') return false;
    }
    return true;
}

fn getWd() [*:0]u8 {
    const wd = abi.OS_working_dir_pathname();
    var len = std.mem.len(wd);
    if (shouldStripTrailingSep(wd[0..len])) {
        len -= 1;
    }
    const result: [*]u8 = @ptrCast(abi.OS_malloc(len + 1).?);
    @memcpy(result[0..len], wd[0..len]);
    result[len] = 0;
    return @ptrCast(result);
}

fn findPathDelimiter(s: [*:0]const u8) ?[*]const u8 {
    var scan: [*:0]const u8 = s;
    while (true) {
        const cur = scan;
        var c = scan[0];
        scan += 1;
        if (c == path_delimiter) return cur;
        if (comptime builtin.os.tag != .windows) {
            if (c == quote_char) {
                c = scan[0];
                if (c == 0) return null;
                scan += 1;
            }
        }
        if (c == 0) return null;
    }
}

fn parsePathString(path: [*:0]const u8) [*]?[*:0]const u8 {
    var start: [*:0]const u8 = path;
    // Call OS_working_dir_pathname early before heap allocation (historical Unix getcwd constraint).
    const wd = getWd();
    const wd_slice = std.mem.span(wd);

    while (true) {
        const delim = findPathDelimiter(start);
        var unquoted: [*:0]u8 = undefined;
        if (delim) |d| {
            const copy = stringCopyLimited(start, d);
            unquoted = unquoteString(copy);
            abi.OS_free(@ptrCast(copy));
        } else {
            unquoted = unquoteString(start);
        }

        var unq_len = std.mem.len(unquoted);
        if (shouldStripTrailingSep(unquoted[0..unq_len])) {
            unq_len -= 1;
            unquoted[unq_len] = 0;
        }

        var element: [*:0]u8 = undefined;
        if (fileAbsolute(unquoted)) {
            element = unquoted;
        } else {
            if (unq_len == 0) {
                element = stringCopy(wd);
            } else {
                const buf: [*]u8 = @ptrCast(abi.OS_malloc(wd_slice.len + unq_len + 2).?);
                @memcpy(buf[0..wd_slice.len], wd_slice);
                buf[wd_slice.len] = sub_directory_delimiter;
                @memcpy(buf[wd_slice.len + 1 .. wd_slice.len + 1 + unq_len], unquoted[0..unq_len]);
                buf[wd_slice.len + 1 + unq_len] = 0;
                element = @ptrCast(buf);
            }
            abi.OS_free(@ptrCast(unquoted));
        }

        boot.scratch_obstack.growPtr(@ptrCast(element));
        if (delim) |d| {
            start = @ptrCast(d + 1);
        } else {
            break;
        }
    }

    boot.scratch_obstack.growPtr(null);
    abi.OS_free(@ptrCast(wd));

    const n_bytes = boot.scratch_obstack.objectSize();
    const finished = boot.scratch_obstack.finish();
    const elements: [*]?[*:0]const u8 = @ptrCast(@alignCast(finished));
    const count = n_bytes / @sizeOf(?[*:0]const u8);
    const result: [*]?[*:0]const u8 = @ptrCast(@alignCast(abi.OS_malloc(n_bytes).?));
    @memcpy(result[0..count], elements[0..count]);
    boot.scratch_obstack.freeObj(finished);
    return result;
}

fn freeParsedPath(path: [*]?[*:0]const u8) void {
    var i: usize = 0;
    while (path[i]) |elem| : (i += 1) {
        abi.OS_free(@ptrCast(@constCast(elem)));
    }
    abi.OS_free(@ptrCast(path));
}

fn addToLibraryPath(new_dir: [*:0]const u8, library_path: [*:0]const u8) [*:0]u8 {
    const quoted_dir = quoteString(new_dir);
    const quoted_slice = std.mem.span(quoted_dir);
    const lib_slice = std.mem.span(library_path);
    const result: [*]u8 = @ptrCast(abi.OS_malloc(quoted_slice.len + lib_slice.len + 2).?);
    @memcpy(result[0..quoted_slice.len], quoted_slice);
    result[quoted_slice.len] = path_delimiter;
    @memcpy(result[quoted_slice.len + 1 .. quoted_slice.len + 1 + lib_slice.len], lib_slice);
    result[quoted_slice.len + 1 + lib_slice.len] = 0;
    abi.OS_free(@ptrCast(quoted_dir));
    return @ptrCast(result);
}

pub export fn search_for_library_file(filename: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const fname_slice = std.mem.span(filename);
    const path = option_library_path orelse return null;
    var i: usize = 0;
    while (path[i]) |directory| : (i += 1) {
        const dir_slice = std.mem.span(directory);
        if (dir_slice.len > 0) {
            boot.scratch_obstack.grow(dir_slice);
            boot.scratch_obstack.growByte(sub_directory_delimiter);
        }
        boot.scratch_obstack.grow(fname_slice);
        boot.scratch_obstack.growByte(0);
        const fullname: [*:0]u8 = @ptrCast(boot.scratch_obstack.finish());
        if (fileReadable(fullname)) {
            const result = stringCopy(fullname);
            boot.scratch_obstack.freeObj(@ptrCast(fullname));
            return result;
        }
        boot.scratch_obstack.freeObj(@ptrCast(fullname));
    }
    return null;
}

pub export fn search_path_for_file(
    option: ?[*:0]const u8,
    filename: [*:0]const u8,
    default_p: bool,
    fail_p: bool,
) callconv(.c) ?[*:0]const u8 {
    if (search_for_library_file(filename)) |result| {
        return result;
    }
    if (!fail_p) {
        return filename;
    }

    const prog = boot.scheme_program_name orelse "mit-scheme";
    const kind: [*:0]const u8 = if (default_p) "default" else "file";
    outf.fatal("{s}: can't find a readable {s}", .{ prog, kind });
    if (option) |opt| {
        outf.fatal(" for option --{s}", .{opt});
    }
    outf.fatal(".\n", .{});
    outf.fatal("\tsearched for file {s} in these directories:\n", .{filename});
    if (!default_p) {
        outf.fatal("\t.\n", .{});
    }
    if (option_library_path) |path| {
        var i: usize = 0;
        while (path[i]) |elem| : (i += 1) {
            outf.fatal("\t{s}\n", .{elem});
        }
    }
    abi.termination_init_error();
}

fn standardFilenameOption(
    option: [*:0]const u8,
    optval: ?[*:0]const u8,
    variable: [*:0]const u8,
    defval: [*:0]const u8,
    fail_p: bool,
) ?[*:0]const u8 {
    const prog = boot.scheme_program_name orelse "mit-scheme";
    if (optval) |val| {
        if (fileReadable(val)) return stringCopy(val);
        if (fileAbsolute(val)) {
            if (fail_p) {
                outf.fatal("{s}: can't read file {s} for option --{s}.\n", .{ prog, val, option });
                abi.termination_init_error();
            }
            return stringCopy(val);
        }
        return search_path_for_file(option, val, false, fail_p);
    }

    const filename = std.c.getenv(variable) orelse defval;
    if (fileAbsolute(filename)) {
        if (!fileReadable(filename) and fail_p) {
            outf.fatal("{s}: can't read default file {s} for option --{s}.\n", .{ prog, filename, option });
            abi.termination_init_error();
        }
        return stringCopy(filename);
    }
    return search_path_for_file(option, filename, true, fail_p);
}

fn conflictingOptions(option1: [*:0]const u8, option2: [*:0]const u8) noreturn {
    const prog = boot.scheme_program_name orelse "mit-scheme";
    outf.fatal("{s}: can't specify both options --{s} and --{s}.\n", .{ prog, option1, option2 });
    abi.termination_init_error();
}

fn readBandSizes(
    filename: [*:0]const u8,
    constant_size: *usize,
    heap_size: *usize,
    code_size: *usize,
) bool {
    var handle: fasl.FaslFileHandle = null;
    if (!fasl.open_fasl_input_file(filename, &handle)) return false;

    var h: fasl.FaslHeader = std.mem.zeroes(fasl.FaslHeader);
    const ok = fasl.read_fasl_header(&h, handle);
    if (!fasl.close_fasl_input_file(handle) or !ok) return false;
    if (fasl.check_fasl_version(&h) != fasl.fasl_file_fine) return false;
    if (fasl.check_fasl_cc_version(&h, compiler_interface_version, build_options.compiler_processor_type) != fasl.fasl_file_fine) {
        return false;
    }

    constant_size.* = schemeWordsToBlocks(fasl.ptrRangeWords(h.constant_end, h.constant_start));
    heap_size.* = schemeWordsToBlocks(fasl.ptrRangeWords(h.heap_end, h.heap_start));
    code_size.* = schemeWordsToBlocks(fasl.ptrRangeWords(h.code_end, h.code_start));
    return true;
}

fn describeBooleanOption(name: [*:0]const u8, value: bool) void {
    const label: [*:0]const u8 = if (value) "yes" else "no";
    outf.fatal("  {s}: {s}\n", .{ name, label });
}

fn describeStringOption(name: [*:0]const u8, value: [*:0]const u8) void {
    outf.fatal("  {s}: {s}\n", .{ name, value });
}

fn describeSizeOption(name: [*:0]const u8, value: usize) void {
    const v: c_uint = @truncate(value);
    outf.fatal("  {s} size: {d}\n", .{ name, v });
}

fn describePathOption(name: [*:0]const u8, value: ?[*]?[*:0]const u8) void {
    outf.fatal("  {s}: ", .{name});
    if (value) |path| {
        if (path[0]) |first| {
            outf.fatal("{s}", .{first});
            var i: usize = 1;
            while (path[i]) |elem| : (i += 1) {
                outf.fatal(":{s}", .{elem});
            }
        }
    }
    outf.fatal("\n", .{});
}

fn describeOptions() void {
    outf.fatal("Summary of configuration options:\n", .{});
    describeSizeOption("heap", option_heap_size);
    describeSizeOption("constant-space", option_constant_size);
    describeSizeOption("stack", option_stack_size);
    describeSizeOption("code-space", option_code_size);
    describePathOption("library path", option_library_path);
    if (option_fasl_file) |ff| {
        describeStringOption("FASL file", ff);
    } else if (option_band_file) |bf| {
        describeStringOption("band", bf);
    }
    describeBooleanOption("emacs subprocess", option_emacs_subprocess);
    describeBooleanOption("force interactive", option_force_interactive);
    describeBooleanOption("disable core dump", option_disable_core_dump);
    describeBooleanOption("suppress noise", option_batch_mode);
    if (option_unused_argc == 0) {
        outf.fatal("  no unused arguments\n", .{});
    } else if (option_unused_argv) |unused| {
        outf.fatal("  unused arguments:", .{});
        const count: usize = if (option_unused_argc > 0) @intCast(option_unused_argc) else 0;
        for (0..count) |i| {
            if (unused[i]) |arg| {
                outf.fatal(" {s}", .{arg});
            }
        }
        outf.fatal("\n", .{});
    }
}

pub export fn read_command_line_options(argc: c_int, argv: [*]?[*:0]const u8) callconv(.c) void {
    var band_sizes_valid = false;
    var band_constant_size: usize = 0;
    var band_heap_size: usize = 0;
    var band_code_size: usize = 0;

    parseStandardOptions(argc, argv);

    if (option_library_path) |prev_path| {
        freeParsedPath(prev_path);
        option_library_path = null;
    }

    var default_library_path: [*:0]const u8 = default_library_path_z.ptr;
    var bundle_lib_alloc: ?[*:0]u8 = null;
    defer if (bundle_lib_alloc) |p| abi.OS_free(@ptrCast(p));

    if (builtin.os.tag.isDarwin()) {
        if (abi.macosx_main_bundle_dir()) |main_bundle_path| {
            const added = addToLibraryPath(main_bundle_path, default_library_path);
            bundle_lib_alloc = added;
            default_library_path = added;
            abi.OS_free(@ptrCast(@constCast(main_bundle_path)));
        }
    }

    var library_path = standardStringOption(option_raw_library, library_path_variable, default_library_path);
    var prepend_alloc: ?[*:0]u8 = null;
    defer if (prepend_alloc) |p| abi.OS_free(@ptrCast(p));

    if (option_raw_prepend) |prep| {
        const added = addToLibraryPath(prep, library_path);
        prepend_alloc = added;
        library_path = added;
    }
    option_library_path = parsePathString(library_path);

    if (option_band_file) |prev_band| {
        abi.OS_free(@ptrCast(@constCast(prev_band)));
        option_band_file = null;
    }

    if (option_fasl_file) |fasl_file| {
        if (option_raw_band != null) {
            conflictingOptions("fasl", "band");
        }
        if (!fileReadable(fasl_file)) {
            const prog = boot.scheme_program_name orelse "mit-scheme";
            outf.fatal("{s}: can't read option file: --fasl {s}\n", .{ prog, fasl_file });
            abi.termination_init_error();
        }
    } else {
        var default_band: [*:0]const u8 = default_std_band;
        const bands = [_][*:0]const u8{
            default_std_band,
            "runtime.com",
            "mechanics.com",
            "edwin-mechanics.com",
        };
        for (bands) |b| {
            if (search_for_library_file(b)) |found| {
                abi.OS_free(@ptrCast(@constCast(found)));
                default_band = b;
                break;
            }
        }
        option_band_file = standardFilenameOption("band", option_raw_band, band_variable, default_band, true);
    }

    if (option_band_file) |bf| {
        band_sizes_valid = readBandSizes(bf, &band_constant_size, &band_heap_size, &band_code_size);
    }

    option_heap_size = standardNumericOption("heap", option_raw_heap, heap_size_variable, default_heap_size);
    if (band_sizes_valid) {
        option_heap_size += band_heap_size;
    } else if (option_fasl_file != null and option_heap_size < minimum_fasl_constant) {
        option_heap_size = minimum_fasl_constant;
    }

    option_constant_size = standardNumericOption(
        "constant",
        option_raw_constant,
        null,
        if (band_sizes_valid) band_constant_size else default_constant_size,
    );
    option_stack_size = standardNumericOption("stack", option_raw_stack, stack_size_variable, default_stack_size);
    option_code_size = standardNumericOption("code", option_raw_code, code_size_variable, default_code_size);
    if (band_sizes_valid) {
        option_code_size += band_code_size;
    }

    if (option_show_version) {
        outf.console("{s}\n", .{package_string_z.ptr});
        outf.flushConsole();
    }
    if (option_show_help) {
        option_batch_mode = true;
        print_help();
    }
    if (option_summary) {
        describeOptions();
    }
}

test "option quoting, parsePathString, parseStandardOptions, and readBandSizes" {
    const stubs = @import("test_stubs.zig");
    const obj = @import("scheme_obj.zig");
    stubs.resetMockRuntime();
    defer stubs.resetMockRuntime();

    boot.scratch_obstack.init(&boot.obstack_chunk_alloc, &std.c.free);
    defer boot.scratch_obstack.freeObj(null);

    // Quote / unquote round-trip
    const orig: [*:0]const u8 = "a:b\\c";
    const quoted = quoteString(orig);
    defer abi.OS_free(@ptrCast(quoted));
    try std.testing.expectEqualStrings("a\\:b\\\\c", std.mem.span(quoted));
    const unquoted = unquoteString(quoted);
    defer abi.OS_free(@ptrCast(unquoted));
    try std.testing.expectEqualStrings("a:b\\c", std.mem.span(unquoted));

    // parsePathString with absolute, escaped colon, and empty segment (= wd)
    const parsed = parsePathString("/abs/one/:/dir\\:two::rel/");
    defer freeParsedPath(parsed);
    try std.testing.expectEqualStrings("/abs/one", std.mem.span(parsed[0].?));
    try std.testing.expectEqualStrings("/dir:two", std.mem.span(parsed[1].?));
    try std.testing.expectEqualStrings("/mock/wd", std.mem.span(parsed[2].?));
    try std.testing.expectEqualStrings("/mock/wd/rel", std.mem.span(parsed[3].?));
    try std.testing.expect(parsed[4] == null);

    // parseStandardOptions flags, numeric options, and --version pass-through
    var argv1 = [_]?[*:0]const u8{ "mit-scheme", "--batch-mode", "--heap", "0x2000", "--extra" };
    parseStandardOptions(argv1.len, &argv1);
    try std.testing.expect(option_batch_mode);
    try std.testing.expectEqual(@as(usize, 8192), standardNumericOption("heap", option_raw_heap, null, default_heap_size));
    try std.testing.expectEqual(@as(c_int, 1), option_unused_argc);
    try std.testing.expectEqualStrings("--extra", std.mem.span(option_unused_argv.?[0].?));

    var argv2 = [_]?[*:0]const u8{ "mit-scheme", "--batch-mode", "--version" };
    parseStandardOptions(argv2.len, &argv2);
    try std.testing.expect(option_show_version);
    try std.testing.expectEqual(@as(c_int, 1), option_unused_argc);
    try std.testing.expectEqualStrings("--version", std.mem.span(option_unused_argv.?[0].?));

    // readBandSizes against a temporary FASL file
    const tmp_path: [*:0]const u8 = "/tmp/zig_option_band_test.com";
    var arena: [64]obj.SchemeObject = @splat(0);
    var hdr = std.mem.zeroes(fasl.FaslHeader);
    hdr.version = fasl.fasl_version_code_space;
    hdr.arch = fasl.currentFaslArch();
    hdr.cc_version = compiler_interface_version;
    hdr.cc_arch = build_options.compiler_processor_type;
    hdr.band_p = true;
    hdr.constant_start = arena[0..].ptr;
    hdr.constant_end = arena[0..].ptr + 1025; // 2 blocks
    hdr.heap_start = arena[0..].ptr;
    hdr.heap_end = arena[0..].ptr + 2048; // 2 blocks
    hdr.code_start = arena[0..].ptr;
    hdr.code_end = arena[0..].ptr + 1; // 1 block

    var wf: fasl.FaslFileHandle = null;
    try std.testing.expect(fasl.open_fasl_output_file(tmp_path, &wf));
    try std.testing.expect(fasl.write_fasl_header(&hdr, wf));
    try std.testing.expect(fasl.close_fasl_output_file(wf));
    defer if (comptime builtin.os.tag == .windows) {
        const WinUnlink = struct {
            extern "c" fn _unlink([*:0]const u8) c_int;
        };
        _ = WinUnlink._unlink(tmp_path);
    } else {
        _ = std.c.unlink(tmp_path);
    };

    var cs: usize = 0;
    var hs: usize = 0;
    var cds: usize = 0;
    try std.testing.expect(readBandSizes(tmp_path, &cs, &hs, &cds));
    try std.testing.expectEqual(@as(usize, 2), cs);
    try std.testing.expectEqual(@as(usize, 2), hs);
    try std.testing.expectEqual(@as(usize, 1), cds);
}
