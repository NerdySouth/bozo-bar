#!/usr/bin/env bash
#
# Full release pipeline: build -> sign -> notarize -> staple -> DMG -> notarize -> staple.
# Produces a notarized, stapled DMG ready for distribution outside the App Store.
#
# Usage:  scripts/release.sh <version>      e.g. scripts/release.sh 1.0.0
#
# Requires a notarytool keychain profile named below (PROFILE), created with:
#   xcrun notarytool store-credentials personal-dev --apple-id <id> --team-id B283H78XJ3 --password <app-pw>
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version, e.g. 1.0.0>}"

APP_NAME="BozoBar"
IDENTITY="Developer ID Application: TRISTEN SETH NOLLMAN (B283H78XJ3)"
PROFILE="personal-dev"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME.zip"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

# 1. Build + sign the .app and zip it (delegated to package.sh)
./scripts/package.sh

# 2. Notarize the .app (submitting the zip), then staple the ticket onto the .app
echo "==> Notarizing app bundle"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 3. Build a DMG (drag-to-Applications layout) from the stapled .app
echo "==> Building DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"

# 4. Sign, notarize, and staple the DMG itself
echo "==> Signing + notarizing DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 5. Final verification
echo "==> Verifying"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Release artifact ready: $DMG"
