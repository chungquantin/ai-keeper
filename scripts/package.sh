#!/bin/bash
# Builds a universal, signed "AI Keeper.app" and zips it for release.
#   VERSION=1.2.3                required
#   SIGN_IDENTITY="Developer ID Application: …"   optional; ad-hoc signed without it
#   NOTARIZE=1 plus either APPLE_API_KEY_P8 (base64) + APPLE_API_KEY_ID + APPLE_API_ISSUER,
#                    or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD     optional; notarizes and staples
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
  # Authenticate with an App Store Connect API key (preferred) or an Apple ID app-specific password.
  AUTH=()
  KEYFILE=""
  if [ -n "${APPLE_API_KEY_P8:-}" ]; then
    KEYFILE="$(mktemp)"
    printf '%s' "$APPLE_API_KEY_P8" | base64 --decode > "$KEYFILE"
    AUTH=(--key "$KEYFILE" --key-id "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID}" --issuer "${APPLE_API_ISSUER:?APPLE_API_ISSUER}")
  else
    AUTH=(--apple-id "${APPLE_ID:?APPLE_ID}" --team-id "${APPLE_TEAM_ID:?APPLE_TEAM_ID}" --password "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD}")
  fi
  trap '[ -n "$KEYFILE" ] && rm -f "$KEYFILE"' EXIT

  ditto -c -k --keepParent "$APP" dist/notarize.zip
  echo "Submitting to Apple's notary service (usually 1 to 5 minutes)..."
  xcrun notarytool submit dist/notarize.zip "${AUTH[@]}" --wait --output-format json > dist/notarize.json || true
  cat dist/notarize.json
  STATUS="$(python3 -c 'import json,sys; print(json.load(open("dist/notarize.json")).get("status",""))' 2>/dev/null || true)"
  SUBMISSION="$(python3 -c 'import json,sys; print(json.load(open("dist/notarize.json")).get("id",""))' 2>/dev/null || true)"
  if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization status: '${STATUS:-unknown}'. Apple's log:"
    [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" "${AUTH[@]}" || true
    exit 1
  fi
  rm -f dist/notarize.zip dist/notarize.json

  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Gatekeeper's own verdict: this is what a user's Mac will say on first launch.
  spctl --assess --type execute -vv "$APP"
  echo "Notarized and stapled."
fi

ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
echo "Packaged $ZIP"
echo "sha256 $(cat "$ZIP.sha256")"
