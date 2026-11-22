const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Core
pub const scheme_obj = @import("core/scheme_obj.zig");
pub const prim_abi = @import("core/prim_abi.zig");
pub const storage = @import("core/storage.zig");
pub const interp = @import("core/interp.zig");
pub const boot = @import("core/boot.zig");
pub const option = @import("core/option.zig");
pub const term = @import("core/term.zig");
pub const utils = @import("core/utils.zig");
pub const utabmd = @import("core/utabmd.zig");

// Runtime
pub const lookup = @import("runtime/lookup.zig");
pub const lookprm = @import("runtime/lookprm.zig");
pub const intern = @import("runtime/intern.zig");
pub const returns = @import("runtime/returns.zig");
pub const hooks = @import("runtime/hooks.zig");
pub const prim = @import("runtime/prim.zig");
pub const primutl = @import("runtime/primutl.zig");
pub const extern_prim = @import("runtime/extern_prim.zig");
pub const sysprim = @import("runtime/sysprim.zig");
pub const daemon = @import("runtime/daemon.zig");
pub const debug = @import("runtime/debug.zig");
pub const bkpt = @import("runtime/bkpt.zig");
pub const step = @import("runtime/step.zig");

// GC & FASL
pub const gcloop = @import("gc/gcloop.zig");
pub const memmag = @import("gc/memmag.zig");
pub const purify = @import("gc/purify.zig");
pub const purutl = @import("gc/purutl.zig");
pub const fasl = @import("gc/fasl.zig");
pub const fasload = @import("gc/fasload.zig");
pub const fasdump = @import("gc/fasdump.zig");

// Compiler & JIT
pub const cmpint = @import("compiler/cmpint.zig");
pub const cmpintmd = @import("compiler/cmpintmd.zig");
pub const svm1_interp = @import("compiler/svm1_interp.zig");
pub const code_arena = @import("compiler/code_arena.zig");
pub const jit = @import("compiler/jit.zig");
pub const comutl = @import("compiler/comutl.zig");

// Arithmetic
pub const bits = @import("arith/bits.zig");
pub const artutl = @import("arith/artutl.zig");
pub const fixnum = @import("arith/fixnum.zig");
pub const bignum = @import("arith/bignum.zig");
pub const bigprm = @import("arith/bigprm.zig");
pub const intprm = @import("arith/intprm.zig");
pub const generic = @import("arith/generic.zig");
pub const fenv_plat = @import("arith/fenv_plat.zig");
pub const floenv = @import("arith/floenv.zig");
pub const flonum = @import("arith/flonum.zig");
pub const dfloat = @import("arith/dfloat.zig");

// Data
pub const list = @import("data/list.zig");
pub const vector = @import("data/vector.zig");
pub const hunk = @import("data/hunk.zig");
pub const char = @import("data/char.zig");
pub const string = @import("data/string.zig");
pub const bytevector = @import("data/bytevector.zig");
pub const bitstr = @import("data/bitstr.zig");

// Text
pub const edwin_defs = @import("text/edwin_defs.zig");
pub const syntax = @import("text/syntax.zig");
pub const regex = @import("text/regex.zig");
pub const rgxprim = @import("text/rgxprim.zig");

// Crypto
pub const chacha = @import("crypto/chacha.zig");
pub const prchacha = @import("crypto/prchacha.zig");
pub const keccak = @import("crypto/keccak.zig");
pub const prkeccak = @import("crypto/prkeccak.zig");
pub const md5 = @import("crypto/md5.zig");
pub const prmd5 = @import("crypto/prmd5.zig");
pub const prentropy = @import("crypto/prentropy.zig");

// OS
pub const osscheme = @import("os/osscheme.zig");
pub const ostty = @import("os/ostty.zig");
pub const win_api = @import("os/win/win_api.zig");
pub const termcap_emulate = @import("os/termcap_emulate.zig");
pub const os_backend = if (builtin.os.tag == .windows) struct {
    pub const win_top = @import("os/win/win_top.zig");
    pub const win_io = @import("os/win/win_io.zig");
    pub const win_fs = @import("os/win/win_fs.zig");
    pub const win_env = @import("os/win/win_env.zig");
    pub const win_tty = @import("os/win/win_tty.zig");
    pub const win_proc = @import("os/win/win_proc.zig");
    pub const win_sock = @import("os/win/win_sock.zig");
} else struct {
    pub const ux = @import("os/unix/ux.zig");
    pub const uxctty = @import("os/unix/uxctty.zig");
    pub const uxentropy = @import("os/unix/uxentropy.zig");
    pub const uxenv = @import("os/unix/uxenv.zig");
    pub const uxfile = @import("os/unix/uxfile.zig");
    pub const uxfs = @import("os/unix/uxfs.zig");
    pub const uxio = @import("os/unix/uxio.zig");
    pub const uxproc = @import("os/unix/uxproc.zig");
    pub const uxsig = @import("os/unix/uxsig.zig");
    pub const uxsock = @import("os/unix/uxsock.zig");
    pub const uxterm = @import("os/unix/uxterm.zig");
    pub const uxtop = @import("os/unix/uxtop.zig");
    pub const uxtrap = @import("os/unix/uxtrap.zig");
    pub const uxtty = @import("os/unix/uxtty.zig");
    pub const uxutil = @import("os/unix/uxutil.zig");
};

// Primitives
pub const prosenv = @import("prims/prosenv.zig");
pub const prosfile = @import("prims/prosfile.zig");
pub const prosfs = @import("prims/prosfs.zig");
pub const prosio = @import("prims/prosio.zig");
pub const prosproc = @import("prims/prosproc.zig");
pub const prospty = @import("prims/prospty.zig");
pub const prosterm = @import("prims/prosterm.zig");
pub const prostty = @import("prims/prostty.zig");
pub const pruxdld = @import("prims/pruxdld.zig");
pub const pruxenv = @import("prims/pruxenv.zig");
pub const pruxffi = @import("prims/pruxffi.zig");
pub const pruxfs = @import("prims/pruxfs.zig");
pub const pruxio = @import("prims/pruxio.zig");
pub const pruxsock = @import("prims/pruxsock.zig");
pub const tterm = if (build_options.use_termcap) @import("prims/tterm.zig") else struct {};

// Support
pub const avltree = @import("support/avltree.zig");
pub const error_cond = @import("support/error_cond.zig");
pub const intext = @import("support/intext.zig");
pub const obstack = @import("support/obstack.zig");
pub const outf = @import("support/outf.zig");
pub const ptrvec = @import("support/ptrvec.zig");
pub const transact = @import("support/transact.zig");
pub const wind = @import("support/wind.zig");

comptime {
    for (std.meta.declarations(@This())) |decl_name| {
        if (std.mem.eql(u8, decl_name, "os_backend") or
            std.mem.eql(u8, decl_name, "tterm") or
            std.mem.eql(u8, decl_name, "termcap_emulate"))
        {
            continue;
        }
        _ = @field(@This(), decl_name);
    }
    for (std.meta.declarations(os_backend)) |decl_name| {
        _ = @field(os_backend, decl_name);
    }
    if (build_options.use_termcap) {
        _ = tterm;
        if (!build_options.use_terminfo) {
            _ = termcap_emulate;
        }
    }
    if (builtin.is_test) {
        _ = @import("core/test_stubs.zig");
    }
}

test "microcode zig scaffold" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(os_backend);
}
