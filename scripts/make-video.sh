#!/bin/bash
# Records the demo video from the real app in demo mode (fictional data), then composes and encodes it.
# Needs: ffmpeg. Output: dist/ai-keeper-demo.mp4. No paid tools or services, nothing leaves your Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "Install ffmpeg first: brew install ffmpeg"; exit 1; }
OUT=dist/ai-keeper-demo.mp4
REC=/tmp/aikeeper-video
swift build
# A throwaway bundle so macOS treats the app as a normal foreground app and keeps its window active.
APP=/tmp/AIKeeperVideo.app
rm -rf "$APP" "$REC"; mkdir -p "$APP/Contents/MacOS" dist
cp .build/debug/AIKeeper "$APP/Contents/MacOS/AIKeeper"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>AIKeeper</string><key>CFBundleIdentifier</key><string>dev.aikeeper.video</string><key>CFBundleName</key><string>AIKeeper</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PL
open -n --env AIKEEPER_DEMO=1 --env AIKEEPER_VIDEO="$REC" "$APP"
for _ in $(seq 1 150); do [ -f "$REC/timeline.json" ] && break; sleep 2; done
[ -f "$REC/timeline.json" ] || { pkill -x AIKeeper || true; echo "Recording did not finish"; exit 1; }
sleep 1; pkill -x AIKeeper || true
swift assets/video.swift "$REC" assets/icon-1024.png "$OUT"
echo "Done: $OUT"
