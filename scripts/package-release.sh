#!/bin/bash
set -euo pipefail

APP_NAME="StreamVibes"
VERSION="${1:?Usage: scripts/package-release.sh VERSION [BUILD_DIR] [OUTPUT_DIR]}"
BUILD_DIR="${2:-.build_output}"
OUTPUT_DIR="${3:-executables}"
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "Use a semantic version, for example 1.0.0 or 1.0.0-beta.1." >&2
    exit 1
fi
if [[ ! -d "${APP_PATH}" ]]; then
    echo "Release app not found. Run make release first." >&2
    exit 1
fi

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
if [[ "${BUNDLE_VERSION}" != "${VERSION%%-*}" ]]; then
    echo "App version does not match the requested release." >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION}-macos-universal.dmg"
if [[ -e "${DMG_PATH}" ]]; then
    echo "Refusing to overwrite an existing release artifact." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

ditto --noextattr --norsrc "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
# Ad-hoc signing checks bundle integrity; it is not Developer ID or notarization.
codesign --force --deep --sign - --timestamp=none "${STAGING_DIR}/${APP_NAME}.app"
codesign --verify --deep --strict "${STAGING_DIR}/${APP_NAME}.app"

# Every shipped native executable/framework must contain both Mac architectures.
while IFS= read -r -d '' FILE; do
    if file -b "${FILE}" | grep -q 'Mach-O'; then
        ARCHITECTURES="$(lipo -archs "${FILE}")"
        for ARCH in arm64 x86_64; do
            case " ${ARCHITECTURES} " in
                *" ${ARCH} "*) ;;
                *) echo "Missing ${ARCH} in a native release binary." >&2; exit 1 ;;
            esac
        done
    fi
done < <(find "${STAGING_DIR}/${APP_NAME}.app" -type f -print0)

# Include the app license and upstream notices alongside the downloadable app.
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "${SOURCE_DIR}/LICENSE" "${STAGING_DIR}/LICENSE.txt"
CHECKOUTS_DIR="${BUILD_DIR}/../Tuist/.build/checkouts"
if [[ -d "${CHECKOUTS_DIR}" ]]; then
    while IFS= read -r -d '' NOTICE; do
        RELATIVE_PATH="${NOTICE#"${CHECKOUTS_DIR}/"}"
        DESTINATION="${STAGING_DIR}/Licenses/${RELATIVE_PATH}"
        mkdir -p "$(dirname "${DESTINATION}")"
        cp "${NOTICE}" "${DESTINATION}"
    done < <(find "${CHECKOUTS_DIR}" -type f \( \
        -iname 'license*' -o -iname 'notice*' -o -iname 'copying*' \
    \) -print0)
fi

ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create -quiet -volname "${APP_NAME} ${VERSION}" -srcfolder "${STAGING_DIR}" \
    -format UDZO -fs HFS+ "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"
(
    cd "${OUTPUT_DIR}"
    shasum -a 256 "${APP_NAME}-${VERSION}-macos-universal.dmg" > SHA256SUMS.txt
)
echo "Packaged ${DMG_PATH} (ad-hoc signed; not notarized)."
