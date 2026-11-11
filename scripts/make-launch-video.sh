#!/bin/bash
# Renders the 30 second launch film (video/launch.html) to dist/ai-keeper-launch.mp4.
# Needs: node, ffmpeg and Google Chrome. Installs puppeteer-core into a temp folder, nothing in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "Install ffmpeg first: brew install ffmpeg"; exit 1; }
DEPS="${TMPDIR:-/tmp}/aikeeper-video-node"
[ -d "$DEPS/node_modules/puppeteer-core" ] || { mkdir -p "$DEPS" && (cd "$DEPS" && npm init -y >/dev/null && npm i puppeteer-core >/dev/null); }
mkdir -p dist
python3 video/music.py dist/ai-keeper-launch.wav
AUDIO=dist/ai-keeper-launch.wav NODE_PATH="$DEPS/node_modules" node video/capture.js dist/ai-keeper-launch.mp4 30 30
rm -f dist/ai-keeper-launch.wav
echo "Done: dist/ai-keeper-launch.mp4"
