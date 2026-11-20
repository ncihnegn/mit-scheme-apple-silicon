#!/usr/bin/env python3
"""Run or parse `make check` output and fail on unexpected test failures."""

import argparse
import os
import re
import subprocess
import sys
import tempfile

RUNNING_RE = re.compile(r'^;Running tests in "([^"]+)"')
SUMMARY_HEADER_RE = re.compile(r'^Test results:\s*$')
RESULT_LINE_RE = re.compile(r'^(PASSED|FAILED):\s*"([^"]+)"\s*$')
SUBTEST_FAILED_RE = re.compile(r'^;([^\s]+)\s+failed\s+\d+\s+sub-tests\s+out\s+of\s+\d+')
ALLOWED_DETAIL_RE = re.compile(
    r'(?:untrap-float-exceptions|trap-float-exceptions|not implemented|'
    r'external return|did not signal|hardware trap)',
    re.IGNORECASE,
)


def extract_section(lines, target_suite):
    """Return log lines belonging to `target_suite`, or None if absent."""
    in_section = False
    section = []
    for line in lines:
        m = RUNNING_RE.match(line)
        if m:
            if in_section:
                break
            if m.group(1) == target_suite:
                in_section = True
                section.append(line)
                continue
        elif in_section:
            if SUMMARY_HEADER_RE.match(line):
                break
            section.append(line)
    return section if in_section else None


def verify_arm64_flonum_except(lines):
    """Ensure every failure in microcode/test-flonum-except is an expected /trap failure."""
    section = extract_section(lines, "microcode/test-flonum-except")
    if not section:
        return False, "missing log section for microcode/test-flonum-except"

    headers = []
    details_checked = 0
    in_failure_block = False
    for raw_line in section[1:]:
        line = raw_line.rstrip("\r\n")
        hm = SUBTEST_FAILED_RE.match(line)
        if hm:
            test_name = hm.group(1)
            headers.append(test_name)
            if not test_name.endswith("/trap"):
                return (
                    False,
                    f"non-/trap test failed in microcode/test-flonum-except: {test_name}",
                )
            in_failure_block = True
            continue
        if in_failure_block:
            if not line or line.startswith(";"):
                # Another top-level notification line ends this detail list unless
                # it is an indented detail line prefixed with ';'.
                if line.startswith(";    "):
                    detail = line[5:].strip()
                else:
                    in_failure_block = False
                    continue
            elif line.startswith("    "):
                detail = line[4:].strip()
            else:
                in_failure_block = False
                continue
            details_checked += 1
            if not ALLOWED_DETAIL_RE.search(detail):
                return (
                    False,
                    "unexpected failure reason in microcode/test-flonum-except: "
                    f"{detail}",
                )

    if not headers:
        return (
            False,
            "no ';... failed N sub-tests' header found in microcode/test-flonum-except",
        )
    if details_checked == 0:
        return (
            False,
            "no failure detail lines found in microcode/test-flonum-except",
        )
    return True, f"verified {len(headers)} /trap-only test failure(s) ({details_checked} sub-tests)"


def parse_summary(lines):
    """Parse final PASSED/FAILED summary block."""
    passed = []
    failed = []
    in_summary = False
    for raw_line in lines:
        line = raw_line.rstrip("\r\n")
        if SUMMARY_HEADER_RE.match(line):
            in_summary = True
            passed = []
            failed = []
            continue
        if in_summary:
            m = RESULT_LINE_RE.match(line)
            if m:
                tag, name = m.group(1), m.group(2)
                if tag == "PASSED":
                    passed.append(name)
                else:
                    failed.append(name)
    return in_summary, passed, failed


def _stream_subprocess(cmd, env, cwd=None):
    """Run cmd </dev/null with streaming combined stdout/stderr capture."""
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        bufsize=1,
    )
    lines = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line)
    rc = proc.wait()
    return rc, lines


def run_make_check(src_dir):
    """Execute FAST=y make -C <src_dir> check </dev/null and capture combined output."""
    env = os.environ.copy()
    env["FAST"] = "y"
    return _stream_subprocess(["make", "-C", src_dir, "check"], env=env)


def run_scheme_check(scheme_exe, src_dir, library_path, test_name=None):
    """Run tests/check.scm directly using scheme_exe against library_path."""
    abs_exe = os.path.abspath(scheme_exe)
    abs_src = os.path.abspath(src_dir)
    abs_lib = os.path.abspath(library_path or os.path.join(src_dir, "lib"))
    check_scm = os.path.abspath(os.path.join(abs_src, "..", "tests", "check.scm"))

    all_com = os.path.join(abs_lib, "all.com")
    if not os.path.isfile(all_com):
        print(
            f"error: library band not found at {all_com}; pass --library-path to a directory containing all.com",
            file=sys.stderr,
        )
        return 1, []

    # MIT Scheme splits --library and MITSCHEME_LIBRARY_PATH on ':'; symlink if ':' appears (e.g. macOS .app bundle).
    tmpdir = None
    try:
        if ":" in abs_lib:
            tmpdir = tempfile.TemporaryDirectory(prefix="mit-scheme-lib-")
            effective_lib = os.path.join(tmpdir.name, "lib")
            os.symlink(abs_lib, effective_lib)
        else:
            effective_lib = abs_lib

        env = os.environ.copy()
        env["FAST"] = "y"
        env["MIT_SCHEME_EXE"] = abs_exe
        env["MITSCHEME_LIBRARY_PATH"] = effective_lib
        env["MITSCHEME_INF_DIRECTORY"] = effective_lib
        if test_name:
            env["TEST"] = test_name

        return _stream_subprocess(
            [
                abs_exe,
                "--batch-mode",
                "--library",
                effective_lib,
                "--load",
                check_scm,
                "--eval",
                "(%exit)",
            ],
            env=env,
            cwd=abs_src,
        )
    finally:
        if tmpdir is not None:
            tmpdir.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src-dir", default="src", help="Path to mit-scheme src/ directory")
    parser.add_argument("--log", help="Parse existing make check log instead of running make")
    parser.add_argument(
        "--scheme-exe",
        help="Path to MIT/GNU Scheme executable to test directly against tests/check.scm",
    )
    parser.add_argument(
        "--library-path",
        help="Scheme library directory containing all.com (defaults to <src-dir>/lib with --scheme-exe)",
    )
    parser.add_argument(
        "--test",
        help="Single test suite name from tests/check.scm to run (sets TEST=<name>)",
    )
    parser.add_argument(
        "--min-passed",
        type=int,
        default=None,
        help="Minimum required PASSED test suites (default: 1 with --test, else 100)",
    )
    parser.add_argument(
        "--allow-arm64-flonum-except",
        action="store_true",
        help="Allow microcode/test-flonum-except iff all failures are /trap FP-trap errors",
    )
    parser.add_argument("--save-log", help="Write captured make check output to this file")
    args = parser.parse_args()

    min_passed = (
        args.min_passed
        if args.min_passed is not None
        else (1 if args.test else 100)
    )

    if args.log:
        with open(args.log, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        rc = 0
    else:
        if args.scheme_exe:
            rc, lines = run_scheme_check(
                args.scheme_exe,
                args.src_dir,
                args.library_path,
                test_name=args.test,
            )
        else:
            rc, lines = run_make_check(args.src_dir)
        if args.save_log:
            with open(args.save_log, "w", encoding="utf-8") as f:
                f.writelines(lines)
        if rc != 0:
            runner = "scheme check" if args.scheme_exe else "make check"
            print(f"error: {runner} exited with status {rc}", file=sys.stderr)
            return rc

    saw_summary, passed, failed = parse_summary(lines)
    if not saw_summary:
        print("error: 'Test results:' summary block not found in test output", file=sys.stderr)
        return 1

    if len(passed) < min_passed:
        print(
            f"error: only {len(passed)} suites passed (expected at least {min_passed})",
            file=sys.stderr,
        )
        return 1

    unexpected_failures = []
    allowed_notes = []
    for suite in failed:
        if suite == "microcode/test-flonum-except" and args.allow_arm64_flonum_except:
            ok, msg = verify_arm64_flonum_except(lines)
            if ok:
                allowed_notes.append(f"{suite}: {msg}")
            else:
                unexpected_failures.append(f"{suite} ({msg})")
        else:
            unexpected_failures.append(suite)

    print(
        f"Summary: {len(passed)} passed, {len(failed)} failed "
        f"(min_passed={min_passed})"
    )
    for note in allowed_notes:
        print(f"Allowed xfail: {note}")

    if unexpected_failures:
        print("Unexpected failures:", file=sys.stderr)
        for item in unexpected_failures:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print("CHECK_RESULTS_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
