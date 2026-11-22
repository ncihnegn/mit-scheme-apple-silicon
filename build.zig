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
            .cmpauxmd = "aarch64",
            .is_native = true,
            .is_svm = false,
            .cc_arch_id = 15,
        },
        .x86_64 => .{
            .scheme_arch = "x86-64",
            .cmpauxmd = "x86-64",
            .is_native = true,
            .is_svm = false,
            .cc_arch_id = 14,
        },
        .svm1_64le => .{
            .scheme_arch = "svm1-64le",
            .cmpauxmd = null,
            .is_native = false,
            .is_svm = true,
            .cc_arch_id = 13,
        },
        .none => .{
            .scheme_arch = "none",
            .cmpauxmd = null,
            .is_native = false,
            .is_svm = false,
            .cc_arch_id = 0,
        },
    };
}

const std_c_sources = [_][]const u8{
    "src/microcode/outf.c",
    "src/microcode/scm_setjmp.c",
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

fn configureMicrocodeModule(
    mod: *std.Build.Module,
    resolved: std.Build.ResolvedTarget,
    termcap: TermcapOption,
) void {
    const t = resolved.result;

    if (t.os.tag.isDarwin()) {
        mod.linkFramework("CoreFoundation", .{});
    } else if (t.os.tag == .linux) {
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("dl", .{});
    } else if (t.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("bcrypt", .{});
        mod.linkSystemLibrary("advapi32", .{});
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
        "Terminal capability provider: ncurses (default on POSIX), emulate, or none (default on Windows)",
    ) orelse @as(TermcapOption, if (target.result.os.tag == .windows) .none else .ncurses);

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

    const host_lib = b.option(
        []const u8,
        "host-lib",
        "Optional host Scheme library directory containing all.com",
    );

    const cross = b.option(
        bool,
        "cross",
        "Cross-compile Scheme subsystems using src/tools/ cross-toolchain",
    ) orelse false;

    const plugins = b.option(
        []const u8,
        "plugins",
        "Comma-separated plugins to build/install, or 'none' (default: edwin,imail)",
    ) orelse "edwin,imail";

    const jobs = b.option(
        usize,
        "jobs",
        "Maximum parallel Scheme compiler tasks",
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
    ) orelse if (target.result.os.tag == .windows)
        b.fmt("C:/Program Files/MIT-GNU-Scheme/lib/{s}", .{auxdir_name})
    else
        b.fmt("/usr/local/lib/{s}", .{auxdir_name});

    _ = valgrind;
    const c_flags = &[_][]const u8{ "-Wall", "-Wstrict-prototypes" };

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
        scheme_exe.root_module,
        target,
        termcap_opt,
    );
    scheme_exe.root_module.addObject(microcode_zig_obj);
    scheme_exe.root_module.addCSourceFiles(.{
        .files = &std_c_sources,
        .flags = c_flags,
    });
    scheme_exe.root_module.addObject(usrdef_zig_obj);
    if (cmpauxmd_s) |asm_file| {
        scheme_exe.root_module.addCSourceFile(.{
            .file = asm_file,
            .flags = &.{},
            .language = .assembly_with_preprocessor,
        });
    }

    b.installArtifact(scheme_exe);
    const exe_ext = if (target.result.os.tag == .windows) ".exe" else "";
    b.getInstallStep().dependOn(&b.addInstallBinFile(scheme_exe.getEmittedBin(), b.fmt("mit-scheme{s}", .{exe_ext})).step);
    b.getInstallStep().dependOn(&b.addInstallBinFile(scheme_exe.getEmittedBin(), b.fmt("scheme{s}", .{exe_ext})).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("src/microcode/pruxffi.h"),
        .prefix,
        b.fmt("lib/{s}/mit-scheme.h", .{auxdir_name}),
    ).step);

    var macosx_starter_exe: ?*std.Build.Step.Compile = null;
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
        macosx_starter_exe = starter;
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
    const zig_options_mod = zig_options.createModule();
    const prim_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/microcode/zig/prim_abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    prim_abi_mod.addImport("build_options", zig_options_mod);
    const smoke_step = b.step("test-smoke", "Build and run standalone microcode Zig smoke tests");
    const smoke_specs = [_]struct {
        name: []const u8,
        src: []const u8,
        needs_cmpint: bool,
        needs_cmpintmd: bool,
        needs_native: bool,
        needs_fasl: bool,
        needs_gcloop: bool,
        needs_setjmp: bool,
    }{
        .{
            .name = "jit-smoke",
            .src = "tests/microcode/jit-smoke.zig",
            .needs_cmpint = false,
            .needs_cmpintmd = true,
            .needs_native = false,
            .needs_fasl = false,
            .needs_gcloop = false,
            .needs_setjmp = true,
        },
        .{
            .name = "arena-smoke",
            .src = "tests/microcode/arena-smoke.zig",
            .needs_cmpint = false,
            .needs_cmpintmd = false,
            .needs_native = false,
            .needs_fasl = false,
            .needs_gcloop = false,
            .needs_setjmp = false,
        },
        .{
            .name = "gc-arena-smoke",
            .src = "tests/microcode/gc-arena-smoke.zig",
            .needs_cmpint = false,
            .needs_cmpintmd = true,
            .needs_native = false,
            .needs_fasl = false,
            .needs_gcloop = true,
            .needs_setjmp = false,
        },
        .{
            .name = "fasl-code-smoke",
            .src = "tests/microcode/fasl-code-smoke.zig",
            .needs_cmpint = false,
            .needs_cmpintmd = true,
            .needs_native = false,
            .needs_fasl = true,
            .needs_gcloop = true,
            .needs_setjmp = false,
        },
        .{
            .name = "trampoline-smoke",
            .src = "tests/microcode/trampoline-smoke.zig",
            .needs_cmpint = true,
            .needs_cmpintmd = true,
            .needs_native = true,
            .needs_fasl = false,
            .needs_gcloop = true,
            .needs_setjmp = false,
        },
    };

    for (smoke_specs) |spec| {
        if (spec.needs_native and !arch.is_native) continue;
        const smoke_exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec.src),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_c = .off,
            }),
        });
        smoke_exe.root_module.addImport("build_options", zig_options_mod);
        smoke_exe.root_module.addImport("prim_abi", prim_abi_mod);
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
        if (spec.needs_setjmp) {
            smoke_exe.root_module.addCSourceFile(.{
                .file = b.path("src/microcode/scm_setjmp.c"),
                .flags = c_flags,
            });
        }
        if (spec.needs_cmpintmd) {
            smoke_exe.root_module.addObject(cmpintmd_smoke_obj);
        }
        if (spec.needs_cmpint) {
            smoke_exe.root_module.addObject(cmpint_smoke_obj);
        }
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
    unit_tests.root_module.addCSourceFile(.{
        .file = b.path("src/microcode/scm_setjmp.c"),
        .flags = &.{},
    });
    if (target.result.os.tag.isDarwin()) {
        unit_tests.root_module.linkFramework("CoreFoundation", .{});
    } else if (target.result.os.tag == .windows) {
        unit_tests.root_module.linkSystemLibrary("ws2_32", .{});
        unit_tests.root_module.linkSystemLibrary("bcrypt", .{});
        unit_tests.root_module.linkSystemLibrary("advapi32", .{});
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

    // `zig build scheme`
    const scheme_step = b.step(
        "scheme",
        "Build Scheme subsystems, bands, libraries, and plugins via tools/build-scheme.py",
    );
    const scheme_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/build-scheme.py",
        "build",
        "--skip-microcode",
        "--arch",
        arch.scheme_arch,
        "--plugins",
        plugins,
    });
    scheme_cmd.addArg("--scheme-exe");
    scheme_cmd.addFileArg(scheme_exe.getEmittedBin());
    if (host_scheme) |hs| {
        scheme_cmd.addArgs(&.{ "--host-scheme", hs });
    }
    if (host_lib) |hl| {
        scheme_cmd.addArgs(&.{ "--host-lib", hl });
    }
    if (cross) {
        scheme_cmd.addArg("--cross");
    }
    if (jobs) |j| {
        scheme_cmd.addArgs(&.{ "--jobs", b.fmt("{d}", .{j}) });
    }
    scheme_cmd.setCwd(b.path("."));
    scheme_step.dependOn(&scheme_cmd.step);

    // `zig build install-scheme`
    const install_scheme_step = b.step(
        "install-scheme",
        "Install Scheme binary, bands, core subsystems, and plugins to install prefix",
    );
    const install_scheme_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/build-scheme.py",
        "install",
        "--skip-microcode",
        "--arch",
        arch.scheme_arch,
        "--plugins",
        plugins,
    });
    install_scheme_cmd.addArg("--prefix");
    install_scheme_cmd.addDirectoryArg(.{ .relative = .{ .base = .install_prefix } });
    install_scheme_cmd.addArg("--scheme-exe");
    install_scheme_cmd.addFileArg(scheme_exe.getEmittedBin());
    if (macosx_starter_exe) |starter| {
        install_scheme_cmd.addArg("--macosx-starter");
        install_scheme_cmd.addFileArg(starter.getEmittedBin());
    }
    install_scheme_cmd.setCwd(b.path("."));
    install_scheme_step.dependOn(&install_scheme_cmd.step);

    // `zig build clean-scheme`
    const clean_scheme_step = b.step(
        "clean-scheme",
        "Clean Scheme build artifacts, bands, and staging symlinks",
    );
    const clean_scheme_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/build-scheme.py",
        "clean",
    });
    clean_scheme_cmd.setCwd(b.path("."));
    clean_scheme_step.dependOn(&clean_scheme_cmd.step);

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
        "--library-path",
        "src/lib",
        "--scheme-exe",
    });
    check_cmd.addFileArg(scheme_exe.getEmittedBin());
    if (test_suite) |suite| {
        check_cmd.addArgs(&.{ "--test", suite });
    }
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
        const app_cmd = b.addSystemCommand(&.{
            "./src/etc/macosx/make-app.sh",
            "--plugins",
            plugins,
        });
        app_cmd.addArg("--scheme-exe");
        app_cmd.addFileArg(scheme_exe.getEmittedBin());
        if (macosx_starter_exe) |starter| {
            app_cmd.addArg("--macosx-starter");
            app_cmd.addFileArg(starter.getEmittedBin());
        }
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
