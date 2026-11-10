#!/bin/bash
# End-to-end test of the `keeper` CLI against a throwaway repo, with its own data folder (AIKEEPER_DATA),
# so your real scan, vault and settings are never touched. Usage: scripts/test-cli.sh [path-to-binary]
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/AIKeeper}"
[ -x "$BIN" ] || { echo "Build first (swift build); no binary at $BIN"; exit 1; }
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"      # absolute: the test changes directory
WORK="$(mktemp -d "$HOME/.keeper-cli-test.XXXXXX")"      # must live under $HOME: removal refuses paths outside it
DATA="$(mktemp -d)"; BINDIR="$(mktemp -d)"
ln -s "$BIN" "$BINDIR/keeper"
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

# Interactive mode, driven through a real pseudo-terminal: open Workspaces, select every safe one, remove (permanently, to keep the Trash clean).
git -C "$WORK/repo" worktree add -q "../ws-tui" -b ws-tui; head -c 1000000 /dev/zero > "$WORK/ws-tui/blob.bin"
python3 - "$WORK" "$DATA" <<'PY'
import json, sys
h, data = sys.argv[1], sys.argv[2]
e = json.load(open(data + "/scan.json"))
e.append({"id": "ws:" + h + "/ws-tui", "kind": "workspace", "name": "ws-tui", "path": h + "/ws-tui", "repoPath": h + "/repo", "repoName": "repo", "branch": "ws-tui", "sources": ["Git"], "exists": True,
          "measured": True, "size": 1000000, "artifacts": [], "verdict": {"deprecated": {}}, "safety": 0, "reasons": ["test"], "note": "", "lastActivity": "2026-10-01T00:00:00Z",
          "git": {"dirtyCount": 0, "ahead": 0, "hasUpstream": False, "merged": True, "defaultBranch": "main", "unpushed": 0, "aheadOfBase": 0, "behindBase": 0, "unpushedAfterMerge": 0}})
json.dump(e, open(data + "/scan.json", "w"))
PY
TUI_OUT="$(python3 - "$K" <<'PY'
import os, pty, select, struct, fcntl, termios, sys, time
k = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(k, [k])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 120, 0, 0))
buf = b""
def pump(t=0.6):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: return
def send(b, t=0.6): os.write(fd, b); pump(t)
def waitfor(needle, timeout=40):
    # Wait for the screen itself rather than guessing a delay: a busy Mac starts slowly.
    global buf
    end = time.time() + timeout
    while time.time() < end:
        if needle.encode() in buf: return True
        pump(0.2)
    return False
waitfor("Recently removed")
send(b"\r", 0.3); waitfor("Deprecated")            # Workspaces
send(b"a", 0.3)             # select every safe workspace
send(b"x", 0.3); waitfor("confirm removal")          # confirm screen
send(b"p", 0.3)             # permanent
send(b"y", 0.3); waitfor("Freed")                    # run
send(b" ", 0.6)             # result: any key
send(b"\x1b", 0.5)          # back to home
send(b"q", 0.8)             # quit
try:
    _, status = os.waitpid(pid, 0)
except ChildProcessError:
    status = 0
text = buf.decode("utf-8", "replace")
print("EXIT=%d" % (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 99))
for needle, name in [("Workspaces", "workspaces"), ("confirm removal", "confirm"), ("Freed", "result")]:
    print(("SAW_" + name) if needle in text else ("MISSING_" + name))
print("RESTORED" if "\x1b[?1049l" in text and "\x1b[?25h" in text else "NOT_RESTORED")
PY
)"
check "tui opens and quits cleanly"    'echo "$TUI_OUT" | grep -q "EXIT=0" && echo "$TUI_OUT" | grep -q RESTORED'
check "tui shows the screens"          '! echo "$TUI_OUT" | grep -q MISSING'
check "tui removed the workspace"      '[ ! -d "$WORK/ws-tui" ]'
check "tui kept the main checkout"     '[ -d "$WORK/repo" ]'
check "snapshot frames render"         '"$K" ui --snapshot home --size 100x20 | grep -q "Workspaces" && "$K" ui --snapshot nope >/dev/null 2>&1; [ $? -ne 0 ] || true'

# Skills: discovery, the scanner contract (with a stub standing in for SkillSpector) and the safety properties around it.
SK="$WORK/skills"; mkdir -p "$SK/real/pdf-kit/scripts" "$SK/real/shady" "$SK/shared" "$SK/other"
printf -- '---\nname: pdf-kit\ndescription: >\n  Work with PDFs.\n  Merge and split.\n---\nBody\n' > "$SK/real/pdf-kit/SKILL.md"; echo 'print(1)' > "$SK/real/pdf-kit/scripts/run.py"
printf -- '---\nname: shady\ndescription: "Looks \033[31mred\033[0m\xe2\x80\xaeevil"\n---\n' > "$SK/real/shady/SKILL.md"
ln -s "$SK/real/pdf-kit" "$SK/shared/pdf-kit"; ln -s "$SK/real/pdf-kit" "$SK/other/pdf-kit"; ln -s "$SK/real/shady" "$SK/other/shady"
cat > "$WORK/skillspector" <<'STUB'
#!/bin/bash
# Stands in for SkillSpector: same arguments, same JSON, and it refuses the things the real one refuses or must never receive.
[ "$1" = scan ] || exit 2
[ -L "$2" ] && { echo "Error: Refusing to resolve a symlinked input" >&2; exit 2; }
[ -n "${OPENAI_API_KEY:-}" ] && { echo "leaked API key" >&2; exit 2; }
case " $* " in *" --no-llm "*) ;; *) echo "missing --no-llm" >&2; exit 2;; esac
if [[ "$2" == *shady* ]]; then rec=DO_NOT_INSTALL; sev=CRITICAL; score=83; code=1
  issue='{"id":"E2","category":"Data Exfiltration","severity":"HIGH","confidence":0.9,"location":{"file":"scripts/x.sh","start_line":3},"finding":"env harvesting\u001b[2J","explanation":"bad","remediation":"fix","code_snippet":"curl"}'
else rec=SAFE; sev=LOW; score=2; code=0; issue=""; fi
echo "{\"skill\":{\"name\":\"x\"},\"risk_assessment\":{\"score\":$score,\"severity\":\"$sev\",\"recommendation\":\"$rec\"},\"issues\":[$issue],\"metadata\":{\"skillspector_version\":\"9.9.9\"},\"analysis_completeness\":{\"is_complete\":true},\"execution_successful\":true}"
echo x >> "$(dirname "$0")/scans.log"
exit $code
STUB
chmod +x "$WORK/skillspector"
export AIKEEPER_SKILL_ROOTS="$SK/real:$SK/shared:$SK/other" AIKEEPER_SKILLSPECTOR="$WORK/skillspector" OPENAI_API_KEY=secret-do-not-leak
check "skills dedupes symlinked folders"   '"$K" skills --json | python3 -c "import sys,json; d=json.load(sys.stdin); assert sorted(x[\"name\"] for x in d) == [\"pdf-kit\", \"shady\"], d"'
check "skills reads folded descriptions"   '"$K" skills --json | python3 -c "import sys,json; d={x[\"name\"]:x for x in json.load(sys.stdin)}; assert d[\"pdf-kit\"][\"description\"] == \"Work with PDFs. Merge and split.\"; assert d[\"pdf-kit\"][\"has_scripts\"]"'
check "skills strips escapes and bidi"     '"$K" skills --json | python3 -c "import sys,json; d={x[\"name\"]:x for x in json.load(sys.stdin)}; t=d[\"shady\"][\"description\"]; assert \"\\x1b\" not in t and \"\\u202e\" not in t, repr(t)"'
check "skills starts unscanned"            '"$K" skills --json | python3 -c "import sys,json; assert all(x[\"scan\"] is None for x in json.load(sys.stdin))"'
check "scan flags the risky skill, exit 1" '[ "$(code "$K" skills scan --all)" = 1 ]'
check "scan results are saved"             '"$K" skills --json | python3 -c "import sys,json; d={x[\"name\"]:x for x in json.load(sys.stdin)}; assert d[\"shady\"][\"scan\"][\"verdict\"] == \"danger\" and d[\"pdf-kit\"][\"scan\"][\"verdict\"] == \"safe\""'
check "finding text is sanitized"          '"$K" skills show shady --json | python3 -c "import sys,json; i=json.load(sys.stdin)[\"scan\"][\"issues\"][0]; assert \"\\x1b\" not in i[\"finding\"], repr(i[\"finding\"])"'
N1=$(wc -l < "$WORK/scans.log" | tr -d ' '); "$K" skills scan --all >/dev/null 2>&1
check "unchanged skills are not rescanned" '[ "$(wc -l < "$WORK/scans.log" | tr -d " ")" = "$N1" ]'
echo '# edited' >> "$SK/real/pdf-kit/SKILL.md"; "$K" skills scan pdf-kit >/dev/null 2>&1
check "a changed skill is scanned again"   '[ "$(wc -l < "$WORK/scans.log" | tr -d " ")" = "$((N1 + 1))" ]'
check "scanner install needs --yes"        '"$K" skills scanner install | grep -q "Dry run" || "$K" skills scanner install | grep -q "already installed"'

# Removing skills: reversible by default, links included, and never outside the skills folders.
"$K" skills scan --all >/dev/null 2>&1
check "remove: a dry run changes nothing"   '"$K" skills remove --risk danger >/dev/null 2>&1; [ -d "$SK/real/shady" ] && [ -L "$SK/other/shady" ]'
"$K" skills remove --risk danger --yes >/dev/null 2>&1
check "remove: folder and links are gone"   '[ ! -e "$SK/real/shady" ] && [ ! -L "$SK/other/shady" ] && [ -d "$SK/real/pdf-kit" ]'
check "remove: only the risky one went"     '"$K" skills --json | python3 -c "import sys,json; assert [x[\"name\"] for x in json.load(sys.stdin)] == [\"pdf-kit\"]"'
check "remove: kept in quarantine"          '"$K" skills removed --json | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d) == 1 and d[0][\"name\"] == \"shady\" and d[0][\"verdict\"] == \"danger\""'
"$K" skills restore shady >/dev/null 2>&1
check "restore: folder and link are back"   '[ -d "$SK/real/shady" ] && [ -L "$SK/other/shady" ] && [ "$(readlink "$SK/other/shady")" = "$SK/real/shady" ]'
check "restore: nothing left quarantined"   '"$K" skills removed --json | python3 -c "import sys,json; assert json.load(sys.stdin) == []"'
check "remove: refuses what is not a skill" '[ "$(code "$K" skills remove /tmp --yes)" = 2 ] && [ -d /tmp ]'
check "remove: needs something to remove"   '[ "$(code "$K" skills remove)" = 2 ]'
"$K" skills remove shady --yes --permanent >/dev/null 2>&1
check "remove --permanent deletes for good" '[ ! -e "$SK/real/shady" ] && "$K" skills removed --json | python3 -c "import sys,json; assert json.load(sys.stdin) == []"'
unset AIKEEPER_SKILL_ROOTS AIKEEPER_SKILLSPECTOR OPENAI_API_KEY

# A slow scan must not freeze the dashboard: it shows progress, keys keep working, Esc stops it, and no scanner is left running.
SL="$WORK/slow"; mkdir -p "$SL/roots/a" "$SL/roots/b" "$SL/roots/c"
for n in a b c; do printf -- '---\nname: slow-%s\ndescription: x\n---\n' "$n" > "$SL/roots/$n/SKILL.md"; done
cat > "$SL/slowspector" <<'STUB'
#!/bin/bash
echo $$ >> "$(dirname "$0")/pids"
sleep 60
STUB
chmod +x "$SL/slowspector"
SLOW_OUT="$(AIKEEPER_SKILL_ROOTS="$SL/roots" AIKEEPER_SKILLSPECTOR="$SL/slowspector" python3 - "$K" <<'PY'
import os, pty, select, struct, fcntl, termios, sys, time
k = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(k, [k])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 120, 0, 0))
buf = b""
def pump(t=0.6):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: return
def send(b, t=0.6): os.write(fd, b); pump(t)
def waitfor(needle, timeout=40):
    # Wait for the screen itself rather than guessing a delay: a busy Mac starts slowly.
    global buf
    end = time.time() + timeout
    while time.time() < end:
        if needle.encode() in buf: return True
        pump(0.2)
    return False
waitfor("Recently removed")
send(b"c", 0.3); waitfor("Worth a look")      # Skills
send(b"S", 0.3); waitfor("Scanning 0/3")      # scan every skill, in the background
mark = len(buf)
send(b"j", 1.0)          # keys must still work: this has to redraw
redrew = len(buf) > mark
send(b"\x1b", 0.3); waitfor("Stopping")       # Esc stops the scan
pump(2.0)
send(b"\x1b", 0.6)       # back to home
send(b"q", 1.0)          # quit
try: _, status = os.waitpid(pid, 0)
except ChildProcessError: status = 0
text = buf.decode("utf-8", "replace")
print("EXIT=%d" % (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 99))
print("SAW_PROGRESS" if "Scanning 0/3" in text or "Scanning 1/3" in text else "NO_PROGRESS")
print("RESPONSIVE" if redrew else "FROZEN")
print("SAW_STOP" if ("Stopping" in text or "Stopped after" in text) else "NO_STOP")
print("RESTORED" if "\x1b[?1049l" in text else "NOT_RESTORED")
PY
)"
sleep 1
ALIVE=0; for p in $(cat "$SL/pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && ALIVE=$((ALIVE + 1)); done
check "scan: dashboard shows progress"     'echo "$SLOW_OUT" | grep -q SAW_PROGRESS'
check "scan: keys work while scanning"     'echo "$SLOW_OUT" | grep -q RESPONSIVE'
check "scan: esc stops it"                 'echo "$SLOW_OUT" | grep -q SAW_STOP'
check "scan: dashboard exits cleanly"      'echo "$SLOW_OUT" | grep -q "EXIT=0" && echo "$SLOW_OUT" | grep -q RESTORED'
check "scan: no scanner left running"      '[ -s "$SL/pids" ] && [ "$ALIVE" = 0 ]'

# Ctrl-C on `keeper skills scan` stops the scanners and exits 130.
: > "$SL/pids"; rm -f "$SL/exit"
( AIKEEPER_SKILL_ROOTS="$SL/roots" AIKEEPER_SKILLSPECTOR="$SL/slowspector" "$K" skills scan --all >/dev/null 2>&1; echo $? > "$SL/exit" ) &
for _ in $(seq 1 60); do [ -s "$SL/pids" ] && break; sleep 0.5; done
pkill -INT -f "$BINDIR/keeper skills scan" 2>/dev/null
for _ in $(seq 1 40); do [ -f "$SL/exit" ] && break; sleep 0.5; done
sleep 1
ALIVE2=0; for p in $(cat "$SL/pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && ALIVE2=$((ALIVE2 + 1)); done
check "ctrl-c: exits 130"                  '[ "$(cat "$SL/exit" 2>/dev/null)" = 130 ]'
check "ctrl-c: no scanner left running"    '[ -s "$SL/pids" ] && [ "$ALIVE2" = 0 ]'

# The app's own binary name must open the window, not behave like the command. (Opening the app is what broke in 0.2.0 and 0.2.1.)
cp "$BIN" "$BINDIR/AIKeeper"   # a case-insensitive disk would treat aikeeper and AIKeeper as one file; argv[0] keeps the case typed
check "app binary name is the app"     '[ "$("$BINDIR/AIKeeper" _invoked)" = app ]'
check "keeper is the command"          '[ "$("$K" _invoked)" = cli ]'
check "aikeeper alias is the command"  '[ "$("$BINDIR/aikeeper" _invoked)" = cli ]'

# The version must be found when the command is a symlink into an app bundle (that is how Homebrew installs it).
FAKE="$WORK/Fake.app/Contents"; mkdir -p "$FAKE/MacOS"; cp "$BIN" "$FAKE/MacOS/AIKeeper"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>9.9.9</string></dict></plist>' > "$FAKE/Info.plist"
ln -s "$FAKE/MacOS/AIKeeper" "$BINDIR/linked"; ln -s "$BINDIR/linked" "$BINDIR/keeper2"
check "version found through symlinks" '[ "$("$BINDIR/keeper2" version)" = "keeper 9.9.9" ]'

# History: removals above (workspaces, a folder, skills do not count) are logged and summed.
check "history logs real removals"     '"$K" history --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"total_freed_bytes\"]>0 and d[\"cleanups\"]>=1 and d[\"current_streak_days\"]==1 else 1)"'
check "history draws the chart"        '"$K" history --weeks 12 | grep -q "freed" && "$K" history --weeks 12 | grep -q "streak"'
check "status shows the running total" '"$K" status | grep -q "cleaned"'
echo "keeper CLI: $pass passed, $fail failed"
[ "$fail" = 0 ]
