import SwiftUI

/// Insights › Cost, as designed: what you spent today against your budget, daily spend by agent, and a table of models.
/// All real, from the agents' own logs. The totals are worked out in the background and only when usage or a filter changes.
struct CostView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var days = 30
    @State private var tool: AgentTool?
    @State private var data = Summary()
    @AppStorage(Prefs.Key.budgetDaily) private var storedDaily = 0.0
    private var dailyBudget: Double { Demo.enabled ? 30 : storedDaily }

    struct ModelRow: Identifiable { let id: String; let model: String; let agent: AgentTool; let sessions: Int; let tokens: Int; let cost: Double }
    struct Summary {
        var today = 0.0, yesterday = 0.0, total = 0.0, tokens = 0, sessions = 0, cacheRate: Int?
        var perDay: [[Double]] = []          // [day][claude, codex, pi]
        var models: [ModelRow] = []
        var top: [SessionInfo] = []
    }

    private var key: [AnyHashable] { [store.usage.count, store.sessions.count, days, tool?.rawValue ?? ""] }

    var body: some View {
        Page(title: "Cost", subtitle: "Estimated at public API list prices, from your local session logs") {
            if store.usage.isEmpty {
                Card { Text(store.usageLoading ? "Reading agent logs…" : "No usage found yet. AI Keeper reads the logs Claude Code, Codex and Pi keep on this Mac.").foregroundStyle(.secondary) }
            } else {
                HStack(spacing: 8) {
                    PillMenu([("Last 7 days", 7), ("Last 30 days", 30), ("Last 90 days", 90)], selection: $days)
                    PillMenu([("All agents", AgentTool?.none)] + AgentTool.enabled.map { (Self.agentName($0), AgentTool?.some($0)) }, selection: $tool)
                    Spacer()
                    Text("\(compact(data.tokens)) tokens · \(data.sessions) sessions" + (data.cacheRate.map { " · \($0)% cache hits" } ?? "")).font(.bCaption).foregroundStyle(.secondary)
                }
                AdaptiveRow(spacing: 14, minChild: 340) {
                    hero.frame(width: 420)
                    chart
                }
                models
                if let c = store.codexLimits, tool != .claude { codex(c) }
                expensive
                Text("Subscription plans bill differently. Claude cache writes use the 5-minute rate.").font(.bCaption).foregroundStyle(.tertiary)
            }
        }
        .task(id: key) {
            let usage = store.usage, sessions = store.sessions, d = days, t = tool
            data = await Task.detached(priority: .userInitiated) { Self.summarize(usage, sessions, days: d, tool: t) }.value
        }
    }

    // MARK: Hero

    private var hero: some View {
        let f = dailyBudget > 0 ? min(data.today / dailyBudget, 1) : 0
        let change = data.yesterday > 0 ? (data.today - data.yesterday) / data.yesterday * 100 : nil
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Spent today").font(.bCaption).foregroundStyle(.secondary); Spacer()
                    if let change { Delta(text: String(format: "%@%.1f%%", change >= 0 ? "+" : "−", abs(change)), good: change <= 0).help("Compared with yesterday") } }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.2f", data.today)).font(.system(size: 80, weight: .medium)).kerning(-3.5).monospacedDigit()
                    Text("USD").font(.system(size: 26, weight: .medium)).kerning(-0.8).foregroundStyle(.secondary)
                }.lineLimit(1).minimumScaleFactor(0.5)
                if dailyBudget > 0 {
                    HStack { Text("Daily budget").foregroundStyle(.secondary); Spacer(); Text(String(format: "$%.2f of $%.2f", data.today, dailyBudget)).monospacedDigit() }.font(.bCaption)
                    PixelMeter(value: f, tint: f >= 1 ? Brand.destructive : Brand.accent, height: 9, warnTail: f > 0.8 && f < 1, segments: 24)
                    Text(paceNote).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No daily budget set. A budget warns you before spend runs away.").font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Set a budget") { nav.open(.agents, .budgets) }
                }
            }
        }
    }

    /// When today's spend would reach the budget if it keeps arriving at the rate it has so far today.
    private var paceNote: String {
        if data.today >= dailyBudget { return "You are over today's budget." }
        let now = Date(), start = Calendar.current.startOfDay(for: now)
        let hours = max(now.timeIntervalSince(start) / 3600, 0.25)
        let rate = data.today / hours
        guard rate > 0 else { return "Nothing spent yet today." }
        let hit = now.addingTimeInterval((dailyBudget - data.today) / rate * 3600)
        guard Calendar.current.isDate(hit, inSameDayAs: now) else { return "At this pace you stay within today's budget." }
        return "At this pace you reach the budget around \(hit.formatted(date: .omitted, time: .shortened))."
    }

    static func agentName(_ a: AgentTool) -> String { a == .claude ? "Claude Code" : a.rawValue }

    /// "claude-sonnet-5-5" reads better as "Claude Sonnet 5.5".
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        parts.removeAll { $0.count == 8 && Int($0) != nil }   // a trailing date stamp
        var words: [String] = [], nums: [String] = []
        for p in parts {
            if Int(p) != nil { nums.append(p) } else if p.first?.isNumber == true { words.append(p) }
            else { words.append(p.lowercased() == "gpt" ? "GPT" : p.prefix(1).uppercased() + p.dropFirst()) }
        }
        if id.lowercased().hasPrefix("gpt"), words.count >= 2 { return words[0] + "-" + words.dropFirst().joined(separator: " ") + (nums.isEmpty ? "" : " " + nums.joined(separator: ".")) }
        return (words + (nums.isEmpty ? [] : [nums.joined(separator: ".")])).joined(separator: " ")
    }

    private var chart: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Daily spend by agent", note: String(format: "$%.2f in %d days", data.total, days))
                StackedBars(data: data.perDay.isEmpty ? [[0, 0, 0]] : data.perDay, colors: [AgentColor.claude, AgentColor.codex, AgentColor.pi], height: 104)
                Legend(items: [("Claude Code", AgentColor.claude), ("Codex", AgentColor.codex), ("Pi", AgentColor.pi)])
            }
        }
    }

    private func codex(_ c: CodexLimits) -> some View {
        Card(padding: 16) {
            HStack(spacing: 24) {
                ForEach([("Codex 5-hour window", c.primaryPct, c.primaryResets), ("Codex weekly", c.weeklyPct, c.weeklyResets)], id: \.0) { l in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(l.0).font(.bBody.weight(.medium)); Spacer(); Text("\(Int(l.1))% used").font(.bCaption).foregroundStyle(.secondary).monospacedDigit() }
                        GeometryReader { g in
                            ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(l.1 >= 90 ? Brand.destructive : l.1 >= 70 ? Brand.reclaim : AgentColor.codex).frame(width: max(4, g.size.width * min(l.1 / 100, 1))) }
                        }.frame(height: 6)
                        Text(l.2 > .now ? "Resets \(l.2.formatted(.relative(presentation: .named)))" : "Window has reset").font(.bCaption).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Model table

    private var models: some View {
        let top = max(data.models.first?.cost ?? 1, 0.0001)
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading); Text("Agent").frame(width: 110, alignment: .leading)
                    Text("Sessions").frame(width: 70, alignment: .trailing); Text("Tokens").frame(width: 80, alignment: .trailing)
                    Text("Spend").frame(width: 80, alignment: .trailing); Text("Share of spend").frame(width: 170, alignment: .leading)
                }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                ForEach(data.models.prefix(8)) { m in
                    Divider()
                    HStack(spacing: 14) {
                        Text(Self.modelName(m.model)).font(.bBody).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(m.model)
                        HStack(spacing: 7) { Circle().fill(AgentColor.of(m.agent.rawValue)).frame(width: 7, height: 7); Text(Self.agentName(m.agent)).font(.bCaption).foregroundStyle(.secondary) }.frame(width: 110, alignment: .leading)
                        Text("\(m.sessions)").foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(compact(m.tokens)).foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Text(String(format: "$%.2f", m.cost)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        GeometryReader { g in
                            ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(AgentColor.of(m.agent.rawValue)).frame(width: max(3, g.size.width * m.cost / top)) }
                        }.frame(width: 170, height: 6)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
    }

    private var expensive: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Most expensive sessions").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                ForEach(data.top) { s in
                    Divider()
                    HStack(spacing: 12) {
                        Circle().fill(AgentColor.of(s.agent.rawValue)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title.isEmpty ? s.project : s.title).font(.bBody.weight(.medium)).lineLimit(1)
                            Text("\(s.agent.rawValue) · \(s.project)").font(.bCaption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(compact(s.tokens)).font(.bCaption).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(String(format: "$%.2f", s.cost)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }.padding(.horizontal, 16).padding(.vertical, 9)
                }
            }
        }
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000_000 ? String(format: "%.1fB", Double(n) / 1e9) : n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)K" : "\(n)"
    }

    // MARK: Totals (one pass, off the main thread)

    nonisolated private static func summarize(_ usage: [UsageRow], _ sessions: [SessionInfo], days: Int, tool: AgentTool?) -> Summary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        var s = Summary()
        s.perDay = Array(repeating: [0, 0, 0], count: days)
        var seen = Set<String>(), cacheRead = 0, prompt = 0
        var byModel: [String: (agent: AgentTool, sessions: Set<String>, tokens: Int, cost: Double)] = [:]
        for r in usage {
            if let tool, r.agent != tool { continue }
            guard r.day >= cutoff else { continue }
            let c = r.cost
            if r.day >= today { s.today += c } else if r.day >= yesterday { s.yesterday += c }
            s.total += c; s.tokens += r.tokens; seen.insert(r.session)
            cacheRead += r.cacheRead; prompt += r.input + r.cacheRead + r.cacheWrite
            let d = Int((r.day.timeIntervalSince(cutoff) / 86_400).rounded(.down))
            if d >= 0, d < days { s.perDay[d][r.agent == .claude ? 0 : r.agent == .codex ? 1 : 2] += c }
            let k = "\(r.agent.rawValue)|\(r.model)"
            var m = byModel[k] ?? (r.agent, [], 0, 0)
            m.sessions.insert(r.session); m.tokens += r.tokens; m.cost += c
            byModel[k] = m
        }
        s.sessions = seen.count
        s.cacheRate = prompt > 0 ? cacheRead * 100 / prompt : nil
        s.models = byModel.map { ModelRow(id: $0.key, model: String($0.key.split(separator: "|", maxSplits: 1).last ?? ""), agent: $0.value.agent, sessions: $0.value.sessions.count, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.cost > $1.cost }
        var top: [SessionInfo] = []
        for x in sessions where x.last >= cutoff && (tool == nil || x.agent == tool) {
            if top.count == 5, let l = top.last, x.cost <= l.cost { continue }
            top.insert(x, at: top.firstIndex { x.cost > $0.cost } ?? top.count)
            if top.count > 5 { top.removeLast() }
        }
        s.top = top
        return s
    }
}
