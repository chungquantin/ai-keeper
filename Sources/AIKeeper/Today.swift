import SwiftUI

struct AttentionItem: Identifiable {
    let id: String
    let tone: Tone
    let title: String
    let subtitle: String
    let action: String
    let go: (NavState, Store) -> Void
}

enum TodayData {
    /// Things that need the user. Real signals first (agents waiting, deprecated workspaces, skills to review), then sample items for what is not measured yet.
    @MainActor static func attention(_ store: Store) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for a in store.agents where a.state == .needsInput && a.kind != .mcp {
            let name = store.workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? a.kind.rawValue
            items.append(.init(id: "agent\(a.pid)", tone: .amber, title: "\(name) is waiting on you",
                               subtitle: "\(a.kind.rawValue) needs an approval", action: "Open") { n, _ in n.open(.sessions, .live) })
        }
        let removable = store.removableWorkspaces
        if !removable.isEmpty {
            items.append(.init(id: "ws", tone: .blue, title: "\(removable.count) workspace\(removable.count == 1 ? "" : "s") are merged or idle and safe to remove",
                               subtitle: store.total(removable).bytesString, action: "Review") { n, _ in n.go(.deprecated) })
        }
        let review = store.skills.filter { let v = SkillLibrary.verdict($0, store.skillScans); return v == .caution || v == .danger }
        if !review.isEmpty {
            items.append(.init(id: "skills", tone: .amber, title: "\(review.count) skill\(review.count == 1 ? " has" : "s have") risky scripts",
                               subtitle: review.prefix(3).map(\.name).joined(separator: ", "), action: "Look") { n, _ in n.open(.agents, .skills) })
        }
        items.append(.init(id: "budget", tone: .red, title: "Spend is at 84% of today's budget",
                           subtitle: "$25.29 of $30.00 · sample", action: "Adjust") { n, _ in n.open(.agents, .budgets) })
        return items
    }

    @MainActor static func spentToday(_ store: Store) -> Double {
        store.usage.filter { Calendar.current.isDateInToday($0.day) }.reduce(0) { $0 + $1.cost }
    }
}

// MARK: Briefing

struct TodayBriefing: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState

    var body: some View {
        let items = TodayData.attention(store)
        let live = store.agents.filter { $0.kind != .mcp }
        Page {
            AdaptiveRow(spacing: 16) {
                reclaimCard
                saveCard
            }
            AdaptiveRow(spacing: 16) {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: "Needs you").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                        RowList(items: items) { it in
                            ListRow(title: it.title, subtitle: it.subtitle) { Dot(tone: it.tone) } trail: {
                                Button(it.action) { it.go(nav, store) }.controlSize(.small)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity)
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: "Running now", note: live.isEmpty ? nil : "\(live.count) agent\(live.count == 1 ? "" : "s")").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                        if live.isEmpty {
                            Text("No agents are running.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 18)
                        } else {
                            RowList(items: Array(live.prefix(5))) { a in
                                ListRow(title: store.workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? a.kind.rawValue,
                                        subtitle: stateText(a)) {
                                    Circle().fill(AgentColor.of(a.kind.rawValue)).frame(width: 8, height: 8)
                                } trail: {
                                    Text(duration(a.elapsed)).font(.bCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(width: 330)
            }
        }
    }

    private var reclaimCard: some View {
        let parts = store.hasData ? store.reclaimable.byteParts : (number: "—", unit: "")
        return Card(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.isScanning ? "Measuring your workspaces…" : "You can get back").font(.bCallout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.number).font(.figure(64)).monospacedDigit()
                    Text(parts.unit).font(.figure(24)).foregroundStyle(.secondary)
                }.lineLimit(1).minimumScaleFactor(0.6)
                Text(heroSummary).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if store.keptArtifactBytes > 0 {
                        Button("Clean \(store.keptArtifactBytes.bytesString)") { store.propose(.purgeArtifacts, for: store.buildHolders) }
                            .buttonStyle(.brandProminent).controlSize(.large)
                    }
                    Button("Review") { nav.open(.today, .reclaim) }.controlSize(.large)
                }
            }
        }
    }

    private var saveCard: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("You could save").font(.bCallout).foregroundStyle(.secondary); Spacer(); SampleChip() }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$\(MockData.monthlySavings)").font(.figure(64)).monospacedDigit()
                    Text("a month").font(.figure(24)).foregroundStyle(.secondary)
                }
                Text("By sending docs and tests to cheaper agents and dropping an unused MCP server. You spent \(String(format: "$%.2f", TodayData.spentToday(store))) today.")
                    .font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("See how") { nav.open(.today, .optimize) }.buttonStyle(.brandProminent).controlSize(.large)
                    Button("Set a budget") { nav.open(.agents, .budgets) }.controlSize(.large)
                }
            }
        }
    }

    private var heroSummary: String {
        guard store.hasData else { return "Measuring your workspaces. Numbers fill in as they come." }
        if let a = store.stats.biggestArtifact { return "Mostly build output. The largest is \(a.holder)/\(a.label) at \(a.bytes.bytesString). Your next build recreates it." }
        return "\(store.workspaces.count) workspaces take \(store.managedBytes.bytesString)."
    }

    private func stateText(_ a: AgentProc) -> String {
        switch a.state { case .needsInput: "Needs you"; case .working: "Working"; case .idle: "Idle"; case .unknown: a.kind.rawValue }
    }
    private func duration(_ t: TimeInterval) -> String { t >= 3600 ? String(format: "%.0f hr", t / 3600) : "\(max(1, Int(t / 60))) min" }
}

// MARK: Reclaim

struct TodayReclaim: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState

    private struct Cat: Identifiable {
        let id: String; let title: String; let why: String; let color: Color; let bytes: Int64
        let safe: Bool; let action: String; let run: () -> Void
    }

    private var cats: [Cat] {
        [
            Cat(id: "build", title: "Build folders", why: "target, node_modules and .next. Your next build recreates them.", color: Brand.reclaim,
                bytes: store.keptArtifactBytes, safe: true, action: "Clean") { store.propose(.purgeArtifacts, for: store.buildHolders) },
            Cat(id: "ws", title: "Deprecated workspaces", why: "\(store.removableWorkspaces.count) worktrees that are merged, closed or idle.", color: Brand.accent,
                bytes: store.total(store.removableWorkspaces), safe: true, action: "Review") { nav.go(.deprecated) },
            Cat(id: "left", title: "Leftovers", why: "Chat history of deleted projects, caches and logs.", color: Brand.merged,
                bytes: store.total(store.orphanSessions) + store.total(store.caches), safe: false, action: "Review") { nav.go(.leftovers) },
        ]
    }

    var body: some View {
        let cats = self.cats
        let total = max(cats.reduce(0) { $0 + $1.bytes }, 1)
        let safeBytes = cats.filter(\.safe).reduce(0) { $0 + $1.bytes }
        Page {
            Card(padding: 22) {
                HStack(alignment: .center, spacing: 28) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(store.hasData ? store.reclaimable.byteParts.number : "—").font(.figure(56)).monospacedDigit()
                        Text(store.reclaimable.byteParts.unit).font(.figure(22)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        GeometryReader { g in
                            HStack(spacing: 2) {
                                ForEach(cats) { c in Rectangle().fill(c.color).frame(width: max(0, (g.size.width - 4) * Double(c.bytes) / Double(total))) }
                            }.clipShape(RoundedRectangle(cornerRadius: 7)).background(RoundedRectangle(cornerRadius: 7).fill(Brand.muted))
                        }.frame(height: 14)
                        Legend(items: cats.map { ("\($0.title) \($0.bytes.bytesString)", $0.color) })
                    }
                    Button("Clean everything safe · \(safeBytes.bytesString)") {
                        store.propose(.purgeArtifacts, for: store.buildHolders)
                    }.buttonStyle(.brandProminent).controlSize(.large).disabled(safeBytes == 0)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: "What it is, and how safe").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                        RowList(items: cats) { c in
                            ListRow(title: c.title, subtitle: c.why) { Circle().fill(c.color).frame(width: 9, height: 9) } trail: {
                                HStack(spacing: 12) {
                                    Tag(text: c.safe ? "Safe" : "Check first", tone: c.safe ? .blue : .amber)
                                    Text(c.bytes.bytesString).font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
                                    Button(c.action) { c.run() }.controlSize(.small).frame(width: 64)
                                }
                            }
                        }
                        Divider()
                        HStack {
                            Button { nav.open(.cleanup, .containers) } label: { Label("Docker and OrbStack images", systemImage: "shippingbox") }.buttonStyle(.link)
                            Button { nav.diskDuplicates = true; nav.open(.cleanup, .disk) } label: { Label("Duplicate files", systemImage: "square.on.square") }.buttonStyle(.link)
                            Spacer()
                            Text("Not counted above").font(.bCaption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 20).padding(.vertical, 10)
                    }
                }
                CleanupChart()
                Card {
                    HStack(spacing: 14) {
                        Note(text: "Your Mac refills with build folders as agents work. A weekly clean keeps it small.")
                        Button("Clean every Friday") {}.controlSize(.large)
                    }
                }
            }
        }
    }
}

// MARK: Optimize (sample data)

struct TodayOptimize: View {
    @EnvironmentObject var nav: NavState

    private struct Tip: Identifiable { let id = UUID(); let title: String; let body: String; let save: String; let action: String; let go: Area; let tab: Tab }
    private struct TipGroup: Identifiable { let id = UUID(); let title: String; let symbol: String; let tone: Tone; let tips: [Tip] }

    private let groups: [TipGroup] = [
        TipGroup(title: "Pick the right agent", symbol: "bolt.horizontal", tone: .blue, tips: [
            Tip(title: "Docs and release notes to Pi", body: "Same merged rate as Claude Code at a fifth of the cost.", save: "$18 a month", action: "Make Pi the default", go: .insights, tab: .advisor),
            Tip(title: "Tests to Codex", body: "83% merged against 69%, and 27% cheaper.", save: "$12 a month", action: "See the evidence", go: .insights, tab: .advisor)]),
        TipGroup(title: "Trim the harness", symbol: "checkmark.shield", tone: .amber, tips: [
            Tip(title: "Turn off the linear server", body: "Never called in 60 days, and adds 3.8K tokens to every session.", save: "$9 a month", action: "Open MCP servers", go: .agents, tab: .mcp),
            Tip(title: "Fix the prettier hook", body: "It fails 17% of the time and each failure costs a retry.", save: "$7 a month", action: "Open hooks", go: .agents, tab: .hooks)]),
        TipGroup(title: "Change a habit", symbol: "person", tone: .violet, tips: [
            Tip(title: "Start fresh at 70% context", body: "Long sessions cost 2.3× as much and finish less often.", save: "$18 a month", action: "See context use", go: .insights, tab: .context),
            Tip(title: "Name the file in the prompt", body: "Merged 2.1× more often than prompts that describe the feature only.", save: "Fewer retries", action: "See your prompts", go: .sessions, tab: .prompts)]),
    ]

    var body: some View {
        Page(sample: true) {
            Card(padding: 22) {
                HStack(alignment: .center, spacing: 32) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("$\(MockData.monthlySavings)").font(.figure(56)).monospacedDigit()
                        Text("a month").font(.figure(22)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Projected this month").font(.bCaption).foregroundStyle(.secondary); Spacer(); Text("$412 now, $348 with all changes").font(.bCaption) }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Brand.muted)
                                Capsule().fill(Brand.reclaimTint).frame(width: g.size.width)
                                Capsule().fill(Brand.accent).frame(width: g.size.width * 0.84)
                            }
                        }.frame(height: 14)
                    }
                    Button("Apply the 3 safe changes") {}.buttonStyle(.brandProminent).controlSize(.large)
                }
            }
            AdaptiveRow(spacing: 16) {
                ForEach(groups) { g in
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: g.symbol).foregroundStyle(g.tone.fg).frame(width: 30, height: 30).background(g.tone.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text(g.title).font(.bHeadline)
                            }
                            ForEach(g.tips) { t in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top) { Text(t.title).font(.bBody.weight(.semibold)); Spacer(minLength: 6); Tag(text: t.save, tone: .blue) }
                                    Text(t.body).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) { Button(t.action) { nav.open(t.go, t.tab) }.controlSize(.small); Button("Why?") { nav.open(t.go, t.tab) }.buttonStyle(.plain).font(.bCaption).foregroundStyle(.secondary) }
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Activity

struct TodayActivity: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState

    var body: some View {
        let live = store.agents.filter { $0.kind != .mcp }
        let recent = Array(store.sessions.sorted { $0.last > $1.last }.prefix(8))
        Page {
            AdaptiveRow(spacing: 16) {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: "Running now", note: "\(live.count) agent\(live.count == 1 ? "" : "s")").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                        if live.isEmpty { Text("No agents are running.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                        RowList(items: live) { a in
                            ListRow(title: a.title ?? store.workspace(for: a)?.name ?? a.kind.rawValue,
                                    subtitle: "\(a.kind.rawValue) · \(a.cwd.map { ($0 as NSString).lastPathComponent } ?? "—")") {
                                Circle().fill(AgentColor.of(a.kind.rawValue)).frame(width: 8, height: 8)
                            } trail: {
                                if a.state == .needsInput { Tag(text: "Needs you", tone: .amber) }
                                else if let c = a.cost { Text(String(format: "$%.2f", c)).font(.bCaption).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                        Divider()
                        Button("Open Live") { nav.open(.sessions, .live) }.buttonStyle(.link).padding(.horizontal, 20).padding(.vertical, 10)
                    }
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: "Recent sessions").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                        if recent.isEmpty { Text("No sessions yet.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                        RowList(items: recent) { s in
                            ListRow(title: s.title.isEmpty ? s.project : s.title, subtitle: "\(s.agent.rawValue) · \(s.project)") {
                                Circle().fill(AgentColor.of(s.agent.rawValue)).frame(width: 8, height: 8)
                            } trail: {
                                Text(s.last.formatted(.relative(presentation: .named))).font(.bCaption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Button("Open History") { nav.open(.sessions, .history) }.buttonStyle(.link).padding(.horizontal, 20).padding(.vertical, 10)
                    }
                }
            }
        }
    }
}
