#!/bin/bash
#
# Copyright (C) 1986, 1987, 1988, 1989, 1990, 1991, 1992, 1993, 1994,
#     1995, 1996, 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004,
#     2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014,
#     2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022 Massachusetts
#     Institute of Technology
#
# This file is part of MIT/GNU Scheme.
#
# MIT/GNU Scheme is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.
#
# MIT/GNU Scheme is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with MIT/GNU Scheme; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301, USA.

# Utility to build a MacOS X application bundle to run Edwin.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)
REPO_ROOT=$(cd "${SRC_DIR}/.." && pwd)

SCHEME_EXE=""
STARTER_EXE=""
PLUGINS="${PLUGINS:-edwin,imail}"

abs_path() {
    python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scheme-exe)
            SCHEME_EXE=$(abs_path "$2")
            shift 2
            ;;
        --macosx-starter)
            STARTER_EXE=$(abs_path "$2")
            shift 2
            ;;
        --plugins)
            PLUGINS="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z ${VERSION_STRING:-} ]] && [[ -f "${REPO_ROOT}/build.zig" ]]; then
    VERSION_STRING=$(sed -n 's/.*addOption(\[\]const u8, "package_version", "\([^"]*\)").*/\1/p' "${REPO_ROOT}/build.zig" | head -n 1 || true)
fi
: ${VERSION_STRING:=13.0.50}
: ${LONG_VERSION_STRING:="release ${VERSION_STRING}"}
: ${YEAR:=$(date +%Y)}

cd "${SRC_DIR}"

: ${USE_SWIFTUI_APP=1}
USE_SWIFTUI=0
if [[ ${USE_SWIFTUI_APP} != 0 ]] \
   && command -v swift >/dev/null 2>&1 \
   && [[ -f etc/macosx/app/Package.swift ]]; then
    USE_SWIFTUI=1
fi

MACOSX_VERSION=$(sw_vers | grep ^ProductVersion: | grep -E -o '[0-9]+\.[0-9]+')
if [[ ${USE_SWIFTUI} -eq 1 ]]; then
    : ${MACOSX_MIN_VERSION=13.0}
else
    : ${MACOSX_MIN_VERSION=${MACOSX_VERSION}}
fi

STAGE_TMP=$(mktemp -d)
SWIFT_BUILD_DIR=
cleanup_build_dirs() {
    if [[ -n ${STAGE_TMP} ]] && [[ -d ${STAGE_TMP} ]]; then
        rm -rf "${STAGE_TMP}"
    fi
    if [[ -n ${SWIFT_BUILD_DIR} ]]; then
        rm -rf "${SWIFT_BUILD_DIR}"
    fi
}
trap cleanup_build_dirs EXIT

rm -rf tmp mit-scheme.app

if [[ -z ${SCHEME_EXE} ]]; then
    if [[ -x "${REPO_ROOT}/zig-out/bin/mit-scheme" ]]; then
        SCHEME_EXE="${REPO_ROOT}/zig-out/bin/mit-scheme"
    else
        if [[ -z ${DYLD_FALLBACK_LIBRARY_PATH:-} ]] && [[ -d /usr/local/lib ]]; then
            export DYLD_FALLBACK_LIBRARY_PATH="/usr/local/lib:/usr/lib"
        fi
        (cd "${REPO_ROOT}" && zig build --release=fast)
        SCHEME_EXE="${REPO_ROOT}/zig-out/bin/mit-scheme"
    fi
fi

# Build directory structure for bundle.
mkdir mit-scheme.app
mkdir mit-scheme.app/Contents
mkdir mit-scheme.app/Contents/MacOS
mkdir mit-scheme.app/Contents/Resources

INSTALL_ARGS=(
    install
    --skip-microcode
    --version "${VERSION_STRING}"
    --scheme-exe "${SCHEME_EXE}"
    --prefix "${STAGE_TMP}"
    --plugins "${PLUGINS}"
)
if [[ -n ${STARTER_EXE} ]] && [[ -x ${STARTER_EXE} ]]; then
    INSTALL_ARGS+=(--macosx-starter "${STARTER_EXE}")
fi
python3 "${REPO_ROOT}/tools/build-scheme.py" "${INSTALL_ARGS[@]}"

AUXDIR=""
for cand in "${STAGE_TMP}"/lib/mit-scheme-*; do
    if [[ -d ${cand} ]]; then
        AUXDIR=${cand}
        break
    fi
done
if [[ -z ${AUXDIR} ]]; then
    echo "error: installed auxiliary library directory missing under ${STAGE_TMP}/lib" >&2
    exit 1
fi

mv "${STAGE_TMP}/bin/mit-scheme" \
    mit-scheme.app/Contents/Resources/mit-scheme
if [[ ${USE_SWIFTUI} -eq 1 ]]; then
    rm -f "${AUXDIR}/macosx-starter"
    SWIFT_BUILD_DIR=$(mktemp -d)
    SWIFT_BUILD_FLAGS=(
        --package-path etc/macosx/app
        --scratch-path "${SWIFT_BUILD_DIR}"
        -c release
        --arch "$(uname -m)"
    )
    swift build "${SWIFT_BUILD_FLAGS[@]}"
    SWIFT_BIN_DIR=$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)
    cp -p "${SWIFT_BIN_DIR}/MITSchemeApp" \
        mit-scheme.app/Contents/MacOS/MITSchemeApp
    chmod 755 mit-scheme.app/Contents/MacOS/MITSchemeApp
    BUNDLE_EXECUTABLE=MITSchemeApp
else
    if [[ ! -x "${AUXDIR}/macosx-starter" ]]; then
        echo "error: macosx-starter missing in ${AUXDIR}; pass --macosx-starter or build with zig build" >&2
        exit 1
    fi
    mv "${AUXDIR}/macosx-starter" mit-scheme.app/Contents/MacOS/.
    BUNDLE_EXECUTABLE=macosx-starter
fi
rm -f "${AUXDIR}/runtime.com"
mv "${AUXDIR}"/* mit-scheme.app/Contents/Resources/.
cp -p etc/macosx/schlogo.icns mit-scheme.app/Contents/Resources/appIcon.icns

# Generate an appropriate Info.plist file.
cat > mit-scheme.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist
          PUBLIC "-//Apple//DTD PLIST 1.0//EN"
	  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>CFBundleName</key>
    <string>mit-scheme</string>
    <key>CFBundleDisplayName</key>
    <string>MIT/GNU Scheme</string>
    <key>CFBundleIdentifier</key>
    <string>org.gnu.mit-scheme</string>
    <key>CFBundleVersion</key>
    <string>${VERSION_STRING}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>mgsc</string>
    <key>CFBundleExecutable</key>
    <string>${BUNDLE_EXECUTABLE}</string>

    <key>CFBundleShortVersionString</key>
    <string>${VERSION_STRING}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOSX_MIN_VERSION}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (C) ${YEAR} Massachusetts Institute of Technology</string>

    <key>CFBundleGetInfoString</key>
    <string>${LONG_VERSION_STRING}</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>LSHasLocalizedDisplayName</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>appIcon.icns</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeExtensions</key>
        <array>
          <string>scm</string>
          <string>sld</string>
          <string>ss</string>
        </array>
        <key>CFBundleTypeName</key>
        <string>Scheme Source</string>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>LSHandlerRank</key>
        <string>Alternate</string>
      </dict>
    </array>
  </dict>
</plist>
EOF

# Sign the embedded runtime binary with allow-jit entitlements (required for
# MAP_JIT on Apple silicon / Hardened Runtime), any loadable plugins, and the
# enclosing application bundle.
: ${CODESIGN_IDENTITY=-}
CODESIGN_FLAGS=(--force --sign "${CODESIGN_IDENTITY}")
if [[ ${CODESIGN_IDENTITY} != - ]]; then
    CODESIGN_FLAGS+=(--options runtime)
fi
if command -v codesign >/dev/null 2>&1; then
    while IFS= read -r -d '' SO_FILE; do
        codesign "${CODESIGN_FLAGS[@]}" "${SO_FILE}"
    done < <(find mit-scheme.app/Contents/Resources -name '*.so' -print0)
    codesign "${CODESIGN_FLAGS[@]}" \
        --entitlements etc/macosx/entitlements.plist \
        mit-scheme.app/Contents/Resources/mit-scheme
    codesign "${CODESIGN_FLAGS[@]}" \
        "mit-scheme.app/Contents/MacOS/${BUNDLE_EXECUTABLE}"
    codesign "${CODESIGN_FLAGS[@]}" \
        mit-scheme.app
fi
