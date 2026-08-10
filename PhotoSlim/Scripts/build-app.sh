#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
OUTPUT_DIRECTORY=${PHOTOSLIM_OUTPUT_DIRECTORY:-"${PROJECT_DIRECTORY}/build"}
SCRATCH_DIRECTORY=${PHOTOSLIM_SCRATCH_DIRECTORY:-"${OUTPUT_DIRECTORY}/swiftpm"}
MODULE_CACHE_DIRECTORY=${PHOTOSLIM_MODULE_CACHE_DIRECTORY:-"${OUTPUT_DIRECTORY}/module-cache"}
SIGNING_IDENTITY=${PHOTOSLIM_SIGNING_IDENTITY:--}

mkdir -p "${OUTPUT_DIRECTORY}" "${MODULE_CACHE_DIRECTORY}"

CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIRECTORY}" xcrun swift build \
    --disable-sandbox \
    --configuration release \
    --package-path "${PROJECT_DIRECTORY}" \
    --scratch-path "${SCRATCH_DIRECTORY}"

BINARY_DIRECTORY=$(CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIRECTORY}" xcrun swift build \
    --disable-sandbox \
    --configuration release \
    --package-path "${PROJECT_DIRECTORY}" \
    --scratch-path "${SCRATCH_DIRECTORY}" \
    --show-bin-path)

STAGING_DIRECTORY=$(mktemp -d "/private/tmp/PhotoSlim-stage.XXXXXX")
ARCHIVE_VERIFY_DIRECTORY=$(mktemp -d "/private/tmp/PhotoSlim-archive-check.XXXXXX")
STAGING_APP="${STAGING_DIRECTORY}/PhotoSlim.app"
STAGING_ARCHIVE="${STAGING_DIRECTORY}/PhotoSlim.app.zip"
FINAL_APP="${OUTPUT_DIRECTORY}/PhotoSlim.app"
FINAL_ARCHIVE="${OUTPUT_DIRECTORY}/PhotoSlim.app.zip"

function cleanup_staging {
    rm -rf "${STAGING_DIRECTORY}"
    rm -rf "${ARCHIVE_VERIFY_DIRECTORY}"
}
trap cleanup_staging EXIT

mkdir -p "${STAGING_APP}/Contents/MacOS" "${STAGING_APP}/Contents/Resources"
cp "${BINARY_DIRECTORY}/PhotoSlim" "${STAGING_APP}/Contents/MacOS/PhotoSlim"
cp "${PROJECT_DIRECTORY}/Resources/Info.plist" "${STAGING_APP}/Contents/Info.plist"
xcrun actool \
    "${PROJECT_DIRECTORY}/Resources/Assets.xcassets" \
    --compile "${STAGING_APP}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${STAGING_DIRECTORY}/asset-info.plist"
xattr -cr "${STAGING_APP}"

codesign \
    --force \
    --options runtime \
    --entitlements "${PROJECT_DIRECTORY}/Resources/PhotoSlim.entitlements" \
    --sign "${SIGNING_IDENTITY}" \
    "${STAGING_APP}"

codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"
plutil -lint "${STAGING_APP}/Contents/Info.plist"
ditto -c -k --norsrc --keepParent "${STAGING_APP}" "${STAGING_ARCHIVE}"
ditto -x -k "${STAGING_ARCHIVE}" "${ARCHIVE_VERIFY_DIRECTORY}"
codesign --verify --deep --strict --verbose=2 "${ARCHIVE_VERIFY_DIRECTORY}/PhotoSlim.app"

if [[ -e "${FINAL_APP}" ]]; then
    rm -rf "${FINAL_APP}"
fi
if [[ -e "${FINAL_ARCHIVE}" ]]; then
    rm -f "${FINAL_ARCHIVE}"
fi
mv "${STAGING_APP}" "${FINAL_APP}"
mv "${STAGING_ARCHIVE}" "${FINAL_ARCHIVE}"
xattr -cr "${FINAL_APP}"

print "Built ${FINAL_APP}"
print "Portable signed archive ${FINAL_ARCHIVE}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    print "Signed ad hoc. Set PHOTOSLIM_SIGNING_IDENTITY to a stable Apple signing certificate to keep the Photo Library permission across binary updates."
fi
