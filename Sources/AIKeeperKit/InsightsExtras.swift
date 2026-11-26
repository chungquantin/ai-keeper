import SwiftUI

// Speed, Reliability, Context and Advisor. Every number comes from the session logs (TraceIndex) and the usage rows.
// Timings and failures cover Claude Code sessions; cost and cache figures cover every agent.

/// The two stretches of time an Insights page compares, worked out in the background when the logs or the range change.
@MainActor
final class InsightsModel: ObservableObject {
    @Published var now = TraceAgg()
    @Published var prev = TraceAgg()
    @Published var ready = false

    func update(_ traces: [TraceSummary], days: Int) async {
        let end = Date().addingTimeInterval(3600), mid = Date().addingTimeInterval(-Double(days) * 86_400), start = mid.addingTimeInterval(-Double(days) * 86_400)
        let (a, b) = await Task.detached(priority: .userInitiated) { (TraceAgg.compute(traces, from: mid, to: end), TraceAgg.compute(traces, from: start, to: mid)) }.value
        now = a; prev = b; ready = true
    }
}

private let dayOptions: [(String, Int)] = [("Last 7 days", 7), ("Last 14 days", 14)]

private struct InsightsBar: View {
    @EnvironmentObject var store: Store
    @Binding var days: Int
    let sessions: Int
    @State private var showCatalog = false
    var body: some View {
        HStack(spacing: 8) {
            PillMenu(dayOptions, selection: $days)
            Text("Compared with the \(days) days before").font(.bCaption).foregroundStyle(.secondary)
            Spacer()
            if let p = store.traceProgress { ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 60); Text("Reading logs \(p.done) of \(p.total)").font(.bCaption).foregroundStyle(.secondary) }
            else { Text("\(sessions) Claude Code sessions").font(.bCaption).foregroundStyle(.secondary) }
            Button("All metrics") { showCatalog = true }.controlSize(.small)
        }.sheet(isPresented: $showCatalog) { MetricsCatalogSheet() }
    }
}

private struct EmptyInsights: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Card { Text(store.traceProgress != nil ? "Reading your session logs. Numbers appear as they are read." : "No Claude Code sessions in this period yet.").foregroundStyle(.secondary) }
    }
}

private func mins(_ s: Double) -> String { s >= 3600 ? String(format: "%.1f hr", s / 3600) : s >= 90 ? String(format: "%.0f min", s / 60) : String(format: "%.0f s", s) }
private func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

/// "−14%" and whether that is good, for a number where lower is better (or higher, with `higherIsBetter`).
private func change(_ now: Double, _ prev: Double, higherIsBetter: Bool = false, enough: Bool) -> (String?, Bool?) {
    guard enough, prev > 0, now > 0 else { return (nil, nil) }
    let d = (now - prev) / prev * 100
    guard abs(d) >= 1 else { return ("0%", nil) }
    return (String(format: "%@%.0f%%", d > 0 ? "+" : "−", abs(d)), higherIsBetter ? d > 0 : d < 0)
}

/// One value per day across the range, scaled 0...1 for a sparkline or line chart.
private func series(_ a: TraceAgg, days: Int, _ pick: (([Double], [Double], [Double], Int)) -> Double?) -> [Double] {
    let today = Int(Date().timeIntervalSince1970 / 86_400)
    var vals: [Double] = [], last = 0.0
    for d in stride(from: today - days + 1, through: today, by: 1) {
        if let x = a.perDay[d], let v = pick((x.turn, x.firstEdit, x.session, x.prompts)) { last = v }
        vals.append(last)
    }
    let top = max(vals.max() ?? 1, 0.0001)
    return vals.map { $0 / top }
}

// MARK: Speed

struct SpeedView: View {
    @EnvironmentObject var store: Store
    @StateObject private var m = InsightsModel()
    @State private var days = 7

    var body: some View {
        let a = m.now, b = m.prev, enough = b.sessions >= 3
        Page {
            InsightsBar(days: $days, sessions: a.sessions)
            if a.sessions == 0 { EmptyInsights() } else {
                let sess = TraceAgg.median(a.sessionSeconds), sessPrev = TraceAgg.median(b.sessionSeconds)
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline(sess, sessPrev, enough)).font(.brand(24, .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("Working time only: from each of your prompts to the agent's last message. Time you were away is counted separately.").foregroundStyle(.secondary)
                }
                AdaptiveRow(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            CardTitle(title: "Where the time goes", note: "\(mins(a.activeSeconds + a.waitSeconds)) in \(a.sessions) sessions")
                            let parts = phases(a)
                            GeometryReader { g in
                                HStack(spacing: 2) { ForEach(parts, id: \.0) { p in Rectangle().fill(p.2).frame(width: max(0, (g.size.width - 6) * p.1)) } }.clipShape(RoundedRectangle(cornerRadius: 10))
                            }.frame(height: 40)
                            HStack(alignment: .top) {
                                ForEach(parts, id: \.0) { p in
                                    VStack(alignment: .leading, spacing: 1) { Text(pct(p.1)).font(.brand(15, .semibold)); Text(p.0).font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if let w = parts.last, w.1 > 0.15 { Note(text: "Agents sat finished for \(mins(a.waitSeconds)) waiting for your next prompt. A notification when an agent stops would give some of that back.") }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            CardTitle(title: "This period against the one before", note: enough ? nil : "Too little earlier history")
                            compare("Time to first edit", TraceAgg.median(a.firstEdit), TraceAgg.median(b.firstEdit), a.firstEdit.count, b.firstEdit.count, enough)
                            compare("Turn time, typical", TraceAgg.median(a.turnSeconds), TraceAgg.median(b.turnSeconds), a.turnSeconds.count, b.turnSeconds.count, enough)
                            compare("Turn time, slowest 5%", TraceAgg.percentile(a.turnSeconds, 0.95), TraceAgg.percentile(b.turnSeconds, 0.95), a.turnSeconds.count, b.turnSeconds.count, enough)
                            compare("Session working time", sess, sessPrev, a.sessionSeconds.count, b.sessionSeconds.count, enough)
                        }
                    }
                }
                KPIRow(items: [
                    kpi("Time to first edit", mins(TraceAgg.median(a.firstEdit)), TraceAgg.median(a.firstEdit), TraceAgg.median(b.firstEdit), enough, series(a, days: days) { $0.1.isEmpty ? nil : TraceAgg.median($0.1) }),
                    kpi("Turn time", mins(TraceAgg.median(a.turnSeconds)), TraceAgg.median(a.turnSeconds), TraceAgg.median(b.turnSeconds), enough, series(a, days: days) { $0.0.isEmpty ? nil : TraceAgg.median($0.0) }),
                    kpi("Session working time", mins(sess), sess, sessPrev, enough, series(a, days: days) { $0.2.isEmpty ? nil : TraceAgg.median($0.2) }),
                    kpi("Output speed", String(format: "%.0f tok/s", a.outputSpeed), a.outputSpeed, b.outputSpeed, enough, nil, higher: true),
                    kpi("Prompts a day", String(format: "%.0f", Double(a.prompts) / Double(days)), Double(a.prompts), Double(b.prompts), enough, series(a, days: days) { Double($0.3) }, higher: true),
                ])
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) { Text("Slowest turns").font(.bHeadline); Text("From one of your prompts to the agent's last message").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                        let top = max(a.slowest.first?.prompt.seconds ?? 1, 1)
                        ForEach(a.slowest.indices, id: \.self) { i in
                            let s = a.slowest[i]
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 1) { Text(s.prompt.text).font(.bBody.weight(.medium)).lineLimit(1); Text("\(s.session.project) · \(s.prompt.turns) replies").font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(AgentColor.conductor).frame(width: max(3, g.size.width * s.prompt.seconds / top)) } }.frame(width: 200, height: 6)
                                Text(mins(s.prompt.seconds)).font(.bBody).monospacedDigit().frame(width: 64, alignment: .trailing)
                            }.padding(.horizontal, 18).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
                        }
                    }
                }
                Text("Stalls inside a turn and queue time at the provider are not in the logs, so they are not shown.").font(.bCaption).foregroundStyle(.tertiary)
            }
        }
        .task(id: "\(store.traces.count)-\(days)") { await m.update(store.traces, days: days) }
    }

    private func headline(_ now: Double, _ prev: Double, _ enough: Bool) -> String {
        guard enough, prev > 0 else { return "A typical session takes \(mins(now)) of working time." }
        let d = (now - prev) / prev * 100
        if abs(d) < 3 { return "A typical session takes \(mins(now)) of working time, about the same as before." }
        return "A typical session takes \(mins(now)) of working time, \(String(format: "%.0f%%", abs(d))) \(d < 0 ? "less" : "more") than the \(days) days before."
    }

    private func phases(_ a: TraceAgg) -> [(String, Double, Color)] {
        let thinking = a.thinkingSeconds, tools = a.toolSeconds
        let writing = max(a.activeSeconds - thinking - tools, 0)
        let total = max(thinking + tools + writing + a.waitSeconds, 1)
        return [("Thinking", thinking / total, AgentColor.conductor), ("Writing and reading", writing / total, AgentColor.claude), ("Running tools", tools / total, AgentColor.codex), ("Waiting on you", a.waitSeconds / total, Brand.reclaim)]
    }

    private func kpi(_ title: String, _ value: String, _ now: Double, _ prev: Double, _ enough: Bool, _ spark: [Double]?, higher: Bool = false) -> KPI {
        let c = change(now, prev, higherIsBetter: higher, enough: enough)
        return KPI(title: title, value: value, prior: enough && prev > 0 ? "before: \(title.contains("speed") ? String(format: "%.0f tok/s", prev) : title.contains("day") ? String(format: "%.0f", prev / Double(days)) : mins(prev))" : nil, delta: c.0, good: c.1, spark: spark)
    }

    private func compare(_ label: String, _ now: Double, _ prev: Double, _ n: Int, _ pn: Int, _ enough: Bool) -> some View {
        let c = change(now, prev, enough: enough)
        return HStack(spacing: 12) {
            Text(label).font(.bBody.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) { Text(enough ? mins(prev) : "–").monospacedDigit(); Text("\(pn) samples").font(.bCaption).foregroundStyle(.tertiary) }.frame(width: 80, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 0) { Text(mins(now)).monospacedDigit(); Text("\(n) samples").font(.bCaption).foregroundStyle(.tertiary) }.frame(width: 80, alignment: .trailing)
            Group { if let t = c.0 { Delta(text: t, good: c.1) } else { Text("–").foregroundStyle(.tertiary) } }.frame(width: 60, alignment: .trailing)
        }.padding(.vertical, 5).overlay(alignment: .top) { Divider() }
    }
}

// MARK: Reliability

struct ReliabilityView: View {
    @EnvironmentObject var store: Store
    @StateObject private var m = InsightsModel()
    @State private var days = 7
    private let kinds: [(String, Color)] = [("Shell commands", Brand.destructive), ("Other tools", Brand.reclaim), ("Declined by you", Brand.merged), ("API errors", AgentColor.pi)]

    var body: some View {
        let a = m.now, b = m.prev, enough = b.sessions >= 3
        Page {
            InsightsBar(days: $days, sessions: a.sessions)
            if a.sessions == 0 { EmptyInsights() } else {
                KPIRow(items: [
                    kpi("Failed tool calls", pct(a.failRate), a.failRate, b.failRate, enough, "\(a.toolErrors) of \(a.toolCalls)"),
                    kpi("Loops caught", "\(a.loops.count)", Double(a.loops.count), Double(b.loops.count), enough, "same failure repeated"),
                    kpi("Declined by you", "\(a.denials)", Double(a.denials), Double(b.denials), enough, "commands and edits"),
                    kpi("Hook failures", "\(a.hookErrors)", Double(a.hookErrors), Double(b.hookErrors), enough, "of \(a.hookRuns) runs"),
                    kpi("API errors", "\(a.apiErrors)", Double(a.apiErrors), Double(b.apiErrors), enough, "including retries"),
                    kpi("Commands that failed", "\(a.cmdFails.count)", Double(a.cmdFails.count), Double(b.cmdFails.count), enough, "different commands"),
                ])
                AdaptiveRow(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            CardTitle(title: "Failures per day", note: "By kind")
                            StackedBars(data: perDay(a), colors: kinds.map(\.1))
                            Legend(items: kinds)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            CardTitle(title: "What failed", note: "\(days) days")
                            let totals = (0..<4).map { k in a.errorDays.values.reduce(0) { $0 + $1[k] } }, top = Double(max(totals.max() ?? 1, 1))
                            ForEach(0..<4, id: \.self) { k in HBar(label: kinds[k].0, value: "\(totals[k])", fraction: Double(totals[k]) / top, color: kinds[k].1) }
                        }
                    }.frame(width: 360)
                }
                AdaptiveRow(spacing: 14) {
                    Card(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 1) { Text("Loops caught").font(.bHeadline); Text("The same command or edit repeated with no progress").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                            if a.loops.isEmpty { Text("No loops in this period.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 16) }
                            ForEach(a.loops.prefix(6).indices, id: \.self) { i in
                                let l = a.loops[i]
                                HStack(spacing: 12) {
                                    Dot(tone: .red)
                                    VStack(alignment: .leading, spacing: 2) { Text(l.loop.what).font(.bBody.weight(.medium)).lineLimit(1); Text(l.loop.detail).font(.code(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                    Spacer(minLength: 8)
                                    Text("\(l.loop.count)×").font(.bBody.weight(.semibold)).monospacedDigit()
                                }.padding(.horizontal, 18).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
                            }
                        }
                    }
                    Card(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 1) { Text("Commands that fail most").font(.bHeadline); Text("Run at least 5 times. Worth fixing once so every session benefits.").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                            let cmds = failing(a)
                            if cmds.isEmpty { Text("No command failed repeatedly.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 16) }
                            ForEach(cmds, id: \.0) { c in
                                HStack(spacing: 12) {
                                    Text(c.0).font(.code(12)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(c.1) runs").font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                                    Text("\(c.2)%").font(.bBody.weight(.semibold)).monospacedDigit().foregroundStyle(c.2 >= 15 ? Brand.destructive : Brand.reclaimText).frame(width: 44, alignment: .trailing)
                                }.padding(.horizontal, 18).padding(.vertical, 11).overlay(alignment: .top) { Divider() }
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(store.traces.count)-\(days)") { await m.update(store.traces, days: days) }
    }

    private func kpi(_ t: String, _ v: String, _ now: Double, _ prev: Double, _ enough: Bool, _ note: String) -> KPI {
        let c = change(now, prev, enough: enough)
        return KPI(title: t, value: v, prior: note, delta: c.0, good: c.1)
    }
    private func perDay(_ a: TraceAgg) -> [[Double]] {
        let today = Int(Date().timeIntervalSince1970 / 86_400)
        return stride(from: today - days + 1, through: today, by: 1).map { d in (a.errorDays[d] ?? [0, 0, 0, 0]).map(Double.init) }
    }
    private func failing(_ a: TraceAgg) -> [(String, Int, Int)] {
        a.cmdFails.compactMap { k, f -> (String, Int, Int)? in
            guard let r = a.cmdRuns[k], r >= 5 else { return nil }
            return (k, r, f * 100 / r)
        }.sorted { ($0.2, $0.1) > ($1.2, $1.1) }.prefix(6).map { $0 }
    }
}

// MARK: Context and cache

struct ContextView: View {
    @EnvironmentObject var store: Store
    @StateObject private var m = InsightsModel()
    @State private var days = 7
    @State private var cache: [(AgentTool, Int, Double)] = []      // agent, hit rate %, dollars saved

    var body: some View {
        let a = m.now, b = m.prev, enough = b.sessions >= 3
        let peak = TraceAgg.median(a.peak.map(Double.init)), peakPrev = TraceAgg.median(b.peak.map(Double.init))
        Page {
            InsightsBar(days: $days, sessions: a.sessions)
            if a.sessions == 0 { EmptyInsights() } else {
                KPIRow(items: [
                    kpi("Typical peak context", String(format: "%.0fK", peak / 1000), peak, peakPrev, enough, "tokens in one request"),
                    kpi("Sessions over 150K", "\(a.bigContext)", Double(a.bigContext), Double(b.bigContext), enough, "of \(a.sessions)"),
                    kpi("Compactions", "\(a.compactions)", Double(a.compactions), Double(b.compactions), enough, "old turns summarized"),
                    KPI(title: "Cache hit rate", value: totalRate.map { "\($0)%" } ?? "–", prior: "all agents, \(days) days"),
                    KPI(title: "Saved by the cache", value: String(format: "$%.2f", cache.reduce(0) { $0 + $1.2 }), prior: "against uncached prices"),
                ])
                AdaptiveRow(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            CardTitle(title: "How the context grows, reply by reply", note: "Your \(curves.count) longest recent sessions")
                            LineChart(lines: curves, height: 190)
                            Note(text: a.bigContext > 0 ? "\(a.bigContext) of \(a.sessions) sessions passed 150K tokens. Each reply after that re-sends the whole history, so long sessions cost more per turn." : "No session passed 150K tokens in this period.")
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            CardTitle(title: "Cache by agent", note: "Cached share of prompt tokens")
                            if cache.isEmpty { Text("No usage in this period.").font(.bCaption).foregroundStyle(.secondary) }
                            ForEach(cache, id: \.0) { c in HBar(label: Advisor.name(c.0), value: "\(c.1)%  saved \(String(format: "$%.2f", c.2))", fraction: Double(c.1) / 100, color: AgentColor.of(c.0.rawValue)) }
                        }
                    }.frame(width: 360)
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) { Text("Habits that cost context").font(.bHeadline); Text("Counted in your Claude Code sessions").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                        habit("Replying after more than 5 minutes", "The prompt cache has usually expired, so the next turn pays full price.", a.idleBreaks)
                        habit("Switching model inside a session", "A different model starts with an empty cache.", a.modelSwitches)
                        habit("Running until the context is compacted", "The session got long enough that old turns had to be summarized.", a.compactions)
                    }
                }
            }
        }
        .task(id: "\(store.traces.count)-\(store.usage.count)-\(days)") {
            await m.update(store.traces, days: days)
            let rows = store.usage, d = days
            cache = await Task.detached { Self.cacheStats(rows, days: d) }.value
        }
    }

    private var totalRate: Int? { cache.isEmpty ? nil : cache.map(\.1).reduce(0, +) / cache.count }
    private var curves: [LineChart.Line] {
        let top = Double(max(m.now.peak.max() ?? 1, 1))
        let pick = store.traces.filter { $0.context.count >= 8 }.sorted { $0.context.count > $1.context.count }.prefix(4)
        let cols = [AgentColor.claude, AgentColor.codex, AgentColor.conductor, AgentColor.superset]
        return pick.enumerated().map { i, t in LineChart.Line(values: t.context.map { min(1, Double($0) / top) }, color: cols[i % 4]) }
    }
    private func kpi(_ t: String, _ v: String, _ now: Double, _ prev: Double, _ enough: Bool, _ note: String) -> KPI {
        let c = change(now, prev, enough: enough)
        return KPI(title: t, value: v, prior: note, delta: c.0, good: c.1)
    }
    private func habit(_ t: String, _ s: String, _ n: Int) -> some View {
        HStack(spacing: 12) {
            Dot(tone: n > 0 ? .amber : .gray)
            VStack(alignment: .leading, spacing: 1) { Text(t).font(.bBody.weight(.medium)); Text(s).font(.bCaption).foregroundStyle(.secondary) }
            Spacer()
            Text("\(n) time\(n == 1 ? "" : "s")").font(.bBody).monospacedDigit()
        }.padding(.horizontal, 18).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
    }

    /// Cached share of prompt tokens per agent, and what those tokens would have cost uncached (a cache read is billed at a tenth).
    nonisolated static func cacheStats(_ rows: [UsageRow], days: Int) -> [(AgentTool, Int, Double)] {
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
        var acc: [AgentTool: (read: Int, prompt: Int, saved: Double)] = [:]
        for r in rows where r.day >= from {
            let price: Double = switch r.family { case "Haiku": 1; case "Sonnet": 3; case "Codex": 1.25; default: 5 }
            var x = acc[r.agent] ?? (0, 0, 0)
            x.read += r.cacheRead; x.prompt += r.input + r.cacheRead + r.cacheWrite
            x.saved += Double(r.cacheRead) * price * 0.9 / 1e6
            acc[r.agent] = x
        }
        return acc.filter { $0.value.prompt > 0 }.map { ($0.key, $0.value.read * 100 / $0.value.prompt, $0.value.saved) }.sorted { $0.2 > $1.2 }
    }
}

// MARK: Advisor

struct AdvisorView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    @Environment(\.pageWidth) private var pageWidth
    private let agents = AgentTool.allCases

    var body: some View {
        let adv = store.advice
        Page {
            VStack(alignment: .leading, spacing: 8) {
                Text(headline(adv)).font(.brand(24, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("From \(adv.sessions) sessions with a cost in the last 30 days, sorted by the words in their first prompt. An agent needs \(Advisor.minSessions) sessions of a kind before it is compared. Costs are estimates at list prices.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    CardTitle(title: "Which agent to use for which task", note: "Sessions, typical cost and typical length. Highlighted is the cheapest with enough history.").padding(.horizontal, 20).padding(.vertical, 14)
                    Divider()
                    HStack(spacing: 10) {
                        Text("Kind of task").frame(width: 180, alignment: .leading); Text("Sessions").frame(width: 60, alignment: .trailing)
                        ForEach(agents, id: \.self) { Text(Advisor.name($0)).frame(maxWidth: .infinity, alignment: .leading) }
                        if pageWidth >= 980 { Text("Suggestion").frame(width: 200, alignment: .leading) }
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
                    if adv.rows.isEmpty { Divider(); Text(store.usageLoading ? "Reading sessions…" : "Not enough sessions yet.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                    ForEach(adv.rows) { r in
                        Divider()
                        HStack(spacing: 10) {
                            Text(r.kind).font(.bBody.weight(.medium)).frame(width: 180, alignment: .leading)
                            Text("\(r.total)").font(.bCaption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                            ForEach(agents, id: \.self) { a in
                                VStack(alignment: .leading, spacing: 1) {
                                    if let c = r.cells[a], c.n >= Advisor.minSessions {
                                        Text(String(format: "$%.2f", c.cost)).font(.brand(15, .semibold)).foregroundStyle(a == r.best ? Brand.primaryText : .primary)
                                        Text("\(c.n) sessions · \(mins(c.minutes * 60))").font(.bCaption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Too few").font(.bBody).foregroundStyle(.tertiary); Text("\(r.cells[a]?.n ?? 0) sessions").font(.bCaption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(a == r.best ? Brand.primaryTint : Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            if pageWidth >= 980 { Text(r.tip).font(.bCaption).foregroundStyle(.secondary).frame(width: 200, alignment: .leading) }
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    CardTitle(title: "Harness tools: what earns its place", note: "MCP servers, skills and hooks in Claude Code, last 30 days").padding(.horizontal, 20).padding(.vertical, 14)
                    let rows = harness(adv.agg)
                    if rows.isEmpty { Divider(); Text("No servers, skills or hooks found.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                    ForEach(rows.indices, id: \.self) { i in
                        Divider()
                        ListRow(title: rows[i].0, subtitle: rows[i].1) { EmptyView() } trail: {
                            HStack(spacing: 14) {
                                Text(rows[i].2).font(.bBody).monospacedDigit().frame(width: 90, alignment: .trailing)
                                Tag(text: rows[i].3, tone: rows[i].4).frame(width: 160, alignment: .leading)
                            }
                        }
                    }
                }
            }
            HStack { Button("Open MCP servers") { nav.open(.agents, .mcp) }; Button("Open hooks") { nav.open(.agents, .hooks) }; Spacer() }
        }
    }

    private func headline(_ a: Advice) -> String {
        if a.monthly >= 1 { return "Using the cheapest agent for each kind of task would save about \(String(format: "$%.0f", a.monthly)) a month." }
        if a.rows.contains(where: { $0.best != nil }) { return "You already use the cheapest agent for the kinds of task there is enough history to compare." }
        return "There is not enough history yet to compare agents on the same kind of task."
    }

    private func harness(_ a: TraceAgg) -> [(String, String, String, String, Tone)] {
        var out: [(String, String, String, String, Tone)] = []
        for s in store.mcpServers {
            let calls = s.agent == "Claude Code" ? (a.mcp[s.name] ?? 0) : -1
            out.append((s.name, "MCP server · \(s.agent) · \(s.scope)", calls < 0 ? "–" : "\(calls) calls", calls < 0 ? "Not measured" : calls == 0 ? "Unused in 30 days" : "In use", calls < 0 ? .gray : calls == 0 ? .amber : .blue))
        }
        for (k, v) in a.skills.sorted(by: { $0.value > $1.value }).prefix(6) { out.append((k, "Skill · Claude Code", "\(v) loads", "In use", .blue)) }
        for h in store.hooks {
            let fails = a.hookFails.first { $0.key.contains(h.command.prefix(30)) }?.value ?? 0
            let runs = a.hooks.first { $0.key.contains(h.command.prefix(30)) }?.value
            out.append((String(h.command.prefix(70)), "Hook · \(h.event)" + (h.matcher.isEmpty ? "" : " · \(h.matcher)"), runs.map { "\($0) runs" } ?? "–", fails > 0 ? "Failed \(fails) times" : "Healthy", fails > 0 ? .amber : .blue))
        }
        return out
    }
}
