#!/usr/bin/env bash
#
# Build, bundle, and sign BozoBar.app with the personal Developer ID cert,
# then produce a zip ready for notarization.
#
# Usage:  scripts/package.sh
#
# After this completes, notarize with:
#   xcrun notarytool submit build/BozoBar.zip --apple-id <id> --team-id B283H78XJ3 --password <app-pw> --wait
#   xcrun stapler staple build/BozoBar.app
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BozoBar"
BUNDLE_ID="dev.bozo.bar"
IDENTITY="Developer ID Application: TRISTEN SETH NOLLMAN (B283H78XJ3)"
ENTITLEMENTS="BozoBar.entitlements"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ICONSET_PNG="Sources/BozoBar/Assets.xcassets/AppIcon.appiconset/icon_1024.png"

echo "==> Universal release build"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Info.plist (add icon reference)
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"

# SwiftPM resource bundle (Assets, PrivacyInfo)
if [ -d "$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle" ]; then
  cp -R "$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
fi

echo "==> Generating AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size       "$ICONSET_PNG" --out "$ICONSET/icon_${size}x${size}.png"   >/dev/null
  sips -z $((size*2)) $((size*2)) "$ICONSET_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Code signing (hardened runtime)"
# Sign nested resource bundle first, then the app (inside-out)
if [ -d "$APP/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle" ]; then
  codesign --force --timestamp --options runtime \
    --sign "$IDENTITY" \
    "$APP/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
fi

codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | head -20 || true

echo "==> Zipping for notarization"
ZIP="$BUILD_DIR/$APP_NAME.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "Done. Artifacts:"
echo "  App: $APP"
echo "  Zip: $ZIP  (submit this to notarytool)"
