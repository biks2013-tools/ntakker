#!/usr/bin/env bash
# scripts/package-ntakker-studio-app.sh — plan-024.
#
# Builds `dist/ntakker-studio.app` (bundle id `com.giorgosmarinos.ntakker-studio`)
# from `swift build -c release` (or `SWIFT_CONFIG=debug`). Same layout and
# signing as `scripts/package-ntakker-app.sh`; the Info.plist source is
# `Resources/NtakkerStudio-Info.plist`, and the icon is shared with ntakker.
#
# Usage:
#   bash scripts/package-ntakker-studio-app.sh
#   CODESIGN_IDENTITY="Developer ID Application: …" bash scripts/package-ntakker-studio-app.sh

set -euo pipefail

# Resolve repo root regardless of where the script was invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
cd "${REPO_ROOT}"

CONFIG="${SWIFT_CONFIG:-release}"
APP_NAME="ntakker-studio"
BUNDLE_ID="com.giorgosmarinos.ntakker-studio"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
PLIST_SRC="${REPO_ROOT}/Resources/NtakkerStudio-Info.plist"

if [[ ! -f "${PLIST_SRC}" ]]; then
  echo "error: Info.plist source not found at ${PLIST_SRC}" >&2
  exit 1
fi

echo "==> swift build -c ${CONFIG} (this may take a minute)"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "error: built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> assembling ${APP_BUNDLE}"
# Tear down any prior bundle so stale Info.plist / signature don't leak.
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy the executable.
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy the Info.plist verbatim — single source of truth.
cp "${PLIST_SRC}" "${APP_BUNDLE}/Contents/Info.plist"

# Copy the app icon. If the .icns is missing, regenerate it from the
# vector source (`scripts/generate-appicon.swift` + `iconutil`).
ICON_SRC="${REPO_ROOT}/Resources/AppIcon.icns"
if [[ ! -f "${ICON_SRC}" ]]; then
  echo "==> regenerating Resources/AppIcon.icns (source missing)"
  swift "${REPO_ROOT}/scripts/generate-appicon.swift"
  iconutil -c icns "${REPO_ROOT}/Resources/AppIcon.iconset" -o "${ICON_SRC}"
fi
cp "${ICON_SRC}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# PkgInfo is conventional but not strictly required.
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# Sign. Default = ad-hoc (local builds). With a real identity (a release:
# CODESIGN_IDENTITY = Developer ID Application SHA-1) the hardened runtime
# and a secure timestamp are added, which notarization requires.
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "${IDENTITY}" == "-" ]]; then
  echo "==> codesign --force --deep --sign - (ad-hoc)"
  codesign --force --deep --sign - "${APP_BUNDLE}"
else
  echo "==> codesign --force --options runtime --timestamp --sign <identity>"
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP_BUNDLE}"
fi

echo "==> verifying signature"
codesign -dv "${APP_BUNDLE}" 2>&1 | head -10

echo
echo "Done. Launch with:"
echo "  open '${APP_BUNDLE}'"
echo
