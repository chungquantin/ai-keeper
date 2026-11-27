import SwiftUI

// Today: one page. A sentence says what matters, three charts back it up, and what needs you sits next to what happened today.

struct TodayHome: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    @EnvironmentObject var basket: Basket

    var body: some View {
        let items = TodayData.attention(store)
        Page {
            headline(items)
            AdaptiveRow(spacing: 14, minChild: 270) {
                ReclaimTile()
                SpendTile()
                RunningTile()
            }
            AdaptiveRow(spacing: 14, minChild: 420) {
                NeedsCard(items: items).frame(maxWidth: .infinity)
                TimelineCard().frame(width: 440)
            }
        }
    }

    // MARK: Headline

    private func headline(_ items: [AttentionItem]) -> some View {
        let n = items.count
        let words = ["Nothing", "One thing", "Two things", "Three things", "Four things", "Five things"]
        let lead = n == 0 ? "Nothing needs you." : (n < words.count ? words[n] : "\(n) things") + (n == 1 ? " needs you." : " need you.")
        let safe = store.stats.safeBytes
        let spent = String(format: "$%.2f", store.spentToday)
        let strong = Color.primary, quiet = Brand.mutedForeground
        let line: Text
        if store.hasData && safe > 0 {
            line = Text(lead + " ").foregroundColor(quiet)
                + Text("\(safe.bytesString) can go").foregroundColor(strong)
                + Text(" without losing work, and ").foregroundColor(quiet)
                + Text("you have spent \(spent)").foregroundColor(strong)
                + Text(" so far today.").foregroundColor(quiet)
        } else {
            line = Text(lead + " ").foregroundColor(quiet)
                + Text("You have spent \(spent)").foregroundColor(strong)
                + Text(" so far today.").foregroundColor(quiet)
        }
        return line.font(.system(size: 30, weight: .semibold)).tracking(-0.5).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 980, alignment: .leading).padding(.bottom, 4)
    }
}

// MARK: Reclaim

private struct Donut: View {
    let parts: [(Double, Color)]
    var lineWidth: CGFloat = 15
    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
        ZStack {
            Circle().stroke(Brand.muted, lineWidth: lineWidth)
            ForEach(parts.indices, id: \.self) { i in
                if parts[i].0 > 0 {
                    let start = parts[..<i].reduce(0) { $0 + $1.0 } / total
                    let end = start + parts[i].0 / total
                    let gap = 0.008
                    Circle().trim(from: start + gap, to: max(start + gap, end - gap))
                        .stroke(parts[i].1, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)).rotationEffect(.degrees(-90))
                }
            }
        }.padding(lineWidth / 2)
    }
}

private struct ReclaimTile: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    @EnvironmentObject var basket: Basket

    var body: some View {
        let st = store.stats
        let safe = st.safeBytes, parts = safe.byteParts
        let tiers: [(Tier, Int64)] = [(.rebuildable, st.rebuildBytes), (.onRemote, st.remoteBytes), (.onlyHere, st.onlyHereBytes)]
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Safe to reclaim").font(.bCaption2).foregroundStyle(.secondary); Spacer(); if safe > 0 { Tag(text: "Clear now", tone: .green) } }
                HStack(spacing: 18) {
                    ZStack {
                        Donut(parts: tiers.map { (Double($0.1), $0.0.color) })
                        VStack(spacing: 0) {
                            Text(store.hasData ? parts.number : "—").font(.figure(24)).monospacedDigit()
                            Text(parts.unit.isEmpty ? " " : "\(parts.unit) safe").font(.bCaption2).foregroundStyle(.secondary)
                        }
                    }.frame(width: 124, height: 124)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(tiers, id: \.0.id) { t, b in
                            HStack(spacing: 8) {
                                Circle().fill(t.color).frame(width: 7, height: 7)
                                Text(t.title).font(.bCaption)
                                Spacer(minLength: 4)
                                Text(b.bytesString).font(.bCaption.weight(.semibold)).monospacedDigit()
                            }
                        }
                        if st.onlyHereBytes > 0 { Text("The amber part needs a look, so it is not in the \(safe.bytesString).").font(.bCaption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(store.hasData ? "\(st.managedBytes.bytesString) in agent workspaces" : "Measuring your workspaces…").font(.bCaption).foregroundStyle(.secondary)
                    Spacer()
                    if safe == 0 && store.hasData && !store.isScanning {
                        Button("Review") { nav.open(.cleanup, .review) }.controlSize(.small)
                    } else {
                        Button("Reclaim \(safe.bytesString)") { basket.resetToSafe(); nav.showBasket = true }
                            .buttonStyle(.brandProminent).controlSize(.small).disabled(safe == 0 || store.isScanning)
                    }
                }
            }
        }
    }
}

// MARK: Spend

private struct DaySpend: Identifiable { let day: Date; var by: [AgentTool: Double]; var id: Date { day }; var total: Double { by.values.reduce(0, +) } }

private struct SpendTile: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    @State private var week: [DaySpend] = []

    var body: some View {
        let today = week.last?.total ?? 0, yesterday = week.count >= 2 ? week[week.count - 2].total : 0
        let agents = Array(Set(week.flatMap { $0.by.keys })).sorted { a, b in week.reduce(0) { $0 + ($1.by[a] ?? 0) } > week.reduce(0) { $0 + ($1.by[b] ?? 0) } }
        let spent = store.spentToday
        let whole = Int(spent), cents = Int(((spent - Double(whole)) * 100).rounded())
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Spent, last 7 days").font(.bCaption2).foregroundStyle(.secondary); Spacer(); if yesterday > 0 { Tag(text: "\(Int((today / yesterday * 100).rounded()))% of yesterday", tone: .gray) } }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("$\(whole)").font(.figure(30)).monospacedDigit()
                    Text(String(format: ".%02d", cents)).font(.figure(15)).foregroundStyle(.secondary).monospacedDigit()
                    Text("today").font(.bCaption).foregroundStyle(.secondary).padding(.leading, 6)
                }
                SpendBars(days: week, agents: agents).frame(height: 84)
                Spacer(minLength: 0)
                HStack {
                    Legend(items: agents.prefix(3).map { a in ("\(a.rawValue) \(String(format: "$%.0f", week.reduce(0) { $0 + ($1.by[a] ?? 0) }))", AgentColor.of(a.rawValue)) })
                    Spacer(minLength: 0)
                    Button("Budgets") { nav.open(.agents, .budgets) }.controlSize(.small)
                }
            }
        }
        .task(id: store.usage.count) {
            let rows = store.usage
            week = await Task.detached(priority: .utility) { Self.compute(rows) }.value
        }
    }

    private nonisolated static func compute(_ rows: [UsageRow]) -> [DaySpend] {
        let cal = Calendar.current, start = cal.startOfDay(for: Date())
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0 - 6, to: start) }
        var out = days.map { DaySpend(day: $0, by: [:]) }
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, $0) })
        for r in rows {
            guard let i = index[cal.startOfDay(for: r.day)] else { continue }
            out[i].by[r.agent, default: 0] += r.cost
        }
        return out
    }
}

private struct SpendBars: View {
    let days: [DaySpend]
    let agents: [AgentTool]
    var body: some View {
        let peak = max(days.map(\.total).max() ?? 0, 0.01)
        VStack(spacing: 4) {
            GeometryReader { g in
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(days) { d in
                        VStack(spacing: 1) {
                            ForEach(agents.reversed(), id: \.self) { a in
                                if let v = d.by[a], v > 0 { Rectangle().fill(AgentColor.of(a.rawValue)).frame(height: max(2, (g.size.height - 2) * v / peak)) }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .frame(maxWidth: .infinity).opacity(d.id == days.last?.id ? 1 : 0.8)
                    }
                }.frame(maxHeight: .infinity, alignment: .bottom)
            }
            HStack {
                Text(days.first.map { $0.day.formatted(.dateTime.weekday(.abbreviated)) } ?? "").font(.bCaption2).foregroundStyle(.secondary)
                Spacer()
                Text("Today").font(.bCaption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Running

private struct RunningTile: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState

    var body: some View {
        let live = store.agents.filter { $0.kind != .mcp }
        let working = live.filter { $0.state == .working }.count, waiting = live.filter { $0.state == .needsInput }.count
        let window: TimeInterval = 12 * 3600
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Running, last 12 hours").font(.bCaption2).foregroundStyle(.secondary)
                    Spacer()
                    if waiting > 0 { Tag(text: "\(waiting) waiting", tone: .amber) } else if working > 0 { Tag(text: "\(working) working", tone: .blue) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(live.count)").font(.figure(30)).monospacedDigit()
                    Text(live.count == 1 ? "agent" : "agents").font(.figure(15)).foregroundStyle(.secondary)
                }
                VStack(spacing: 7) {
                    if live.isEmpty { Text("No agents are running.").font(.bCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(live.prefix(5)) { a in
                        HStack(spacing: 10) {
                            Text(store.workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? a.kind.rawValue)
                                .font(.bCaption).foregroundStyle(.secondary).lineLimit(1).frame(width: 96, alignment: .leading)
                            GeometryReader { g in
                                let f = min(a.elapsed, window) / window
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Brand.muted)
                                    Capsule().fill(a.state == .needsInput ? Brand.reclaim : AgentColor.of(a.kind.rawValue).opacity(a.state == .idle ? 0.45 : 1))
                                        .frame(width: max(6, g.size.width * f)).offset(x: g.size.width * (1 - f))
                                }
                            }.frame(height: 10)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(live.count > working + waiting ? "\(live.count - working - waiting) idle" : " ").font(.bCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open sessions") { nav.open(.sessions, .live) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: Needs you and Worth changing

private struct NeedsCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    let items: [AttentionItem]

    private func symbol(_ id: String) -> String {
        if id.hasPrefix("agent") { return "bolt.horizontal" }
        switch id { case "ws": return "trash"; case "skills": return "shield"; case "budget": return "dollarsign.circle"; case "loops": return "arrow.triangle.2.circlepath"; default: return "circle" }
    }

    var body: some View {
        let tips = store.advice.tips
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("Needs you").font(.bHeadline); Spacer(); if !items.isEmpty { Tag(text: "\(items.count) thing\(items.count == 1 ? "" : "s")", tone: .amber) } }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                if items.isEmpty { Text("Nothing needs you right now.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 14) }
                ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { i, it in
                    HStack(spacing: 14) {
                        TierChip(symbol: symbol(it.id), tone: it.tone, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.title).font(.bBody.weight(.semibold)).lineLimit(1)
                            Text(it.subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if i == 0 { Button(it.action) { it.go(nav, store) }.buttonStyle(.brandProminent).controlSize(.small) } else { Button(it.action) { it.go(nav, store) }.controlSize(.small) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 11).overlay(alignment: .top) { Divider() }
                }
                if let tip = tips.first {
                    HStack { Text("Worth changing").font(.bHeadline); Spacer(); Tag(text: "\(tips.count) suggestion\(tips.count == 1 ? "" : "s")", tone: .violet) }
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8).overlay(alignment: .top) { Divider() }
                    HStack(spacing: 14) {
                        TierChip(symbol: "bolt", tone: .violet, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tip.title).font(.bBody.weight(.semibold)).lineLimit(1)
                            Text(tip.body).font(.bCaption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button("See all") { nav.open(.insights, .advisor) }.controlSize(.small)
                    }.padding(.horizontal, 20).padding(.bottom, 12)
                }
                Spacer(minLength: 0)
                Text(store.lastScan.map { "Scanned \($0.formatted(.relative(presentation: .named))). Read from your own logs and folders; nothing leaves this Mac." } ?? "Not scanned yet.")
                    .font(.bCaption2).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 6)
            }
        }
    }
}

// MARK: Today so far

private struct TimelineCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState

    var body: some View {
        let start = Calendar.current.startOfDay(for: Date())
        let today = store.sessions.filter { $0.last >= start }
        let shown = today.newest(6)
        let top = max(shown.map(\.cost).max() ?? 0, 0.01)
        let live = Set(store.agents.compactMap(\.cwd))
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Today so far", note: today.isEmpty ? nil : "\(today.count) session\(today.count == 1 ? "" : "s") · \(String(format: "$%.2f", store.spentToday))")
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                if shown.isEmpty { Text("No sessions yet today.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8) }
                ForEach(shown) { s in
                    let color = AgentColor.of(s.agent.rawValue)
                    let isLive = live.contains(s.cwd)
                    HStack(spacing: 12) {
                        Text(isLive ? "Now" : s.last.formatted(date: .omitted, time: .shortened)).font(.bCaption2).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Circle().fill(color).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title.isEmpty ? s.project : s.title).font(.bBody.weight(.semibold)).lineLimit(1)
                            Text("\(isLive ? "Working" : "Finished") · \(s.agent.rawValue) · \(s.project)").font(.bCaption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(String(format: "$%.2f", s.cost)).font(.bCaption).monospacedDigit()
                            GeometryReader { g in
                                ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(color).frame(width: max(3, g.size.width * s.cost / top)) }
                            }.frame(width: 58, height: 4)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                }
                Spacer(minLength: 0)
                Button("Open all sessions") { nav.open(.sessions, .history) }.buttonStyle(.link).padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }
}
