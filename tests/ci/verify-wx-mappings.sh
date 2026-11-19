#!/bin/bash
#
# Verify OS virtual memory protections for a live native Scheme process:
# - the code_arena mapping covering (code-space-bounds) is executable;
# - the heap (>= 8 MiB anonymous region) is mapped RW without execute permission;
# - no unexpected anonymous region outside code_arena is currently executable.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
SCHEME_EXE="${REPO_ROOT}/src/microcode/scheme"
LIBRARY_DIR="${REPO_ROOT}/src/lib"

usage() {
    cat <<EOF
Usage: $0 [--scheme PATH] [--library PATH]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --scheme)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SCHEME_EXE=$2
            shift 2
            ;;
        --library)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            LIBRARY_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

exec python3 - "${SCHEME_EXE}" "${LIBRARY_DIR}" <<'PY'
import os
import platform
import re
import subprocess
import sys
import time

scheme_exe, library_dir = sys.argv[1], sys.argv[2]

expr = (
    '(begin '
    '  (let ((f (compile-procedure (lambda (x) (+ x 1))))) '
    '    (if (not (= (f 41) 42)) (error "compile-procedure failed"))) '
    '  (let ((b (code-space-bounds))) '
    '    (display "READY ") '
    '    (display (number->string (car b) 16)) '
    '    (display " ") '
    '    (display (number->string (cdr b) 16)) '
    '    (newline) '
    '    (flush-output-port)) '
    '  (let loop () (sleep-current-thread 1000) (loop)))'
)

cmd = [
    scheme_exe,
    "--library", library_dir,
    "--band", "all.com",
    "--batch-mode",
    "--no-init-file",
    "--eval", expr,
]

proc = subprocess.Popen(
    cmd,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)

def verify_darwin(pid, code_start):
    vm = subprocess.run(
        ["vmmap", "-v", str(pid)],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if vm.returncode != 0:
        raise RuntimeError(f"vmmap -v {pid} failed ({vm.returncode}): {vm.stderr}")

    # Match region lines such as:
    # Untagged    110110000-110114000 [  16K ...] rwx/rwx SM=ZER ...
    # VM_ALLOCATE 104000000-108000000 [64.0M ...] rw-/rwx SM=PRV ...
    region_re = re.compile(
        r'^(.+?)\s+([0-9a-fA-F]+)-([0-9a-fA-F]+)\s+\[([^\]]+)\]\s+'
        r'([r-][w-][x-])/([r-][w-][x-])\s+(.*)$'
    )
    in_regions = False
    regions = []

    for line in vm.stdout.splitlines():
        if "REGION TYPE" in line and "PRT/MAX" in line:
            in_regions = True
            continue
        if in_regions and line.startswith("==== "):
            # Continue scanning subsequent NON-WRITABLE / WRITABLE sections if any.
            continue
        m = region_re.match(line)
        if not m:
            continue
        rtype = m.group(1).strip()
        start = int(m.group(2), 16)
        end = int(m.group(3), 16)
        cur_prot, max_prot = m.group(5), m.group(6)
        rest = m.group(7)

        # File-backed regions carry a path starting with '/' or belong to Mach-O
        # image segments (__TEXT, __LINKEDIT, etc.).
        has_file_path = (" /" in rest) or rest.strip().startswith("/")
        is_anon = (
            rtype == "Untagged"
            or rtype.startswith("VM_ALLOCATE")
            or rtype.startswith("MALLOC")
            or rtype.startswith("Malloc")
            or rtype in ("Stack", "STACK GUARD", "dyld private memory")
            or (rtype == "mapped file" and not has_file_path)
        )
        regions.append((start, end, rtype, cur_prot, max_prot, is_anon, line.strip()))

    # Coalesce contiguous anonymous executable regions (vmmap splits a single
    # MAP_JIT reservation into multiple sub-ranges by residency/zerofill state).
    exec_runs = []
    for start, end, rtype, cur_prot, max_prot, is_anon, raw in regions:
        if not is_anon or ("x" not in cur_prot):
            continue
        if exec_runs and exec_runs[-1][1] == start:
            prev = exec_runs[-1]
            exec_runs[-1] = (prev[0], end, prev[2], prev[3] + [raw])
        else:
            exec_runs.append((start, end, cur_prot, [raw]))

    code_run = None
    unexpected_anon_exec = []
    for r_start, r_end, cur_prot, raws in exec_runs:
        if r_start <= code_start < r_end:
            code_run = (r_start, r_end, cur_prot, raws)
        else:
            unexpected_anon_exec.extend(raws)

    large_nx_heap = None
    for start, end, rtype, cur_prot, max_prot, is_anon, raw in regions:
        if code_run and (code_run[0] <= start < code_run[1]):
            continue
        size = end - start
        if (
            (rtype == "Untagged" or rtype.startswith("VM_ALLOCATE"))
            and cur_prot == "rw-"
            and size >= 8 * 1024 * 1024
        ):
            if large_nx_heap is None or size > large_nx_heap[0]:
                large_nx_heap = (size, raw)

    if code_run is None:
        raise RuntimeError(f"Did not find vmmap executable region covering code_start=0x{code_start:x}")
    if large_nx_heap is None:
        raise RuntimeError("Did not find >= 8 MiB rw- anonymous NX Scheme heap region")
    if unexpected_anon_exec:
        raise RuntimeError(
            "Found unexpected anonymous executable mapping(s):\n"
            + "\n".join(unexpected_anon_exec)
        )
    print(
        f"Verified code_arena region: 0x{code_run[0]:x}-0x{code_run[1]:x} "
        f"({code_run[2]}, {len(code_run[3])} vmmap slices)"
    )
    print(f"Verified NX Scheme heap:   {large_nx_heap[1]}")


def verify_linux(pid, code_start):
    maps_path = f"/proc/{pid}/maps"
    with open(maps_path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()

    map_re = re.compile(
        r'^([0-9a-fA-F]+)-([0-9a-fA-F]+)\s+([rwxsp-]+)\s+[0-9a-fA-F]+\s+\S+\s+\d+(?:\s+(.*))?$'
    )
    code_region = None
    large_nx_heap = None
    unexpected_anon_exec = []

    for line in lines:
        m = map_re.match(line)
        if not m:
            continue
        start = int(m.group(1), 16)
        end = int(m.group(2), 16)
        perms = m.group(3)
        path = (m.group(4) or "").strip()
        size = end - start

        is_code = (start <= code_start < end)
        is_anon = (path == "" or path.startswith("[anon") or path in ("[heap]", "[stack]"))
        if is_code:
            code_region = (line, perms, path)
        elif is_anon and ("x" in perms):
            unexpected_anon_exec.append(line)

        if is_anon and not is_code and perms.startswith("rw-") and size >= 8 * 1024 * 1024:
            if large_nx_heap is None or size > large_nx_heap[0]:
                large_nx_heap = (size, line)

    if code_region is None:
        raise RuntimeError(f"Did not find /proc/{pid}/maps region for 0x{code_start:x}")
    if "x" not in code_region[1]:
        raise RuntimeError(f"code_arena region is not executable: {code_region[0]}")
    if large_nx_heap is None:
        raise RuntimeError("Did not find >= 8 MiB rw- anonymous NX Scheme heap region")
    if unexpected_anon_exec:
        raise RuntimeError(
            "Found unexpected anonymous executable mapping(s):\n"
            + "\n".join(unexpected_anon_exec)
        )
    print(f"Verified code_arena region: {code_region[0]}")
    print(f"Verified NX Scheme heap:   {large_nx_heap[1]}")


try:
    assert proc.stdout is not None
    deadline = time.monotonic() + 30.0
    code_start = None
    seen = []
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        seen.append(line.rstrip("\r\n"))
        m = re.match(r'^READY\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s*$', line)
        if m:
            code_start = int(m.group(1), 16)
            break

    if code_start is None:
        raise RuntimeError(
            "Scheme process failed to report READY code bounds; output:\n"
            + "\n".join(seen)
        )

    sysname = platform.system()
    if sysname == "Darwin":
        verify_darwin(proc.pid, code_start)
    elif sysname == "Linux":
        verify_linux(proc.pid, code_start)
    else:
        raise RuntimeError(f"Unsupported OS for verify-wx-mappings: {sysname}")

    print("WX_MAPPINGS_OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY
