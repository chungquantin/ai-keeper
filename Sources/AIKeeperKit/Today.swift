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

    @MainActor static func spentToday(_ store: Store) -> Double { store.spentToday }
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
    @State private var docker: Int64?          // reclaimable Docker and OrbStack bytes; nil until measured
    @State private var dockerState = "Measuring"

    private struct Cat: Identifiable {
        let id: String; let title: String; let why: String; let color: Color; let bytes: Int64?
        let counted: Bool; let safe: Bool; let action: String; let run: () -> Void
    }

    private var cats: [Cat] {
        [
            Cat(id: "build", title: "Build folders", why: "target and node_modules. Your next build recreates them.", color: Brand.reclaim,
                bytes: store.keptArtifactBytes, counted: true, safe: true, action: "Clean") { store.propose(.purgeArtifacts, for: store.buildHolders) },
            Cat(id: "ws", title: "Merged workspaces", why: "\(store.removableWorkspaces.count) worktrees whose pull requests merged or closed.", color: Brand.accent,
                bytes: store.total(store.removableWorkspaces), counted: true, safe: true, action: "Review") { nav.go(.deprecated) },
            Cat(id: "left", title: "Leftovers", why: "Folders agents left behind in old projects.", color: Brand.merged,
                bytes: store.total(store.orphanSessions) + store.total(store.caches), counted: true, safe: false, action: "Review") { nav.go(.leftovers) },
            Cat(id: "docker", title: "Containers", why: "Not counted in the \(store.reclaimable.bytesString). Docker and OrbStack images you are not running.", color: AgentColor.codex,
                bytes: docker, counted: false, safe: false, action: "Prune") { nav.open(.cleanup, .containers) },
            Cat(id: "dups", title: "Duplicates", why: "Not counted in the \(store.reclaimable.bytesString). Identical files that can share one copy.", color: AgentColor.pi,
                bytes: store.dedup.report?.reclaim, counted: false, safe: true, action: store.dedup.report == nil ? "Scan" : "Merge") { nav.diskDuplicates = true; nav.open(.cleanup, .disk) },
        ]
    }

    var body: some View {
        let cats = self.cats
        let counted = cats.filter(\.counted)
        let total = max(counted.reduce(0) { $0 + ($1.bytes ?? 0) }, 1)
        let safeBytes = cats.filter { $0.counted && $0.safe }.reduce(0) { $0 + ($1.bytes ?? 0) }
        Page {
            Card(padding: 22) {
                HStack(alignment: .center, spacing: 28) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(store.hasData ? store.reclaimable.byteParts.number : "—").font(.figure(56)).monospacedDigit()
                        Text(store.reclaimable.byteParts.unit).font(.figure(22)).foregroundStyle(.secondary)
                    }.fixedSize()
                    VStack(alignment: .leading, spacing: 10) {
                        GeometryReader { g in
                            HStack(spacing: 2) {
                                ForEach(counted) { c in Rectangle().fill(c.color).frame(width: max(0, (g.size.width - 4) * Double(c.bytes ?? 0) / Double(total))) }
                            }.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }.frame(height: 10)
                        Legend(items: cats.map { c in ("\(c.title) \(c.bytes.map { $0.bytesString } ?? "…")", c.color) })
                    }.frame(maxWidth: .infinity)
                    Button("Clean everything safe · \(safeBytes.bytesString)") { store.propose(.purgeArtifacts, for: store.buildHolders) }
                        .buttonStyle(.brandProminent).controlSize(.large).disabled(safeBytes == 0).fixedSize()
                }
            }
            AdaptiveRow(spacing: 16, minChild: 380) {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: "What it is, and how safe").padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                        ForEach(cats) { c in
                            HStack(spacing: 12) {
                                Circle().fill(c.color).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title).font(.bBody.weight(.medium))
                                    Text(c.why).font(.bCaption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Tag(text: c.safe ? "Safe" : "Check first", tone: c.safe ? .blue : .amber)
                                Text(c.bytes.map { $0.bytesString } ?? (c.id == "docker" ? dockerState : "Not scanned")).font(.bBody).monospacedDigit()
                                    .frame(width: 78, alignment: .trailing).foregroundStyle(c.bytes == nil ? Color.secondary : Color.primary)
                                Button(c.action) { c.run() }.buttonStyle(.brandOutline).frame(width: 74)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 11).overlay(alignment: .top) { Divider() }
                        }
                    }
                }
                ReclaimHistory().frame(width: 360)
            }
        }
        .task { await measureDocker() }
    }

    /// Docker and OrbStack report their reclaimable space as text ("12.3GB (45%)"); sum it without blocking the window.
    private func measureDocker() async {
        if Demo.enabled { docker = 62_400_000_000; return }
        let r = await Task.detached(priority: .utility) { DockerCLI.usage() }.value
        if r.error != nil { dockerState = "Not running"; return }
        docker = r.rows.reduce(0) { $0 + Self.parseBytes($1.reclaimable) }
    }

    static func parseBytes(_ s: String) -> Int64 {
        let t = s.split(separator: " ").first.map(String.init) ?? s
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) { return Int64((Double(t.dropLast(u.count)) ?? 0) * m) }
        return 0
    }
}

/// "Space you got back": the cleanup log as a grid of weeks, with what to do next. Real data from the cleanup log.
struct ReclaimHistory: View {
    @EnvironmentObject var store: Store
    @State private var records: [CleanRecord] = CleanLog.all()
    private let weekCount = 20
    private var finishedJobs: Int { store.jobs.filter { $0.state == .finished }.count }

    var body: some View {
        let s = CleanLog.summary(records)
        let weeks = CleanLog.weeks(count: weekCount)
        let peak = weeks.flatMap { $0 }.compactMap { $0.flatMap { s.days[$0]?.bytes } }.max() ?? 0
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Space you got back", note: s.runs == 0 ? nil : "Last \(weekCount) weeks · \(s.totalBytes.bytesString)")
                if s.runs == 0 {
                    Text("Nothing cleaned yet. Each day you remove something gets a square here.").font(.bCaption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    ForEach(weeks.indices, id: \.self) { w in
                        VStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { d in
                                if let day = weeks[w][d] {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(level(CleanLog.level(s.days[day]?.bytes ?? 0, peak: peak)))
                                        .aspectRatio(1, contentMode: .fit)
                                } else { Color.clear.aspectRatio(1, contentMode: .fit) }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }.accessibilityHidden(true)
                Note(text: "Your Mac refills with build folders as agents work. A weekly clean keeps it small.")
                Button { } label: { Text("Clean every Friday").frame(maxWidth: .infinity) }.buttonStyle(.brandOutline)
            }
        }
        .onAppear { records = CleanLog.all() }
        .onChange(of: finishedJobs) { _, _ in records = CleanLog.all() }
    }

    private func level(_ l: Int) -> Color { l == 0 ? Brand.muted : Brand.accent.opacity([0, 0.25, 0.45, 0.7, 1][l]) }
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
        let recent = store.sessions.newest(8)
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
