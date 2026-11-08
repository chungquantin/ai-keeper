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
"$K" ui --snapshot home --size 76x21 > "$OUT/home.ans"
"$K" ui --snapshot workspaces --size 124x19 --select 3 > "$OUT/workspaces.ans"
"$K" ui --snapshot skills --size 124x17 > "$OUT/skills.ans"
"$K" ui --snapshot confirm --size 92x13 --select 3 > "$OUT/confirm.ans"
python3 - "$OUT" "$VERSION" <<'PY'
import re, sys
sys.path.insert(0, "scripts")
from ansi2html import convert
out, version = sys.argv[1], sys.argv[2]
def term(name, label, caption="", cls="term"):
    text = open(f"{out}/{name}.ans").read().rstrip("\n").replace("keeper dev", f"keeper {version}")
    cap = f"<figcaption>{caption}</figcaption>" if caption else ""
    box = (f'<div class="{cls}" role="img" aria-label="{label}"><div class="term-bar"><span>{name if name != "ws" else "workspaces"}</span></div>'
           f'<pre aria-hidden="true">{convert(text)}</pre></div>')
    return f'<figure class="term-fig">{cap}{box}</figure>' if caption else box

hero = ("<!-- terminal-hero:start -->\n"
        + term("home", "The keeper dashboard: 107.9 GB you can get back drawn as large numerals, where it comes from, and a numbered menu.", cls="term term-hero") + "\n"
        + "<!-- terminal-hero:end -->")
block = ("<!-- terminal:start -->\n"
         + term("workspaces", "The keeper workspace picker. Three safe workspaces are selected, and a preview explains why the highlighted one can go.", "Pick what goes, with the reason beside it.", "term term-lg") + "\n"
         + '<div class="term-pair">\n'
         + term("skills", "The keeper skills screen: ten skills with risk ratings from NVIDIA SkillSpector, and the findings for the highlighted one.", "Check every skill your agents can load.") + "\n"
         + term("confirm", "The confirmation screen listing three workspaces to remove, 22.9 GB in total.", "Nothing happens until you confirm.") + "\n"
         + "</div>\n<!-- terminal:end -->")
html = open("site/index.html").read()
html = re.sub(r"<!-- terminal-hero:start -->.*?<!-- terminal-hero:end -->", lambda m: hero, html, flags=re.S)
html = re.sub(r"<!-- terminal:start -->.*?<!-- terminal:end -->", lambda m: block, html, flags=re.S)
open("site/index.html", "w").write(html)
print("Updated the terminal windows in site/index.html")
PY
