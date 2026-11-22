#!/usr/bin/env python3
"""Autoconf/automake/libtool-free Scheme, plugin, install, and clean driver for MIT/GNU Scheme."""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"
TESTS_DIR = REPO_ROOT / "tests"

ARCH_CONFIGS = {
    "aarch64le": {
        "scheme_arch": "aarch64le",
        "zig_arch": "aarch64le",
        "compiler_dir": "aarch64",
    },
    "x86-64": {
        "scheme_arch": "x86-64",
        "zig_arch": "x86_64",
        "compiler_dir": "x86-64",
    },
    "x86_64": {
        "scheme_arch": "x86-64",
        "zig_arch": "x86_64",
        "compiler_dir": "x86-64",
    },
    "svm1-64le": {
        "scheme_arch": "svm1-64le",
        "zig_arch": "svm1_64le",
        "compiler_dir": "svm",
    },
    "svm1_64le": {
        "scheme_arch": "svm1-64le",
        "zig_arch": "svm1_64le",
        "compiler_dir": "svm",
    },
    "none": {
        "scheme_arch": "none",
        "zig_arch": "none",
        "compiler_dir": "C",
    },
}

ALL_PLUGINS = ("edwin", "imail", "blowfish", "gdbm", "pgsql", "x11", "x11-screen")
LIB_SYMLINK_SUBDIRS = (
    "compiler",
    "cref",
    "edwin",
    "ffi",
    "imail",
    "libraries",
    "runtime",
    "sf",
    "sos",
    "ssp",
    "star-parser",
    "x11",
    "x11-screen",
    "xml",
)
RUNTIME_INSTALL_COMS = (
    "chrsyn",
    "cpress",
    "format",
    "gdbm",
    "mime-codec",
    "numint",
    "ordvec",
    "pgsql",
    "process",
    "rbtree",
    "regexp",
    "rexp",
    "rgxcmp",
    "syncproc",
    "wttree",
    "ystep",
)
COMPILER_SUBDIRS = ("back", "base", "fggen", "fgopt", "rtlbase", "rtlgen", "rtlopt")
CORE_SIMPLE_MODULES = ("cref", "sf")
CORE_LOAD_MODULES = ("sos", "ssp", "star-parser", "xml")
SRC_CLEAN_DIRS = (
    "6001",
    "compiler",
    "compiler/back",
    "compiler/base",
    "compiler/fggen",
    "compiler/fgopt",
    "compiler/machines/aarch64",
    "compiler/machines/x86-64",
    "compiler/machines/svm",
    "compiler/machines/C",
    "compiler/rtlbase",
    "compiler/rtlgen",
    "compiler/rtlopt",
    "cref",
    "edwin",
    "ffi",
    "imail",
    "libraries",
    "runtime",
    "sf",
    "sos",
    "ssp",
    "star-parser",
    "xdoc",
    "xml",
    "blowfish",
    "gdbm",
    "pgsql",
    "x11",
    "x11-screen",
)
TEST_CLEAN_DIRS = (
    "compiler",
    "libraries",
    "microcode",
    "runtime",
    "runtime/test-continuation-parser-data",
    "sos",
    "star-parser",
    "xml",
    "ffi",
)
SCHEME_ARTIFACT_PATTERNS = (
    "*.bci",
    "*.bcild",
    "*.bin",
    "*.binld",
    "*.com",
    "*.comld",
    "*.crf",
    "*.dkp",
    "*.ext",
    "*.fni",
    "*.fre",
    "*.icb",
    "*.lap",
    "*.moc",
    "*.nib",
    "*.pkd",
    "*.rtl",
    "*.txe",
    "*-init.c",
    "*-init.h",
    "*-init.o",
    "TAGS",
)
C_FFI_PLUGINS = ("blowfish", "gdbm", "pgsql", "x11")


def resolve_arch(raw_arch: str) -> dict[str, str]:
    if raw_arch == "auto":
        mach = platform.machine().lower()
        if mach in ("arm64", "aarch64"):
            raw_arch = "aarch64le"
        elif mach in ("x86_64", "amd64"):
            raw_arch = "x86-64"
        else:
            raw_arch = "svm1-64le"
    if raw_arch not in ARCH_CONFIGS:
        raise SystemExit(f"error: unsupported architecture '{raw_arch}'")
    return ARCH_CONFIGS[raw_arch]


def parse_plugins(raw: str | None) -> list[str]:
    if not raw or raw.strip().lower() == "none":
        return []
    out: list[str] = []
    for item in raw.split(","):
        name = item.strip()
        if not name:
            continue
        if name not in ALL_PLUGINS:
            raise SystemExit(
                f"error: unknown plugin '{name}' (valid: {', '.join(ALL_PLUGINS)})"
            )
        if name not in out:
            out.append(name)
    # Keep deterministic dependency order: C FFI plugins, edwin, then imail/x11-screen.
    order = {name: i for i, name in enumerate(ALL_PLUGINS)}
    priority = {
        "blowfish": 0,
        "gdbm": 1,
        "pgsql": 2,
        "x11": 3,
        "edwin": 4,
        "imail": 5,
        "x11-screen": 6,
    }
    return sorted(out, key=lambda n: priority.get(n, order[n]))


def ensure_symlink(link_path: Path, target: str) -> None:
    if link_path.is_symlink():
        if os.readlink(link_path) == target:
            return
        link_path.unlink()
    elif link_path.exists():
        if link_path.is_dir():
            raise SystemExit(f"error: refusing to replace directory with symlink: {link_path}")
        link_path.unlink()
    link_path.symlink_to(target)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path, ignore_errors=True)


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    stdin_text: str | None = None,
    label: str | None = None,
) -> str:
    prefix = f"[{label}] " if label else ""
    print(f"{prefix}+ {' '.join(cmd)}", flush=True)
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        input=stdin_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if proc.returncode != 0:
        if proc.stdout:
            sys.stderr.write(proc.stdout)
        raise SystemExit(
            f"error: command failed with status {proc.returncode} in {cwd}: {' '.join(cmd)}"
        )
    return proc.stdout


def query_scheme(exe: Path, expr: str, env: dict[str, str], extra_args: list[str] | None = None) -> str:
    cmd = [str(exe), "--batch-mode"]
    if extra_args:
        cmd.extend(extra_args)
    cmd.extend(["--no-init-file", "--eval", expr, "(%exit)"])
    proc = subprocess.run(
        cmd,
        cwd=str(SRC_DIR),
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"error: Scheme query failed using {exe}: {expr}")
    return proc.stdout.strip()


def run_dag(
    tasks: dict[str, tuple[list[str], Callable[[], None]]],
    max_workers: int,
) -> None:
    if max_workers < 1:
        max_workers = 1
    pending = {name: (set(deps), fn) for name, (deps, fn) in tasks.items()}
    running = {}
    done: set[str] = set()

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        while pending or running:
            ready = [name for name, (deps, _) in pending.items() if deps.issubset(done)]
            for name in ready:
                _, fn = pending.pop(name)
                running[pool.submit(fn)] = name

            if not running:
                raise SystemExit(f"error: cyclic or unsatisfied task graph: {sorted(pending)}")

            completed, _ = wait(running.keys(), return_when=FIRST_COMPLETED)
            for fut in completed:
                name = running.pop(fut)
                fut.result()
                done.add(name)


def resolve_zig() -> str:
    zig = shutil.which("zig")
    if zig:
        return zig
    raise SystemExit("error: zig compiler not found in PATH")


def zig_opt_mode(optimize: str) -> str:
    return {
        "Debug": "debug",
        "ReleaseFast": "fast",
        "ReleaseSafe": "safe",
        "ReleaseSmall": "small",
    }[optimize]


def darwin_zig_env(env: dict[str, str] | None = None) -> dict[str, str]:
    out = dict(env) if env is not None else os.environ.copy()
    if (
        platform.system() == "Darwin"
        and not out.get("DYLD_FALLBACK_LIBRARY_PATH")
        and Path("/usr/local/lib").is_dir()
    ):
        out["DYLD_FALLBACK_LIBRARY_PATH"] = "/usr/local/lib:/usr/lib"
    return out


def pkg_config_try(package: str) -> tuple[list[str], list[str]] | None:
    pc = shutil.which("pkg-config")
    if not pc:
        return None
    cflags = subprocess.run([pc, "--cflags", package], capture_output=True, text=True)
    if cflags.returncode != 0:
        return None
    libs = subprocess.run([pc, "--libs", package], capture_output=True, text=True)
    if libs.returncode != 0:
        return None
    return shlex.split(cflags.stdout), shlex.split(libs.stdout)


def probe_header_flags(
    header_rel: str,
    prefixes: tuple[str, ...],
    default_libs: list[str],
    direct_inc_dirs: tuple[str, ...] = (),
) -> tuple[list[str], list[str]] | None:
    for prefix in prefixes:
        p = Path(prefix)
        inc_dir = p / "include"
        if (inc_dir / header_rel).is_file():
            cflags = [f"-I{inc_dir}"]
            lib_dir = p / "lib"
            libs = ([f"-L{lib_dir}"] if lib_dir.is_dir() else []) + default_libs
            return cflags, libs
    for inc in direct_inc_dirs:
        p = Path(inc)
        if (p / header_rel).is_file():
            cflags = [f"-I{p}"]
            lib_dir = p.parent / "lib"
            libs = ([f"-L{lib_dir}"] if lib_dir.is_dir() else []) + default_libs
            return cflags, libs
    return None


def libpq_flags() -> tuple[list[str], list[str]]:
    if found := pkg_config_try("libpq"):
        return found
    pg_config = shutil.which("pg_config")
    if pg_config:
        inc_res = subprocess.run([pg_config, "--includedir"], capture_output=True, text=True)
        lib_res = subprocess.run([pg_config, "--libdir"], capture_output=True, text=True)
        if inc_res.returncode == 0 and lib_res.returncode == 0:
            inc = inc_res.stdout.strip()
            lib = lib_res.stdout.strip()
            if inc and Path(inc, "libpq-fe.h").is_file():
                libs = ([f"-L{lib}"] if lib and Path(lib).is_dir() else []) + ["-lpq"]
                return [f"-I{inc}"], libs
    if found := probe_header_flags(
        "libpq-fe.h",
        ("/opt/homebrew/opt/libpq", "/usr/local/opt/libpq", "/opt/homebrew", "/usr/local", "/usr"),
        ["-lpq"],
        direct_inc_dirs=("/usr/include/postgresql", "/usr/local/include/postgresql"),
    ):
        return found
    raise SystemExit("error: libpq headers not found (install libpq/postgresql or configure pkg-config)")


def gdbm_flags() -> tuple[list[str], list[str]]:
    if found := pkg_config_try("gdbm"):
        return found
    if found := probe_header_flags(
        "gdbm.h",
        ("/opt/homebrew/opt/gdbm", "/usr/local/opt/gdbm", "/opt/homebrew", "/usr/local", "/usr"),
        ["-lgdbm"],
    ):
        return found
    return [], ["-lgdbm"]


def x11_flags() -> tuple[list[str], list[str]]:
    if found := pkg_config_try("x11"):
        return found
    if found := probe_header_flags(
        "X11/Xlib.h",
        ("/opt/X11", "/opt/homebrew", "/usr/local", "/usr", "/usr/X11R6"),
        ["-lX11"],
    ):
        return found
    return [], ["-lX11"]


def split_pkg_flags(cflags: list[str], lib_flags: list[str]) -> tuple[list[str], list[str], list[str], list[str]]:
    inc_dirs: list[str] = []
    other_cflags: list[str] = []
    lib_dirs: list[str] = []
    link_args: list[str] = []

    i = 0
    while i < len(cflags):
        tok = cflags[i]
        if tok in ("-I", "-isystem") and i + 1 < len(cflags):
            inc_dirs.append(cflags[i + 1])
            i += 2
        elif tok.startswith("-I") and len(tok) > 2:
            inc_dirs.append(tok[2:])
            i += 1
        elif tok.startswith("-isystem") and len(tok) > 8:
            inc_dirs.append(tok[8:])
            i += 1
        else:
            other_cflags.append(tok)
            i += 1

    i = 0
    while i < len(lib_flags):
        tok = lib_flags[i]
        if tok == "-L" and i + 1 < len(lib_flags):
            lib_dirs.append(lib_flags[i + 1])
            i += 2
        elif tok.startswith("-L") and len(tok) > 2:
            lib_dirs.append(tok[2:])
            i += 1
        elif tok == "-l" and i + 1 < len(lib_flags):
            link_args.append(f"-l{lib_flags[i + 1]}")
            i += 2
        else:
            link_args.append(tok)
            i += 1

    return inc_dirs, other_cflags, lib_dirs, link_args


class SchemeContext:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.arch = resolve_arch(args.arch)
        self.scheme_arch = self.arch["scheme_arch"]
        self.zig_arch = self.arch["zig_arch"]
        self.compiler_dir = self.arch["compiler_dir"]
        self.version = args.version
        self.auxdir_name = f"mit-scheme-{self.scheme_arch}-{self.version}"
        self.plugins = parse_plugins(args.plugins)
        self.jobs = max(1, args.jobs or (os.cpu_count() or 4))
        self._temp_dirs: list[tempfile.TemporaryDirectory[str]] = []

    def close(self) -> None:
        for td in self._temp_dirs:
            td.cleanup()
        self._temp_dirs.clear()

    def make_temp_lib_symlink(self, real_dir: Path) -> str:
        # MIT Scheme splits --library and MITSCHEME_LIBRARY_PATH on ':' on POSIX.
        if ":" not in str(real_dir) or platform.system() == "Windows":
            return str(real_dir)
        td = tempfile.TemporaryDirectory(prefix="mit-scheme-hostlib-")
        self._temp_dirs.append(td)
        link = Path(td.name) / "lib"
        link.symlink_to(real_dir)
        return str(link)

    def resolve_target_scheme(self, build_if_needed: bool) -> Path:
        if self.args.scheme_exe:
            exe = Path(self.args.scheme_exe).resolve()
            if not exe.is_file():
                raise SystemExit(f"error: --scheme-exe not found: {exe}")
            return exe

        exe_ext = ".exe" if platform.system() == "Windows" else ""
        candidates = [
            REPO_ROOT / "zig-out" / "bin" / f"{self.auxdir_name}{exe_ext}",
            REPO_ROOT / "zig-out" / "bin" / f"mit-scheme{exe_ext}",
        ]
        if not self.args.skip_microcode and build_if_needed:
            cmd = [
                "zig",
                "build",
                f"-Darch={self.zig_arch}",
                f"-Doptimize={self.args.optimize}",
            ]
            if self.args.termcap:
                cmd.append(f"-Dtermcap={self.args.termcap}")
            if self.args.debugging:
                cmd.append("-Ddebugging=true")
            prefix = getattr(self.args, "prefix", None)
            if prefix:
                cmd.append(
                    f"-Dlibrary-path={Path(prefix).resolve() / 'lib' / self.auxdir_name}"
                )
            run_cmd(cmd, cwd=REPO_ROOT, env=darwin_zig_env(), label="zig")

        for cand in candidates:
            if cand.is_file():
                return cand
        raise SystemExit(
            f"error: built microcode executable not found in {REPO_ROOT / 'zig-out' / 'bin'}; "
            "run `zig build` first or pass --scheme-exe"
        )

    def resolve_macosx_starter(self) -> Path | None:
        if self.args.macosx_starter:
            starter = Path(self.args.macosx_starter).resolve()
            return starter if starter.is_file() else None
        cand = REPO_ROOT / "zig-out" / "lib" / self.auxdir_name / "macosx-starter"
        return cand if cand.is_file() else None

    def resolve_host_scheme(self) -> tuple[Path, str | None, bool]:
        raw = self.args.host_scheme or os.environ.get("MIT_SCHEME_EXE", "").strip()
        exe: Path | None = None
        if raw:
            cand = Path(raw)
            if cand.is_file():
                exe = cand.resolve()
            else:
                found = shutil.which(raw)
                if found:
                    exe = Path(found).resolve()
        else:
            for name in (f"mit-scheme-{self.scheme_arch}", "mit-scheme"):
                found = shutil.which(name)
                if found:
                    exe = Path(found).resolve()
                    break

        if exe is None:
            raise SystemExit(
                "error: host MIT/GNU Scheme executable not found; pass --host-scheme PATH or set MIT_SCHEME_EXE"
            )

        host_lib_raw = self.args.host_lib
        if not host_lib_raw:
            sibling_all = exe.parent / "all.com"
            if sibling_all.is_file():
                host_lib_raw = str(exe.parent)
            else:
                prefix_lib = exe.parent.parent / "lib"
                if (prefix_lib / self.auxdir_name / "all.com").is_file():
                    host_lib_raw = str(prefix_lib / self.auxdir_name)
                elif prefix_lib.is_dir():
                    for cand in sorted(prefix_lib.glob("mit-scheme-*")):
                        if (cand / "all.com").is_file():
                            host_lib_raw = str(cand)
                            break

        effective_host_lib: str | None = None
        has_runtime_com = True
        if host_lib_raw:
            lib_dir = Path(host_lib_raw).resolve()
            if not lib_dir.is_dir():
                raise SystemExit(f"error: --host-lib directory not found: {lib_dir}")
            effective_host_lib = self.make_temp_lib_symlink(lib_dir)
            has_runtime_com = (lib_dir / "runtime.com").is_file()

        return exe, effective_host_lib, has_runtime_com

    def host_env(self, host_lib: str | None, extra_lib: str | None = None) -> dict[str, str]:
        env = os.environ.copy()
        env.pop("MIT_SCHEME_EXE", None)
        libs: list[str] = []
        if extra_lib:
            libs.append(extra_lib)
        if host_lib:
            libs.append(host_lib)
        if libs:
            joined = os.pathsep.join(libs)
            env["MITSCHEME_LIBRARY_PATH"] = joined
            env["MITSCHEME_INF_DIRECTORY"] = libs[0]
        else:
            env.pop("MITSCHEME_LIBRARY_PATH", None)
            env.pop("MITSCHEME_INF_DIRECTORY", None)
        return env

    def target_env(self, target_scheme: Path, prepend_dir: Path | None = None) -> dict[str, str]:
        env = os.environ.copy()
        src_lib = self.make_temp_lib_symlink(SRC_DIR / "lib")
        lib_path = f"{prepend_dir}{os.pathsep}{src_lib}" if prepend_dir else src_lib
        env["MIT_SCHEME_EXE"] = str(target_scheme)
        env["MITSCHEME_LIBRARY_PATH"] = lib_path
        env["MITSCHEME_INF_DIRECTORY"] = src_lib
        return env

    def setup_tree_links(self) -> None:
        lib_dir = SRC_DIR / "lib"
        lib_dir.mkdir(parents=True, exist_ok=True)
        ensure_symlink(lib_dir / "include", "../microcode")
        ensure_symlink(lib_dir / "mit-scheme.h", "../microcode/pruxffi.h")
        ensure_symlink(lib_dir / "optiondb.scm", "../etc/optiondb.scm")
        for sub in LIB_SYMLINK_SUBDIRS:
            ensure_symlink(lib_dir / sub, f"../{sub}")

        comp_dir = SRC_DIR / "compiler"
        ensure_symlink(comp_dir / "machine", f"machines/{self.compiler_dir}")
        for fn in ("compiler.cbf", "compiler.pkg", "compiler.sf", "make.com", "make.bin"):
            ensure_symlink(comp_dir / fn, f"machine/{fn}")

        machine_path = comp_dir / "machines" / self.compiler_dir
        if self.scheme_arch == "svm1-64le":
            ensure_symlink(machine_path / "wordsize.scm", "wordsize-64.scm")
            ensure_symlink(machine_path / "endian.scm", "little-endian.scm")
        elif (machine_path / "little-endian.scm").is_file() and not (
            machine_path / "endian.scm"
        ).exists():
            ensure_symlink(machine_path / "endian.scm", "little-endian.scm")

    def generate_standard_libs(
        self, host_exe: Path, host_lib: str | None
    ) -> None:
        env = self.host_env(host_lib)
        cmd = [str(host_exe), "--batch-mode"]
        if host_lib:
            cmd.extend(["--library", host_lib])
        cmd.extend(
            [
                "--no-init-file",
                "--load",
                "../etc/standards/standards",
                "../etc/standards/generate-standard-libs",
                "--eval",
                '(generate-standard-libs "runtime/generated-standard-libs")',
                "(exit)",
            ]
        )
        run_cmd(cmd, cwd=SRC_DIR, env=env, label="standards")

    def generate_svm1_defns(
        self, host_exe: Path, host_lib: str | None, has_runtime_com: bool
    ) -> None:
        if self.scheme_arch != "svm1-64le":
            return
        env = self.host_env(host_lib)
        cmd = [str(host_exe), "--batch-mode"]
        if host_lib:
            cmd.extend(["--library", host_lib])
        if has_runtime_com:
            cmd.extend(["--band", "runtime.com"])
        cmd.append("--no-init-file")
        run_cmd(
            cmd,
            cwd=SRC_DIR,
            env=env,
            stdin_text='(with-working-directory-pathname "compiler/machines/svm" (lambda () (load "compile-assembler")))\n',
            label="svm-asm",
        )

    def build_cross_toolchain(
        self, host_exe: Path, host_lib: str | None, has_runtime_com: bool
    ) -> None:
        tools_dir = SRC_DIR / "tools"
        for rel in (
            "compiler/back",
            "compiler/base",
            "compiler/fggen",
            "compiler/fgopt",
            f"compiler/machines/{self.compiler_dir}",
            "compiler/rtlbase",
            "compiler/rtlgen",
            "compiler/rtlopt",
            "cref",
            "runtime",
            "sf",
            "star-parser",
        ):
            (tools_dir / rel).mkdir(parents=True, exist_ok=True)

        ensure_symlink(tools_dir / "compiler" / "machine", f"machines/{self.compiler_dir}")
        for fn in ("compiler.cbf", "compiler.pkg", "compiler.sf", "make.bin", "make.com"):
            ensure_symlink(tools_dir / "compiler" / fn, f"machine/{fn}")
        ensure_symlink(tools_dir / "compiler" / "base" / "make.scm", "../../../compiler/base/make.scm")
        ensure_symlink(tools_dir / "cref" / "make.scm", "../../cref/make.scm")
        ensure_symlink(tools_dir / "sf" / "make.scm", "../../sf/make.scm")
        ensure_symlink(tools_dir / "star-parser" / "make.scm", "../../star-parser/load.scm")
        ensure_symlink(tools_dir / "optiondb.scm", "../etc/optiondb.scm")

        env = self.host_env(host_lib)
        sf_settings = (
            '(set! sf/object-root (pathname-simplify (merge-pathnames "tools/"))) '
            '(set! sf/source-root (pathname-simplify (merge-pathnames "./")))'
        )
        cref_settings = (
            '(set! cref/object-root (pathname-simplify (merge-pathnames "tools/"))) '
            '(set! cref/source-root (pathname-simplify (merge-pathnames "./")))'
        )
        host_compiler_cmd = [str(host_exe), "--batch-mode"]
        if host_lib:
            host_compiler_cmd.extend(["--library", host_lib])
        host_compiler_cmd.extend(
            [
                "--no-init-file",
                "--load",
                "runtime/host-adapter.scm",
                "--eval",
                "(load-option (quote CREF))",
                "--eval",
                f"(begin {cref_settings} {sf_settings})",
            ]
        )

        host_syntaxer_cmd = [str(host_exe), "--batch-mode"]
        if host_lib:
            host_syntaxer_cmd.extend(["--library", host_lib])
        if has_runtime_com:
            host_syntaxer_cmd.extend(["--band", "runtime.com"])
        host_syntaxer_cmd.append("--no-init-file")
        if has_runtime_com:
            host_syntaxer_cmd.extend(["--eval", "(load-option (quote SF))"])
        host_syntaxer_cmd.extend(
            [
                "--load",
                "runtime/host-adapter.scm",
                "--eval",
                "(load-option (quote CREF))",
                "--eval",
                f"(begin {cref_settings} {sf_settings})",
            ]
        )

        def run_tool_star_parser() -> None:
            run_cmd(
                host_syntaxer_cmd,
                cwd=SRC_DIR,
                env=env,
                stdin_text='(sf-directory "star-parser")\n',
                label="tools:syntax-*parser",
            )
            run_cmd(
                host_syntaxer_cmd,
                cwd=SRC_DIR,
                env=env,
                stdin_text='(cref/generate-constructors "star-parser/parser")\n',
                label="tools:cref-*parser",
            )

        def save_tools_runtime() -> None:
            rt_env = self.host_env(str(SRC_DIR / "tools"))
            run_cmd(
                [
                    str(host_exe),
                    "--batch-mode",
                    "--library",
                    "../../tools",
                    "--fasl",
                    "make.com",
                ],
                cwd=tools_dir / "runtime",
                env=rt_env,
                stdin_text='(disk-save "../../tools/runtime.com")\n',
                label="tools/runtime.com",
            )

        def save_tools_band(target_name: str, with_compiler: bool) -> None:
            comp_load = (
                '  (with-working-directory-pathname "tools/compiler" (lambda () (load "make")))\n'
                if with_compiler
                else ""
            )
            script = (
                "(begin\n"
                '  (with-working-directory-pathname "tools/cref" (lambda () (load "make")))\n'
                '  (with-working-directory-pathname "tools/sf" (lambda () (load "make")))\n'
                '  (with-working-directory-pathname "tools/star-parser" (lambda () (load "load")))\n'
                f"{comp_load}"
                f'  (disk-save "{target_name}"))\n'
            )
            run_cmd(
                [
                    str(host_exe),
                    "--library",
                    "tools",
                    "--band",
                    "tools/runtime.com",
                    "--batch-mode",
                    "--no-init-file",
                ],
                cwd=SRC_DIR,
                env=self.host_env(str(tools_dir)),
                stdin_text=script,
                label=target_name,
            )

        tasks: dict[str, tuple[list[str], Callable[[], None]]] = {
            "tools:syntax-runtime": (
                [],
                lambda: run_cmd(
                    host_syntaxer_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(begin (cd "runtime") (load "runtime.sf"))\n',
                    label="tools:syntax-runtime",
                ),
            ),
            "tools:compile-runtime": (
                ["tools:syntax-runtime"],
                lambda: run_cmd(
                    host_compiler_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(compile-directory "tools/runtime")\n',
                    label="tools:compile-runtime",
                ),
            ),
            "tools/runtime.com": (["tools:compile-runtime"], save_tools_runtime),
            "tools:syntax-cref": (
                ["tools:syntax-runtime"],
                lambda: run_cmd(
                    host_syntaxer_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(begin (cd "cref") (load "cref.sf"))\n',
                    label="tools:syntax-cref",
                ),
            ),
            "tools:compile-cref": (
                ["tools:syntax-cref"],
                lambda: run_cmd(
                    host_compiler_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(compile-directory "tools/cref")\n',
                    label="tools:compile-cref",
                ),
            ),
            "tools:syntax-sf": (
                ["tools:syntax-runtime"],
                lambda: run_cmd(
                    host_syntaxer_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(begin (cd "sf") (load "sf.sf"))\n',
                    label="tools:syntax-sf",
                ),
            ),
            "tools:compile-sf": (
                ["tools:syntax-sf"],
                lambda: run_cmd(
                    host_compiler_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(compile-directory "tools/sf")\n',
                    label="tools:compile-sf",
                ),
            ),
            "tools:syntax-star-parser": (["tools:syntax-runtime"], run_tool_star_parser),
            "tools:compile-star-parser": (
                ["tools:syntax-star-parser"],
                lambda: run_cmd(
                    host_compiler_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text='(compile-directory "tools/star-parser")\n',
                    label="tools:compile-star-parser",
                ),
            ),
            "tools:syntax-compiler": (
                ["tools:syntax-runtime", "tools:syntax-sf"]
                if has_runtime_com
                else ["tools/syntaxer.com"],
                lambda: run_cmd(
                    host_syntaxer_cmd
                    if has_runtime_com
                    else [
                        str(host_exe),
                        "--batch-mode",
                        "--library",
                        "tools",
                        "--band",
                        "tools/syntaxer.com",
                        "--no-init-file",
                        "--eval",
                        f"(begin {cref_settings} {sf_settings})",
                    ],
                    cwd=SRC_DIR,
                    env=env if has_runtime_com else self.host_env(str(tools_dir)),
                    stdin_text='(begin (cd "compiler") (load "compiler.sf"))\n',
                    label="tools:syntax-compiler",
                ),
            ),
            "tools/syntaxer.com": (
                [
                    "tools:compile-cref",
                    "tools:compile-sf",
                    "tools:compile-star-parser",
                    "tools/runtime.com",
                ],
                lambda: save_tools_band("tools/syntaxer.com", False),
            ),
            "tools/compiler.com": (
                [
                    *(f"tools:compile-compiler-{sub}" for sub in (*COMPILER_SUBDIRS, "machine")),
                    "tools:compile-cref",
                    "tools:compile-sf",
                    "tools:compile-star-parser",
                    "tools/runtime.com",
                ],
                lambda: save_tools_band("tools/compiler.com", True),
            ),
        }
        for sub in (*COMPILER_SUBDIRS, "machine"):
            tname = f"tools:compile-compiler-{sub}"
            tasks[tname] = (
                ["tools:syntax-compiler"],
                lambda s=sub, lb=tname: run_cmd(
                    host_compiler_cmd,
                    cwd=SRC_DIR,
                    env=env,
                    stdin_text=f'(compile-directory "tools/compiler/{s}")\n',
                    label=lb,
                ),
            )

        run_dag(tasks, self.jobs)

    def compile_core_subsystems(
        self, host_exe: Path, host_lib: str | None, has_runtime_com: bool, cross: bool
    ) -> None:
        if cross:
            sf_settings = (
                "(set! sf/cross-compiling? true) "
                "(set! package/cross-compiling? true) "
                "(set! target-bytes-per-object (lambda () 8))"
            )
            compiler_settings = f"{sf_settings} (set! compiler:cross-compiling? true)"
            tool_compiler = [
                str(host_exe),
                "--batch-mode",
                "--band",
                "tools/compiler.com",
                "--no-init-file",
                "--eval",
                f"(begin {compiler_settings})",
            ]
            tool_syntaxer = [
                str(host_exe),
                "--batch-mode",
                "--band",
                "tools/syntaxer.com",
                "--no-init-file",
                "--eval",
                f"(begin {sf_settings})",
            ]
            default_env = self.host_env(host_lib)
            xml_extra = str(SRC_DIR / "tools")
            xml_env = self.host_env(host_lib, extra_lib=xml_extra)
        else:
            sf_settings = ""
            lib_args = ["--library", host_lib] if host_lib else []
            tool_compiler = [
                str(host_exe),
                "--batch-mode",
                *lib_args,
                "--no-init-file",
                "--load",
                "runtime/host-adapter.scm",
            ]
            tool_syntaxer = [
                str(host_exe),
                "--batch-mode",
                *lib_args,
                *(["--band", "runtime.com"] if has_runtime_com else []),
                "--no-init-file",
                "--load",
                "runtime/host-adapter.scm",
                *(["--eval", "(load-option (quote SF))"] if has_runtime_com else []),
            ]
            default_env = self.host_env(host_lib)
            xml_env = default_env

        def cross_host(subdir: str, env: dict[str, str]) -> None:
            if not cross:
                return
            cmd = [
                *tool_compiler,
                "--eval",
                '(begin (load "etc/crossbin"))',
                "--eval",
                f'(begin (apply convert fasl-format:{self.scheme_arch} (cdr (member "--" (command-line)))))',
                "--eval",
                "(%exit 0)",
                "--",
                subdir,
            ]
            run_cmd(cmd, cwd=SRC_DIR, env=env, label=f"cross-host:{subdir}")

        def with_dir_expr(subdir: str, body: str) -> str:
            return f'(with-working-directory-pathname "{subdir}"\n  (lambda () {body}))\n'

        def compile_subdir(subdir: str, expr: str, env: dict[str, str], label: str) -> None:
            run_cmd(tool_compiler, cwd=SRC_DIR, env=env, stdin_text=expr, label=label)
            cross_host(subdir, env)

        def stage_sos_for_cross() -> None:
            if not cross:
                return
            tools_sos = SRC_DIR / "tools" / "sos"
            tools_sos.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SRC_DIR / "sos" / "load.scm", tools_sos / "load.scm")
            shutil.copy2(SRC_DIR / "sos" / "sos-unx.dkp", tools_sos / "sos-unx.pkd")
            for nib in (SRC_DIR / "sos").glob("*.nib"):
                shutil.copy2(nib, tools_sos / f"{nib.stem}.bin")

        def compile_sos_and_stage() -> None:
            compile_subdir(
                "sos",
                with_dir_expr("sos", '(load "compile")'),
                default_env,
                "compile-sos",
            )
            stage_sos_for_cross()

        def compile_compiler_sub(sub: str) -> None:
            subdir = f"compiler/{sub}"
            run_cmd(
                tool_compiler,
                cwd=SRC_DIR,
                env=default_env,
                stdin_text=f'(compile-directory "{subdir}")\n',
                label=f"compile:{subdir}",
            )
            cross_host(subdir, default_env)

        tasks: dict[str, tuple[list[str], Callable[[], None]]] = {
            "syntax-runtime": (
                [],
                lambda: run_cmd(
                    tool_compiler,
                    cwd=SRC_DIR,
                    env=default_env,
                    stdin_text=with_dir_expr("runtime", '(load "runtime.sf")'),
                    label="syntax-runtime",
                ),
            ),
            "compile-runtime": (
                ["syntax-runtime"],
                lambda: compile_subdir(
                    "runtime",
                    with_dir_expr("runtime", '(load "runtime.cbf")'),
                    default_env,
                    "compile-runtime",
                ),
            ),
            "syntax-sf": (
                ["syntax-runtime"],
                lambda: run_cmd(
                    tool_compiler,
                    cwd=SRC_DIR,
                    env=default_env,
                    stdin_text=with_dir_expr("sf", '(load "sf.sf")'),
                    label="syntax-sf",
                ),
            ),
            "compile-sf": (
                ["syntax-sf"],
                lambda: compile_subdir(
                    "sf",
                    with_dir_expr("sf", '(load "sf.cbf")'),
                    default_env,
                    "compile-sf",
                ),
            ),
            "syntax-cref": (
                ["syntax-runtime"],
                lambda: run_cmd(
                    tool_compiler,
                    cwd=SRC_DIR,
                    env=default_env,
                    stdin_text=with_dir_expr("cref", '(load "cref.sf")'),
                    label="syntax-cref",
                ),
            ),
            "compile-cref": (
                ["syntax-cref"],
                lambda: compile_subdir(
                    "cref",
                    with_dir_expr("cref", '(load "cref.cbf")'),
                    default_env,
                    "compile-cref",
                ),
            ),
            "compile-star-parser": (
                ["syntax-runtime"],
                lambda: compile_subdir(
                    "star-parser",
                    with_dir_expr("star-parser", '(load "compile")'),
                    default_env,
                    "compile-star-parser",
                ),
            ),
            "compile-ffi": (
                ["syntax-runtime"],
                lambda: compile_subdir(
                    "ffi",
                    with_dir_expr("ffi", '(load "compile.scm")'),
                    default_env,
                    "compile-ffi",
                ),
            ),
            "compile-sos": (
                ["syntax-runtime"],
                compile_sos_and_stage,
            ),
            "syntax-compiler": (
                ["syntax-runtime", "syntax-sf"],
                lambda: run_cmd(
                    tool_syntaxer,
                    cwd=SRC_DIR,
                    env=default_env,
                    stdin_text=with_dir_expr(
                        "compiler", f'{sf_settings} (load "compiler.sf")'
                    ),
                    label="syntax-compiler",
                ),
            ),
            "compile-compiler": (
                [f"compile-compiler-{sub}" for sub in (*COMPILER_SUBDIRS, "machine")],
                lambda: cross_host("compiler", default_env),
            ),
            "compile-xml": (
                ["syntax-runtime", "compile-sos", "compile-star-parser"],
                lambda: compile_subdir(
                    "xml",
                    with_dir_expr("xml", '(load "compile")'),
                    xml_env,
                    "compile-xml",
                ),
            ),
            "compile-ssp": (
                ["syntax-runtime", "compile-xml"],
                lambda: compile_subdir(
                    "ssp",
                    with_dir_expr("ssp", '(load "compile")'),
                    xml_env,
                    "compile-ssp",
                ),
            ),
        }
        for sub in (*COMPILER_SUBDIRS, "machine"):
            tasks[f"compile-compiler-{sub}"] = (
                ["syntax-compiler"],
                lambda s=sub: compile_compiler_sub(s),
            )

        run_dag(tasks, self.jobs)

    def finish_cross_target(self, target_scheme: Path, cross: bool) -> None:
        if not cross:
            return
        env = self.target_env(target_scheme)
        runtime_dir = SRC_DIR / "runtime"
        steps = [
            ("make.bin", "finish-cross-compilation:files", "."),
            ("make.com", "finish-cross-compilation:files", ".."),
            ("make.com", "finish-cross-compilation:info-files", ".."),
        ]
        for fasl, proc, arg in steps:
            expr = (
                "(let ((env (->environment (quote (runtime)))))\n"
                '  (load "../compiler/base/crsend" env)\n'
                f'  ((access {proc} env) "{arg}"))\n'
            )
            run_cmd(
                [str(target_scheme), "--batch-mode", "--library", "../lib", "--fasl", fasl],
                cwd=runtime_dir,
                env=env,
                stdin_text=expr,
                label=f"cross-target:{proc}({arg})",
            )

    def build_bands(self, target_scheme: Path) -> None:
        env = self.target_env(target_scheme)
        run_cmd(
            [str(target_scheme), "--batch-mode", "--library", "../lib", "--fasl", "make.com"],
            cwd=SRC_DIR / "runtime",
            env=env,
            stdin_text='(disk-save "../lib/runtime.com")\n',
            label="lib/runtime.com",
        )
        run_cmd(
            [str(target_scheme), "--batch-mode", "--library", "lib", "--band", "runtime.com"],
            cwd=SRC_DIR,
            env=env,
            stdin_text=(
                "(begin\n"
                "  (load-option (quote compiler))\n"
                "  (load-option (quote sf))\n"
                '  (disk-save "lib/all.com"))\n'
            ),
            label="lib/all.com",
        )

    def compile_libraries(self, target_scheme: Path) -> None:
        env = self.target_env(target_scheme)
        run_cmd(
            [str(target_scheme), "--batch-mode", "--library", "lib", "--no-init-file"],
            cwd=SRC_DIR,
            env=env,
            stdin_text='(with-working-directory-pathname "libraries" (lambda () (load "compile")))\n',
            label="compile-libraries",
        )

    def compile_plugin(self, name: str, target_scheme: Path) -> None:
        pdir = SRC_DIR / name
        if not pdir.is_dir():
            raise SystemExit(f"error: plugin directory not found: {pdir}")

        if name in ("edwin", "imail", "x11-screen"):
            env = self.target_env(target_scheme)
            run_cmd(["sh", "./compile.sh"], cwd=pdir, env=env, label=f"plugin:{name}")
            return

        if name not in C_FFI_PLUGINS:
            raise SystemExit(f"error: unknown plugin: {name}")

        # Remove stale libtool artifacts so Scheme loads <name>-shim.so directly.
        remove_path(pdir / f"{name}-shim.la")
        remove_path(pdir / ".libs")

        zig = resolve_zig()
        exe_ext = ".exe" if platform.system() == "Windows" else ""
        inc_dir = self.make_temp_lib_symlink(SRC_DIR / "lib")

        extra_cflags: list[str] = []
        extra_libs: list[str] = []
        zig_root: str | None = None
        translate_info: tuple[str, str] | None = None  # (c_mod_name, header_filename)

        if name == "blowfish":
            zig_root = "blowfish_adapter.zig"
        elif name == "gdbm":
            zig_root = "gdbm_adapter.zig"
            translate_info = ("gdbm_c", "gdbm-shim.h")
            extra_cflags, extra_libs = gdbm_flags()
        elif name == "pgsql":
            extra_cflags, extra_libs = libpq_flags()
        else:  # x11
            zig_root = "x11.zig"
            translate_info = ("x11_c", "x11.h")
            extra_cflags, extra_libs = x11_flags()

        inc_dirs, other_cflags, lib_dirs, link_args = split_pkg_flags(extra_cflags, extra_libs)

        scheme_env = self.target_env(target_scheme, prepend_dir=pdir)
        run_cmd(
            [str(target_scheme), "--batch-mode"],
            cwd=pdir,
            env=scheme_env,
            stdin_text=f'(generate-shim "{name}" "#include \\"{name}-shim.h\\"")\n',
            label=f"plugin:{name}:shim",
        )

        with tempfile.TemporaryDirectory(prefix=f"mit-scheme-plugin-{name}-") as tmpdir_raw:
            tmp_dir = Path(tmpdir_raw)
            zig_cache = tmp_dir / "zig-cache"
            zig_cache.mkdir(parents=True, exist_ok=True)
            zig_env = darwin_zig_env()
            zig_env["ZIG_LOCAL_CACHE_DIR"] = str(zig_cache)

            const_exe = pdir / f"{name}-const{exe_ext}"
            run_cmd(
                [
                    zig,
                    "cc",
                    "-O2",
                    f"-I{pdir}",
                    f"-I{inc_dir}",
                    *extra_cflags,
                    "-o",
                    str(const_exe),
                    f"{name}-const.c",
                ],
                cwd=pdir,
                env=zig_env,
                label=f"plugin:{name}:const-cc",
            )
            run_cmd([str(const_exe)], cwd=pdir, label=f"plugin:{name}:const-gen")
            run_cmd(
                [str(target_scheme), "--batch-mode"],
                cwd=pdir,
                env=scheme_env,
                stdin_text=f'(sf "{name}-const")\n',
                label=f"plugin:{name}:const-sf",
            )

            lib_cmd = [
                zig,
                "build-lib",
                "-dynamic",
                "-fallow-shlib-undefined",
                "-O",
                zig_opt_mode(self.args.optimize),
                "-fPIC",
                "-fno-sanitize-c",
                "-lc",
                "--cache-dir",
                str(zig_cache),
                f"-femit-bin={pdir / f'{name}-shim.so'}",
                f"-I{pdir}",
                f"-I{inc_dir}",
                *(f"-I{d}" for d in inc_dirs),
                *(f"-L{d}" for d in lib_dirs),
                *(arg for d in lib_dirs for arg in ("-rpath", d)),
            ]

            if translate_info is not None:
                c_mod_name, header_name = translate_info
                tc_cmd = [
                    zig,
                    "translate-c",
                    "-lc",
                    f"-I{pdir}",
                    f"-I{inc_dir}",
                    *(f"-I{d}" for d in inc_dirs),
                    *other_cflags,
                    header_name,
                ]
                print(f"[plugin:{name}:translate-c] + {' '.join(shlex.quote(a) for a in tc_cmd)}", flush=True)
                tc_res = subprocess.run(tc_cmd, cwd=pdir, env=zig_env, capture_output=True, text=True)
                if tc_res.returncode != 0:
                    raise SystemExit(
                        f"error: zig translate-c failed for plugin '{name}':\n{tc_res.stderr}"
                    )
                c_mod_file = tmp_dir / f"{c_mod_name}.zig"
                c_mod_file.write_text(tc_res.stdout, encoding="utf-8")
                lib_cmd.extend([
                    "--dep",
                    c_mod_name,
                    f"-Mroot={zig_root}",
                    f"-M{c_mod_name}={c_mod_file}",
                ])
            elif zig_root is not None:
                lib_cmd.append(zig_root)

            if other_cflags:
                lib_cmd.extend(["-cflags", *other_cflags, "--"])
            lib_cmd.append(f"{name}-shim.c")
            lib_cmd.extend(link_args)

            run_cmd(
                lib_cmd,
                cwd=pdir,
                env=zig_env,
                label=f"plugin:{name}:so",
            )

        run_cmd(
            ["sh", "./compile.sh"],
            cwd=pdir,
            env=self.target_env(target_scheme),
            label=f"plugin:{name}:scm",
        )

    def build_all(self) -> None:
        target_scheme = self.resolve_target_scheme(build_if_needed=True)
        host_exe, host_lib, has_runtime_com = self.resolve_host_scheme()
        self.setup_tree_links()
        self.generate_standard_libs(host_exe, host_lib)
        self.generate_svm1_defns(host_exe, host_lib, has_runtime_com)
        if self.args.cross:
            self.build_cross_toolchain(host_exe, host_lib, has_runtime_com)
        self.compile_core_subsystems(host_exe, host_lib, has_runtime_com, self.args.cross)
        self.finish_cross_target(target_scheme, self.args.cross)
        self.build_bands(target_scheme)
        self.compile_libraries(target_scheme)
        for plugin in self.plugins:
            self.compile_plugin(plugin, target_scheme)

    def copy_globs(self, src_dir: Path, dst_dir: Path, patterns: tuple[str, ...]) -> None:
        dst_dir.mkdir(parents=True, exist_ok=True)
        for pat in patterns:
            for item in sorted(src_dir.glob(pat)):
                if item.is_file():
                    shutil.copy2(item, dst_dir / item.name)

    def copy_exact(self, src_file: Path, dst_dir: Path) -> None:
        if not src_file.is_file():
            raise SystemExit(f"error: expected built file missing: {src_file}")
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_file, dst_dir / src_file.name)

    def install_all(self) -> None:
        prefix = Path(self.args.prefix or (REPO_ROOT / "zig-out")).resolve()
        target_scheme = self.resolve_target_scheme(build_if_needed=False)
        bindir = prefix / "bin"
        auxdir = prefix / "lib" / self.auxdir_name
        exe_ext = ".exe" if platform.system() == "Windows" else ""

        runtime_com = SRC_DIR / "lib" / "runtime.com"
        all_com = SRC_DIR / "lib" / "all.com"
        if not runtime_com.is_file() or not all_com.is_file():
            raise SystemExit(
                f"error: built bands missing in {SRC_DIR / 'lib'}; run `zig build scheme` (or tools/build-scheme.py build) first"
            )

        bindir.mkdir(parents=True, exist_ok=True)
        auxdir.mkdir(parents=True, exist_ok=True)

        # Avoid shutil.SameFileError if scheme_exe already lives under prefix/bin.
        scheme_real = target_scheme.resolve()
        for bin_name in (f"{self.auxdir_name}{exe_ext}", f"mit-scheme{exe_ext}", f"scheme{exe_ext}"):
            dest = bindir / bin_name
            if not (dest.exists() and dest.resolve() == scheme_real):
                shutil.copy2(scheme_real, dest)
                dest.chmod(0o755)

        if platform.system() == "Darwin":
            starter = self.resolve_macosx_starter()
            if starter is not None:
                dest_starter = auxdir / "macosx-starter"
                if not (dest_starter.exists() and dest_starter.resolve() == starter.resolve()):
                    shutil.copy2(starter, dest_starter)
                    dest_starter.chmod(0o755)

        shutil.copy2(SRC_DIR / "microcode" / "pruxffi.h", auxdir / "mit-scheme.h")
        shutil.copy2(SRC_DIR / "etc" / "optiondb.scm", auxdir / "optiondb.scm")
        shutil.copy2(SRC_DIR / "etc" / "plugins.scm", auxdir / "plugins.scm")
        shutil.copy2(runtime_com, auxdir / "runtime.com")
        shutil.copy2(all_com, auxdir / "all.com")

        # runtime/
        rundir = auxdir / "runtime"
        remove_path(rundir)
        self.copy_globs(SRC_DIR / "runtime", rundir, ("*.pkd", "*.bci"))
        self.copy_exact(SRC_DIR / "runtime" / "optiondb.scm", rundir)
        for mod in RUNTIME_INSTALL_COMS:
            self.copy_exact(SRC_DIR / "runtime" / f"{mod}.com", rundir)

        # compiler/
        compdir = auxdir / "compiler"
        remove_path(compdir)
        self.copy_globs(SRC_DIR / "compiler", compdir, ("compiler-*.pkd",))
        for sub in COMPILER_SUBDIRS:
            self.copy_globs(SRC_DIR / "compiler" / sub, compdir / sub, ("*.com", "*.bci"))

        # cref/, sf/
        for mod in CORE_SIMPLE_MODULES:
            dst = auxdir / mod
            remove_path(dst)
            self.copy_globs(SRC_DIR / mod, dst, ("*.com", "*.pkd", "*.bci"))

        # ffi/
        ffidir = auxdir / "ffi"
        remove_path(ffidir)
        self.copy_globs(SRC_DIR / "ffi", ffidir, ("*.com", "*.bci", "ffi-*.pkd"))
        self.copy_exact(SRC_DIR / "ffi" / "make.scm", ffidir)

        # libraries/
        libdir = auxdir / "libraries"
        remove_path(libdir)
        self.copy_globs(SRC_DIR / "libraries", libdir, ("*.comld", "*.bcild"))

        # sos/, ssp/, star-parser/, xml/
        for mod in CORE_LOAD_MODULES:
            dst = auxdir / mod
            remove_path(dst)
            self.copy_globs(SRC_DIR / mod, dst, ("*.com", "*.pkd", "*.bci"))
            self.copy_exact(SRC_DIR / mod / "load.scm", dst)

        # Installed plugins
        env = self.target_env(target_scheme)
        for plugin in self.plugins:
            self.install_plugin(plugin, auxdir, target_scheme, env)

    def install_plugin(
        self, name: str, auxdir: Path, target_scheme: Path, env: dict[str, str]
    ) -> None:
        pdir = SRC_DIR / name
        dst = auxdir / name
        if name == "edwin":
            remove_path(dst)
            self.copy_globs(
                pdir, dst, ("*.scm", "*.com", "*.bci", "edwin-*.pkd")
            )
            for fn in ("loadef.scm", "edwin.bld", "make.scm", "edwin.pkg", "TUTORIAL"):
                self.copy_exact(pdir / fn, dst)
        elif name == "imail":
            remove_path(dst)
            self.copy_globs(pdir, dst, ("*.scm", "*.com", "*.bci", "imail-*.pkd"))
            for fn in ("make.scm", "imail.pkg"):
                self.copy_exact(pdir / fn, dst)
            self.register_plugin(name, auxdir, target_scheme, env)
        elif name == "x11-screen":
            remove_path(dst)
            self.copy_globs(pdir, dst, ("*.scm", "*.com", "*.bci", "x11-screen-*.pkd"))
            self.copy_exact(pdir / "make.scm", dst)
        elif name in C_FFI_PLUGINS:
            self.copy_exact(pdir / f"{name}-shim.so", auxdir)
            self.copy_exact(pdir / f"{name}-types.bin", auxdir)
            self.copy_exact(pdir / f"{name}-const.bin", auxdir)
            remove_path(dst)
            self.copy_globs(pdir, dst, ("*.scm", "*.com", "*.bci", f"{name}-*.pkd"))
            self.copy_exact(pdir / "make.scm", dst)
            if name != "x11":
                self.register_plugin(name, auxdir, target_scheme, env)

    def register_plugin(
        self, name: str, auxdir: Path, target_scheme: Path, env: dict[str, str]
    ) -> None:
        aux_str = f"{auxdir}{os.sep}"
        expr = f'(add-plugin "{name}" "mit-scheme" "" "{aux_str}" "")\n'
        run_cmd(
            [str(target_scheme), "--batch-mode"],
            cwd=SRC_DIR,
            env=env,
            stdin_text=expr,
            label=f"add-plugin:{name}",
        )

    def clean_all(self) -> None:
        for rel in (
            "lib",
            "mit-scheme.app",
            "tmp",
            "runtime/generated-standard-libs",
            "makefiles_created",
            "dummy-config.h",
            "dummy-config.h.in",
            "config.log",
            "config.status",
            "Makefile",
            "Makefile.tools",
            "autom4te.cache",
            "boot-root",
            "c-boot-compiler.com",
            "native-boot-compiler.com",
        ):
            remove_path(SRC_DIR / rel)

        for p in SRC_DIR.glob("stamp_*"):
            remove_path(p)

        tools_dir = SRC_DIR / "tools"
        if tools_dir.is_dir():
            for child in tools_dir.iterdir():
                if child.name not in (".gitignore", "README"):
                    remove_path(child)

        comp_dir = SRC_DIR / "compiler"
        for rel in ("machine", "compiler.cbf", "compiler.pkg", "compiler.sf", "make.com", "make.bin", "make.so"):
            remove_path(comp_dir / rel)
        for rel in (
            "machines/svm/wordsize.scm",
            "machines/svm/endian.scm",
            "machines/svm/assembler-db.scm",
            "machines/svm/assembler-rules.exp",
            "machines/svm/svm1-defns.h",
            "machines/svm/svm1-opcodes.scm",
        ):
            remove_path(comp_dir / rel)

        for base_dir, rels in ((SRC_DIR, SRC_CLEAN_DIRS), (TESTS_DIR, TEST_CLEAN_DIRS)):
            for rel in rels:
                d = base_dir / rel
                if not d.is_dir():
                    continue
                for pat in SCHEME_ARTIFACT_PATTERNS:
                    for item in d.glob(pat):
                        if item.is_file() or item.is_symlink():
                            item.unlink()
                for extra in ("stamp-scheme", "stamp-shim", "edwin.bld"):
                    remove_path(d / extra)
                for generated_link in ("Clean.sh", "Setup.sh", "Stage.sh", "Tags.sh", ".edwin-ffi", "Makefile", "Makefile.in"):
                    p = d / generated_link
                    if p.is_symlink():
                        p.unlink()

        for d in (
            *(SRC_DIR / name for name in C_FFI_PLUGINS),
            TESTS_DIR / "ffi",
        ):
            if not d.is_dir():
                continue
            prefix = "ffi-test" if d == TESTS_DIR / "ffi" else d.name
            for extra in (
                f"{prefix}-const",
                f"{prefix}-const.exe",
                f"{prefix}-const.c",
                f"{prefix}-const.scm",
                f"{prefix}-shim.c",
                f"{prefix}-shim.so",
                f"{prefix}-shim.la",
                f"{prefix}-shim.lo",
                ".libs",
                ".deps",
                "test-ffi-wrapper.com",
                "test-ffi-wrapper.bci",
                "ffi-test.c",
            ):
                if extra == "ffi-test.c" and d == TESTS_DIR / "ffi":
                    # Preserve tracked C test fixture in tests/ffi/ffi-test.c.
                    continue
                remove_path(d / extra)
            for pat in ("*.o", "*.lo", "*.la"):
                for item in d.glob(pat):
                    if item.is_file() or item.is_symlink():
                        item.unlink()
            for generated_link in ("Clean.sh", "Stage.sh", "Tags.sh", ".edwin-ffi", "Makefile", "Makefile.in"):
                p = d / generated_link
                if p.is_symlink():
                    p.unlink()


def add_common_flags(parser: argparse.ArgumentParser, use_suppress: bool) -> None:
    def dflt(val):
        return argparse.SUPPRESS if use_suppress else val

    parser.add_argument(
        "--arch",
        default=dflt("auto"),
        choices=("auto", *ARCH_CONFIGS.keys()),
        help="Target Scheme architecture (default: auto)",
    )
    parser.add_argument(
        "--optimize",
        default=dflt("ReleaseFast"),
        choices=("Debug", "ReleaseFast", "ReleaseSafe", "ReleaseSmall"),
        help="Zig optimization mode when building microcode (default: ReleaseFast)",
    )
    parser.add_argument(
        "--termcap",
        default=dflt(None),
        choices=("ncurses", "emulate", "none"),
        help="Termcap mode forwarded to zig build when building microcode",
    )
    parser.add_argument(
        "--debugging",
        action="store_true",
        default=dflt(False),
        help="Pass -Ddebugging=true when building microcode",
    )
    parser.add_argument(
        "--version",
        default=dflt("13.0.50"),
        help="MIT/GNU Scheme package version (default: 13.0.50)",
    )
    parser.add_argument(
        "--host-scheme",
        default=dflt(None),
        help="Host mit-scheme binary for compiling Scheme subsystems",
    )
    parser.add_argument(
        "--host-lib",
        default=dflt(None),
        help="Optional host Scheme library directory containing all.com",
    )
    parser.add_argument(
        "--cross",
        action="store_true",
        default=dflt(False),
        help="Enable Stage-2 cross-compilation using src/tools/ cross-toolchain",
    )
    parser.add_argument(
        "--plugins",
        default=dflt("edwin,imail"),
        help="Comma-separated plugins to build/install, or 'none' (default: edwin,imail)",
    )
    parser.add_argument(
        "--prefix",
        default=dflt(None),
        help="Install prefix (default: <repo>/zig-out)",
    )
    parser.add_argument(
        "--scheme-exe",
        default=dflt(None),
        help="Path to pre-built target microcode executable",
    )
    parser.add_argument(
        "--macosx-starter",
        default=dflt(None),
        help="Optional pre-built macosx-starter executable (Darwin)",
    )
    parser.add_argument(
        "--skip-microcode",
        action="store_true",
        default=dflt(False),
        help="Do not invoke zig build for the microcode binary",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=dflt(None),
        help="Maximum parallel Scheme compiler tasks",
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    add_common_flags(parser, use_suppress=False)
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="Build Scheme subsystems, bands, libraries, and plugins")
    add_common_flags(p_build, use_suppress=True)
    p_build.add_argument(
        "--install",
        action="store_true",
        help="Also install into --prefix after building",
    )

    p_install = sub.add_parser("install", help="Install Scheme binary, bands, core subsystems, and plugins")
    add_common_flags(p_install, use_suppress=True)

    p_plugin = sub.add_parser("plugin", help="Build a single plugin in src/<name>")
    add_common_flags(p_plugin, use_suppress=True)
    p_plugin.add_argument("plugin_name", choices=ALL_PLUGINS, help="Plugin name")

    p_clean = sub.add_parser("clean", help="Clean Scheme build artifacts, bands, and staging symlinks")
    add_common_flags(p_clean, use_suppress=True)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    ctx = SchemeContext(args)
    try:
        if args.command == "build":
            ctx.build_all()
            if getattr(args, "install", False):
                ctx.install_all()
        elif args.command == "install":
            ctx.install_all()
        elif args.command == "plugin":
            target_scheme = ctx.resolve_target_scheme(build_if_needed=True)
            ctx.compile_plugin(args.plugin_name, target_scheme)
        elif args.command == "clean":
            ctx.clean_all()
    finally:
        ctx.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
