#!/bin/bash
# Builds build/Legato.app from the Swift package. No Xcode needed, only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Legato.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Legato "$APP/Contents/MacOS/Legato"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself, then packed into the sizes macOS wants.
ICONSET=build/Legato.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
.build/release/Legato --render-assets build/assets
for size in 16 32 128 256 512; do
  sips -z $size $size build/assets/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/assets/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Legato.icns"

# macOS ties the Microphone and Accessibility permissions to the signature. A stable identity
# (see scripts/dev-signing.sh) keeps them across rebuilds; an ad-hoc signature asks again.
IDENTITY="${LEGATO_SIGN_IDENTITY:-Legato Dev}"
DEV_KEYCHAIN="$HOME/Library/Keychains/legato-dev.keychain-db"
[ -f "$DEV_KEYCHAIN" ] && security unlock-keychain -p legato "$DEV_KEYCHAIN"
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  # A build for other people: notarization requires the hardened runtime, and under it the
  # microphone needs its entitlement.
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements Resources/Legato.entitlements "$APP"
elif security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
