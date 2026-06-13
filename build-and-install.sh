#!/usr/bin/env bash
# build-and-install.sh — one-stop "build everything + install" for ntakker.
#
# Produces both build flavors of the menu-bar app and installs the
# release flavor to /Applications, leaving exactly ONE ntakker entry
# in Spotlight / Launchpad.
#
# Steps (in order):
#   1. Build the DEBUG bundle  → dist/ntakker-debug.app
#      (kept locally so you can `open dist/ntakker-debug.app` while
#       developing; will NOT appear in Spotlight).
#   2. Build the RELEASE bundle → dist/ntakker.app
#      (signed, with AppIcon.icns + Info.plist).
#   3. Stop any running ntakker and replace /Applications/ntakker.app
#      with the release bundle.
#   4. Delete dist/ntakker.app — the same bits now live at
#      /Applications/ntakker.app, so keeping a copy in dist/ only
#      creates the "two icons in Spotlight" confusion.
#   5. Mark dist/ as non-indexable for Spotlight (.metadata_never_index)
#      and explicitly unregister every dist/* bundle from Launch
#      Services, so neither Spotlight nor Launchpad surfaces them.
#   6. Force-register /Applications/ntakker.app and flush Dock/Finder
#      so the new icon shows up immediately instead of "next login".
#
# Flags:
#   --release-only   Skip the debug build (still installs the release).
#   --no-install     Build both flavors, but do NOT touch /Applications.
#   -h, --help       Print this header.
#
# Exit status: non-zero on the first failed step (set -euo pipefail).

set -euo pipefail

# ----------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------
BUILD_DEBUG=1
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --release-only) BUILD_DEBUG=0 ;;
        --no-install)   INSTALL=0 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg' (use --help)" >&2
            exit 64
            ;;
    esac
done

# ----------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "$PROJECT_ROOT"

if [[ ! -f "$PROJECT_ROOT/Package.swift" ]]; then
    echo "error: Package.swift not found at $PROJECT_ROOT — wrong directory?" >&2
    exit 70
fi

DIST_DIR="$PROJECT_ROOT/dist"
DEBUG_BUNDLE="$DIST_DIR/ntakker-debug.app"
RELEASE_BUNDLE="$DIST_DIR/ntakker.app"
INSTALL_BUNDLE="/Applications/ntakker.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

if [[ ! -x "$LSREG" ]]; then
    echo "warning: lsregister not found at expected path — Spotlight refresh may be deferred" >&2
fi

# ----------------------------------------------------------------------
# 1. Debug bundle
# ----------------------------------------------------------------------
if [[ $BUILD_DEBUG -eq 1 ]]; then
    echo "==> [1/6] Building DEBUG bundle"
    # bin/build-ntakker-app.sh always emits dist/ntakker.app — move it
    # aside immediately so step 2 (release) can land at the canonical
    # dist/ntakker.app path without colliding.
    bash bin/build-ntakker-app.sh
    rm -rf "$DEBUG_BUNDLE"
    mv "$RELEASE_BUNDLE" "$DEBUG_BUNDLE"
    echo "    debug bundle ready: $DEBUG_BUNDLE"
else
    echo "==> [1/6] Skipping debug build (--release-only)"
fi

# ----------------------------------------------------------------------
# 2. Release bundle
# ----------------------------------------------------------------------
echo
echo "==> [2/6] Building RELEASE bundle"
SWIFT_CONFIG=release bash scripts/package-ntakker-app.sh
echo "    release bundle ready: $RELEASE_BUNDLE"

# ----------------------------------------------------------------------
# 3. Install to /Applications
# ----------------------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
    echo
    echo "==> [3/6] Installing to $INSTALL_BUNDLE"

    # Stop the running menu-bar instance so we can overwrite the bundle.
    # `killall ntakker` matches the exact executable name from the
    # Info.plist's CFBundleExecutable, so it will not kill `ntakker-cli`
    # or this script.
    if pgrep -x ntakker > /dev/null; then
        echo "    stopping running ntakker process"
        killall ntakker || true
        # brief grace period for the process to release file handles
        sleep 0.5
    fi

    if [[ -e "$INSTALL_BUNDLE" ]]; then
        rm -rf "$INSTALL_BUNDLE"
    fi
    # `cp -R` preserves the codesign seal — using `cp -Rp` would be
    # equivalent on macOS, but -R is enough here.
    cp -R "$RELEASE_BUNDLE" "$INSTALL_BUNDLE"
    echo "    installed: $INSTALL_BUNDLE"
else
    echo
    echo "==> [3/6] Skipping install (--no-install)"
fi

# ----------------------------------------------------------------------
# 4. Drop the duplicate release copy from dist/
# ----------------------------------------------------------------------
# The release bundle has been promoted to /Applications. Keeping a
# second copy in dist/ is the root cause of the "two ntakker tiles in
# Spotlight" symptom — Launch Services treats different paths as
# different installs, even with the same CFBundleIdentifier.
if [[ $INSTALL -eq 1 ]]; then
    echo
    echo "==> [4/6] Removing dist/ntakker.app (now lives at $INSTALL_BUNDLE)"
    rm -rf "$RELEASE_BUNDLE"
else
    echo
    echo "==> [4/6] Keeping dist/ntakker.app (no install requested)"
fi

# ----------------------------------------------------------------------
# 5. Hide remaining dist/* bundles from Spotlight + Launch Services
# ----------------------------------------------------------------------
echo
echo "==> [5/6] Excluding dist/ from Spotlight / Launch Services"

# 5a. Spotlight: a `.metadata_never_index` marker file tells `mds` to
#     skip the entire directory tree. Persistent until removed.
touch "$DIST_DIR/.metadata_never_index"

# 5b. Launch Services: explicitly drop any registration that may have
#     been created by `bin/build-ntakker-app.sh` (which calls
#     `lsregister -f` at the end of its run) or by a prior `open` of
#     dist/. `open <absolute path>` still works after this, so the
#     debug bundle remains directly launchable.
if [[ -x "$LSREG" ]]; then
    "$LSREG" -u "$RELEASE_BUNDLE" 2>/dev/null || true
    "$LSREG" -u "$DEBUG_BUNDLE"   2>/dev/null || true
fi

# ----------------------------------------------------------------------
# 6. Refresh the installed bundle's registration and repaint UI
# ----------------------------------------------------------------------
echo
echo "==> [6/6] Refreshing Launch Services for $INSTALL_BUNDLE"

if [[ $INSTALL -eq 1 && -x "$LSREG" ]]; then
    # Force re-registration so LS re-reads the bundle's Info.plist and
    # AppIcon.icns. Without this, Launchpad/Dock can keep painting the
    # generic "blueprint" placeholder for ~hours after install.
    "$LSREG" -f "$INSTALL_BUNDLE" 2>/dev/null || true
fi

# Bouncing the Dock + Finder is what actually makes the new icon
# appear NOW. Both auto-relaunch.
killall Dock   2>/dev/null || true
killall Finder 2>/dev/null || true

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo
echo "Done."
if [[ $BUILD_DEBUG -eq 1 ]]; then
    echo "  Debug bundle  : $DEBUG_BUNDLE"
    echo "                  (run with: open '$DEBUG_BUNDLE')"
fi
if [[ $INSTALL -eq 1 ]]; then
    echo "  Installed copy: $INSTALL_BUNDLE"
    echo "                  (launchable from Spotlight / Launchpad / Dock)"
else
    echo "  Release bundle: $RELEASE_BUNDLE  (not installed)"
fi
echo
echo "Spotlight / Launchpad should now show exactly one ntakker entry."
