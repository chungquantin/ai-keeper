import SwiftUI

// Today: one page. A sentence says what matters, three charts back it up, and what needs you sits next to what happened today.

struct TodayHome: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket

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
        let lead = n == 0 ? "All clear" : (n < words.count ? words[n] : "\(n) things") + (n == 1 ? " needs you" : " need you")
        return Text(lead).font(.system(size: 30, weight: .semibold)).tracking(-0.5).padding(.bottom, 2)
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
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(Basket.self) private var basket

    var body: some View {
        let st = store.stats
        let safe = st.safeBytes, parts = safe.byteParts
        let tiers: [(Tier, Int64)] = [(.rebuildable, st.rebuildBytes), (.onRemote, st.remoteBytes)]
        let scan: String = store.isScanning ? "Scanning" : store.lastScan.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) } ?? "Not scanned"
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Safe to reclaim").font(.bCaption2).foregroundStyle(.secondary); Spacer(); Text(scan).font(.bCaption2).foregroundStyle(.tertiary) }
                HStack(spacing: 18) {
                    ZStack {
                        Donut(parts: tiers.map { (Double($0.1), $0.0.color) })
                        VStack(spacing: 0) {
                            Text(store.hasData ? parts.number : "—").font(.figure(24)).monospacedDigit()
                            Text(parts.unit.isEmpty ? " " : parts.unit).font(.bCaption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 116, height: 116)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Safe to reclaim \(safe.bytesString). " + tiers.map { "\($0.0.title) \($0.1.bytesString)" }.joined(separator: ", "))
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(tiers, id: \.0.id) { t, b in
                            HStack(spacing: 8) {
                                Circle().fill(t.color).frame(width: 7, height: 7)
                                Text(t.title).font(.bCaption).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(b.bytesString).font(.bCaption.weight(.semibold)).monospacedDigit().lineLimit(1)
                            }
                        }
                        if st.onlyHereBytes > 0 {
                            HStack(spacing: 8) {
                                Circle().strokeBorder(Tier.onlyHere.color, lineWidth: 1.5).frame(width: 7, height: 7)
                                Text("Needs a look").font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(st.onlyHereBytes.bytesString).font(.bCaption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.top, 8).overlay(alignment: .top) { Divider() }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button { Task { await store.rescan() } } label: {
                        if store.isScanning { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) } else { Image(systemName: "arrow.clockwise").frame(width: 14, height: 14) }
                    }.controlSize(.small).disabled(store.isScanning).help("Rescan (⌘R)").accessibilityLabel("Rescan")
                    Spacer(minLength: 0)
                    if safe == 0 && store.hasData && !store.isScanning {
                        Button("Review") { nav.go(.review) }.controlSize(.small).fixedSize()
                    } else {
                        Button("Reclaim \(safe.bytesString)") { basket.resetToSafe(); nav.showBasket = true }
                            .buttonStyle(.brandProminent).controlSize(.small).fixedSize().disabled(safe == 0 || store.isScanning)
                    }
                }
            }
        }
    }
}

// MARK: Spend

private struct DaySpend: Identifiable { let day: Date; var by: [AgentTool: Double]; var id: Date { day }; var total: Double { by.values.reduce(0, +) } }

private struct SpendTile: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var week: [DaySpend] = []

    var body: some View {
        let today = week.last?.total ?? 0, yesterday = week.count >= 2 ? week[week.count - 2].total : 0
        let agents = Array(Set(week.flatMap { $0.by.keys })).sorted { a, b in week.reduce(0) { $0 + ($1.by[a] ?? 0) } > week.reduce(0) { $0 + ($1.by[b] ?? 0) } }
        let spent = store.spentToday
        let whole = Int(spent), cents = Int(((spent - Double(whole)) * 100).rounded())
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Last 7 days").font(.bCaption2).foregroundStyle(.secondary); Spacer(); if yesterday > 0 { let d = Int(((today - yesterday) / yesterday * 100).rounded()); Tag(text: (d >= 0 ? "+" : "−") + "\(abs(d))% vs yesterday", tone: .gray) } }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("$\(whole)").font(.figure(30)).monospacedDigit()
                    Text(String(format: ".%02d", cents)).font(.figure(15)).foregroundStyle(.secondary).monospacedDigit()
                    Text("today").font(.bCaption).foregroundStyle(.secondary).padding(.leading, 6)
                }
                SpendBars(days: week, agents: agents).frame(height: 84)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Spend over the last 7 days: " + week.map { String(format: "$%.0f", $0.total) }.joined(separator: ", "))
                Spacer(minLength: 0)
                HStack {
                    Legend(items: agents.prefix(2).map { a in ("\(a.rawValue.capitalized) \(Self.money(week.reduce(0) { $0 + ($1.by[a] ?? 0) }))", AgentColor.of(a.rawValue)) })
                    Spacer(minLength: 0)
                    Button("Budgets") { nav.open(.agents, .budgets) }.controlSize(.small).fixedSize()
                }
            }
        }
        .task(id: store.usage.count) {
            let rows = store.usage
            week = await Task.detached(priority: .utility) { Self.compute(rows) }.value
        }
    }

    private static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

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
    /// 41m, 3h 8m: no seconds once it has run for a minute.
    private static func span(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 1 ? "just now" : m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav

    var body: some View {
        let live = store.agents.filter { $0.kind != .mcp }
        let working = live.filter { $0.state == .working }.count, waiting = live.filter { $0.state == .needsInput }.count
        let window: TimeInterval = 12 * 3600
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agents").font(.bCaption2).foregroundStyle(.secondary)
                    Spacer()
                    if waiting > 0 { Tag(text: "\(waiting) waiting", tone: .amber) } else if working > 0 { Tag(text: "\(working) working", tone: .blue) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(live.count)").font(.figure(30)).monospacedDigit()
                    Text(live.count == 1 ? "agent" : "agents").font(.figure(15)).foregroundStyle(.secondary)
                }
                VStack(spacing: 9) {
                    if live.isEmpty { Text("No agents are running.").font(.bCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(live.prefix(5)) { a in
                        HStack(spacing: 8) {
                            Circle().fill(a.state == .needsInput ? Brand.reclaim : AgentColor.of(a.kind.rawValue).opacity(a.state == .idle ? 0.4 : 1)).frame(width: 7, height: 7)
                            Text(store.workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? a.kind.rawValue)
                                .font(.bCaption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(a.state == .needsInput ? "Waiting" : Self.span(a.elapsed)).font(.bCaption2).foregroundStyle(a.state == .needsInput ? Brand.reclaimText : Color.secondary).monospacedDigit().fixedSize()
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(live.count > working + waiting ? "\(live.count - working - waiting) idle" : " ").font(.bCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open sessions") { nav.open(.sessions, .live) }.controlSize(.small).fixedSize()
                }
            }
        }
    }
}

// MARK: Needs you and Worth changing

private struct NeedsCard: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
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
                            Text(it.subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if i == 0 { Button(it.action) { it.go(nav, store) }.buttonStyle(.brandProminent).controlSize(.small).fixedSize() } else { Button(it.action) { it.go(nav, store) }.controlSize(.small).fixedSize() }
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
                            Text(tip.caption.isEmpty ? tip.body : "\(tip.value) \(tip.caption)").font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("See all") { nav.open(.insights, .advisor) }.controlSize(.small).fixedSize()
                    }.padding(.horizontal, 20).padding(.bottom, 12)
                }
                Spacer(minLength: 0)
            }.padding(.bottom, 6)
        }
    }
}

// MARK: Today so far

private struct TimelineCard: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var today: [SessionInfo] = []

    var body: some View {
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
                        Circle().fill(color).frame(width: 9, height: 9).overlay { if isLive { Circle().strokeBorder(color.opacity(0.35), lineWidth: 3).frame(width: 15, height: 15) } }.frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title.isEmpty ? s.project : s.title).font(.bBody.weight(.semibold)).lineLimit(1)
                            Text((isLive ? "Working" : s.last.formatted(date: .omitted, time: .shortened)) + " · \(s.project)").font(.bCaption2).foregroundStyle(.secondary).lineLimit(1)
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
        // Sessions can number in the tens of thousands: filter them off the main thread, and only when they change.
        .task(id: store.sessions.count) {
            let all = store.sessions, start = Calendar.current.startOfDay(for: Date())
            today = await Task.detached(priority: .utility) { all.filter { $0.last >= start } }.value
        }
    }
}
