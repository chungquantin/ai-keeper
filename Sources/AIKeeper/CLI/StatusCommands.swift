import Foundation

enum StatusCommands {
    static var all: [Command] { [ui, status, scan] }

    /// Spend figures from the app's saved usage (instant); falls back to parsing the logs when the app never ran.
    static func usageData() -> UsageData { Persist.load(UsageData.self, "usage.json") ?? UsageParser.load() }

    /// Only what the app already saved: instant, never parses logs. nil when the app has not computed usage yet.
    static func cachedUsage() -> UsageData? { Persist.load(UsageData.self, "usage.json") }

    static func spend(_ d: UsageData) -> (today: Double, week: Double) {
        let cal = Calendar.current, now = Date()
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
        return (d.rows.filter { cal.isDateInToday($0.day) }.reduce(0) { $0 + $1.cost }, d.rows.filter { $0.day >= weekStart }.reduce(0) { $0 + $1.cost })
    }

    /// Line-weight gauge, the same one the dashboard draws.
    static func gauge(_ f: Double, _ width: Int, _ style: (String) -> String) -> String {
        let full = f > 0 ? max(1, Int((Double(width) * min(1, f)).rounded())) : 0
        return style(String(repeating: "━", count: full)) + Term.dim(String(repeating: "─", count: max(0, width - full)))
    }

    static let status = Command(
        name: "status", group: "Overview", summary: "Disk, what you can get back, agents and spend at a glance",
        usage: ["keeper status [--json]"],
        run: { a in
            let disk = Tools.diskInfo()
            let entries = Library.entries()
            let st = Stats(entries)
            let agents = Library.agents().filter { $0.kind != .mcp }
            let needYou = agents.filter { $0.state == .needsInput }.count
            let (today, week) = spend(usageData())
            let floorGB = UserDefaults.standard.number("guard.floorGB", default: 50)
            let lowDisk = Double(disk.available) / 1e9 < floorGB
            let daily = UserDefaults.standard.number("budget.daily", default: 0), weekly = UserDefaults.standard.number("budget.weekly", default: 0)
            var alerts: [String] = []
            if lowDisk { alerts.append("Free space is below your \(Int(floorGB)) GB floor") }
            if daily > 0, today >= daily { alerts.append("Daily AI budget reached: \(Fmt.usd(today)) of \(Fmt.usd(daily))") }
            if weekly > 0, week >= weekly { alerts.append("Weekly AI budget reached: \(Fmt.usd(week)) of \(Fmt.usd(weekly))") }
            let deprecatedBytes = st.removable.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let leftovers = (st.orphans + st.caches).reduce(Int64(0)) { $0 + max($1.size ?? 0, 0) }

            if a.json {
                Out.json(["disk": ["free_bytes": disk.available, "used_bytes": disk.used, "total_bytes": disk.total, "purgeable_bytes": disk.purgeable, "low": lowDisk, "alert_floor_gb": floorGB],
                          "reclaimable": ["total_bytes": st.reclaimable, "build_folders_bytes": st.keptArtifactBytes, "deprecated_workspaces_bytes": deprecatedBytes,
                                          "deprecated_workspaces": st.removable.count, "leftovers_bytes": leftovers],
                          "agents": ["running": agents.count, "need_you": needYou],
                          "spend_usd": ["today": Double(String(format: "%.2f", today)) as Any, "week": Double(String(format: "%.2f", week)) as Any],
                          "alerts": alerts, "scan_age_minutes": Library.scanDate.map { Int(Date().timeIntervalSince($0) / 60) } as Any] as [String: Any])
                return 0
            }
            let usedFraction = disk.total > 0 ? Double(disk.total - disk.available) / Double(disk.total) : 0
            func row(_ k: String, _ v: String) { Out.line(Term.dim(k.padding(toLength: 13, withPad: " ", startingAt: 0)) + v) }
            row("disk", Term.bold(Fmt.size(disk.available)) + Term.dim(" free of \(Fmt.size(disk.total))   ") + gauge(usedFraction, 14, lowDisk ? Term.red : Term.blue) + (lowDisk ? "  " + Term.red("low") : ""))
            if entries.isEmpty { row("reclaimable", Term.dim("no scan yet, run `keeper scan`")) }
            else {
                row("reclaimable", Term.bold(Term.amber(Fmt.size(st.reclaimable))))
                let top = Double(max(st.keptArtifactBytes, deprecatedBytes, leftovers, 1))
                for (name, bytes, note) in [("build folders", st.keptArtifactBytes, ""), ("workspaces", deprecatedBytes, "\(st.removable.count) safe to remove"), ("leftovers", leftovers, "")] {
                    Out.line(String(repeating: " ", count: 13) + Term.dim(name.padding(toLength: 15, withPad: " ", startingAt: 0)) + gauge(Double(bytes) / top, 20, Term.amber) + "  " + Fmt.size(bytes) + Term.dim(note.isEmpty ? "" : "  " + note))
                }
            }
            row("agents", "\(agents.count) running" + (needYou > 0 ? ", " + Term.bold("\(needYou) waiting for you") : ""))
            row("spend", "\(Fmt.usd(today)) today, \(Fmt.usd(week)) this week")
            let log = CleanLog.summary(CleanLog.all())
            if log.runs > 0 { row("cleaned", Term.bold(Fmt.size(log.totalBytes)) + Term.dim(" in total, \(HistoryCommands.days(log.currentStreak)) streak")) }
            row("scanned", Term.dim(Library.scanDate.map { Fmt.ago($0) } ?? "never"))
            for al in alerts { Out.line(); Out.line(Term.yellow("! ") + al) }
            return 0
        })

    static let scan = Command(
        name: "scan", aliases: ["rescan"], group: "Overview", summary: "Re-scan workspaces: sizes, git state and pull requests",
        usage: ["keeper scan [--no-prs] [--json]", "", "  Measures every workspace and main checkout (git status, build folders) and looks up",
                "  pull request state with the GitHub CLI when it is signed in. Takes a minute or two.",
                "  --no-prs   Skip the pull request lookup"],
        flags: ["no-prs"],
        run: { a in
            let list = Library.scan(prs: !a.flag("no-prs"))
            let st = Stats(list)
            if a.json { Out.json(["workspaces": st.workspaces.count, "deprecated": st.deprecated.count, "reclaimable_bytes": st.reclaimable, "managed_bytes": st.managedBytes]); return 0 }
            Out.line("Scanned \(st.workspaces.count) workspaces and \(list.filter { $0.kind == .repo }.count) main checkouts: \(Fmt.size(st.managedBytes)) in total.")
            Out.line("\(Term.bold(Fmt.size(st.reclaimable))) can be reclaimed, \(st.removable.count) workspaces are safe to remove.")
            if !a.flag("no-prs"), PRService.gh == nil { Out.note(Term.dim("Install the GitHub CLI (brew install gh) to see pull request state.")) }
            return 0
        })
}

enum WorkspaceCommands {
    static var all: [Command] { [workspaces, workspace] }

    static let workspaces = Command(
        name: "workspaces", aliases: ["ls", "list"], group: "Workspaces", summary: "List workspaces, biggest first",
        usage: ["keeper workspaces [--deprecated] [--safe] [--tool claude|conductor|codex|superset|pi|zcode|git]",
                "                  [--repo NAME] [--sort size|activity|name] [--limit N] [--all] [--paths] [--json]", "",
                "  --deprecated   Only workspaces judged deprecated (work merged, abandoned or stale)",
                "  --safe         Only the ones safe to remove right now",
                "  --all          Include empty workspaces and main checkouts"],
        valueOptions: ["tool", "repo", "sort", "limit"],
        flags: ["deprecated", "safe", "all", "paths"],
        run: { a in
            guard var list = Library.requireScan() else { return 1 }
            if !a.flag("all") { list = list.filter { ($0.size ?? 0) > 0 || $0.artifactBytes > 0 } }
            list = list.filter { $0.kind == .workspace || (a.flag("all") && $0.kind == .repo) || ($0.kind == .repo && $0.artifactBytes > 0) }
            if a.flag("deprecated") { list = list.filter { $0.verdict == .deprecated } }
            if a.flag("safe") { list = list.filter { $0.verdict == .deprecated && $0.safety == .safe } }
            if let t = a.value("tool")?.lowercased() { list = list.filter { Library.tools($0).contains(t) } }
            if let r = a.value("repo")?.lowercased() { list = list.filter { $0.repoName.lowercased() == r } }
            switch a.value("sort") ?? "size" {
            case "activity": list.sort { $0.activityValue > $1.activityValue }
            case "name": list.sort { $0.name.lowercased() < $1.name.lowercased() }
            default: list.sort { ($0.size ?? 0) > ($1.size ?? 0) }
            }
            let total = list.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            list = Array(list.prefix(a.int("limit") ?? 50))
            if a.json { Out.json(list.map(Library.dict)); return 0 }
            guard !list.isEmpty else { Out.line("Nothing matches."); return 0 }
            let showPaths = a.flag("paths")
            let rows = list.map { e -> [Out.Cell] in
                let status = Library.statusText(e)
                let style: (String) -> String = e.safety == .danger ? Term.red : e.verdict == .deprecated && e.safety == .safe ? Term.blue : e.safety == .caution ? Term.yellow : Term.dim
                return [Out.Cell(Fmt.size(e.size ?? 0)), Out.Cell(Fmt.size(e.artifactBytes), Term.dim), Out.Cell(status, style),
                        Out.Cell(e.pr.map { "#\($0.number) \($0.state.lowercased())" } ?? e.gitSummary?.text ?? "", Term.dim),
                        Out.Cell(Fmt.ago(e.lastActivity), Term.dim),
                        Out.Cell(showPaths ? Fmt.tilde(e.path) : "\(e.repoName)/\(e.name)")]
            }
            Out.line(Out.table(["SIZE", "BUILD", "STATUS", "GIT / PR", "ACTIVE", showPaths ? "PATH" : "WORKSPACE"], rows, right: [0, 1]))
            Out.line(Term.dim("\n\(list.count) shown · \(Fmt.size(total)) · `keeper workspace <name>` for details"))
            return 0
        })

    static let workspace = Command(
        name: "workspace", aliases: ["inspect", "show"], group: "Workspaces", summary: "Everything about one workspace and why it is flagged",
        usage: ["keeper workspace <name | repo/name | path> [--json]"],
        run: { a in
            guard let sel = a.positional.first else { Out.fail("which workspace? `keeper workspace <name>`"); return 2 }
            guard let all = Library.requireScan() else { return 1 }
            switch Library.resolve(sel, in: all) {
            case .failed(let m): Out.fail(m); return 1
            case .found(let e):
                let running = Library.agents(in: e, from: Library.agents())
                if a.json {
                    var d = Library.dict(e); d["running_agents"] = running.map { ["pid": Int($0.pid), "tool": $0.kind.rawValue, "state": $0.state.rawValue] }
                    if let n = e.neededness { d["needed"] = ["headline": n.headline, "detail": n.detail] }
                    Out.json(d); return 0
                }
                Out.line(Term.bold(e.name) + Term.dim("  \(e.repoName)" + (e.branch.map { " · \($0)" } ?? "")))
                Out.line(Term.dim(Fmt.tilde(e.path)))
                Out.line()
                let style: (String) -> String = e.safety == .danger ? Term.red : e.verdict == .deprecated && e.safety == .safe ? Term.blue : Term.yellow
                Out.line(style(Library.statusText(e)) + Term.dim("  ·  \(Library.tools(e).joined(separator: ", "))  ·  active \(Fmt.ago(e.lastActivity))"))
                if let n = e.neededness { Out.line(Term.bold(n.headline)); Out.line(n.detail) }
                if !running.isEmpty { Out.line(Term.yellow("\(running.count) agent\(running.count == 1 ? "" : "s") running here: ") + running.map { "\($0.kind.rawValue) (pid \($0.pid))" }.joined(separator: ", ")) }
                if let g = e.git {
                    Out.line()
                    Out.line(Term.bold("Git"))
                    Out.line("  Working tree   " + (g.dirtyCount == 0 ? "clean" : "\(g.dirtyCount) uncommitted file\(g.dirtyCount == 1 ? "" : "s")"))
                    Out.line("  Not on a remote  " + (g.unpushed == 0 ? "nothing" : "\(g.unpushed) commit\(g.unpushed == 1 ? "" : "s")"))
                    Out.line("  Versus \(g.defaultBranch)   " + (g.merged ? "landed" : "\(g.aheadOfBase) ahead, \(g.behindBase) behind"))
                    if let s = g.lastSubject { Out.line("  Last commit    " + s + Term.dim("  (\(Fmt.ago(g.lastCommit)))")) }
                }
                if let p = e.pr {
                    Out.line()
                    Out.line(Term.bold("Pull request") + "  #\(p.number) \(p.state.lowercased())" + (p.detailLine.isEmpty ? "" : Term.dim("  \(p.detailLine)")))
                    Out.line("  \(p.title)"); Out.line(Term.dim("  \(p.url)"))
                }
                if !e.reasons.isEmpty { Out.line(); Out.line(Term.bold("Why it is flagged")); for r in e.reasons { Out.line("  · \(r)") } }
                Out.line()
                Out.line(Term.bold("Storage") + "  \(Fmt.size(e.size ?? 0))" + Term.dim(" total, \(Fmt.size(e.artifactBytes)) rebuildable"))
                for art in e.artifacts.sorted(by: { $0.bytes > $1.bytes }) { Out.line("  " + Fmt.size(art.bytes).padding(toLength: 10, withPad: " ", startingAt: 0) + art.label) }
                Out.line()
                Out.line(Term.dim("Remove: keeper remove \(e.name) --yes     Build folders only: keeper clean \(e.name) --yes"))
                return 0
            }
        })
}
