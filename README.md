# AI Keeper

A macOS app that shows where your disk space and AI-agent spend are going, and cleans up safely.
It manages the worktrees that coding agents leave behind, watches running agents, and explains what is using your Mac.

Built with SwiftUI and Swift Package Manager. macOS 14 or later.

## What it does

- **Workspaces.** Finds git worktrees created by Claude Code, Conductor, Codex and Superset, plus plain git worktrees.
  Each one gets a "still needed?" verdict from git state and pull request status (via the GitHub CLI).
- **Cleanup.** Removes deprecated workspaces and rebuildable build folders (`target`, `node_modules`, …).
  Runs as a background job queue, takes a recovery snapshot of unsaved work first, and never touches a folder an agent is using.
- **Disk.** A whole-disk map that explains the biggest items in plain language, a drill-down analyzer, duplicate merging
  with APFS clones, and Docker/OrbStack prune. Results are cached and only re-measured when you press Refresh.
- **Agents and usage.** Running agents with live state ("needs you"), token and cost tracking for Claude, Codex and Pi,
  budgets, and a searchable session history.
- **System.** Health score, CPU, memory, swap, disk I/O, battery and network, sampled only while the page is open.
- **Agent access.** A `keeper` command for everything the app does, and an MCP server so agents can check disk space and clean their own build folders.

## Install

**Homebrew** 7 or later (also puts `keeper` on your PATH):

```bash
brew tap chungquantin/ai-keeper https://github.com/chungquantin/ai-keeper
brew trust --tap chungquantin/ai-keeper   # Homebrew asks you to trust non-official taps once
brew install --cask ai-keeper
```

**Download** the zip from [the website](https://chungquantin.github.io/ai-keeper/) or [Releases](https://github.com/chungquantin/ai-keeper/releases/latest) and drag AI Keeper to Applications.
Releases are not notarized yet, so macOS warns when you open a zip downloaded in a browser. Either open System Settings, Privacy & Security and click **Open Anyway**, or install from Terminal, which is never quarantined:

```bash
curl -fsSL https://chungquantin.github.io/ai-keeper/install.sh | bash
```

Homebrew installs skip the warning too.

Landing page: https://chungquantin.github.io/ai-keeper/

## Build

```bash
swift build                 # debug build
./scripts/bundle.sh         # release build into dist/AIKeeper.app
./scripts/install.sh        # build and install to /Applications
```

## Command line: `keeper`

Run `keeper` in a terminal to open the **interactive dashboard**: arrow keys to move, space to select, enter to open, esc to go back, and the keys for each screen on the bottom line. Pick workspaces with the evidence beside them (git state, pull request, what a cleanup frees), confirm, and watch a live progress bar. It also has live Agents and System screens, spend charts, the disk map with a folder explorer, and the vault. `keeper ui --snapshot <screen>` prints a single frame for docs and tests.

Everything the app does is also a plain command for scripts and agents. Every command takes `--json`, and anything that deletes is a **dry run until you add `--yes`**. It never opens the window.

```bash
keeper status                              # disk, what you can get back, agents, spend
keeper scan                                # re-measure workspaces, git state and pull requests
keeper workspaces --deprecated             # what is no longer needed, biggest first
keeper workspace feat-search-index         # why it is flagged: git, PR, build folders
keeper remove --all-safe                   # preview; add --yes to move them to the Trash
keeper clean --all --yes                   # delete build folders, keep the workspaces
keeper usage --days 7 --by model           # AI spend; `keeper usage budget --daily 40`
keeper agents                              # running agents; `keeper agents stop <pid> --yes`
keeper sessions --search "billing"         # past sessions; `keeper sessions resume <id>`
keeper disk                                # where the space went; `disk explore`, `disk large`
keeper system                              # CPU, memory, disk, network, heaviest apps
keeper vault restore <id>                  # bring back a removed workspace's unsaved work
keeper dedupe --merge --yes                # replace duplicate files with APFS clones
keeper docker prune all-safe --yes         # build cache, unused images, stopped containers
keeper tools                               # which agent tools are detected and enabled
```

| Section in the app | Command |
|---|---|
| Overview | `status`, `scan` |
| All workspaces, Deprecated, By tool, inspector | `workspaces`, `workspace`, `remove`, `clean` |
| Leftovers, Duplicates, Containers | `leftovers`, `dedupe`, `docker` |
| Agents, Sessions, AI Usage | `agents`, `sessions`, `usage` |
| Disk Analyzer, System | `disk`, `system` |
| Recently removed | `vault` |
| Tools, Settings | `tools`, `config` |

`keeper help <command>` shows every option. Shell completions: `keeper completions zsh|bash|fish`. Exit codes: 0 done, 1 failed or everything you named was skipped, 2 wrong usage.

The same safety rules as the app apply: unsaved work is saved to the vault first, workspaces with a running agent are skipped, main checkouts are never removed, and files go to the Trash unless you pass `--permanent`.

### For agents

```bash
claude mcp add keeper -- ~/.local/bin/keeper mcp
```

Homebrew installs `keeper` (and `aikeeper`, the old name, as an alias). Installed the app by hand? Run `keeper install`, or use Settings → Agent access. `./scripts/test-cli.sh` runs the CLI end to end against a throwaway repo.

## Safety

- Workspaces with uncommitted changes are never marked safe to remove.
- Main checkouts are never removed, only their build folders are cleaned.
- Deletion defaults to the Trash for workspaces; build folders are deleted directly because they are regenerated.
- A cleanup will not start in a folder where an agent is running.

## Layout

```
Sources/AIKeeper   the app (scanner, cleanup engine, monitors, SwiftUI views)
assets/            app icon and the Swift script that draws it
scripts/           bundle, package (universal, signed zip), install, cask update
Casks/             Homebrew cask (this repo is its own tap)
site/              landing page, deployed to GitHub Pages
.github/workflows/ CI, release on tag, Pages deploy
```

## Releasing

Push a tag: `git tag v0.2.0 && git push origin v0.2.0`. The release workflow builds a universal app, publishes
`AI-Keeper-<version>.zip` with its checksum to GitHub Releases, and updates the cask.

Releases are ad-hoc signed until Developer ID credentials are added. To sign and notarize them (so Gatekeeper accepts a
download without the Open Anyway step), follow [docs/SIGNING.md](docs/SIGNING.md), which ends with one script,
`scripts/setup-signing.sh`, that stores the credentials as repository secrets.

## Notes

- Costs are estimates at public API list prices from local session logs.
- Several `--probe`-style flags in `App.swift` exist for checking the scanners from the command line.
