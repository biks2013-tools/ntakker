#!/usr/bin/env bash
# bin/build-ntakker-app.sh
#
# Wrap the SPM-built `ntakker` executable in a real `.app` bundle so
# macOS Launch Services can register the bundle id `com.local.ntakker`.
# Without this, TCC has no record of the bundle id (verifiable with
# `tccutil reset Microphone com.local.ntakker` reporting "No such
# bundle identifier"), which causes:
#
#   * The macOS microphone prompt to either not appear or be attributed
#     to the parent process (your terminal).
#   * `AVCaptureSession.startRunning()` to succeed silently while
#     never delivering microphone buffers.
#   * `ntakker` to never appear in System Settings > Privacy &
#     Security > Microphone.
#
# Screen Recording is unaffected because that TCC service is keyed by
# binary path rather than bundle id.
#
# This script is idempotent. Re-running it rebuilds the binary,
# refreshes the `.app` payload, re-applies the ad-hoc signature, and
# nudges Launch Services to re-register the bundle.
#
# Usage:
#   bash bin/build-ntakker-app.sh                # debug build
#   bash bin/build-ntakker-app.sh --release      # release build
#
# Output:
#   dist/ntakker.app
#
# After the first build, EITHER `open dist/ntakker.app` OR drag the
# bundle into ~/Applications/ to give it a stable path. The first
# microphone-touching action will then prompt; once granted, the bundle
# appears in System Settings > Microphone like any other app.
#
# Re-prompt note (R-23, R-2 in `Issues - Pending Items.md`): ad-hoc
# signatures are not stable across rebuilds, so macOS may invalidate
# the TCC grant and re-prompt after each `bin/build-ntakker-app.sh`
# run. A real Developer ID signature in v2 packaging fixes this.

set -euo pipefail

# ---- 1. Resolve paths ----
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

CONFIG="debug"
SWIFT_BUILD_FLAGS=()
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
    SWIFT_BUILD_FLAGS+=("-c" "release")
fi

BIN_NAME="ntakker"
APP_BUNDLE_NAME="${BIN_NAME}.app"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST_SRC="$PROJECT_ROOT/Resources/Ntakker-Info.plist"
INFO_PLIST_DST="$CONTENTS_DIR/Info.plist"
ENTITLEMENT_PLIST="$PROJECT_ROOT/.build/$CONFIG/${BIN_NAME}-entitlement.plist"

if [[ ! -f "$INFO_PLIST_SRC" ]]; then
    echo "error: Info.plist source missing: $INFO_PLIST_SRC" >&2
    exit 2
fi

# ---- 2. Build the binary ----
echo "==> swift build --product $BIN_NAME ${SWIFT_BUILD_FLAGS[*]:-}"
# `set -u` treats an empty array as unbound; the `+` parameter
# expansion sidesteps that without disabling the safety net.
swift build --product "$BIN_NAME" ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"}

BIN_SRC="$PROJECT_ROOT/.build/$CONFIG/$BIN_NAME"
if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: built binary not found at $BIN_SRC" >&2
    exit 3
fi

# ---- 3. (Re)build the bundle layout ----
echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_SRC" "$MACOS_DIR/$BIN_NAME"
cp "$INFO_PLIST_SRC" "$INFO_PLIST_DST"

# App icon. Regenerate from the Swift source if the .icns is missing
# (e.g. a fresh checkout) so packaging never silently ships an
# icon-less bundle.
ICON_ICNS="$PROJECT_ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICON_ICNS" ]]; then
    echo "==> regenerating Resources/AppIcon.icns (source missing)"
    swift "$PROJECT_ROOT/scripts/generate-appicon.swift"
    iconutil -c icns "$PROJECT_ROOT/Resources/AppIcon.iconset" -o "$ICON_ICNS"
fi
cp "$ICON_ICNS" "$RESOURCES_DIR/AppIcon.icns"

# PkgInfo is optional but trips fewer Launch Services edge cases when
# present. "APPL????" is the canonical "generic application" tag.
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# ---- 4. Re-sign the embedded binary ----
# Moving the binary into the bundle invalidates the linker-emitted
# signature; LS will refuse to register the bundle if the signature
# is broken. Re-apply ad-hoc sign so the bundle is internally
# consistent. If a project-level entitlement plist exists, pass it
# through (preserves get-task-allow for debugging).
echo "==> codesign --force --sign - --timestamp=none $APP_DIR"
if [[ -f "$ENTITLEMENT_PLIST" ]]; then
    codesign --force --sign - --timestamp=none \
        --entitlements "$ENTITLEMENT_PLIST" \
        "$APP_DIR"
else
    codesign --force --sign - --timestamp=none "$APP_DIR"
fi

# ---- 5. Nudge Launch Services to re-register ----
# `lsregister -f` forces a re-registration of the bundle even if LS
# thinks it has already seen it. Without this, Launch Services may
# keep a stale record from a previous build (or no record at all if
# the bundle has never been opened). After this, `tccutil reset
# Microphone com.local.ntakker` should succeed, and the next
# microphone-touching action will produce a real per-app prompt.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    echo "==> lsregister -f $APP_DIR"
    "$LSREGISTER" -f "$APP_DIR" || true
else
    echo "note: lsregister not found at expected path; LS may take a moment to pick up the bundle" >&2
fi

# ---- 6. Verify ----
echo
echo "==> codesign -dv $APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | sed 's/^/    /'
echo
echo "Bundle ready: $APP_DIR"
echo
echo "Next steps:"
echo "  1. Reset any stale TCC state (now succeeds because LS knows the bundle):"
echo "       tccutil reset Microphone com.local.ntakker"
echo "  2. Launch the bundle (NOT the bare binary in .build/) and click Start:"
echo "       open $APP_DIR"
echo "  3. The macOS microphone prompt should appear, attributed to ntakker."
echo "  4. After granting, verify via:"
echo "       tail -f ~/.tool-agents/ntakker/ntakker.log | grep mic_health"
echo "     — buffers count and recentPeakAmp must be non-zero when you speak."
