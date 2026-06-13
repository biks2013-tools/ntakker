#!/usr/bin/env bash
# scripts/package-ntakker-app.sh —
# 2026-05-01 packaging script for the ntakker menu-bar app.
#
# Produces a self-contained `.app` bundle at `dist/ntakker.app` from a
# fresh `swift build -c release` (or `-c debug` if SWIFT_CONFIG is set
# to `debug`). The bundle is required for the Apple Cloud transcription
# provider (`apple-cloud`) because:
#
#   * `SFSpeechRecognizer.requestAuthorization(_:)` SIGABRTs ad-hoc-
#     signed CLI binaries on macOS 26 — the system Speech Recognition
#     prompt only works from inside a `.app` bundle that TCC can
#     attach the grant to.
#   * The Microphone + Screen Recording grants the user has already
#     given are scoped to the `com.local.ntakker` bundle id; running
#     the raw CLI binary uses the same id and inherits those grants,
#     but Speech Recognition has never been requested from this
#     binary so it isn't on the TCC allow-list.
#
# Usage:
#   bash scripts/package-ntakker-app.sh           # release build, ad-hoc sign
#   SWIFT_CONFIG=debug bash scripts/...             # debug build (faster)
#   CODESIGN_IDENTITY="Developer ID Application: …" bash scripts/...
#                                                    # sign with a real identity
#
# Output:
#   dist/ntakker.app/Contents/{Info.plist, MacOS/ntakker, Resources/, _CodeSignature/}
#
# Notes:
#   * The bundle id (`com.local.ntakker`) must match what the app
#     references at runtime so the existing Microphone + Screen
#     Recording TCC grants carry over.
#   * The Info.plist source is `Resources/Ntakker-Info.plist` —
#     edit that file if you want to change usage descriptions etc.
#     This script never edits the plist in-place.
#   * After packaging, `open dist/ntakker.app` to launch. The first
#     time you select Apple Cloud as the transcription provider AND
#     start a recording, macOS will pop the system Speech Recognition
#     prompt; click Allow.

set -euo pipefail

# Resolve repo root regardless of where the script was invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
cd "${REPO_ROOT}"

CONFIG="${SWIFT_CONFIG:-release}"
APP_NAME="ntakker"
BUNDLE_ID="com.local.ntakker"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
PLIST_SRC="${REPO_ROOT}/Resources/Ntakker-Info.plist"

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

# Sign. Default = ad-hoc (sufficient for TCC bundle metadata, and the
# only option without a paid Developer ID); override via env var to
# use a real identity.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> codesign --force --deep --sign '${IDENTITY}'"
codesign --force --deep --sign "${IDENTITY}" "${APP_BUNDLE}"

echo "==> verifying signature"
codesign -dv "${APP_BUNDLE}" 2>&1 | head -10

echo
echo "Done. Launch with:"
echo "  open '${APP_BUNDLE}'"
echo
echo "Tip: if macOS still won't show the Speech Recognition prompt,"
echo "kill any running raw-CLI ntakker first:"
echo "  pkill -f '\\.build/.*ntakker' || true"
