#!/usr/bin/env bash
# scripts/release.sh — build, sign, notarize and package one product for a
# GitHub release, and write its Homebrew cask.
#
#   bash scripts/release.sh ntakker          menu-bar app  → .zip + .dmg
#   bash scripts/release.sh ntakker-studio   Dock app      → .zip + .dmg
#   bash scripts/release.sh ntakker-cli      command line  → .zip (binary)
#
# Required environment (no defaults — a release is always Developer ID
# signed and notarized):
#   NTAKKER_SIGN_IDENTITY  Developer ID Application identity, by SHA-1 (two
#                          identities share the name). List them:
#                          security find-identity -v -p codesigning
#   NOTARY_PROFILE         notarytool keychain profile
#                          (xcrun notarytool store-credentials <name>).
#
# Output in dist/release/<product>/: the archives, SHA256SUMS; and
# homebrew-tap/Casks/<product>.rb. Publishing (tag, GitHub release, tap) is
# described in docs/tools/<product>.md, "Releasing".
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PRODUCT="${1:-}"
REPO="biks2013-tools/ntakker"
TAP_NAME="biks2013-tools/ntakker"

case "$PRODUCT" in
  ntakker)        PLIST="Resources/Ntakker-Info.plist";       KIND=app; TESTS="NtakkerUITests|NtakkerCoreTests" ;;
  ntakker-studio) PLIST="Resources/NtakkerStudio-Info.plist"; KIND=app; TESTS="NtakkerStudioTests" ;;
  ntakker-cli)    PLIST="Resources/Info.plist";               KIND=cli; TESTS="NtakkerCoreTests" ;;
  *) echo "usage: $0 ntakker|ntakker-studio|ntakker-cli" >&2; exit 64 ;;
esac
[[ -n "${NTAKKER_SIGN_IDENTITY:-}" ]] || { echo "error: NTAKKER_SIGN_IDENTITY is not set (Developer ID Application SHA-1)" >&2; exit 1; }
[[ -n "${NOTARY_PROFILE:-}" ]] || { echo "error: NOTARY_PROFILE is not set (a release must be notarized)" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
OUT="$ROOT/dist/release/$PRODUCT"
ZIP="$OUT/$PRODUCT-$VERSION.zip"
DMG="$OUT/$PRODUCT-$VERSION.dmg"
CASK="$ROOT/homebrew-tap/Casks/$PRODUCT.rb"
TAG="$PRODUCT-v$VERSION"
if [[ "$PRODUCT" == ntakker-cli ]]; then
  CLI_VERSION="$(sed -n 's/.*version: "\(.*\)",.*/\1/p' Sources/ntakker-cli/Commands/RootCommand.swift)"
  [[ "$CLI_VERSION" == "$VERSION" ]] || { echo "error: RootCommand version ($CLI_VERSION) != $PLIST ($VERSION)" >&2; exit 1; }
fi
echo "=== Releasing $PRODUCT $VERSION ($BUNDLE_ID) ==="

# 1. Tests. Anything failing that is not in scripts/release-known-failures.txt stops the release.
LOG="$(mktemp)"
swift test --filter "$TESTS" > "$LOG" 2>&1 || true
FAILED="$( { sed -n 's/^✘ Test "\(.*\)" failed after.*/\1/p' "$LOG"; sed -n "s/^Test Case '\(.*\)' failed.*/\1/p" "$LOG"; } | sort -u)"
UNEXPECTED="$(grep -vxF -f <(grep -v '^#' scripts/release-known-failures.txt) <<<"$FAILED" || true)"
if ! grep -qE "Test run with [0-9]+ tests|Executed [0-9]+ tests" "$LOG"; then
  echo "error: the tests did not run:" >&2; tail -20 "$LOG" >&2; exit 1
fi
if [[ -n "$UNEXPECTED" ]]; then
  echo "error: tests failing that are not known failures:" >&2; echo "$UNEXPECTED" >&2; exit 1
fi
echo "tests: no new failures ($(grep -c . <<<"$FAILED" || true) known)"

rm -rf "$OUT"; mkdir -p "$OUT"
verify_sig() {
  codesign --verify --strict --verbose=2 "$1"
  local sig; sig="$(codesign -dvv "$1" 2>&1)"
  [[ "$sig" == *"Authority=Developer ID Application"* ]] || { echo "error: $1 is not Developer ID signed" >&2; exit 1; }
  [[ "$sig" =~ flags=0x[0-9a-f]+\(runtime\) ]] || { echo "error: $1 lacks the hardened runtime" >&2; exit 1; }
}
notarize() { xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr | grep "status: Accepted" >/dev/null; }

if [[ "$KIND" == app ]]; then
  APP="$ROOT/dist/$PRODUCT.app"
  # 2. Release build, hardened runtime, Developer ID.
  CODESIGN_IDENTITY="$NTAKKER_SIGN_IDENTITY" bash "scripts/package-$PRODUCT-app.sh"
  verify_sig "$APP"
  # 3. Zip → notarize → staple → zip again.
  make_zip() { rm -f "$ZIP"; ditto -c -k --norsrc --keepParent "$APP" "$ZIP"; }
  make_zip; notarize "$ZIP"
  xcrun stapler staple "$APP"; xcrun stapler validate "$APP"
  make_zip
  spctl --assess --type execute --verbose=2 "$APP"
  # 4. Drag-to-Applications disk image, signed, notarized, stapled.
  STAGE="$ROOT/dist/dmg-root"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$PRODUCT.app"
  ln -s /Applications "$STAGE/Applications"
  cp "packaging/$PRODUCT/INSTALL.txt" "$STAGE/INSTALL.txt"
  hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$NTAKKER_SIGN_IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"; xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  (cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
else
  # 2. Release build of the binary, hardened runtime, Developer ID, mic entitlement.
  swift build -c release --product ntakker-cli
  BIN="$(swift build -c release --show-bin-path)/ntakker-cli"
  STAGE="$ROOT/dist/cli-root"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp "$BIN" "$STAGE/ntakker-cli"
  codesign --force --options runtime --timestamp --identifier "$BUNDLE_ID" \
    --entitlements Resources/ntakker.entitlements --sign "$NTAKKER_SIGN_IDENTITY" "$STAGE/ntakker-cli"
  verify_sig "$STAGE/ntakker-cli"
  cp packaging/ntakker-cli/INSTALL.txt "$STAGE/INSTALL.txt"
  # 3. Zip → notarize. A bare binary cannot be stapled; Gatekeeper checks the ticket online.
  (cd "$STAGE" && ditto -c -k --norsrc . "$ZIP")
  notarize "$ZIP"
  rm -rf "$STAGE"
  (cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS)
fi
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# 5. Homebrew cask for this version.
mkdir -p "$(dirname "$CASK")"
URL="https://github.com/$REPO/releases/download/$PRODUCT-v#{version}/$PRODUCT-#{version}.zip"
case "$PRODUCT" in
  ntakker) cat > "$CASK" <<CASKEOF
cask "ntakker" do
  version "$VERSION"
  sha256 "$SHA"

  url "$URL"
  name "ntakker"
  desc "Menu-bar recorder for system audio and microphone, with live transcription"
  homepage "https://github.com/$REPO"

  depends_on macos: :tahoe

  app "ntakker.app"

  uninstall quit: "$BUNDLE_ID"

  zap trash: [
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]

  caveats <<~EOS
    ntakker lives in the menu bar (no Dock icon). On the first recording macOS
    asks for Microphone and Screen Recording (system audio); allow both.
    Settings and provider keys are kept in ~/.tool-agents/ntakker/.env.
    Companion apps: brew install --cask $TAP_NAME/ntakker-studio
                    brew install --cask $TAP_NAME/ntakker-cli
  EOS
end
CASKEOF
  ;;
  ntakker-studio) cat > "$CASK" <<CASKEOF
cask "ntakker-studio" do
  version "$VERSION"
  sha256 "$SHA"

  url "$URL"
  name "ntakker studio"
  desc "Explore ntakker recordings: transcripts, playback, cuts, Q&A and minutes"
  homepage "https://github.com/$REPO"

  depends_on macos: :tahoe

  app "ntakker-studio.app"

  uninstall quit: "$BUNDLE_ID"

  zap trash: [
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]

  caveats <<~EOS
    ntakker studio opens the recordings ntakker saved. On first launch it uses
    ntakker's recording folder, or asks you to choose one.
    Ask, minutes and re-transcription use ntakker's settings in
    ~/.tool-agents/ntakker/.env (NTAKKER_ASK_PROVIDER and the provider's key).
  EOS
end
CASKEOF
  ;;
  ntakker-cli) cat > "$CASK" <<CASKEOF
cask "ntakker-cli" do
  version "$VERSION"
  sha256 "$SHA"

  url "$URL"
  name "ntakker-cli"
  desc "Command-line recorder for system audio and microphone, with live transcription"
  homepage "https://github.com/$REPO"

  depends_on macos: :tahoe

  binary "ntakker-cli"

  caveats <<~EOS
    Run: ntakker-cli start --output ~/Recordings/test.m4a   (Ctrl-C stops)
    macOS asks your terminal app for Microphone and Screen Recording access
    on the first recording. Settings: ~/.tool-agents/ntakker-cli/.env.
  EOS
end
CASKEOF
  ;;
esac

echo ""
echo "=== $PRODUCT $VERSION packaged ==="
echo "Archives:   $OUT"
echo "Zip SHA256: $SHA"
echo "Cask:       $CASK"
echo "Next: tag $TAG, create the GitHub release with the files in $OUT, copy the cask to $TAP_NAME."
