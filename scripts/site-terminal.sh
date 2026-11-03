#!/bin/bash
# Renders the terminal windows on the landing page from the real `keeper` dashboard, using the fictional demo data
# (never your own workspaces). Rewrites the block between the "terminal:start/end" markers in site/index.html.
# Usage: scripts/site-terminal.sh [path-to-binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/AIKeeper}"
[ -x "$BIN" ] || { echo "Build first (swift build)"; exit 1; }
VERSION="$(grep -m1 'VERSION="${VERSION:-' scripts/bundle.sh | sed -E 's/.*:-([0-9.]+)\}.*/\1/')"
BINDIR="$(mktemp -d)"; DATA="$(mktemp -d)"; OUT="$(mktemp -d)"
trap 'rm -rf "$BINDIR" "$DATA" "$OUT"' EXIT
ln -s "$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")" "$BINDIR/keeper"
export AIKEEPER_DEMO=1 AIKEEPER_DATA="$DATA" COLORTERM=truecolor
K="$BINDIR/keeper"
"$K" demo-export >/dev/null
"$K" ui --snapshot workspaces --size 128x19 --select 3 > "$OUT/workspaces.ans"
"$K" ui --snapshot confirm --size 92x13 --select 3 > "$OUT/confirm.ans"
python3 - "$OUT" "$VERSION" <<'PY'
import re, sys
sys.path.insert(0, "scripts")
from ansi2html import convert
out, version = sys.argv[1], sys.argv[2]
def term(name, label, caption, big=False):
    text = open(f"{out}/{name}.ans").read().rstrip("\n").replace("keeper dev", f"keeper {version}")
    cls = "term term-lg" if big else "term"
    return (f'<figure class="term-fig"><figcaption>{caption}</figcaption><div class="{cls}" role="img" aria-label="{label}"><div class="term-bar"><i></i><i></i><i></i><span>keeper</span></div>'
            f'<pre aria-hidden="true">{convert(text)}</pre></div></figure>')
block = ("<!-- terminal:start -->\n"
         + term("workspaces", "The keeper dashboard on the Workspaces screen. Three safe workspaces are selected, and a preview on the right explains why the highlighted one can go.",
                "Select what goes, with the reason beside it.", True) + "\n"
         + term("confirm", "The confirmation screen listing three workspaces to remove, 22.9 GB in total.",
                "Nothing happens until you confirm. Workspaces with an agent running in them are left alone.") + "\n"
         + "<!-- terminal:end -->")
html = open("site/index.html").read()
html = re.sub(r"<!-- terminal:start -->.*?<!-- terminal:end -->", lambda m: block, html, flags=re.S)
open("site/index.html", "w").write(html)
print("Updated the terminal windows in site/index.html")
PY
