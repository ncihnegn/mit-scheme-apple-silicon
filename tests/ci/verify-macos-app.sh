#!/bin/bash
#
# Build, verify code signing + entitlements, and run a smoke check on
# src/mit-scheme.app on macOS.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
SRC_DIR="${REPO_ROOT}/src"
CLEAN=0

usage() {
    cat <<EOF
Usage: $0 [--src-dir DIR] [--clean]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SRC_DIR=$(cd "$2" && pwd)
            shift 2
            ;;
        --clean)
            CLEAN=1
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

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Skipping macOS app verification on non-Darwin host ($(uname -s))."
    exit 0
fi

TMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf "${TMP_DIR}"
    if [ "${CLEAN}" -eq 1 ]; then
        rm -rf "${SRC_DIR}/mit-scheme.app" "${SRC_DIR}/tmp"
    fi
}
trap cleanup EXIT

PRINT_MK="${TMP_DIR}/print-dirs.mk"
cat > "${PRINT_MK}" <<'EOF'
.PHONY: print-app-dirs
print-app-dirs:
	@printf '%s\t%s\n' '$(bindir)' '$(libdir)'
EOF

IFS=$'\t' read -r CONFIGURED_BINDIR CONFIGURED_LIBDIR < <(
    make -s -C "${SRC_DIR}" -f Makefile -f "${PRINT_MK}" print-app-dirs
)

echo "=== Building mit-scheme.app (bindir=${CONFIGURED_BINDIR}, libdir=${CONFIGURED_LIBDIR}) ==="
env -u MIT_SCHEME_EXE \
    bindir="${CONFIGURED_BINDIR}" \
    libdir="${CONFIGURED_LIBDIR}" \
    make -C "${SRC_DIR}" macosx-app

APP_DIR="${SRC_DIR}/mit-scheme.app"
BUNDLE_BIN="${APP_DIR}/Contents/Resources/mit-scheme"
BUNDLE_RES="${APP_DIR}/Contents/Resources"

if [ ! -x "${BUNDLE_BIN}" ]; then
    echo "error: signed bundle binary missing at ${BUNDLE_BIN}" >&2
    exit 1
fi

echo "=== Verifying codesign signature & entitlements ==="
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
ENTITLEMENTS=$(codesign -d --entitlements :- "${BUNDLE_BIN}" 2>&1)
printf '%s\n' "${ENTITLEMENTS}"
if ! printf '%s\n' "${ENTITLEMENTS}" | grep -q 'com.apple.security.cs.allow-jit'; then
    echo "error: com.apple.security.cs.allow-jit missing from ${BUNDLE_BIN}" >&2
    exit 1
fi

echo "=== Executing signed bundle binary ==="
OUT=$("${BUNDLE_BIN}" \
    --macosx-application \
    --batch-mode \
    --no-init-file \
    --eval '(begin (load-option (quote edwin)) (load-option (quote imail)) (let ((f (compile-procedure (lambda (x) (* x x))))) (if (not (= (f 9) 81)) (error "bundle check failed")) (display "MACOS_APP_BUNDLE_OK\n")) (%exit))' \
    </dev/null)
printf '%s\n' "${OUT}"
if ! printf '%s\n' "${OUT}" | grep -q 'MACOS_APP_BUNDLE_OK'; then
    echo "error: bundle smoke check did not print MACOS_APP_BUNDLE_OK" >&2
    exit 1
fi

echo "VERIFY_MACOS_APP_OK"
