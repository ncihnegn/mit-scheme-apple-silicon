// Derived from MIT/GNU Scheme C sources (`src/microcode/storage.c`, `types.h`, `const.h`, `errors.h`, `fixobj.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const build_options = @import("build_options");
const obj = @import("scheme_obj.zig");

pub export var Free: ?[*]obj.SchemeObject = null;
pub export var Free_primitive: ?[*]obj.SchemeObject = null;
pub export var heap_alloc_limit: ?[*]obj.SchemeObject = null;
pub export var heap_start: ?[*]obj.SchemeObject = null;
pub export var heap_end: ?[*]obj.SchemeObject = null;

pub export var stack_pointer: ?[*]obj.SchemeObject = null;
pub export var stack_guard: ?[*]obj.SchemeObject = null;
pub export var stack_start: ?[*]obj.SchemeObject = null;
pub export var stack_end: ?[*]obj.SchemeObject = null;

pub export var constant_alloc_next: ?[*]obj.SchemeObject = null;
pub export var constant_start: ?[*]obj.SchemeObject = null;
pub export var constant_end: ?[*]obj.SchemeObject = null;

pub export var last_return_code: ?[*]obj.SchemeObject = null;

pub export var fixed_objects: obj.SchemeObject = 0;

pub export var ephemeron_array: obj.SchemeObject = obj.sharp_f;
pub export var ephemeron_count: usize = 0;

pub export var trapping: bool = false;

pub export var n_heap_blocks: usize = 0;
pub export var n_constant_blocks: usize = 0;
pub export var n_stack_blocks: usize = 0;
pub export var memory_block_start: ?[*]obj.SchemeObject = null;
pub export var memory_block_end: ?[*]obj.SchemeObject = null;

pub export var heap_reserved: usize = 0;
pub export var gc_space_needed: usize = 0;

pub export var n_ephemerons_requested: usize = 0;
pub export var ephemeron_request_hard_p: bool = false;

var registers_storage: [14]obj.SchemeObject = @splat(0);
pub var memory_base_storage: ?[*]obj.SchemeObject = null;

pub var eval_debug: bool = false;
pub var hex_input_debug: bool = false;
pub var file_load_debug: bool = false;
pub var reloc_debug: bool = false;
pub var intern_debug: bool = false;
pub var cont_debug: bool = false;
pub var primitive_debug: bool = false;
pub var lookup_debug: bool = false;
pub var define_debug: bool = false;
pub var gc_debug: bool = false;
pub var upgrade_debug: bool = false;
pub var dump_debug: bool = false;
pub var trace_on_error: bool = false;
pub var per_file: bool = false;
pub var bignum_debug: bool = false;
pub var print_errors: bool = true;
pub var debug_slotno_storage: c_uint = 0;
pub var debug_nslots_storage: c_uint = 0;
pub var local_slotno_storage: c_uint = 0;
pub var local_nslots_storage: c_uint = 0;
pub var debug_circle_storage: [100]c_uint = @splat(0);
pub var local_circle_storage: [100]c_uint = @splat(0);

comptime {
    if (!build_options.cc_support) {
        @export(&registers_storage, .{ .name = "Registers" });
    }
    if (!obj.heap_in_low_memory) {
        @export(&memory_base_storage, .{ .name = "memory_base" });
    }
    if (build_options.debugging) {
        @export(&eval_debug, .{ .name = "Eval_Debug" });
        @export(&hex_input_debug, .{ .name = "Hex_Input_Debug" });
        @export(&file_load_debug, .{ .name = "File_Load_Debug" });
        @export(&reloc_debug, .{ .name = "Reloc_Debug" });
        @export(&intern_debug, .{ .name = "Intern_Debug" });
        @export(&cont_debug, .{ .name = "Cont_Debug" });
        @export(&primitive_debug, .{ .name = "Primitive_Debug" });
        @export(&lookup_debug, .{ .name = "Lookup_Debug" });
        @export(&define_debug, .{ .name = "Define_Debug" });
        @export(&gc_debug, .{ .name = "GC_Debug" });
        @export(&upgrade_debug, .{ .name = "Upgrade_Debug" });
        @export(&dump_debug, .{ .name = "Dump_Debug" });
        @export(&trace_on_error, .{ .name = "Trace_On_Error" });
        @export(&per_file, .{ .name = "Per_File" });
        @export(&bignum_debug, .{ .name = "Bignum_Debug" });
        @export(&print_errors, .{ .name = "Print_Errors" });
        @export(&debug_slotno_storage, .{ .name = "debug_slotno" });
        @export(&debug_nslots_storage, .{ .name = "debug_nslots" });
        @export(&local_slotno_storage, .{ .name = "local_slotno" });
        @export(&local_nslots_storage, .{ .name = "local_nslots" });
        @export(&debug_circle_storage, .{ .name = "debug_circle" });
        @export(&local_circle_storage, .{ .name = "local_circle" });
    }
}

pub export var type_names = [64]?[*:0]const u8{
    "false", // 0x00
    "pair", // 0x01
    "character", // 0x02
    "quotation", // 0x03
    "compiled-return", // 0x04
    "uninterned-symbol", // 0x05
    "flonum", // 0x06
    "apply-hook", // 0x07
    "constant", // 0x08
    "extended-procedure", // 0x09
    "vector", // 0x0a
    "return-code", // 0x0b
    null, // 0x0c
    "manifest-closure", // 0x0d
    "bignum", // 0x0e
    "procedure", // 0x0f
    "entity", // 0x10
    "delay", // 0x11
    "environment", // 0x12
    "promise", // 0x13
    "extended-lambda", // 0x14
    "comment", // 0x15
    "non-marked-vector", // 0x16
    "lambda", // 0x17
    "primitive", // 0x18
    "sequence", // 0x19
    "fixnum", // 0x1a
    "unicode-string", // 0x1b
    "control-point", // 0x1c
    "interned-symbol", // 0x1d
    "string", // 0x1e
    "access", // 0x1f
    "hunk3-a", // 0x20
    "definition", // 0x21
    "broken-heart", // 0x22
    "assignment", // 0x23
    "triple", // 0x24
    "tagged-object", // 0x25
    "combination", // 0x26
    "manifest-nm-vector", // 0x27
    "compiled-entry", // 0x28
    "lexpr", // 0x29
    null, // 0x2a
    "ephemeron", // 0x2b
    "variable", // 0x2c
    "the-environment", // 0x2d
    "syntax-error", // 0x2e
    "vector-1b", // 0x2f
    null, // 0x30
    "vector-16b", // 0x31
    "reference-trap", // 0x32
    "bytevector", // 0x33
    "conditional", // 0x34
    "disjunction", // 0x35
    "cell", // 0x36
    "weak-cons", // 0x37
    "quad", // 0x38
    "linkage-section", // 0x39
    "ratnum", // 0x3a
    "stack-environment", // 0x3b
    "recnum", // 0x3c
    "compiled-code-block", // 0x3d
    "record", // 0x3e
    null, // 0x3f
};

pub export var Abort_Names = [13][*:0]const u8{
    "DONE", // -1
    "DO-EXPRESSION", // -2
    "APPLY", // -3
    "INTERRUPT", // -4
    "NO-TRAP-EVAL", // -5
    "NO-TRAP_APPLY", // -6
    "POP-RETURN", // -7
    "TOUCH", // -8
    "APPLY-INTERRUPT", // -9
    "REENTER", // -10
    "NO-TRAP-POP-RETURN", // -11
    "RETURN-TO-C", // -12
    "ABORT-TO-C", // -13
};

pub export var Error_Names = [64]?[*:0]const u8{
    "bad-error-code", // 0x00
    "unbound-variable", // 0x01
    "unassigned-variable", // 0x02
    "undefined-procedure", // 0x03
    "system-call", // 0x04
    "error-with-argument", // 0x05
    "bad-frame", // 0x06
    null, // 0x07
    null, // 0x08
    "undefined-primitive-operation", // 0x09
    "external-return", // 0x0a
    "execute-manifest-vector", // 0x0b
    "wrong-number-of-arguments", // 0x0c
    "wrong-type-argument-0", // 0x0d
    "wrong-type-argument-1", // 0x0e
    "wrong-type-argument-2", // 0x0f
    "bad-range-argument-0", // 0x10
    "bad-range-argument-1", // 0x11
    "bad-range-argument-2", // 0x12
    "macro-binding", // 0x13
    "fasdump-object-too-large", // 0x14
    "syntax-error", // 0x15
    null, // 0x16
    "fasl-file-too-big", // 0x17
    "fasl-file-bad-data", // 0x18
    null, // 0x19
    null, // 0x1a
    null, // 0x1b
    null, // 0x1c
    null, // 0x1d
    null, // 0x1e
    null, // 0x1f
    "out-of-file-handles", // 0x20
    null, // 0x21
    "bad-range-argument-3", // 0x22
    "bad-range-argument-4", // 0x23
    "bad-range-argument-5", // 0x24
    "bad-range-argument-6", // 0x25
    "bad-range-argument-7", // 0x26
    "bad-range-argument-8", // 0x27
    "bad-range-argument-9", // 0x28
    "wrong-type-argument-3", // 0x29
    "wrong-type-argument-4", // 0x2a
    "wrong-type-argument-5", // 0x2b
    "wrong-type-argument-6", // 0x2c
    "wrong-type-argument-7", // 0x2d
    "wrong-type-argument-8", // 0x2e
    "wrong-type-argument-9", // 0x2f
    "inapplicable-continuation", // 0x30
    "compiled-code-error", // 0x31
    "floating-overflow", // 0x32
    "unimplemented-primitive", // 0x33
    "illegal-reference-trap", // 0x34
    null, // 0x35
    "wrong-arity-primitives", // 0x36
    null, // 0x37
    "fasdump-environment", // 0x38
    "fasload-band", // 0x39
    "fasload-compiled-mismatch", // 0x3a
    null, // 0x3b
    null, // 0x3c
    "stack-has-slipped", // 0x3d
    "cannot-recurse", // 0x3e
    "process-terminated", // 0x3f
};

pub export var Term_Names = [27]?[*:0]const u8{
    "halt", // 0x00
    "disk-restore", // 0x01
    "broken-heart", // 0x02
    "non-pointer-relocation", // 0x03
    "bad-root", // 0x04
    "non-existent-continuation", // 0x05
    "bad-stack", // 0x06
    "stack-overflow", // 0x07
    "stack-allocation-failed", // 0x08
    "no-error-handler", // 0x09
    "no-interrupt-handler", // 0x0a
    "unimplemented-continuation", // 0x0b
    "exit", // 0x0c
    "bad-primitive-during-error", // 0x0d
    "eof", // 0x0e
    "bad-primitive", // 0x0f
    "termination-handler", // 0x10
    "end-of-computation", // 0x11
    "invalid-type-code", // 0x12
    "compiler-death", // 0x13
    "gc-out-of-space", // 0x14
    "no-space", // 0x15
    "signal", // 0x16
    null, // 0x17
    "save-and-exit", // 0x18
    "trap", // 0x19
    "bad-back-out", // 0x1a
};

pub export var term_messages = [27]?[*:0]const u8{
    null, // 0x00
    "Unrecoverable error while loading a band", // 0x01
    "Broken heart encountered", // 0x02
    "Non pointer relocation", // 0x03
    "Cannot restore control state from band", // 0x04
    "Nonexistent return code", // 0x05
    "Control stack messed up", // 0x06
    "Stack overflow: Maximum recursion depth exceeded", // 0x07
    "Not enough space for stack!", // 0x08
    "No error handler", // 0x09
    "No interrupt handler", // 0x0a
    "Unimplemented return code", // 0x0b
    "Inconsistency detected", // 0x0c
    "Error during unknown primitive", // 0x0d
    "End of input stream reached", // 0x0e
    "Bad primitive invoked", // 0x0f
    "Termination handler returned", // 0x10
    "End of computation", // 0x11
    "Unknown type encountered", // 0x12
    "Mismatch between compiled code and compiled code support", // 0x13
    "Out of space after garbage collection", // 0x14
    "Out of memory: Available memory exceeded", // 0x15
    "Unhandled signal received", // 0x16
    null, // 0x17
    "Halt requested by external source", // 0x18
    "User requested termination after trap", // 0x19
    "Backing out of non-primitive", // 0x1a
};

pub export var term_halt_messages = [7][*:0]const u8{
    "Moriturus te salutat.",
    "Happy happy joy joy!",
    "Ceterum censeo Carthaginem esse delendam.",
    "..#]^@^@^@ NO CARRIER",
    "Fortitudine vincimus.",
    "Post proelium, praemium.",
    "Pulvis et umbra sumus.",
};

pub export var fixed_objects_names = [70]?[*:0]const u8{
    "non-object", // 0x00
    "system-interrupt-vector", // 0x01
    "system-error-vector", // 0x02
    "obarray", // 0x03
    "microcode-types-vector", // 0x04
    "microcode-returns-vector", // 0x05
    "interrupt-mask-vector", // 0x06
    "microcode-errors-vector", // 0x07
    "microcode-identification-vector", // 0x08
    "system-call-names", // 0x09
    "system-call-errors", // 0x0a
    "gc-daemon", // 0x0b
    "trap-handler", // 0x0c
    "edwin-auto-save", // 0x0d
    "stepper-state", // 0x0e
    "microcode-fixed-objects-slots", // 0x0f
    "files-to-delete", // 0x10
    "record-dispatch-tag", // 0x11
    "record-applicator-index", // 0x12
    "dummy-history", // 0x13
    "bignum-one", // 0x14
    "proxied-record-types", // 0x15
    "microcode-terminations-vector", // 0x16
    "microcode-terminations-procedures", // 0x17
    "gc-reclaimed-object", // 0x18
    "initial-hash", // 0x19
    "return-frame-types", // 0x1a
    "reflect-code-names", // 0x1b
    "return-code-fields", // 0x1c
    "error-procedure", // 0x1d
    null, // 0x1e
    null, // 0x1f
    "compiler-error-procedure", // 0x20
    null, // 0x21
    null, // 0x22
    "primitive-profiling-table", // 0x23
    "generic-trampoline-zero?", // 0x24
    "generic-trampoline-positive?", // 0x25
    "generic-trampoline-negative?", // 0x26
    "generic-trampoline-add-1", // 0x27
    "generic-trampoline-subtract-1", // 0x28
    "generic-trampoline-equal?", // 0x29
    "generic-trampoline-less?", // 0x2a
    "generic-trampoline-greater?", // 0x2b
    "generic-trampoline-add", // 0x2c
    "generic-trampoline-subtract", // 0x2d
    "generic-trampoline-multiply", // 0x2e
    "generic-trampoline-divide", // 0x2f
    "generic-trampoline-quotient", // 0x30
    "generic-trampoline-remainder", // 0x31
    "generic-trampoline-modulo", // 0x32
    "arity-dispatcher-tag", // 0x33
    "pc-sample/builtin-table", // 0x34
    "pc-sample/utility-table", // 0x35
    "pc-sample/primitive-table", // 0x36
    "pc-sample/code-block-table", // 0x37
    "pc-sample/purified-code-block-block-buffer", // 0x38
    "pc-sample/purified-code-block-offset-buffer", // 0x39
    "pc-sample/heathen-code-block-block-buffer", // 0x3a
    "pc-sample/heathen-code-block-offset-buffer", // 0x3b
    "pc-sample/interp-proc-buffer", // 0x3c
    "pc-sample/prob-comp-table", // 0x3d
    "pc-sample/ufo-table", // 0x3e
    "compiled-code-bkpt-handler", // 0x3f
    null, // 0x40
    "callback-handler", // 0x41
    null, // 0x42
    null, // 0x43
    null, // 0x44
    null, // 0x45
};

test "storage exports runtime globals and name tables" {
    const abi = @import("prim_abi.zig");
    const stubs = @import("test_stubs.zig");
    stubs.resetMockRuntime();

    // Pointer globals match abi externs and nullable globals default to null.
    try std.testing.expectEqual(@as(?[*]obj.SchemeObject, abi.heap_start), memory_block_start);
    try std.testing.expectEqual(@as(?[*]obj.SchemeObject, null), memory_block_end);
    try std.testing.expectEqual(@as(?[*]obj.SchemeObject, null), last_return_code);
    try std.testing.expectEqual(obj.sharp_f, ephemeron_array);
    try std.testing.expectEqual(@as(usize, 0), ephemeron_count);
    try std.testing.expectEqual(false, trapping);

    try std.testing.expectEqualStrings("false", std.mem.span(type_names[0x00].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), type_names[0x0C]);
    try std.testing.expectEqualStrings("record", std.mem.span(type_names[0x3E].?));
    try std.testing.expectEqualStrings("NO-TRAP_APPLY", std.mem.span(Abort_Names[5]));
    try std.testing.expectEqualStrings("process-terminated", std.mem.span(Error_Names[0x3F].?));
    try std.testing.expectEqualStrings("bad-back-out", std.mem.span(Term_Names[0x1A].?));
    try std.testing.expectEqualStrings("Backing out of non-primitive", std.mem.span(term_messages[0x1A].?));
    try std.testing.expectEqualStrings("Moriturus te salutat.", std.mem.span(term_halt_messages[0]));
    try std.testing.expectEqualStrings("callback-handler", std.mem.span(fixed_objects_names[0x41].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), fixed_objects_names[0x45]);

    if (build_options.debugging) {
        try std.testing.expectEqual(false, eval_debug);
        try std.testing.expectEqual(true, print_errors);
        try std.testing.expectEqual(@as(c_uint, 0), debug_circle_storage[0]);
    }
}
