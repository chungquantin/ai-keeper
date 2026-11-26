import SwiftUI

// What your own history suggests changing. Everything here is worked out from real sessions:
// which agent was cheapest for each kind of task, which servers and hooks earn their place, and which habits cost time.

struct AdvisorCell { var n = 0; var cost = 0.0; var minutes = 0.0 }
struct AdvisorRow: Identifiable {
    var id: String { kind }
    let kind: String; let total: Int
    let cells: [AgentTool: AdvisorCell]
    let best: AgentTool?; let tip: String; let saving: Double
}
struct Tip: Identifiable {
    enum Group: String { case agent = "Pick the right agent", harness = "Trim the harness", habit = "Change a habit" }
    var id: String { title }
    let group: Group; let title: String; let body: String; let save: String?; let action: String; let area: Area; let tab: Tab
}
struct Advice {
    var rows: [AdvisorRow] = []
    var tips: [Tip] = []
    var monthly = 0.0            // estimated saving from switching agents, per 30 days
    var agg = TraceAgg()         // last 30 days
    var sessions = 0
}

enum Advisor {
    static let minSessions = 5

    static func kind(_ title: String) -> String {
        let t = title.lowercased()
        func has(_ w: [String]) -> Bool { w.contains { t.contains($0) } }
        if has([" ci", "ci ", "pipeline", "workflow", "github action"]) { return "Debug CI" }
        if has(["test"]) { return "Write tests" }
        if has(["doc", "readme", "release note", "changelog", "write up", "blog"]) { return "Docs and release notes" }
        if has(["refactor", "rename", "clean up", "cleanup", "simplif", "reorganiz", "restructure"]) { return "Refactor" }
        if has(["migrat", "schema", "database"]) { return "Database migrations" }
        if has(["fix", "bug", "error", "crash", "broken", "fail", "not work", "issue"]) { return "Fix a bug" }
        if has(["design", "ui", "style", "redesign", "layout", "theme"]) { return "Design and UI" }
        if has(["add", "implement", "create", "build", "support", "feature", "write", "make"]) { return "Add a feature" }
        return "Other"
    }

    static func name(_ a: AgentTool) -> String { a == .claude ? "Claude Code" : a.rawValue }

    static func compute(sessions: [SessionInfo], traces: [TraceSummary], servers: [MCPServerInfo]) -> Advice {
        var out = Advice()
        let from = Date().addingTimeInterval(-30 * 86_400)
        let recent = sessions.filter { $0.last >= from && $0.cost > 0 }
        out.sessions = recent.count
        out.agg = TraceAgg.compute(traces, from: from, to: Date().addingTimeInterval(3600))

        var groups: [String: [AgentTool: [SessionInfo]]] = [:]
        for s in recent { groups[kind(s.title), default: [:]][s.agent, default: []].append(s) }
        for (k, by) in groups where k != "Other" {
            var cells: [AgentTool: AdvisorCell] = [:]
            for (a, list) in by {
                cells[a] = AdvisorCell(n: list.count, cost: TraceAgg.median(list.map(\.cost)), minutes: TraceAgg.median(list.map { max($0.last.timeIntervalSince($0.first), 0) / 60 }))
            }
            let total = by.values.reduce(0) { $0 + $1.count }
            let enough = cells.filter { $0.value.n >= minSessions }
            let best = enough.min { $0.value.cost < $1.value.cost }?.key
            let most = cells.max { $0.value.n < $1.value.n }?.key
            var tip = enough.count < 2 ? "Too little history to compare agents" : "Keep \(name(best ?? .claude))"
            var saving = 0.0
            if let best, let most, best != most, let b = cells[best], let m = cells[most], m.n >= minSessions, m.cost > b.cost * 1.15 {
                saving = (m.cost - b.cost) * Double(m.n)
                tip = "Try \(name(best)). About \(String(format: "$%.2f", m.cost - b.cost)) cheaper a session."
                out.tips.append(Tip(group: .agent, title: "\(k): try \(name(best))", body: "Its median session cost \(String(format: "$%.2f", b.cost)) against \(String(format: "$%.2f", m.cost)) with \(name(most)), over \(b.n) and \(m.n) sessions.",
                                    save: String(format: "about $%.0f a month", saving), action: "See the comparison", area: .insights, tab: .advisor))
            }
            out.rows.append(AdvisorRow(kind: k, total: total, cells: cells, best: enough.count >= 2 ? best : nil, tip: tip, saving: saving))
        }
        out.rows.sort { $0.total > $1.total }
        out.monthly = out.rows.reduce(0) { $0 + $1.saving }
        out.tips.sort { ($0.save ?? "") > ($1.save ?? "") }

        // Harness: servers nobody called, hooks that fail, commands that keep failing.
        let a = out.agg
        if a.sessions > 0 {
            let unused = Set(servers.filter { $0.agent == "Claude Code" }.map(\.name)).filter { (a.mcp[$0] ?? 0) == 0 }.sorted()
            if !unused.isEmpty {
                out.tips.append(Tip(group: .harness, title: unused.count == 1 ? "\(unused[0]) was never called" : "\(unused.count) MCP servers were never called",
                                    body: "No Claude Code session used \(unused.prefix(3).joined(separator: ", ")) in 30 days. Each server's tool list is sent with every request.", save: nil, action: "Open MCP servers", area: .agents, tab: .mcp))
            }
            if let h = a.hookFails.max(by: { $0.value < $1.value }) {
                out.tips.append(Tip(group: .harness, title: "A hook failed \(h.value) times", body: h.key, save: nil, action: "Open hooks", area: .agents, tab: .hooks))
            }
            if let c = a.cmdFails.filter({ (a.cmdRuns[$0.key] ?? 0) >= 8 }).max(by: { Double($0.value) / Double(a.cmdRuns[$0.key] ?? 1) < Double($1.value) / Double(a.cmdRuns[$1.key] ?? 1) }),
               let runs = a.cmdRuns[c.key], Double(c.value) / Double(runs) >= 0.15 {
                out.tips.append(Tip(group: .harness, title: "\(c.key) fails \(c.value * 100 / runs)% of the time", body: "\(c.value) of \(runs) runs failed. Fixing it once helps every session.", save: nil, action: "See what fails", area: .insights, tab: .reliability))
            }
            if a.bigContext >= 3 {
                out.tips.append(Tip(group: .habit, title: "\(a.bigContext) sessions passed 150K tokens", body: "Every reply in a long session re-sends its whole history. Starting a fresh session sooner costs less.", save: nil, action: "See context use", area: .insights, tab: .context))
            }
            if a.idleBreaks >= 10 {
                out.tips.append(Tip(group: .habit, title: "\(a.idleBreaks) replies came after a 5 minute pause", body: "The prompt cache expires after about 5 minutes, so the next turn pays full price for the whole context.", save: nil, action: "See context use", area: .insights, tab: .context))
            }
            if !a.loops.isEmpty {
                out.tips.append(Tip(group: .habit, title: "\(a.loops.count) loops in 30 days", body: "An agent repeated the same failing command or edit. Stopping it early saves the retries.", save: nil, action: "See the loops", area: .insights, tab: .reliability))
            }
        }
        return out
    }
}
