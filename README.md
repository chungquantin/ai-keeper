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
- **Agent access.** `aikeeper` CLI and an MCP server so agents can check disk space and clean their own build folders.

## Install

**Homebrew** (also puts `aikeeper` on your PATH):

```bash
brew tap chungquantin/ai-keeper https://github.com/chungquantin/ai-keeper
brew install --cask ai-keeper
```

**Download** the zip from [Releases](https://github.com/chungquantin/ai-keeper/releases/latest) and drag AI Keeper to Applications.
Releases are not notarized yet, so the first time, right-click the app and choose Open (Homebrew handles this for you).

Landing page: https://chungquantin.github.io/ai-keeper/

## Build

```bash
swift build                 # debug build
./scripts/bundle.sh         # release build into dist/AIKeeper.app
./scripts/install.sh        # build and install to /Applications
```

## Command line and MCP

```bash
aikeeper status
aikeeper workspaces --deprecated
aikeeper clean-artifacts <workspace-path>        # dry run
aikeeper clean-artifacts <workspace-path> --yes
claude mcp add aikeeper -- ~/.local/bin/aikeeper mcp
```

Settings → Agent access installs the command-line tool.

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
`AI-Keeper-<version>.zip` with its checksum to GitHub Releases, and updates the cask. To sign and notarize, add the
repository secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` and
`APPLE_APP_PASSWORD`; without them the app is ad-hoc signed.

## Notes

- Costs are estimates at public API list prices from local session logs.
- Several `--probe`-style flags in `App.swift` exist for checking the scanners from the command line.
