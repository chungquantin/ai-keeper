import Foundation

enum AgentCommands {
    static var all: [Command] { [agents, sessions] }

    static func stateText(_ s: AgentState) -> (String, (String) -> String) {
        switch s {
        case .working: ("working", Term.blue)
        case .needsInput: ("needs you", Term.yellow)
        case .idle: ("idle", Term.dim)
        case .unknown: ("running", Term.dim)
        }
    }

    static let agents = Command(
        name: "agents", aliases: ["ps"], group: "Agents and usage", summary: "Coding agents running now, and stop one",
        usage: ["keeper agents [--all] [--json]", "keeper agents stop <pid>... [--force] [--yes]", "",
                "  --all     Also list MCP servers (orphaned ones have lost their client)",
                "  stop      Send SIGTERM (--force: SIGKILL) to agents you name. Dry run without --yes"],
        flags: ["all", "force"],
        run: { a in
            let list = Library.agents().filter { a.flag("all") || $0.kind != .mcp }
            if a.positional.first == "stop" {
                let pids = a.positional.dropFirst().compactMap { Int32($0) }
                guard !pids.isEmpty else { Out.fail("which agent? `keeper agents stop <pid>` (pids are in `keeper agents`)."); return 2 }
                var status: Int32 = 0
                for pid in pids {
                    guard let ag = Library.agents().first(where: { $0.pid == pid }) else {
                        Out.fail("pid \(pid) is not a running coding agent, so I won't signal it."); status = 1; continue   // never a general kill command
                    }
                    let what = "\(ag.kind.rawValue) (pid \(pid))" + (ag.cwd.map { " in \(Fmt.tilde($0))" } ?? "")
                    if !a.yes { Out.line("Would stop \(what)" + (ag.state == .working ? Term.yellow("  it is working right now") : "")); continue }
                    if kill(pid, a.flag("force") ? SIGKILL : SIGTERM) == 0 { Out.line("Stopped \(what)") } else { Out.fail("couldn't stop pid \(pid): \(String(cString: strerror(errno)))"); status = 1 }
                }
                if !a.yes { Out.line(Term.dim("\nDry run. Add --yes to stop them.")) }
                return status
            }
            if a.json {
                Out.json(list.map { ag in
                    var o: [String: Any] = ["pid": Int(ag.pid), "tool": ag.kind.rawValue, "state": ag.state.rawValue, "cpu_percent": Int(ag.cpu.rounded()), "memory_bytes": ag.rssBytes,
                                            "running_seconds": Int(ag.elapsed), "cwd": ag.cwd ?? "", "orphaned": ag.orphaned]
                    if let c = ag.cost { o["session_cost_usd"] = Double(String(format: "%.2f", c)) }
                    if let t = ag.title { o["task"] = t }
                    return o
                }); return 0
            }
            guard !list.isEmpty else { Out.line("No coding agents are running."); return 0 }
            let rows = list.map { ag -> [Out.Cell] in
                let (txt, style) = stateText(ag.state)
                return [Out.Cell("\(ag.pid)", Term.dim), Out.Cell(ag.kind.rawValue), Out.Cell(ag.orphaned ? "orphaned" : txt, ag.orphaned ? Term.red : style),
                        Out.Cell(String(format: "%.0f%%", ag.cpu), Term.dim), Out.Cell(Fmt.size(ag.rssBytes), Term.dim),
                        Out.Cell(ag.cost.map(Fmt.usd) ?? "", Term.dim), Out.Cell(Fmt.duration(ag.elapsed), Term.dim),
                        Out.Cell(ag.title ?? ag.cwd.map(Fmt.tilde) ?? "")]
            }
            Out.line(Out.table(["PID", "TOOL", "STATE", "CPU", "MEM", "COST", "UP", "TASK"], rows, right: [0, 3, 4, 5, 6]))
            let needs = list.filter { $0.state == .needsInput }.count
            Out.line(Term.dim("\n\(list.count) running" + (needs > 0 ? ", \(needs) waiting for you" : "")))
            return 0
        })

    static let sessions = Command(
        name: "sessions", group: "Agents and usage", summary: "Past agent sessions: search, cost, and resume one",
        usage: ["keeper sessions [--tool claude|codex|pi] [--project NAME] [--search TEXT] [--limit N] [--json]",
                "keeper sessions resume <session-id-prefix> [--run]", "",
                "  --search   Sessions whose conversation contains the text",
                "  resume     Print the command that resumes a session, or run it here with --run"],
        valueOptions: ["tool", "project", "search", "limit"],
        flags: ["run"],
        run: { a in
            let d = UsageCommands.freshUsage()
            if a.positional.first == "resume" {
                guard let prefix = a.positional.dropFirst().first?.lowercased() else { Out.fail("which session? `keeper sessions resume <id>`."); return 2 }
                // One session can span several log files; they share an id, so only differing ids are ambiguous.
                let hits = d.sessions.filter { $0.sessionID.lowercased().hasPrefix(prefix) }.sorted { $0.last > $1.last }
                let ids = Set(hits.map(\.sessionID))
                guard ids.count == 1, let s = hits.first else { Out.fail(hits.isEmpty ? "no session starts with '\(prefix)'." : "\(ids.count) sessions start with '\(prefix)'; type more of the id."); return 1 }
                // The id comes from a log file anyone can write: only real ids may reach a shell.
                guard s.sessionID.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { Out.fail("that session id looks wrong; not resuming."); return 1 }
                guard s.cwdExists else { Out.fail("its folder no longer exists: \(Fmt.tilde(s.cwd))"); return 1 }
                func q(_ x: String) -> String { "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let cmd: String
                switch s.agent {
                case .claude: cmd = "claude --resume \(q(s.sessionID))"
                case .codex: cmd = "codex resume \(q(s.sessionID))"
                case .pi: cmd = "pi --session \(q(s.file))"
                }
                let line = "cd \(q(s.cwd)) && \(cmd)"
                guard a.flag("run") else { Out.line(line); return 0 }
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", line]
                try? p.run(); p.waitUntilExit(); return p.terminationStatus
            }
            var list = d.sessions.sorted { $0.last > $1.last }
            if let t = a.value("tool")?.lowercased() { list = list.filter { $0.agent.toolID == t } }
            if let p = a.value("project")?.lowercased() { list = list.filter { $0.project.lowercased().contains(p) } }
            if let q = a.value("search"), !q.isEmpty {
                Out.status("Searching…")
                let out = Shell.run("/usr/bin/grep", ["-rliF", "--include=*.jsonl", "--", q, "\(home)/.claude/projects", "\(home)/.codex/sessions", "\(home)/.pi/agent/sessions"]).out
                Out.endStatus()
                let files = Set(out.split(separator: "\n").map(String.init))
                list = list.filter { files.contains($0.file) }
            }
            list = Array(list.prefix(a.int("limit") ?? 20))
            if a.json {
                Out.json(list.map { ["id": $0.sessionID, "tool": $0.agent.rawValue, "title": $0.title, "project": $0.project, "cwd": $0.cwd, "last_active": Fmt.iso($0.last) as Any,
                                     "cost_usd": Double(String(format: "%.2f", $0.cost)) as Any, "tokens": $0.tokens, "folder_exists": $0.cwdExists] as [String: Any] }); return 0
            }
            guard !list.isEmpty else { Out.line("No sessions match."); return 0 }
            Out.line(Out.table(["ID", "LAST", "TOOL", "COST", "PROJECT", "TITLE"],
                               list.map { [Out.Cell(String($0.sessionID.prefix(8)), Term.dim), Out.Cell(Fmt.ago($0.last), Term.dim), Out.Cell($0.agent.rawValue), Out.Cell(Fmt.usd($0.cost), Term.dim),
                                           Out.Cell($0.project, Term.dim), Out.Cell($0.title)] }, right: [3]))
            Out.line(Term.dim("\nResume one: keeper sessions resume <id>"))
            return 0
        })
}

enum UsageCommands {
    static var all: [Command] { [usage] }

    /// Parses the logs (fast when nothing changed: results are cached on disk).
    static func freshUsage() -> UsageData {
        Out.status("Reading session logs…")
        let d = UsageParser.load()
        Out.endStatus()
        return d
    }

    static let usage = Command(
        name: "usage", aliases: ["spend", "cost"], group: "Agents and usage", summary: "AI spend and tokens by tool, model, day, project, and budgets",
        usage: ["keeper usage [--days N] [--by tool|model|day|project] [--tool claude|codex|pi] [--json]",
                "keeper usage budget [--daily USD] [--weekly USD]", "",
                "  Costs are estimates at public API list prices. Defaults: 7 days, grouped by tool.",
                "  budget   Show or set the daily and weekly spend limits (0 turns one off)"],
        valueOptions: ["days", "by", "tool", "daily", "weekly"],
        run: { a in
            let cal = Calendar.current
            if a.positional.first == "budget" {
                let ud = UserDefaults.standard
                var changed = false
                for (flag, key) in [("daily", "budget.daily"), ("weekly", "budget.weekly")] {
                    if let v = a.value(flag) { guard let n = Double(v), n >= 0 else { Out.fail("--\(flag) needs a dollar amount, like 40."); return 2 }; ud.set(n, forKey: key); changed = true }
                }
                let daily = ud.number("budget.daily", default: 0), weekly = ud.number("budget.weekly", default: 0)
                let (today, week) = StatusCommands.spend(StatusCommands.usageData())
                if a.json { Out.json(["daily_usd": daily, "weekly_usd": weekly, "today_usd": today, "week_usd": week]); return 0 }
                if changed { Out.line("Saved.") }
                func line(_ k: String, _ spent: Double, _ limit: Double) {
                    Out.line(Term.dim(k.padding(toLength: 8, withPad: " ", startingAt: 0)) + (limit > 0 ? "\(Fmt.usd(spent)) of \(Fmt.usd(limit))" + (spent >= limit ? "  " + Term.red("reached") : "") : "off  " + Term.dim("(\(Fmt.usd(spent)) so far)")))
                }
                line("Daily", today, daily); line("Weekly", week, weekly)
                return 0
            }
            let days = max(1, a.int("days") ?? 7)
            let by = a.value("by") ?? "tool"
            guard ["tool", "model", "day", "project"].contains(by) else { Out.fail("--by takes tool, model, day or project."); return 2 }
            let d = freshUsage()
            let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: .now))!
            var rows = d.rows.filter { $0.day >= cutoff }
            if let t = a.value("tool")?.lowercased() { rows = rows.filter { $0.agent.toolID == t } }
            let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
            var groups: [String: (cost: Double, tokens: Int)] = [:]
            for r in rows {
                let key: String
                switch by {
                case "model": key = r.model
                case "day": key = dayFmt.string(from: r.day)
                case "project": key = r.project.isEmpty ? "(none)" : r.project
                default: key = r.agent.rawValue
                }
                groups[key, default: (0, 0)].cost += r.cost; groups[key, default: (0, 0)].tokens += r.tokens
            }
            let ordered = groups.sorted { by == "day" ? $0.key > $1.key : $0.value.cost > $1.value.cost }
            let total = rows.reduce(0) { $0 + $1.cost }, tokens = rows.reduce(0) { $0 + $1.tokens }
            if a.json {
                var out: [String: Any] = ["days": days, "by": by, "total_usd": Double(String(format: "%.2f", total)) as Any, "total_tokens": tokens,
                                          "groups": ordered.map { ["key": $0.key, "cost_usd": Double(String(format: "%.2f", $0.value.cost)) as Any, "tokens": $0.value.tokens] as [String: Any] },
                                          "note": "Estimated at API list prices"]
                if let c = d.codex { out["codex_limits"] = ["primary_percent": c.primaryPct, "primary_resets": Fmt.iso(c.primaryResets) as Any, "weekly_percent": c.weeklyPct, "weekly_resets": Fmt.iso(c.weeklyResets) as Any] }
                Out.json(out); return 0
            }
            guard !ordered.isEmpty else { Out.line("No usage in the last \(days) day\(days == 1 ? "" : "s")."); return 0 }
            Out.line(Out.table([by.uppercased(), "COST", "TOKENS", "SHARE"],
                               ordered.prefix(by == "day" ? days : 15).map { [Out.Cell($0.key), Out.Cell(Fmt.usd($0.value.cost)), Out.Cell(String(format: "%.1fM", Double($0.value.tokens) / 1e6), Term.dim),
                                                                               Out.Cell(total > 0 ? Fmt.pct($0.value.cost / total) : "", Term.dim)] }, right: [1, 2, 3]))
            Out.line("\nTotal  " + Term.bold(Fmt.usd(total)) + Term.dim("  ·  \(String(format: "%.1fM", Double(tokens) / 1e6)) tokens  ·  last \(days) day\(days == 1 ? "" : "s")  ·  estimated at API list prices"))
            if let c = d.codex { Out.line(Term.dim("Codex limits  5-hour window \(Int(c.primaryPct))% (resets \(c.primaryResets.formatted(date: .omitted, time: .shortened))) · weekly \(Int(c.weeklyPct))%")) }
            return 0
        })
}
