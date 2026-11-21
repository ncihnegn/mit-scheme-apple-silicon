const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const abi = @import("prim_abi.zig");
const storage = @import("storage.zig");
const utils = @import("utils.zig");
const boot = @import("boot.zig");
const option = @import("option.zig");
const gcloop = @import("gcloop.zig");

pub var signal_block_depth: i32 = 0;
pub var fatal_count: usize = 0;
pub var last_closed_channel: ?c_uint = null;
pub var mock_outf_calls: usize = 0;
pub var mock_trap_state: c_int = 4;
pub var mock_under_emacs: c_int = 0;

fn mockDummyPrim() callconv(.c) obj.SchemeObject {
    return obj.unspecific;
}

var mock_heap: [8192]obj.SchemeObject = @splat(0);
var mock_tospace: [8192]obj.SchemeObject = @splat(0);
var mock_stack: [128]obj.SchemeObject = @splat(0);
var mock_const: [64]obj.SchemeObject = @splat(0);

var mock_Registers: [abi.regblock_length]obj.SchemeObject = @splat(0);

comptime {
    if (@import("build_options").cc_support) {
        @export(&mock_Registers, .{ .name = "Registers" });
    }
}

pub export var compiler_processor_type: c_uint = abi.compiler_aarch64_type;
pub export var compiler_interface_version: c_uint = 4;
var mock_saved_argv = [_]?[*:0]const u8{ "scheme", "--batch-mode", null };
var mock_unused_argv = [_]?[*:0]const u8{ "--extra", null };
var mock_library_path = [_]?[*:0]const u8{ "/mock/lib1", "/mock/lib2", null };
pub export var compiler_utilities: obj.SchemeObject = obj.sharp_f;
pub var mock_icache_flush_calls: usize = 0;
pub var mock_resize_tospace_arg: c_ulong = 0;
pub export var OS_channel_table_size: abi.Tchannel = 16;
pub export var OS_have_select_p: c_int = 1;
pub var mock_channel_buf: [256]u8 = @splat(0);
var mock_channel_len: usize = 0;
var mock_channels_open: [16]bool = @splat(false);
var mock_channels_type: [16]c_uint = @splat(0);
var mock_channels_nonblock: [16]bool = @splat(false);
var mock_next_pipe_ch: abi.Tchannel = 6;
var mock_sel_fds: [8]c_int = @splat(0);
var mock_sel_modes: [8]c_uint = @splat(0);
var mock_sel_count: c_uint = 0;
var mock_sel_sentinel: u8 = 0;
var mock_file_lengths: [16]abi.OffT = @splat(0);
var mock_file_positions: [16]abi.OffT = @splat(0);
pub var mock_file_existence: c_uint = 0;
pub var mock_file_type: c_int = 0;
pub var mock_soft_link: ?[*:0]const u8 = null;
var mock_dir_open: bool = false;
pub var mock_jiffy: abi.ClockT = @bitCast(@as(isize, -1));
var mock_int_enables: abi.TinterruptEnables = 0;
var mock_int_chars: [2]abi.CcT = .{ 3, 7 };
var mock_int_handlers: [2]abi.CcT = .{ 'i', 'q' };
var mock_ispeed: c_uint = 0;
var mock_ospeed: c_uint = 0;
var mock_term_cooked: c_int = 1;
var mock_term_buffered: c_int = 1;
var mock_term_state: [4]u8 = .{ 1, 2, 3, 4 };
pub var mock_last_pty_sig: c_int = 0;
pub var mock_pty_ops: usize = 0;
pub export var OS_process_table_size: abi.Tprocess = 4;
var mock_proc_valid: [4]bool = @splat(false);
pub var mock_last_proc_sig: c_int = 0;
pub var mock_sock_accept_none: bool = false;
pub var mock_last_sock_shutdown: c_ulong = 0;
pub var mock_sock_listen_calls: usize = 0;
var mock_host_addr_1: [4]u8 = .{ 127, 0, 0, 1 };
var mock_host_addr_2: [4]u8 = .{ 10, 0, 0, 2 };
var mock_host_addrs = [_]?[*]u8{ &mock_host_addr_1, &mock_host_addr_2, null };
pub var mock_stat: abi.Stat = std.mem.zeroes(abi.Stat);
pub var mock_stat_2: abi.Stat = std.mem.zeroes(abi.Stat);
pub var mock_stat_ok: c_int = 1;
pub var mock_fs_type: ?[*:0]const u8 = "apfs";
pub var mock_channel_table_entries: [16]abi.Channel = @splat(.{ .descriptor = -1, .type = .unknown, .flags = .{} });
pub export var channel_table: [*]abi.Channel = &mock_channel_table_entries;
pub export var UX_out_of_files_p: bool = false;
pub var mock_terminal_open_calls: usize = 0;
pub var mock_tty_get_calls: usize = 0;
pub var mock_tty_set_calls: usize = 0;
pub var mock_tty_raw_calls: usize = 0;
pub var mock_sig_quit_handler: c_uint = 3;
pub var mock_sig_int_handler: c_uint = 5;
pub var mock_sig_tstp_handler: c_uint = 4;
pub var mock_write_var_cache_calls: usize = 0;
pub var mock_make_uuo_link_calls: usize = 0;
pub var mock_apply_compiled_calls: usize = 0;
pub var mock_last_compiled_nargs: c_ulong = 0;
pub var mock_last_compiled_proc: obj.SchemeObject = obj.sharp_f;
pub var mock_stack_marker_calls: usize = 0;
pub var mock_last_marker_thunk: obj.SchemeObject = obj.sharp_f;
pub var mock_int_mask_calls: usize = 0;
pub var mock_last_compiled_mask: c_ulong = 0;
pub var mock_last_compiled_new_mask: c_ulong = 0;
pub export var ERROR_OUTPUT: abi.OutfChannel = .{ .type = 1, .cookie = null };
pub export var FATAL_OUTPUT: abi.OutfChannel = .{ .type = 2, .cookie = null };
pub var mock_cc_entry_bad: bool = false;
pub var mock_cc_entry_type: abi.CcEntryType = .{
    .marker = .procedure,
    .args = .{ .for_procedure = .{ .n_required = 0, .n_optional = 0, .rest_p = false } },
};
pub export var MAX_STATIC_PRIMITIVE: c_long = 1;
pub export var Static_Primitive_Procedure_Table = [_]abi.PrimitiveProcedure{ &mockDummyPrim, &mockDummyPrim };
pub export var Static_Primitive_Arity_Table = [_]c_int{ 1, 2 };
pub export var Static_Primitive_Count_Table = [_]c_int{ @sizeOf(obj.SchemeObject), 2 * @sizeOf(obj.SchemeObject) };
pub export var Static_Primitive_Name_Table = [_]?[*:0]const u8{ "CAR", "CDR" };
pub export var Static_Primitive_Documentation_Table = [_]?[*:0]const u8{ "Returns car", null };

pub fn resetMockRuntime() void {
    signal_block_depth = 0;
    fatal_count = 0;
    last_closed_channel = null;
    mock_outf_calls = 0;
    mock_trap_state = 4;
    mock_under_emacs = 0;
    compiler_processor_type = abi.compiler_aarch64_type;
    compiler_interface_version = 4;
    boot.OS_Name = "unix";
    boot.OS_Variant = "macOS";
    boot.scheme_program_name = "mit-scheme-unit";
    boot.critical_section_name = null;
    boot.critical_section_hook_p = false;
    boot.critical_section_hook = null;
    boot.clearReloadSavedString();
    option.option_saved_argc = 2;
    option.option_saved_argv = &mock_saved_argv;
    option.option_unused_argc = 1;
    option.option_unused_argv = &mock_unused_argv;
    option.option_batch_mode = false;
    option.option_show_help = false;
    option.option_show_version = false;
    option.option_emacs_subprocess = false;
    option.option_force_interactive = false;
    option.option_disable_core_dump = false;
    option.option_library_path = &mock_library_path;
    option.option_band_file = null;
    option.option_fasl_file = null;
    option.option_heap_size = 1024;
    option.option_constant_size = 512;
    option.option_stack_size = 64;
    option.option_code_size = 64;
    mock_tospace = @splat(0);
    gcloop.resetForTesting();
    gcloop.initialize_gc(mock_tospace.len, &storage.heap_start, &storage.Free, &mockTospaceAllocator, &mockAbortGc);
    compiler_utilities = obj.sharp_f;
    mock_icache_flush_calls = 0;
    mock_resize_tospace_arg = 0;
    OS_channel_table_size = 16;
    OS_have_select_p = 1;
    mock_channel_buf = @splat(0);
    mock_channel_len = 0;
    mock_channels_open = @splat(false);
    mock_channels_type = @splat(0);
    mock_channels_nonblock = @splat(false);
    mock_next_pipe_ch = 6;
    mock_sel_fds = @splat(0);
    mock_sel_modes = @splat(0);
    mock_sel_count = 0;
    mock_file_lengths = @splat(0);
    mock_file_positions = @splat(0);
    mock_file_existence = 0;
    mock_file_type = 0;
    mock_soft_link = null;
    mock_dir_open = false;
    mock_jiffy = @bitCast(@as(isize, -1));
    mock_int_enables = 0;
    mock_int_chars = .{ 3, 7 };
    mock_int_handlers = .{ 'i', 'q' };
    mock_ispeed = 0;
    mock_ospeed = 0;
    mock_term_cooked = 1;
    mock_term_buffered = 1;
    mock_term_state = .{ 1, 2, 3, 4 };
    mock_last_pty_sig = 0;
    mock_pty_ops = 0;
    OS_process_table_size = 4;
    mock_proc_valid = @splat(false);
    mock_last_proc_sig = 0;
    mock_sock_accept_none = false;
    mock_last_sock_shutdown = 0;
    mock_sock_listen_calls = 0;
    mock_stat = std.mem.zeroes(abi.Stat);
    mock_stat_2 = std.mem.zeroes(abi.Stat);
    mock_stat_ok = 1;
    mock_fs_type = "apfs";
    mock_channel_table_entries = @splat(.{ .descriptor = -1, .type = .unknown, .flags = .{} });
    UX_out_of_files_p = false;
    mock_terminal_open_calls = 0;
    mock_tty_get_calls = 0;
    mock_tty_set_calls = 0;
    mock_tty_raw_calls = 0;
    mock_sig_quit_handler = 3;
    mock_sig_int_handler = 5;
    mock_sig_tstp_handler = 4;
    stop_signal_hook = null;
    subprocess_death_hook = null;
    storage.memory_block_end = null;
    storage.heap_reserved = 0;
    storage.ephemeron_array = obj.sharp_f;
    storage.ephemeron_count = 0;
    storage.n_ephemerons_requested = 0;
    storage.ephemeron_request_hard_p = false;
    mock_write_var_cache_calls = 0;
    mock_make_uuo_link_calls = 0;
    utils.history_register = null;
    utils.prev_restore_history_offset = 0;
    utils.death_blow = 0;
    mock_cc_entry_bad = false;
    mock_cc_entry_type = .{
        .marker = .procedure,
        .args = .{ .for_procedure = .{ .n_required = 0, .n_optional = 0, .rest_p = false } },
    };
    mock_apply_compiled_calls = 0;
    mock_last_compiled_nargs = 0;
    mock_last_compiled_proc = obj.sharp_f;
    mock_stack_marker_calls = 0;
    mock_last_marker_thunk = obj.sharp_f;
    mock_int_mask_calls = 0;
    mock_last_compiled_mask = 0;
    mock_last_compiled_new_mask = 0;
    mock_return_to_interpreter = obj.makeObject(obj.tc_compiled_return, 1);
    mock_reflect_to_interface = obj.makeObject(obj.tc_compiled_return, 2);
    mock_heap = @splat(0);
    mock_stack = @splat(0);
    mock_const = @splat(0);
    abi.Registers = @splat(0);
    abi.heap_start = (&mock_heap).ptr;
    abi.heap_end = (&mock_heap).ptr + mock_heap.len;
    abi.heap_alloc_limit = (&mock_heap).ptr + mock_heap.len - 16;
    abi.Free = abi.heap_start;
    abi.Free_primitive = abi.heap_start;
    abi.memory_block_start = abi.heap_start;
    abi.stack_start = (&mock_stack).ptr;
    abi.stack_end = (&mock_stack).ptr + mock_stack.len;
    abi.stack_start[0] = obj.makeBrokenHeart(abi.stack_start);
    abi.stack_guard = abi.stack_start + 8;
    abi.stack_pointer = abi.stack_end;
    abi.constant_start = (&mock_const).ptr;
    abi.constant_alloc_next = (&mock_const).ptr;
    abi.constant_end = (&mock_const).ptr + mock_const.len;
    abi.fixed_objects = obj.sharp_f;
    abi.gc_space_needed = 0;
    abi.trapping = false;
}

pub fn setArgs(args: []const obj.SchemeObject) void {
    std.debug.assert(args.len <= mock_stack.len);
    abi.stack_pointer = abi.stack_end - args.len;
    for (args, 0..) |arg, idx| {
        abi.stack_pointer[idx] = arg;
    }
    abi.Registers[abi.regblock_lexpr_actuals] = @intCast(args.len);
}

pub export fn OS_malloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(if (size == 0) 1 else size) orelse @panic("OS_malloc OOM");
}

pub export fn OS_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(ptr, if (size == 0) 1 else size) orelse @panic("OS_realloc OOM");
}

pub export fn OS_free(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

pub export fn block_signals() callconv(.c) void {
    signal_block_depth += 1;
}

pub export fn unblock_signals() callconv(.c) void {
    signal_block_depth -= 1;
}

pub export fn outf_fatal(_: [*:0]const u8, ...) callconv(.c) void {
    fatal_count += 1;
}

pub export fn outf_error(_: [*:0]const u8, ...) callconv(.c) void {
    mock_outf_calls += 1;
}

pub export fn outf_error_line(_: [*:0]const u8, ...) callconv(.c) void {
    mock_outf_calls += 1;
}

pub export fn outf_flush_error() callconv(.c) void {}

pub export fn outf_flush_fatal() callconv(.c) void {}

pub export fn OS_channel_close_noerror(ch: c_uint) callconv(.c) void {
    last_closed_channel = ch;
}

pub export fn Microcode_Termination(_: c_int) callconv(.c) noreturn {
    @panic("mock Microcode_Termination");
}

pub export fn termination_no_error_handler() callconv(.c) noreturn {
    @panic("mock termination_no_error_handler");
}

pub export fn OS_error_code_to_syserr(code: c_int) callconv(.c) c_int {
    return code;
}

pub export fn guarantee_interp_return() callconv(.c) void {}

comptime {
    if (@import("build_options").cc_support) {
        @export(&mockReadCcEntryType, .{ .name = "read_cc_entry_type" });
    }
}

fn mockReadCcEntryType(cet: *abi.CcEntryType, _: ?*anyopaque) callconv(.c) bool {
    if (mock_cc_entry_bad) return true;
    cet.* = mock_cc_entry_type;
    return false;
}

pub export fn OS_tty_map_interrupt_char(c: u8) callconv(.c) u8 {
    return c;
}

pub export fn outf(_: abi.OutfChannel, _: [*:0]const u8, ...) callconv(.c) void {
    mock_outf_calls += 1;
}

pub export fn outf_flush(_: abi.OutfChannel) callconv(.c) void {}

pub export fn OS_get_entropy(buf: *[32]u8) callconv(.c) void {
    for (buf, 0..) |*slot, idx| {
        slot.* = @intCast(idx + 0xA0);
    }
}

pub export fn abort_to_interpreter(_: c_long) callconv(.c) noreturn {
    @panic("mock abort_to_interpreter");
}

pub export fn OS_malloc_init(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(if (size == 0) 1 else size);
}

pub export fn termination_init_error() callconv(.c) noreturn {
    @panic("mock termination_init_error");
}

pub export fn termination_normal(_: c_int) callconv(.c) noreturn {
    @panic("mock termination_normal");
}

pub export fn OS_restartable_exit() callconv(.c) void {}

pub export fn OS_under_emacs_p() callconv(.c) c_int {
    return mock_under_emacs;
}

pub export fn OS_set_trap_state(state: c_int) callconv(.c) c_int {
    const old = mock_trap_state;
    mock_trap_state = state;
    return old;
}

pub export fn cc_block_linkage_info(block: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return block;
}

var mock_return_to_interpreter: obj.SchemeObject = obj.makeObject(obj.tc_compiled_return, 1);
var mock_reflect_to_interface: obj.SchemeObject = obj.makeObject(obj.tc_compiled_return, 2);

comptime {
    if (@import("build_options").cc_support) {
        @export(&mock_return_to_interpreter, .{ .name = "return_to_interpreter" });
        @export(&mock_reflect_to_interface, .{ .name = "reflect_to_interface" });
        @export(&mockCcReturnAddressP, .{ .name = "cc_return_address_p" });
        @export(&mockReflectToInterfaceFrameType, .{ .name = "reflect_to_interface_frame_type" });
        @export(&mockCpointCompiledCodeNext, .{ .name = "cpoint_compiled_code_next" });
        @export(&mockCpointCompiledAddressNext, .{ .name = "cpoint_compiled_address_next" });
        @export(&mockCpointReflectToInterfaceNext, .{ .name = "cpoint_reflect_to_interface_next" });
    }
}

fn mockCcReturnAddressP(o: obj.SchemeObject) callconv(.c) bool {
    return obj.ccReturnP(o) or obj.ccEntryP(o);
}

fn mockReflectToInterfaceFrameType(frame: [*]obj.SchemeObject) callconv(.c) c_int {
    if (!obj.fixnumP(frame[1]) or !obj.fixnumToUlongP(frame[1])) {
        return @intFromEnum(abi.ReturnFrameType.undefined);
    }
    return switch (obj.fixnumToUlong(frame[1])) {
        0 => @intFromEnum(abi.ReturnFrameType.cc_internal_apply),
        1 => @intFromEnum(abi.ReturnFrameType.cc_restore_interrupt_mask),
        2 => @intFromEnum(abi.ReturnFrameType.cc_stack_marker),
        3 => @intFromEnum(abi.ReturnFrameType.cc_bkpt),
        8 => @intFromEnum(abi.ReturnFrameType.cc_invocation),
        else => @intFromEnum(abi.ReturnFrameType.undefined),
    };
}

fn mockCpointCompiledCodeNext(_: obj.SchemeObject, idx: c_ulong) callconv(.c) c_ulong {
    return idx + 3;
}

fn mockCpointCompiledAddressNext(_: obj.SchemeObject, idx: c_ulong) callconv(.c) c_ulong {
    return idx + 4;
}

fn mockCpointReflectToInterfaceNext(_: obj.SchemeObject, idx: c_ulong) callconv(.c) c_ulong {
    return idx + 5;
}

comptime {
    if (@import("build_options").cc_support) {
        @export(&mockMakeReflectCodeTable, .{ .name = "make_reflect_code_table" });
    }
}

fn mockMakeReflectCodeTable() callconv(.c) obj.SchemeObject {
    return abi.make_vector(4, obj.sharp_f, true);
}

var mock_syscall_names_arr = [_]?[*:0]const u8{ "open", null, "read" };
var mock_syserr_names_arr = [_]?[*:0]const u8{ "EPERM", "ENOENT" };

pub export fn OS_tty_x_size() callconv(.c) c_uint {
    return 80;
}

pub export fn OS_tty_y_size() callconv(.c) c_uint {
    return 24;
}

pub export fn OS_syscall_names(len_out: *c_ulong, names_out: *[*]?[*:0]const u8) callconv(.c) void {
    len_out.* = mock_syscall_names_arr.len;
    names_out.* = &mock_syscall_names_arr;
}

pub export fn OS_syserr_names(len_out: *c_ulong, names_out: *[*]?[*:0]const u8) callconv(.c) void {
    len_out.* = mock_syserr_names_arr.len;
    names_out.* = &mock_syserr_names_arr;
}

comptime {
    if (@import("build_options").cc_support) {
        @export(&mockApplyCompiledFromPrimitive, .{ .name = "apply_compiled_from_primitive" });
        @export(&mockCompiledWithStackMarker, .{ .name = "compiled_with_stack_marker" });
        @export(&mockCompiledWithInterruptMask, .{ .name = "compiled_with_interrupt_mask" });
    }
}

fn mockApplyCompiledFromPrimitive(nargs: c_ulong, proc: obj.SchemeObject) callconv(.c) void {
    mock_apply_compiled_calls += 1;
    mock_last_compiled_nargs = nargs;
    mock_last_compiled_proc = proc;
}

fn mockCompiledWithStackMarker(thunk: obj.SchemeObject) callconv(.c) void {
    mock_stack_marker_calls += 1;
    mock_last_marker_thunk = thunk;
}

fn mockCompiledWithInterruptMask(old_mask: c_ulong, _: obj.SchemeObject, new_mask: c_ulong) callconv(.c) void {
    mock_int_mask_calls += 1;
    mock_last_compiled_mask = old_mask;
    mock_last_compiled_new_mask = new_mask;
}

fn mockTospaceAllocator(n_words: c_ulong, start_out: *?[*]obj.SchemeObject, end_out: *?[*]obj.SchemeObject) callconv(.c) void {
    mock_resize_tospace_arg = n_words;
    if (n_words == 0) {
        start_out.* = null;
        end_out.* = null;
        return;
    }
    std.debug.assert(n_words <= mock_tospace.len);
    start_out.* = (&mock_tospace).ptr;
    end_out.* = (&mock_tospace).ptr + @as(usize, @intCast(n_words));
}

fn mockAbortGc() callconv(.c) noreturn {
    @panic("mock abort_gc");
}

pub export fn OS_free_pages(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
pub export fn OS_expect_sequential_access(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) void {}
pub export fn OS_expect_normal_access(_: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) void {}

comptime {
    if (build_options.cc_is_native and builtin.cpu.arch == .aarch64) {
        @export(&mockAarch64FlushICache, .{ .name = "aarch64_flush_i_cache" });
        @export(&mockAarch64FlushICacheRegion, .{ .name = "aarch64_flush_i_cache_region" });
    }
}

fn mockAarch64FlushICache() callconv(.c) void {
    mock_icache_flush_calls += 1;
}

fn mockAarch64FlushICacheRegion(_: [*]obj.SchemeObject, _: usize) callconv(.c) void {
    mock_icache_flush_calls += 1;
}

pub export fn init_exit_scheme() callconv(.c) void {}
pub export fn OS_file_access(_: [*:0]const u8, _: c_uint) callconv(.c) c_int {
    return 0;
}
pub export fn OS_working_dir_pathname() callconv(.c) [*:0]const u8 {
    return "/mock/wd";
}
comptime {
    if (builtin.os.tag.isDarwin()) {
        @export(&mockMacosxMainBundleDir, .{ .name = "macosx_main_bundle_dir" });
    }
}
fn mockMacosxMainBundleDir() callconv(.c) ?[*:0]const u8 {
    return null;
}
pub export fn compiler_initialize(_: bool) callconv(.c) void {}
pub export fn OS_initialize() callconv(.c) void {}
pub export fn OS_announcement() callconv(.c) void {}
pub export fn Interpret() callconv(.c) void {}
pub export fn outf_console(_: [*:0]const u8, ...) callconv(.c) void {}
pub export fn outf_flush_console() callconv(.c) void {}

comptime {
    if (build_options.cc_support) {
        @export(&mockCcEntryToBlock, .{ .name = "cc_entry_to_block" });
        @export(&mockCcReturnToBlock, .{ .name = "cc_return_to_block" });
        @export(&mockCcEntryToBlockOffset, .{ .name = "cc_entry_to_block_offset" });
        @export(&mockCcReturnToBlockOffset, .{ .name = "cc_return_to_block_offset" });
        @export(&mockCcEntryToBlockAddress, .{ .name = "cc_entry_to_block_address" });
        @export(&mockCcReturnToBlockAddress, .{ .name = "cc_return_to_block_address" });
        @export(&mockCoerceToCompiled, .{ .name = "coerce_to_compiled" });
        @export(&mockCcEntryClosureP, .{ .name = "cc_entry_closure_p" });
        @export(&mockCcBlockClosureP, .{ .name = "cc_block_closure_p" });
        @export(&mockCcClosureToEntry, .{ .name = "cc_closure_to_entry" });
        @export(&mockUtilityIndexToName, .{ .name = "utility_index_to_name" });
        @export(&mockBuiltinIndexToName, .{ .name = "builtin_index_to_name" });
        @export(&mockDeclareCompiledCodeBlock, .{ .name = "declare_compiled_code_block" });
        @export(&mockBkptInstall, .{ .name = "bkpt_install" });
        @export(&mockBkptClosureInstall, .{ .name = "bkpt_closure_install" });
        @export(&mockBkptRemove, .{ .name = "bkpt_remove" });
        @export(&mockBkptP, .{ .name = "bkpt_p" });
        @export(&mockBkptProceed, .{ .name = "bkpt_proceed" });
        @export(&mockCcBlockEnvironment, .{ .name = "cc_block_environment" });
        @export(&mockWriteVariableCache, .{ .name = "write_variable_cache" });
        @export(&mockMakeUuoLink, .{ .name = "make_uuo_link" });
        @export(&mockCcBlockDebuggingInfo, .{ .name = "cc_block_debugging_info" });
        @export(&mockReadCcEntryOffset, .{ .name = "read_cc_entry_offset" });
        @export(&mockCompiledClosureObjects, .{ .name = "compiled_closure_objects" });
        @export(&mockCcEntryAddressToBlockAddress, .{ .name = "cc_entry_address_to_block_address" });
        @export(&mockCcReturnAddressToBlockAddress, .{ .name = "cc_return_address_to_block_address" });
        @export(&mockLinkageSectionType, .{ .name = "linkage_section_type" });
        @export(&mockLinkageSectionCount, .{ .name = "linkage_section_count" });
        @export(&mockReadUuoTarget, .{ .name = "read_uuo_target" });
        @export(&mockWriteUuoTarget, .{ .name = "write_uuo_target" });
        @export(&mockPlausibleCcBlockP, .{ .name = "plausible_cc_block_p" });
        @export(&mockPcToBuiltinIndex, .{ .name = "pc_to_builtin_index" });
        @export(&mockPcToUtilityIndex, .{ .name = "pc_to_utility_index" });
        @export(&mockWriteCcEntryType, .{ .name = "write_cc_entry_type" });
        @export(&mockWriteCcEntryOffset, .{ .name = "write_cc_entry_offset" });
        @export(&mockReadUuoSymbol, .{ .name = "read_uuo_symbol" });
        @export(&mockReadUuoFrameSize, .{ .name = "read_uuo_frame_size" });
        @export(&mockReadUuoTargetNoReloc, .{ .name = "read_uuo_target_no_reloc" });
        @export(&mockTrampolineEntrySize, .{ .name = "trampoline_entry_size" });
        @export(&mockTrampolineEntryAddr, .{ .name = "trampoline_entry_addr" });
        @export(&mockTrampolineReturnAddr, .{ .name = "trampoline_return_addr" });
        @export(&mockStoreTrampolineInsns, .{ .name = "store_trampoline_insns" });
        @export(&mockStoreTrampolineToInterfaceInsns, .{ .name = "store_trampoline_to_interface_insns" });
    }
    if (build_options.cc_is_svm) {
        @export(&mockSvmExportIp, .{ .name = "svm_export_instruction_pointer" });
        @export(&mockCtoInterfaceSvm, .{ .name = "C_to_interface" });
        @export(&mockInitializeSvm1, .{ .name = "initialize_svm1" });
    }
    if (build_options.cc_is_native) {
        @export(&mockCcReturnAddressToEntryAddress, .{ .name = "cc_return_address_to_entry_address" });
        @export(&mockStartClosureRelocation, .{ .name = "start_closure_relocation" });
        @export(&mockCompiledClosureStart, .{ .name = "compiled_closure_start" });
        @export(&mockCompiledClosureCount, .{ .name = "compiled_closure_count" });
        @export(&mockCompiledClosureNext, .{ .name = "compiled_closure_next" });
        @export(&mockCompiledClosureEntry, .{ .name = "compiled_closure_entry" });
        @export(&mockCompiledClosureEntryToTarget, .{ .name = "compiled_closure_entry_to_target" });
        @export(&mockReadCompiledClosureTarget, .{ .name = "read_compiled_closure_target" });
        @export(&mockWriteCompiledClosureTarget, .{ .name = "write_compiled_closure_target" });
        @export(&mockSkipCompiledClosurePadding, .{ .name = "skip_compiled_closure_padding" });
        @export(&mockInterfaceToC, .{ .name = "interface_to_C" });
        @export(&mockInterfaceToScheme, .{ .name = "interface_to_scheme" });
        @export(&mockInterfaceToSchemeReturn, .{ .name = "interface_to_scheme_return" });
        @export(&mockCtoInterfaceNative, .{ .name = "C_to_interface" });
        @export(&mockAarch64ResetHook, .{ .name = "aarch64_reset_hook" });
        @export(&mockX8664ResetHook, .{ .name = "x86_64_reset_hook" });
    }
}

fn mockCcEntryToBlock(entry: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return entry;
}

fn mockCcBlockEnvironment(block: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    const len = obj.vectorLength(block);
    return if (len >= 1) obj.vectorRef(block, @intCast(len - 1)) else obj.the_global_env;
}

fn mockWriteVariableCache(_: obj.SchemeObject, _: obj.SchemeObject, _: c_ulong) callconv(.c) void {
    mock_write_var_cache_calls += 1;
}

fn mockMakeUuoLink(_: obj.SchemeObject, _: obj.SchemeObject, _: obj.SchemeObject, _: c_ulong) callconv(.c) c_long {
    mock_make_uuo_link_calls += 1;
    return abi.prim_done;
}

fn mockCcReturnToBlock(ret: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return ret;
}

fn mockCcEntryToBlockOffset(_: obj.SchemeObject) callconv(.c) c_ulong {
    return 0;
}

fn mockCcReturnToBlockOffset(_: obj.SchemeObject) callconv(.c) c_ulong {
    return 0;
}

fn mockCcEntryToBlockAddress(_: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return (&mock_heap).ptr;
}

fn mockCcReturnToBlockAddress(_: obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return (&mock_heap).ptr;
}

fn mockCcReturnAddressToEntryAddress(addr: ?*anyopaque) callconv(.c) ?*anyopaque {
    return addr;
}

fn mockCoerceToCompiled(proc: obj.SchemeObject, _: c_uint, out: *obj.SchemeObject) callconv(.c) c_long {
    out.* = proc;
    return abi.prim_done;
}

fn mockCcEntryClosureP(_: obj.SchemeObject) callconv(.c) bool {
    return false;
}

fn mockCcBlockClosureP(_: obj.SchemeObject) callconv(.c) bool {
    return false;
}

fn mockCcClosureToEntry(entry: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return entry;
}

fn mockUtilityIndexToName(_: c_uint) callconv(.c) ?[*:0]const u8 {
    return null;
}

fn mockBuiltinIndexToName(_: c_uint) callconv(.c) ?[*:0]const u8 {
    return null;
}

fn mockDeclareCompiledCodeBlock(_: obj.SchemeObject) callconv(.c) void {}

fn mockBkptInstall(_: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return obj.sharp_f;
}

fn mockBkptClosureInstall(_: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return obj.sharp_f;
}

fn mockBkptRemove(_: ?*anyopaque, _: obj.SchemeObject) callconv(.c) void {}

fn mockBkptP(_: ?*anyopaque) callconv(.c) bool {
    return false;
}

fn mockBkptProceed(_: ?*anyopaque, _: obj.SchemeObject, state: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return state;
}

fn mockCcBlockDebuggingInfo(_: obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return obj.sharp_f;
}

fn mockReadCcEntryOffset(ceo: *abi.CcEntryOffset, _: ?*anyopaque) callconv(.c) bool {
    ceo.* = .{ .offset = 1, .continued_p = false };
    return true;
}

fn mockCompiledClosureObjects(ptr: [*]obj.SchemeObject) callconv(.c) [*]obj.SchemeObject {
    return ptr;
}

fn mockCcEntryAddressToBlockAddress(_: ?*anyopaque) callconv(.c) [*]obj.SchemeObject {
    return (&mock_heap).ptr;
}

fn mockCcReturnAddressToBlockAddress(_: ?*anyopaque) callconv(.c) [*]obj.SchemeObject {
    return (&mock_heap).ptr;
}

fn mockLinkageSectionType(marker: obj.SchemeObject) callconv(.c) c_uint {
    return @intCast(obj.objectDatum(marker) >> 16);
}

fn mockLinkageSectionCount(marker: obj.SchemeObject) callconv(.c) c_ulong {
    return obj.objectDatum(marker) & 0xFFFF;
}

fn mockReadUuoTarget(_: [*]obj.SchemeObject) callconv(.c) ?*anyopaque {
    return null;
}

fn mockWriteUuoTarget(_: ?*anyopaque, _: [*]obj.SchemeObject) callconv(.c) void {}

fn mockStartClosureRelocation(_: [*]obj.SchemeObject, ref: *abi.RelocRef) callconv(.c) void {
    ref.* = .{ .old_addr = null, .new_addr = null };
}

fn mockCompiledClosureStart(ptr: [*]obj.SchemeObject) callconv(.c) ?*anyopaque {
    return @ptrCast(ptr);
}

fn mockCompiledClosureCount(_: [*]obj.SchemeObject) callconv(.c) c_ulong {
    return 0;
}

fn mockCompiledClosureNext(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    return ptr;
}

fn mockReadCompiledClosureTarget(_: ?*anyopaque, _: ?*abi.RelocRef) callconv(.c) ?*anyopaque {
    return null;
}

fn mockWriteCompiledClosureTarget(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn mockSkipCompiledClosurePadding(ptr: ?*anyopaque) callconv(.c) [*]obj.SchemeObject {
    return @ptrCast(@alignCast(ptr.?));
}
fn mockPlausibleCcBlockP(_: [*]obj.SchemeObject) callconv(.c) c_int {
    return 1;
}
fn mockPcToBuiltinIndex(_: c_ulong) callconv(.c) c_int {
    return -1;
}
fn mockPcToUtilityIndex(_: c_ulong) callconv(.c) c_int {
    return -1;
}
fn mockSvmExportIp(pc: c_ulong) callconv(.c) c_ulong {
    return pc;
}

pub var mock_declare_builtin_calls: usize = 0;

pub export fn declare_builtin(_: c_ulong, _: [*:0]const u8) callconv(.c) void {
    mock_declare_builtin_calls += 1;
}

pub export fn make_compiled_procedure_type(
    cet: *abi.CcEntryType,
    n_required: c_uint,
    n_optional: c_uint,
    rest_p: bool,
) callconv(.c) void {
    cet.marker = .procedure;
    cet.args = .{ .for_procedure = .{
        .n_required = n_required,
        .n_optional = n_optional,
        .rest_p = rest_p,
    } };
}

pub export fn make_compiled_continuation_type(
    cet: *abi.CcEntryType,
    offset: c_ulong,
) callconv(.c) void {
    cet.marker = .continuation;
    cet.args = .{ .for_continuation = .{ .offset = offset } };
}

pub export fn make_cc_entry_type(
    cet: *abi.CcEntryType,
    marker: abi.CcEntryTypeMarker,
) callconv(.c) void {
    std.debug.assert(marker != .procedure and marker != .continuation);
    cet.* = std.mem.zeroes(abi.CcEntryType);
    cet.marker = marker;
}

pub export fn decode_old_style_format_word(cet: *abi.CcEntryType, fw: u16) callconv(.c) bool {
    var low: u16 = fw & 0x00FF;
    const high: u16 = (fw & 0xFF00) >> 8;
    var rest_p = false;

    if (high < 0x80) {
        if (high == 0x00 or low == 0x00 or low == 0x80) return true;
        if (low > 0x80) {
            low = 0xFF - low;
            rest_p = true;
        }
        if (!(high <= low)) return true;
        make_compiled_procedure_type(cet, high - 1, low - high, rest_p);
        return false;
    }
    if (low < 0x80) return true;
    if (low < 0xE0) {
        make_compiled_continuation_type(cet, @as(c_ulong, ((low & 0x7F) << 7) | (high & 0x7F)));
        return false;
    }
    if (high != 0xFF) return true;
    const marker: abi.CcEntryTypeMarker = switch (low) {
        0xFF => .expression,
        0xFE => .internal_procedure,
        0xFD => .trampoline,
        0xFC => .internal_continuation,
        0xFB => .return_to_interpreter,
        0xFA => .closure,
        else => return true,
    };
    make_cc_entry_type(cet, marker);
    return false;
}

pub export fn encode_old_style_format_word(cet: *abi.CcEntryType, fw_r: *u16) callconv(.c) bool {
    var low: u16 = 0;
    var high: u16 = 0;
    switch (cet.marker) {
        .procedure => {
            high = @intCast(cet.args.for_procedure.n_required + 1);
            low = @intCast(high + cet.args.for_procedure.n_optional);
            if (!(low < 0x80)) return true;
            if (cet.args.for_procedure.rest_p) {
                low = 0xFF - low;
            }
        },
        .continuation => {
            const n = cet.args.for_continuation.offset;
            if (!(n < 0x3000)) return true;
            high = @intCast((n & 0x7F) | 0x80);
            low = @intCast((n >> 7) | 0x80);
        },
        .expression => {
            low = 0xFF;
            high = 0xFF;
        },
        .internal_procedure => {
            low = 0xFE;
            high = 0xFF;
        },
        .trampoline => {
            low = 0xFD;
            high = 0xFF;
        },
        .internal_continuation => {
            low = 0xFC;
            high = 0xFF;
        },
        .return_to_interpreter => {
            low = 0xFB;
            high = 0xFF;
        },
        .closure => {
            low = 0xFA;
            high = 0xFF;
        },
    }
    fw_r.* = (high << 8) | low;
    return false;
}

pub export var prim_apply_error_code: c_long = 0;

pub export fn apply_primitive_external(_: obj.SchemeObject) callconv(.c) void {}

fn mockWriteCcEntryType(_: *abi.CcEntryType, _: ?*anyopaque) callconv(.c) bool {
    return false;
}
fn mockWriteCcEntryOffset(_: *abi.CcEntryOffset, _: ?*anyopaque) callconv(.c) bool {
    return false;
}
fn mockCompiledClosureEntry(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    return ptr;
}
fn mockCompiledClosureEntryToTarget(ptr: ?*anyopaque) callconv(.c) obj.SchemeObject {
    return obj.makeObject(obj.tc_compiled_entry, obj.rawAddressToDatum(@intFromPtr(ptr orelse return obj.sharp_f)));
}
fn mockReadUuoSymbol(saddr: [*]obj.SchemeObject) callconv(.c) obj.SchemeObject {
    return saddr[0];
}
fn mockReadUuoFrameSize(_: [*]obj.SchemeObject) callconv(.c) c_uint {
    return 1;
}
fn mockReadUuoTargetNoReloc(saddr: [*]obj.SchemeObject) callconv(.c) ?*anyopaque {
    return @ptrFromInt(@as(usize, @intCast(saddr[0])));
}
fn mockTrampolineEntrySize(n_entries: c_ulong) callconv(.c) c_ulong {
    return n_entries * 4;
}
fn mockTrampolineEntryAddr(block: [*]obj.SchemeObject, index: c_ulong) callconv(.c) ?*anyopaque {
    return @ptrCast(block + 2 + @as(usize, @intCast(index)) * 4 + 2);
}
fn mockTrampolineReturnAddr(block: [*]obj.SchemeObject, index: c_ulong) callconv(.c) ?*anyopaque {
    return mockTrampolineEntryAddr(block, index);
}
fn mockStoreTrampolineInsns(_: ?*anyopaque, _: u8) callconv(.c) bool {
    return false;
}
fn mockStoreTrampolineToInterfaceInsns(_: ?*anyopaque) callconv(.c) bool {
    return false;
}
fn mockInitializeSvm1() callconv(.c) void {}
fn mockCtoInterfaceSvm(_: ?*anyopaque) callconv(.c) c_long {
    return abi.prim_done;
}
fn mockInterfaceToC() callconv(.c) void {}
fn mockInterfaceToScheme() callconv(.c) void {}
fn mockInterfaceToSchemeReturn() callconv(.c) void {}
fn mockCtoInterfaceNative(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_long {
    return abi.prim_done;
}
fn mockAarch64ResetHook() callconv(.c) void {}
fn mockX8664ResetHook() callconv(.c) void {}

pub export fn compiler_reset(utilities: obj.SchemeObject) callconv(.c) void {
    _ = utilities;
}

pub export fn abort_to_interpreter_argument() callconv(.c) c_int {
    return @intCast(abi.err_fasl_file_bad_data);
}

pub export fn OS_file_remove(_: [*:0]const u8) callconv(.c) void {}
pub export fn OS_file_remove_link(_: [*:0]const u8) callconv(.c) void {}

pub fn setMockChannel(ch: abi.Tchannel, ch_type: c_uint, nonblock: bool) void {
    mock_channels_open[ch] = true;
    mock_channels_type[ch] = ch_type;
    mock_channels_nonblock[ch] = nonblock;
}

pub export fn OS_channel_open_p(ch: abi.Tchannel) callconv(.c) c_int {
    return if (ch < mock_channels_open.len and mock_channels_open[ch]) 1 else 0;
}

pub export fn OS_channel_close(ch: abi.Tchannel) callconv(.c) void {
    if (ch < mock_channels_open.len) {
        mock_channels_open[ch] = false;
        last_closed_channel = ch;
    }
}

pub export fn OS_channel_close_on_abort(ch: abi.Tchannel) callconv(.c) void {
    _ = ch;
}

pub export fn OS_channel_synchronize(_: abi.Tchannel) callconv(.c) void {}

pub export fn OS_channel_type(ch: abi.Tchannel) callconv(.c) c_uint {
    return if (ch < mock_channels_type.len) mock_channels_type[ch] else 0;
}

pub export fn OS_channel_read(_: abi.Tchannel, buf: ?*anyopaque, nbytes: usize) callconv(.c) c_long {
    const n = @min(nbytes, mock_channel_len);
    const dst: [*]u8 = @ptrCast(buf.?);
    @memcpy(dst[0..n], mock_channel_buf[0..n]);
    return @intCast(n);
}

pub export fn OS_channel_write(_: abi.Tchannel, buf: ?*const anyopaque, nbytes: usize) callconv(.c) c_long {
    const n = @min(nbytes, mock_channel_buf.len);
    const src: [*]const u8 = @ptrCast(buf.?);
    @memcpy(mock_channel_buf[0..n], src[0..n]);
    mock_channel_len = n;
    return @intCast(n);
}

pub export fn OS_make_pipe(rp: *abi.Tchannel, wp: *abi.Tchannel) callconv(.c) void {
    rp.* = mock_next_pipe_ch;
    wp.* = mock_next_pipe_ch + 1;
    setMockChannel(rp.*, @intFromEnum(abi.ChannelType.unix_pipe), false);
    setMockChannel(wp.*, @intFromEnum(abi.ChannelType.unix_pipe), false);
    mock_next_pipe_ch += 2;
}

pub export fn OS_channel_nonblocking_p(ch: abi.Tchannel) callconv(.c) c_int {
    return if (ch < mock_channels_nonblock.len and mock_channels_nonblock[ch]) 1 else 0;
}

pub export fn OS_channel_nonblocking(ch: abi.Tchannel) callconv(.c) void {
    if (ch < mock_channels_nonblock.len) mock_channels_nonblock[ch] = true;
}

pub export fn OS_channel_blocking(ch: abi.Tchannel) callconv(.c) void {
    if (ch < mock_channels_nonblock.len) mock_channels_nonblock[ch] = false;
}

pub export fn OS_allocate_select_registry() callconv(.c) abi.SelectRegistry {
    return &mock_sel_sentinel;
}

pub export fn OS_deallocate_select_registry(_: abi.SelectRegistry) callconv(.c) void {}

pub export fn OS_add_to_select_registry(_: abi.SelectRegistry, fd: c_int, mode: c_uint) callconv(.c) void {
    if (mock_sel_count < mock_sel_fds.len) {
        mock_sel_fds[mock_sel_count] = fd;
        mock_sel_modes[mock_sel_count] = mode;
        mock_sel_count += 1;
    }
}

pub export fn OS_remove_from_select_registry(_: abi.SelectRegistry, fd: c_int, _: c_uint) callconv(.c) void {
    var i: c_uint = 0;
    while (i < mock_sel_count) : (i += 1) {
        if (mock_sel_fds[i] == fd) {
            var j = i;
            while (j + 1 < mock_sel_count) : (j += 1) {
                mock_sel_fds[j] = mock_sel_fds[j + 1];
                mock_sel_modes[j] = mock_sel_modes[j + 1];
            }
            mock_sel_count -= 1;
            return;
        }
    }
}

pub export fn OS_select_registry_length(_: abi.SelectRegistry) callconv(.c) c_uint {
    return mock_sel_count;
}

pub export fn OS_select_registry_result(_: abi.SelectRegistry, idx: c_uint, fd_r: *c_int, mode_r: *c_uint) callconv(.c) void {
    fd_r.* = mock_sel_fds[idx];
    mode_r.* = mock_sel_modes[idx];
}

pub export fn OS_test_select_registry(_: abi.SelectRegistry, _: c_int) callconv(.c) c_int {
    return @intCast(mock_sel_count);
}

pub export fn OS_test_select_descriptor(_: c_int, _: c_int, mode: c_uint) callconv(.c) c_int {
    return @intCast(mode);
}

pub export fn OS_pause(_: bool, _: bool) callconv(.c) c_int {
    return 0;
}

pub export fn OS_process_any_status_change() callconv(.c) c_int {
    return 0;
}

pub fn setMockFileMetrics(ch: abi.Tchannel, len: abi.OffT, pos: abi.OffT) void {
    mock_file_lengths[ch] = len;
    mock_file_positions[ch] = pos;
}

fn mockOpenFile() abi.Tchannel {
    const ch: abi.Tchannel = 3;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.file), false);
    return ch;
}

pub export fn OS_open_input_file(_: [*:0]const u8) callconv(.c) abi.Tchannel {
    return mockOpenFile();
}
pub export fn OS_open_output_file(_: [*:0]const u8) callconv(.c) abi.Tchannel {
    return mockOpenFile();
}
pub export fn OS_open_exclusive_output_file(_: [*:0]const u8) callconv(.c) abi.Tchannel {
    return mockOpenFile();
}
pub export fn OS_open_io_file(_: [*:0]const u8) callconv(.c) abi.Tchannel {
    return mockOpenFile();
}
pub export fn OS_open_append_file(_: [*:0]const u8) callconv(.c) abi.Tchannel {
    return mockOpenFile();
}
pub export fn OS_file_length(ch: abi.Tchannel) callconv(.c) abi.OffT {
    return mock_file_lengths[ch];
}
pub export fn OS_file_position(ch: abi.Tchannel) callconv(.c) abi.OffT {
    return mock_file_positions[ch];
}
pub export fn OS_file_set_position(ch: abi.Tchannel, pos: abi.OffT) callconv(.c) void {
    mock_file_positions[ch] = pos;
}
pub export fn OS_file_truncate(ch: abi.Tchannel, len: abi.OffT) callconv(.c) void {
    mock_file_lengths[ch] = len;
}
pub export fn OS_file_existence_test(_: [*:0]const u8) callconv(.c) c_uint {
    return mock_file_existence;
}
pub export fn OS_file_existence_test_direct(_: [*:0]const u8) callconv(.c) c_uint {
    return mock_file_existence;
}
pub export fn OS_file_type_direct(_: [*:0]const u8) callconv(.c) c_int {
    return mock_file_type;
}
pub export fn OS_file_type_indirect(_: [*:0]const u8) callconv(.c) c_int {
    return mock_file_type;
}
pub export fn OS_file_directory_p(_: [*:0]const u8) callconv(.c) c_int {
    return 0;
}
pub export fn OS_file_soft_link_p(_: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return mock_soft_link;
}
pub export fn OS_file_rename(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) void {}
pub export fn OS_file_link_hard(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) void {}
pub export fn OS_file_link_soft(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) void {}
pub export fn OS_directory_make(_: [*:0]const u8) callconv(.c) void {}
pub export fn OS_directory_delete(_: [*:0]const u8) callconv(.c) void {}
pub export fn OS_file_touch(_: [*:0]const u8) callconv(.c) c_int {
    return 1;
}
pub export fn OS_directory_open(_: [*:0]const u8) callconv(.c) c_uint {
    mock_dir_open = true;
    return 1;
}
pub export fn OS_directory_valid_p(idx: c_uint) callconv(.c) c_int {
    return if (mock_dir_open and idx == 1) 1 else 0;
}
pub export fn OS_directory_close(idx: c_uint) callconv(.c) void {
    if (idx == 1) mock_dir_open = false;
}
pub export fn OS_directory_read(_: c_uint) callconv(.c) ?[*:0]const u8 {
    return "entry.scm";
}
pub export fn OS_directory_read_matching(_: c_uint, _: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return "match.scm";
}
pub export fn OS_file_copy(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) void {}

pub export fn OS_nanotime_since_utc_epoch(t: *abi.SchemeNanotime) callconv(.c) void {
    t.* = .{ .seconds = 123, .nanoseconds = 456 };
}
pub export fn OS_monotonic_nanotime(t: *abi.SchemeNanotime) callconv(.c) void {
    t.* = .{ .seconds = 789, .nanoseconds = 10 };
}
pub export fn OS_encoded_time() callconv(.c) abi.TimeT {
    return 1700000000;
}
pub export fn OS_decode_time(_: abi.TimeT, ts: *abi.TimeStructure) callconv(.c) void {
    ts.* = .{
        .year = 2024,
        .month = 11,
        .day = 20,
        .hour = 12,
        .minute = 30,
        .second = 45,
        .day_of_week = 3,
        .daylight_savings_time = -1,
        .time_zone = std.math.maxInt(c_int),
    };
}
pub export fn OS_decode_utc(t: abi.TimeT, ts: *abi.TimeStructure) callconv(.c) void {
    OS_decode_time(t, ts);
}
pub export fn OS_encode_time(_: *abi.TimeStructure) callconv(.c) abi.TimeT {
    return 1700000000;
}
pub export fn OS_process_clock() callconv(.c) f64 {
    return 100.0;
}
pub export fn OS_real_time_clock() callconv(.c) f64 {
    return 200.0;
}
pub export fn OS_process_timer_set(_: abi.ClockT, _: abi.ClockT) callconv(.c) void {}
pub export fn OS_process_timer_clear() callconv(.c) void {}
pub export fn OS_profile_timer_set(_: abi.ClockT, _: abi.ClockT) callconv(.c) void {}
pub export fn OS_profile_timer_clear() callconv(.c) void {}
pub export fn OS_real_timer_set(_: abi.ClockT, _: abi.ClockT) callconv(.c) void {}
pub export fn OS_real_timer_clear() callconv(.c) void {}
pub export fn OS_set_working_dir_pathname(_: [*:0]const u8) callconv(.c) void {}
pub export fn OS_current_jiffy() callconv(.c) abi.ClockT {
    return mock_jiffy;
}
pub export fn OS_jiffies_per_second() callconv(.c) abi.ClockT {
    return 1000;
}
pub export fn OS_error_code_to_message(code: c_uint) callconv(.c) ?[*:0]const u8 {
    return if (code == 1) "mock-err" else null;
}

pub export fn OS_tty_input_channel() callconv(.c) abi.Tchannel {
    return 0;
}
pub export fn OS_tty_output_channel() callconv(.c) abi.Tchannel {
    return 1;
}
pub export fn OS_tty_error_channel() callconv(.c) abi.Tchannel {
    return 2;
}
pub export fn OS_tty_command_beep() callconv(.c) [*:0]const u8 {
    return "\x07";
}
pub export fn OS_tty_command_clear() callconv(.c) [*:0]const u8 {
    return "\x1b[2J";
}
pub export fn OS_ctty_get_interrupt_enables(mask: *abi.TinterruptEnables) callconv(.c) void {
    mask.* = mock_int_enables;
}
pub export fn OS_ctty_set_interrupt_enables(mask: *abi.TinterruptEnables) callconv(.c) void {
    mock_int_enables = mask.*;
}
pub export fn OS_ctty_num_int_chars() callconv(.c) c_uint {
    return mock_int_chars.len;
}
pub export fn OS_ctty_get_int_chars() callconv(.c) [*]abi.CcT {
    return &mock_int_chars;
}
pub export fn OS_ctty_get_int_char_handlers() callconv(.c) [*]abi.CcT {
    return &mock_int_handlers;
}
pub export fn OS_ctty_set_int_chars(chars: [*]abi.CcT) callconv(.c) void {
    if (chars != @as([*]abi.CcT, &mock_int_chars)) {
        @memcpy(&mock_int_chars, chars[0..mock_int_chars.len]);
    }
}
pub export fn OS_ctty_set_int_char_handlers(handlers: [*]abi.CcT) callconv(.c) void {
    if (handlers != @as([*]abi.CcT, &mock_int_handlers)) {
        @memcpy(&mock_int_handlers, handlers[0..mock_int_handlers.len]);
    }
}

pub export fn OS_terminal_get_ispeed(_: abi.Tchannel) callconv(.c) c_uint {
    return mock_ispeed;
}
pub export fn OS_terminal_get_ospeed(_: abi.Tchannel) callconv(.c) c_uint {
    return mock_ospeed;
}
pub export fn OS_terminal_set_ispeed(_: abi.Tchannel, baud: c_uint) callconv(.c) void {
    mock_ispeed = baud;
}
pub export fn OS_terminal_set_ospeed(_: abi.Tchannel, baud: c_uint) callconv(.c) void {
    mock_ospeed = baud;
}
pub export fn arg_baud_index(n: c_uint) callconv(.c) c_uint {
    return @intCast(abi.arg_ulong_integer(@intCast(n)));
}
pub export fn OS_baud_index_to_rate(idx: c_uint) callconv(.c) c_uint {
    return if (idx == 3) 9600 else 0;
}
pub export fn OS_baud_rate_to_index(rate: c_uint) callconv(.c) c_int {
    return if (rate == 9600) 3 else -1;
}
pub export fn OS_terminal_state_size() callconv(.c) c_uint {
    return mock_term_state.len;
}
pub export fn OS_terminal_get_state(_: abi.Tchannel, statep: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(statep.?);
    @memcpy(dst[0..mock_term_state.len], &mock_term_state);
}
pub export fn OS_terminal_set_state(_: abi.Tchannel, statep: ?*anyopaque) callconv(.c) void {
    const src: [*]const u8 = @ptrCast(statep.?);
    @memcpy(&mock_term_state, src[0..mock_term_state.len]);
}
pub export fn OS_terminal_cooked_output_p(_: abi.Tchannel) callconv(.c) c_int {
    return mock_term_cooked;
}
pub export fn OS_terminal_raw_output(_: abi.Tchannel) callconv(.c) void {
    mock_term_cooked = 0;
}
pub export fn OS_terminal_cooked_output(_: abi.Tchannel) callconv(.c) void {
    mock_term_cooked = 1;
}
pub export fn OS_terminal_buffered_p(_: abi.Tchannel) callconv(.c) c_int {
    return mock_term_buffered;
}
pub export fn OS_terminal_buffered(_: abi.Tchannel) callconv(.c) void {
    mock_term_buffered = 1;
}
pub export fn OS_terminal_nonbuffered(_: abi.Tchannel) callconv(.c) void {
    mock_term_buffered = 0;
}
pub export fn OS_terminal_flush_input(_: abi.Tchannel) callconv(.c) void {}
pub export fn OS_terminal_flush_output(_: abi.Tchannel) callconv(.c) void {}
pub export fn OS_terminal_drain_output(_: abi.Tchannel) callconv(.c) void {}
pub export fn OS_job_control_p() callconv(.c) c_int {
    return 1;
}
pub export fn OS_have_ptys_p() callconv(.c) c_int {
    return 1;
}

pub export fn OS_open_pty_master(ch_out: *abi.Tchannel, master_name: *[*:0]const u8) callconv(.c) [*:0]const u8 {
    ch_out.* = 5;
    setMockChannel(5, @intFromEnum(abi.ChannelType.unix_pty_master), false);
    master_name.* = "/dev/ptym0";
    return "/dev/ptys0";
}
pub export fn OS_pty_master_send_signal(_: abi.Tchannel, sig: c_int) callconv(.c) void {
    mock_last_pty_sig = sig;
}
pub export fn OS_pty_master_kill(_: abi.Tchannel) callconv(.c) void {
    mock_pty_ops += 1;
}
pub export fn OS_pty_master_stop(_: abi.Tchannel) callconv(.c) void {
    mock_pty_ops += 1;
}
pub export fn OS_pty_master_continue(_: abi.Tchannel) callconv(.c) void {
    mock_pty_ops += 1;
}
pub export fn OS_pty_master_interrupt(_: abi.Tchannel) callconv(.c) void {
    mock_pty_ops += 1;
}
pub export fn OS_pty_master_quit(_: abi.Tchannel) callconv(.c) void {
    mock_pty_ops += 1;
}
pub export fn OS_pty_master_hangup(_: abi.Tchannel) callconv(.c) void {
    mock_pty_ops += 1;
}

pub export fn OS_make_subprocess(
    _: [*:0]const u8,
    _: [*]const ?[*:0]const u8,
    _: ?[*]const ?[*:0]const u8,
    _: ?[*:0]const u8,
    _: abi.ProcessCttyType,
    _: ?[*:0]u8,
    _: abi.ProcessChannelType,
    _: abi.Tchannel,
    _: abi.ProcessChannelType,
    _: abi.Tchannel,
    _: abi.ProcessChannelType,
    _: abi.Tchannel,
) callconv(.c) abi.Tprocess {
    mock_proc_valid[0] = true;
    return 0;
}
pub export fn OS_process_deallocate(p: abi.Tprocess) callconv(.c) void {
    if (p < mock_proc_valid.len) mock_proc_valid[p] = false;
}
pub export fn OS_process_valid_p(p: abi.Tprocess) callconv(.c) c_int {
    return if (p < mock_proc_valid.len and mock_proc_valid[p]) 1 else 0;
}
pub export fn OS_process_continuable_p(_: abi.Tprocess) callconv(.c) c_int {
    return 1;
}
pub export fn OS_process_foregroundable_p(_: abi.Tprocess) callconv(.c) c_int {
    return 1;
}
pub export fn OS_process_id(_: abi.Tprocess) callconv(.c) abi.PidT {
    return 4321;
}
pub export fn OS_process_jc_status(_: abi.Tprocess) callconv(.c) c_uint {
    return @intFromEnum(abi.ProcessJcStatus.jc);
}
pub export fn OS_process_status_sync(_: abi.Tprocess) callconv(.c) c_int {
    return 1;
}
pub export fn OS_process_status_sync_all() callconv(.c) c_int {
    return 1;
}
pub export fn OS_process_status(_: abi.Tprocess) callconv(.c) c_uint {
    return @intFromEnum(abi.ProcessStatus.running);
}
pub export fn OS_process_reason(_: abi.Tprocess) callconv(.c) c_ushort {
    return 0;
}
pub export fn OS_process_send_signal(_: abi.Tprocess, sig: c_int) callconv(.c) void {
    mock_last_proc_sig = sig;
}
pub export fn OS_process_kill(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_stop(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_interrupt(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_quit(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_hangup(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_continue_background(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_continue_foreground(_: abi.Tprocess) callconv(.c) void {}
pub export fn OS_process_wait(_: abi.Tprocess) callconv(.c) void {}

fn mockDupCString(s: []const u8) [*:0]const u8 {
    const mem: [*]u8 = @ptrCast(OS_malloc(s.len + 1).?);
    @memcpy(mem[0..s.len], s);
    mem[s.len] = 0;
    return @ptrCast(mem);
}

pub export fn UX_channel_descriptor(ch: abi.Tchannel) callconv(.c) c_int {
    return @intCast(ch + 10);
}
pub export fn OS_open_tcp_stream_socket(_: ?*anyopaque, _: c_uint) callconv(.c) abi.Tchannel {
    const ch: abi.Tchannel = 7;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.tcp_stream_socket), false);
    return ch;
}
pub export fn OS_shutdown_socket(_: abi.Tchannel, action: c_ulong) callconv(.c) void {
    mock_last_sock_shutdown = action;
}
pub export fn OS_get_service_by_name(service: [*:0]const u8, _: [*:0]const u8) callconv(.c) c_int {
    const name = std.mem.span(service);
    if (std.mem.eql(u8, name, "http")) return 80 << 8;
    return -1;
}
pub export fn OS_get_service_by_number(port: c_ulong) callconv(.c) c_ulong {
    return ((port & 0xff) << 8) | ((port >> 8) & 0xff);
}
pub export fn OS_host_address_length() callconv(.c) c_uint {
    return 4;
}
pub export fn OS_get_host_by_name(name: [*:0]const u8) callconv(.c) ?[*]?[*]u8 {
    if (std.mem.eql(u8, std.mem.span(name), "missing.invalid")) return null;
    return &mock_host_addrs;
}
pub export fn OS_get_host_name() callconv(.c) ?[*:0]const u8 {
    return mockDupCString("mock-host");
}
pub export fn OS_canonical_host_name(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (std.mem.eql(u8, std.mem.span(name), "missing.invalid")) return null;
    return mockDupCString("mock-host.local");
}
pub export fn OS_get_host_by_address(addr: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    _ = addr;
    return mockDupCString("localhost");
}
pub export fn OS_host_address_any(addr: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(addr.?);
    @memset(dst[0..4], 0);
}
pub export fn OS_host_address_loopback(addr: ?*anyopaque) callconv(.c) void {
    const dst: [*]u8 = @ptrCast(addr.?);
    dst[0] = 127;
    dst[1] = 0;
    dst[2] = 0;
    dst[3] = 1;
}
pub export fn OS_open_unix_stream_socket(_: [*:0]const u8, _: c_int) callconv(.c) abi.Tchannel {
    const ch: abi.Tchannel = 8;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.unix_stream_socket), false);
    return ch;
}
pub export fn OS_create_unix_server_socket(_: [*:0]const u8, _: c_int) callconv(.c) abi.Tchannel {
    if (mock_sock_accept_none) return abi.no_channel;
    const ch: abi.Tchannel = 9;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.unix_server_socket), false);
    return ch;
}
pub export fn OS_unix_server_connection_accept(_: abi.Tchannel) callconv(.c) abi.Tchannel {
    if (mock_sock_accept_none) return abi.no_channel;
    const ch: abi.Tchannel = 10;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.unix_stream_socket), false);
    return ch;
}
pub export fn OS_create_tcp_server_socket() callconv(.c) abi.Tchannel {
    const ch: abi.Tchannel = 11;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.tcp_server_socket), false);
    return ch;
}
pub export fn OS_bind_tcp_server_socket(_: abi.Tchannel, _: ?*anyopaque, _: c_uint) callconv(.c) void {}
pub export fn OS_listen_tcp_server_socket(_: abi.Tchannel) callconv(.c) void {
    mock_sock_listen_calls += 1;
}
pub export fn OS_tcp_server_connection_accept(_: abi.Tchannel, peer_host: ?*anyopaque, _: ?*c_uint) callconv(.c) abi.Tchannel {
    if (mock_sock_accept_none) return abi.no_channel;
    if (peer_host) |dst_raw| {
        const dst: [*]u8 = @ptrCast(dst_raw);
        dst[0] = 10;
        dst[1] = 0;
        dst[2] = 0;
        dst[3] = 2;
    }
    const ch: abi.Tchannel = 12;
    setMockChannel(ch, @intFromEnum(abi.ChannelType.tcp_stream_socket), false);
    return ch;
}

pub export fn UX_prim_check_errno(name: c_int) callconv(.c) void {
    _ = name;
}
pub export fn UX_prim_check_fd_errno(name: c_int) callconv(.c) void {
    _ = name;
}
pub export fn UX_SC_CLK_TCK() callconv(.c) abi.ClockT {
    return 100;
}
pub export fn channel_allocate() callconv(.c) abi.Tchannel {
    for (&mock_channel_table_entries, 0..) |entry, idx| {
        if (entry.descriptor < 0) return @intCast(idx);
    }
    return abi.no_channel;
}
pub export fn terminal_open(_: abi.Tchannel) callconv(.c) void {
    mock_terminal_open_calls += 1;
}
pub export fn OS_open_fd(fd: c_int) callconv(.c) abi.Tchannel {
    return abi.makeChannel(fd, .file);
}
pub export fn UX_terminal_get_state(_: c_int, s: *abi.TttyState) callconv(.c) c_int {
    s.* = std.mem.zeroes(abi.TttyState);
    mock_tty_get_calls += 1;
    return 0;
}
pub export fn UX_terminal_set_state(_: c_int, _: *const abi.TttyState) callconv(.c) c_int {
    mock_tty_set_calls += 1;
    return 0;
}
pub export fn terminal_state_raw(_: *abi.TttyState, _: c_int) callconv(.c) void {
    mock_tty_raw_calls += 1;
}
pub export fn termination_eof() callconv(.c) noreturn {
    @panic("mock termination_eof");
}
pub export fn UX_PC_VDISABLE(_: c_int) callconv(.c) abi.CcT {
    return if (builtin.os.tag.isDarwin()) 0xff else 0;
}
pub export fn UX_terminal_control_ok(_: c_int) callconv(.c) c_int {
    return 1;
}
pub export fn OS_signal_quit_handler() callconv(.c) c_uint {
    return mock_sig_quit_handler;
}
pub export fn OS_signal_int_handler() callconv(.c) c_uint {
    return mock_sig_int_handler;
}
pub export fn OS_signal_tstp_handler() callconv(.c) c_uint {
    return mock_sig_tstp_handler;
}
pub export fn OS_signal_set_interrupt_handlers(q: c_uint, i: c_uint, t: c_uint) callconv(.c) void {
    mock_sig_quit_handler = q;
    mock_sig_int_handler = i;
    mock_sig_tstp_handler = t;
}
pub export fn UX_initialize_ctty(_: c_int) callconv(.c) void {}
pub export fn UX_initialize_channels() callconv(.c) void {}
pub export fn UX_initialize_terminals() callconv(.c) void {}
pub export fn UX_initialize_environment() callconv(.c) void {}
pub export fn UX_initialize_tty() callconv(.c) void {}
pub export fn UX_initialize_userio() callconv(.c) void {}
pub export fn UX_initialize_signals() callconv(.c) void {}
pub export fn UX_initialize_processes() callconv(.c) void {}
pub export fn UX_initialize_trap_recovery() callconv(.c) void {}
pub export fn UX_initialize_directory_reader() callconv(.c) void {}
pub export fn UX_reset_channels() callconv(.c) void {}
pub export fn UX_reset_terminals() callconv(.c) void {}
pub export fn UX_reset_processes() callconv(.c) void {}
pub export fn OS_ctty_quit_char() callconv(.c) abi.CcT {
    return 3;
}
pub export fn UX_ctty_save_external_state() callconv(.c) void {}
pub export fn UX_ctty_save_internal_state() callconv(.c) void {}
pub export fn UX_ctty_restore_internal_state() callconv(.c) void {}
pub export fn UX_ctty_restore_external_state() callconv(.c) void {}
pub export fn OS_ctty_interrupt_control() callconv(.c) c_int {
    return 0;
}
pub export fn char_description(_: u8, _: c_int) callconv(.c) [*:0]const u8 {
    return "`^C'";
}
pub export fn userio_confirm(_: [*:0]const u8) callconv(.c) c_int {
    return 0;
}
pub export fn UX_dump_core() callconv(.c) void {}
pub export fn find_signal_name(sig: c_int) callconv(.c) [*:0]const u8 {
    return switch (sig) {
        8 => "SIGFPE",
        11 => "SIGSEGV",
        else => "SIGTEST",
    };
}
pub export fn termination_trap() callconv(.c) noreturn {
    @panic("mock termination_trap");
}
pub export fn userio_choose_option(_: [*:0]const u8, _: [*:0]const u8, _: [*]const ?[*:0]const u8) callconv(.c) u8 {
    return 'N';
}
pub export var CONSOLE_OUTPUT: abi.OutfChannel = .{ .type = 0, .cookie = null };
pub export fn FILE_OUTPUT(fp: *std.c.FILE) callconv(.c) abi.OutfChannel {
    return .{ .type = 3, .cookie = @ptrCast(fp) };
}
pub export fn OS_ctty_int_char() callconv(.c) abi.CcT {
    return 7;
}
pub export fn OS_ctty_tstp_char() callconv(.c) abi.CcT {
    return 26;
}
pub export fn OS_ctty_disabled_char() callconv(.c) abi.CcT {
    return 0xff;
}
pub export fn UX_reinitialize_tty() callconv(.c) void {}
pub export fn termination_signal(_: [*:0]const u8) callconv(.c) noreturn {
    @panic("mock termination_signal");
}
pub export fn hard_reset(_: ?*anyopaque) callconv(.c) void {}
pub export fn soft_reset() callconv(.c) void {}
pub export fn trap_handler(_: [*:0]const u8, _: c_int, _: ?*std.c.siginfo_t, _: ?*anyopaque) callconv(.c) void {}
pub export fn userio_buffered_input() callconv(.c) void {}
pub export fn userio_read_char() callconv(.c) u8 {
    return '\n';
}
pub export fn userio_read_char_raw() callconv(.c) u8 {
    return 'i';
}
pub export var stop_signal_hook: ?*const fn (c_int) callconv(.c) void = null;
pub export var subprocess_death_hook: ?*const fn (abi.PidT, *c_int) callconv(.c) void = null;
pub export fn OS_ctty_fd() callconv(.c) c_int {
    return -1;
}
pub export fn OS_save_internal_state() callconv(.c) void {}
pub export fn OS_restore_internal_state() callconv(.c) void {}
pub export fn OS_save_external_state() callconv(.c) void {}
pub export fn OS_restore_external_state() callconv(.c) void {}
pub export fn UX_initialize_child_signals() callconv(.c) void {}
pub export fn stop_signal_default(_: c_int) callconv(.c) void {}
pub export fn OS_current_user_name() callconv(.c) [*:0]const u8 {
    return "mock-user";
}
pub export fn OS_current_user_home_directory() callconv(.c) [*:0]const u8 {
    return "/home/mock-user";
}
pub export fn find_ccblock(pc: c_ulong) callconv(.c) obj.SchemeObject {
    return obj.ulongToFixnum(pc & 0xFFFF);
}
pub export fn UX_read_fd_status(_: c_int, s: *abi.Stat) callconv(.c) void {
    s.* = mock_stat;
}
pub export fn UX_read_file_status(filename: [*:0]const u8, s: *abi.Stat) callconv(.c) c_int {
    if (std.mem.eql(u8, std.mem.span(filename), "/same-alias")) {
        s.* = mock_stat_2;
        return mock_stat_ok;
    }
    s.* = mock_stat;
    return mock_stat_ok;
}
pub export fn UX_read_file_status_indirect(filename: [*:0]const u8, s: *abi.Stat) callconv(.c) c_int {
    return UX_read_file_status(filename, s);
}
pub export fn UX_file_system_type(_: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return mock_fs_type;
}

var mock_bc: ?[*:0]u8 = null;
var mock_up: ?[*:0]u8 = null;
var mock_pc: u8 = 0;
var mock_termcap_ospeed: c_short = 0;

comptime {
    if (build_options.use_termcap) {
        @export(&mock_bc, .{ .name = "BC" });
        @export(&mock_up, .{ .name = "UP" });
        @export(&mock_pc, .{ .name = "PC" });
        @export(&mock_termcap_ospeed, .{ .name = "ospeed" });
        @export(&mockTgetent, .{ .name = "tgetent" });
        @export(&mockTgetnum, .{ .name = "tgetnum" });
        @export(&mockTgetflag, .{ .name = "tgetflag" });
        @export(&mockTgetstr, .{ .name = "tgetstr" });
        @export(&mockTgoto, .{ .name = "tgoto" });
        @export(&mockTputs, .{ .name = "tputs" });
        @export(&mockTparam, .{ .name = "tparam" });
    }
}

fn mockTgetent(_: [*]u8, name: [*:0]const u8) callconv(.c) c_int {
    return if (std.mem.eql(u8, std.mem.span(name), "xterm")) 1 else 0;
}
fn mockTgetnum(id: [*:0]const u8) callconv(.c) c_int {
    return if (std.mem.eql(u8, std.mem.span(id), "co")) 80 else -1;
}
fn mockTgetflag(id: [*:0]const u8) callconv(.c) c_int {
    return if (std.mem.eql(u8, std.mem.span(id), "am")) 1 else 0;
}
fn mockTgetstr(id: [*:0]const u8, area: *[*]u8) callconv(.c) ?[*:0]u8 {
    if (!std.mem.eql(u8, std.mem.span(id), "cl")) return null;
    const seq = "\x1b[H\x1b[2J";
    const start = area.*;
    @memcpy(start[0..seq.len], seq);
    start[seq.len] = 0;
    area.* = start + seq.len + 1;
    return @ptrCast(start);
}
fn mockTgoto(_: [*:0]const u8, col: c_int, line: c_int) callconv(.c) ?[*:0]u8 {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(tmp[0 .. tmp.len - 1], "\x1b[{d};{d}H", .{ line + 1, col + 1 }) catch return null;
    tmp[s.len] = 0;
    return @constCast(mockDupCString(s));
}
fn mockTputs(str: [*:0]const u8, _: c_int, outc: *const fn (c_int) callconv(.c) c_int) callconv(.c) c_int {
    for (std.mem.span(str)) |ch| {
        _ = outc(@intCast(ch));
    }
    return 0;
}
fn mockTparam(fmt: [*:0]const u8, outstring: [*]u8, outlen: c_int, ...) callconv(.c) ?[*:0]u8 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const a1 = @cVaArg(&ap, c_int);
    const a2 = @cVaArg(&ap, c_int);
    const a3 = @cVaArg(&ap, c_int);
    const a4 = @cVaArg(&ap, c_int);
    const limit: usize = @intCast(outlen);
    const s = std.fmt.bufPrint(outstring[0 .. limit - 1], "{s}:{d},{d},{d},{d}", .{ std.mem.span(fmt), a1, a2, a3, a4 }) catch return null;
    outstring[s.len] = 0;
    return @ptrCast(outstring);
}
