#!/bin/bash
# Type-checks the preview files without Xcode. `#Preview` needs Xcode's macro plugin, which the command-line tools do not have,
# so this turns each `#Preview("name") { ... }` into an ordinary function in a scratch copy of the package and builds that.
# Usage: scripts/check-previews.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/AIKeeperPreviews"
sed "s#path: \"..\"#path: \"$PWD\"#" Previews/Package.swift > "$WORK/Package.swift"
n=0
for f in Previews/Sources/AIKeeperPreviews/*.swift; do
  python3 - "$f" "$WORK/Sources/AIKeeperPreviews/$(basename "$f")" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
i = [0]
def fn(m):
    i[0] += 1
    return f'@MainActor func _preview{i[0]}_{abs(hash(m.group(1))) % 10**6}() -> some View {{'
out = re.sub(r'#Preview\("([^"]*)"\)\s*\{', fn, src)
out = re.sub(r'#Preview\s*\{', lambda m: '@MainActor func _previewAnon%d() -> some View {' % (i.__setitem__(0, i[0] + 1) or i[0]), out)
open(sys.argv[2], 'w').write(out)
PY
done
cd "$WORK"
OUT="$(swift build 2>&1 || true)"
if echo "$OUT" | grep -q "error:"; then echo "$OUT" | grep -E "error:" | sort -u | head -30; exit 1; fi
echo "previews type-checked"
