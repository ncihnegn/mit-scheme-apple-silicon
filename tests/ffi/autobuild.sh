#!/bin/sh

set -eu

TMP_INC_DIR=""
cleanup() {
    if [ -n "${TMP_INC_DIR}" ] && [ -d "${TMP_INC_DIR}" ]; then
        rm -rf "${TMP_INC_DIR}"
    fi
}
trap cleanup EXIT

if [ -z "${MIT_SCHEME_EXE:-}" ]; then
    if [ -x "../../zig-out/bin/mit-scheme" ]; then
        MIT_SCHEME_EXE="../../zig-out/bin/mit-scheme"
    elif [ -x "../../src/run-build" ]; then
        MIT_SCHEME_EXE="../../src/run-build"
    else
        MIT_SCHEME_EXE="mit-scheme"
    fi
fi

if [ -z "${MIT_SCHEME_INCLUDE_DIR:-}" ] && [ -n "${MITSCHEME_LIBRARY_PATH:-}" ]; then
    OLD_IFS=${IFS}
    IFS=':'
    for dir in ${MITSCHEME_LIBRARY_PATH}; do
        if [ -f "${dir}/mit-scheme.h" ]; then
            MIT_SCHEME_INCLUDE_DIR=${dir}
            break
        fi
    done
    IFS=${OLD_IFS}
fi

if [ -z "${MIT_SCHEME_INCLUDE_DIR:-}" ]; then
    if [ -f "../../src/lib/mit-scheme.h" ]; then
        MIT_SCHEME_INCLUDE_DIR="../../src/lib"
    else
        for cand in ../../zig-out/lib/mit-scheme-*/mit-scheme.h; do
            if [ -f "${cand}" ]; then
                MIT_SCHEME_INCLUDE_DIR=$(dirname "${cand}")
                break
            fi
        done
    fi
fi

if [ -z "${MIT_SCHEME_INCLUDE_DIR:-}" ]; then
    if [ ! -f "../../src/microcode/pruxffi.h" ]; then
        echo "error: unable to locate mit-scheme.h or pruxffi.h" >&2
        exit 1
    fi
    TMP_INC_DIR=$(mktemp -d)
    ln -s "$(pwd)/../../src/microcode/pruxffi.h" "${TMP_INC_DIR}/mit-scheme.h"
    MIT_SCHEME_INCLUDE_DIR="${TMP_INC_DIR}"
fi

run_cc() {
    if [ -n "${CC:-}" ]; then
        ${CC} "$@"
    elif command -v cc >/dev/null 2>&1; then
        cc "$@"
    elif command -v zig >/dev/null 2>&1; then
        if [ "$(uname -s)" = "Darwin" ] && [ -z "${DYLD_FALLBACK_LIBRARY_PATH:-}" ] && [ -d /usr/local/lib ]; then
            export DYLD_FALLBACK_LIBRARY_PATH="/usr/local/lib:/usr/lib"
        fi
        zig cc "$@"
    else
        echo "error: no C compiler found (set CC or install cc/zig)" >&2
        exit 1
    fi
}

rm -rf ffi-test-shim.la .libs

printf '%s\n' '(generate-shim "ffi-test" "#include \"ffi-test.h\"")' \
    | "${MIT_SCHEME_EXE}" --batch-mode

run_cc -O2 -I"${MIT_SCHEME_INCLUDE_DIR}" -o ffi-test-const ffi-test-const.c
./ffi-test-const
printf '%s\n' '(sf "ffi-test-const")' | "${MIT_SCHEME_EXE}" --batch-mode

case "$(uname -s)" in
    Darwin)
        run_cc -O2 -bundle -undefined dynamic_lookup -fPIC \
            -I"${MIT_SCHEME_INCLUDE_DIR}" \
            -o ffi-test-shim.so ffi-test-shim.c ffi-test.c
        ;;
    *)
        run_cc -O2 -shared -fPIC \
            -I"${MIT_SCHEME_INCLUDE_DIR}" \
            -o ffi-test-shim.so ffi-test-shim.c ffi-test.c
        ;;
esac
