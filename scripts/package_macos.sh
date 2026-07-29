#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/Remora.xcodeproj"
PROJECT_GENERATOR="${ROOT_DIR}/scripts/generate_xcodeproj.rb"
SCHEME="Remora"
CONFIGURATION="Release"
ARCH="$(uname -m)"
VERSION="0.0.0"
BUILD_NUMBER="1"
OUTPUT_DIR="${ROOT_DIR}/dist"
DERIVED_DATA_PATH="${ROOT_DIR}/.derived-package"
ARCHIVE_PATH="${DERIVED_DATA_PATH}/archives/Remora.xcarchive"
ZIP_NAME=""
DMG_NAME=""
DMG_BACKGROUND_SVG="${ROOT_DIR}/scripts/dmg-background.svg"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="$2"
      ARCHIVE_PATH="${DERIVED_DATA_PATH}/archives/Remora.xcarchive"
      shift 2
      ;;
    --zip-name)
      ZIP_NAME="$2"
      shift 2
      ;;
    --dmg-name)
      DMG_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -f "${PROJECT_GENERATOR}" ]]; then
  ruby "${PROJECT_GENERATOR}"
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "Missing ${PROJECT_PATH}. Could not generate Xcode project via ${PROJECT_GENERATOR}." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
rm -rf "${ARCHIVE_PATH}"

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=macOS" \
  -archivePath "${ARCHIVE_PATH}" \
  ARCHS="${ARCH}" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  CODE_SIGNING_ALLOWED=NO \
  archive

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Remora.app"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Missing archived app at ${APP_PATH}" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_PATH}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP_PATH}/Contents/Info.plist"
codesign --force --deep --sign - "${APP_PATH}"

if [[ -z "${ZIP_NAME}" ]]; then
  ZIP_NAME="Remora-${VERSION}-macos-${ARCH}.zip"
fi

ZIP_PATH="${OUTPUT_DIR}/${ZIP_NAME}"
rm -f "${ZIP_PATH}" "${ZIP_PATH}.sha256"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
shasum -a 256 "${ZIP_PATH}" > "${ZIP_PATH}.sha256"

echo "Packaged ${ZIP_PATH}"

if [[ -z "${DMG_NAME}" ]]; then
  DMG_NAME="Remora-${VERSION}-macos-${ARCH}.dmg"
fi

DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
DMG_STAGING_DIR="${DERIVED_DATA_PATH}/dmg-staging"
DMG_BACKGROUND_DIR="${DMG_STAGING_DIR}/.background"
DMG_TEMP_PATH="${DERIVED_DATA_PATH}/Remora-writable.dmg"
DMG_WORK_VOLUME_NAME="Remora-$$"
DMG_MOUNT_DIR=""

rm -rf "${DMG_STAGING_DIR}"
rm -f "${DMG_PATH}" "${DMG_PATH}.sha256" "${DMG_TEMP_PATH}"
mkdir -p "${DMG_BACKGROUND_DIR}"

ditto "${APP_PATH}" "${DMG_STAGING_DIR}/Remora.app"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"
sips -s format png "${DMG_BACKGROUND_SVG}" \
  --out "${DMG_BACKGROUND_DIR}/background.png" >/dev/null

hdiutil create \
  -volname "${DMG_WORK_VOLUME_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov \
  -format UDRW \
  "${DMG_TEMP_PATH}" >/dev/null

DMG_DEVICE=""
cleanup_dmg() {
  if [[ -n "${DMG_DEVICE}" ]]; then
    hdiutil detach "${DMG_DEVICE}" -force >/dev/null 2>&1 || true
  fi
  rm -f "${DMG_TEMP_PATH}"
}
trap cleanup_dmg EXIT

DMG_ATTACH_OUTPUT="$(
  hdiutil attach "${DMG_TEMP_PATH}" \
    -readwrite \
    -noverify \
    -noautoopen
)"
DMG_DEVICE="$(printf '%s\n' "${DMG_ATTACH_OUTPUT}" | awk '/\/Volumes\// { print $1; exit }')"
DMG_MOUNT_DIR="$(printf '%s\n' "${DMG_ATTACH_OUTPUT}" | awk '/\/Volumes\// { print $3; exit }')"

if [[ -z "${DMG_DEVICE}" || -z "${DMG_MOUNT_DIR}" ]]; then
  echo "Could not mount writable DMG." >&2
  exit 1
fi

osascript <<APPLESCRIPT
with timeout of 30 seconds
  tell application "Finder"
    tell disk "${DMG_WORK_VOLUME_NAME}"
      open
      set diskWindow to container window
      set current view of diskWindow to icon view
      set toolbar visible of diskWindow to false
      set statusbar visible of diskWindow to false
      set pathbar visible of diskWindow to false
      set bounds of diskWindow to {120, 120, 780, 520}

      set viewOptions to icon view options of diskWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 112
      set text size of viewOptions to 13
      set background picture of viewOptions to file ".background:background.png"

      set position of item "Remora.app" to {170, 190}
      set position of item "Applications" to {490, 190}

      update without registering applications
      delay 2
      close diskWindow
    end tell
  end tell
end timeout
return true
APPLESCRIPT

sync
diskutil rename "${DMG_MOUNT_DIR}" "Remora" >/dev/null
sync
hdiutil detach "${DMG_DEVICE}" >/dev/null
DMG_DEVICE=""

hdiutil convert "${DMG_TEMP_PATH}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "${DMG_PATH}" >/dev/null

shasum -a 256 "${DMG_PATH}" > "${DMG_PATH}.sha256"
trap - EXIT
cleanup_dmg

echo "Packaged ${DMG_PATH}"
