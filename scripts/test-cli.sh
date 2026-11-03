#!/bin/bash
# End-to-end test of the `keeper` CLI against a throwaway repo, with its own data folder (AIKEEPER_DATA),
# so your real scan, vault and settings are never touched. Usage: scripts/test-cli.sh [path-to-binary]
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/AIKeeper}"
[ -x "$BIN" ] || { echo "Build first (swift build); no binary at $BIN"; exit 1; }
WORK="$(mktemp -d "$HOME/.keeper-cli-test.XXXXXX")"      # must live under $HOME: removal refuses paths outside it
DATA="$(mktemp -d)"; BINDIR="$(mktemp -d)"
ln -s "$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")" "$BINDIR/keeper"
K="$BINDIR/keeper"; export AIKEEPER_DATA="$DATA" NO_COLOR=1
trap 'rm -rf "$WORK" "$DATA" "$BINDIR"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
code() { "$@" >/dev/null 2>&1; echo $?; }

# A repo with three worktrees: one clean with a build folder, one with unsaved work, one with work that exists nowhere else.
git init -q "$WORK/repo" && cd "$WORK/repo" && git config user.email t@t && git config user.name t
echo "node_modules/" > .gitignore; echo one > a.txt; git add .; git commit -qm init
for w in ws-safe ws-dirty ws-danger; do git worktree add -q "../$w" -b "$w"; done
mkdir "$WORK/ws-safe/node_modules"; head -c 3000000 /dev/zero > "$WORK/ws-safe/node_modules/big.bin"
echo changed >> "$WORK/ws-dirty/a.txt"; head -c 4000 /dev/urandom > "$WORK/ws-dirty/blob.dat"; echo secret > "$WORK/ws-dirty/notes.txt"
mkdir "$WORK/cachey"; head -c 2000000 /dev/zero > "$WORK/cachey/c.bin"
python3 - "$WORK" "$DATA" <<'PY'
import json, sys
h, data = sys.argv[1], sys.argv[2]
def ws(name, safety, dirty, art):
    p = f"{h}/{name}"
    return {"id": "ws:" + p, "kind": "workspace", "name": name, "path": p, "repoPath": f"{h}/repo", "repoName": "repo", "branch": name, "sources": ["Git"], "exists": True,
            "measured": True, "size": 3000000 if art else 4000, "artifacts": [{"path": p + "/node_modules", "bytes": 3000000}] if art else [], "verdict": {"deprecated": {}},
            "safety": safety, "reasons": ["test"], "note": "", "lastActivity": "2026-10-01T00:00:00Z",
            "git": {"dirtyCount": dirty, "ahead": 0, "hasUpstream": False, "merged": dirty == 0, "defaultBranch": "main", "unpushed": 0, "aheadOfBase": 0, "behindBase": 0, "unpushedAfterMerge": 0}}
entries = [ws("ws-safe", 0, 0, True), ws("ws-dirty", 1, 3, False), ws("ws-danger", 2, 1, False),
           {"id": "repo", "kind": "repo", "name": "repo", "path": f"{h}/repo", "repoPath": f"{h}/repo", "repoName": "repo", "sources": ["Git"], "exists": True, "measured": True,
            "size": 0, "artifacts": [], "verdict": {"active": {}}, "safety": 0, "reasons": [], "note": ""},
           {"id": "cache:cachey", "kind": "cache", "name": "cachey", "path": f"{h}/cachey", "repoName": "", "sources": ["Dev tools"], "exists": True, "measured": True,
            "size": 2000000, "artifacts": [], "verdict": {"deprecated": {}}, "safety": 0, "reasons": ["Rebuilt on demand"], "note": "A test cache"}]
json.dump(entries, open(data + "/scan.json", "w"))
PY
cd "$WORK"

# Reading
check "help lists commands"            '"$K" help | grep -q "remove"'
check "unknown command exits 2"        '[ "$(code "$K" bogus)" = 2 ]'
check "unknown flag exits 2"           '[ "$(code "$K" workspaces --bad)" = 2 ]'
check "workspaces --json is JSON"      '"$K" workspaces --all --json | python3 -c "import sys,json; assert len(json.load(sys.stdin)) == 4"'
check "workspace shows the reason"     '"$K" workspace ws-dirty | grep -q "uncommitted"'
check "ambiguous/missing name fails"   '[ "$(code "$K" workspace nope)" = 1 ]'

# Dry runs change nothing
"$K" remove --all-safe >/dev/null 2>&1
check "dry run removes nothing"        '[ -d "$WORK/ws-safe" ] && [ -d "$WORK/ws-dirty" ]'

# Guards
check "main checkout is refused"       '[ "$(code "$K" remove repo --yes)" = 1 ] && [ -d "$WORK/repo" ]'
check "danger needs --danger"          '[ "$(code "$K" remove ws-danger --yes --permanent)" = 1 ] && [ -d "$WORK/ws-danger" ]'
check "disk clean refuses unknown"     '[ "$(code "$K" disk clean "$HOME/Documents" --yes)" = 1 ]'
check "agents stop refuses non-agents" '[ "$(code "$K" agents stop 1 --yes)" = 1 ]'

# Cleaning
"$K" clean ws-safe --yes --permanent >/dev/null 2>&1
check "clean removes build folders"    '[ ! -e "$WORK/ws-safe/node_modules" ] && [ -f "$WORK/ws-safe/a.txt" ]'

# Snapshot, remove, restore
"$K" remove ws-dirty --yes --permanent >/dev/null 2>&1
check "unsaved work is snapshotted"    '"$K" vault --json | python3 -c "import sys,json; v=json.load(sys.stdin); assert len(v) == 1 and v[0][\"has_changes\"] and v[0][\"has_untracked\"]"'
check "workspace was removed"          '[ ! -d "$WORK/ws-dirty" ]'
"$K" vault restore "$(date +%Y)" >/dev/null 2>&1
check "restore brings back changes"    '[ "$(tail -1 "$WORK/ws-dirty/a.txt")" = changed ] && [ "$(cat "$WORK/ws-dirty/notes.txt")" = secret ]'
check "restore keeps binary bytes"     '[ "$(wc -c < "$WORK/ws-dirty/blob.dat" | tr -d " ")" = 4000 ]'

# Leftovers and config
"$K" leftovers clean --all --yes --permanent >/dev/null 2>&1
check "leftover cache is emptied"      '[ -z "$(ls -A "$WORK/cachey")" ]'
"$K" config set stale-days 21 >/dev/null 2>&1
check "config round-trips"             '[ "$("$K" config get stale-days)" = 21 ]'
"$K" config set stale-days 14 >/dev/null 2>&1
check "bad config value fails"         '[ "$(code "$K" config set stale-days abc)" = 2 ]'
check "completions parse"              '"$K" completions bash | bash -n && "$K" completions zsh | zsh -n'

echo "keeper CLI: $pass passed, $fail failed"
[ "$fail" = 0 ]
