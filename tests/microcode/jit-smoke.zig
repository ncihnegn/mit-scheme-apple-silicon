// Standalone W^X smoke test for jit.zig / MAP_JIT on Apple silicon.
// Derived from tests/microcode/jit-smoke.c (GPL v2 or later).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const abi = @import("prim_abi");
const smoke = @import("smoke_common.zig");

var free_storage: ?[*]smoke.SchemeObject = null;
var constant_start_storage: ?[*]smoke.SchemeObject = null;

fn passthroughAddr(addr: ?*anyopaque) callconv(.c) ?*anyopaque {
    return addr;
}

comptime {
    smoke.exportBaseRuntimeStubs();
    smoke.exportSvmCcTypeStubs();
    if (smoke.is_native_aarch64) {
        @export(&free_storage, .{ .name = "Free" });
        @export(&constant_start_storage, .{ .name = "constant_start" });
        @export(&passthroughAddr, .{ .name = "tospace_to_newspace" });
        @export(&passthroughAddr, .{ .name = "newspace_to_tospace" });
        @export(&smoke.stubDecodeOldStyleFormatWord, .{ .name = "decode_old_style_format_word" });
        @export(&smoke.stubEncodeOldStyleFormatWord, .{ .name = "encode_old_style_format_word" });
    }
}

extern "c" fn scm_setjmp_try(env_slot: *?*anyopaque, body: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) c_int;
extern "c" fn scm_longjmp(env: ?*anyopaque, code: c_int) noreturn;

const DarwinJit = struct {
    extern "c" fn pthread_jit_write_protect_supported_np() c_int;
    extern "c" fn raise(sig: c_int) c_int;
};

var sigusr1_env: ?*anyopaque = null;
var sigusr1_seen: c_int = 0;

fn sigusr1Handler(_: std.c.SIG) callconv(.c) void {
    sigusr1_seen = 1;
    scm_longjmp(sigusr1_env, 1);
}

var rx_fault_env: ?*anyopaque = null;
var rx_fault_seen: c_int = 0;

fn rxFaultHandler(_: std.c.SIG) callconv(.c) void {
    rx_fault_seen = 1;
    scm_longjmp(rx_fault_env, 1);
}

fn rxFaultAttempt(ctx: ?*anyopaque) callconv(.c) void {
    const target: *volatile u32 = @ptrCast(@alignCast(ctx.?));
    target.* = 0;
}

fn rxWriteFaults(target: *volatile u32) bool {
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = rxFaultHandler },
        .mask = undefined,
        .flags = std.c.SA.NODEFER,
    };
    _ = std.c.sigemptyset(&sa.mask);
    var old_bus: std.c.Sigaction = undefined;
    var old_segv: std.c.Sigaction = undefined;
    smoke.check(std.c.sigaction(.BUS, &sa, &old_bus) == 0, "sigaction SIGBUS");
    smoke.check(std.c.sigaction(.SEGV, &sa, &old_segv) == 0, "sigaction SIGSEGV");

    rx_fault_seen = 0;
    _ = scm_setjmp_try(&rx_fault_env, rxFaultAttempt, @ptrCast(@volatileCast(target)));

    smoke.check(std.c.sigaction(.BUS, &old_bus, null) == 0, "restore SIGBUS");
    smoke.check(std.c.sigaction(.SEGV, &old_segv, null) == 0, "restore SIGSEGV");
    return rx_fault_seen != 0;
}

fn triggerUsr1(_: ?*anyopaque) callconv(.c) void {
    smoke.jit_write_begin();
    smoke.check(smoke.jit_write_nesting_depth() == 1, "depth == 1 before raise");
    _ = DarwinJit.raise(@intFromEnum(std.c.SIG.USR1));
    std.c.abort();
}

const jit_smoke_total: c_int = if (smoke.is_native_aarch64) 9 else 6;

pub fn main() u8 {
    const region_size: usize = 65536;
    smoke.dstack_initialize();

    smoke.check(smoke.jit_available_p(), "jit_available_p()");
    smoke.check(smoke.jit_page_size() >= 4096, "jit_page_size >= 4096");

    // 1. Map code space.
    const code = smoke.jit_map_code_space(region_size) orelse {
        smoke.check(false, "jit_map_code_space != null");
        unreachable;
    };
    smoke.check(smoke.jit_write_nesting_depth() == 0, "depth == 0");
    smoke.printf("[1/{d}] jit_map_code_space OK (0x{x}, page={d})\n", .{
        jit_smoke_total,
        @intFromPtr(code),
        smoke.jit_page_size(),
    });

    if (comptime smoke.is_native_aarch64) {
        const AddFn = *const fn (c_int) callconv(.c) c_int;
        const insns: [*]volatile u32 = @ptrCast(@alignCast(code));
        const func: AddFn = @ptrCast(@alignCast(code));

        // 2. Nested write brackets, emit `add w0, w0, #42; ret`, flush, execute.
        smoke.jit_write_begin();
        smoke.check(smoke.jit_write_nesting_depth() == 1, "depth == 1");
        smoke.jit_write_begin();
        smoke.check(smoke.jit_write_nesting_depth() == 2, "depth == 2");
        insns[0] = 0x1100a800; // add w0, w0, #42
        insns[1] = 0xd65f03c0; // ret
        abi.jit_flush_icache(code, 2 * @sizeOf(u32));
        smoke.jit_write_end();
        smoke.check(smoke.jit_write_nesting_depth() == 1, "depth == 1");
        smoke.jit_write_end();
        smoke.check(smoke.jit_write_nesting_depth() == 0, "depth == 0");
        smoke.check(func(10) == 52, "func(10) == 52");
        smoke.printf("[2/{d}] nested write brackets + execute add #42 OK\n", .{jit_smoke_total});

        // 3. Self-modification over cached line: patch to `add w0, w0, #100`.
        smoke.jit_write_begin();
        insns[0] = 0x11019000; // add w0, w0, #100
        abi.jit_flush_icache(code, @sizeOf(u32));
        smoke.jit_write_end();
        smoke.check(smoke.jit_write_nesting_depth() == 0, "depth == 0");
        smoke.check(func(10) == 110, "func(10) == 110");
        smoke.printf("[3/{d}] patch + icache invalidate + re-execute #100 OK\n", .{jit_smoke_total});

        if (comptime smoke.is_apple_jit) {
            const jit_wp_supported = DarwinJit.pthread_jit_write_protect_supported_np();

            // 4. Confirm RX enforcement via hardware fault in RX mode.
            if (jit_wp_supported != 0) {
                smoke.check(rxWriteFaults(&insns[2]), "RX write faults");
                smoke.printf("[4/{d}] RX hardware write fault verified\n", .{jit_smoke_total});
            } else {
                smoke.printf("[4/{d}] skipped RX hardware write fault (pthread_jit_write_protect_supported_np() == 0)\n", .{jit_smoke_total});
            }

            // 5. Recover from longjmp inside an open write bracket.
            var sa: std.c.Sigaction = .{
                .handler = .{ .handler = sigusr1Handler },
                .mask = undefined,
                .flags = std.c.SA.NODEFER,
            };
            _ = std.c.sigemptyset(&sa.mask);
            var old_sa: std.c.Sigaction = undefined;
            smoke.check(std.c.sigaction(.USR1, &sa, &old_sa) == 0, "sigaction SIGUSR1");

            sigusr1_seen = 0;
            const jumped = scm_setjmp_try(&sigusr1_env, triggerUsr1, null);
            smoke.check(jumped != 0, "scm_setjmp_try caught longjmp");
            smoke.check(sigusr1_seen == 1, "sigusr1_seen == 1");
            smoke.check(smoke.jit_write_nesting_depth() == 1, "depth still 1 before force execute");
            abi.jit_force_execute_mode();
            smoke.check(smoke.jit_write_nesting_depth() == 0, "depth 0 after force execute");
            smoke.check(func(10) == 110, "func(10) == 110 after recovery");
            if (jit_wp_supported != 0) {
                smoke.check(rxWriteFaults(&insns[2]), "RX enforced after recovery");
            }
            smoke.check(std.c.sigaction(.USR1, &old_sa, null) == 0, "restore SIGUSR1");
            smoke.printf("[5/{d}] siglongjmp APRR_EL0 / jit_force_execute_mode recovery OK\n", .{jit_smoke_total});
        } else {
            smoke.printf("[4/{d}] skipped RX child fault test (non-SCM_JIT_APPLE)\n", .{jit_smoke_total});
            smoke.printf("[5/{d}] skipped siglongjmp APRR_EL0 test (non-SCM_JIT_APPLE)\n", .{jit_smoke_total});
        }

        // 6. dstack scope unwind protection.
        {
            const s1 = smoke.jit_write_scope_begin();
            const s2 = smoke.jit_write_scope_begin();
            smoke.check(smoke.jit_write_nesting_depth() == 2, "scope depth 2");
            smoke.jit_write_scope_end(s2);
            smoke.check(smoke.jit_write_nesting_depth() == 1, "scope depth 1");
            smoke.jit_write_scope_end(s1);
            smoke.check(smoke.jit_write_nesting_depth() == 0, "scope depth 0");

            const outer1 = smoke.dstack_position;
            _ = smoke.jit_write_scope_begin();
            _ = smoke.jit_write_scope_begin();
            smoke.check(smoke.jit_write_nesting_depth() == 2, "bulk scope depth 2");
            smoke.dstack_set_position(outer1);
            smoke.check(smoke.jit_write_nesting_depth() == 0, "bulk unwind depth 0");

            const outer2 = smoke.dstack_position;
            _ = smoke.jit_write_scope_begin();
            smoke.check(smoke.jit_write_nesting_depth() == 1, "post-force scope depth 1");
            abi.jit_force_execute_mode();
            smoke.check(smoke.jit_write_nesting_depth() == 0, "post-force depth 0");
            smoke.dstack_set_position(outer2);
            smoke.check(smoke.jit_write_nesting_depth() == 0, "post-force unwind depth 0");
            smoke.check(func(10) == 110, "func(10) == 110 after scopes");
            smoke.printf("[6/{d}] dstack write-scope unwind OK\n", .{jit_smoke_total});
        }

        // 7-9. Native AArch64 UUO dispatch tests (near, far br x1, RW NX closure).
        {
            const UuoFn = *const fn (u64, u64, *u64) callconv(.c) u64;
            const far_size: usize = 144 * 1024 * 1024;
            const far_code = smoke.jit_map_code_space(far_size).?;
            const far_base: [*]u8 = @ptrCast(far_code);
            const saddr: [*]smoke.SchemeObject = @ptrCast(@alignCast(far_base));
            const uuo_entry: UuoFn = @ptrCast(@alignCast(@as([*]u32, @ptrCast(saddr)) + 3));

            const near_hdr: *i64 = @ptrCast(@alignCast(far_base + 64));
            const target_near: [*]u32 = @ptrCast(@alignCast(far_base + 72));
            const target_closure_rx: [*]u32 = @ptrCast(@alignCast(far_base + 128));
            const far_hdr: *i64 = @ptrCast(@alignCast(far_base + (136 * 1024 * 1024)));
            const target_far: [*]u32 = @ptrCast(@alignCast(far_base + (136 * 1024 * 1024) + 8));

            smoke.jit_write_begin();
            near_hdr.* = 0;
            target_near[0] = 0xf9000041; // str x1, [x2]
            target_near[1] = 0x11001c00; // add w0, w0, #7
            target_near[2] = 0xd65f03c0; // ret

            target_closure_rx[0] = 0xf9000041; // str x1, [x2]
            target_closure_rx[1] = 0x11005c00; // add w0, w0, #23
            target_closure_rx[2] = 0xd65f03c0; // ret

            far_hdr.* = 0;
            target_far[0] = 0xf9000041; // str x1, [x2]
            target_far[1] = 0x11004c00; // add w0, w0, #19
            target_far[2] = 0xd65f03c0; // ret

            abi.jit_flush_icache(far_code, 256);
            abi.jit_flush_icache(target_far, 3 * @sizeOf(u32));

            // 7. Near open procedure (<= 128 MiB): b target_near.
            abi.write_uuo_target(target_near, saddr);
            abi.aarch64_flush_i_cache_region(saddr, smoke.uuo_link_size);
            smoke.check((@as([*]u32, @ptrCast(saddr))[4] & 0xfc000000) == 0x14000000, "uuo near B");
            smoke.jit_write_end();

            var seen_x1: u64 = 0;
            smoke.check(uuo_entry(100, 0, &seen_x1) == 107, "uuo near return 107");
            smoke.check(seen_x1 == @intFromPtr(target_near), "uuo near x1 == target_near");
            smoke.printf("[7/{d}] write_uuo_target near open procedure OK\n", .{jit_smoke_total});

            // 8. Far open procedure (> 128 MiB): br x1.
            smoke.jit_write_begin();
            abi.write_uuo_target(target_far, saddr);
            abi.aarch64_flush_i_cache_region(saddr, smoke.uuo_link_size);
            smoke.check(@as([*]u32, @ptrCast(saddr))[4] == 0xd61f0020, "uuo far br x1");
            smoke.jit_write_end();

            seen_x1 = 0;
            smoke.check(uuo_entry(100, 0, &seen_x1) == 119, "uuo far return 119");
            smoke.check(seen_x1 == @intFromPtr(target_far), "uuo far x1 == target_far");
            smoke.printf("[8/{d}] write_uuo_target far br x1 (>128 MiB) OK\n", .{jit_smoke_total});

            // 9. Split RW NX closure target -> RX code entry with x1 == closure_entry.
            const raw_cls = std.c.malloc(4 * @sizeOf(smoke.SchemeObject)).?;
            const rw_closure: [*]smoke.SchemeObject = @ptrCast(@alignCast(raw_cls));
            @memset(rw_closure[0..4], 0);
            const closure_entry: [*]u32 = @ptrCast(rw_closure + 2);
            const cls_pc_off_ptr: *i64 = @ptrFromInt(@intFromPtr(closure_entry) - @sizeOf(i64));
            const target_addr: isize = @bitCast(@intFromPtr(target_closure_rx));
            const entry_addr: isize = @bitCast(@intFromPtr(closure_entry));
            cls_pc_off_ptr.* = @intCast(target_addr - entry_addr);

            smoke.jit_write_begin();
            abi.write_uuo_target(closure_entry, saddr);
            abi.aarch64_flush_i_cache_region(saddr, smoke.uuo_link_size);
            smoke.check(@as([*]u32, @ptrCast(saddr))[4] == 0xd1002031, "uuo closure indirect");
            smoke.jit_write_end();

            seen_x1 = 0;
            smoke.check(uuo_entry(100, 0, &seen_x1) == 123, "uuo closure return 123");
            smoke.check(seen_x1 == @intFromPtr(closure_entry), "uuo closure x1 == closure_entry");
            std.c.free(raw_cls);

            // Verify aarch64_reset_hook() and aarch64_flush_i_cache().
            smoke.jit_write_begin();
            smoke.check(smoke.jit_write_nesting_depth() == 1, "depth 1 before reset_hook");
            abi.aarch64_reset_hook();
            smoke.check(smoke.jit_write_nesting_depth() == 0, "depth 0 after reset_hook");
            constant_start_storage = @ptrCast(@alignCast(far_code));
            free_storage = constant_start_storage.? + 8;
            abi.aarch64_flush_i_cache();
            free_storage = null;
            constant_start_storage = null;

            smoke.jit_unmap_code_space(far_code, far_size);
            smoke.printf("[9/{d}] write_uuo_target split RW NX closure -> RX OK\n", .{jit_smoke_total});
        }
    } else {
        const rw: [*]volatile u32 = @ptrCast(@alignCast(code));
        smoke.jit_write_begin();
        smoke.check(smoke.jit_write_nesting_depth() == 1, "depth == 1");
        smoke.jit_write_begin();
        smoke.check(smoke.jit_write_nesting_depth() == 2, "depth == 2");
        rw[0] = 0x12345678;
        abi.jit_flush_icache(code, @sizeOf(u32));
        smoke.jit_write_end();
        smoke.check(smoke.jit_write_nesting_depth() == 1, "depth == 1");
        smoke.jit_write_end();
        smoke.check(smoke.jit_write_nesting_depth() == 0, "depth == 0");
        smoke.check(rw[0] == 0x12345678, "rw[0] == 0x12345678");
        smoke.printf("[2-5/{d}] non-native RW code_arena write OK\n", .{jit_smoke_total});

        const s1 = smoke.jit_write_scope_begin();
        const s2 = smoke.jit_write_scope_begin();
        smoke.check(smoke.jit_write_nesting_depth() == 2, "scope depth 2");
        smoke.jit_write_scope_end(s2);
        smoke.check(smoke.jit_write_nesting_depth() == 1, "scope depth 1");
        smoke.jit_write_scope_end(s1);
        smoke.check(smoke.jit_write_nesting_depth() == 0, "scope depth 0");

        const outer = smoke.dstack_position;
        _ = smoke.jit_write_scope_begin();
        smoke.check(smoke.jit_write_nesting_depth() == 1, "depth 1 before force execute");
        abi.jit_force_execute_mode();
        smoke.check(smoke.jit_write_nesting_depth() == 0, "depth 0 after force execute");
        smoke.dstack_set_position(outer);
        smoke.check(smoke.jit_write_nesting_depth() == 0, "depth 0 after unwind");
        smoke.printf("[6/{d}] dstack write-scope unwind OK\n", .{jit_smoke_total});
    }

    smoke.jit_unmap_code_space(code, region_size);
    return 0;
}
