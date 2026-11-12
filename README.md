<p align="center">
  <img src="site/logo-robot.svg" alt="AI Keeper" width="96" height="96">
</p>

<h1 align="center">AI Keeper</h1>

<p align="center"><b>Clean up after your coding agents.</b></p>

https://github.com/user-attachments/assets/de70d3b0-d4b6-49fe-9f42-064d94749875

**AI Keeper** is a free and open source Mac app and command line tool. It finds the worktrees, build folders and caches that
Claude Code, Codex, Conductor and other coding agents leave on your Mac, shows which of them are safe to delete and why, and clears
them in the background. It also watches running agents, tracks what they cost, and checks the skills they load for risky scripts.

Everything runs on your Mac. There is no account, and the app makes no network requests of its own.

> [!TIP]
> **Questions or ideas?** Open an [issue](https://github.com/chungquantin/ai-keeper/issues/new/choose) and pick the form that fits.
> The [website](https://chungquantin.github.io/ai-keeper/) has a short tour, and [the command reference](docs/CLI.md) covers the terminal.

## Download

[![Download](https://img.shields.io/github/v/release/chungquantin/ai-keeper?style=for-the-badge&logo=github&label=Download)](https://github.com/chungquantin/ai-keeper/releases/latest)&nbsp;&nbsp;
[![Homebrew](https://img.shields.io/badge/Homebrew-cask-fbb040?style=for-the-badge&logo=homebrew&logoColor=white)](#install)

Needs **macOS 14 or later**. The app is a universal binary, so it runs on Apple Silicon and Intel.

> [!NOTE]
> Releases are not notarized yet, because that needs a paid Apple Developer ID. macOS therefore warns about a zip downloaded in a browser.
> Open **System Settings, Privacy & Security** and click **Open Anyway**, or clear the quarantine flag:
> `xattr -dr com.apple.quarantine "/Applications/AI Keeper.app"`. Homebrew and the install script skip the warning.

## Install

**Homebrew** (also puts `keeper` on your PATH):

```bash
brew tap chungquantin/ai-keeper https://github.com/chungquantin/ai-keeper
brew trust --tap chungquantin/ai-keeper   # Homebrew asks you to trust a non-official tap once
brew install --cask ai-keeper
```

**Install script**, which is never quarantined:

```bash
curl -fsSL https://chungquantin.github.io/ai-keeper/install.sh | bash
```

**Zip.** Download `AI-Keeper-<version>.zip` from [Releases](https://github.com/chungquantin/ai-keeper/releases/latest) and drag the app to Applications.

## Stats

[![CI](https://github.com/chungquantin/ai-keeper/actions/workflows/ci.yml/badge.svg)](https://github.com/chungquantin/ai-keeper/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/chungquantin/ai-keeper?logo=github)](https://github.com/chungquantin/ai-keeper/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/chungquantin/ai-keeper/total?logo=github)](https://github.com/chungquantin/ai-keeper/releases)
[![License](https://img.shields.io/github/license/chungquantin/ai-keeper?logo=github)](LICENSE)
[![Stars](https://img.shields.io/github/stars/chungquantin/ai-keeper?logo=github)](https://github.com/chungquantin/ai-keeper/stargazers)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](Package.swift)

## What it does

- **Workspaces.** Finds git worktrees created by Claude Code, Conductor, Codex and Superset, plus plain git worktrees.
  Each one gets a "still needed?" verdict from its git state and pull request status (through the GitHub CLI).
- **Cleanup.** Removes deprecated workspaces and rebuildable build folders (`target`, `node_modules`, and so on) as a background job queue.
  It saves unsaved work to a recovery vault first and never touches a folder an agent is using. Every cleanup is logged, and a contribution-style chart shows how often you cleaned up and how much you got back.
- **Disk.** A whole-disk map that explains the biggest items in plain language, a drill-down analyzer, duplicate merging with APFS clones, and Docker or OrbStack prune.
- **Agents and usage.** Running agents with live state ("needs you"), token and cost tracking for Claude, Codex and Pi, budgets, and a searchable session history.
- **Skills.** Every skill your agents can load, scanned for prompt injection, data exfiltration and risky scripts with [NVIDIA SkillSpector](https://github.com/NVIDIA/SkillSpector). Risky ones can be moved to a quarantine and restored later.
- **System.** Health score, CPU, memory, swap, disk I/O, battery and network, sampled only while the page is open.
- **Agent access.** A `keeper` command for everything the app does, with an interactive terminal dashboard, and an MCP server so agents can check disk space and clean their own build folders.

### Supported tools

| Tool | What AI Keeper handles |
|---|---|
| Claude Code, Codex | Worktrees, sessions and spend |
| Conductor, Superset | Parallel workspaces and worktrees |
| Pi | Sessions and spend |
| ZCode, Cursor, Goose, Gemini CLI, Aider, OpenCode | Disk use and running agents |

Missing yours? [Request a tool](https://github.com/chungquantin/ai-keeper/issues/new?template=feature_request.yml).

## The command line

```bash
keeper                     # the interactive dashboard
keeper status              # disk, what you can get back, agents, spend
keeper remove --all-safe   # a preview; add --yes to move them to the Trash
keeper skills scan --all   # check every skill your agents can load
keeper history             # how often you cleaned up, and the total freed
```

Anything that deletes is a **dry run until you add `--yes`**, and every command takes `--json` for scripts. See [docs/CLI.md](docs/CLI.md) for all commands, the skills scanner and the MCP server.

## Safety

- Workspaces with uncommitted changes are never marked safe to remove, and unpushed work is saved to the vault first.
- Main checkouts are never removed. Only their build folders are cleaned.
- Workspaces are moved to the Trash by default. Build folders are deleted directly, because they are regenerated.
- A cleanup will not start in a folder where an agent is running.
- Nothing leaves your Mac. The app itself makes no network requests; it runs `git`, and the GitHub CLI if you have it, to read pull request status.
  The optional skills scanner is a separate tool, and it looks up the packages a skill lists on [OSV.dev](https://osv.dev).

## FAQ

### Is it safe to let it delete things?

It shows exactly what will go, and why, before anything is removed. Commands are previews until you add `--yes`, workspaces go to the Trash,
and unsaved work is saved to a vault you can restore from. See [Safety](#safety).

### Why does macOS say the app can't be opened?

The releases are not notarized yet. Use **Open Anyway** in System Settings, or install with Homebrew or the install script. See [Download](#download).

### Do I need the GitHub CLI?

No. Without it you just don't get pull request status beside each workspace. Install `gh` and run `gh auth login` to turn it on.

### Does it work with an agent that isn't listed?

It still finds plain git worktrees. For a new agent's own folders, [open a feature request](https://github.com/chungquantin/ai-keeper/issues/new?template=feature_request.yml) saying where it keeps its data.

### Are the cost numbers exact?

They are estimates at public API list prices, read from your local session logs.

## Similar projects

AI Keeper is built for the mess that coding agents make. These tools cover neighbouring ground, and several are better at their one job:

- [**Kondo**](https://github.com/tbillington/kondo) and [**npkill**](https://github.com/voidcosmos/npkill) clean build folders and `node_modules` in project directories.
- [**DaisyDisk**](https://daisydiskapp.com) is a polished disk-space visualizer for the whole Mac.
- [**Xcode DevCleaner**](https://github.com/vashpan/xcode-dev-cleaner) clears Xcode's derived data, archives and simulators.

## Contribute

There are many ways to help: reporting a bug, asking for a tool to be supported, improving the docs, or sending a pull request.
We're a small and friendly project. Read [CONTRIBUTING.md](CONTRIBUTING.md) to get started, and please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

```bash
swift build                 # debug build
./scripts/test-cli.sh       # the CLI end to end, against a throwaway repo
./scripts/bundle.sh         # release build into dist/AIKeeper.app
```

To report a security problem, follow [SECURITY.md](SECURITY.md).

## Layout

```
Sources/AIKeeper   the app and the keeper command (scanner, cleanup engine, monitors, SwiftUI views, terminal UI)
assets/            app icon, bundled fonts and tool logos, and the scripts that draw them
scripts/           bundle, package (universal, signed zip), install, cask update, tests, the launch film
Casks/             Homebrew cask (this repo is its own tap)
site/              landing page, deployed to GitHub Pages
video/             the 30 second launch film (canvas animation, frame renderer, soundtrack)
docs/              command reference and release signing notes
.github/           CI, release and Pages workflows; issue forms and the pull request template
```

## Releasing

Push a tag: `git tag v0.2.2 && git push origin v0.2.2`. The release workflow builds a universal app, publishes `AI-Keeper-<version>.zip`
with its checksum to GitHub Releases, and updates the cask. Releases are ad-hoc signed until Developer ID credentials are added;
[docs/SIGNING.md](docs/SIGNING.md) explains how to sign and notarize them.

## Contributors

<a href="https://github.com/chungquantin/ai-keeper/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=chungquantin/ai-keeper" alt="AI Keeper contributors">
</a>

## License

AI Keeper is licensed under the [MIT License](LICENSE). It bundles open-licensed fonts, and uses logos that belong to their owners;
see [THIRD_PARTY.md](THIRD_PARTY.md).
