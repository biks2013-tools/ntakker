#!/usr/bin/env bash
# scripts/redeploy-ntakker.sh
#
# One-shot redeploy pipeline for ntakker:
#
#   1. Kill any running instance so the bundle isn't busy.
#   2. Rebuild + repackage the `.app` into `dist/ntakker.app`
#      (via `scripts/package-ntakker-app.sh`).
#   3. Replace `/Applications/ntakker.app` with the fresh bundle.
#   4. Launch the freshly-installed app.
#
# Run from the repo root:
#
#     bash scripts/redeploy-ntakker.sh
#
# Pass-through env vars are honoured by the packaging step — e.g.
#
#     SWIFT_CONFIG=debug bash scripts/redeploy-ntakker.sh
#     CODESIGN_IDENTITY="Developer ID Application: …" bash scripts/redeploy-ntakker.sh

set -euo pipefail

# Resolve the repo root from this script's own location so the command
# works regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="ntakker"
DIST_APP="$REPO_ROOT/dist/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"

echo "==> [1/4] Stopping any running ${APP_NAME} instance"
pkill -x "${APP_NAME}" || true

echo "==> [2/4] Building + packaging .app bundle"
bash "$SCRIPT_DIR/package-ntakker-app.sh"

if [[ ! -d "$DIST_APP" ]]; then
    echo "ERROR: $DIST_APP not found after packaging step." >&2
    exit 1
fi

echo "==> [3/4] Installing to ${INSTALL_APP}"
rm -rf "$INSTALL_APP"
cp -R "$DIST_APP" "$INSTALL_APP"

echo "==> [4/4] Launching"
open "$INSTALL_APP"

echo "Done. ntakker is now running from ${INSTALL_APP}."
