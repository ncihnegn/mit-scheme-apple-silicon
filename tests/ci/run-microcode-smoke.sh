#!/bin/bash
#
# Build and run the standalone microcode Zig smoke tests.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
REQUIRE_NATIVE=0

usage() {
    cat <<EOF
Usage: $0 [--ucode-dir DIR] [--require-native]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ucode-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            shift 2
            ;;
        --require-native)
            REQUIRE_NATIVE=1
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

if [ "${REQUIRE_NATIVE}" -eq 1 ]; then
    case "$(uname -m)" in
        arm64|aarch64|x86_64)
            ;;
        *)
            echo "error: --require-native requested, but host arch $(uname -m) is not native" >&2
            exit 1
            ;;
    esac
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig compiler not found on PATH" >&2
    exit 1
fi

if [ "$(uname -s)" = "Darwin" ] && [ -z "${DYLD_FALLBACK_LIBRARY_PATH:-}" ] && [ -d /usr/local/lib ]; then
    # macOS SIP strips DYLD_FALLBACK_LIBRARY_PATH when launching /bin/bash.
    export DYLD_FALLBACK_LIBRARY_PATH="/usr/local/lib:/usr/lib"
fi

echo "=== Running microcode Zig smoke tests ==="
(cd "${REPO_ROOT}" && zig build test-smoke --summary all)

echo "ALL_MICROCODE_SMOKE_OK"
