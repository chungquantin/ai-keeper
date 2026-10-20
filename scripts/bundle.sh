#!/bin/bash
# Builds a release AIKeeper.app into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/AIKeeper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIKeeper "$APP/Contents/MacOS/AIKeeper"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
