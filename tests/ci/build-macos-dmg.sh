#!/bin/bash
#
# Build, package, and verify a compressed macOS UDZO .dmg containing
# MIT:GNU Scheme <version>.app (SwiftUI MITSchemeApp + allow-jit arm64
# runtime) and an /Applications symlink.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
SRC_DIR="${REPO_ROOT}/src"
OUT_DIR="${REPO_ROOT}/build-dmg"
VERSION=""
MIN_MACOS="13.0"
CLEAN=0

usage() {
    cat <<EOF
Usage: $0 [--src-dir DIR] [--out-dir DIR] [--version VER] [--min-macos VER] [--clean]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SRC_DIR=$(cd "$2" && pwd)
            shift 2
            ;;
        --out-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            OUT_DIR="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            VERSION="$2"
            shift 2
            ;;
        --min-macos)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            MIN_MACOS="$2"
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
    echo "error: build-macos-dmg.sh requires macOS (Darwin)" >&2
    exit 1
fi

if [ -z "${VERSION}" ] && [ -f "${REPO_ROOT}/build.zig" ]; then
    VERSION=$(sed -n 's/.*addOption(\[\]const u8, "package_version", "\([^"]*\)").*/\1/p' "${REPO_ROOT}/build.zig" | head -n 1 || true)
fi
if [ -z "${VERSION}" ]; then
    VERSION="13.0.50"
fi

UNAME_M=$(uname -m)
case "${UNAME_M}" in
    arm64) SCHEME_ARCH="aarch64le" ;;
    x86_64) SCHEME_ARCH="x86-64" ;;
    *) SCHEME_ARCH="${UNAME_M}" ;;
esac

mkdir -p "${OUT_DIR}"
OUT_DIR=$(cd "${OUT_DIR}" && pwd)

TMP_DIR=$(mktemp -d)
STAGE_DIR="${TMP_DIR}/stage"
MNT_DIR="${TMP_DIR}/mnt"
mkdir -p "${STAGE_DIR}" "${MNT_DIR}"

cleanup() {
    hdiutil detach "${MNT_DIR}" >/dev/null 2>&1 || true
    rm -rf "${TMP_DIR}"
    if [ "${CLEAN}" -eq 1 ]; then
        rm -rf "${SRC_DIR}/mit-scheme.app" "${SRC_DIR}/tmp"
    fi
}
trap cleanup EXIT

echo "=== Building mit-scheme.app (version=${VERSION}, min_macos=${MIN_MACOS}) ==="
env -u MIT_SCHEME_EXE \
    VERSION_STRING="${VERSION}" \
    MACOSX_MIN_VERSION="${MIN_MACOS}" \
    "${SRC_DIR}/etc/macosx/make-app.sh" </dev/null

APP_DIR="${SRC_DIR}/mit-scheme.app"
BUNDLE_NAME="MIT:GNU Scheme ${VERSION}.app"
DMG_NAME="mit-scheme-${VERSION}-${SCHEME_ARCH}.dmg"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"

rm -f "${DMG_PATH}" "${DMG_PATH}.sha256"
ditto "${APP_DIR}" "${STAGE_DIR}/${BUNDLE_NAME}"
ln -s /Applications "${STAGE_DIR}/Applications"

echo "=== Packaging ${DMG_PATH} ==="
hdiutil create \
    -volname "MIT-GNU Scheme ${VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"
chmod a-w "${DMG_PATH}"

(
    cd "${OUT_DIR}"
    shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

echo "=== Verifying ${DMG_PATH} ==="
hdiutil verify "${DMG_PATH}"
hdiutil attach "${DMG_PATH}" -mountpoint "${MNT_DIR}" -readonly -nobrowse

MOUNTED_APP="${MNT_DIR}/${BUNDLE_NAME}"
MOUNTED_BIN="${MOUNTED_APP}/Contents/Resources/mit-scheme"

plutil -lint "${MOUNTED_APP}/Contents/Info.plist"
if command -v swift >/dev/null 2>&1 \
   && [ -f "${SRC_DIR}/etc/macosx/app/Package.swift" ] \
   && [ "${USE_SWIFTUI_APP:-1}" != "0" ]; then
    MOUNTED_GUI="${MOUNTED_APP}/Contents/MacOS/MITSchemeApp"
    if [ ! -x "${MOUNTED_GUI}" ]; then
        echo "error: SwiftUI bundle executable missing at ${MOUNTED_GUI}" >&2
        exit 1
    fi
    file "${MOUNTED_GUI}"
fi
file "${MOUNTED_BIN}"

codesign --verify --deep --strict --verbose=2 "${MOUNTED_APP}"
ENTITLEMENTS=$(codesign -d --entitlements :- "${MOUNTED_BIN}" 2>&1)
printf '%s\n' "${ENTITLEMENTS}"
if ! printf '%s\n' "${ENTITLEMENTS}" | grep -q 'com.apple.security.cs.allow-jit'; then
    echo "error: com.apple.security.cs.allow-jit missing from ${MOUNTED_BIN}" >&2
    exit 1
fi

OUT=$("${MOUNTED_BIN}" \
    --macosx-application \
    --batch-mode \
    --no-init-file \
    --eval '(begin (load-option (quote edwin)) (load-option (quote imail)) (let ((f (compile-procedure (lambda (x) (* x x))))) (if (not (= (f 9) 81)) (error "bundle check failed")) (display "MACOS_APP_BUNDLE_OK\n")) (%exit))' \
    </dev/null)
printf '%s\n' "${OUT}"
if ! printf '%s\n' "${OUT}" | grep -q 'MACOS_APP_BUNDLE_OK'; then
    echo "error: mounted DMG bundle smoke check did not print MACOS_APP_BUNDLE_OK" >&2
    exit 1
fi

if command -v swift >/dev/null 2>&1 \
   && [ -f "${SRC_DIR}/etc/macosx/app/Package.swift" ]; then
    echo "=== Running SwiftUI workbench tests against mounted DMG bundle ==="
    env -u MIT_SCHEME_APP_LIBRARY -u MIT_SCHEME_APP_BAND \
        MIT_SCHEME_APP_EXE="${MOUNTED_BIN}" \
        swift test \
        --package-path "${SRC_DIR}/etc/macosx/app" \
        --scratch-path "${TMP_DIR}/swift-test"
fi

echo "BUILD_MACOS_DMG_OK"
echo "DMG_PATH=${DMG_PATH}"
cat "${DMG_PATH}.sha256"
