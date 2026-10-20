#!/bin/bash
# Builds a universal, signed "AI Keeper.app" and zips it for release.
#   VERSION=1.2.3                required
#   SIGN_IDENTITY="Developer ID Application: …"   optional; ad-hoc signed without it
#   NOTARIZE=1 + APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   optional; notarizes and staples
# Output: dist/AI-Keeper-<version>.zip and dist/AI-Keeper-<version>.zip.sha256
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:?set VERSION, e.g. VERSION=0.1.0}"

ARCHS="${ARCHS:-arm64 x86_64}" VERSION="$VERSION" ./scripts/bundle.sh

APP="dist/AI Keeper.app"
ZIP="dist/AI-Keeper-${VERSION}.zip"
rm -rf "$APP" "$ZIP" "$ZIP.sha256"
mv dist/AIKeeper.app "$APP"   # the cask installs "AI Keeper.app"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  echo "No SIGN_IDENTITY: ad-hoc signed (users will see a Gatekeeper warning outside Homebrew)."
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

if [ "${NOTARIZE:-0}" = "1" ]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$APP"
  rm -f dist/notarize.zip
fi

ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
echo "Packaged $ZIP"
echo "sha256 $(cat "$ZIP.sha256")"
