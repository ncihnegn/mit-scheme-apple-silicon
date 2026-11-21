// Derived from MIT/GNU Scheme C sources (`src/microcode/prims.h`, `src/microcode/prim.h`, `src/microcode/extern.h`, `src/microcode/intrpt.h`, `src/microcode/memmag.h`, `src/microcode/gc.h`, `src/microcode/const.h`, `src/microcode/errors.h`, `src/microcode/fixobj.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");

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

pub const int_stack_overflow: c_ulong = 0x0001;
pub const int_gc: c_ulong = 0x0004;
pub const int_character: c_ulong = 0x0010;
pub const int_timer: c_ulong = 0x0040;
pub const int_global_3: c_ulong = 0x0080;
pub const int_suspend: c_ulong = 0x0100;
pub const int_mask: c_ulong = (@as(c_ulong, 1) << 16) - 1;
pub const max_interrupt_number: c_ulong = 0xF;

pub const term_bad_stack: c_int = 0x06;
pub const term_stack_overflow: c_int = 0x07;
pub const term_no_interrupt_handler: c_int = 0x0A;
pub const term_exit: c_int = 0x0C;
pub const term_no_space: c_int = 0x15;
pub const err_bad_error_code: c_long = 0x00;
pub const err_unbound_variable: c_long = 0x01;
pub const err_unassigned_variable: c_long = 0x02;
pub const err_in_system_call: c_long = 0x04;
pub const err_with_argument: c_long = 0x05;
pub const err_undefined_primitive: c_long = 0x09;
pub const err_external_return: c_long = 0x0A;
pub const err_wrong_number_of_arguments: c_long = 0x0C;
pub const err_arg_1_wrong_type: c_long = 0x0D;
pub const err_arg_2_wrong_type: c_long = 0x0E;
pub const err_arg_3_wrong_type: c_long = 0x0F;
pub const err_arg_1_bad_range: c_long = 0x10;
pub const err_arg_2_bad_range: c_long = 0x11;
pub const err_arg_3_bad_range: c_long = 0x12;
pub const err_macro_binding: c_long = 0x13;
pub const err_out_of_file_handles: c_long = 0x20;
pub const err_arg_4_bad_range: c_long = 0x22;
pub const err_arg_5_bad_range: c_long = 0x23;
pub const err_arg_6_bad_range: c_long = 0x24;
pub const err_arg_7_bad_range: c_long = 0x25;
pub const err_arg_8_bad_range: c_long = 0x26;
pub const err_arg_9_bad_range: c_long = 0x27;
pub const err_arg_10_bad_range: c_long = 0x28;
pub const err_arg_4_wrong_type: c_long = 0x29;
pub const err_arg_5_wrong_type: c_long = 0x2A;
pub const err_arg_6_wrong_type: c_long = 0x2B;
pub const err_arg_7_wrong_type: c_long = 0x2C;
pub const err_arg_8_wrong_type: c_long = 0x2D;
pub const err_arg_9_wrong_type: c_long = 0x2E;
pub const err_arg_10_wrong_type: c_long = 0x2F;
pub const err_floating_overflow: c_long = 0x32;
pub const err_unimplemented_primitive: c_long = 0x33;
pub const err_wrong_arity_primitives: c_long = 0x36;
pub const err_process_terminated: c_long = 0x3F;
pub const prim_done: c_long = -1;
pub const prim_do_expression: c_long = -2;
pub const prim_apply: c_long = -3;
pub const prim_interrupt: c_long = -4;
pub const prim_no_trap_eval: c_long = -5;
pub const prim_no_trap_apply: c_long = -6;
pub const prim_pop_return: c_long = -7;
pub const prim_no_trap_pop_return: c_long = -11;
pub const max_return_code: c_ulong = 0x5E;
pub const rc_join_stacklets: c_ulong = 0x01;
pub const rc_internal_apply: c_ulong = 0x03;
pub const rc_restore_history: c_ulong = 0x05;
pub const rc_snap_need_thunk: c_ulong = 0x1C;
pub const rc_normal_gc_done: c_ulong = 0x20;
pub const rc_pop_from_compiled_code: c_ulong = 0x29;
pub const rc_restore_dont_copy_history: c_ulong = 0x2F;
pub const rc_pop_return_error: c_ulong = 0x40;
pub const rc_eval_error: c_ulong = 0x41;
pub const rc_stack_marker: c_ulong = 0x42;
pub const rc_comp_interrupt_restart: c_ulong = 0x43;
pub const rc_restore_int_mask: c_ulong = 0x45;
pub const rc_comp_lookup_trap_restart: c_ulong = 0x53;
pub const rc_comp_assignment_trap_restart: c_ulong = 0x54;
pub const rc_comp_op_ref_trap_restart: c_ulong = 0x56;
pub const rc_comp_cache_ref_apply_restart: c_ulong = 0x57;
pub const rc_comp_safe_ref_trap_restart: c_ulong = 0x58;
pub const rc_comp_unassigned_trap_restart: c_ulong = 0x59;
pub const rc_hardware_trap: c_ulong = 0x5C;
pub const rc_internal_apply_val: c_ulong = 0x5D;
pub const rc_comp_error_restart: c_ulong = 0x5E;
pub const hist_rib: usize = 0;
pub const hist_next_subproblem: usize = 1;
pub const hist_prev_subproblem: usize = 2;
pub const hist_mark: usize = 1;
pub const rib_exp: usize = 0;
pub const rib_env: usize = 1;
pub const rib_next_reduction: usize = 2;
pub const rib_mark: usize = 2;
pub const constant_space_fudge: c_ulong = 128;
pub const default_heap_reserved: c_ulong = 4500;
pub const stack_guard_size: c_ulong = 4096;
pub const ephemeron_size: c_ulong = 5;
pub const marked_ephemeron_manifest: obj.SchemeObject = obj.makeVectorHeader(ephemeron_size - 1);
pub const cont_size: usize = 2;
pub const env_cont_size: usize = cont_size + 1;
pub const history_cont_size: usize = cont_size + 2;
pub const lexpr_primitive_arity: c_int = -1;
pub const unknown_primitive_arity: c_int = -2;
pub const syscall_malloc: c_int = 29;
pub const syserr_not_enough_space: c_int = 33;

pub const PrimitiveProcedure = *const fn () callconv(.c) obj.SchemeObject;
pub const OutfChannel = extern struct {
    type: c_int,
    cookie: ?*anyopaque,
};

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
pub const fixobj_initial_hash: usize = 0x19;
pub const fixobj_primitive_profiling_table: usize = 0x23;
pub const n_fixed_objects: c_ulong = 0x45;
pub const obarray_size: c_ulong = 32771;
pub const fasdump_record_marker_start: c_ulong = 0x100;
pub const fasdump_record_marker_end: c_ulong = 0x200;

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
            offset: c_ulong,
        },
    },
};

pub extern var Registers: [14]obj.SchemeObject;
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
pub extern var heap_reserved: c_ulong;
pub extern var gc_space_needed: c_ulong;
pub extern var critical_section_name: ?[*:0]const u8;
pub extern var current_gc_table: ?*anyopaque;
pub extern var history_register: [*]obj.SchemeObject;
pub extern var prev_restore_history_offset: c_ulong;
pub extern var ERROR_OUTPUT: OutfChannel;
pub extern var FATAL_OUTPUT: OutfChannel;
pub extern var trapping: bool;
pub extern var constant_start: [*]obj.SchemeObject;
pub extern var constant_alloc_next: [*]obj.SchemeObject;
pub extern var constant_end: [*]obj.SchemeObject;
pub extern var compiler_processor_type: c_uint;
pub extern var OS_Name: [*:0]const u8;
pub extern var OS_Variant: [*:0]const u8;
pub extern var scheme_program_name: [*:0]const u8;
pub extern var MAX_PRIMITIVE: c_ulong;
pub extern var Primitive_Arity_Table: ?[*]c_int;
pub extern var Primitive_Name_Table: ?[*]?[*:0]const u8;
pub extern var Primitive_Documentation_Table: ?[*]?[*:0]const u8;

pub extern "c" fn error_wrong_type_arg(c_int) noreturn;
pub extern "c" fn error_bad_range_arg(c_int) noreturn;
pub extern "c" fn error_external_return() noreturn;
pub extern "c" fn signal_error_from_primitive(c_long) noreturn;
pub extern "c" fn signal_interrupt_from_primitive() noreturn;
pub extern "c" fn Microcode_Termination(c_int) noreturn;
pub extern "c" fn termination_init_error() noreturn;
pub extern "c" fn error_in_system_call(c_int, c_int) noreturn;
pub extern "c" fn OS_malloc(usize) ?*anyopaque;
pub extern "c" fn OS_realloc(?*anyopaque, usize) ?*anyopaque;
pub extern "c" fn OS_free(?*anyopaque) void;
pub extern "c" fn get_object_address(obj.SchemeObject) ?[*]obj.SchemeObject;
pub extern "c" fn OS_tty_map_interrupt_char(u8) u8;
pub extern "c" fn outf(OutfChannel, [*:0]const u8, ...) void;
pub extern "c" fn outf_flush(OutfChannel) void;
pub extern "c" fn debug_stack_trace(OutfChannel) void;
pub extern "c" fn debug_print_expr(obj.SchemeObject, [*:0]const u8) void;
pub extern "c" fn outf_fatal([*:0]const u8, ...) void;
pub extern "c" fn outf_error([*:0]const u8, ...) void;
pub extern "c" fn record_primitive_entry(obj.SchemeObject) void;
pub extern "c" fn gc_type_code(c_uint) c_int;
pub extern "c" fn gc_ptr_type(obj.SchemeObject) c_int;
pub extern "c" fn hashable_object_p(obj.SchemeObject) bool;
pub extern "c" fn hash_object(obj.SchemeObject) u32;
pub extern "c" fn combine_hashes(u32, u32) u32;
pub extern "c" fn OS_channel_close_noerror(c_uint) void;
pub extern "c" fn find_primitive(obj.SchemeObject, bool, bool, c_int) obj.SchemeObject;
pub extern "c" fn termination_normal(c_int) noreturn;
pub extern "c" fn OS_restartable_exit() void;
pub extern "c" fn OS_under_emacs_p() c_int;
pub extern "c" fn OS_set_trap_state(c_int) c_int;
pub extern "c" fn OS_tty_x_size() c_uint;
pub extern "c" fn OS_tty_y_size() c_uint;
pub extern "c" fn OS_syscall_names(*c_ulong, *[*]?[*:0]const u8) void;
pub extern "c" fn OS_syserr_names(*c_ulong, *[*]?[*:0]const u8) void;
pub extern "c" fn initialize_history() obj.SchemeObject;
pub extern "c" fn initialize_interrupt_handler_vector() obj.SchemeObject;
pub extern "c" fn initialize_interrupt_mask_vector() obj.SchemeObject;
pub extern "c" fn make_reflect_code_table() obj.SchemeObject;
pub extern "c" fn cc_block_linkage_info(obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn return_address_p(obj.SchemeObject) bool;
pub extern "c" fn cpoint_next_frame(obj.SchemeObject, c_ulong) c_ulong;
pub extern "c" fn return_frame_type([*]obj.SchemeObject) c_int;
pub extern "c" fn return_code_frame_type(obj.SchemeObject) c_int;

pub extern var return_to_interpreter: obj.SchemeObject;
pub extern var reflect_to_interface: obj.SchemeObject;
pub extern "c" fn cc_return_address_p(obj.SchemeObject) bool;
pub extern "c" fn reflect_to_interface_frame_type([*]obj.SchemeObject) c_int;
pub extern "c" fn cpoint_compiled_code_next(obj.SchemeObject, c_ulong) c_ulong;
pub extern "c" fn cpoint_compiled_address_next(obj.SchemeObject, c_ulong) c_ulong;
pub extern "c" fn cpoint_reflect_to_interface_next(obj.SchemeObject, c_ulong) c_ulong;

pub extern "c" fn open_tospace([*]obj.SchemeObject) void;
pub extern "c" fn initialize_weak_chain() void;
pub extern "c" fn get_newspace_ptr() [*]obj.SchemeObject;
pub extern "c" fn add_to_tospace(obj.SchemeObject) void;
pub extern "c" fn std_gc_table() ?*anyopaque;
pub extern "c" fn gc_scan_tospace([*]obj.SchemeObject, ?[*]obj.SchemeObject) void;
pub extern "c" fn increment_tospace_ptr(c_ulong) void;
pub extern "c" fn std_gc_pt1() void;
pub extern "c" fn std_gc_pt2() void;
pub extern "c" fn resize_tospace(c_ulong) void;

pub extern "c" fn lookup_variable(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) c_long;
pub extern "c" fn assign_variable(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) c_long;
pub extern "c" fn define_variable(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject) c_long;
pub extern "c" fn variable_unassigned_p(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) c_long;
pub extern "c" fn variable_unbound_p(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) c_long;
pub extern "c" fn variable_unreferenceable_p(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) c_long;
pub extern "c" fn link_variables(obj.SchemeObject, obj.SchemeObject, obj.SchemeObject, obj.SchemeObject) c_long;
pub extern "c" fn unbind_variable(obj.SchemeObject, obj.SchemeObject, *obj.SchemeObject) c_long;

pub extern "c" fn make_dummy_history() [*]obj.SchemeObject;
pub extern "c" fn save_history(c_ulong) void;
pub extern "c" fn stop_history() void;
pub extern "c" fn preserve_interrupt_mask() void;
pub extern "c" fn back_out_of_primitive() void;
pub extern "c" fn apply_compiled_from_primitive(c_ulong, obj.SchemeObject) void;
pub extern "c" fn compiled_with_stack_marker(obj.SchemeObject) void;
pub extern "c" fn compiled_with_interrupt_mask(c_ulong, obj.SchemeObject, c_ulong) void;
pub extern "c" fn termination_no_error_handler() noreturn;
pub extern "c" fn OS_error_code_to_syserr(c_int) c_int;
pub extern "c" fn guarantee_interp_return() void;
pub extern "c" fn update_weak_pointers() void;
pub extern "c" fn read_cc_entry_type(*CcEntryType, ?*anyopaque) bool;
pub extern "c" fn record_applicator(obj.SchemeObject) obj.SchemeObject;

pub const GcTospaceAllocator = *const fn (c_ulong, *?[*]obj.SchemeObject, *?[*]obj.SchemeObject) callconv(.c) void;
pub const GcAbortHandler = *const fn () callconv(.c) noreturn;
pub const GcWalkProc = *const fn ([*]obj.SchemeObject, [*]obj.SchemeObject, ?*anyopaque) callconv(.c) bool;

pub extern var compiler_utilities: obj.SchemeObject;
pub extern "c" fn OS_malloc_init(usize) ?*anyopaque;
pub extern "c" fn outf_flush_fatal() void;
pub extern "c" fn initialize_gc(c_ulong, *?[*]obj.SchemeObject, *?[*]obj.SchemeObject, GcTospaceAllocator, GcAbortHandler) void;
pub extern "c" fn save_tospace(GcWalkProc, ?*anyopaque) bool;
pub extern "c" fn tospace_to_newspace(?*anyopaque) ?*anyopaque;
pub extern "c" fn gc_scan_oldspace([*]obj.SchemeObject, [*]obj.SchemeObject) void;
pub extern "c" fn gc_drain_tospace_and_code_arena([*]obj.SchemeObject) void;
pub extern "c" fn aarch64_flush_i_cache() void;
pub extern "c" fn debug_verify_heap() void;
pub extern "c" fn std_gc_death([*:0]const u8, ...) noreturn;
pub extern "c" fn initialize_gc_object_references() void;
pub extern "c" fn finalize_gc_object_references() void;
pub extern "c" fn collect_gc_object_references(obj.SchemeObject, obj.SchemeObject) void;

pub extern "c" fn arg_integer(c_int) c_long;
pub extern "c" fn arg_nonnegative_integer(c_int) c_long;
pub extern "c" fn arg_index_integer(c_int, c_long) c_long;
pub extern "c" fn arg_ulong_integer(c_int) c_ulong;
pub extern "c" fn arg_ulong_index_integer(c_int, c_ulong) c_ulong;
pub extern "c" fn arg_flonum(c_int) f64;

pub extern "c" fn long_to_integer(c_long) obj.SchemeObject;
pub extern "c" fn ulong_to_integer(c_ulong) obj.SchemeObject;
pub extern "c" fn double_to_flonum(f64) obj.SchemeObject;

pub extern "c" fn allocate_non_marked_vector(c_uint, c_ulong, bool) obj.SchemeObject;
pub extern "c" fn allocate_marked_vector(c_uint, c_ulong, bool) obj.SchemeObject;
pub extern "c" fn allocate_vector(c_ulong, bool) obj.SchemeObject;
pub extern "c" fn make_vector(c_ulong, obj.SchemeObject, bool) obj.SchemeObject;

pub extern "c" fn arg_bytevector(c_int, *c_ulong) [*]u8;
pub extern "c" fn allocate_bytevector(c_ulong) obj.SchemeObject;
pub extern "c" fn memory_to_bytevector(c_ulong, ?*const anyopaque) obj.SchemeObject;
pub extern "c" fn OS_get_entropy(*[32]u8) void;

pub extern "c" fn canonicalize_primitive_context() void;
pub extern "c" fn abort_to_interpreter(c_long) noreturn;
pub extern "c" fn stack_death([*:0]const u8) noreturn;
pub extern "c" fn cons(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;

pub extern "c" fn arg_integer_in_range(c_int, c_long, c_long) c_long;
pub extern "c" fn arg_index_integer_to_intmax(c_int, i64) i64;
pub extern "c" fn error_unimplemented_primitive() noreturn;
pub extern "c" fn Mul(obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn string_p(obj.SchemeObject) bool;
pub extern "c" fn allocate_string(c_ulong) obj.SchemeObject;
pub extern "c" fn system_pair_cons(c_long, obj.SchemeObject, obj.SchemeObject) obj.SchemeObject;
pub extern "c" fn memory_hash(c_ulong, ?*const anyopaque) u32;
pub extern "c" fn arg_ascii_char(c_int) c_long;
pub extern "c" fn arg_ascii_integer(c_int) c_long;
pub extern "c" fn char_upcase(c_long) c_long;
pub extern "c" fn char_downcase(c_long) c_long;
pub extern "c" fn string_to_char_pointer(obj.SchemeObject, ?*c_ulong) [*]u8;
pub extern "c" fn arg_extended_string(c_uint, ?*c_ulong) [*]u8;

pub const BignumComparison = enum(c_int) {
    equal = 0,
    less = 1,
    greater = 2,
};

pub const dbl_min_exp: c_long = -1021;
pub const dbl_max_exp: c_long = 1024;
pub const dbl_mant_dig: c_long = 53;

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
pub extern "c" fn long_to_bignum(c_long) obj.SchemeObject;
pub extern "c" fn ulong_to_bignum(c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_to_long(obj.SchemeObject) c_long;
pub extern "c" fn bignum_to_ulong(obj.SchemeObject) c_ulong;
pub extern "c" fn intmax_to_bignum(i64) obj.SchemeObject;
pub extern "c" fn uintmax_to_bignum(u64) obj.SchemeObject;
pub extern "c" fn bignum_to_intmax(obj.SchemeObject) i64;
pub extern "c" fn bignum_to_uintmax(obj.SchemeObject) u64;
pub extern "c" fn double_to_bignum(f64) obj.SchemeObject;
pub extern "c" fn bignum_to_double(obj.SchemeObject) f64;
pub extern "c" fn bignum_fits_in_word_p(obj.SchemeObject, c_long, c_int) c_int;
pub extern "c" fn bignum_length_in_bits(obj.SchemeObject) c_ulong;
pub extern "c" fn bignum_integer_length(obj.SchemeObject) c_ulong;
pub extern "c" fn bignum_first_set_bit(obj.SchemeObject) c_long;
pub extern "c" fn bignum_bit_count(obj.SchemeObject) c_ulong;
pub extern "c" fn bignum_hamming_distance(obj.SchemeObject, obj.SchemeObject) c_long;
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
pub extern "c" fn bignum_nonnegative_one_bits(c_ulong, c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_negative_zero_bits(c_ulong, c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_shift_right(obj.SchemeObject, c_ulong) obj.SchemeObject;
pub extern "c" fn bignum_shift_left(obj.SchemeObject, c_ulong) obj.SchemeObject;
pub extern "c" fn unsigned_long_to_shifted_bignum(c_ulong, c_ulong, c_int) obj.SchemeObject;
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
    *const fn (?*anyopaque, c_long) callconv(.c) void,
    ?*anyopaque,
) void;
pub extern "c" fn bignum_max_digit_stream_radix() c_long;

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
    return bignum_fits_in_word_p(b, @bitSizeOf(c_long), 1) != 0;
}

pub inline fn bignumToUlongP(b: obj.SchemeObject) bool {
    return bignum_fits_in_word_p(b, @bitSizeOf(c_ulong), 0) != 0;
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
    return bignum_fits_in_word_p(b, @as(c_long, obj.fixnum_length) + 1, 1) != 0;
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

pub inline fn getLexprActuals() c_ulong {
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

pub inline fn interruptEnabledP(mask: c_ulong) bool {
    return (Registers[regblock_int_mask] & mask) != 0;
}

pub inline fn gcEnabledP() bool {
    return interruptEnabledP(int_gc);
}

pub inline fn pendingInterrupts() c_ulong {
    return Registers[regblock_int_mask] & Registers[regblock_int_code];
}

pub inline fn interruptPendingP(mask: c_ulong) bool {
    return (pendingInterrupts() & mask) != 0;
}

pub inline fn addressInConstantP(addr: [*]const obj.SchemeObject) bool {
    return @intFromPtr(addr) >= @intFromPtr(constant_start) and @intFromPtr(addr) < @intFromPtr(constant_end);
}

pub inline fn requestInterrupt(code: c_ulong) void {
    Registers[regblock_int_code] |= code;
    compilerSetupInterrupt();
}

pub inline fn setInterruptMask(mask: c_ulong) void {
    Registers[regblock_int_mask] = mask;
    compilerSetupInterrupt();
}

pub inline fn freeOkP(free: [*]const obj.SchemeObject) bool {
    return @intFromPtr(free) >= @intFromPtr(heap_start) and @intFromPtr(free) < @intFromPtr(heap_alloc_limit);
}

pub inline fn heapAvailableP(n_words: c_ulong) bool {
    if (!freeOkP(Free)) return false;
    const avail_words: c_ulong = @intCast((@intFromPtr(heap_alloc_limit) - @intFromPtr(Free)) / @sizeOf(obj.SchemeObject));
    return n_words <= avail_words;
}

pub inline fn gcNeededP(n_words: c_ulong) bool {
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

pub inline fn requestGc(n_words: c_ulong) void {
    Registers[regblock_int_code] |= int_gc;
    compilerSetupInterrupt();
    gc_space_needed = n_words;
}

pub fn primitiveGc(amount: c_ulong) noreturn {
    const free_prim = Free_primitive orelse {
        outf_fatal("\nMicrocode requested primitive GC outside primitive!\n");
        Microcode_Termination(term_exit);
    };
    if (@intFromPtr(free_prim) < @intFromPtr(heap_start)) {
        outf_fatal("\nMicrocode requested primitive GC outside primitive!\n");
        Microcode_Termination(term_exit);
    }
    if (@intFromPtr(Free) < @intFromPtr(free_prim)) {
        outf_fatal("\nFree has gone backwards!\n");
        Microcode_Termination(term_exit);
    }
    const used_words: c_ulong = @intCast((@intFromPtr(Free) - @intFromPtr(free_prim)) / @sizeOf(obj.SchemeObject));
    requestGc(amount + used_words);
    signal_interrupt_from_primitive();
}

pub inline fn primitiveGcIfNeeded(amount: c_ulong) void {
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

pub inline fn pushCont(rc: c_ulong, exp: obj.SchemeObject) void {
    stackPush(exp);
    stackPush(obj.makeObject(obj.tc_return_code, rc));
}

pub inline fn makeApplyFrameHeader(size: c_ulong) obj.SchemeObject {
    return obj.makeObject(obj.tc_manifest_vector, size);
}

pub inline fn heapAvailable() c_ulong {
    if (!freeOkP(Free)) return 0;
    return @intCast((@intFromPtr(heap_alloc_limit) - @intFromPtr(Free)) / @sizeOf(obj.SchemeObject));
}

pub inline fn argHeapReserved(n: c_int) c_ulong {
    const words: c_ulong = @intCast((@intFromPtr(heap_end) - @intFromPtr(heap_start)) / @sizeOf(obj.SchemeObject));
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

pub inline fn stackNPushed() c_ulong {
    return @intCast((@intFromPtr(stack_end) - @intFromPtr(stack_pointer)) / @sizeOf(obj.SchemeObject));
}

pub inline fn clearInterrupt(code: c_ulong) void {
    Registers[regblock_int_code] &= ~code;
    compilerSetupInterrupt();
}

pub inline fn contFrameRet(frame: [*]const obj.SchemeObject) obj.SchemeObject {
    return frame[0];
}

pub inline fn contFrameExp(frame: [*]const obj.SchemeObject) obj.SchemeObject {
    return frame[1];
}

pub inline fn primitiveNArgs(prim: obj.SchemeObject) c_ulong {
    const arity = Primitive_Arity_Table.?[@intCast(obj.objectDatum(prim))];
    return if (arity == lexpr_primitive_arity) getLexprActuals() else @intCast(arity);
}

pub inline fn pushEnvCont(rc: c_ulong, exp: obj.SchemeObject, env: obj.SchemeObject) void {
    stackPush(env);
    pushCont(rc, exp);
}

pub inline fn addressInHeapP(addr: [*]const obj.SchemeObject) bool {
    return @intFromPtr(addr) >= @intFromPtr(heap_start) and @intFromPtr(addr) < @intFromPtr(heap_end);
}

pub inline fn spaceBeforeGc() c_ulong {
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

pub inline fn setStackLimits(start: [*]obj.SchemeObject, size: c_ulong) void {
    stack_start = start;
    stack_end = start + @as(usize, @intCast(size));
}

pub inline fn initializeStack() void {
    stack_pointer = stack_end;
    stack_start[0] = obj.makeBrokenHeart(stack_start);
    stack_guard = stack_start + @as(usize, @intCast(stack_guard_size));
    compilerSetupInterrupt();
}
