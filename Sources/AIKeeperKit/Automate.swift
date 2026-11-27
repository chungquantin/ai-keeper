import SwiftUI

// Cleanup › Automate: rules that run by themselves, only ever on things you could get back.

struct CleanRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case buildFolders, mergedWorkspaces, dockerCache, transcripts }
    var kind: Kind
    var enabled = false
    var days: Int
    var gb: Int
    var lastRun: Date?
    var lastFreed: Int64 = 0
    var id: String { kind.rawValue }

    static let defaults: [CleanRule] = [
        .init(kind: .buildFolders, days: 14, gb: 60),
        .init(kind: .mergedWorkspaces, days: 3, gb: 5),
        .init(kind: .dockerCache, days: 0, gb: 20),
        .init(kind: .transcripts, days: 60, gb: 0),
    ]

    var title: String {
        switch kind {
        case .buildFolders: "Clear build folders nobody opened for \(days) days"
        case .mergedWorkspaces: "Remove a workspace \(days) days after its pull request merges"
        case .dockerCache: "Prune Docker build cache above \(gb) GB"
        case .transcripts: "Archive transcripts older than \(days) days"
        }
    }
    var detail: String {
        switch kind {
        case .buildFolders: "Runs when free space is below \(gb) GB"
        case .mergedWorkspaces: "Asks first when a workspace holds more than \(gb) GB"
        case .dockerCache: "Checks once a day"
        case .transcripts: "Once a month, packed into a file you can restore"
        }
    }
    var tier: Tier { switch kind { case .buildFolders, .dockerCache: .rebuildable; case .mergedWorkspaces: .onRemote; case .transcripts: .onlyHere } }
    var symbol: String { switch kind { case .buildFolders: "folder"; case .mergedWorkspaces: "arrow.triangle.branch"; case .dockerCache: "shippingbox"; case .transcripts: "doc.text" } }
    /// How often it may run on its own.
    var interval: TimeInterval { kind == .transcripts ? 28 * 86400 : 20 * 3600 }
}

@MainActor
final class RuleBook: ObservableObject {
    @Published var rules: [CleanRule] = Persist.load([CleanRule].self, "rules.json") ?? CleanRule.defaults
    @Published var notify: Bool = UserDefaults.standard.object(forKey: "rules.notify") as? Bool ?? true { didSet { UserDefaults.standard.set(notify, forKey: "rules.notify") } }

    func update(_ r: CleanRule) {
        guard let i = rules.firstIndex(where: { $0.id == r.id }) else { return }
        rules[i] = r
        if !Demo.enabled { Persist.save(rules, "rules.json") }
    }
}

@MainActor
enum RuleEngine {
    struct Preview { var plan = Basket.Plan(); var bytes: Int64 = 0; var count = 0; var askFirst: Int64 = 0 }

    /// What a rule would clear right now, for the two rules that read the scan. Docker and transcripts are measured by `asyncBytes`.
    static func preview(_ r: CleanRule, store: Store) -> Preview {
        var p = Preview()
        let items = ReclaimPlanner.items(store)
        func idle(_ e: Entry) -> Bool { store.runningAgents(in: e).isEmpty }
        switch r.kind {
        case .buildFolders:
            let cutoff = Date().addingTimeInterval(-Double(r.days) * 86400)
            let hit = (items.first { $0.kind == .buildFolders }?.entries ?? []).filter { ($0.lastActivity ?? .distantPast) < cutoff && idle($0) }
            p.plan.purge = hit; p.bytes = hit.reduce(0) { $0 + $1.artifactBytes }; p.count = hit.count
        case .mergedWorkspaces:
            let cutoff = Date().addingTimeInterval(-Double(r.days) * 86400)
            let all = (items.first { $0.kind == .merged }?.entries ?? []).filter { ($0.pr?.mergedAt ?? $0.lastActivity ?? .distantPast) < cutoff && idle($0) }
            let limit = Int64(r.gb) * 1_000_000_000
            let small = all.filter { ($0.size ?? 0) <= limit }
            p.plan.removeSafe = small; p.bytes = small.reduce(0) { $0 + ($1.size ?? 0) }; p.count = small.count
            p.askFirst = all.filter { ($0.size ?? 0) > limit }.reduce(0) { $0 + ($1.size ?? 0) }
        default: break
        }
        return p
    }

    static func asyncBytes(_ r: CleanRule, store: Store) async -> Int64 {
        switch r.kind {
        case .dockerCache: return max(0, (store.sources.dockerCache ?? 0) - Int64(r.gb) * 1_000_000_000)
        case .transcripts: let d = r.days; return await Task.detached { Archiver.candidates(id: "claude", days: d).bytes }.value
        default: return 0
        }
    }

    /// Do what the rule says. Returns the bytes it cleared.
    @discardableResult
    static func run(_ r: CleanRule, store: Store) async -> Int64 {
        var freed: Int64 = 0
        switch r.kind {
        case .buildFolders, .mergedWorkspaces:
            let p = preview(r, store: store)
            guard !p.plan.isEmpty else { break }
            let jobs = store.reclaim(p.plan, deleteNow: true)
            while jobs.contains(where: { $0.state != .finished }) { try? await Task.sleep(for: .milliseconds(500)) }
            freed = jobs.compactMap(\.outcome).reduce(0) { $0 + $1.freed }
            jobs.forEach { store.dismissJob($0) }
        case .dockerCache:
            let keep = r.gb
            freed = await asyncBytes(r, store: store)
            guard freed > 0 else { break }
            _ = await Task.detached { DockerCLI.prune(["builder", "prune", "-f", "--keep-storage", "\(keep)GB"]) }.value
            await store.sources.measure()
        case .transcripts:
            let d = r.days
            let res = await Task.detached(priority: .utility) { () -> Int64 in
                let plan = Archiver.candidates(id: "claude", days: d)
                if case .success = Archiver.archive(plan, id: "claude") { return plan.bytes }
                return 0
            }.value
            freed = res
            if res > 0 { await store.sources.measure(); store.loadTraces() }
        }
        var next = r; next.lastRun = .now; next.lastFreed = freed
        store.rules.update(next)
        if freed > 0, store.rules.notify { Notifier.send("A cleanup rule ran", "\(r.title): \(freed.bytesString)", id: "rule.\(r.id)") }
        return freed
    }

    /// Called after each scan and every half hour. A rule runs on its own at most once per interval.
    static func tick(_ store: Store) async {
        guard !Demo.enabled, ToolSettings.onboarded, !store.isScanning else { return }
        for r in store.rules.rules where r.enabled {
            if let l = r.lastRun, Date().timeIntervalSince(l) < r.interval { continue }
            if r.kind == .buildFolders, store.disk.total > 0, store.disk.available >= Int64(r.gb) * 1_000_000_000 { continue }
            await run(r, store: store)
        }
    }
}

// MARK: The tab

struct AutomateTab: View {
    @EnvironmentObject var store: Store
    @State private var sel: CleanRule.Kind = .buildFolders
    @State private var extra: [String: Int64] = [:]
    @State private var running = false

    var body: some View {
        let book = store.rules
        RulesBody(book: book, sel: $sel, extra: $extra, running: $running)
            .task(id: store.rules.rules) { await store.sources.measureIfNeeded(); await measure(book) }
    }

    private func measure(_ book: RuleBook) async {
        for r in book.rules where r.kind == .dockerCache || r.kind == .transcripts { extra[r.id] = await RuleEngine.asyncBytes(r, store: store) }
    }
}

private struct RulesBody: View {
    @EnvironmentObject var store: Store
    @ObservedObject var book: RuleBook
    @Binding var sel: CleanRule.Kind
    @Binding var extra: [String: Int64]
    @Binding var running: Bool

    private func wouldFree(_ r: CleanRule) -> Int64 {
        switch r.kind { case .buildFolders, .mergedWorkspaces: RuleEngine.preview(r, store: store).bytes; default: extra[r.id] ?? 0 }
    }

    var body: some View {
        Page {
            AdaptiveRow(spacing: 16, minChild: 380) {
                VStack(spacing: 12) {
                    ForEach(book.rules) { r in ruleCard(r) }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    if let r = book.rules.first(where: { $0.kind == sel }) { editor(r) }
                    guardrails
                }.frame(width: 400)
            }
        }
    }

    private func ruleCard(_ r: CleanRule) -> some View {
        let on = r.kind == sel
        return Button { sel = r.kind } label: {
            HStack(spacing: 14) {
                TierChip(symbol: r.symbol, tone: r.tier.tone, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.bBody.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(r.detail + (r.lastRun.map { " · last ran \($0.formatted(.relative(presentation: .named)))" } ?? "")).font(.bCaption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(wouldFree(r).bytesString).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    Text("would free now").font(.bCaption2).foregroundStyle(.secondary)
                }
                Toggle("", isOn: Binding(get: { r.enabled }, set: { var n = r; n.enabled = $0; book.update(n) })).toggleStyle(.switch).labelsHidden()
            }
            .padding(16).background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Brand.accent : Brand.edge, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func editor(_ r: CleanRule) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Edit rule").font(.bHeadline); Spacer(); Tag(text: r.kind == .transcripts ? "Archived, not deleted" : r.tier.title, tone: r.kind == .transcripts ? .gray : r.tier.tone) }
                FlowLayout(spacing: 6, lineSpacing: 8) { sentence(r) }.font(.system(size: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Right now").font(.bCaption2).foregroundStyle(.secondary)
                    let p = RuleEngine.preview(r, store: store)
                    Text(wouldFree(r) > 0 ? "It would clear \(wouldFree(r).bytesString)." : "It would clear nothing: nothing matches yet.").font(.bBody)
                    if p.askFirst > 0 { Text("\(p.askFirst.bytesString) more is over the size limit, so it would ask first.").font(.bCaption).foregroundStyle(.secondary) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button { Task { running = true; await RuleEngine.run(r, store: store); running = false } } label: { Text(running ? "Running…" : "Run now").frame(maxWidth: .infinity) }
                    .buttonStyle(.brandProminent).controlSize(.large).disabled(running || wouldFree(r) == 0)
            }
        }
    }

    @ViewBuilder private func sentence(_ r: CleanRule) -> some View {
        switch r.kind {
        case .buildFolders:
            Text("When free space is below"); pick(r, \.gb, [20, 40, 60, 100, 200]) { "\($0) GB" }
            Text("clear build folders nobody opened for"); pick(r, \.days, [3, 7, 14, 30]) { "\($0) days" }
        case .mergedWorkspaces:
            Text("Remove a workspace"); pick(r, \.days, [0, 1, 3, 7, 14]) { $0 == 0 ? "as soon as" : "\($0) days after" }
            Text("its pull request merges. Ask first above"); pick(r, \.gb, [1, 2, 5, 10, 20]) { "\($0) GB" }
        case .dockerCache:
            Text("Prune Docker build cache above"); pick(r, \.gb, [5, 10, 20, 50]) { "\($0) GB" }
        case .transcripts:
            Text("Archive session transcripts older than"); pick(r, \.days, [30, 60, 90, 180]) { "\($0) days" }
        }
    }

    private func pick(_ r: CleanRule, _ key: WritableKeyPath<CleanRule, Int>, _ options: [Int], _ fmt: @escaping (Int) -> String) -> some View {
        Menu {
            ForEach(options, id: \.self) { v in Button(fmt(v)) { var n = r; n[keyPath: key] = v; book.update(n) } }
        } label: {
            Text(fmt(r[keyPath: key])).fontWeight(.semibold).foregroundStyle(Brand.primaryText)
                .padding(.horizontal, 9).frame(height: 26).background(Brand.primaryTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var guardrails: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Guardrails for every rule").font(.bHeadline)
                ForEach(["Never touches uncommitted changes or unpushed commits", "Skips any folder an agent has open", "Only clears Rebuildable and On a remote items", "Every run is logged under History, with a way to restore"], id: \.self) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentColor.good)
                        Text(t).font(.bBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Toggle(isOn: $book.notify) {
                    VStack(alignment: .leading, spacing: 1) { Text("Tell me when a rule runs").font(.bBody.weight(.medium)); Text("A notification with how much it cleared.").font(.bCaption).foregroundStyle(.secondary) }
                }.toggleStyle(.switch)
            }
        }
    }
}
