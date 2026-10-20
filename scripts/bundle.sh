#!/bin/bash
# Builds a release AIKeeper.app into ./dist.
#   VERSION=1.2.3          marketing version written to Info.plist (default 0.1.0)
#   ARCHS="arm64 x86_64"   build a universal binary (default: this machine's architecture)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD_NUMBER:-1}"

# One build per architecture, joined with lipo. (SwiftPM's --arch with several values needs full Xcode; --triple does not.)
ARCH_LIST=(${ARCHS:-})
if [ "${#ARCH_LIST[@]}" -gt 1 ]; then
  SLICES=()
  for a in "${ARCH_LIST[@]}"; do
    # A separate scratch dir per architecture: sharing one build database between triples makes SwiftPM fail
    # intermittently with "command ... not registered".
    SCRATCH="$PWD/.build-universal/$a"
    swift build -c release --triple "${a}-apple-macosx14.0" --scratch-path "$SCRATCH"
    SLICES+=("$(swift build -c release --triple "${a}-apple-macosx14.0" --scratch-path "$SCRATCH" --show-bin-path)/AIKeeper")
  done
  mkdir -p dist
  BIN=dist/AIKeeper-universal
  lipo -create "${SLICES[@]}" -output "$BIN"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/AIKeeper"
fi

APP=dist/AIKeeper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIKeeper"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AI Keeper</string>
<key>CFBundleDisplayName</key><string>AI Keeper</string>
<key>CFBundleIdentifier</key><string>co.architect.ai-keeper</string>
<key>CFBundleExecutable</key><string>AIKeeper</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/AIKeeper"))"
