#!/usr/bin/env bash
# scripts/release-ntakker-studio.sh — build, sign, notarize and package
# ntakker-studio for a GitHub release: a zip (used by the Homebrew cask) and a
# drag-to-Applications disk image, plus SHA256SUMS and the Homebrew cask for
# this version (homebrew-tap/Casks/ntakker-studio.rb).
#
# Required environment (no defaults — a release is always Developer ID signed
# and notarized):
#   NTAKKER_STUDIO_SIGN_IDENTITY  Developer ID Application identity, by SHA-1
#                                 (two identities share the name). List them:
#                                 security find-identity -v -p codesigning
#   NOTARY_PROFILE                notarytool keychain profile
#                                 (xcrun notarytool store-credentials <name>).
#
# Usage:
#   NTAKKER_STUDIO_SIGN_IDENTITY=<sha1> NOTARY_PROFILE=<profile> \
#     bash scripts/release-ntakker-studio.sh
#
# The version is CFBundleShortVersionString in Resources/NtakkerStudio-Info.plist.
# Publishing (tag, GitHub release, tap) is in docs/tools/ntakker-studio.md, "Releasing".
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

PLIST="$ROOT/Resources/NtakkerStudio-Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
APP="$ROOT/dist/ntakker-studio.app"
OUT="$ROOT/dist/release"
ZIP="$OUT/ntakker-studio-$VERSION.zip"
DMG="$OUT/ntakker-studio-$VERSION.dmg"
SUMS="$OUT/SHA256SUMS"
CASK="$ROOT/homebrew-tap/Casks/ntakker-studio.rb"
TAG="ntakker-studio-v$VERSION"
REPO="biks2013-tools/recording-tool"

[[ -n "$VERSION" ]] || { echo "error: no CFBundleShortVersionString in $PLIST" >&2; exit 1; }
[[ -n "${NTAKKER_STUDIO_SIGN_IDENTITY:-}" ]] || { echo "error: NTAKKER_STUDIO_SIGN_IDENTITY is not set (Developer ID Application SHA-1)" >&2; exit 1; }
[[ -n "${NOTARY_PROFILE:-}" ]] || { echo "error: NOTARY_PROFILE is not set (a release must be notarized)" >&2; exit 1; }

echo "=== Releasing ntakker-studio $VERSION ($BUNDLE_ID) ==="

# 1. Tests: the studio's suites must be green.
swift test --filter NtakkerStudioTests

# 2. Release build, signed with the hardened runtime.
CODESIGN_IDENTITY="$NTAKKER_STUDIO_SIGN_IDENTITY" bash scripts/package-ntakker-studio-app.sh

# 3. The signature must be Developer ID with the hardened runtime.
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] \
  || { echo "error: not signed with a Developer ID Application identity" >&2; exit 1; }
[[ "$SIGNATURE" =~ flags=0x[0-9a-f]+\(runtime\) ]] \
  || { echo "error: hardened runtime is not enabled" >&2; exit 1; }

# 4. Zip, notarize, staple, zip again (ditto is the format Apple recommends).
rm -rf "$OUT"
mkdir -p "$OUT"
make_zip() { rm -f "$ZIP"; ditto -c -k --norsrc --keepParent "$APP" "$ZIP"; }
make_zip
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
make_zip
spctl --assess --type execute --verbose=2 "$APP"

# 5. Disk image with the install notes, signed, notarized and stapled.
STAGE="$ROOT/dist/dmg-root"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ntakker-studio.app"
ln -s /Applications "$STAGE/Applications"
cp packaging/ntakker-studio/INSTALL.txt "$STAGE/INSTALL.txt"
hdiutil create -volname "ntakker studio $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$NTAKKER_STUDIO_SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# 6. Checksums.
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$SUMS")

# 7. Homebrew cask for this version (copied into biks2013-tools/homebrew-ntakker-studio).
mkdir -p "$(dirname "$CASK")"
cat > "$CASK" <<CASKEOF
cask "ntakker-studio" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/ntakker-studio-v#{version}/ntakker-studio-#{version}.zip"
  name "ntakker studio"
  desc "Explore ntakker recordings: transcripts, playback, cuts, Q&A and minutes"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :tahoe"

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

echo ""
echo "=== Release package complete ==="
echo "Version:    $VERSION"
echo "Zip:        $ZIP"
echo "Zip SHA256: $SHA"
echo "DMG:        $DMG"
echo "Cask:       $CASK"
echo "Next: tag $TAG, create the GitHub release with the zip, DMG and SHA256SUMS, update the tap."
