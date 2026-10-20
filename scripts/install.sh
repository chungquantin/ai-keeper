#!/bin/bash
# Builds the app and installs it to /Applications so Spotlight, Launchpad and the Dock can find it.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
DEST="/Applications/AI Keeper.app"
pkill -x AIKeeper 2>/dev/null || true
rm -rf "$DEST"
cp -R dist/AIKeeper.app "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
mdimport "$DEST" 2>/dev/null || true
echo "Installed $DEST"
