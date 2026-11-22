// Derived from MIT/GNU Scheme C sources (`src/microcode/uxtrap.c`, `src/microcode/uxtrap.h`):
// Copyright (C) 1986-2022 Massachusetts Institute of Technology
// Licensed under the GNU General Public License (GPL v2 or later); see src/COPYING.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const obj = @import("../../core/scheme_obj.zig");
const abi = @import("../../core/prim_abi.zig");
const outf = @import("../../support/outf.zig");
const boot = @import("../../core/boot.zig");
const code_arena = @import("../../compiler/code_arena.zig");
const jit = @import("../../compiler/jit.zig");
const option = @import("../../core/option.zig");
const storage = @import("../../core/storage.zig");
const string = @import("../../data/string.zig");
const utils = @import("../../core/utils.zig");
const stubs = if (builtin.is_test) @import("../../core/test_stubs.zig") else struct {};

pub const TrapState = enum(c_int) {
    trapped = 0,
    exit = 1,
    @"suspend" = 2,
    query = 3,
    recover = 4,
    exitting_soft = 5,
    exitting_hard = 6,
};

const PcLocation = enum {
    heap,
    constant,
    code,
    builtin,
    utility,
    primitive,
    unknown,
};

const state_unknown: obj.SchemeObject = obj.makeObject(obj.tc_fixnum, 0);
const state_primitive: obj.SchemeObject = obj.makeObject(obj.tc_fixnum, 1);
const state_compiled_code: obj.SchemeObject = obj.makeObject(obj.tc_fixnum, 2);
const state_builtin: obj.SchemeObject = obj.makeObject(obj.tc_fixnum, 4);
const state_utility: obj.SchemeObject = obj.makeObject(obj.tc_fixnum, 5);

const TrapRecoveryInfo = extern struct {
    state: obj.SchemeObject,
    pc_info_1: obj.SchemeObject,
    pc_info_2: obj.SchemeObject,
    extra_trap_info: obj.SchemeObject,
};

const UxSigCodeDesc = struct {
    signo: c_int = 0,
    code_mask: usize = 0,
    code_value: usize = 0,
    name: ?[*:0]const u8 = null,
};

const DarwinSigaltstack = extern struct {
    ss_sp: ?*anyopaque,
    ss_size: usize,
    ss_flags: c_int,
};

const DarwinArmThreadState64 = extern struct {
    x: [29]u64,
    fp: u64,
    lr: u64,
    sp: u64,
    pc: u64,
    cpsr: u32,
    pad: u32,
};

const DarwinArmMcontext64 = extern struct {
    es: extern struct {
        far: u64,
        esr: u32,
        exception: u32,
    },
    ss: DarwinArmThreadState64,
};

const DarwinX86ThreadState64 = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
    cs: u64,
    fs: u64,
    gs: u64,
};

const DarwinX86Mcontext64 = extern struct {
    es: extern struct {
        trapno: u16,
        cpu: u16,
        err: u32,
        faultvaddr: u64,
    },
    ss: DarwinX86ThreadState64,
};

const LinuxStackT = extern struct {
    ss_sp: ?*anyopaque,
    ss_flags: c_int,
    ss_size: usize,
};

const LinuxArmMcontext = extern struct {
    fault_address: u64,
    regs: [31]u64,
    sp: u64,
    pc: u64,
    pstate: u64,
    reserved: [4096]u8 align(16),
};

const LinuxX86Mcontext = extern struct {
    gregs: [23]c_long,
    fpregs: ?*anyopaque,
    reserved1: [8]u64,
};

pub const Ucontext = if (builtin.os.tag.isDarwin()) extern struct {
    const DarwinMcontext64 = if (builtin.cpu.arch == .aarch64) DarwinArmMcontext64 else DarwinX86Mcontext64;
    uc_onstack: c_int,
    uc_sigmask: std.c.sigset_t,
    uc_stack: DarwinSigaltstack,
    uc_link: ?*Ucontext,
    uc_mcsize: usize,
    uc_mcontext: *DarwinMcontext64,
} else if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) extern struct {
    uc_flags: c_ulong,
    uc_link: ?*Ucontext,
    uc_stack: LinuxStackT,
    uc_sigmask: std.c.sigset_t,
    uc_mcontext: LinuxArmMcontext,
} else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) extern struct {
    uc_flags: c_ulong,
    uc_link: ?*Ucontext,
    uc_stack: LinuxStackT,
    uc_mcontext: LinuxX86Mcontext,
    uc_sigmask: std.c.sigset_t,
    fpregs_mem: [512]u8,
    ssp: [4]u64,
} else @compileError("unsupported OS/arch for ucontext_t");

comptime {
    if (builtin.os.tag.isDarwin()) {
        std.debug.assert(@sizeOf(Ucontext) == 56);
        std.debug.assert(@offsetOf(Ucontext, "uc_mcontext") == 48);
        if (builtin.cpu.arch == .aarch64) {
            std.debug.assert(@sizeOf(DarwinArmThreadState64) == 272);
            std.debug.assert(@offsetOf(DarwinArmMcontext64, "ss") == 16);
        } else if (builtin.cpu.arch == .x86_64) {
            std.debug.assert(@sizeOf(DarwinX86ThreadState64) == 168);
            std.debug.assert(@offsetOf(DarwinX86Mcontext64, "ss") == 16);
        }
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .aarch64) {
        std.debug.assert(@sizeOf(Ucontext) == 4560);
        std.debug.assert(@offsetOf(Ucontext, "uc_mcontext") == 176);
        std.debug.assert(@offsetOf(LinuxArmMcontext, "regs") == 8);
        std.debug.assert(@offsetOf(LinuxArmMcontext, "sp") == 256);
        std.debug.assert(@offsetOf(LinuxArmMcontext, "pc") == 264);
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        std.debug.assert(@sizeOf(Ucontext) == 968);
        std.debug.assert(@offsetOf(Ucontext, "uc_mcontext") == 40);
    }
    std.debug.assert(@offsetOf(std.c.siginfo_t, "code") == 8);
}

const sigcontext_nregs: usize = if (builtin.os.tag.isDarwin())
    (if (builtin.cpu.arch == .aarch64)
        (@sizeOf(DarwinArmThreadState64) + @sizeOf(c_ulong) - 1) / @sizeOf(c_ulong)
    else
        (@sizeOf(DarwinX86ThreadState64) + @sizeOf(c_ulong) - 1) / @sizeOf(c_ulong))
else if (builtin.cpu.arch == .aarch64)
    31
else
    23;

const uuo_link_size: usize = if (build_options.cc_is_svm) 2 else 4;
const scheme_alignment_mask: usize = @sizeOf(obj.SchemeObject) - 1;
const fixnum_marker: usize = obj.tc_fixnum;

var ux_signal_codes: [64]UxSigCodeDesc = @splat(.{});
var trap_state: TrapState = .recover;
var user_trap_state: TrapState = .recover;
var saved_trap_state: TrapState = .recover;
var saved_signo: c_int = 0;
var saved_info: ?*std.c.siginfo_t = null;
var saved_scp: ?*Ucontext = null;

pub fn sigcontextPc(scp: ?*const anyopaque) usize {
    const uc: ?*const Ucontext = if (scp) |p| @ptrCast(@alignCast(p)) else null;
    if (uc == null) return 0;
    if (builtin.os.tag.isDarwin()) {
        return if (builtin.cpu.arch == .aarch64) @intCast(uc.?.uc_mcontext.ss.pc) else @intCast(uc.?.uc_mcontext.ss.rip);
    }
    return if (builtin.cpu.arch == .aarch64) @intCast(uc.?.uc_mcontext.pc) else @bitCast(uc.?.uc_mcontext.gregs[16]);
}

fn sigcontextSp(scp: ?*const Ucontext) usize {
    const uc = scp orelse return 0;
    if (builtin.os.tag.isDarwin()) {
        return if (builtin.cpu.arch == .aarch64) @intCast(uc.uc_mcontext.ss.sp) else @intCast(uc.uc_mcontext.ss.rsp);
    }
    return if (builtin.cpu.arch == .aarch64) @intCast(uc.uc_mcontext.sp) else @bitCast(uc.uc_mcontext.gregs[15]);
}

fn sigcontextSchsp(scp: ?*const Ucontext) usize {
    const uc = scp orelse return 0;
    if (builtin.cpu.arch == .aarch64) {
        return if (builtin.os.tag.isDarwin()) @intCast(uc.uc_mcontext.ss.x[28]) else @intCast(uc.uc_mcontext.regs[28]);
    }
    return sigcontextSp(uc);
}

fn sigcontextRfree(scp: ?*const Ucontext) usize {
    const uc = scp orelse return @intFromPtr(abi.heap_alloc_limit);
    if (builtin.os.tag.isDarwin()) {
        return if (builtin.cpu.arch == .aarch64) @intCast(uc.uc_mcontext.ss.x[20]) else @intCast(uc.uc_mcontext.ss.rdi);
    }
    return if (builtin.cpu.arch == .aarch64) @intCast(uc.uc_mcontext.regs[20]) else @bitCast(uc.uc_mcontext.gregs[8]);
}

fn sigcontextFirstReg(scp: ?*const Ucontext) ?[*]const usize {
    const uc = scp orelse return null;
    if (builtin.os.tag.isDarwin()) {
        return @ptrCast(@alignCast(&uc.uc_mcontext.ss));
    }
    return if (builtin.cpu.arch == .aarch64) @ptrCast(&uc.uc_mcontext.regs[0]) else @ptrCast(&uc.uc_mcontext.gregs[0]);
}

fn pcAlignedP(pc: usize) bool {
    if (build_options.cc_is_native and builtin.cpu.arch == .aarch64) {
        return (pc & 3) == 0;
    }
    return true;
}

fn alignedP(addr: ?*const anyopaque) bool {
    return (@intFromPtr(addr) & scheme_alignment_mask) == 0;
}

fn heapAddressP(addr: ?*const anyopaque) bool {
    const p = @intFromPtr(addr);
    return p >= @intFromPtr(abi.heap_start) and p < @intFromPtr(abi.Free);
}

fn addressUcodeP(pc: usize) bool {
    if (builtin.os.tag == .linux and !builtin.is_test) {
        const LinuxBounds = struct {
            extern var __executable_start: u8;
            extern var etext: u8;
        };
        return pc >= @intFromPtr(&LinuxBounds.__executable_start) and pc <= @intFromPtr(&LinuxBounds.etext);
    }
    return false;
}

fn writeFileStr(stream: *std.c.FILE, s: []const u8) void {
    _ = std.c.fwrite(s.ptr, 1, s.len, stream);
}

fn writeFmt(stream: *std.c.FILE, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFileStr(stream, msg);
}

fn declareSignalCode(idx: *usize, signo: c_int, mask: usize, val: usize, name: ?[*:0]const u8) void {
    ux_signal_codes[idx.*] = .{
        .signo = signo,
        .code_mask = mask,
        .code_value = val,
        .name = name,
    };
    idx.* += 1;
}

fn initializeUxSignalCodes() void {
    const all_ones: usize = std.math.maxInt(usize);
    var i: usize = 0;

    if (builtin.os.tag.isDarwin()) {
        const ill = @backingInt(std.c.SIG.ILL);
        const fpe = @backingInt(std.c.SIG.FPE);
        const segv = @backingInt(std.c.SIG.SEGV);
        const bus = @backingInt(std.c.SIG.BUS);
        const trap = @backingInt(std.c.SIG.TRAP);

        declareSignalCode(&i, ill, all_ones, 1, "Illegal opcode");
        declareSignalCode(&i, ill, all_ones, 2, "Illegal trap");
        declareSignalCode(&i, ill, all_ones, 3, "Privileged opcode");
        declareSignalCode(&i, ill, all_ones, 7, "Coprocessor error");
        declareSignalCode(&i, ill, all_ones, 8, "Internal stack error");

        declareSignalCode(&i, fpe, all_ones, 1, "Floating-point divide by zero");
        declareSignalCode(&i, fpe, all_ones, 2, "Floating-point overflow");
        declareSignalCode(&i, fpe, all_ones, 3, "Floating-point underflow");
        declareSignalCode(&i, fpe, all_ones, 4, "Floating-point inexact result");
        declareSignalCode(&i, fpe, all_ones, 5, "Invalid floating-point operation");
        declareSignalCode(&i, fpe, all_ones, 6, "Subscript out of range");
        declareSignalCode(&i, fpe, all_ones, 7, "Integer divide by zero");
        declareSignalCode(&i, fpe, all_ones, 8, "Integer overflow");

        declareSignalCode(&i, segv, all_ones, 1, "Address not mapped to object");
        declareSignalCode(&i, segv, all_ones, 2, "Invalid permissions for mapped object");

        declareSignalCode(&i, bus, all_ones, 1, "Invalid address alignment");
        declareSignalCode(&i, bus, all_ones, 2, "Nonexistent physical address");
        declareSignalCode(&i, bus, all_ones, 3, "Object-specific hardware error");

        declareSignalCode(&i, trap, all_ones, 1, "Process breakpoint");
        declareSignalCode(&i, trap, all_ones, 2, "Process trace trap");

        declareSignalCode(&i, -1, all_ones, 0x10001, "signal sent by kill");
        declareSignalCode(&i, -1, all_ones, 0x10002, "signal sent by sigqueue");
        declareSignalCode(&i, -1, all_ones, 0x10003, "signal generated by timer expiration");
        declareSignalCode(&i, -1, all_ones, 0x10004, "signal generated by asynchronous I/O completion");
        declareSignalCode(&i, -1, all_ones, 0x10005, "signal generated by message queue arrival");
    } else if (builtin.os.tag == .linux) {
        const fpe = @backingInt(std.c.SIG.FPE);
        const ill = @backingInt(std.c.SIG.ILL);
        const segv = @backingInt(std.c.SIG.SEGV);
        const bus = @backingInt(std.c.SIG.BUS);
        const trap = @backingInt(std.c.SIG.TRAP);

        declareSignalCode(&i, fpe, all_ones, 1, "integer divide by 0 trap");
        declareSignalCode(&i, fpe, all_ones, 2, "integer overflow trap");
        declareSignalCode(&i, fpe, all_ones, 3, "floating-point divide by 0 trap");
        declareSignalCode(&i, fpe, all_ones, 4, "floating-point overflow trap");
        declareSignalCode(&i, fpe, all_ones, 5, "floating-point underflow trap");
        declareSignalCode(&i, fpe, all_ones, 6, "floating-point inexact result");
        declareSignalCode(&i, fpe, all_ones, 7, "invalid floating-point operation");
        declareSignalCode(&i, fpe, all_ones, 8, "subscript-range trap");

        declareSignalCode(&i, ill, all_ones, 1, "illegal opcode trap");
        declareSignalCode(&i, ill, all_ones, 2, "illegal operand trap");
        declareSignalCode(&i, ill, all_ones, 3, "illegal addressing mode trap");
        declareSignalCode(&i, ill, all_ones, 4, "illegal trap");
        declareSignalCode(&i, ill, all_ones, 5, "privileged opcode trap");
        declareSignalCode(&i, ill, all_ones, 6, "privileged register trap");
        declareSignalCode(&i, ill, all_ones, 7, "co-processor trap");
        declareSignalCode(&i, ill, all_ones, 8, "bad stack trap");

        declareSignalCode(&i, segv, all_ones, 1, "address not mapped to object");
        declareSignalCode(&i, segv, all_ones, 2, "invalid permissions for mapped object");

        declareSignalCode(&i, bus, all_ones, 1, "invalid address alignment");
        declareSignalCode(&i, bus, all_ones, 2, "nonexistent physical address");
        declareSignalCode(&i, bus, all_ones, 3, "object-specific hardware error");

        declareSignalCode(&i, trap, all_ones, 1, "process breakpoint");
        declareSignalCode(&i, trap, all_ones, 2, "process trace trap");

        declareSignalCode(&i, -1, all_ones, 0, "signal sent by kill");
        declareSignalCode(&i, -1, all_ones, @bitCast(@as(isize, -1)), "signal sent by sigqueue");
        declareSignalCode(&i, -1, all_ones, @bitCast(@as(isize, -2)), "signal generated by timer expiration");
        declareSignalCode(&i, -1, all_ones, @bitCast(@as(isize, -4)), "signal generated by asynchronous I/O completion");
        declareSignalCode(&i, -1, all_ones, @bitCast(@as(isize, -3)), "signal generated by message queue arrival");
    }

    declareSignalCode(&i, 0, 0, 0, null);
}

fn findSignalCodeName(signo: c_int, info: ?*const std.c.siginfo_t, _: ?*const Ucontext) obj.SchemeObject {
    const code: usize = if (info) |si| @bitCast(@as(isize, si.code)) else 0;
    const name: ?[*:0]const u8 = if (info != null) blk: {
        var idx: usize = 0;
        while (ux_signal_codes[idx].signo != 0) : (idx += 1) {
            const entry = ux_signal_codes[idx];
            if ((entry.signo < 0 or entry.signo == signo) and (entry.code_mask & code) == entry.code_value) {
                break :blk entry.name;
            }
        }
        break :blk null;
    } else null;
    return abi.cons(
        abi.ulong_to_integer(code),
        if (name) |n| string.char_pointer_to_string(n) else obj.sharp_f,
    );
}

fn findBlockAddress(pc: usize, area_start: [*]obj.SchemeObject) ?[*]obj.SchemeObject {
    const pcp_addr = pc & ~scheme_alignment_mask;
    var first_valid = area_start;
    var area = area_start;

    while (@intFromPtr(area) < pcp_addr) {
        const object = area[0];
        switch (obj.objectType(object)) {
            obj.tc_linkage_section => {
                const count: usize = @intCast(abi.linkage_section_count(object));
                area += 1;
                switch (abi.linkage_section_type(object)) {
                    @backingInt(abi.LinkageSectionType.global_operator),
                    @backingInt(abi.LinkageSectionType.operator),
                    => area += count * uuo_link_size,
                    else => area += count,
                }
            },
            obj.tc_manifest_closure => {
                area = abi.compiled_closure_objects(area + 1);
            },
            obj.tc_manifest_nm_vector => {
                const count = obj.objectDatum(object);
                const word_advance: usize = @intCast(count + 1);
                if (count < std.math.maxInt(usize) / @sizeOf(obj.SchemeObject) and
                    (@intFromPtr(area) + word_advance * @sizeOf(obj.SchemeObject)) < pcp_addr)
                {
                    area += word_advance;
                    first_valid = area;
                } else {
                    if (@intFromPtr(area) == @intFromPtr(first_valid)) return null;
                    const block = area - 1;
                    const block_type = obj.objectType(block[0]);
                    if ((block_type == obj.tc_manifest_vector or block_type == fixnum_marker) and
                        obj.objectDatum(block[0]) >= count + 1 and
                        abi.plausible_cc_block_p(block) != 0)
                    {
                        return block;
                    }
                    return null;
                }
            },
            else => area += 1,
        }
    }
    return null;
}

fn findCodeAddress(pc: usize) ?[*]obj.SchemeObject {
    const block = code_arena.code_arena_find_block(@ptrFromInt(pc)) orelse return null;
    return if (abi.plausible_cc_block_p(block) != 0) block else null;
}

fn classifyPc(pc: usize, r_block_addr: ?*?[*]obj.SchemeObject, r_index: ?*c_uint) PcLocation {
    if (build_options.cc_support) {
        if (pcAlignedP(pc)) {
            const pc_ptr: ?*const anyopaque = @ptrFromInt(pc);
            if (heapAddressP(pc_ptr)) {
                const block_addr = findBlockAddress(pc, abi.heap_start) orelse return .unknown;
                if (r_block_addr) |out| out.* = block_addr;
                return .heap;
            }
            if (pc >= @intFromPtr(abi.constant_start) and pc < @intFromPtr(abi.constant_end)) {
                const block_addr = findBlockAddress(pc, abi.constant_start) orelse return .unknown;
                if (r_block_addr) |out| out.* = block_addr;
                return .constant;
            }
            if (abi.code_address_p(pc_ptr)) {
                const block_addr = findCodeAddress(pc) orelse return .unknown;
                if (r_block_addr) |out| out.* = block_addr;
                return .code;
            }
            if (addressUcodeP(pc)) {
                const b_idx = abi.pc_to_builtin_index(pc);
                if (b_idx >= 0) {
                    if (r_index) |out| out.* = @intCast(b_idx);
                    return .builtin;
                }
                const u_idx = abi.pc_to_utility_index(pc);
                if (u_idx >= 0) {
                    if (r_index) |out| out.* = @intCast(u_idx);
                    return .utility;
                }
                if (obj.primitiveP(abi.Registers[abi.regblock_primitive])) {
                    return .primitive;
                }
            }
        }
    } else {
        if (addressUcodeP(pc) and obj.primitiveP(abi.Registers[abi.regblock_primitive])) {
            return .primitive;
        }
    }
    return .unknown;
}

fn setupTrapFrame(
    signo: c_int,
    info: ?*const std.c.siginfo_t,
    scp: ?*const Ucontext,
    trinfo: *const TrapRecoveryInfo,
    new_stack_pointer: ?[*]obj.SchemeObject,
) noreturn {
    const saved_mask = abi.Registers[abi.regblock_int_mask];
    abi.setInterruptMask(0);

    const handler = if (obj.vectorP(abi.fixed_objects))
        obj.vectorRef(abi.fixed_objects, abi.fixobj_trap_handler)
    else
        obj.sharp_f;
    if (!utils.interpreter_applicable_p(handler)) {
        const err_stream = abi.cStderr();
        writeFileStr(err_stream, "There is no trap handler for recovery!\n");
        _ = abi.fflush(err_stream);
        abi.termination_trap();
    }

    const signal_name = if (signo != 0)
        string.char_pointer_to_string(abi.find_signal_name(signo))
    else
        obj.sharp_f;

    if (!abi.freeOkP(abi.Free)) {
        abi.requestGc(0);
    }

    if (new_stack_pointer) |sp| {
        abi.stack_pointer = sp;
    } else {
        abi.initializeStack();
        abi.stackCheck(abi.cont_size);
        abi.pushCont(abi.rc_end_of_computation, obj.sharp_f);
    }

    abi.stackCheck(7 + abi.cont_size);
    abi.stackPush(trinfo.extra_trap_info);
    abi.stackPush(trinfo.pc_info_2);
    abi.stackPush(trinfo.pc_info_1);
    abi.stackPush(trinfo.state);
    abi.stackPush(obj.booleanToObject(new_stack_pointer != null));
    abi.stackPush(findSignalCodeName(signo, info, scp));
    abi.stackPush(signal_name);
    abi.pushCont(abi.rc_hardware_trap, abi.long_to_integer(signo));

    if (new_stack_pointer != null and trinfo.state == state_compiled_code) {
        utils.stop_history();
    }
    utils.history_register = utils.make_dummy_history();

    abi.stackCheck(3);
    abi.stackPush(signal_name);
    abi.stackPush(handler);
    abi.stackPush(abi.makeApplyFrameHeader(2));

    abi.setInterruptMask(saved_mask);
    abi.abort_to_interpreter(abi.prim_apply);
}

fn continueFromTrap(signo: c_int, info: ?*const std.c.siginfo_t, scp: ?*const Ucontext) noreturn {
    var pc = sigcontextPc(scp);
    if (build_options.cc_is_svm) {
        pc = abi.svm_export_instruction_pointer(pc);
    }
    const primitive = abi.Registers[abi.regblock_primitive];
    var block_addr: ?[*]obj.SchemeObject = null;
    var index: c_uint = 0;
    var new_sp: ?[*]obj.SchemeObject = null;
    var recovery_info: TrapRecoveryInfo = undefined;

    switch (classifyPc(pc, &block_addr, &index)) {
        .primitive => {
            new_sp = abi.stack_pointer;
            recovery_info.state = state_primitive;
            recovery_info.pc_info_1 = primitive;
            recovery_info.pc_info_2 = obj.ulongToFixnum(abi.getLexprActuals());
        },
        .heap, .constant, .code => {
            if (build_options.cc_support) {
                if (build_options.cc_is_svm) {
                    new_sp = abi.stack_pointer;
                } else {
                    const schsp = sigcontextSchsp(scp);
                    new_sp = if (schsp != 0) @ptrFromInt(schsp) else null;
                    abi.Free = @ptrFromInt(sigcontextRfree(scp));
                }
                const blk = block_addr.?;
                recovery_info.state = state_compiled_code;
                recovery_info.pc_info_1 = obj.makeCcBlock(blk);
                recovery_info.pc_info_2 = obj.longToUnsignedFixnum(@intCast(pc - @intFromPtr(blk)));
            } else {
                unreachable;
            }
        },
        .utility => {
            if (build_options.cc_support) {
                new_sp = abi.stack_pointer;
                recovery_info.state = state_utility;
                recovery_info.pc_info_1 = obj.ulongToFixnum(index);
                recovery_info.pc_info_2 = obj.unspecific;
            } else {
                unreachable;
            }
        },
        .builtin => {
            if (build_options.cc_support) {
                const schsp = sigcontextSchsp(scp);
                new_sp = if (schsp != 0) @ptrFromInt(schsp) else null;
                abi.Free = @ptrFromInt(sigcontextRfree(scp));
                recovery_info.state = state_builtin;
                recovery_info.pc_info_1 = obj.ulongToFixnum(index);
                recovery_info.pc_info_2 = obj.unspecific;
            } else {
                unreachable;
            }
        },
        .unknown => {
            if (obj.primitiveP(primitive) and
                abi.addressInStackP(abi.stack_pointer) and alignedP(abi.stack_pointer) and
                abi.addressInHeapP(abi.Free) and alignedP(abi.Free))
            {
                if (build_options.debugging and storage.gc_debug) {
                    outf.errLine(";Warning: trap at 0x{x} assumed a primitive", .{pc});
                }
                new_sp = abi.stack_pointer;
                recovery_info.state = state_primitive;
                recovery_info.pc_info_1 = primitive;
                recovery_info.pc_info_2 = obj.ulongToFixnum(abi.getLexprActuals());
            } else {
                new_sp = null;
                recovery_info.state = state_unknown;
                recovery_info.pc_info_1 = obj.longToUnsignedFixnum(@bitCast(pc));
                recovery_info.pc_info_2 = obj.unspecific;
            }
        },
    }

    if (new_sp) |sp| {
        if (!(abi.addressInStackP(sp) and alignedP(sp))) {
            new_sp = null;
        }
    }

    if (new_sp == null or !abi.addressInHeapP(abi.Free) or !alignedP(abi.Free)) {
        if (build_options.debugging and storage.gc_debug) {
            if (new_sp == null) {
                outf.errLine(";Warning: bogus stack_pointer in continue_from_trap", .{});
            } else {
                outf.errLine(";Warning: bogus Free in continue_from_trap", .{});
            }
        }
        abi.Free = abi.heap_alloc_limit;
    }

    recovery_info.extra_trap_info = obj.makePointerObject(obj.tc_non_marked_vector, abi.Free);
    abi.Free[0] = obj.makeNmvHeader(@intCast(2 + sigcontext_nregs));
    abi.Free[1] = pc;
    abi.Free[2] = sigcontextSp(scp);
    abi.Free += 3;
    if (sigcontextFirstReg(scp)) |regs| {
        @memcpy(abi.Free[0..sigcontext_nregs], regs[0..sigcontext_nregs]);
    } else {
        @memset(abi.Free[0..sigcontext_nregs], 0);
    }
    abi.Free += sigcontext_nregs;

    setupTrapFrame(signo, info, scp, &recovery_info, new_sp);
}

fn trapNormalTermination() noreturn {
    trap_state = .exitting_soft;
    abi.termination_trap();
}

fn trapImmediateTermination() noreturn {
    trap_state = .exitting_hard;
    abi.OS_restore_external_state();
    std.c._exit(1);
}

fn trapDumpCore() noreturn {
    if (!option.option_disable_core_dump) {
        abi.UX_dump_core();
        trapImmediateTermination();
    }
    const out = abi.cStdout();
    writeFileStr(out, ">> Core dumps are disabled - Terminating normally.\n");
    _ = abi.fflush(out);
    abi.termination_trap();
}

fn trapRecover() noreturn {
    jit.jit_force_execute_mode();
    if (boot.critical_section_name != null) {
        boot.critical_section_hook_p = false;
        boot.critical_section_name = null;
    }
    abi.reset_interruptable_extent();
    continueFromTrap(saved_signo, saved_info, saved_scp);
}

/// Initialize signal code table and trap recovery state (`UX_initialize_trap_recovery`).
pub fn uxInitializeTrapRecovery() callconv(.c) void {
    trap_state = .recover;
    user_trap_state = .recover;
    initializeUxSignalCodes();
}

/// Set user and active trap recovery mode, returning previous user mode (`OS_set_trap_state`).
pub fn osSetTrapState(state: TrapState) callconv(.c) TrapState {
    const old_trap_state = user_trap_state;
    user_trap_state = state;
    trap_state = state;
    return old_trap_state;
}

/// Perform user-requested hard reset from interactive signal prompt (`hard_reset`).
pub fn hardReset(scp: ?*const Ucontext) callconv(.c) noreturn {
    continueFromTrap(0, null, scp);
}

/// Perform synchronous soft reset out of a critical section (`soft_reset`).
pub fn softReset() callconv(.c) noreturn {
    var trinfo: TrapRecoveryInfo = undefined;
    const new_sp: ?[*]obj.SchemeObject = if (@intFromPtr(abi.stack_pointer) >= @intFromPtr(abi.stack_guard))
        abi.stack_pointer
    else
        null;
    const primitive = abi.Registers[abi.regblock_primitive];
    if (primitive != obj.sharp_f) {
        trinfo.state = state_primitive;
        trinfo.pc_info_1 = primitive;
        trinfo.pc_info_2 = obj.ulongToFixnum(abi.getLexprActuals());
        trinfo.extra_trap_info = obj.sharp_f;
    } else {
        trinfo.state = state_unknown;
        trinfo.pc_info_1 = obj.sharp_f;
        trinfo.pc_info_2 = obj.sharp_f;
        trinfo.extra_trap_info = obj.sharp_f;
    }
    if (!abi.addressInHeapP(abi.Free)) {
        abi.Free = abi.heap_alloc_limit;
    }
    setupTrapFrame(0, null, null, &trinfo, new_sp);
}

/// Find compiled code block containing native/SVM `pc`, or `#F` (`find_ccblock`).
pub fn findCcblock(pc: usize) callconv(.c) obj.SchemeObject {
    var block_addr: ?[*]obj.SchemeObject = null;
    var index: c_uint = 0;
    _ = classifyPc(pc, &block_addr, &index);
    return if (block_addr) |blk| obj.makeCcBlock(blk) else obj.sharp_f;
}

/// Hardware/software trap signal dispatcher (`trap_handler`).
pub fn trapHandler(
    message: [*:0]const u8,
    signo: c_int,
    info: ?*std.c.siginfo_t,
    scp: ?*Ucontext,
) callconv(.c) void {
    const code: c_int = if (info) |si| si.code else 0;
    const stack_overflowed = abi.stackOverflowedP();
    const old_trap_state = trap_state;
    const out = abi.cStdout();

    if (old_trap_state == .exitting_hard) std.c._exit(1);
    if (old_trap_state == .exitting_soft) trapImmediateTermination();
    trap_state = .trapped;

    if (boot.critical_section_name) |cs_name| {
        writeFmt(out, "\n>> A {s} has occurred within critical section \"{s}\".\n", .{
            std.mem.span(message),
            std.mem.span(cs_name),
        });
        writeFmt(out, ">> [signal {d} ({s}), code {d}]\n", .{
            signo,
            std.mem.span(abi.find_signal_name(signo)),
            code,
        });
    } else if (stack_overflowed or old_trap_state != .recover) {
        writeFmt(out, "\n>> A {s} has occurred.\n", .{std.mem.span(message)});
        writeFmt(out, ">> [signal {d} ({s}), code {d}]\n", .{
            signo,
            std.mem.span(abi.find_signal_name(signo)),
            code,
        });
    }
    if (stack_overflowed) {
        writeFileStr(out, ">> The stack has overflowed overwriting adjacent memory.\n");
        writeFileStr(out, ">> This was probably caused by a runaway recursion.\n");
    }
    _ = abi.fflush(out);

    switch (old_trap_state) {
        .trapped => {
            if (saved_trap_state == .recover or saved_trap_state == .query) {
                const prev_code: c_int = if (saved_info) |si| si.code else 0;
                writeFileStr(out, ">> The trap occurred while processing an earlier trap.\n");
                writeFmt(out, ">> [The earlier trap raised signal {d} ({s}), code {d}.]\n", .{
                    saved_signo,
                    std.mem.span(abi.find_signal_name(saved_signo)),
                    prev_code,
                });
                writeFmt(out, ">> Successful recovery is {s}unlikely.\n", .{
                    if (boot.critical_section_name != null) "extremely " else "",
                });
            } else {
                trapImmediateTermination();
            }
        },
        .recover => {
            if (boot.critical_section_name != null or stack_overflowed) {
                writeFileStr(out, ">> Successful recovery is unlikely.\n");
            } else {
                saved_trap_state = old_trap_state;
                saved_signo = signo;
                saved_info = info;
                saved_scp = scp;
                trapRecover();
            }
        },
        .exit => abi.termination_trap(),
        else => {},
    }

    _ = abi.fflush(out);
    saved_trap_state = old_trap_state;
    saved_signo = signo;
    saved_info = info;
    saved_scp = scp;

    const trap_query_choices = [_]?[*:0]const u8{
        "D = dump core",
        "I = terminate immediately",
        "N = terminate normally",
        "R = attempt recovery",
        "Q = terminate normally",
        null,
    };
    while (true) {
        switch (abi.userio_choose_option(
            "Choose one of the following actions:",
            "Action -> ",
            &trap_query_choices,
        )) {
            'I' => trapImmediateTermination(),
            'D' => trapDumpCore(),
            0, 'N', 'Q' => trapNormalTermination(),
            'R' => trapRecover(),
            else => {},
        }
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&uxInitializeTrapRecovery, .{ .name = "UX_initialize_trap_recovery" });
        @export(&osSetTrapState, .{ .name = "OS_set_trap_state" });
        @export(&hardReset, .{ .name = "hard_reset" });
        @export(&softReset, .{ .name = "soft_reset" });
        if (build_options.cc_support) {
            @export(&findCcblock, .{ .name = "find_ccblock" });
        }
        @export(&trapHandler, .{ .name = "trap_handler" });
    }
}

fn legacySlice(s: obj.SchemeObject) []const u8 {
    return obj.legacyStringData(s)[0..@intCast(obj.legacyStringLength(s))];
}

test "uxtrap initialization, signal codes, and compiled block classification" {
    stubs.resetMockRuntime();
    uxInitializeTrapRecovery();

    try std.testing.expectEqual(TrapState.recover, osSetTrapState(.query));
    try std.testing.expectEqual(TrapState.query, osSetTrapState(.recover));

    var si: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
    if (builtin.os.tag.isDarwin()) {
        si.code = 1; // FPE_FLTDIV
        const fpe_pair = findSignalCodeName(@backingInt(std.c.SIG.FPE), &si, null);
        try std.testing.expect(obj.pairP(fpe_pair));
        try std.testing.expectEqualStrings("Floating-point divide by zero", legacySlice(obj.pairCdr(fpe_pair)));

        si.code = 2; // SEGV_ACCERR
        const segv_pair = findSignalCodeName(@backingInt(std.c.SIG.SEGV), &si, null);
        try std.testing.expectEqualStrings("Invalid permissions for mapped object", legacySlice(obj.pairCdr(segv_pair)));

        si.code = 0x10002; // SI_QUEUE
        const q_pair = findSignalCodeName(@backingInt(std.c.SIG.USR1), &si, null);
        try std.testing.expectEqualStrings("signal sent by sigqueue", legacySlice(obj.pairCdr(q_pair)));
    } else if (builtin.os.tag == .linux) {
        si.code = 3; // FPE_FLTDIV
        const fpe_pair = findSignalCodeName(@backingInt(std.c.SIG.FPE), &si, null);
        try std.testing.expectEqualStrings("floating-point divide by 0 trap", legacySlice(obj.pairCdr(fpe_pair)));

        si.code = -1; // SI_QUEUE
        const q_pair = findSignalCodeName(@backingInt(std.c.SIG.USR1), &si, null);
        try std.testing.expectEqualStrings("signal sent by sigqueue", legacySlice(obj.pairCdr(q_pair)));
    }

    const null_pair = findSignalCodeName(@backingInt(std.c.SIG.SEGV), null, null);
    try std.testing.expectEqual(obj.fixnum_zero, obj.pairCar(null_pair));
    try std.testing.expectEqual(obj.sharp_f, obj.pairCdr(null_pair));

    if (build_options.cc_support) {
        try std.testing.expectEqual(obj.sharp_f, findCcblock(0));
        if (build_options.cc_is_native and builtin.cpu.arch == .aarch64) {
            try std.testing.expectEqual(obj.sharp_f, findCcblock(1));
        }

        const base = abi.heap_start;
        base[0] = obj.makeVectorHeader(4);
        base[1] = obj.makeNmvHeader(2);
        base[2] = 0;
        base[3] = 0;
        base[4] = obj.sharp_f;
        abi.Free = base + 5;
        storage.Free = abi.Free;

        const target_pc: usize = @intFromPtr(base + 3);
        try std.testing.expectEqual(obj.makeCcBlock(base), findCcblock(target_pc));
    }
}
