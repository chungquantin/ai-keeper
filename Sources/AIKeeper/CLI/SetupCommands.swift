import Foundation

enum SafetyCommands {
    static var all: [Command] { [vault] }

    static let vault = Command(
        name: "vault", aliases: ["recovery"], group: "Safety nets", summary: "Recently removed workspaces: list, restore, delete, purge",
        usage: ["keeper vault [--json]", "keeper vault restore <id>", "keeper vault delete <id> [--yes]", "keeper vault purge [--days N] [--yes]", "",
                "  Before a workspace with unsaved work is removed, its unpushed commits, changes and untracked files are saved here.",
                "  restore recreates the worktree at the saved commit and re-applies the changes. Ids can be a prefix."],
        valueOptions: ["days"],
        run: { a in
            let items = Vault.list()
            func find(_ p: String?) -> VaultItem? {
                guard let p, !p.isEmpty else { Out.fail("which snapshot? Use an id from `keeper vault`."); return nil }
                let hits = items.filter { $0.id.hasPrefix(p) || $0.name == p }
                if hits.count == 1 { return hits[0] }
                Out.fail(hits.isEmpty ? "no snapshot matches '\(p)'." : "\(hits.count) snapshots match '\(p)'; type more of the id."); return nil
            }
            switch a.positional.first {
            case "restore":
                guard let i = find(a.positional.dropFirst().first) else { return 1 }
                do { try Vault.restore(i); Out.line("Restored \(Term.bold(i.name)) to \(Fmt.tilde(i.path))"); return 0 }
                catch { Out.fail(error.localizedDescription); return 1 }
            case "delete":
                guard let i = find(a.positional.dropFirst().first) else { return 1 }
                guard a.yes else { Out.line("Would permanently delete the snapshot of \(i.name) (\(Fmt.size(i.bytes))).\n" + Term.dim("\nDry run. Add --yes to delete it.")); return 0 }
                Vault.delete(i); Out.line("Deleted the snapshot of \(i.name)."); return 0
            case "purge":
                let days = a.int("days") ?? Int(UserDefaults.standard.number("vault.days", default: 30))
                let old = items.filter { $0.date < Date().addingTimeInterval(-Double(days) * 86_400) }
                guard a.yes else { Out.line("Would delete \(old.count) snapshot\(old.count == 1 ? "" : "s") older than \(days) days (\(Fmt.size(old.reduce(Int64(0)) { $0 + $1.bytes }))).\n" + Term.dim("\nDry run. Add --yes to delete them.")); return 0 }
                Vault.purgeExpired(days: days); Out.line("Deleted \(old.count) snapshot\(old.count == 1 ? "" : "s")."); return 0
            case nil:
                if a.json {
                    Out.json(items.map { ["id": $0.id, "name": $0.name, "path": $0.path, "repo": $0.repoPath, "branch": $0.branch as Any, "saved": Fmt.iso($0.date) as Any, "bytes": $0.bytes,
                                          "has_commits": $0.hasBundle, "has_changes": $0.hasPatch, "has_untracked": $0.hasUntracked, "notes": $0.notes] as [String: Any] }); return 0
                }
                guard !items.isEmpty else { Out.line("Nothing saved. Snapshots appear here after you remove a workspace that had unsaved work."); return 0 }
                Out.line(Out.table(["ID", "SAVED", "SIZE", "HOLDS", "WORKSPACE"],
                                   items.map { [Out.Cell(String($0.id.prefix(15)), Term.dim), Out.Cell(Fmt.ago($0.date), Term.dim), Out.Cell(Fmt.size($0.bytes)),
                                                Out.Cell([$0.hasBundle ? "commits" : nil, $0.hasPatch ? "changes" : nil, $0.hasUntracked ? "untracked" : nil].compactMap { $0 }.joined(separator: ", "), Term.dim),
                                                Out.Cell($0.name)] }, right: [2]))
                Out.line(Term.dim("\nBring one back: keeper vault restore <id>"))
                return 0
            default:
                Out.fail("unknown vault command '\(a.positional[0])'. See `keeper help vault`."); return 2
            }
        })
}

enum SetupCommands {
    static var all: [Command] { [tools, config, install, completions, mcp, cleanArtifacts, demoExport, invoked] }

    static let tools = Command(
        name: "tools", aliases: ["integrations"], group: "Setup", summary: "Which agent tools AI Keeper looks at: detect, enable, disable",
        usage: ["keeper tools [--json]", "keeper tools enable <id>...", "keeper tools disable <id>...", "", "  Ids: " + ToolCatalog.all.map(\.id).joined(separator: ", ")],
        run: { a in
            let ids = ToolCatalog.all.map(\.id)
            if let verb = a.positional.first, ["enable", "disable"].contains(verb) {
                let chosen = Array(a.positional.dropFirst())
                guard !chosen.isEmpty else { Out.fail("which tool? ids: \(ids.joined(separator: ", "))"); return 2 }
                if let bad = chosen.first(where: { !ids.contains($0) }) { Out.fail("unknown tool '\(bad)'. Ids: \(ids.joined(separator: ", "))"); return 2 }
                var on = Set(ToolSettings.storedEnabled ?? ids)
                if verb == "enable" { on.formUnion(chosen) } else { on.subtract(chosen) }
                UserDefaults.standard.set(ids.filter(on.contains), forKey: ToolSettings.enabledKey)
                UserDefaults.standard.set(true, forKey: ToolSettings.onboardedKey)
                Out.line("\(verb == "enable" ? "Enabled" : "Disabled") \(chosen.joined(separator: ", ")). Run `keeper scan` to refresh."); return 0
            }
            let found = Dictionary(ToolCatalog.detect().map { ($0.spec.id, $0) }, uniquingKeysWith: { x, _ in x })
            if a.json {
                Out.json(ToolCatalog.all.map { ["id": $0.id, "name": $0.name, "enabled": ToolSettings.enabled($0.id), "found": found[$0.id]?.found ?? false, "evidence": found[$0.id]?.evidence ?? "",
                                                "capabilities": $0.capabilities] as [String: Any] }); return 0
            }
            Out.line(Out.table(["ON", "TOOL", "ID", "FOUND ON THIS MAC"],
                               ToolCatalog.all.map { t in [Out.Cell(ToolSettings.enabled(t.id) ? "yes" : "no", ToolSettings.enabled(t.id) ? Term.blue : Term.dim), Out.Cell(t.name), Out.Cell(t.id, Term.dim),
                                                           Out.Cell(found[t.id]?.found == true ? (found[t.id]?.evidence ?? "") : "not found", Term.dim)] }))
            return 0
        })

    private static let settings: [(key: String, defaults: String, fallback: Double, detail: String, integer: Bool)] = [
        ("stale-days", "staleDays", 14, "Days without activity before a workspace counts as stale", true),
        ("vault-days", "vault.days", 30, "Days recovery snapshots are kept", true),
        ("floor-gb", "guard.floorGB", 50, "Alert when free space drops below this many GB", false),
        ("budget-daily", "budget.daily", 0, "Daily AI spend limit in USD (0 = off)", false),
        ("budget-weekly", "budget.weekly", 0, "Weekly AI spend limit in USD (0 = off)", false),
    ]

    static let config = Command(
        name: "config", group: "Setup", summary: "Read or change settings (shared with the app)",
        usage: ["keeper config [--json]", "keeper config get <key>", "keeper config set <key> <value>", "",
                "  Keys: " + settings.map(\.key).joined(separator: ", ") + ", notify-agents (true/false)"],
        run: { a in
            let ud = UserDefaults.standard
            func current(_ key: String) -> String? {
                if key == "notify-agents" { return String(ud.object(forKey: "notify.agents") as? Bool ?? true) }
                guard let s = settings.first(where: { $0.key == key }) else { return nil }
                let v = ud.number(s.defaults, default: s.fallback)
                return s.integer ? String(Int(v == 0 && s.key == "stale-days" ? s.fallback : v)) : String(v == v.rounded() ? String(Int(v)) : String(v))
            }
            switch a.positional.first {
            case "get":
                guard let k = a.positional.dropFirst().first, let v = current(k) else { Out.fail("unknown key. Keys: \(settings.map(\.key).joined(separator: ", ")), notify-agents"); return 2 }
                Out.line(v); return 0
            case "set":
                guard a.positional.count >= 3 else { Out.fail("usage: keeper config set <key> <value>"); return 2 }
                let k = a.positional[1], v = a.positional[2]
                if k == "notify-agents" {
                    guard let b = ["true": true, "on": true, "yes": true, "false": false, "off": false, "no": false][v.lowercased()] else { Out.fail("notify-agents takes true or false."); return 2 }
                    ud.set(b, forKey: "notify.agents"); Out.line("notify-agents = \(b)"); return 0
                }
                guard let s = settings.first(where: { $0.key == k }) else { Out.fail("unknown key '\(k)'."); return 2 }
                guard let n = Double(v), n >= 0, !(s.integer && n != n.rounded()) else { Out.fail("\(k) needs a \(s.integer ? "whole " : "")number, 0 or more."); return 2 }
                if s.integer { ud.set(Int(n), forKey: s.defaults) } else { ud.set(n, forKey: s.defaults) }
                Out.line("\(k) = \(current(k) ?? v)"); return 0
            case nil:
                let keys = settings.map(\.key) + ["notify-agents"]
                if a.json { Out.json(Dictionary(uniqueKeysWithValues: keys.map { ($0, current($0) ?? "") })); return 0 }
                Out.line(Out.table(["KEY", "VALUE", "WHAT IT DOES"], keys.map { k in
                    [Out.Cell(k), Out.Cell(current(k) ?? ""), Out.Cell(settings.first { $0.key == k }?.detail ?? "Notify when an agent needs you or finishes", Term.dim)] }))
                return 0
            default: Out.fail("unknown config command '\(a.positional[0])'."); return 2
            }
        })

    static let install = Command(
        name: "install", group: "Setup", summary: "Put `keeper` on your PATH (links into ~/.local/bin)",
        usage: ["keeper install", "", "  Homebrew does this for you. Use this if you installed the app by hand."],
        run: { _ in Out.line(CLIInstaller.install()); return 0 })

    static let completions = Command(
        name: "completions", group: "Setup", summary: "Shell completions for zsh, bash or fish",
        usage: ["keeper completions zsh|bash|fish", "", "  zsh:   keeper completions zsh > ~/.zfunc/_keeper   (and add ~/.zfunc to fpath)",
                "  bash:  eval \"$(keeper completions bash)\"", "  fish:  keeper completions fish > ~/.config/fish/completions/keeper.fish"],
        run: { a in
            let cmds = CLI.all.filter { $0.group != "Hidden" }
            switch a.positional.first {
            case "zsh":
                let list = cmds.map { "'\($0.name):\($0.summary.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: "\n    ")
                Out.line("#compdef keeper aikeeper\n_keeper() {\n  local -a cmds\n  cmds=(\n    \(list)\n  )\n  if (( CURRENT == 2 )); then _describe 'command' cmds; fi\n}\n_keeper \"$@\"")
            case "bash":
                Out.line("_keeper() { COMPREPLY=( $(compgen -W \"\(cmds.map(\.name).joined(separator: " "))\" -- \"${COMP_WORDS[1]}\") ); }\ncomplete -F _keeper keeper aikeeper")
            case "fish":
                Out.line(cmds.map { "complete -c keeper -n __fish_use_subcommand -a \($0.name) -d '\($0.summary.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: "\n"))
            default: Out.fail("which shell? zsh, bash or fish."); return 2
            }
            return 0
        })

    static let mcp = Command(
        name: "mcp", group: "Setup", summary: "Run as an MCP server over stdio so agents can use AI Keeper",
        usage: ["keeper mcp", "", "  Add to Claude Code:  claude mcp add keeper -- \(CLIInstaller.linkPath) mcp"],
        run: { _ in MCPServer.run() })

    /// The old name for `keeper clean <path>`, kept so existing scripts and MCP setups keep working.
    static let cleanArtifacts = Command(
        name: "clean-artifacts", group: "Hidden", summary: "Same as `keeper clean <path>`",
        usage: ["keeper clean-artifacts <path> [--yes]"],
        run: { a in
            guard let p = a.positional.first else { Out.fail("usage: keeper clean-artifacts <workspace-path> [--yes]"); return 2 }
            let r = Tools.cleanArtifacts(path: p, confirm: a.yes)
            Out.line(r.text); return r.isError ? 1 : 0
        })

    /// Writes the fictional demo workspaces, usage and disk map into the data folder, so every screen and command can be shown
    /// without real names. Only works with AIKEEPER_DEMO=1; use AIKEEPER_DATA to pick where.
    static let demoExport = Command(
        name: "demo-export", group: "Hidden", summary: "Write demo data for screenshots and docs",
        usage: ["AIKEEPER_DEMO=1 AIKEEPER_DATA=<folder> keeper demo-export"],
        run: { _ in
            guard Demo.enabled else { Out.fail("set AIKEEPER_DEMO=1 first."); return 2 }
            MainActor.assumeIsolated {
                let s = Store(); s.loadDemo()
                Library.save(s.entries)
                if let m = s.map { Persist.save(m, "map.json") }
                Persist.save(UsageData(rows: s.usage, sessions: s.sessions, codex: s.codexLimits), "usage.json")
            }
            Out.line("Wrote demo data to \(Persist.dir.path)"); return 0
        })

    /// Prints whether this binary was started under a command name. The tests use it to prove that the app's own name opens the window.
    static let invoked = Command(
        name: "_invoked", group: "Hidden", summary: "Test helper", usage: ["keeper _invoked"],
        run: { _ in Out.line(CLI.invokedAsCLI ? "cli" : "app"); return 0 })
}
