#!/usr/bin/env python3
"""Run or parse `make check` output and fail on unexpected test failures."""

import argparse
import os
import re
import subprocess
import sys

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


def run_make_check(src_dir):
    """Execute FAST=y make -C <src_dir> check </dev/null and capture combined output."""
    env = os.environ.copy()
    env["FAST"] = "y"
    proc = subprocess.Popen(
        ["make", "-C", src_dir, "check"],
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src-dir", default="src", help="Path to mit-scheme src/ directory")
    parser.add_argument("--log", help="Parse existing make check log instead of running make")
    parser.add_argument(
        "--min-passed",
        type=int,
        default=100,
        help="Minimum required PASSED test suites (default: 100)",
    )
    parser.add_argument(
        "--allow-arm64-flonum-except",
        action="store_true",
        help="Allow microcode/test-flonum-except iff all failures are /trap FP-trap errors",
    )
    parser.add_argument("--save-log", help="Write captured make check output to this file")
    args = parser.parse_args()

    if args.log:
        with open(args.log, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        rc = 0
    else:
        rc, lines = run_make_check(args.src_dir)
        if args.save_log:
            with open(args.save_log, "w", encoding="utf-8") as f:
                f.writelines(lines)
        if rc != 0:
            print(f"error: make check exited with status {rc}", file=sys.stderr)
            return rc

    saw_summary, passed, failed = parse_summary(lines)
    if not saw_summary:
        print("error: 'Test results:' summary block not found in make check output", file=sys.stderr)
        return 1

    if len(passed) < args.min_passed:
        print(
            f"error: only {len(passed)} suites passed (expected at least {args.min_passed})",
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
        f"(min_passed={args.min_passed})"
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
