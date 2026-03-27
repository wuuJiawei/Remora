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
