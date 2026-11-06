#!/bin/bash
# Launches the app's real binary the way a double-click does (no arguments, no terminal) and checks it keeps running.
# A binary that prints help and exits, or crashes at startup, fails here. Demo mode: no scanning, no real data.
# Usage: scripts/test-launch.sh [path-to-binary]
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/AIKeeper}"
[ -x "$BIN" ] || { echo "Build first; no binary at $BIN"; exit 1; }
DATA="$(mktemp -d)"
AIKEEPER_DEMO=1 AIKEEPER_DATA="$DATA" "$BIN" </dev/null >"$DATA/out.log" 2>&1 &
PID=$!
sleep 6
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  rm -rf "$DATA"; echo "launch ok: still running after 6 seconds"; exit 0
fi
echo "FAIL: the app exited within 6 seconds"; head -5 "$DATA/out.log"; rm -rf "$DATA"; exit 1
