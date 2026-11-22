const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const chacha = @import("chacha.zig");
pub const outf = @import("outf.zig");
pub const win_api = @import("win_api.zig");
pub const keccak = @import("keccak.zig");
pub const md5 = @import("md5.zig");
pub const obstack = @import("obstack.zig");
pub const wind = @import("wind.zig");
pub const transact = @import("transact.zig");
pub const ptrvec = @import("ptrvec.zig");
pub const avltree = @import("avltree.zig");
pub const jit = @import("jit.zig");
pub const scheme_obj = @import("scheme_obj.zig");
pub const code_arena = @import("code_arena.zig");
pub const cmpint = @import("cmpint.zig");
pub const cmpintmd = @import("cmpintmd.zig");
pub const svm1_interp = @import("svm1_interp.zig");
pub const prim_abi = @import("prim_abi.zig");
pub const prchacha = @import("prchacha.zig");
pub const prkeccak = @import("prkeccak.zig");
pub const prmd5 = @import("prmd5.zig");
pub const prentropy = @import("prentropy.zig");
pub const bytevector = @import("bytevector.zig");
pub const char = @import("char.zig");
pub const hunk = @import("hunk.zig");
pub const dfloat = @import("dfloat.zig");
pub const list = @import("list.zig");
pub const vector = @import("vector.zig");
pub const bits = @import("bits.zig");
pub const fixnum = @import("fixnum.zig");
pub const generic = @import("generic.zig");
pub const bignum = @import("bignum.zig");
pub const artutl = @import("artutl.zig");
pub const bigprm = @import("bigprm.zig");
pub const intprm = @import("intprm.zig");
pub const fenv_plat = @import("fenv_plat.zig");
pub const floenv = @import("floenv.zig");
pub const flonum = @import("flonum.zig");
pub const bitstr = @import("bitstr.zig");
pub const string = @import("string.zig");
pub const intern = @import("intern.zig");
pub const edwin_defs = @import("edwin_defs.zig");
pub const syntax = @import("syntax.zig");
pub const regex = @import("regex.zig");
pub const rgxprim = @import("rgxprim.zig");
pub const bkpt = @import("bkpt.zig");
pub const daemon = @import("daemon.zig");
pub const step = @import("step.zig");
pub const extern_prim = @import("extern_prim.zig");
pub const sysprim = @import("sysprim.zig");
pub const error_cond = @import("error_cond.zig");
pub const prim = @import("prim.zig");
pub const primutl = @import("primutl.zig");
pub const purutl = @import("purutl.zig");
pub const ostty = @import("ostty.zig");
pub const osscheme = @import("osscheme.zig");
pub const returns = @import("returns.zig");
pub const storage = @import("storage.zig");
pub const utabmd = @import("utabmd.zig");
pub const purify = @import("purify.zig");
pub const lookprm = @import("lookprm.zig");
pub const hooks = @import("hooks.zig");
pub const fasl = @import("fasl.zig");
pub const utils = @import("utils.zig");
pub const memmag = @import("memmag.zig");
pub const boot = @import("boot.zig");
pub const comutl = @import("comutl.zig");
pub const option = @import("option.zig");
pub const lookup = @import("lookup.zig");
pub const fasload = @import("fasload.zig");
pub const fasdump = @import("fasdump.zig");
pub const debug = @import("debug.zig");
pub const gcloop = @import("gcloop.zig");
pub const prosio = @import("prosio.zig");
pub const prosfile = @import("prosfile.zig");
pub const prosfs = @import("prosfs.zig");
pub const prosenv = @import("prosenv.zig");
pub const prostty = @import("prostty.zig");
pub const prosterm = @import("prosterm.zig");
pub const prospty = @import("prospty.zig");
pub const prosproc = @import("prosproc.zig");
pub const pruxdld = @import("pruxdld.zig");
pub const pruxenv = @import("pruxenv.zig");
pub const pruxffi = @import("pruxffi.zig");
pub const pruxfs = @import("pruxfs.zig");
pub const pruxio = @import("pruxio.zig");
pub const pruxsock = @import("pruxsock.zig");
pub const os_backend = if (builtin.os.tag == .windows) struct {
    pub const win_top = @import("win_top.zig");
    pub const win_io = @import("win_io.zig");
    pub const win_fs = @import("win_fs.zig");
    pub const win_env = @import("win_env.zig");
    pub const win_tty = @import("win_tty.zig");
    pub const win_proc = @import("win_proc.zig");
    pub const win_sock = @import("win_sock.zig");
} else struct {
    pub const ux = @import("ux.zig");
    pub const uxctty = @import("uxctty.zig");
    pub const uxentropy = @import("uxentropy.zig");
    pub const uxenv = @import("uxenv.zig");
    pub const uxfile = @import("uxfile.zig");
    pub const uxfs = @import("uxfs.zig");
    pub const uxio = @import("uxio.zig");
    pub const uxproc = @import("uxproc.zig");
    pub const uxsig = @import("uxsig.zig");
    pub const uxsock = @import("uxsock.zig");
    pub const uxterm = @import("uxterm.zig");
    pub const uxtop = @import("uxtop.zig");
    pub const uxtrap = @import("uxtrap.zig");
    pub const uxtty = @import("uxtty.zig");
    pub const uxutil = @import("uxutil.zig");
};
pub const tterm = if (build_options.use_termcap) @import("tterm.zig") else struct {};
pub const termcap_emulate = @import("termcap_emulate.zig");
pub const intext = @import("intext.zig");
pub const interp = @import("interp.zig");
pub const term = @import("term.zig");

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
        _ = @import("test_stubs.zig");
    }
}

test "microcode zig scaffold" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(os_backend);
}
