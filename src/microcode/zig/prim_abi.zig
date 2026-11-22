// Derived from MIT/GNU Scheme C sources (`src/microcode/prims.h`, `src/microcode/prim.h`, `src/microcode/extern.h`, `src/microcode/intrpt.h`, `src/microcode/memmag.h`, `src/microcode/gc.h`, `src/microcode/const.h`, `src/microcode/errors.h`, `src/microcode/fixobj.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");
const outf = @import("outf.zig");

pub const regblock_memtop: usize = 0;
pub const regblock_int_mask: usize = 1;
pub const regblock_val: usize = 2;
pub const regblock_env: usize = 3;
pub const regblock_expr: usize = 5;
pub const regblock_return: usize = 6;
pub const regblock_lexpr_actuals: usize = 7;
pub const regblock_primitive: usize = 8;
pub const regblock_closure_free: usize = 9;
pub const regblock_closure_space: usize = 10;
pub const regblock_stack_guard: usize = 11;
pub const regblock_int_code: usize = 12;
pub const regblock_reflect_to_interface: usize = 13;

pub const regblock_length: usize = switch (build_options.compiler_processor_type) {
    compiler_aarch64_type => 16 + (256 * 1),
    compiler_x86_64_type => 16 + (256 * 1) + (80 * 1),
    compiler_svm_type => 14 + (256 * 2),
    else => 14,
};

pub const int_stack_overflow: usize = 0x0001;
pub const int_gc: usize = 0x0004;
pub const int_character: usize = 0x0010;
pub const int_timer: usize = 0x0040;
pub const int_global_3: usize = 0x0080;
pub const int_suspend: usize = 0x0100;
pub const int_mask: usize = (@as(usize, 1) << 16) - 1;
pub const max_interrupt_number: usize = 0xF;

pub const term_halt: c_int = 0x00;
pub const term_disk_restore: c_int = 0x01;
pub const term_broken_heart: c_int = 0x02;
pub const term_bad_stack: c_int = 0x06;
pub const term_stack_overflow: c_int = 0x07;
pub const term_no_error_handler: c_int = 0x09;
pub const term_no_interrupt_handler: c_int = 0x0A;
pub const term_exit: c_int = 0x0C;
pub const term_eof: c_int = 0x0E;
pub const term_term_handler: c_int = 0x10;
pub const term_end_of_computation: c_int = 0x11;
pub const term_compiler_death: c_int = 0x13;
pub const term_gc_out_of_space: c_int = 0x14;
pub const term_no_space: c_int = 0x15;
pub const term_signal: c_int = 0x16;
pub const term_trap: c_int = 0x19;
pub const max_termination: c_int = 0x1A;
pub const max_error: c_int = 0x3F;
pub const err_bad_error_code: isize = 0x00;
pub const err_unbound_variable: isize = 0x01;
pub const err_unassigned_variable: isize = 0x02;
pub const err_inapplicable_object: isize = 0x03;
pub const err_in_system_call: isize = 0x04;
pub const err_with_argument: isize = 0x05;
pub const err_bad_frame: isize = 0x06;
pub const err_undefined_primitive: isize = 0x09;
pub const err_external_return: isize = 0x0A;
pub const err_execute_manifest_vector: isize = 0x0B;
pub const err_wrong_number_of_arguments: isize = 0x0C;
pub const err_arg_1_wrong_type: isize = 0x0D;
pub const err_arg_2_wrong_type: isize = 0x0E;
pub const err_arg_3_wrong_type: isize = 0x0F;
pub const err_arg_1_bad_range: isize = 0x10;
pub const err_arg_2_bad_range: isize = 0x11;
pub const err_arg_3_bad_range: isize = 0x12;
pub const err_macro_binding: isize = 0x13;
pub const err_fasdump_object_too_large: isize = 0x14;
pub const err_syntax_error: isize = 0x15;
pub const err_fasl_file_too_big: isize = 0x17;
pub const err_fasl_file_bad_data: isize = 0x18;
pub const err_out_of_file_handles: isize = 0x20;
pub const err_arg_4_bad_range: isize = 0x22;
pub const err_arg_5_bad_range: isize = 0x23;
pub const err_arg_6_bad_range: isize = 0x24;
pub const err_arg_7_bad_range: isize = 0x25;
pub const err_arg_8_bad_range: isize = 0x26;
pub const err_arg_9_bad_range: isize = 0x27;
pub const err_arg_10_bad_range: isize = 0x28;
pub const err_arg_4_wrong_type: isize = 0x29;
pub const err_arg_5_wrong_type: isize = 0x2A;
pub const err_arg_6_wrong_type: isize = 0x2B;
pub const err_arg_7_wrong_type: isize = 0x2C;
pub const err_arg_8_wrong_type: isize = 0x2D;
pub const err_arg_9_wrong_type: isize = 0x2E;
pub const err_arg_10_wrong_type: isize = 0x2F;
pub const err_inapplicable_continuation: isize = 0x30;
pub const err_compiled_code_error: isize = 0x31;
pub const err_floating_overflow: isize = 0x32;
pub const err_unimplemented_primitive: isize = 0x33;
pub const err_illegal_reference_trap: isize = 0x34;
pub const err_wrong_arity_primitives: isize = 0x36;
pub const err_fasdump_environment: isize = 0x38;
pub const err_fasload_band: isize = 0x39;
pub const err_fasload_compiled_mismatch: isize = 0x3A;
pub const err_stack_has_slipped: isize = 0x3D;
pub const err_cannot_recurse: isize = 0x3E;
pub const err_process_terminated: isize = 0x3F;
pub const prim_done: isize = -1;
pub const prim_do_expression: isize = -2;
pub const prim_apply: isize = -3;
pub const prim_interrupt: isize = -4;
pub const prim_no_trap_eval: isize = -5;
pub const prim_no_trap_apply: isize = -6;
pub const prim_pop_return: isize = -7;
pub const prim_apply_interrupt: isize = -9;
pub const prim_apply_error: isize = -10;
pub const prim_no_trap_pop_return: isize = -11;
pub const prim_return_to_c: isize = -12;
pub const max_return_code: usize = 0x5E;
pub const rc_end_of_computation: usize = 0x00;
pub const rc_join_stacklets: usize = 0x01;
pub const rc_internal_apply: usize = 0x03;
pub const rc_restore_history: usize = 0x05;
pub const rc_execute_assignment_finish: usize = 0x08;
pub const rc_execute_definition_finish: usize = 0x09;
pub const rc_execute_access_finish: usize = 0x0A;
pub const rc_execute_sequence_finish: usize = 0x0C;
pub const rc_conditional_decide: usize = 0x0F;
pub const rc_disjunction_decide: usize = 0x10;
pub const rc_comb_apply_function: usize = 0x12;
pub const rc_comb_save_value: usize = 0x15;
pub const rc_snap_need_thunk: usize = 0x1C;
pub const rc_reenter_compiled_code: usize = 0x1D;
pub const rc_normal_gc_done: usize = 0x20;
pub const rc_pop_from_compiled_code: usize = 0x29;
pub const rc_restore_value: usize = 0x2E;
pub const rc_restore_dont_copy_history: usize = 0x2F;
pub const rc_pop_return_error: usize = 0x40;
pub const rc_eval_error: usize = 0x41;
pub const rc_stack_marker: usize = 0x42;
pub const rc_comp_interrupt_restart: usize = 0x43;
pub const rc_restore_int_mask: usize = 0x45;
pub const rc_halt: usize = 0x46;
pub const rc_comp_lookup_trap_restart: usize = 0x53;
pub const rc_comp_assignment_trap_restart: usize = 0x54;
pub const rc_comp_op_ref_trap_restart: usize = 0x56;
pub const rc_comp_cache_ref_apply_restart: usize = 0x57;
pub const rc_comp_safe_ref_trap_restart: usize = 0x58;
pub const rc_comp_unassigned_trap_restart: usize = 0x59;
pub const rc_comp_link_caches_restart: usize = 0x5B;
pub const rc_hardware_trap: usize = 0x5C;
pub const rc_internal_apply_val: usize = 0x5D;
pub const rc_comp_error_restart: usize = 0x5E;
pub const hist_rib: usize = 0;
pub const hist_next_subproblem: usize = 1;
pub const hist_prev_subproblem: usize = 2;
pub const hist_mark: usize = 1;
pub const rib_exp: usize = 0;
pub const rib_env: usize = 1;
pub const rib_next_reduction: usize = 2;
pub const rib_mark: usize = 2;
pub const constant_space_fudge: usize = 128;
pub const default_heap_reserved: usize = 4500;
pub const stack_guard_size: usize = 4096;
pub const ephemeron_size: usize = 5;
pub const ephemeron_key: usize = 1;
pub const ephemeron_datum: usize = 2;
pub const ephemeron_list: usize = 3;
pub const ephemeron_next: usize = 4;
pub const marked_ephemeron_manifest: obj.SchemeObject = obj.makeVectorHeader(ephemeron_size - 1);
pub const unmarked_ephemeron_manifest: obj.SchemeObject = obj.makeObject(obj.tc_manifest_nm_vector, ephemeron_size - 1);
pub const cont_size: usize = 2;
pub const env_cont_size: usize = cont_size + 1;
pub const history_cont_size: usize = cont_size + 2;
pub const lexpr_primitive_arity: c_int = -1;
pub const unknown_primitive_arity: c_int = -2;
pub const syscall_accept: c_int = 0;
pub const syscall_bind: c_int = 1;
pub const syscall_chdir: c_int = 2;
pub const syscall_chmod: c_int = 3;
pub const syscall_clock_gettime: c_int = 4;
pub const syscall_close: c_int = 5;
pub const syscall_connect: c_int = 6;
pub const syscall_fcntl_GETFL: c_int = 7;
pub const syscall_fcntl_FULLFSYNC: c_int = 8;
pub const syscall_fcntl_SETFL: c_int = 9;
pub const syscall_fdatasync: c_int = 10;
pub const syscall_fstat: c_int = 12;
pub const syscall_fsync: c_int = 14;
pub const syscall_ftruncate: c_int = 16;
pub const syscall_getcwd: c_int = 17;
pub const syscall_gethostname: c_int = 18;
pub const syscall_gettimeofday: c_int = 19;
pub const syscall_gmtime: c_int = 20;
pub const syscall_ioctl_tiocsigsend: c_int = 22;
pub const syscall_kill: c_int = 23;
pub const syscall_link: c_int = 24;
pub const syscall_listen: c_int = 25;
pub const syscall_localtime: c_int = 26;
pub const syscall_lseek: c_int = 27;
pub const syscall_lstat: c_int = 28;
pub const syscall_malloc: c_int = 29;
pub const syscall_mkdir: c_int = 30;
pub const syscall_mktime: c_int = 31;
pub const syscall_ntp_adjtime: c_int = 32;
pub const syscall_open: c_int = 34;
pub const syscall_opendir: c_int = 35;
pub const syscall_pipe: c_int = 37;
pub const syscall_read: c_int = 38;
pub const syscall_readlink: c_int = 39;
pub const syscall_realloc: c_int = 40;
pub const syscall_rename: c_int = 41;
pub const syscall_rmdir: c_int = 42;
pub const syscall_select: c_int = 43;
pub const syscall_setitimer: c_int = 44;
pub const syscall_setsockopt: c_int = 46;
pub const syscall_shutdown: c_int = 47;
pub const syscall_socket: c_int = 52;
pub const syscall_stat: c_int = 53;
pub const syscall_statfs: c_int = 54;
pub const syscall_symlink: c_int = 55;
pub const syscall_sync_file_range: c_int = 56;
pub const syscall_tcdrain: c_int = 57;
pub const syscall_tcflush: c_int = 58;
pub const syscall_tcgetpgrp: c_int = 59;
pub const syscall_tcsetpgrp: c_int = 60;
pub const syscall_terminal_get_state: c_int = 61;
pub const syscall_terminal_set_state: c_int = 62;
pub const syscall_time: c_int = 63;
pub const syscall_uname: c_int = 65;
pub const syscall_unlink: c_int = 66;
pub const syscall_utime: c_int = 67;
pub const syscall_vfork: c_int = 68;
pub const syscall_write: c_int = 69;
pub const syserr_no_such_process: c_int = 31;
pub const syserr_not_enough_space: c_int = 33;

pub const PrimitiveProcedure = *const fn () callconv(.c) obj.SchemeObject;
pub const OutfChannel = outf.OutfChannel;

pub const fixobj_non_object: usize = 0x00;
pub const fixobj_system_interrupt_vector: usize = 0x01;
pub const fixobj_system_error_vector: usize = 0x02;
pub const fixobj_obarray: usize = 0x03;
pub const fixobj_types_vector: usize = 0x04;
pub const fixobj_returns_vector: usize = 0x05;
pub const fixobj_interrupt_mask_vector: usize = 0x06;
pub const fixobj_errors_vector: usize = 0x07;
pub const fixobj_identification_vector: usize = 0x08;
pub const fixobj_system_call_names: usize = 0x09;
pub const fixobj_system_call_errors: usize = 0x0A;
pub const fixobj_gc_daemon: usize = 0x0B;
pub const fixobj_trap_handler: usize = 0x0C;
pub const fixobj_edwin_auto_save: usize = 0x0D;
pub const fixobj_stepper_state: usize = 0x0E;
pub const fixobj_fixed_objects_slots: usize = 0x0F;
pub const fixobj_files_to_delete: usize = 0x10;
pub const fixobj_record_tag: usize = 0x11;
pub const fixobj_record_app_index: usize = 0x12;
pub const fixobj_dummy_history: usize = 0x13;
pub const fixobj_bignum_one: usize = 0x14;
pub const fixobj_proxied_record_types: usize = 0x15;
pub const fixobj_termination_vector: usize = 0x16;
pub const fixobj_termination_proc_vector: usize = 0x17;
pub const fixobj_gc_reclaimed: usize = 0x18;
pub const fixobj_return_frames_vector: usize = 0x1A;
pub const fixobj_reflect_code_names: usize = 0x1B;
pub const fixobj_return_codes_vector: usize = 0x1C;
pub const fixobj_error_procedure: usize = 0x1D;
pub const fixobj_cc_error_procedure: usize = 0x20;
pub const fixobj_initial_hash: usize = 0x19;
pub const fixobj_primitive_profiling_table: usize = 0x23;
pub const fixobj_arity_dispatcher_tag: usize = 0x33;
pub const fixobj_cc_bkpt_procedure: usize = 0x3F;
pub const fixobj_callback_handler: usize = 0x41;
pub const n_fixed_objects: usize = 0x45;
pub const obarray_size: usize = 32771;
pub const fasdump_record_marker_start: usize = 0x100;
pub const fasdump_record_marker_end: usize = 0x200;

pub const compiler_none_type: c_uint = 0;
pub const compiler_ia32_type: c_uint = 9;
pub const compiler_c_type: c_uint = 12;
pub const compiler_svm_type: c_uint = 13;
pub const compiler_x86_64_type: c_uint = 14;
pub const compiler_aarch64_type: c_uint = 15;

pub const fixobj_generic_trampoline_zero_p: usize = 0x24;
pub const fixobj_generic_trampoline_positive_p: usize = 0x25;
pub const fixobj_generic_trampoline_negative_p: usize = 0x26;
pub const fixobj_generic_trampoline_successor: usize = 0x27;
pub const fixobj_generic_trampoline_predecessor: usize = 0x28;
pub const fixobj_generic_trampoline_equal_p: usize = 0x29;
pub const fixobj_generic_trampoline_less_p: usize = 0x2A;
pub const fixobj_generic_trampoline_greater_p: usize = 0x2B;
pub const fixobj_generic_trampoline_add: usize = 0x2C;
pub const fixobj_generic_trampoline_subtract: usize = 0x2D;
pub const fixobj_generic_trampoline_multiply: usize = 0x2E;
pub const fixobj_generic_trampoline_divide: usize = 0x2F;
pub const fixobj_generic_trampoline_quotient: usize = 0x30;
pub const fixobj_generic_trampoline_remainder: usize = 0x31;
pub const fixobj_generic_trampoline_modulo: usize = 0x32;

pub const GcType = enum(c_int) {
    compiled_entry = -4,
    vector = -3,
    special = -2,
    undefined = -1,
    non_pointer = 0,
    cell = 1,
    pair = 2,
    triple = 3,
    quadruple = 4,
    compiled_return = 5,
};

pub const GcPtrType = enum(c_int) {
    normal = 0,
    compiled_entry = 1,
    compiled_return = 2,
    not = 3,
};

pub const ReturnFrameType = enum(c_int) {
    undefined = 0,
    with_arg = 1,
    with_arg_subproblem = 2,
    exp_env = 3,
    history = 4,
    apply = 5,
    combination_apply = 6,
    compiled_code = 7,
    compiled_code_subproblem = 8,
    compiled_address = 9,
    combination_save = 10,
    stack_marker = 11,
    hardware_trap = 12,
    return_to_interpreter = 13,
    cc_internal_apply = 14,
    cc_restore_interrupt_mask = 15,
    cc_stack_marker = 16,
    cc_bkpt = 17,
    cc_invocation = 18,
    limit = 19,
};

pub const CcEntryTypeMarker = enum(c_int) {
    procedure = 0,
    continuation = 1,
    expression = 2,
    internal_procedure = 3,
    internal_continuation = 4,
    trampoline = 5,
    return_to_interpreter = 6,
    closure = 7,
};

pub const CcEntryType = extern struct {
    marker: CcEntryTypeMarker,
    args: extern union {
        for_procedure: extern struct {
            n_required: c_uint,
            n_optional: c_uint,
            rest_p: bool,
        },
        for_continuation: extern struct {
            offset: usize,
        },
    },
};

pub const CcEntryTypeGroup = enum(usize) {
    procedure = 0,
    continuation = 1,
    expression = 2,
    internal_procedure = 3,
    unknown = 4,
};

pub const CcEntryOffset = extern struct {
    offset: usize,
    continued_p: bool,
};

pub const LinkageSectionType = enum(c_uint) {
    operator = 0,
    reference = 1,
    assignment = 2,
    global_operator = 3,
};

pub const CacheRefKind = enum(c_int) {
    lookup_cache = 0,
    assignment_cache = 1,
    operator_cache = 2,
};

pub const RelocRef = extern struct {
    old_addr: ?*anyopaque,
    new_addr: ?*anyopaque,
};

pub const trampoline_k_return_to_interpreter: u8 = 0;
pub const trampoline_k_apply: u8 = 1;
pub const trampoline_k_arity: u8 = 2;
pub const trampoline_k_entity: u8 = 3;
pub const trampoline_k_interpreted: u8 = 4;
pub const trampoline_k_lexpr_primitive: u8 = 5;
pub const trampoline_k_primitive: u8 = 6;
pub const trampoline_k_lookup: u8 = 7;
pub const trampoline_k_1_0: u8 = 8;
pub const trampoline_k_2_1: u8 = 9;
pub const trampoline_k_2_0: u8 = 10;
pub const trampoline_k_3_2: u8 = 11;
pub const trampoline_k_3_1: u8 = 12;
pub const trampoline_k_3_0: u8 = 13;
pub const trampoline_k_4_3: u8 = 14;
pub const trampoline_k_4_2: u8 = 15;
pub const trampoline_k_4_1: u8 = 16;
pub const trampoline_k_4_0: u8 = 17;
pub const trampoline_k_reflect_to_interface: u8 = 0x3A;

pub const Tchannel = c_uint;
pub const no_channel: Tchannel = std.math.maxInt(Tchannel);
pub const SelectRegistry = ?*anyopaque;
pub const select_mode_read: c_uint = 1;
pub const select_mode_write: c_uint = 2;
pub const select_mode_error: c_uint = 4;
pub const select_mode_hup: c_uint = 8;
pub const select_interrupt: c_int = -1;
pub const select_process_status_change: c_int = -2;
pub const OffT = if (builtin.os.tag == .windows) i64 else std.c.off_t;
pub const off_t_max: i64 = std.math.maxInt(i64);
pub const FdT = if (builtin.os.tag == .windows) c_int else std.c.fd_t;
pub const SiginfoT = if (builtin.os.tag == .windows) anyopaque else std.c.siginfo_t;
pub const OpenFlags = if (builtin.os.tag == .windows) c_int else std.c.O;

pub const WinTimespec = extern struct {
    sec: i64,
    nsec: i64,
};

pub const Stat = if (builtin.os.tag.isDarwin())
    std.c.Stat
else if (builtin.os.tag == .windows)
    extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        size: i64,
        atim: WinTimespec,
        mtim: WinTimespec,
        ctim: WinTimespec,

        pub fn atime(self: @This()) WinTimespec {
            return self.atim;
        }

        pub fn mtime(self: @This()) WinTimespec {
            return self.mtim;
        }

        pub fn ctime(self: @This()) WinTimespec {
            return self.ctim;
        }
    }
else if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64)
    extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        __pad1: u64,
        size: i64,
        blksize: i32,
        __pad2: i32,
        blocks: i64,
        atim: std.c.timespec,
        mtim: std.c.timespec,
        ctim: std.c.timespec,
        __glibc_reserved: [2]c_int,

        pub fn atime(self: @This()) std.c.timespec {
            return self.atim;
        }

        pub fn mtime(self: @This()) std.c.timespec {
            return self.mtim;
        }

        pub fn ctime(self: @This()) std.c.timespec {
            return self.ctim;
        }
    }
else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
    extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: c_int,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: std.c.timespec,
        mtim: std.c.timespec,
        ctim: std.c.timespec,
        __glibc_reserved: [3]isize,

        pub fn atime(self: @This()) std.c.timespec {
            return self.atim;
        }

        pub fn mtime(self: @This()) std.c.timespec {
            return self.mtim;
        }

        pub fn ctime(self: @This()) std.c.timespec {
            return self.ctim;
        }
    }
else
    @compileError("unsupported OS/arch for struct stat");

comptime {
    if (builtin.os.tag.isDarwin()) {
        std.debug.assert(@sizeOf(Stat) == 144);
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
        std.debug.assert(@sizeOf(Stat) == 128);
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        std.debug.assert(@sizeOf(Stat) == 144);
    }
}

pub const FileExistence = enum(c_uint) {
    does_exist = 0,
    doesnt_exist = 1,
    is_link = 2,
};

pub const TimeT = if (builtin.os.tag == .windows) i64 else c_long;
pub const time_t_max: i64 = std.math.maxInt(i64);
pub const ClockT = if (builtin.os.tag == .windows) i64 else if (builtin.os.tag.isDarwin()) c_ulong else c_long;
pub const TinterruptEnables = c_uint;
pub const CcT = u8;

pub const SchemeNanotime = extern struct {
    seconds: i64,
    nanoseconds: u32,
};

pub const TimeStructure = extern struct {
    year: c_uint,
    month: c_uint,
    day: c_uint,
    hour: c_uint,
    minute: c_uint,
    second: c_uint,
    day_of_week: c_uint,
    daylight_savings_time: c_int,
    time_zone: c_int,
};

pub const Tprocess = c_uint;
pub const no_process: Tprocess = std.math.maxInt(Tprocess);
pub const PidT = if (builtin.os.tag == .windows) u32 else std.c.pid_t;

pub const Process = extern struct {
    id: PidT,
    tick: isize,
    sync_tick: isize,
    raw_reason: c_ushort,
    reason: c_ushort,
    raw_status: ProcessStatus,
    status: ProcessStatus,
    jc_status: ProcessJcStatus,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Process) == 40);
        std.debug.assert(@offsetOf(Process, "tick") == 8);
        std.debug.assert(@offsetOf(Process, "sync_tick") == 16);
        std.debug.assert(@offsetOf(Process, "raw_reason") == 24);
        std.debug.assert(@offsetOf(Process, "reason") == 26);
        std.debug.assert(@offsetOf(Process, "raw_status") == 28);
        std.debug.assert(@offsetOf(Process, "status") == 32);
        std.debug.assert(@offsetOf(Process, "jc_status") == 36);
    }
}

pub const ProcessStatus = enum(c_uint) {
    free = 0,
    allocated = 1,
    running = 2,
    stopped = 3,
    exited = 4,
    signalled = 5,
};

pub const ProcessJcStatus = enum(c_uint) {
    no_ctty = 0,
    unrelated = 1,
    no_jc = 2,
    jc = 3,
};

pub const ProcessCttyType = enum(c_uint) {
    none = 0,
    inherit_bg = 1,
    inherit_fg = 2,
    explicit = 3,
};

pub const ProcessChannelType = enum(c_uint) {
    none = 0,
    inherit = 1,
    ctty = 2,
    explicit = 3,
};

pub const FileType = enum(c_int) {
    nonexistent = -1,
    regular = 0,
    directory = 1,
    unix_symbolic_link = 2,
    unix_character_device = 3,
    unix_block_device = 4,
    unix_fifo = 5,
    unix_stream_socket = 6,
    unused_1 = 7,
    win32_named_pipe = 8,
    unknown = 0xFFFF,
};

pub const ChannelType = enum(c_uint) {
    unknown = 0,
    file = 1,
    unix_pipe = 2,
    unix_fifo = 3,
    terminal = 4,
    unix_pty_master = 5,
    unix_server_socket = 6,
    unix_stream_socket = 7,
    tcp_stream_socket = 8,
    tcp_server_socket = 9,
    directory = 10,
    unix_character_device = 11,
    unix_block_device = 12,
    unused_1 = 13,
    unused_2 = 14,
    unused_3 = 15,
    win32_anonymous_pipe = 16,
    win32_named_pipe = 17,
};

pub const mode_reg: c_uint = 0o666;
pub const mode_dir: c_uint = 0o777;

pub const TttyState = if (builtin.os.tag == .windows)
    extern struct {
        mode: u32,
    }
else
    extern struct {
        tio: std.c.termios,
    };

pub const Channel = extern struct {
    descriptor: c_int,
    type: ChannelType,
    flags: packed struct(c_uint) {
        internal: u1 = 0,
        nonblocking: u1 = 0,
        _pad: u30 = 0,
    },
};

comptime {
    std.debug.assert(@sizeOf(Channel) == 12);
    std.debug.assert(@offsetOf(Channel, "descriptor") == 0);
    std.debug.assert(@offsetOf(Channel, "type") == 4);
    std.debug.assert(@offsetOf(Channel, "flags") == 8);
}

pub inline fn cFstat(fd: FdT, buf: *Stat) c_int {
    if (comptime builtin.os.tag == .windows) {
        @compileError("POSIX-only cFstat called on Windows");
    }
    if (builtin.os.tag == .linux) {
        const LinuxLibc = struct {
            extern "c" fn fstat(fd: c_int, buf: *Stat) callconv(.c) c_int;
        };
        return LinuxLibc.fstat(fd, buf);
    }
    return std.c.fstat(fd, buf);
}

pub inline fn cStat(path: [*:0]const u8, buf: *Stat) c_int {
    if (comptime builtin.os.tag == .windows) {
        @compileError("POSIX-only cStat called on Windows");
    }
    if (builtin.os.tag == .linux) {
        const LinuxLibc = struct {
            extern "c" fn stat(path: [*:0]const u8, buf: *Stat) callconv(.c) c_int;
        };
        return LinuxLibc.stat(path, buf);
    }
    return std.c.stat(path, buf);
}

pub inline fn cLstat(path: [*:0]const u8, buf: *Stat) c_int {
    if (comptime builtin.os.tag == .windows) {
        @compileError("POSIX-only cLstat called on Windows");
    }
    if (builtin.os.tag.isDarwin() and builtin.cpu.arch == .x86_64) {
        const DarwinLibc = struct {
            extern "c" fn @"lstat$INODE64"(path: [*:0]const u8, buf: *Stat) callconv(.c) c_int;
        };
        return DarwinLibc.@"lstat$INODE64"(path, buf);
    }
    const PosixLibc = struct {
        extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) callconv(.c) c_int;
    };
    return PosixLibc.lstat(path, buf);
}

pub fn makeChannel(fd: c_int, ch_type: ChannelType) Tchannel {
    const ch = channel_allocate();
    channel_table[ch] = .{
        .descriptor = fd,
        .type = ch_type,
        .flags = .{},
    };
    return ch;
}

pub inline fn openFdRetry(path: [*:0]const u8, oflags: OpenFlags, mode: c_uint) c_int {
    if (comptime builtin.os.tag == .windows) {
        @compileError("POSIX-only openFdRetry called on Windows");
    }
    var fd = std.c.open(path, oflags, mode);
    while (fd < 0) {
        UX_prim_check_fd_errno(syscall_open);
        fd = std.c.open(path, oflags, mode);
    }
    UX_out_of_files_p = false;
    return fd;
}

pub extern var ephemeron_array: obj.SchemeObject;
pub extern var ephemeron_count: usize;

pub extern var Registers: [regblock_length]obj.SchemeObject;
pub extern var Free: [*]obj.SchemeObject;
pub extern var Free_primitive: ?[*]obj.SchemeObject;
pub extern var heap_alloc_limit: [*]obj.SchemeObject;
pub extern var heap_start: [*]obj.SchemeObject;
pub extern var heap_end: [*]obj.SchemeObject;
pub extern var stack_pointer: [*]obj.SchemeObject;
pub extern var stack_guard: [*]obj.SchemeObject;
pub extern var stack_start: [*]obj.SchemeObject;
pub extern var stack_end: [*]obj.SchemeObject;
pub extern var memory_block_start: [*]obj.SchemeObject;
pub extern var fixed_objects: obj.SchemeObject;
pub extern var heap_reserved: usize;
pub extern var gc_space_needed: usize;
pub extern var critical_section_name: ?[*:0]const u8;
pub extern var current_gc_table: ?*anyopaque;
pub extern var history_register: [*]obj.SchemeObject;
pub extern var last_return_code: ?[*]obj.SchemeObject;
pub extern var prev_restore_history_offset: usize;
pub extern var trapping: bool;
pub extern var constant_start: [*]obj.SchemeObject;
pub extern var constant_alloc_next: [*]obj.SchemeObject;
pub extern var constant_end: [*]obj.SchemeObject;
pub extern var compiler_processor_type: c_uint;
pub extern var OS_Name: [*:0]const u8;
pub extern var OS_Variant: [*:0]const u8;
pub extern var scheme_program_name: [*:0]const u8;
pub extern var option_saved_argc: c_int;
pub extern var option_saved_argv: [*]?[*:0]const u8;
pub extern var option_unused_argc: c_int;
pub extern var option_unused_argv: ?[*]?[*:0]const u8;
pub extern var option_batch_mode: bool;
pub extern var option_show_help: bool;
pub extern var option_show_version: bool;
pub extern var option_library_path: [*]?[*:0]const u8;
pub extern var option_band_file: ?[*:0]const u8;
pub extern var option_fasl_file: ?[*:0]const u8;
pub extern var option_heap_size: usize;
pub extern var option_constant_size: usize;
pub extern var option_stack_size: usize;
pub extern var option_code_size: usize;
pub extern var MAX_PRIMITIVE: usize;
pub extern var Primitive_Arity_Table: ?[*]c_int;
pub extern var Primitive_Name_Table: ?[*]?[*:0]const u8;
pub extern var Primitive_Documentation_Table: ?[*]?[*:0]const u8;

pub extern "c" fn error_wrong_type_arg(c_int) noreturn;
pub extern "c" fn error_bad_range_arg(c_int) noreturn;

pub const fflush = outf.fflush;
pub const cStdout = outf.cStdout;
pub const cStderr = outf.cStderr;
pub extern "c" fn error_external_return() noreturn;
pub extern "c" fn signal_error_from_primitive(isize) noreturn;
pub extern "c" fn signal_interrupt_from_primitive() noreturn;
pub extern "c" fn Microcode_Termination(c_int) noreturn;
pub extern "c" fn termination_init_error() noreturn;
pub extern "c" fn error_in_system_call(c_int, c_int) noreturn;
pub extern "c" fn OS_malloc(usize) ?*anyopaque;
pub extern "c" fn OS_realloc(?*anyopaque, usize) ?*anyopaque;
pub extern "c" fn OS_free(?*anyopaque) void;
pub extern "c" fn get_object_address(obj.SchemeObject) ?[*]obj.SchemeObject;
pub extern "c" fn OS_tty_map_interrupt_char(u8) u8;
pub extern "c" fn debug_stack_trace(OutfChannel) void;
pub extern "c" fn debug_print_expr(obj.SchemeObject, [*:0]const u8) void;
pub extern "c" fn code_address_p(?*const anyopaque) bool;
pub extern "c" fn record_primitive_entry(obj.SchemeObject) void;
pub extern "c" fn gc_type_code(c_uint) c_int;
pub extern "c" fn gc_ptr_type(obj.SchemeObject) c_int;
pub extern "c" fn hashable_object_p(obj.SchemeObject) bool;
pub extern "c" fn hash_object(obj.SchemeObject) u32;
pub extern "c" fn combine_hashes(u32, u32) u32;
pub extern "c" fn OS_channel_close_noerror(c_uint) void;
pub extern var OS_channel_table_size: Tchannel;
pub extern var channel_table: [*]Channel;
pub extern var UX_out_of_files_p: bool;
pub extern var OS_have_select_p: c_int;
pub extern "c" fn channel_allocate() Tchannel;
pub extern "c" fn terminal_open(Tchannel) void;
pub extern "c" fn UX_prim_check_fd_errno(c_int) void;
pub extern "c" fn UX_SC_CLK_TCK() ClockT;
pub extern "c" fn OS_open_fd(c_int) Tchannel;
pub extern "c" fn OS_channel_open_p(Tchannel) c_int;
pub extern "c" fn OS_channel_close(Tchannel) void;
pub extern "c" fn OS_channel_close_on_abort(Tchannel) void;
pub extern "c" fn OS_channel_synchronize(Tchannel) void;
pub extern "c" fn OS_channel_type(Tchannel) c_uint;
pub extern "c" fn OS_channel_read(Tchannel, ?*anyopaque, usize) isize;
pub extern "c" fn OS_channel_write(Tchannel, ?*const anyopaque, usize) isize;
pub extern "c" fn OS_make_pipe(*Tchannel, *Tchannel) void;
pub extern "c" fn OS_channel_nonblocking_p(Tchannel) c_int;
pub extern "c" fn OS_channel_nonblocking(Tchannel) void;
pub extern "c" fn OS_channel_blocking(Tchannel) void;
pub extern "c" fn OS_allocate_select_registry() SelectRegistry;
pub extern "c" fn OS_deallocate_select_registry(SelectRegistry) void;
pub extern "c" fn OS_add_to_select_registry(SelectRegistry, c_int, c_uint) void;
pub extern "c" fn OS_remove_from_select_registry(SelectRegistry, c_int, c_uint) void;
pub extern "c" fn OS_select_registry_length(SelectRegistry) c_uint;
pub extern "c" fn OS_select_registry_result(SelectRegistry, c_uint, *c_int, *c_uint) void;
pub extern "c" fn OS_test_select_registry(SelectRegistry, c_int) c_int;
pub extern "c" fn OS_test_select_descriptor(c_int, c_int, c_uint) c_int;
pub extern "c" fn OS_pause(bool, bool) c_int;
pub extern "c" fn OS_process_any_status_change() c_int;
pub extern "c" fn arg_to_channel(obj.SchemeObject, c_int) Tchannel;
pub extern "c" fn arg_channel(c_int) Tchannel;
pub extern "c" fn OS_open_input_file([*:0]const u8) Tchannel;
pub extern "c" fn OS_open_output_file([*:0]const u8) Tchannel;
pub extern "c" fn OS_open_exclusive_output_file([*:0]const u8) Tchannel;
pub extern "c" fn OS_open_io_file([*:0]const u8) Tchannel;
pub extern "c" fn OS_open_append_file([*:0]const u8) Tchannel;
pub extern "c" fn OS_file_length(Tchannel) OffT;
pub extern "c" fn OS_file_position(Tchannel) OffT;
pub extern "c" fn OS_file_set_position(Tchannel, OffT) void;
pub extern "c" fn OS_file_truncate(Tchannel, OffT) void;
pub extern "c" fn OS_file_existence_test([*:0]const u8) c_uint;
pub extern "c" fn OS_file_existence_test_direct([*:0]const u8) c_uint;
pub extern "c" fn OS_file_type_direct([*:0]const u8) c_int;
pub extern "c" fn OS_file_type_indirect([*:0]const u8) c_int;
pub extern "c" fn OS_file_directory_p([*:0]const u8) c_int;
pub extern "c" fn OS_file_soft_link_p([*:0]const u8) ?[*:0]const u8;
pub extern "c" fn OS_file_rename([*:0]const u8, [*:0]const u8) void;
pub extern "c" fn OS_file_link_hard([*:0]const u8, [*:0]const u8) void;
pub extern "c" fn OS_file_link_soft([*:0]const u8, [*:0]const u8) void;
pub extern "c" fn OS_directory_make([*:0]const u8) void;
pub extern "c" fn OS_directory_delete([*:0]const u8) void;
pub extern "c" fn OS_file_touch([*:0]const u8) c_int;
pub extern "c" fn OS_directory_open([*:0]const u8) c_uint;
pub extern "c" fn OS_directory_valid_p(c_uint) c_int;
pub extern "c" fn OS_directory_close(c_uint) void;
pub extern "c" fn OS_directory_read(c_uint) ?[*:0]const u8;
pub extern "c" fn OS_directory_read_matching(c_uint, [*:0]const u8) ?[*:0]const u8;
pub extern "c" fn OS_channel_copy(OffT, Tchannel, Tchannel) c_int;
pub extern "c" fn OS_file_copy([*:0]const u8, [*:0]const u8) void;
pub extern "c" fn OS_nanotime_since_utc_epoch(*SchemeNanotime) void;
pub extern "c" fn OS_monotonic_nanotime(*SchemeNanotime) void;
pub extern "c" fn OS_encoded_time() TimeT;
pub extern "c" fn OS_decode_time(TimeT, *TimeStructure) void;
pub extern "c" fn OS_decode_utc(TimeT, *TimeStructure) void;
pub extern "c" fn OS_encode_time(*TimeStructure) TimeT;
pub extern "c" fn OS_process_clock() f64;
pub extern "c" fn OS_real_time_clock() f64;
pub extern "c" fn OS_process_timer_set(ClockT, ClockT) void;
pub extern "c" fn OS_process_timer_clear() void;
pub extern "c" fn OS_profile_timer_set(ClockT, ClockT) void;
pub extern "c" fn OS_profile_timer_clear() void;
pub extern "c" fn OS_real_timer_set(ClockT, ClockT) void;
pub extern "c" fn OS_real_timer_clear() void;
pub extern "c" fn OS_set_working_dir_pathname([*:0]const u8) void;
pub extern "c" fn OS_current_jiffy() ClockT;
pub extern "c" fn OS_jiffies_per_second() ClockT;
pub extern "c" fn OS_error_code_to_message(c_uint) ?[*:0]const u8;
pub extern "c" fn OS_tty_input_channel() Tchannel;
pub extern "c" fn OS_tty_output_channel() Tchannel;
pub extern "c" fn OS_tty_error_channel() Tchannel;
pub extern "c" fn OS_tty_command_beep() [*:0]const u8;
pub extern "c" fn OS_tty_command_clear() [*:0]const u8;
pub extern "c" fn OS_tty_next_interrupt_char() CcT;
pub extern "c" fn UX_PC_VDISABLE(c_int) CcT;
pub extern "c" fn UX_terminal_control_ok(c_int) c_int;
pub extern "c" fn OS_signal_quit_handler() c_uint;
pub extern "c" fn OS_signal_int_handler() c_uint;
pub extern "c" fn OS_signal_tstp_handler() c_uint;
pub extern "c" fn OS_signal_set_interrupt_handlers(c_uint, c_uint, c_uint) void;
pub extern "c" fn initialize_interruptable_extent() void;
pub extern "c" fn UX_initialize_ctty(c_int) void;
pub extern "c" fn UX_initialize_channels() void;
pub extern "c" fn UX_initialize_terminals() void;
pub extern "c" fn UX_initialize_environment() void;
pub extern "c" fn UX_initialize_tty() void;
pub extern "c" fn UX_initialize_userio() void;
pub extern "c" fn UX_initialize_signals() void;
pub extern "c" fn UX_initialize_processes() void;
pub extern "c" fn UX_initialize_trap_recovery() void;
pub extern "c" fn UX_initialize_directory_reader() void;
pub extern "c" fn UX_reset_channels() void;
pub extern "c" fn UX_reset_terminals() void;
pub extern "c" fn UX_reset_processes() void;
pub extern "c" fn OS_ctty_quit_char() CcT;
pub extern "c" fn UX_ctty_save_external_state() void;
pub extern "c" fn UX_ctty_save_internal_state() void;
pub extern "c" fn UX_ctty_restore_internal_state() void;
pub extern "c" fn UX_ctty_restore_external_state() void;
pub extern "c" fn OS_ctty_interrupt_control() c_int;
pub extern "c" fn char_description(u8, c_int) [*:0]const u8;
pub extern "c" fn userio_confirm([*:0]const u8) c_int;
pub extern "c" fn UX_dump_core() void;
pub extern "c" fn OS_ctty_get_interrupt_enables(*TinterruptEnables) void;
pub extern "c" fn OS_ctty_set_interrupt_enables(*TinterruptEnables) void;
pub extern "c" fn OS_ctty_num_int_chars() c_uint;
pub extern "c" fn OS_ctty_get_int_chars() [*]CcT;
pub extern "c" fn OS_ctty_get_int_char_handlers() [*]CcT;
pub extern "c" fn OS_ctty_set_int_chars([*]CcT) void;
pub extern "c" fn OS_ctty_set_int_char_handlers([*]CcT) void;
pub extern "c" fn arg_terminal(c_int) Tchannel;
pub extern "c" fn OS_terminal_get_ispeed(Tchannel) c_uint;
pub extern "c" fn OS_terminal_get_ospeed(Tchannel) c_uint;
pub extern "c" fn OS_terminal_set_ispeed(Tchannel, c_uint) void;
pub extern "c" fn OS_terminal_set_ospeed(Tchannel, c_uint) void;
pub extern "c" fn arg_baud_index(c_uint) c_uint;
pub extern "c" fn OS_baud_index_to_rate(c_uint) c_uint;
pub extern "c" fn OS_baud_rate_to_index(c_uint) c_int;
pub extern "c" fn OS_terminal_state_size() c_uint;
pub extern "c" fn OS_terminal_get_state(Tchannel, ?*anyopaque) void;
pub extern "c" fn OS_terminal_set_state(Tchannel, ?*anyopaque) void;
pub extern "c" fn OS_terminal_cooked_output_p(Tchannel) c_int;
pub extern "c" fn OS_terminal_raw_output(Tchannel) void;
pub extern "c" fn OS_terminal_cooked_output(Tchannel) void;
pub extern "c" fn OS_terminal_buffered_p(Tchannel) c_int;
pub extern "c" fn OS_terminal_buffered(Tchannel) void;
pub extern "c" fn OS_terminal_nonbuffered(Tchannel) void;
pub extern "c" fn OS_terminal_flush_input(Tchannel) void;
pub extern "c" fn OS_terminal_flush_output(Tchannel) void;
pub extern "c" fn OS_terminal_drain_output(Tchannel) void;
pub extern "c" fn OS_job_control_p() c_int;
pub extern "c" fn OS_have_ptys_p() c_int;
pub extern "c" fn OS_open_pty_master(*Tchannel, *[*:0]const u8) [*:0]const u8;
pub extern "c" fn OS_pty_master_send_signal(Tchannel, c_int) void;
pub extern "c" fn OS_pty_master_kill(Tchannel) void;
pub extern "c" fn OS_pty_master_stop(Tchannel) void;
pub extern "c" fn OS_pty_master_continue(Tchannel) void;
pub extern "c" fn OS_pty_master_interrupt(Tchannel) void;
pub extern "c" fn OS_pty_master_quit(Tchannel) void;
pub extern "c" fn OS_pty_master_hangup(Tchannel) void;
pub extern var OS_process_table_size: Tprocess;
pub extern "c" fn OS_make_subprocess(
    [*:0]const u8,
    [*]const ?[*:0]const u8,
    ?[*]const ?[*:0]const u8,
    ?[*:0]const u8,
    ProcessCttyType,
    ?[*:0]u8,
    ProcessChannelType,
    Tchannel,
    ProcessChannelType,
    Tchannel,
    ProcessChannelType,
    Tchannel,
) Tprocess;
pub extern "c" fn OS_process_deallocate(Tprocess) void;
pub extern "c" fn OS_process_valid_p(Tprocess) c_int;
pub extern "c" fn OS_process_continuable_p(Tprocess) c_int;
pub extern "c" fn OS_process_foregroundable_p(Tprocess) c_int;
pub extern "c" fn OS_process_id(Tprocess) PidT;
pub extern "c" fn OS_process_jc_status(Tprocess) c_uint;
pub extern "c" fn OS_process_status_sync(Tprocess) c_int;
pub extern "c" fn OS_process_status_sync_all() c_int;
pub extern "c" fn OS_process_status(Tprocess) c_uint;
pub extern "c" fn OS_process_reason(Tprocess) c_ushort;
pub extern "c" fn OS_process_send_signal(Tprocess, c_int) void;
pub extern "c" fn OS_process_kill(Tprocess) void;
pub extern "c" fn OS_process_stop(Tprocess) void;
pub extern "c" fn OS_process_interrupt(Tprocess) void;
pub extern "c" fn OS_process_quit(Tprocess) void;
pub extern "c" fn OS_process_hangup(Tprocess) void;
pub extern "c" fn OS_process_continue_background(Tprocess) void;
pub extern "c" fn OS_process_continue_foreground(Tprocess) void;
pub extern "c" fn OS_process_wait(Tprocess) void;
pub extern "c" fn OS_ctty_fd() c_int;
pub extern "c" fn OS_save_internal_state() void;
pub extern "c" fn OS_restore_internal_state() void;
pub extern "c" fn OS_save_external_state() void;
pub extern "c" fn OS_restore_external_state() void;
pub extern "c" fn UX_initialize_child_signals() void;
pub extern "c" fn stop_signal_default(c_int) void;
pub extern var stop_signal_hook: ?*const fn (c_int) callconv(.c) void;
pub extern var subprocess_death_hook: ?*const fn (PidT, *c_int) callconv(.c) void;
pub extern "c" fn UX_channel_descriptor(Tchannel) c_int;
pub extern "c" fn OS_open_tcp_stream_socket(?*anyopaque, c_uint) Tchannel;
pub extern "c" fn OS_shutdown_socket(Tchannel, usize) void;
pub extern "c" fn OS_get_service_by_name([*:0]const u8, [*:0]const u8) c_int;
pub extern "c" fn OS_get_service_by_number(usize) usize;
pub extern "c" fn OS_host_address_length() c_uint;
pub extern "c" fn OS_get_host_by_name([*:0]const u8) ?[*]?[*]u8;
pub extern "c" fn OS_get_host_name() ?[*:0]const u8;
pub extern "c" fn OS_canonical_host_name([*:0]const u8) ?[*:0]const u8;
pub extern "c" fn OS_get_host_by_address([*:0]const u8) ?[*:0]const u8;
pub extern "c" fn OS_host_address_any(?*anyopaque) void;
pub extern "c" fn OS_host_address_loopback(?*anyopaque) void;
pub extern "c" fn OS_open_unix_stream_socket([*:0]const u8, c_int) Tchannel;
pub extern "c" fn OS_create_unix_server_socket([*:0]const u8, c_int) Tchannel;
pub extern "c" fn OS_unix_server_connection_accept(Tchannel) Tchannel;
pub extern "c" fn OS_create_tcp_server_socket() Tchannel;
pub extern "c" fn OS_bind_tcp_server_socket(Tchannel, ?*anyopaque, c_uint) void;
pub extern "c" fn OS_listen_tcp_server_socket(Tchannel) void;
pub extern "c" fn OS_tcp_server_connection_accept(Tchannel, ?*anyopaque, ?*c_uint) Tchannel;
pub extern "c" fn UX_prim_check_errno(c_int) void;
pub extern "c" fn OS_current_user_name() [*:0]const u8;
pub extern "c" fn OS_current_user_home_directory() [*:0]const u8;
pub extern "c" fn find_ccblock(usize) obj.SchemeObject;
pub extern "c" fn UX_read_fd_status(c_int, *Stat) void;
pub extern "c" fn UX_read_file_status([*:0]const u8, *Stat) c_int;
pub extern "c" fn UX_read_file_status_indirect([*:0]const u8, *Stat) c_int;
pub extern "c" fn UX_file_system_type([*:0]const u8) ?[*:0]const u8;
pub extern "c" fn find_primitive(obj.SchemeObject, bool, bool, c_int) obj.SchemeObject;
pub extern "c" fn termination_normal(c_int) noreturn;
pub extern "c" fn termination_eof() noreturn;
pub extern "c" fn UX_terminal_get_state(c_int, *TttyState) c_int;
pub extern "c" fn UX_terminal_set_state(c_int, *const TttyState) c_int;
pub extern "c" fn terminal_state_raw(*TttyState, c_int) void;
pub extern "c" fn OS_restartable_exit() void;
pub extern "c" fn OS_under_emacs_p() c_int;
pub extern "c" fn OS_set_trap_state(c_int) c_int;
pub extern "c" fn OS_tty_x_size() c_uint;
pub extern "c" fn OS_tty_y_size() c_uint;
pub extern "c" fn OS_syscall_names(*usize, *[*]?[*:0]const u8) void;
pub extern "c" fn OS_syserr_names(*usize, *[*]?[*:0]const u8) void;
pub extern "c" fn initialize_history() obj.SchemeObject;
pub extern "c" fn initialize_interrupt_handler_vector() obj.SchemeObject;
pub extern "c" fn initialize_interrupt_mask_vector() obj.SchemeObject;
pub extern "c" fn make_reflect_code_table() obj.SchemeObject;
pub extern "c" fn cc_block_linkage_info(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn return_address_p(obj.SchemeObject) bool;
pub extern "c" fn cpoint_next_frame(obj.SchemeObject, usize) usize;
pub extern "c" fn return_frame_type([*]obj.SchemeObject) c_int;
pub extern "c" fn return_code_frame_type(obj.SchemeObject) c_int;

pub extern var return_to_interpreter: obj.SchemeObject;
pub extern var reflect_to_interface: obj.SchemeObject;
pub extern "c" fn cc_return_address_p(obj.SchemeObject) bool;
pub extern "c" fn reflect_to_interface_frame_type([*]obj.SchemeObject) c_int;
pub extern "c" fn cpoint_compiled_code_next(obj.SchemeObject, usize) usize;
pub extern "c" fn cpoint_compiled_address_next(obj.SchemeObject, usize) usize;
pub extern "c" fn cpoint_reflect_to_interface_next(obj.SchemeObject, usize) usize;

pub extern "c" fn open_tospace([*]obj.SchemeObject) void;
pub extern "c" fn initialize_weak_chain() void;
pub extern "c" fn get_newspace_ptr() [*]obj.SchemeObject;
pub extern "c" fn add_to_tospace(obj.SchemeObject) void;
pub extern "c" fn std_gc_table() ?*anyopaque;
pub extern "c" fn gc_scan_tospace([*]obj.SchemeObject, ?[*]obj.SchemeObject) void;
pub extern "c" fn increment_tospace_ptr(usize) void;
pub extern "c" fn std_gc_pt1() void;
pub extern "c" fn std_gc_pt2() void;
pub extern "c" fn resize_tospace(usize) void;

pub extern "c" fn lookup_variable(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn safe_lookup_variable(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn assign_variable(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn define_variable(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject) isize;
pub extern "c" fn variable_unassigned_p(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn variable_unbound_p(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn variable_unreferenceable_p(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn link_variables(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject, obj.SchemeObject) isize;
pub extern "c" fn unbind_variable(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;

pub extern "c" fn make_dummy_history() [*]obj.SchemeObject;
pub extern "c" fn save_history(usize) void;
pub extern "c" fn stop_history() void;
pub extern "c" fn preserve_interrupt_mask() void;
pub extern "c" fn back_out_of_primitive() void;
pub extern "c" fn apply_compiled_from_primitive(usize, obj.SchemeObject) void;
pub extern "c" fn compiled_with_stack_marker(obj.SchemeObject) void;
pub extern "c" fn compiled_with_interrupt_mask(usize, obj.SchemeObject, usize) void;
pub extern "c" fn termination_no_error_handler() noreturn;
pub extern "c" fn OS_error_code_to_syserr(c_int) c_int;
pub extern "c" fn guarantee_interp_return() void;
pub extern "c" fn update_weak_pointers() void;
pub extern "c" fn read_cc_entry_type(*CcEntryType, ?*anyopaque) bool;
pub extern "c" fn record_applicator(obj.SchemeObject) obj.SchemeObject;

pub const GcTospaceAllocator = *const fn (usize, *?[*]obj.SchemeObject, *?[*]obj.SchemeObject) callconv(.c) void;
pub const GcAbortHandler = *const fn () callconv(.c) noreturn;
pub const GcWalkProc = *const fn ([*]obj.SchemeObject, [*]obj.SchemeObject, ?*anyopaque) callconv(.c) bool;
pub const GcHandler = *const fn ([*]obj.SchemeObject, obj.SchemeObject) callconv(.c) [*]obj.SchemeObject;
pub const GcTupleHandler = *const fn (obj.SchemeObject, c_uint) callconv(.c) obj.SchemeObject;
pub const GcVectorHandler = *const fn (obj.SchemeObject, bool) callconv(.c) obj.SchemeObject;
pub const GcObjectHandler = *const fn (obj.SchemeObject) callconv(.c) obj.SchemeObject;
pub const GcPrecheckFrom = *const fn ([*]obj.SchemeObject) callconv(.c) ?[*]obj.SchemeObject;
pub const GcTransportWords = *const fn ([*]obj.SchemeObject, usize, bool) callconv(.c) [*]obj.SchemeObject;
pub const GcIgnoreObjectP = *const fn (obj.SchemeObject) callconv(.c) bool;
pub const GcRawAddressToObject = *const fn (c_uint, [*]obj.SchemeObject) callconv(.c) obj.SchemeObject;
pub const GcObjectToRawAddress = *const fn (obj.SchemeObject) callconv(.c) [*]obj.SchemeObject;
pub const GcRawAddressToCcEntry = *const fn (?*anyopaque) callconv(.c) obj.SchemeObject;
pub const GcCcEntryToRawAddress = *const fn (obj.SchemeObject) callconv(.c) ?*anyopaque;

pub const GcTable = extern struct {
    handlers: [64]?GcHandler,
    tuple_handler: ?GcTupleHandler,
    vector_handler: ?GcVectorHandler,
    cc_entry_handler: ?GcObjectHandler,
    cc_return_handler: ?GcObjectHandler,
    precheck_from: ?GcPrecheckFrom,
    transport_words: ?GcTransportWords,
    ignore_object_p: ?GcIgnoreObjectP,
    raw_address_to_object: ?GcRawAddressToObject,
    object_to_raw_address: ?GcObjectToRawAddress,
    raw_address_to_cc_entry: ?GcRawAddressToCcEntry,
    cc_entry_to_raw_address: ?GcCcEntryToRawAddress,
};

comptime {
    std.debug.assert(@sizeOf(GcTable) == 75 * @sizeOf(usize));
}

pub extern var compiler_utilities: obj.SchemeObject;
pub extern var compiler_interface_version: c_uint;
pub extern "c" fn OS_malloc_init(usize) ?*anyopaque;
pub extern "c" fn initialize_gc(usize, *?[*]obj.SchemeObject, *?[*]obj.SchemeObject, GcTospaceAllocator, GcAbortHandler) void;
pub extern "c" fn save_tospace(GcWalkProc, ?*anyopaque) bool;
pub extern "c" fn tospace_to_newspace(?*anyopaque) ?*anyopaque;
pub extern "c" fn gc_scan_oldspace([*]obj.SchemeObject, [*]obj.SchemeObject) void;
pub extern "c" fn gc_drain_tospace_and_code_arena([*]obj.SchemeObject) void;
pub extern "c" fn aarch64_flush_i_cache() void;
pub extern "c" fn aarch64_flush_i_cache_region([*]obj.SchemeObject, usize) void;
pub extern "c" fn debug_verify_heap() bool;
pub extern "c" fn std_gc_death([*:0]const u8) noreturn;
pub extern "c" fn initialize_gc_object_references() void;
pub extern "c" fn finalize_gc_object_references() void;
pub extern "c" fn collect_gc_object_references(obj.SchemeObject, obj.SchemeObject) void;
pub extern "c" fn OS_free_pages(?*anyopaque, ?*anyopaque) void;
pub extern "c" fn OS_expect_sequential_access(?*const anyopaque, ?*const anyopaque) void;
pub extern "c" fn OS_expect_normal_access(?*const anyopaque, ?*const anyopaque) void;
pub extern "c" fn code_arena_max_end() ?[*]obj.SchemeObject;
pub extern "c" fn code_arena_mark_begin() void;
pub extern "c" fn code_arena_mark_block(?[*]obj.SchemeObject) bool;
pub extern "c" fn code_arena_marked_p(?[*]const obj.SchemeObject) bool;
pub extern "c" fn code_arena_mark_stack_empty_p() bool;
pub extern "c" fn code_arena_pop_mark_stack() ?[*]obj.SchemeObject;
pub extern "c" fn code_arena_write_begin() void;
pub extern "c" fn code_arena_write_end() void;
pub extern "c" fn cc_entry_address_to_block_address(?*anyopaque) [*]obj.SchemeObject;
pub extern "c" fn cc_return_address_to_block_address(?*anyopaque) [*]obj.SchemeObject;
pub extern "c" fn linkage_section_type(obj.SchemeObject) c_uint;
pub extern "c" fn linkage_section_count(obj.SchemeObject) usize;
pub extern "c" fn read_uuo_target([*]obj.SchemeObject) ?*anyopaque;
pub extern "c" fn write_uuo_target(?*anyopaque, [*]obj.SchemeObject) void;
pub extern "c" fn start_closure_relocation([*]obj.SchemeObject, *RelocRef) void;
pub extern "c" fn compiled_closure_start([*]obj.SchemeObject) ?*anyopaque;
pub extern "c" fn compiled_closure_count([*]obj.SchemeObject) usize;
pub extern "c" fn compiled_closure_next(?*anyopaque) ?*anyopaque;
pub extern "c" fn read_compiled_closure_target(?*anyopaque, ?*RelocRef) ?*anyopaque;
pub extern "c" fn write_compiled_closure_target(?*anyopaque, ?*anyopaque) void;
pub extern "c" fn skip_compiled_closure_padding(?*anyopaque) [*]obj.SchemeObject;
pub extern "c" fn decode_old_style_format_word(*CcEntryType, u16) bool;
pub extern "c" fn encode_old_style_format_word(*CcEntryType, *u16) bool;
pub extern "c" fn make_compiled_procedure_type(*CcEntryType, c_uint, c_uint, bool) void;
pub extern "c" fn make_compiled_continuation_type(*CcEntryType, usize) void;
pub extern "c" fn make_cc_entry_type(*CcEntryType, CcEntryTypeMarker) void;
pub extern "c" fn declare_builtin(usize, [*:0]const u8) void;
pub extern "c" fn jit_force_execute_mode() void;
pub extern "c" fn jit_flush_icache(?*anyopaque, usize) void;
pub extern "c" fn code_arena_flush_icache() void;
pub extern "c" fn init_exit_scheme() void;
pub extern "c" fn read_command_line_options(c_int, [*]?[*:0]const u8) void;
pub extern "c" fn compiler_initialize(bool) void;
pub extern "c" fn compiler_reset(obj.SchemeObject) void;
pub extern "c" fn abort_to_interpreter_argument() c_int;
pub extern "c" fn initialize_gc_table(*GcTable, bool) void;
pub extern "c" fn gc_handle_non_pointer([*]obj.SchemeObject, obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn gc_handle_pair([*]obj.SchemeObject, obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn gc_handle_unaligned_vector([*]obj.SchemeObject, obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn gc_handle_manifest_closure([*]obj.SchemeObject, obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn gc_handle_linkage_section([*]obj.SchemeObject, obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn gc_handle_broken_heart([*]obj.SchemeObject, obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn gc_transport_words([*]obj.SchemeObject, usize, bool) [*]obj.SchemeObject;
pub extern "c" fn gc_no_cc_support() noreturn;
pub extern "c" fn tospace_available_p(usize) bool;
pub extern "c" fn read_tospace([*]obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn write_tospace([*]obj.SchemeObject, obj.SchemeObject) void;
pub extern "c" fn newspace_to_tospace(?*anyopaque) ?*anyopaque;
pub extern "c" fn discard_tospace() void;
pub extern "c" fn open_code_tospace(usize) bool;
pub extern "c" fn discard_code_tospace() void;
pub extern "c" fn get_code_newspace_start() [*]obj.SchemeObject;
pub extern "c" fn get_code_newspace_ptr() [*]obj.SchemeObject;
pub extern "c" fn code_tospace_available_p(usize) bool;
pub extern "c" fn gc_transport_words_to_code_tospace([*]obj.SchemeObject, usize, bool) [*]obj.SchemeObject;
pub extern "c" fn gc_scan_code_tospace([*]obj.SchemeObject, [*]obj.SchemeObject) void;
pub extern "c" fn open_stage_tospace([*]obj.SchemeObject, [*]obj.SchemeObject, usize) void;
pub extern "c" fn close_stage_tospace() void;
pub extern "c" fn gc_scan_stage_tospace() void;
pub extern "c" fn OS_file_remove([*:0]const u8) void;
pub extern "c" fn OS_file_remove_link([*:0]const u8) void;
pub extern "c" fn cc_return_to_block_address(obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn cc_block_debugging_info(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn read_cc_entry_offset(*CcEntryOffset, ?*anyopaque) bool;
pub extern "c" fn compiled_closure_objects([*]obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn find_signal_name(c_int) [*:0]const u8;
pub extern "c" fn reset_interruptable_extent() void;
pub extern "c" fn termination_trap() noreturn;
pub extern "c" fn userio_choose_option([*:0]const u8, [*:0]const u8, [*]const ?[*:0]const u8) u8;
pub extern "c" fn plausible_cc_block_p([*]obj.SchemeObject) c_int;
pub extern "c" fn pc_to_builtin_index(usize) c_int;
pub extern "c" fn pc_to_utility_index(usize) c_int;
pub extern "c" fn svm_export_instruction_pointer(usize) usize;
pub extern "c" fn enter_interruption_extent() c_int;
pub extern "c" fn exit_interruption_extent() void;
pub extern "c" fn OS_ctty_int_char() CcT;
pub extern "c" fn OS_ctty_tstp_char() CcT;
pub extern "c" fn OS_ctty_disabled_char() CcT;
pub extern "c" fn UX_reinitialize_tty() void;
pub extern "c" fn termination_signal([*:0]const u8) noreturn;
pub extern "c" fn hard_reset(?*anyopaque) void;
pub extern "c" fn soft_reset() void;
pub extern "c" fn trap_handler([*:0]const u8, c_int, ?*SiginfoT, ?*anyopaque) void;
pub extern "c" fn userio_buffered_input() void;
pub extern "c" fn userio_read_char() u8;
pub extern "c" fn userio_read_char_raw() u8;
pub extern "c" fn OS_initialize() void;
pub extern "c" fn OS_announcement() void;
pub extern "c" fn Interpret() void;
pub extern "c" fn OS_file_access([*:0]const u8, c_uint) c_int;
pub extern "c" fn OS_working_dir_pathname() [*:0]const u8;
pub extern "c" fn macosx_main_bundle_dir() ?[*:0]const u8;

pub extern "c" fn cc_entry_to_block(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn cc_return_to_block(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn cc_entry_to_block_offset(obj.SchemeObject) usize;
pub extern "c" fn cc_return_to_block_offset(obj.SchemeObject) usize;
pub extern "c" fn cc_entry_to_block_address(obj.SchemeObject) [*]obj.SchemeObject;
pub extern "c" fn cc_return_address_to_entry_address(?*anyopaque) ?*anyopaque;
pub extern "c" fn coerce_to_compiled(obj.SchemeObject, c_uint, *obj.SchemeObject) isize;
pub extern "c" fn cc_entry_closure_p(obj.SchemeObject) bool;
pub extern "c" fn cc_block_closure_p(obj.SchemeObject) bool;
pub extern "c" fn cc_closure_to_entry(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn utility_index_to_name(c_uint) ?[*:0]const u8;
pub extern "c" fn builtin_index_to_name(c_uint) ?[*:0]const u8;
pub extern "c" fn declare_compiled_code_block(obj.SchemeObject) void;
pub extern "c" fn bkpt_install(?*anyopaque) obj.SchemeObject;
pub extern "c" fn bkpt_closure_install(?*anyopaque) obj.SchemeObject;
pub extern "c" fn bkpt_remove(?*anyopaque, obj.SchemeObject) void;
pub extern "c" fn bkpt_p(?*anyopaque) bool;
pub const tat_always: c_int = 2;

pub extern var prim_apply_error_code: isize;
pub extern var Primitive_Procedure_Table: ?[*]PrimitiveProcedure;
pub extern "c" fn Prim_unimplemented() obj.SchemeObject;
pub extern "c" fn apply_primitive_external(obj.SchemeObject) void;
pub extern "c" fn char_pointer_to_string(?[*:0]const u8) obj.SchemeObject;
pub extern "c" fn end_subproblem() void;
pub extern "c" fn compiler_new_subproblem() void;
pub extern "c" fn compiler_new_reduction() void;
pub extern "c" fn dstack_alloc(c_uint) ?*anyopaque;
pub extern "c" fn transaction_begin() void;
pub extern "c" fn transaction_commit() void;
pub extern "c" fn transaction_record_action(c_int, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) void;
pub extern "c" fn code_arena_alloc(usize) ?[*]obj.SchemeObject;
pub extern "c" fn code_arena_write_scope_begin() ?*anyopaque;
pub extern "c" fn code_arena_write_scope_end(?*anyopaque) void;
pub extern "c" fn compiler_cache_operator(obj.SchemeObject, obj.SchemeObject, usize) isize;
pub extern "c" fn compiler_cache_global_operator(obj.SchemeObject, obj.SchemeObject, usize) isize;
pub extern "c" fn compiler_cache_lookup(obj.SchemeObject, obj.SchemeObject, usize) isize;
pub extern "c" fn compiler_cache_assignment(obj.SchemeObject, obj.SchemeObject, usize) isize;
pub extern "c" fn compiler_var_error(obj.SchemeObject, obj.SchemeObject, CacheRefKind) obj.SchemeObject;
pub extern "c" fn compiler_assignment_trap(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn compiler_lookup_trap(obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn compiler_safe_lookup_trap(obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn compiler_unassigned_p_trap(obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn compiler_operator_reference_trap(obj.SchemeObject, *obj.SchemeObject) isize;
pub extern "c" fn write_cc_entry_type(*CcEntryType, ?*anyopaque) bool;
pub extern "c" fn write_cc_entry_offset(*CcEntryOffset, ?*anyopaque) bool;
pub extern "c" fn compiled_closure_entry(?*anyopaque) ?*anyopaque;
pub extern "c" fn compiled_closure_entry_to_target(?*anyopaque) obj.SchemeObject;
pub extern "c" fn read_uuo_symbol([*]obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn read_uuo_frame_size([*]obj.SchemeObject) c_uint;
pub extern "c" fn read_uuo_target_no_reloc([*]obj.SchemeObject) ?*anyopaque;
pub extern "c" fn trampoline_entry_size(usize) usize;
pub extern "c" fn trampoline_entry_addr([*]obj.SchemeObject, usize) ?*anyopaque;
pub extern "c" fn trampoline_return_addr([*]obj.SchemeObject, usize) ?*anyopaque;
pub extern "c" fn store_trampoline_insns(?*anyopaque, u8) bool;
pub extern "c" fn store_trampoline_to_interface_insns(?*anyopaque) bool;
pub extern "c" fn aarch64_reset_hook() void;
pub extern "c" fn x86_64_reset_hook() void;
pub extern "c" fn initialize_svm1() void;

pub extern "c" fn bkpt_proceed(?*anyopaque, obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn cc_block_environment(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn write_variable_cache(obj.SchemeObject, obj.SchemeObject, usize) void;
pub extern "c" fn make_uuo_link(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject, usize) isize;

pub extern "c" fn arg_integer(c_int) isize;
pub extern "c" fn arg_nonnegative_integer(c_int) isize;
pub extern "c" fn arg_index_integer(c_int, isize) isize;
pub extern "c" fn arg_ulong_integer(c_int) usize;
pub extern "c" fn arg_ulong_index_integer(c_int, usize) usize;
pub extern "c" fn arg_flonum(c_int) f64;

pub extern "c" fn long_to_integer(isize) obj.SchemeObject;
pub extern "c" fn ulong_to_integer(usize) obj.SchemeObject;
pub extern "c" fn double_to_flonum(f64) obj.SchemeObject;

pub extern "c" fn allocate_non_marked_vector(c_uint, usize, bool) obj.SchemeObject;
pub extern "c" fn allocate_marked_vector(c_uint, usize, bool) obj.SchemeObject;
pub extern "c" fn allocate_vector(usize, bool) obj.SchemeObject;
pub extern "c" fn make_vector(usize, obj.SchemeObject, bool) obj.SchemeObject;

pub extern "c" fn arg_bytevector(c_int, *usize) [*]u8;
pub extern "c" fn allocate_bytevector(usize) obj.SchemeObject;
pub extern "c" fn memory_to_bytevector(usize, ?*const anyopaque) obj.SchemeObject;
pub extern "c" fn OS_get_entropy(*[32]u8) void;

pub extern "c" fn canonicalize_primitive_context() void;
pub extern "c" fn abort_to_interpreter(isize) noreturn;
pub extern "c" fn stack_death([*:0]const u8) noreturn;
pub extern "c" fn cons(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;

pub extern "c" fn arg_integer_in_range(c_int, isize, isize) isize;
pub extern "c" fn arg_index_integer_to_intmax(c_int, i64) i64;
pub extern "c" fn error_unimplemented_primitive() noreturn;
pub extern "c" fn Mul(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn string_p(obj.SchemeObject) bool;
pub extern "c" fn allocate_string(usize) obj.SchemeObject;
pub extern "c" fn system_pair_cons(isize, obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn memory_hash(usize, ?*const anyopaque) u32;
pub extern "c" fn arg_ascii_char(c_int) isize;
pub extern "c" fn arg_ascii_integer(c_int) isize;
pub extern "c" fn char_upcase(isize) isize;
pub extern "c" fn char_downcase(isize) isize;
pub extern "c" fn string_to_char_pointer(obj.SchemeObject, ?*usize) [*]u8;
pub extern "c" fn arg_extended_string(c_uint, ?*usize) [*]u8;

pub const BignumComparison = enum(c_int) {
    equal = 0,
    less = 1,
    greater = 2,
};

pub const dbl_min_exp: isize = -1021;
pub const dbl_max_exp: isize = 1024;
pub const dbl_mant_dig: isize = 53;

pub extern "c" fn bignum_equal_p(obj.SchemeObject, obj.SchemeObject) c_int;
pub extern "c" fn bignum_test(obj.SchemeObject) c_int;
pub extern "c" fn bignum_compare(obj.SchemeObject, obj.SchemeObject) c_int;
pub extern "c" fn bignum_add(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_subtract(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_negate(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_multiply(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_divide(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject, *obj.SchemeObject) c_int;
pub extern "c" fn bignum_quotient(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_remainder(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn long_to_bignum(isize) obj.SchemeObject;
pub extern "c" fn ulong_to_bignum(usize) obj.SchemeObject;
pub extern "c" fn bignum_to_long(obj.SchemeObject) isize;
pub extern "c" fn bignum_to_ulong(obj.SchemeObject) usize;
pub extern "c" fn intmax_to_bignum(i64) obj.SchemeObject;
pub extern "c" fn uintmax_to_bignum(u64) obj.SchemeObject;
pub extern "c" fn bignum_to_intmax(obj.SchemeObject) i64;
pub extern "c" fn bignum_to_uintmax(obj.SchemeObject) u64;
pub extern "c" fn double_to_bignum(f64) obj.SchemeObject;
pub extern "c" fn bignum_to_double(obj.SchemeObject) f64;
pub extern "c" fn bignum_fits_in_word_p(obj.SchemeObject, isize, c_int) c_int;
pub extern "c" fn bignum_length_in_bits(obj.SchemeObject) usize;
pub extern "c" fn bignum_integer_length(obj.SchemeObject) usize;
pub extern "c" fn bignum_first_set_bit(obj.SchemeObject) isize;
pub extern "c" fn bignum_bit_count(obj.SchemeObject) usize;
pub extern "c" fn bignum_hamming_distance(obj.SchemeObject, obj.SchemeObject) isize;
pub extern "c" fn bignum_bitwise_not(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_and(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_andc2(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_andc1(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_xor(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_ior(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_nor(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_eqv(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_orc2(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_orc1(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_bitwise_nand(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn bignum_nonnegative_one_bits(usize, usize) obj.SchemeObject;
pub extern "c" fn bignum_negative_zero_bits(usize, usize) obj.SchemeObject;
pub extern "c" fn bignum_shift_right(obj.SchemeObject, usize) obj.SchemeObject;
pub extern "c" fn bignum_shift_left(obj.SchemeObject, usize) obj.SchemeObject;
pub extern "c" fn unsigned_long_to_shifted_bignum(usize, usize, c_int) obj.SchemeObject;
pub extern "c" fn digit_stream_to_bignum(
    c_uint,
    *const fn (?*anyopaque) callconv(.c) c_uint,
    ?*anyopaque,
    c_uint,
    c_int,
) obj.SchemeObject;
pub extern "c" fn bignum_to_digit_stream(
    obj.SchemeObject,
    c_uint,
    *const fn (?*anyopaque, isize) callconv(.c) void,
    ?*anyopaque,
) void;
pub extern "c" fn bignum_max_digit_stream_radix() isize;

pub inline fn bignumZeroP(b: obj.SchemeObject) bool {
    return bignum_test(b) == @intFromEnum(BignumComparison.equal);
}

pub inline fn bignumNegativeP(b: obj.SchemeObject) bool {
    return bignum_test(b) == @intFromEnum(BignumComparison.less);
}

pub inline fn bignumPositiveP(b: obj.SchemeObject) bool {
    return bignum_test(b) == @intFromEnum(BignumComparison.greater);
}

pub inline fn bignumLessP(x: obj.SchemeObject, y: obj.SchemeObject) bool {
    return bignum_compare(x, y) == @intFromEnum(BignumComparison.less);
}

pub inline fn bignumToLongP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @bitSizeOf(isize), 1) != 0;
}

pub inline fn bignumToUlongP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @bitSizeOf(usize), 0) != 0;
}

pub inline fn bignumToIntmaxP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, 64, 1) != 0;
}

pub inline fn bignumToUintmaxP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, 64, 0) != 0;
}

pub inline fn bignumToDoubleP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, dbl_max_exp + 1, 1) != 0;
}

pub inline fn losslessBignumToDoubleP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, dbl_mant_dig + 1, 1) != 0;
}

pub inline fn bignumToFixnumP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @as(isize, obj.fixnum_length) + 1, 1) != 0;
}

pub inline fn fixnumToBignum(f: obj.SchemeObject) obj.SchemeObject {
    return long_to_bignum(obj.fixnumToLong(f));
}

pub inline fn bignumToFixnumVal(b: obj.SchemeObject) obj.SchemeObject {
    return obj.longToFixnum(bignum_to_long(b));
}

pub inline fn bignumToFlonumVal(b: obj.SchemeObject) obj.SchemeObject {
    return double_to_flonum(bignum_to_double(b));
}

pub inline fn flonumToBignum(f: obj.SchemeObject) obj.SchemeObject {
    return double_to_bignum(obj.flonumToDouble(f));
}

pub inline fn primitiveHeader() void {
    if (build_options.debugging) {
        record_primitive_entry(Registers[regblock_expr]);
    }
}

pub inline fn argRef(n: usize) obj.SchemeObject {
    return stack_pointer[n - 1];
}

pub inline fn argLoc(n: usize) [*]obj.SchemeObject {
    return stack_pointer + (n - 1);
}

pub inline fn checkArg(n: c_int, comptime pred: anytype) void {
    if (!pred(argRef(@intCast(n)))) {
        error_wrong_type_arg(n);
    }
}

pub inline fn stringArg(n: c_int) [*:0]u8 {
    const arg = argRef(@intCast(n));
    if (!string_p(arg)) {
        error_wrong_type_arg(n);
    }
    return @ptrCast(obj.legacyStringData(arg));
}

pub inline fn vectorArg(n: c_int) obj.SchemeObject {
    const arg = argRef(@intCast(n));
    if (!obj.vectorP(arg)) {
        error_wrong_type_arg(n);
    }
    return arg;
}

pub inline fn booleanArg(n: usize) bool {
    return argRef(n) != obj.sharp_f;
}

pub inline fn getLexprActuals() usize {
    return @intCast(Registers[regblock_lexpr_actuals]);
}

pub inline fn gcType(o: obj.SchemeObject) c_int {
    return gc_type_code(@intCast(obj.objectType(o)));
}

pub inline fn gcTypePair(o: obj.SchemeObject) bool {
    return gcType(o) == @intFromEnum(GcType.pair);
}

pub inline fn gcTypeTriple(o: obj.SchemeObject) bool {
    return gcType(o) == @intFromEnum(GcType.triple);
}

pub inline fn gcTypeVector(o: obj.SchemeObject) bool {
    return gcType(o) == @intFromEnum(GcType.vector);
}

pub inline fn interruptEnabledP(mask: usize) bool {
    return (Registers[regblock_int_mask] & mask) != 0;
}

pub inline fn gcEnabledP() bool {
    return interruptEnabledP(int_gc);
}

pub inline fn pendingInterrupts() usize {
    return Registers[regblock_int_mask] & Registers[regblock_int_code];
}

pub inline fn interruptPendingP(mask: usize) bool {
    return (pendingInterrupts() & mask) != 0;
}

pub inline fn addressInConstantP(addr: [*]const obj.SchemeObject) bool {
    return @intFromPtr(addr) >= @intFromPtr(constant_start) and @intFromPtr(addr) < @intFromPtr(constant_end);
}

pub inline fn requestInterrupt(code: usize) void {
    Registers[regblock_int_code] |= code;
    compilerSetupInterrupt();
}

pub inline fn setInterruptMask(mask: usize) void {
    Registers[regblock_int_mask] = mask;
    compilerSetupInterrupt();
}

pub inline fn freeOkP(free: [*]const obj.SchemeObject) bool {
    return @intFromPtr(free) >= @intFromPtr(heap_start) and @intFromPtr(free) < @intFromPtr(heap_alloc_limit);
}

pub inline fn heapAvailableP(n_words: usize) bool {
    if (!freeOkP(Free)) return false;
    const avail_words: usize = @intCast((@intFromPtr(heap_alloc_limit) - @intFromPtr(Free)) / @sizeOf(obj.SchemeObject));
    return n_words <= avail_words;
}

pub inline fn gcNeededP(n_words: usize) bool {
    return !heapAvailableP(n_words) and gcEnabledP();
}

pub inline fn compilerSetupInterrupt() void {
    const memtop_ptr: [*]obj.SchemeObject = if (pendingInterrupts() != 0)
        memory_block_start
    else if (gcEnabledP())
        heap_alloc_limit
    else
        heap_end;
    Registers[regblock_memtop] = @intCast(@intFromPtr(memtop_ptr));

    const stack_guard_ptr: [*]obj.SchemeObject = if (interruptEnabledP(int_stack_overflow))
        stack_guard
    else
        stack_start;
    Registers[regblock_stack_guard] = @intCast(@intFromPtr(stack_guard_ptr));
}

pub inline fn requestGc(n_words: usize) void {
    Registers[regblock_int_code] |= int_gc;
    compilerSetupInterrupt();
    gc_space_needed = n_words;
}

pub fn primitiveGc(amount: usize) noreturn {
    const free_prim = Free_primitive orelse {
        outf.fatal("\nMicrocode requested primitive GC outside primitive!\n", .{});
        Microcode_Termination(term_exit);
    };
    if (@intFromPtr(free_prim) < @intFromPtr(heap_start)) {
        outf.fatal("\nMicrocode requested primitive GC outside primitive!\n", .{});
        Microcode_Termination(term_exit);
    }
    if (@intFromPtr(Free) < @intFromPtr(free_prim)) {
        outf.fatal("\nFree has gone backwards!\n", .{});
        Microcode_Termination(term_exit);
    }
    const used_words: usize = @intCast((@intFromPtr(Free) - @intFromPtr(free_prim)) / @sizeOf(obj.SchemeObject));
    requestGc(amount + used_words);
    signal_interrupt_from_primitive();
}

pub inline fn primitiveGcIfNeeded(amount: usize) void {
    if (gcNeededP(amount)) {
        primitiveGc(amount);
    }
}

pub inline fn stackPush(object: obj.SchemeObject) void {
    stack_pointer -= 1;
    stack_pointer[0] = object;
}

pub inline fn decrementSp(offset: usize) void {
    stack_pointer -= offset;
}

pub inline fn incrementSp(offset: usize) void {
    stack_pointer += offset;
}

pub inline fn popPrimitiveFrame(n: usize) void {
    incrementSp(n);
}

pub inline fn stackCanPushP(n: usize) bool {
    return @intFromPtr(stack_pointer) >= @intFromPtr(stack_guard) + n * @sizeOf(obj.SchemeObject);
}

pub inline fn stackOverflowedP() bool {
    return stack_start[0] != obj.makeBrokenHeart(stack_start);
}

pub inline fn stackCheck(n: usize) void {
    if (!stackCanPushP(n)) {
        if (stackOverflowedP()) stack_death("stack_check");
        Registers[regblock_int_code] |= int_stack_overflow;
        compilerSetupInterrupt();
    }
}

pub inline fn stackCheckFatal(s: [*:0]const u8) void {
    if (stackOverflowedP()) stack_death(s);
}

pub inline fn pushCont(rc: usize, exp: obj.SchemeObject) void {
    stackPush(exp);
    stackPush(obj.makeObject(obj.tc_return_code, rc));
}

pub inline fn makeApplyFrameHeader(size: usize) obj.SchemeObject {
    return obj.makeObject(obj.tc_manifest_vector, size);
}

pub inline fn applyFrameHeaderNArgs(header: obj.SchemeObject) usize {
    return obj.objectDatum(header) - 1;
}

pub inline fn heapAvailable() usize {
    if (!freeOkP(Free)) return 0;
    return @intCast((@intFromPtr(heap_alloc_limit) - @intFromPtr(Free)) / @sizeOf(obj.SchemeObject));
}

pub inline fn argHeapReserved(n: c_int) usize {
    const words: usize = @intCast((@intFromPtr(heap_end) - @intFromPtr(heap_start)) / @sizeOf(obj.SchemeObject));
    return arg_ulong_index_integer(n, words / 2);
}

pub inline fn stackPop() obj.SchemeObject {
    const val = stack_pointer[0];
    stack_pointer += 1;
    return val;
}

pub inline fn stackLoc(offset: usize) [*]obj.SchemeObject {
    return stack_pointer + offset;
}

pub inline fn stackRef(offset: usize) obj.SchemeObject {
    return stack_pointer[offset];
}

pub inline fn stackNPushed() usize {
    return @intCast((@intFromPtr(stack_end) - @intFromPtr(stack_pointer)) / @sizeOf(obj.SchemeObject));
}

pub inline fn clearInterrupt(code: usize) void {
    Registers[regblock_int_code] &= ~code;
    compilerSetupInterrupt();
}

pub inline fn contFrameRet(frame: [*]const obj.SchemeObject) obj.SchemeObject {
    return frame[0];
}

pub inline fn contFrameExp(frame: [*]const obj.SchemeObject) obj.SchemeObject {
    return frame[1];
}

pub inline fn primitiveNArgs(prim: obj.SchemeObject) usize {
    const arity = Primitive_Arity_Table.?[@intCast(obj.objectDatum(prim))];
    return if (arity == lexpr_primitive_arity) getLexprActuals() else @intCast(arity);
}

pub inline fn pushEnvCont(rc: usize, exp: obj.SchemeObject, env: obj.SchemeObject) void {
    stackPush(env);
    pushCont(rc, exp);
}

pub inline fn addressInHeapP(addr: [*]const obj.SchemeObject) bool {
    return @intFromPtr(addr) >= @intFromPtr(heap_start) and @intFromPtr(addr) < @intFromPtr(heap_end);
}

pub inline fn spaceBeforeGc() usize {
    if (gcEnabledP()) return heapAvailable();
    if (addressInHeapP(Free)) {
        return @intCast((@intFromPtr(heap_end) - @intFromPtr(Free)) / @sizeOf(obj.SchemeObject));
    }
    return 0;
}

pub inline fn historyUnmark(slot: *obj.SchemeObject) void {
    slot.* &= ~obj.history_mark_mask;
}

pub inline fn resetHeapAllocLimit() void {
    heap_alloc_limit = heap_end - @as(usize, @intCast(heap_reserved));
    compilerSetupInterrupt();
}

pub inline fn setStackLimits(start: [*]obj.SchemeObject, size: usize) void {
    stack_start = start;
    stack_end = start + @as(usize, @intCast(size));
}

pub inline fn initializeStack() void {
    stack_pointer = stack_end;
    stack_start[0] = obj.makeBrokenHeart(stack_start);
    stack_guard = stack_start + @as(usize, @intCast(stack_guard_size));
    compilerSetupInterrupt();
}

pub inline fn initializeInterrupts(mask: usize) void {
    Registers[regblock_int_mask] = mask;
    Registers[regblock_int_code] = 0;
    compilerSetupInterrupt();
}

pub inline fn addressInStackP(addr: [*]const obj.SchemeObject) bool {
    return @intFromPtr(addr) >= @intFromPtr(stack_start) and @intFromPtr(addr) < @intFromPtr(stack_end);
}

pub inline fn spToNPushed(sp: [*]const obj.SchemeObject, _: [*]const obj.SchemeObject, end: [*]const obj.SchemeObject) usize {
    return @intCast((@intFromPtr(end) - @intFromPtr(sp)) / @sizeOf(obj.SchemeObject));
}
