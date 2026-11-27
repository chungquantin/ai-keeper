#!/bin/bash
# Runs the unit tests. With full Xcode this is just `swift test`; with only the Command Line Tools, SwiftPM does not
# find the Swift Testing framework by itself, so point it at the copy the tools ship.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT/Frameworks/Testing.framework" ]; then
  exec swift test -Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks" \
       -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
