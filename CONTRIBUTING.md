# Contributing to AI Keeper

Thanks for helping. Bug reports, tool support, documentation and code are all welcome.

## Before you start

- **Found a bug?** Search the [issues](https://github.com/chungquantin/ai-keeper/issues) first, then use the [bug report form](https://github.com/chungquantin/ai-keeper/issues/new?template=bug_report.yml). Say which version you run: `keeper version`, or the app's About box.
- **Want a feature or a new tool supported?** Use the [feature request form](https://github.com/chungquantin/ai-keeper/issues/new?template=feature_request.yml). For a new agent tool, tell us where it keeps its worktrees, sessions and logs.
- **Planning a larger change?** Open an issue first so we can agree on the approach before you spend time on it.
- Please read the [Code of Conduct](CODE_OF_CONDUCT.md). It includes how we treat AI-assisted contributions.

## Set up

You need macOS 14 or later and Swift 5.9 or later (Xcode or the command line tools). There are no other dependencies.

```bash
git clone https://github.com/chungquantin/ai-keeper
cd ai-keeper
swift build                    # debug build
.build/debug/AIKeeper          # run the app (use "keeper" commands through a symlink named keeper)
```

Useful while developing:

- `AIKEEPER_DEMO=1` shows invented data instead of scanning your Mac, and `AIKEEPER_DATA=<folder>` keeps caches and the vault out of your real ones.
- `AIKEEPER_NOSPLASH=1` skips the loading screen.
- `.build/debug/AIKeeper ui --snapshot home --size 100x24` prints one frame of the terminal dashboard.

## Tests

```bash
./scripts/test-cli.sh          # the keeper command end to end, against a throwaway repo
./scripts/test-launch.sh       # builds the app and checks that it opens and stays running
```

If you change behaviour, add a check to `scripts/test-cli.sh`. A change that deletes, moves or restores files must be covered by one.

## Safety comes first

AI Keeper deletes things, so these rules are not negotiable and a change must not weaken them:

- Anything that deletes is a preview until the user confirms (`--yes` in the CLI, a confirmation in the app).
- Unsaved work (uncommitted files, unpushed commits) is saved to the vault before a workspace is removed.
- A workspace with a running agent is skipped. Main checkouts are never removed.
- Paths are validated before anything is removed (a removal refuses a path outside your home folder), and the skills scanner refuses symlinks.
- The app makes no network requests of its own.

## Pull requests

- Keep a pull request to one change. Describe what it does and why, and how you tested it. The template has the rest.
- Match the style of the surrounding code. Names should say what a thing is, and comments should say why, not what.
- Use [conventional commit](https://www.conventionalcommits.org) messages (`feat:`, `fix:`, `chore:`, and a scope such as `feat(cli):`), as the history does.
- Do not commit build output or `dist/`. Generated files have a script: tool logos (`scripts/gen-tool-logos.py`), the app icon (`assets/icon.swift`), the landing page's terminal frames (`scripts/site-terminal.sh`) and the launch film (`scripts/make-launch-video.sh`).
- Fonts, logos and other assets must be open-licensed or the owner's own mark, and are listed in [THIRD_PARTY.md](THIRD_PARTY.md).

## Releases

Maintainers cut releases by pushing a `v*` tag. See the Releasing section of the [README](README.md).
