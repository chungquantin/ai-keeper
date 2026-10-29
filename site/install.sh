#!/bin/bash
# Installs the latest AI Keeper release into /Applications.
#
#   curl -fsSL https://chungquantin.github.io/ai-keeper/install.sh | bash
#
# Why this exists: releases are not notarized yet, and a zip downloaded in a browser is quarantined, so macOS refuses
# to open it. A file fetched by curl is not quarantined. The download is checked against the SHA-256 published with
# the release before anything is installed. Set INSTALL_DIR to install somewhere else.
set -euo pipefail

REPO="chungquantin/ai-keeper"
DEST="${INSTALL_DIR:-/Applications}"

for tool in curl ditto shasum; do
  command -v "$tool" >/dev/null || { echo "AI Keeper installer: '$tool' is required." >&2; exit 1; }
done
[ "$(uname -s)" = "Darwin" ] || { echo "AI Keeper is a macOS app." >&2; exit 1; }
if pgrep -f "$DEST/AI Keeper.app/Contents/MacOS/AIKeeper" >/dev/null 2>&1; then
  echo "AI Keeper is running. Quit it first, then run this again." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Finding the latest release..."
ZIP_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"browser_download_url": *"\([^"]*AI-Keeper-[0-9][^"]*\.zip\)".*/\1/p' | head -1)"
[ -n "$ZIP_URL" ] || { echo "Could not find a release to download." >&2; exit 1; }
NAME="$(basename "$ZIP_URL")"

echo "Downloading $NAME..."
curl -fsSL -o "$TMP/$NAME" "$ZIP_URL"
curl -fsSL -o "$TMP/$NAME.sha256" "$ZIP_URL.sha256"

echo "Checking the download..."
WANT="$(tr -d '[:space:]' < "$TMP/$NAME.sha256" | cut -c1-64)"   # the release publishes just the hash
GOT="$(shasum -a 256 "$TMP/$NAME" | awk '{print $1}')"
[ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || { echo "The download does not match its checksum. Nothing was installed." >&2; exit 1; }

ditto -x -k "$TMP/$NAME" "$TMP/unpacked"
[ -d "$TMP/unpacked/AI Keeper.app" ] || { echo "The download did not contain AI Keeper.app." >&2; exit 1; }

mkdir -p "$DEST"
rm -rf "$DEST/AI Keeper.app"
ditto "$TMP/unpacked/AI Keeper.app" "$DEST/AI Keeper.app"
xattr -dr com.apple.quarantine "$DEST/AI Keeper.app" 2>/dev/null || true

echo "Installed $DEST/AI Keeper.app"
echo "Open it from Launchpad or Spotlight."
