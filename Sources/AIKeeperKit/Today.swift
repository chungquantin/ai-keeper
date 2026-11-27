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
        let budget = Demo.enabled ? 30 : UserDefaults.standard.double(forKey: "budget.daily")
        if budget > 0, store.spentToday >= budget * 0.8 {
            items.append(.init(id: "budget", tone: .red, title: "Spend is at \(Int(store.spentToday / budget * 100))% of today's budget",
                               subtitle: String(format: "$%.2f of $%.2f", store.spentToday, budget), action: "Adjust") { n, _ in n.open(.agents, .budgets) })
        }
        let loops = store.advice.agg.loops.count
        if loops > 0 { items.append(.init(id: "loops", tone: .amber, title: "\(loops) loop\(loops == 1 ? "" : "s") in the last 30 days", subtitle: store.advice.agg.loops[0].loop.detail, action: "See") { n, _ in n.open(.insights, .reliability) }) }
        return items
    }

    @MainActor static func spentToday(_ store: Store) -> Double { store.spentToday }
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
            }
        }
        .onAppear { records = CleanLog.all() }
        .onChange(of: finishedJobs) { _, _ in records = CleanLog.all() }
    }

    private func level(_ l: Int) -> Color { l == 0 ? Brand.muted : Brand.accent.opacity([0, 0.25, 0.45, 0.7, 1][l]) }
}
