#!/bin/bash
# Rebuilds and relaunches the app whenever a Swift file changes. An incremental debug build takes a few seconds.
#   scripts/dev.sh          demo data (invented workspaces and sessions; nothing on this Mac is read or changed)
#   scripts/dev.sh --real   your real data
# The app reopens on the area and tab you were last looking at. Stop with Ctrl-C.
set -uo pipefail
cd "$(dirname "$0")/.."
REAL=0; [ "${1:-}" = "--real" ] && REAL=1
BIN=.build/debug/AIKeeper
STAMP="$(mktemp)"
PID=""

stop() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; }
trap 'stop; rm -f "$STAMP"; echo; exit 0' INT TERM

build() {
  local t0=$SECONDS out; out="$(swift build 2>&1)"
  if echo "$out" | grep -q "error:"; then
    echo "$out" | grep -E "error:" | sort -u | head -20
    echo "── build failed; the running app is unchanged. Fix and save again."
    return 1
  fi
  echo "── built in $((SECONDS - t0))s at $(date +%H:%M:%S)"
}

# Start the new build first and close the old one once its window is up, so there is no blank gap between versions.
launch() {
  local old="$PID"
  if [ "$REAL" = 1 ]; then AIKEEPER_DEV=1 AIKEEPER_NOSPLASH=1 "$BIN" >/dev/null 2>&1 &
  else AIKEEPER_DEV=1 AIKEEPER_DEMO=1 AIKEEPER_NOSPLASH=1 "$BIN" >/dev/null 2>&1 &
  fi
  PID=$!
  if [ -n "$old" ]; then sleep 1.2; kill "$old" 2>/dev/null; wait "$old" 2>/dev/null; fi
}

echo "Watching Sources/ for changes ($([ "$REAL" = 1 ] && echo "real data" || echo "demo data")). Ctrl-C to stop."
touch "$STAMP"
build && launch
while true; do
  sleep 1
  if [ -n "$(find Sources Package.swift -name '*.swift' -newer "$STAMP" -print -quit)" ]; then
    touch "$STAMP"
    sleep 0.3   # let an editor finish writing several files
    build && launch
  fi
done
