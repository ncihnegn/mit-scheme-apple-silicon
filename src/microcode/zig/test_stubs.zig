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

var mock_Registers: [14]obj.SchemeObject = @splat(0);

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
    }
    if (build_options.cc_is_native) {
        @export(&mockCcReturnAddressToEntryAddress, .{ .name = "cc_return_address_to_entry_address" });
        @export(&mockStartClosureRelocation, .{ .name = "start_closure_relocation" });
        @export(&mockCompiledClosureStart, .{ .name = "compiled_closure_start" });
        @export(&mockCompiledClosureCount, .{ .name = "compiled_closure_count" });
        @export(&mockCompiledClosureNext, .{ .name = "compiled_closure_next" });
        @export(&mockReadCompiledClosureTarget, .{ .name = "read_compiled_closure_target" });
        @export(&mockWriteCompiledClosureTarget, .{ .name = "write_compiled_closure_target" });
        @export(&mockSkipCompiledClosurePadding, .{ .name = "skip_compiled_closure_padding" });
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

fn mockReadCompiledClosureTarget(_: ?*anyopaque, _: *abi.RelocRef) callconv(.c) ?*anyopaque {
    return null;
}

fn mockWriteCompiledClosureTarget(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn mockSkipCompiledClosurePadding(ptr: ?*anyopaque) callconv(.c) [*]obj.SchemeObject {
    return @ptrCast(@alignCast(ptr.?));
}

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
