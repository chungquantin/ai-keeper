# The `keeper` command

Run `keeper` in a terminal to open the **interactive dashboard**: arrow keys to move, space to select, enter to open, esc to go back, and the keys for each screen on the bottom line. Pick workspaces with the evidence beside them (git state, pull request, what a cleanup frees), confirm, and watch a live progress bar. It also has live Agents and System screens, spend charts, the disk map with a folder explorer, and the vault. `keeper ui --snapshot <screen>` prints a single frame for docs and tests.

Everything the app does is also a plain command for scripts and agents. Every command takes `--json`, and anything that deletes is a **dry run until you add `--yes`**. It never opens the window.

```bash
keeper status                              # disk, what you can get back, agents, spend
keeper history                             # how often you cleaned up, total space freed, streaks
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
keeper skills                              # every installed skill; `skills scan --all`, `skills show <name>`
keeper skills remove --risk danger         # preview; --yes quarantines them, `skills restore <name>` undoes it
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
| Skills | `skills` |
| Tools, Settings | `tools`, `config` |

`keeper help <command>` shows every option. Shell completions: `keeper completions zsh|bash|fish`. Exit codes: 0 done, 1 failed or everything you named was skipped, 2 wrong usage.

The same safety rules as the app apply: unsaved work is saved to the vault first, workspaces with a running agent are skipped, main checkouts are never removed, and files go to the Trash unless you pass `--permanent`.

## Skills and SkillSpector

Skills run with your agent's trust, and plenty of them ship scripts. The **Skills** page (and `keeper skills`) lists every skill your agents can load and scans them with NVIDIA's open-source [SkillSpector](https://github.com/NVIDIA/SkillSpector) (Apache-2.0). Each finding comes with the lines it points at, because a scanner reads a security denylist as an attack as readily as an attack: findings are heuristics, not verdicts.

- AI Keeper does not bundle SkillSpector. `keeper skills scanner install --yes` (or the button) installs the reviewed release `v2.13.4` with `uv`, after showing you the exact command.
- Scans are static (`--no-llm`): nothing in a skill goes to a language model. SkillSpector does check the dependencies a skill lists against [OSV.dev](https://osv.dev), so those package names and versions leave your Mac.
- The scanner runs with a bare environment (no API keys), on the skill's real folder (it refuses symlinks), and results are cached until a skill's files change. `keeper skills scan` exits 1 if any skill is rated do-not-install, so it can gate a script. A full scan batches eight skills per process, stops cleanly on Ctrl-C (or Esc in the dashboard) keeping what finished, and drops to one at a time when the Mac is short of memory.
- **Removing skills.** `keeper skills remove --risk danger` (dry run) lists every skill rated do-not-install; add `--yes` to take them out of use. In the dashboard, `space` selects, `a` selects every high-risk skill and `x` removes; in the app, "Select high risk" then "Remove…". Skills are moved to a **quarantine**, not deleted, and the symlinks other tools use are recorded, so `keeper skills restore <name>` (or `u` in the dashboard, "Removed" in the app) puts everything back exactly. Findings are heuristics, so check them first. Plugin and project skills are never touched: uninstall the plugin, or delete the folder in its repository.

## For agents

```bash
claude mcp add keeper -- ~/.local/bin/keeper mcp
```

Homebrew installs `keeper` (and `aikeeper`, the old name, as an alias). Installed the app by hand? Run `keeper install`, or use Settings → Agent access. `./scripts/test-cli.sh` runs the CLI end to end against a throwaway repo.
