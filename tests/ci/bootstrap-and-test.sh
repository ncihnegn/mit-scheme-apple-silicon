#!/bin/bash
#
# End-to-end AArch64 native bootstrap, build, and verification driver.
# Supports macOS Apple silicon (macos-latest arm64) and Linux aarch64.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
SRC_DIR="${REPO_ROOT}/src"

NATIVE_HOST=""
STAGE2_PREFIX=""
HOST_SCHEME=""
HOST_LIB=""
JOBS=""
SKIP_BUILD=0
SKIP_CHECK=0
SKIP_MACOS_APP=0
STAGE2_ONLY=0
CLEAN_AFTER=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
  --native-host PATH     Existing 13.x native aarch64le mit-scheme binary (skips Stage 1 & Stage 2)
  --stage2-prefix PATH   Install prefix for Stage 2 native host (default: temp dir)
  --stage2-only          Bootstrap and install Stage 2 native host only, then exit
  --host-scheme PATH     Bootstrap host scheme binary (12.1 svm1 or patched 12.1 aarch64le)
  --host-lib PATH        Bootstrap host library directory
  --jobs N               Parallel build jobs (default: CPU count)
  --skip-build           Skip build stages; run verification against existing src/ build
  --skip-check           Skip Scheme test suite check
  --skip-macos-app       Skip macOS app bundle build/codesign verification
  --clean-after          Remove build and test artifacts from working tree when done
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --native-host)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            NATIVE_HOST=$2
            shift 2
            ;;
        --stage2-prefix)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            STAGE2_PREFIX=$2
            shift 2
            ;;
        --host-scheme)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            HOST_SCHEME=$2
            shift 2
            ;;
        --host-lib)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            HOST_LIB=$2
            shift 2
            ;;
        --jobs)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            JOBS=$2
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --skip-check)
            SKIP_CHECK=1
            shift
            ;;
        --skip-macos-app)
            SKIP_MACOS_APP=1
            shift
            ;;
        --stage2-only)
            STAGE2_ONLY=1
            shift
            ;;
        --clean-after)
            CLEAN_AFTER=1
            shift
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

SYSNAME=$(uname -s)
if [ -z "${JOBS}" ]; then
    if [ "${SYSNAME}" = "Darwin" ]; then
        JOBS=$(sysctl -n hw.ncpu)
    else
        JOBS=$(nproc)
    fi
fi

WORK_TMP=$(mktemp -d)
VERIFY_TMP=$(mktemp -d)
cleanup() {
    rm -rf "${WORK_TMP}" "${VERIFY_TMP}"
}
trap cleanup EXIT

clean_tree() {
    python3 "${REPO_ROOT}/tools/build-scheme.py" clean
}

resolve_host_scheme_and_lib() {
    if [ -z "${HOST_SCHEME}" ]; then
        if ! HOST_SCHEME=$(command -v mit-scheme 2>/dev/null); then
            echo "error: no --host-scheme supplied and 'mit-scheme' is not in PATH" >&2
            exit 1
        fi
    fi
    if [ -z "${HOST_LIB}" ]; then
        local real_scheme
        real_scheme=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${HOST_SCHEME}")
        local real_prefix
        real_prefix=$(cd "$(dirname "${real_scheme}")/.." && pwd)
        for cand in "${real_prefix}"/lib/mit-scheme-*; do
            if [ -d "${cand}" ]; then
                HOST_LIB="${cand}"
                break
            fi
        done
        if [ -z "${HOST_LIB}" ] && [ "${SYSNAME}" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
            local brew_ms
            brew_ms=$(brew --prefix mit-scheme 2>/dev/null || true)
            if [ -n "${brew_ms}" ]; then
                for cand in "${brew_ms}"/lib/mit-scheme-*; do
                    if [ -d "${cand}" ]; then
                        HOST_LIB="${cand}"
                        break
                    fi
                done
            fi
        fi
    fi
}

query_compiled_code_type() {
    local exe="$1"
    local lib="$2"
    if [ -n "${lib}" ]; then
        "${exe}" --library "${lib}" --batch-mode --no-init-file \
            --eval '(begin (write microcode-id/compiled-code-type) (newline) (%exit))' \
            </dev/null
    else
        "${exe}" --batch-mode --no-init-file \
            --eval '(begin (write microcode-id/compiled-code-type) (newline) (%exit))' \
            </dev/null
    fi
}

prepare_stage1_host() {
    resolve_host_scheme_and_lib
    local host_arch
    host_arch=$(query_compiled_code_type "${HOST_SCHEME}" "${HOST_LIB}" | tr -d '[:space:]')
    echo "=== Bootstrap host: ${HOST_SCHEME} (arch=${host_arch}, lib=${HOST_LIB:-default}) ==="

    local wrapper="${WORK_TMP}/stage1-host-scheme"
    if [ "${host_arch}" = "svm" ] || [ "${host_arch}" = "svm1" ]; then
        if [ -z "${HOST_LIB}" ] || [ ! -d "${HOST_LIB}" ]; then
            echo "error: svm1 host requires --host-lib pointing to its library directory" >&2
            exit 1
        fi
        echo "=== Stage 1: Building fixed svm1 microcode for safe fasdump ==="
        if [ "${SYSNAME}" = "Darwin" ] && [ -z "${DYLD_FALLBACK_LIBRARY_PATH:-}" ] && [ -d /usr/local/lib ]; then
            export DYLD_FALLBACK_LIBRARY_PATH="/usr/local/lib:/usr/lib"
        fi
        (cd "${REPO_ROOT}" && zig build -Darch=svm1_64le -Doptimize=ReleaseFast --prefix "${WORK_TMP}/stage1-svm1")
        cp "${WORK_TMP}/stage1-svm1/bin/mit-scheme" "${WORK_TMP}/svm1-scheme"
        chmod +x "${WORK_TMP}/svm1-scheme"
        cat > "${wrapper}" <<EOF
#!/bin/sh
: "\${MITSCHEME_LIBRARY_PATH:=${HOST_LIB}}"
export MITSCHEME_LIBRARY_PATH
exec "${WORK_TMP}/svm1-scheme" "\$@"
EOF
    else
        if [ -n "${HOST_LIB}" ]; then
            cat > "${wrapper}" <<EOF
#!/bin/sh
: "\${MITSCHEME_LIBRARY_PATH:=${HOST_LIB}}"
export MITSCHEME_LIBRARY_PATH
exec "${HOST_SCHEME}" "\$@"
EOF
        else
            cat > "${wrapper}" <<EOF
#!/bin/sh
exec "${HOST_SCHEME}" "\$@"
EOF
        fi
    fi
    chmod +x "${wrapper}"
    STAGE1_HOST_SCHEME="${wrapper}"
}

build_stage2() {
    if [ -z "${STAGE2_PREFIX}" ]; then
        STAGE2_PREFIX="${WORK_TMP}/stage2-native"
    fi
    clean_tree
    prepare_stage1_host
    echo "=== Stage 2: Cross-bootstrapping native aarch64le into ${STAGE2_PREFIX} ==="
    local build_args=(
        build --install
        --arch aarch64le
        --optimize ReleaseFast
        --cross
        --host-scheme "${STAGE1_HOST_SCHEME}"
        --prefix "${STAGE2_PREFIX}"
        --jobs "${JOBS}"
    )
    if [ -n "${HOST_LIB}" ]; then
        build_args+=(--host-lib "${HOST_LIB}")
    fi
    python3 "${REPO_ROOT}/tools/build-scheme.py" "${build_args[@]}"

    NATIVE_HOST="${STAGE2_PREFIX}/bin/mit-scheme"
    if ! "${NATIVE_HOST}" --batch-mode --no-init-file --eval '(%exit)' </dev/null >/dev/null 2>&1; then
        echo "error: Stage 2 installed binary failed sanity check: ${NATIVE_HOST}" >&2
        exit 1
    fi
    clean_tree
}

build_stage3() {
    echo "=== Stage 3: Clean self-hosted native rebuild (using ${NATIVE_HOST}) ==="
    clean_tree
    python3 "${REPO_ROOT}/tools/build-scheme.py" build \
        --arch aarch64le \
        --optimize ReleaseFast \
        --host-scheme "${NATIVE_HOST}" \
        --jobs "${JOBS}"
}

run_verifications() {
    local scheme_bin="${REPO_ROOT}/zig-out/bin/mit-scheme"
    local lib_dir="${SRC_DIR}/lib"
    local native_log="${VERIFY_TMP}/verify-native.log"
    local trap_log="${VERIFY_TMP}/verify-trap.log"

    if [ ! -x "${scheme_bin}" ]; then
        echo "error: built Scheme executable not found at ${scheme_bin}" >&2
        exit 1
    fi

    echo "=== Running standalone microcode Zig smoke tests ==="
    "${SCRIPT_DIR}/run-microcode-smoke.sh" \
        --ucode-dir "${SRC_DIR}/microcode" \
        --require-native

    echo "=== Verifying OS W^X virtual memory mappings ==="
    "${SCRIPT_DIR}/verify-wx-mappings.sh" \
        --scheme "${scheme_bin}" \
        --library "${lib_dir}"

    echo "=== Running end-to-end native AArch64 runtime & compiler tests ==="
    SCM_CI_TMPDIR="${VERIFY_TMP}" \
        "${scheme_bin}" \
            --library "${lib_dir}" \
            --band all.com \
            --batch-mode \
            --no-init-file \
            --load "${SCRIPT_DIR}/verify-native-aarch64.scm" \
            --eval '(%exit)' \
            </dev/null 2>&1 | tee "${native_log}"
    if ! grep -q 'ALL_VERIFY_NATIVE_OK' "${native_log}"; then
        echo "error: verify-native-aarch64.scm did not report ALL_VERIFY_NATIVE_OK" >&2
        exit 1
    fi

    echo "=== Running hardware SIGSEGV trap recovery test ==="
    SCM_CI_TMPDIR="${VERIFY_TMP}" \
        "${scheme_bin}" \
            --library "${lib_dir}" \
            --band all.com \
            --emacs \
            --batch-mode \
            --no-init-file \
            --load "${SCRIPT_DIR}/verify-trap.scm" \
            --eval '(%exit)' \
            </dev/null 2>&1 | tee "${trap_log}"
    if ! grep -q 'FORGE_TRAP_RECOVERY_OK' "${trap_log}"; then
        echo "error: verify-trap.scm did not report FORGE_TRAP_RECOVERY_OK" >&2
        exit 1
    fi

    if [ "${SKIP_CHECK}" -eq 0 ]; then
        echo "=== Running Scheme test suite ==="
        python3 "${SCRIPT_DIR}/check-results.py" \
            --src-dir "${SRC_DIR}" \
            --scheme-exe "${scheme_bin}" \
            --library-path "${lib_dir}" \
            --allow-arm64-flonum-except
    fi

    if [ "${SYSNAME}" = "Darwin" ] && [ "${SKIP_MACOS_APP}" -eq 0 ]; then
        "${SCRIPT_DIR}/verify-macos-app.sh" --src-dir "${SRC_DIR}" --clean
    fi
}

if [ "${STAGE2_ONLY}" -eq 1 ]; then
    build_stage2
    echo "STAGE2_ONLY_OK"
    exit 0
fi

if [ "${SKIP_BUILD}" -eq 0 ]; then
    if [ -n "${NATIVE_HOST}" ]; then
        if ! "${NATIVE_HOST}" --batch-mode --no-init-file --eval '(%exit)' </dev/null >/dev/null 2>&1; then
            echo "error: --native-host cannot execute cleanly: ${NATIVE_HOST}" >&2
            exit 1
        fi
    else
        build_stage2
    fi
    build_stage3
fi

run_verifications

if [ "${CLEAN_AFTER}" -eq 1 ]; then
    echo "=== Cleaning build and test artifacts ==="
    clean_tree
fi

echo "BOOTSTRAP_AND_TEST_OK"
