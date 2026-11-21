const std = @import("std");

const ArchOption = enum {
    auto,
    aarch64le,
    x86_64,
    svm1_64le,
    none,
};

const TermcapOption = enum {
    ncurses,
    emulate,
    none,
};

const ArchConfig = struct {
    scheme_arch: []const u8,
    cmpintmd: []const u8,
    cmpauxmd: ?[]const u8,
    is_native: bool,
    is_svm: bool,
    cc_arch_id: c_uint,
};

fn resolveArch(option: ArchOption, cpu: std.Target.Cpu) ArchConfig {
    const resolved: ArchOption = switch (option) {
        .auto => switch (cpu.arch) {
            .aarch64 => .aarch64le,
            .x86_64 => .x86_64,
            else => .svm1_64le,
        },
        else => option,
    };

    return switch (resolved) {
        .auto => unreachable,
        .aarch64le => .{
            .scheme_arch = "aarch64le",
            .cmpintmd = "aarch64",
            .cmpauxmd = "aarch64",
            .is_native = true,
            .is_svm = false,
            .cc_arch_id = 15,
        },
        .x86_64 => .{
            .scheme_arch = "x86-64",
            .cmpintmd = "x86-64",
            .cmpauxmd = "x86-64",
            .is_native = true,
            .is_svm = false,
            .cc_arch_id = 14,
        },
        .svm1_64le => .{
            .scheme_arch = "svm1-64le",
            .cmpintmd = "svm1",
            .cmpauxmd = null,
            .is_native = false,
            .is_svm = true,
            .cc_arch_id = 13,
        },
        .none => .{
            .scheme_arch = "none",
            .cmpintmd = "none",
            .cmpauxmd = null,
            .is_native = false,
            .is_svm = false,
            .cc_arch_id = 0,
        },
    };
}

const std_c_sources = [_][]const u8{
    "src/microcode/interp.c",
    "src/microcode/outf.c",
    "src/microcode/term.c",
};

const zig_prim_sources = [_][]const u8{
    "src/microcode/zig/bigprm.zig",
    "src/microcode/zig/bitstr.zig",
    "src/microcode/zig/boot.zig",
    "src/microcode/zig/bytevector.zig",
    "src/microcode/zig/char.zig",
    "src/microcode/zig/comutl.zig",
    "src/microcode/zig/daemon.zig",
    "src/microcode/zig/debug.zig",
    "src/microcode/zig/dfloat.zig",
    "src/microcode/zig/extern_prim.zig",
    "src/microcode/zig/fasdump.zig",
    "src/microcode/zig/fasload.zig",
    "src/microcode/zig/fixnum.zig",
    "src/microcode/zig/floenv.zig",
    "src/microcode/zig/flonum.zig",
    "src/microcode/zig/generic.zig",
    "src/microcode/zig/hooks.zig",
    "src/microcode/zig/hunk.zig",
    "src/microcode/zig/intern.zig",
    "src/microcode/zig/intprm.zig",
    "src/microcode/zig/list.zig",
    "src/microcode/zig/lookprm.zig",
    "src/microcode/zig/memmag.zig",
    "src/microcode/zig/prchacha.zig",
    "src/microcode/zig/prentropy.zig",
    "src/microcode/zig/prim.zig",
    "src/microcode/zig/prkeccak.zig",
    "src/microcode/zig/prmd5.zig",
    "src/microcode/zig/prosenv.zig",
    "src/microcode/zig/prosfile.zig",
    "src/microcode/zig/prosfs.zig",
    "src/microcode/zig/prosio.zig",
    "src/microcode/zig/prosproc.zig",
    "src/microcode/zig/prospty.zig",
    "src/microcode/zig/prosterm.zig",
    "src/microcode/zig/prostty.zig",
    "src/microcode/zig/pruxdld.zig",
    "src/microcode/zig/pruxenv.zig",
    "src/microcode/zig/pruxffi.zig",
    "src/microcode/zig/pruxfs.zig",
    "src/microcode/zig/pruxio.zig",
    "src/microcode/zig/pruxsock.zig",
    "src/microcode/zig/purify.zig",
    "src/microcode/zig/purutl.zig",
    "src/microcode/zig/rgxprim.zig",
    "src/microcode/zig/step.zig",
    "src/microcode/zig/string.zig",
    "src/microcode/zig/syntax.zig",
    "src/microcode/zig/sysprim.zig",
    "src/microcode/zig/vector.zig",
};

const config_h_bottom =
    \\#ifndef SCM_CONFIG_H
    \\#define SCM_CONFIG_H
    \\
    \\#include "config_defs.h"
    \\
    \\#ifndef __unix__
    \\#  define __unix__
    \\#endif
    \\
    \\#define _GNU_SOURCE
    \\
    \\#include <sys/types.h>
    \\
    \\#include <time.h>
    \\#ifdef HAVE_SYS_TIME_H
    \\#  include <sys/time.h>
    \\#endif
    \\
    \\#ifdef HAVE_TERMIOS_H
    \\#  include <termios.h>
    \\#else
    \\#  ifdef HAVE_TERMIO_H
    \\#    include <termio.h>
    \\#  endif
    \\#endif
    \\
    \\#ifdef HAVE_SYS_MMAN_H
    \\#  include <sys/mman.h>
    \\#endif
    \\
    \\#ifdef HAVE_MMAP
    \\#  if defined(MAP_ANON) && !defined(MAP_ANONYMOUS)
    \\#    define MAP_ANONYMOUS MAP_ANON
    \\#  endif
    \\#  ifdef MAP_ANONYMOUS
    \\#    define USE_MMAP_HEAP_MALLOC
    \\#  endif
    \\#endif
    \\
    \\#include "confshared.h"
    \\
    \\#endif /* SCM_CONFIG_H */
    \\
;

fn flag(cond: bool) ?i64 {
    return if (cond) 1 else null;
}

fn addMicrocodeConfig(
    b: *std.Build,
    resolved: std.Build.ResolvedTarget,
    termcap: TermcapOption,
) std.Build.LazyPath {
    const t = resolved.result;
    const is_darwin = t.os.tag.isDarwin();
    const is_linux = t.os.tag == .linux;
    const is_gnu = t.abi.isGnu();
    const ptr_bytes: i64 = @intCast(t.ptrBitWidth() / 8);
    const long_bytes: i64 = @intCast((t.cTypeBitSize(.long) orelse t.ptrBitWidth()) / 8);
    const int_bytes: i64 = @intCast((t.cTypeBitSize(.int) orelse 32) / 8);
    const short_bytes: i64 = @intCast((t.cTypeBitSize(.short) orelse 16) / 8);
    const is_big_endian = t.cpu.arch.endian() == .big;

    const use_termcap = termcap != .none;
    const have_ncurses_headers = termcap == .ncurses;

    // On macOS Apple Silicon (Darwin), MAP_JIT + pthread_jit_write_protect_np +
    // sys_icache_invalidate are always present on arm64 SDKs.
    const is_apple_jit = is_darwin and t.cpu.arch == .aarch64;

    const package_version = "13.0.50";
    const defs_header = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "config_defs.h",
        .include_guard = "SCM_CONFIG_DEFS_H",
    }, .{
        .PACKAGE_BUGREPORT = "bug-mit-scheme@gnu.org",
        .PACKAGE_NAME = "MIT/GNU Scheme",
        .PACKAGE_STRING = "MIT/GNU Scheme " ++ package_version,
        .PACKAGE_TARNAME = "mit-scheme",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = package_version,

        .PROTOTYPES = @as(i64, 1),
        .__PROTOTYPES = @as(i64, 1),
        .STDC_HEADERS = @as(i64, 1),
        .HAVE_STRINGIZE = @as(i64, 1),
        .HAVE_C_BACKSLASH_A = @as(i64, 1),
        .HAVE__BOOL = @as(i64, 1),
        .HAVE_LONG_LONG_INT = @as(i64, 1),
        .HAVE_UNSIGNED_LONG_LONG_INT = @as(i64, 1),

        .SIZEOF_CHAR = @as(i64, 1),
        .SIZEOF_UNSIGNED_CHAR = @as(i64, 1),
        .SIZEOF_SHORT = short_bytes,
        .SIZEOF_UNSIGNED_SHORT = short_bytes,
        .SIZEOF_INT = int_bytes,
        .SIZEOF_UNSIGNED_INT = int_bytes,
        .SIZEOF_LONG = long_bytes,
        .SIZEOF_UNSIGNED_LONG = long_bytes,
        .SIZEOF_VOID_P = ptr_bytes,
        .SIZEOF_INTPTR_T = ptr_bytes,
        .SIZEOF_UINTPTR_T = ptr_bytes,
        .SIZEOF_INTMAX_T = @as(i64, 8),
        .SIZEOF_UINTMAX_T = @as(i64, 8),
        .SIZEOF_TIME_T = @as(i64, 8),
        .SIZEOF_OFF_T = @as(i64, 8),

        .WORDS_BIGENDIAN = flag(is_big_endian),

        // Types & time
        .HAVE_INTTYPES_H = @as(i64, 1),
        .HAVE_STDINT_H = @as(i64, 1),
        .HAVE_STDBOOL_H = @as(i64, 1),
        .HAVE_STDIO_H = @as(i64, 1),
        .HAVE_STDLIB_H = @as(i64, 1),
        .HAVE_STRING_H = @as(i64, 1),
        .HAVE_STRINGS_H = @as(i64, 1),
        .HAVE_INTPTR_T = @as(i64, 1),
        .HAVE_UINTPTR_T = @as(i64, 1),
        .HAVE_INTMAX_T = @as(i64, 1),
        .HAVE_UINTMAX_T = @as(i64, 1),
        .HAVE_STRUCT_TM_TM_ZONE = @as(i64, 1),
        .HAVE_TM_ZONE = @as(i64, 1),
        .HAVE_TM_GMTOFF = @as(i64, 1),
        .TM_GMTOFF = .tm_gmtoff,
        .HAVE_TZNAME = @as(i64, 1),
        .HAVE_TIMEZONE = flag(!is_darwin),
        .TIMEZONE = null,

        // Standard POSIX headers
        .HAVE_DIRENT_H = @as(i64, 1),
        .HAVE_DLFCN_H = @as(i64, 1),
        .HAVE_FCNTL_H = @as(i64, 1),
        .HAVE_FENV_H = @as(i64, 1),
        .HAVE_FENV_T = @as(i64, 1),
        .HAVE_FEXCEPT_T = @as(i64, 1),
        .HAVE_NETDB_H = @as(i64, 1),
        .HAVE_HOSTENT_H_ADDR_LIST = @as(i64, 1),
        .HAVE_POLL_H = @as(i64, 1),
        .HAVE_PTHREAD_H = @as(i64, 1),
        .HAVE_SYS_FILE_H = @as(i64, 1),
        .HAVE_SYS_IOCTL_H = @as(i64, 1),
        .HAVE_SYS_MMAN_H = @as(i64, 1),
        .HAVE_SYS_MOUNT_H = flag(is_darwin or is_linux),
        .HAVE_SYS_PARAM_H = @as(i64, 1),
        .HAVE_SYS_SOCKET_H = @as(i64, 1),
        .HAVE_SYS_STAT_H = @as(i64, 1),
        .HAVE_SYS_TIME_H = @as(i64, 1),
        .HAVE_SYS_TYPES_H = @as(i64, 1),
        .HAVE_SYS_UN_H = @as(i64, 1),
        .HAVE_SYS_UTSNAME_H = @as(i64, 1),
        .HAVE_SYS_WAIT_H = @as(i64, 1),
        .HAVE_TERMIOS_H = @as(i64, 1),
        .HAVE_UNISTD_H = @as(i64, 1),
        .HAVE_UTIME_H = @as(i64, 1),

        // Darwin / Linux specific headers
        .HAVE_LIBKERN_OSCACHECONTROL_H = flag(is_darwin),
        .HAVE_UTIL_H = flag(is_darwin),
        .HAVE_MALLOC_H = flag(is_linux),
        .HAVE_SYS_TIMEX_H = flag(is_linux),
        .HAVE_SYS_VFS_H = flag(is_linux),
        .HAVE_STRUCT_NTPTIMEVAL = flag(is_linux and is_gnu),
        .HAVE_NTPTIMEVAL_TAI = flag(is_linux and is_gnu),
        .HAVE_NTPTIMEVAL_TIME_TV_NSEC = null,
        .HAVE_STRUCT_TIMEX = flag(is_linux and is_gnu),
        .HAVE_TIMEX_TAI = flag(is_linux and is_gnu),
        .HAVE_TIMEX_TIME_TV_USEC = flag(is_linux and is_gnu),

        // Absent / intentionally unused legacy headers
        .HAVE_BSDTTY_H = null,
        .HAVE_IEEEFP_H = null,
        .HAVE_NDIR_H = null,
        .HAVE_SGTTY_H = null,
        .HAVE_STROPTS_H = null,
        .HAVE_STRUCT_LTCHARS = null,
        .HAVE_STRUCT_SIGCONTEXT = null,
        .HAVE_SYS_DIR_H = null,
        .HAVE_SYS_NDIR_H = null,
        .HAVE_SYS_PTYIO_H = null,
        .HAVE_TERMIO_H = null,
        .HAVE_VFORK_H = null,
        .HAVE_DOPRNT = null,
        .TM_IN_SYS_TIME = null,
        .HAVE_FPGETROUND_FPSETROUND = null,

        // Process & environment declarations
        .GETPGRP_VOID = @as(i64, 1),
        .SETPGRP_VOID = @as(i64, 1),
        .HAVE_GETPGRP = @as(i64, 1),
        .HAVE_SETPGRP = @as(i64, 1),
        .HAVE_SETPGRP2 = null,
        .HAVE_DECL_ENVIRON = @as(i64, if (is_linux) 1 else 0),
        .HAVE_DECL___ENVIRON = @as(i64, if (is_linux and is_gnu) 1 else 0),
        .HAVE_DECL_TZNAME = @as(i64, 1),

        // POSIX functions
        .HAVE_CLOCK_GETTIME = @as(i64, 1),
        .HAVE_CTERMID = @as(i64, 1),
        .HAVE_DUP2 = @as(i64, 1),
        .HAVE_EXPM1 = @as(i64, 1),
        .HAVE_FCNTL = @as(i64, 1),
        .HAVE_FLOOR = @as(i64, 1),
        .HAVE_FMA = @as(i64, 1),
        .HAVE_FMOD = @as(i64, 1),
        .HAVE_FORK = @as(i64, 1),
        .HAVE_WORKING_FORK = @as(i64, 1),
        .HAVE_VFORK = flag(is_linux),
        .HAVE_WORKING_VFORK = flag(is_linux),
        .HAVE_FPATHCONF = @as(i64, 1),
        .HAVE_FREXP = @as(i64, 1),
        .HAVE_FSYNC = @as(i64, 1),
        .HAVE_FTRUNCATE = @as(i64, 1),
        .HAVE_GETCWD = @as(i64, 1),
        .HAVE_GETHOSTBYNAME = @as(i64, 1),
        .HAVE_GETHOSTNAME = @as(i64, 1),
        .HAVE_GETLOGIN = @as(i64, 1),
        .HAVE_GETPAGESIZE = @as(i64, 1),
        .HAVE_GETTIMEOFDAY = @as(i64, 1),
        .HAVE_GRANTPT = @as(i64, 1),
        .HAVE_KILL = @as(i64, 1),
        .HAVE_LGAMMA_R = @as(i64, 1),
        .HAVE_LIBM = @as(i64, 1),
        .HAVE_LOG1P = @as(i64, 1),
        .HAVE_MADVISE = @as(i64, 1),
        .HAVE_MEMCPY = @as(i64, 1),
        .HAVE_MKDIR = @as(i64, 1),
        .HAVE_MKTIME = @as(i64, 1),
        .HAVE_MMAP = @as(i64, 1),
        .HAVE_MODF = @as(i64, 1),
        .HAVE_NICE = @as(i64, 1),
        .HAVE_POLL = @as(i64, 1),
        .HAVE_POSIX_MADVISE = @as(i64, 1),
        .HAVE_POSIX_OPENPT = @as(i64, 1),
        .HAVE_PSELECT = @as(i64, 1),
        .HAVE_RENAME = @as(i64, 1),
        .HAVE_RMDIR = @as(i64, 1),
        .HAVE_SELECT = @as(i64, 1),
        .HAVE_SETITIMER = @as(i64, 1),
        .HAVE_SIGACTION = @as(i64, 1),
        .HAVE_SIGSUSPEND = @as(i64, 1),
        .HAVE_SOCKET = @as(i64, 1),
        .HAVE_STATFS = @as(i64, 1),
        .HAVE_STRCHR = @as(i64, 1),
        .HAVE_STRERROR = @as(i64, 1),
        .HAVE_STRTOUL = @as(i64, 1),
        .HAVE_SYMLINK = @as(i64, 1),
        .HAVE_SYSCONF = @as(i64, 1),
        .HAVE_TIMES = @as(i64, 1),
        .HAVE_TRUNCATE = @as(i64, 1),
        .HAVE_UTIME = @as(i64, 1),
        .HAVE_UTIME_NULL = @as(i64, 1),
        .HAVE_VPRINTF = @as(i64, 1),
        .HAVE_WAITPID = @as(i64, 1),
        .HAVE_LONG_FILE_NAMES = @as(i64, 1),

        // Leave legacy SIGHOLD and GETWD undefined to use sigaction and getcwd.
        .HAVE_SIGHOLD = null,
        .HAVE_GETWD = null,

        // Standard C99 <fenv.h> functions
        .HAVE_FECLEAREXCEPT = @as(i64, 1),
        .HAVE_FEGETENV = @as(i64, 1),
        .HAVE_FEGETEXCEPTFLAG = @as(i64, 1),
        .HAVE_FEGETROUND = @as(i64, 1),
        .HAVE_FEHOLDEXCEPT = @as(i64, 1),
        .HAVE_FERAISEEXCEPT = @as(i64, 1),
        .HAVE_FESETENV = @as(i64, 1),
        .HAVE_FESETEXCEPTFLAG = @as(i64, 1),
        .HAVE_FESETROUND = @as(i64, 1),
        .HAVE_FETESTEXCEPT = @as(i64, 1),
        .HAVE_FEUPDATEENV = @as(i64, 1),

        // GNU extensions & platform-specific syscalls
        .HAVE_CLOSEFROM = null,
        .HAVE_POLLTS = null,
        .HAVE_FSYNC_RANGE = null,
        .HAVE_OPENPTY = flag(is_darwin),
        .HAVE_MAP_JIT = flag(is_darwin),
        .HAVE_PTHREAD_JIT_WRITE_PROTECT_NP = flag(is_darwin),
        .HAVE_SYS_ICACHE_INVALIDATE = flag(is_darwin),
        .SCM_JIT_APPLE = flag(is_apple_jit),

        .HAVE_FDATASYNC = flag(is_linux),
        .HAVE_PPOLL = flag(is_linux),
        .HAVE_SYNC_FILE_RANGE = flag(is_linux),
        .HAVE_LIBDL = flag(is_linux),
        .HAVE_GETPT = flag(is_linux and is_gnu),
        .HAVE_FEENABLEEXCEPT = flag(is_linux and is_gnu),
        .HAVE_FEDISABLEEXCEPT = flag(is_linux and is_gnu),
        .HAVE_FEGETEXCEPT = flag(is_linux and is_gnu),
        .HAVE_NTP_ADJTIME = flag(is_linux and is_gnu),
        .HAVE_NTP_GETTIME = flag(is_linux and is_gnu),

        // Dynamic loading & termcap
        .UX_DLD_ENABLED = @as(i64, 1),
        .USE_TERMCAP = flag(use_termcap),
        .HAVE_NCURSES_H = flag(have_ncurses_headers),
        .HAVE_CURSES_H = flag(have_ncurses_headers),
        .HAVE_TERM_H = flag(have_ncurses_headers),
        .HAVE_TERMCAP_H = flag(have_ncurses_headers),
    });
    if (!is_darwin) {
        defs_header.addIdent("TIMEZONE", "timezone");
    }

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(defs_header.getOutputFile(), "config_defs.h");
    _ = wf.add("config.h", config_h_bottom);
    return wf.getDirectory();
}

fn configureMicrocodeModule(
    b: *std.Build,
    mod: *std.Build.Module,
    resolved: std.Build.ResolvedTarget,
    config_dir: std.Build.LazyPath,
    arch_headers_dir: std.Build.LazyPath,
    termcap: TermcapOption,
) void {
    const t = resolved.result;
    mod.addIncludePath(config_dir);
    mod.addIncludePath(arch_headers_dir);
    mod.addIncludePath(b.path("src/microcode"));

    if (t.os.tag.isDarwin()) {
        mod.linkFramework("CoreFoundation", .{});
    } else if (t.os.tag == .linux) {
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("dl", .{});
    }

    if (termcap == .ncurses) {
        mod.linkSystemLibrary("ncurses", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const arch_opt = b.option(
        ArchOption,
        "arch",
        "Native-code / microcode architecture (default: auto)",
    ) orelse .auto;

    const termcap_opt = b.option(
        TermcapOption,
        "termcap",
        "Terminal capability provider: ncurses (default), emulate, or none",
    ) orelse .ncurses;

    const debugging = b.option(
        bool,
        "debugging",
        "Enable microcode debugging checks (ENABLE_DEBUGGING_TOOLS)",
    ) orelse false;

    const valgrind = b.option(
        bool,
        "valgrind",
        "Enable Valgrind support (VALGRIND_MODE)",
    ) orelse false;

    const host_scheme = b.option(
        []const u8,
        "host-scheme",
        "Optional host mit-scheme binary passed to bootstrap step",
    );

    const check_library_path = b.option(
        []const u8,
        "check-library-path",
        "Scheme library directory containing all.com for `zig build check-zig`",
    );

    const test_suite = b.option(
        []const u8,
        "test-suite",
        "Optional single tests/check.scm suite name for `zig build check-zig`",
    );

    const arch = resolveArch(arch_opt, target.result.cpu);
    const auxdir_name = b.fmt("mit-scheme-{s}-13.0.50", .{arch.scheme_arch});
    const default_library_path = b.option(
        []const u8,
        "library-path",
        "Compile-time DEFAULT_LIBRARY_PATH baked into scheme",
    ) orelse b.fmt("/usr/local/lib/{s}", .{auxdir_name});

    const target_config_dir = addMicrocodeConfig(b, target, termcap_opt);

    const arch_headers = b.addWriteFiles();
    _ = arch_headers.add(
        "cmpintmd.h",
        b.fmt("#include \"cmpintmd/{s}.h\"\n", .{arch.cmpintmd}),
    );
    _ = arch_headers.add(
        "cmpintmd-config.h",
        b.fmt("#include \"cmpintmd/{s}-config.h\"\n", .{arch.cmpintmd}),
    );
    const arch_headers_dir = arch_headers.getDirectory();

    var c_flags_list: std.ArrayList([]const u8) = .empty;
    c_flags_list.appendSlice(b.allocator, &.{
        "-DHAVE_CONFIG_H",
        "-DMIT_SCHEME",
        b.fmt("-DDEFAULT_LIBRARY_PATH=\"{s}\"", .{default_library_path}),
        "-fno-builtin-floor",
        "-Wall",
        "-Wempty-body",
        "-Wignored-qualifiers",
        "-Wimplicit-fallthrough",
        "-Wmissing-field-initializers",
        "-Wnested-externs",
        "-Wpointer-arith",
        "-Wredundant-decls",
        "-Wshift-negative-value",
        "-Wstrict-prototypes",
        "-Wtype-limits",
        "-Wundef",
        "-Wuninitialized",
        "-Wwrite-strings",
    }) catch @panic("OOM");

    if (target.result.os.tag.isDarwin()) {
        c_flags_list.appendSlice(b.allocator, &.{
            "-fconstant-cfstrings",
            "-DSIGNAL_HANDLERS_CAN_USE_SCHEME_STACK",
            "-D_REENTRANT",
        }) catch @panic("OOM");
    } else if (target.result.os.tag == .linux) {
        c_flags_list.append(b.allocator, "-D_init=__executable_start") catch @panic("OOM");
        if (target.result.abi.isMusl()) {
            c_flags_list.append(b.allocator, "-DMUSL") catch @panic("OOM");
        }
    }

    if (debugging) {
        c_flags_list.append(b.allocator, "-DENABLE_DEBUGGING_TOOLS") catch @panic("OOM");
    }
    if (valgrind) {
        c_flags_list.append(b.allocator, "-DVALGRIND_MODE") catch @panic("OOM");
    }
    const c_flags = c_flags_list.items;

    // Assemble optional microcode C source list.
    var scheme_c_sources: std.ArrayList([]const u8) = .empty;
    scheme_c_sources.appendSlice(b.allocator, &std_c_sources) catch @panic("OOM");

    switch (termcap_opt) {
        .ncurses => {},
        .emulate => scheme_c_sources.append(b.allocator, "src/microcode/tparam.c") catch @panic("OOM"),
        .none => {},
    }

    // Build host-native Zig findprim and generate usrdef.zig out-of-tree.
    const findprim = b.addExecutable(.{
        .name = "findprim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/microcode/zig/findprim.zig"),
            .target = b.graph.host,
            .optimize = .fast,
        }),
    });

    const fp_run = b.addRunArtifact(findprim);
    fp_run.addArgs(&.{ "--zig", "-o" });
    const usrdef_zig = fp_run.addOutputFileArg("usrdef.zig");
    for (zig_prim_sources) |src_rel| {
        fp_run.addFileArg(b.path(src_rel));
    }
    if (termcap_opt != .none) {
        fp_run.addFileArg(b.path("src/microcode/zig/tterm.zig"));
    }

    const cmpauxmd_s: ?std.Build.LazyPath = if (arch.cmpauxmd) |asm_arch|
        b.path(b.fmt("src/microcode/cmpauxmd/{s}.S", .{asm_arch}))
    else
        null;

    const zig_options = b.addOptions();
    zig_options.addOption(bool, "cc_is_native", arch.is_native);
    zig_options.addOption(bool, "cc_is_svm", arch.is_svm);
    zig_options.addOption(bool, "cc_support", arch.is_native or arch.is_svm);
    zig_options.addOption(bool, "debugging", debugging);
    zig_options.addOption(bool, "use_termcap", termcap_opt != .none);
    zig_options.addOption(bool, "use_terminfo", termcap_opt == .ncurses);
    zig_options.addOption([]const u8, "package_version", "13.0.50");
    zig_options.addOption([]const u8, "default_library_path", default_library_path);
    zig_options.addOption(c_uint, "compiler_processor_type", arch.cc_arch_id);

    const microcode_zig_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    microcode_zig_mod.addOptions("build_options", zig_options);
    const microcode_zig_obj = b.addObject(.{
        .name = "microcode_zig",
        .root_module = microcode_zig_mod,
    });

    const scheme_obj_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/scheme_obj.zig"),
        .target = target,
        .optimize = optimize,
    });
    const usrdef_zig_mod = b.createModule(.{
        .root_source_file = usrdef_zig,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    usrdef_zig_mod.addOptions("build_options", zig_options);
    usrdef_zig_mod.addImport("scheme_obj", scheme_obj_mod);
    const usrdef_zig_obj = b.addObject(.{
        .name = "usrdef_zig",
        .root_module = usrdef_zig_mod,
    });

    // Build the microcode `scheme` binary.
    const scheme_exe = b.addExecutable(.{
        .name = auxdir_name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    // Export all microcode symbols and disable linker GC/dead-stripping so
    // dlopen()-loaded FFI plugins (pruxffi.h helpers like arg_alien_entry,
    // arg_long, is_alien, etc.) resolve in both Debug and ReleaseFast builds.
    scheme_exe.rdynamic = true;
    scheme_exe.link_gc_sections = false;
    configureMicrocodeModule(
        b,
        scheme_exe.root_module,
        target,
        target_config_dir,
        arch_headers_dir,
        termcap_opt,
    );
    scheme_exe.root_module.addObject(microcode_zig_obj);
    scheme_exe.root_module.addCSourceFiles(.{
        .files = scheme_c_sources.items,
        .flags = c_flags,
    });
    if (termcap_opt == .emulate) {
        var termcap_flags: std.ArrayList([]const u8) = .empty;
        termcap_flags.appendSlice(b.allocator, c_flags) catch @panic("OOM");
        termcap_flags.appendSlice(b.allocator, &.{
            "-std=gnu89",
            "-Wno-deprecated-non-prototype",
            "-Wno-incompatible-pointer-types-discards-qualifiers",
            "-Wno-implicit-function-declaration",
            "-Wno-return-type",
            "-Wno-pointer-to-int-cast",
            "-Wno-unused-variable",
        }) catch @panic("OOM");
        scheme_exe.root_module.addCSourceFile(.{
            .file = b.path("src/microcode/termcap.c"),
            .flags = termcap_flags.items,
        });
    }
    scheme_exe.root_module.addObject(usrdef_zig_obj);
    if (cmpauxmd_s) |asm_file| {
        scheme_exe.root_module.addCSourceFile(.{
            .file = asm_file,
            .flags = &.{},
            .language = .assembly_with_preprocessor,
        });
    }

    b.installArtifact(scheme_exe);
    b.getInstallStep().dependOn(&b.addInstallBinFile(scheme_exe.getEmittedBin(), "mit-scheme").step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(scheme_exe.getEmittedBin(), "scheme").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("src/microcode/pruxffi.h"),
        .prefix,
        b.fmt("lib/{s}/mit-scheme.h", .{auxdir_name}),
    ).step);

    if (target.result.os.tag.isDarwin()) {
        const starter = b.addExecutable(.{
            .name = "macosx-starter",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/microcode/zig/macosx_starter.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        starter.root_module.linkFramework("CoreFoundation", .{});
        b.getInstallStep().dependOn(&b.addInstallArtifact(starter, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("lib/{s}", .{auxdir_name}) } },
        }).step);
    }

    // `zig build run -- <args>`
    const run_step = b.step("run", "Run the Zig-built mit-scheme binary");
    const run_scheme = b.addRunArtifact(scheme_exe);
    run_scheme.addPassthruArgs();
    run_step.dependOn(&run_scheme.step);

    // `zig build test-smoke`
    const smoke_runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/smoke_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_runtime_mod.addOptions("build_options", zig_options);
    const smoke_runtime_obj = b.addObject(.{
        .name = "smoke_runtime",
        .root_module = smoke_runtime_mod,
    });
    const fasl_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/fasl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fasl_smoke_mod.addOptions("build_options", zig_options);
    const fasl_smoke_obj = b.addObject(.{
        .name = "fasl_smoke",
        .root_module = fasl_smoke_mod,
    });
    const gcloop_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/gcloop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gcloop_smoke_mod.addOptions("build_options", zig_options);
    const gcloop_smoke_obj = b.addObject(.{
        .name = "gcloop_smoke",
        .root_module = gcloop_smoke_mod,
    });
    const cmpintmd_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/cmpintmd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cmpintmd_smoke_mod.addOptions("build_options", zig_options);
    const cmpintmd_smoke_obj = b.addObject(.{
        .name = "cmpintmd_smoke",
        .root_module = cmpintmd_smoke_mod,
    });
    const cmpint_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/cmpint.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cmpint_smoke_mod.addOptions("build_options", zig_options);
    const cmpint_smoke_obj = b.addObject(.{
        .name = "cmpint_smoke",
        .root_module = cmpint_smoke_mod,
    });
    const smoke_step = b.step("test-smoke", "Build and run standalone microcode C smoke tests");
    const smoke_specs = [_]struct {
        name: []const u8,
        src: []const u8,
        deps: []const []const u8,
        needs_cmpint: bool,
        needs_cmpintmd: bool,
        needs_native: bool,
        needs_fasl: bool,
        needs_gcloop: bool,
    }{
        .{
            .name = "jit-smoke",
            .src = "tests/microcode/jit-smoke.c",
            .deps = &.{},
            .needs_cmpint = false,
            .needs_cmpintmd = true,
            .needs_native = false,
            .needs_fasl = false,
            .needs_gcloop = false,
        },
        .{
            .name = "arena-smoke",
            .src = "tests/microcode/arena-smoke.c",
            .deps = &.{},
            .needs_cmpint = false,
            .needs_cmpintmd = false,
            .needs_native = false,
            .needs_fasl = false,
            .needs_gcloop = false,
        },
        .{
            .name = "gc-arena-smoke",
            .src = "tests/microcode/gc-arena-smoke.c",
            .deps = &.{},
            .needs_cmpint = false,
            .needs_cmpintmd = true,
            .needs_native = false,
            .needs_fasl = false,
            .needs_gcloop = true,
        },
        .{
            .name = "fasl-code-smoke",
            .src = "tests/microcode/fasl-code-smoke.c",
            .deps = &.{},
            .needs_cmpint = false,
            .needs_cmpintmd = true,
            .needs_native = false,
            .needs_fasl = true,
            .needs_gcloop = true,
        },
        .{
            .name = "trampoline-smoke",
            .src = "tests/microcode/trampoline-smoke.c",
            .deps = &.{},
            .needs_cmpint = true,
            .needs_cmpintmd = true,
            .needs_native = true,
            .needs_fasl = false,
            .needs_gcloop = true,
        },
    };

    for (smoke_specs) |spec| {
        if (spec.needs_native and !arch.is_native) continue;
        const smoke_exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_c = .off,
            }),
        });
        smoke_exe.root_module.addIncludePath(target_config_dir);
        smoke_exe.root_module.addIncludePath(arch_headers_dir);
        smoke_exe.root_module.addIncludePath(b.path("src/microcode"));
        if (target.result.os.tag == .linux) {
            smoke_exe.root_module.linkSystemLibrary("m", .{});
        }
        smoke_exe.root_module.addObject(smoke_runtime_obj);
        if (spec.needs_fasl) {
            smoke_exe.root_module.addObject(fasl_smoke_obj);
        }
        if (spec.needs_gcloop) {
            smoke_exe.root_module.addObject(gcloop_smoke_obj);
        }
        smoke_exe.root_module.addCSourceFile(.{ .file = b.path(spec.src), .flags = c_flags });
        if (spec.needs_cmpintmd) {
            smoke_exe.root_module.addObject(cmpintmd_smoke_obj);
        }
        if (spec.needs_cmpint) {
            smoke_exe.root_module.addObject(cmpint_smoke_obj);
        }
        smoke_exe.root_module.addCSourceFiles(.{ .files = spec.deps, .flags = c_flags });
        if (spec.needs_native) {
            if (cmpauxmd_s) |asm_file| {
                smoke_exe.root_module.addCSourceFile(.{
                    .file = asm_file,
                    .flags = &.{},
                    .language = .assembly_with_preprocessor,
                });
            }
        }
        const run_smoke = b.addRunArtifact(smoke_exe);
        smoke_step.dependOn(&run_smoke.step);
    }

    // `zig build test-unit`
    const unit_test_step = b.step("test-unit", "Run Zig microcode unit tests");
    const unit_tests = b.addTest(.{
        .name = "microcode-zig-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/microcode/zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addOptions("build_options", zig_options);
    if (target.result.os.tag.isDarwin()) {
        unit_tests.root_module.linkFramework("CoreFoundation", .{});
    }
    unit_test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const findprim_tests = b.addTest(.{
        .name = "findprim-unit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/microcode/zig/findprim.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    unit_test_step.dependOn(&b.addRunArtifact(findprim_tests).step);

    if (target.result.os.tag.isDarwin()) {
        const starter_tests = b.addTest(.{
            .name = "macosx-starter-unit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/microcode/zig/macosx_starter.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        starter_tests.root_module.linkFramework("CoreFoundation", .{});
        unit_test_step.dependOn(&b.addRunArtifact(starter_tests).step);
    }

    // `zig build bootstrap`
    const bootstrap_step = b.step(
        "bootstrap",
        "Run full Stage 1/2/3 Scheme bootstrap & CI suite via tests/ci/bootstrap-and-test.sh",
    );
    const bootstrap_cmd = b.addSystemCommand(&.{"./tests/ci/bootstrap-and-test.sh"});
    bootstrap_cmd.setCwd(b.path("."));
    if (host_scheme) |hs| {
        bootstrap_cmd.addArgs(&.{ "--host-scheme", hs });
    }
    bootstrap_cmd.addPassthruArgs();
    bootstrap_step.dependOn(&bootstrap_cmd.step);

    // `zig build check`
    const check_step = b.step("check", "Run Scheme test suite against built src/");
    const check_cmd = b.addSystemCommand(&.{
        "python3",
        "tests/ci/check-results.py",
        "--src-dir",
        "src",
        "--allow-arm64-flonum-except",
    });
    check_cmd.setCwd(b.path("."));
    check_step.dependOn(&check_cmd.step);

    // `zig build check-zig`
    const check_zig_step = b.step(
        "check-zig",
        "Run Scheme test suite using the Zig-built mit-scheme binary",
    );
    const check_zig_cmd = b.addSystemCommand(&.{
        "python3",
        "tests/ci/check-results.py",
        "--src-dir",
        "src",
        "--allow-arm64-flonum-except",
        "--scheme-exe",
    });
    check_zig_cmd.addFileArg(scheme_exe.getEmittedBin());
    if (check_library_path) |lib_path| {
        check_zig_cmd.addArgs(&.{ "--library-path", lib_path });
    }
    if (test_suite) |suite| {
        check_zig_cmd.addArgs(&.{ "--test", suite });
    }
    check_zig_cmd.setCwd(b.path("."));
    check_zig_step.dependOn(&check_zig_cmd.step);

    // `zig build macos-app` & `zig build macos-dmg`
    if (target.result.os.tag.isDarwin()) {
        const app_step = b.step("macos-app", "Build MIT/GNU Scheme macOS .app bundle");
        const app_cmd = b.addSystemCommand(&.{"./src/etc/macosx/make-app.sh"});
        app_cmd.setCwd(b.path("."));
        app_step.dependOn(&app_cmd.step);

        const dmg_step = b.step("macos-dmg", "Build distributable Apple Silicon .dmg installer");
        const dmg_cmd = b.addSystemCommand(&.{
            "./tests/ci/build-macos-dmg.sh",
            "--src-dir",
            "src",
            "--out-dir",
            "build-dmg",
            "--clean",
        });
        dmg_cmd.setCwd(b.path("."));
        dmg_step.dependOn(&dmg_cmd.step);
    }
}
