#!/bin/bash
#
# Build and run the standalone microcode C smoke tests against a configured
# src/microcode build directory.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
UCODE_DIR="${REPO_ROOT}/src/microcode"
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
            UCODE_DIR=$(cd "$2" && pwd)
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

if [ ! -f "${UCODE_DIR}/Makefile" ] || [ ! -f "${UCODE_DIR}/config.h" ]; then
    echo "error: ${UCODE_DIR} does not look like a configured microcode build directory" >&2
    exit 1
fi

IS_NATIVE=0
for cfg in "${UCODE_DIR}/cmpintmd-config.h" "${UCODE_DIR}/config.h"; do
    if [ -f "${cfg}" ] && grep -q '^#define CC_IS_NATIVE' "${cfg}"; then
        IS_NATIVE=1
        break
    fi
done

if [ "${REQUIRE_NATIVE}" -eq 1 ] && [ "${IS_NATIVE}" -ne 1 ]; then
    echo "error: --require-native requested, but CC_IS_NATIVE is not enabled in ${UCODE_DIR}" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

TESTS=(jit-smoke arena-smoke gc-arena-smoke fasl-code-smoke)
if [ "${IS_NATIVE}" -eq 1 ]; then
    TESTS+=(trampoline-smoke)
fi

SMOKE_MK="${TMP_DIR}/smoke.mk"
TEST_DIR="${REPO_ROOT}/tests/microcode"

cat > "${SMOKE_MK}" <<EOF
SMOKE_CFLAGS = \$(DEFS) \$(CPPFLAGS) \$(CFLAGS)

${TMP_DIR}/jit-smoke.o: ${TEST_DIR}/jit-smoke.c
	\$(CC) \$(SMOKE_CFLAGS) -c \$< -o \$@
${TMP_DIR}/jit-smoke: ${TMP_DIR}/jit-smoke.o jit.o cmpintmd.o code_arena.o wind.o obstack.o
	\$(CCLD) \$(LDFLAGS) -o \$@ \$^ \$(LIBS)

${TMP_DIR}/arena-smoke.o: ${TEST_DIR}/arena-smoke.c
	\$(CC) \$(SMOKE_CFLAGS) -c \$< -o \$@
${TMP_DIR}/arena-smoke: ${TMP_DIR}/arena-smoke.o code_arena.o jit.o transact.o wind.o obstack.o
	\$(CCLD) \$(LDFLAGS) -o \$@ \$^ \$(LIBS)

${TMP_DIR}/gc-arena-smoke.o: ${TEST_DIR}/gc-arena-smoke.c
	\$(CC) \$(SMOKE_CFLAGS) -c \$< -o \$@
${TMP_DIR}/gc-arena-smoke: ${TMP_DIR}/gc-arena-smoke.o gcloop.o code_arena.o jit.o cmpintmd.o transact.o wind.o obstack.o
	\$(CCLD) \$(LDFLAGS) -o \$@ \$^ \$(LIBS)

${TMP_DIR}/fasl-code-smoke.o: ${TEST_DIR}/fasl-code-smoke.c
	\$(CC) \$(SMOKE_CFLAGS) -c \$< -o \$@
${TMP_DIR}/fasl-code-smoke: ${TMP_DIR}/fasl-code-smoke.o fasl.o gcloop.o code_arena.o jit.o cmpintmd.o transact.o wind.o obstack.o
	\$(CCLD) \$(LDFLAGS) -o \$@ \$^ \$(LIBS)

${TMP_DIR}/trampoline-smoke.o: ${TEST_DIR}/trampoline-smoke.c
	\$(CC) \$(SMOKE_CFLAGS) -c \$< -o \$@
${TMP_DIR}/trampoline-smoke: ${TMP_DIR}/trampoline-smoke.o cmpint.o cmpintmd.o cmpauxmd.o gcloop.o code_arena.o jit.o transact.o wind.o obstack.o
	\$(CCLD) \$(LDFLAGS) -o \$@ \$^ \$(LIBS)

.PHONY: run-smoke-build
run-smoke-build: ${TESTS[*]/#/${TMP_DIR}/}
EOF

echo "=== Building microcode smoke tests (CC_IS_NATIVE=${IS_NATIVE}) ==="
make -C "${UCODE_DIR}" -f Makefile -f "${SMOKE_MK}" run-smoke-build

for name in "${TESTS[@]}"; do
    echo "=== Running ${name} ==="
    "${TMP_DIR}/${name}"
done

echo "ALL_MICROCODE_SMOKE_OK"
