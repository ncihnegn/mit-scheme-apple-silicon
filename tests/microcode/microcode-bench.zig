//! Microcode Zig benchmarks (`zig build bench`).
//!
//! Batched timing with Io.Clock: warmup, then a few timed batches per
//! benchmark, reporting the best batch (closest to the true cost, and
//! immune to scheduler noise that inflates means). Results are folded
//! into a sink and blackboxed with std.mem.doNotOptimizeAway so the
//! compiler cannot eliminate the measured work.
//!
//! Run with `-Doptimize=ReleaseFast`; Debug builds are 10-100x slower.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const targets = @import("microcode_bench");

const chacha = targets.chacha;
const keccak = targets.keccak;
const md5 = targets.md5;

const batches = 5;

fn fillPattern(buf: anytype) void {
    for (0..buf.len) |i| {
        buf[i] = @truncate(i *% 7919 +% 17);
    }
}

/// Times `op(ctx)`: ~10% warmup iterations, then `batches` timed batches
/// of `iters` iterations each, printing the best batch's ns/op and the
/// effective MB/s for `bytes_per_op`.
fn bench(
    io: Io,
    comptime name: []const u8,
    comptime iters: usize,
    comptime bytes_per_op: usize,
    ctx: anytype,
    comptime op: anytype,
) void {
    for (0..iters / 10 + 1) |_| op(ctx);
    var best: u64 = std.math.maxInt(u64);
    for (0..batches) |_| {
        const start = Io.Clock.awake.now(io).nanoseconds;
        for (0..iters) |_| op(ctx);
        const ns: u64 = @intCast(Io.Clock.awake.now(io).nanoseconds - start);
        if (ns < best) best = ns;
        std.mem.doNotOptimizeAway(ctx.sink);
    }
    const ns_per_op = best / iters;
    const mb_per_s = @as(f64, @floatFromInt(bytes_per_op)) /
        @as(f64, @floatFromInt(ns_per_op)) * 1000;
    std.debug.print("{s:<22} {d:>6} B/op {d:>8} ns/op {d:>9.1} MB/s\n", .{
        name, bytes_per_op, ns_per_op, mb_per_s,
    });
}

const ChachaCtx = struct {
    sink: u64 = 0,
    out: [chacha.output_bytes]u8 = undefined,
    in: [chacha.input_bytes]u8 = undefined,
    key: [chacha.key_bytes]u8 = undefined,
    constant: [chacha.const_bytes]u8 = "expand 32-byte k".*,

    fn init() ChachaCtx {
        var self: ChachaCtx = .{};
        fillPattern(&self.in);
        fillPattern(&self.key);
        return self;
    }
};

fn chacha8Op(ctx: *ChachaCtx) void {
    chacha.chacha8_core(&ctx.out, &ctx.in, &ctx.key, &ctx.constant);
    ctx.sink +%= ctx.out[0];
}

fn chacha12Op(ctx: *ChachaCtx) void {
    chacha.chacha12_core(&ctx.out, &ctx.in, &ctx.key, &ctx.constant);
    ctx.sink +%= ctx.out[0];
}

fn chacha20Op(ctx: *ChachaCtx) void {
    chacha.chacha20_core(&ctx.out, &ctx.in, &ctx.key, &ctx.constant);
    ctx.sink +%= ctx.out[0];
}

const KeccakCtx = struct {
    sink: u64 = 0,
    state: [25]u64 = undefined,

    fn init() KeccakCtx {
        var self: KeccakCtx = .{};
        for (0..self.state.len) |i| {
            self.state[i] = 0x1234_5678_9abc_def0 ^
                @as(u64, i) *% 0x9e37_79b9_7f4a_7c15;
        }
        return self;
    }
};

fn keccakOp(ctx: *KeccakCtx) void {
    keccak.keccakf1600(&ctx.state);
    ctx.sink ^= ctx.state[0];
}

const Md5Ctx = struct {
    sink: u64 = 0,
    m: md5.Md5 = undefined,
    buf: [1024]u8 = undefined,
    hash: [md5.hash_len]u8 = undefined,

    fn init() Md5Ctx {
        var self: Md5Ctx = .{};
        fillPattern(&self.buf);
        return self;
    }
};

fn md5Op(ctx: *Md5Ctx) void {
    md5.md5_init(&ctx.m);
    md5.md5_update(&ctx.m, &ctx.buf, ctx.buf.len);
    md5.md5_final(&ctx.m, &ctx.hash);
    ctx.sink +%= ctx.hash[0];
}

fn runSelftests() bool {
    return chacha.chacha8_core_selftest() == 0 and
        chacha.chacha12_core_selftest() == 0 and
        chacha.chacha20_core_selftest() == 0 and
        md5.md5_selftest() == 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    if (builtin.mode == .debug) {
        std.debug.print(
            "warning: Debug build; benchmarks need -Doptimize=ReleaseFast\n\n",
            .{},
        );
    }
    if (!runSelftests()) {
        std.debug.print("selftest FAILED\n", .{});
        std.process.exit(1);
    }
    std.debug.print("microcode-bench ({s}, {s}), selftest OK\n\n", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.mode),
    });

    var chacha_ctx = ChachaCtx.init();
    bench(io, "chacha8_core", 200_000, chacha.output_bytes, &chacha_ctx, chacha8Op);
    bench(io, "chacha12_core", 100_000, chacha.output_bytes, &chacha_ctx, chacha12Op);
    bench(io, "chacha20_core", 100_000, chacha.output_bytes, &chacha_ctx, chacha20Op);
    var keccak_ctx = KeccakCtx.init();
    bench(io, "keccakf1600", 100_000, 200, &keccak_ctx, keccakOp);
    var md5_ctx = Md5Ctx.init();
    bench(io, "md5 1KiB", 20_000, md5_ctx.buf.len, &md5_ctx, md5Op);
}
