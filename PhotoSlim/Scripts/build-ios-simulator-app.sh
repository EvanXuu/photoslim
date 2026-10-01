#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
OUTPUT_DIRECTORY=${PHOTOSLIM_IOS_OUTPUT_DIRECTORY:-"${PROJECT_DIRECTORY}/build"}
CONFIGURATION=${PHOTOSLIM_IOS_CONFIGURATION:-Release}
SDK=${PHOTOSLIM_IOS_SDK:-iphonesimulator}
# The repository is inside a File Provider location on this machine. Build
# and sign outside that location so macOS cannot attach Finder/provenance
# attributes while codesign is hashing the bundle.
BUILD_DIRECTORY=${PHOTOSLIM_IOS_BUILD_DIRECTORY:-"/private/tmp/PhotoSlim-iOS-Simulator-build"}
APP_PATH="${BUILD_DIRECTORY}/PhotoSlim.app"
PACKAGE_PATH="${OUTPUT_DIRECTORY}/PhotoSlim-iOS-Simulator.app.zip"

mkdir -p "${OUTPUT_DIRECTORY}"

xcodebuild \
    -project "${PROJECT_DIRECTORY}/PhotoSlim-iOS.xcodeproj" \
    -target PhotoSlimiOS \
    -configuration "${CONFIGURATION}" \
    -sdk "${SDK}" \
    CONFIGURATION_BUILD_DIR="${BUILD_DIRECTORY}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

# Xcode can inherit Finder/provenance extended attributes from a synced
# workspace. They are not valid in an iOS app bundle, so remove them only
# from this generated artifact before signing it ad hoc.
xattr -cr "${APP_PATH}"
codesign --force --sign - --timestamp=none "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
plutil -lint "${APP_PATH}/Info.plist"
xcrun lipo -info "${APP_PATH}/PhotoSlim"

# Keep a portable archive in the project output directory. The signed .app
# itself remains at APP_PATH for direct simctl installation.
ditto -c -k --norsrc --keepParent "${APP_PATH}" "${PACKAGE_PATH}"
print "Built ${APP_PATH}"
print "Packaged ${PACKAGE_PATH}"
