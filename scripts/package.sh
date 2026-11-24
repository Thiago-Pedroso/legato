#!/bin/bash
# Zips build/Legato.app for download. With notarization credentials in the environment it also
# sends the app to Apple and staples the ticket, so it opens on other Macs without warnings:
#   NOTARY_KEY      path to an App Store Connect API key (.p8)
#   NOTARY_KEY_ID   its key ID
#   NOTARY_ISSUER   its issuer ID
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Legato.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/Legato-$VERSION.zip"
rm -f "$ZIP"

if [ -n "${NOTARY_KEY:-}" ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  # Progress goes to stderr; stdout carries only the zip's path, for scripts.
  xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait >&2
  xcrun stapler staple "$APP" >&2
  rm "$ZIP"
else
  echo "No notarization credentials: on other Macs the app opens only after Open Anyway in Privacy & Security." >&2
fi
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"
