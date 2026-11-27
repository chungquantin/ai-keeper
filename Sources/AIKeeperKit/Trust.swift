import SwiftUI

// Cleanup asks one question of everything it finds: what happens if I lose this?
// The answer is a tier, and the tier decides what is preselected and what rules may touch.

extension Brand {
    /// A fill for "safe": the green of the trust ladder. For green text use `AgentColor.good`.
    static let ok = Color.dynamic(light: 0x1F9D55, dark: 0x4ADE80)
}

enum Tier: Int, CaseIterable, Identifiable {
    case rebuildable, onRemote, onlyHere
    var id: Int { rawValue }

    var title: String { ["Rebuildable", "On a remote", "Only here"][rawValue] }
    /// One line saying what the tier means in plain words.
    var meaning: String {
        switch self {
        case .rebuildable: "your next build recreates it"
        case .onRemote: "it is all on GitHub"
        case .onlyHere: "nowhere else has it"
        }
    }
    var tone: Tone { [Tone.green, .violet, .amber][rawValue] }
    var color: Color { [Brand.ok, Brand.merged, Brand.reclaim][rawValue] }
    var isSafe: Bool { self != .onlyHere }
}

struct ReclaimItem: Identifiable {
    enum Kind: String { case buildFolders, caches, merged, uncommitted, unpushed, leftovers }
    var id: String { kind.rawValue }
    let kind: Kind
    let tier: Tier
    let title: String
    let subtitle: String
    let regret: String
    let bytes: Int64
    let lastUsed: Date?
    let entries: [Entry]
    let symbol: String
    var count: Int { entries.count }
}

enum ReclaimPlanner {
    /// Everything Cleanup can clear, grouped by what it would cost to regret. Cheap: one pass over the scan.
    @MainActor static func items(_ store: Store) -> [ReclaimItem] {
        let st = store.stats
        func removing(_ e: Entry) -> Bool { e.kind == .workspace && e.verdict == .deprecated && e.safety != .danger }
        let holders = st.buildHolders.filter { !removing($0) && $0.verdict != .dangling && !$0.artifacts.isEmpty }
        let merged = st.workspaces.filter { removing($0) && $0.safety == .safe }
        let uncommitted = st.workspaces.filter { $0.verdict == .deprecated && $0.safety == .danger }
        let unpushed = st.workspaces.filter { $0.verdict == .deprecated && $0.safety == .caution }
        func bytes(_ l: [Entry]) -> Int64 { l.reduce(0) { $0 + max($1.size ?? 0, 0) } }
        func newest(_ l: [Entry]) -> Date? { l.compactMap(\.lastActivity).max() }
        var out: [ReclaimItem] = []
        let build = holders.reduce(Int64(0)) { $0 + $1.artifactBytes }
        if build > 0 {
            out.append(.init(kind: .buildFolders, tier: .rebuildable, title: "Build folders · \(holders.count) project\(holders.count == 1 ? "" : "s")",
                             subtitle: "target, node_modules, .next, dist in your workspaces", regret: "Rebuilds in a few minutes",
                             bytes: build, lastUsed: newest(holders), entries: holders, symbol: "shippingbox"))
        }
        if bytes(st.caches) > 0 {
            out.append(.init(kind: .caches, tier: .rebuildable, title: "Tool caches · \(st.caches.count)",
                             subtitle: st.caches.prefix(3).map(\.name).joined(separator: ", "), regret: "Downloads again when needed",
                             bytes: bytes(st.caches), lastUsed: nil, entries: st.caches, symbol: "shippingbox"))
        }
        if !merged.isEmpty {
            out.append(.init(kind: .merged, tier: .onRemote, title: "\(merged.count) workspace\(merged.count == 1 ? "" : "s"), pull request merged or closed",
                             subtitle: merged.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(2).map(\.name).joined(separator: ", ") + (merged.count > 2 ? " and \(merged.count - 2) more" : ""),
                             regret: "Recreate it from GitHub in a minute", bytes: bytes(merged), lastUsed: newest(merged), entries: merged, symbol: "arrow.triangle.branch"))
        }
        if !uncommitted.isEmpty {
            out.append(.init(kind: .uncommitted, tier: .onlyHere, title: "\(uncommitted.count) workspace\(uncommitted.count == 1 ? "" : "s") with uncommitted changes",
                             subtitle: uncommitted.prefix(2).map(\.name).joined(separator: ", "), regret: "Lost, unless we save a snapshot first",
                             bytes: bytes(uncommitted), lastUsed: newest(uncommitted), entries: uncommitted, symbol: "exclamationmark.triangle"))
        }
        if !unpushed.isEmpty {
            out.append(.init(kind: .unpushed, tier: .onlyHere, title: "\(unpushed.count) workspace\(unpushed.count == 1 ? "" : "s") with commits that exist only here",
                             subtitle: unpushed.prefix(2).map(\.name).joined(separator: ", "), regret: "Lost, unless we save a snapshot first",
                             bytes: bytes(unpushed), lastUsed: newest(unpushed), entries: unpushed, symbol: "exclamationmark.triangle"))
        }
        if bytes(st.orphans) > 0 {
            out.append(.init(kind: .leftovers, tier: .onlyHere, title: "Leftover chat history · \(st.orphans.count)",
                             subtitle: "Left behind by agents in projects that no longer exist", regret: "Lost for good",
                             bytes: bytes(st.orphans), lastUsed: nil, entries: st.orphans, symbol: "folder"))
        }
        return out
    }

    /// The facts behind a verdict, so a row never asks you to take its word for it.
    struct Proof: Identifiable { let id = UUID(); let ok: Bool; let text: String }

    @MainActor static func evidence(_ e: Entry, store: Store) -> [Proof] {
        var out: [Proof] = []
        let g = e.git
        if let pr = e.pr, pr.state == "MERGED" {
            out.append(.init(ok: true, text: "PR #\(pr.number) merged" + (pr.mergedAt.map { " " + $0.formatted(.relative(presentation: .named)) } ?? "")))
        } else if let pr = e.pr, pr.state == "CLOSED" {
            out.append(.init(ok: true, text: "PR #\(pr.number) closed without merging"))
        } else if let g, g.merged {
            out.append(.init(ok: true, text: "Branch is merged into \(g.defaultBranch)"))
        } else if let pr = e.pr {
            out.append(.init(ok: false, text: "PR #\(pr.number) is still open"))
        }
        if let g {
            out.append(.init(ok: g.dirtyCount == 0, text: g.dirtyCount == 0 ? "Working tree is clean" : "\(g.dirtyCount) uncommitted change\(g.dirtyCount == 1 ? "" : "s")"))
            let landed = g.merged || (e.pr?.state == "MERGED" && g.unpushedAfterMerge == 0)
            let lonely = landed ? 0 : g.unpushed
            out.append(.init(ok: lonely == 0, text: lonely == 0 ? "Every commit is on a remote" : "\(lonely) commit\(lonely == 1 ? "" : "s") exist only in this folder"))
        }
        let running = store.runningAgents(in: e)
        out.append(.init(ok: running.isEmpty, text: running.isEmpty ? "No agent is running here" : "\(running.count) agent\(running.count == 1 ? " is" : "s are") running here"))
        if let last = e.lastActivity {
            let days = Calendar.current.dateComponents([.day], from: last, to: .now).day ?? 0
            out.append(.init(ok: true, text: days <= 0 ? "Last opened today" : "Not opened for \(days) day\(days == 1 ? "" : "s")"))
        }
        return out
    }
}

// MARK: The basket

/// What the user has chosen to clear. Safe tiers start ticked; Only here never does. The model stores only the user's changes,
/// so a scan finishing later never silently adds or drops a choice.
@MainActor
final class Basket: ObservableObject {
    @Published private var off: Set<String> = []        // safe items the user unticked
    @Published private var on: Set<String> = []         // Only here items the user chose on purpose
    @Published var excluded: Set<String> = []           // entries unticked inside a ticked item
    @Published var buildOnly: Set<String> = []          // workspaces where only the build folders go

    func contains(_ item: ReclaimItem) -> Bool { item.tier.isSafe ? !off.contains(item.id) : on.contains(item.id) }

    func toggle(_ item: ReclaimItem) {
        if item.tier.isSafe { if off.contains(item.id) { off.remove(item.id) } else { off.insert(item.id) } }
        else { if on.contains(item.id) { on.remove(item.id) } else { on.insert(item.id) } }
    }

    func toggleEntry(_ e: Entry) { if excluded.contains(e.id) { excluded.remove(e.id) } else { excluded.insert(e.id) } }
    func toggleBuildOnly(_ e: Entry) { if buildOnly.contains(e.id) { buildOnly.remove(e.id) } else { buildOnly.insert(e.id) } }

    /// Back to the default: every safe item ticked, nothing else.
    func resetToSafe() { off = []; on = []; excluded = []; buildOnly = [] }

    func entries(_ item: ReclaimItem) -> [Entry] { item.entries.filter { !excluded.contains($0.id) } }

    func bytes(_ item: ReclaimItem) -> Int64 {
        guard contains(item) else { return 0 }
        return entries(item).reduce(0) { $0 + Self.cost($1, item: item, buildOnly: buildOnly) }
    }

    static func cost(_ e: Entry, item: ReclaimItem, buildOnly: Set<String>) -> Int64 {
        if item.kind == .buildFolders || buildOnly.contains(e.id) { return e.artifactBytes }
        return max(e.size ?? 0, 0)
    }

    func total(_ items: [ReclaimItem]) -> Int64 { items.reduce(0) { $0 + bytes($1) } }
    func count(_ items: [ReclaimItem]) -> Int { items.filter { contains($0) }.reduce(0) { $0 + entries($1).count } }

    struct Plan {
        var purge: [Entry] = []          // clear build folders only
        var removeSafe: [Entry] = []     // rebuildable or on a remote: remove whole
        var removeRisky: [Entry] = []    // Only here: remove after saving a snapshot, always via Trash
        var isEmpty: Bool { purge.isEmpty && removeSafe.isEmpty && removeRisky.isEmpty }
    }

    func plan(_ items: [ReclaimItem]) -> Plan {
        var p = Plan()
        for item in items where contains(item) {
            for e in entries(item) {
                if item.kind == .buildFolders || buildOnly.contains(e.id) { if !e.artifacts.isEmpty { p.purge.append(e) } }
                else if item.tier.isSafe { p.removeSafe.append(e) }
                else { p.removeRisky.append(e) }
            }
        }
        return p
    }
}

extension Store {
    /// Safe items only, the way the sidebar button and Today use it: one click, nothing risky.
    @MainActor func safeItems() -> [ReclaimItem] { ReclaimPlanner.items(self).filter { $0.tier.isSafe } }

    /// Queue the basket as up to three jobs. Returns them so the sheet can follow their progress.
    @MainActor @discardableResult
    func reclaim(_ plan: Basket.Plan, deleteNow: Bool) -> [CleanupJob] {
        var jobs: [CleanupJob] = []
        if !plan.purge.isEmpty {
            var o = CleanupOptions(); o.permanent = deleteNow
            jobs.append(startCleanup(CleanupPlan(mode: .purgeArtifacts, entries: plan.purge), options: o))
        }
        if !plan.removeSafe.isEmpty {
            var o = CleanupOptions(); o.permanent = deleteNow; o.vault = false
            jobs.append(startCleanup(CleanupPlan(mode: .removeWorkspaces, entries: plan.removeSafe), options: o))
        }
        if !plan.removeRisky.isEmpty {
            var o = CleanupOptions(); o.permanent = false; o.vault = true; o.includeDanger = true
            jobs.append(startCleanup(CleanupPlan(mode: .removeWorkspaces, entries: plan.removeRisky), options: o))
        }
        return jobs
    }
}

// MARK: Undo

/// How a removed item comes back: out of the Trash, or from its branch on the remote. Kept in `restores.json`.
struct RestoreRecord: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var name: String
    var bytes: Int64
    var path: String           // where it lived
    var trash: String?         // where the Trash put it, if it went there
    var repo: String?          // the main checkout, for a worktree we can recreate
    var branch: String?
    var restored = false
    var canRestore: Bool { !restored && (trash != nil || (repo != nil && branch != nil)) }
}

enum RestoreLog {
    private static let file = "restores.json"
    private static let lock = NSLock()

    static func all() -> [RestoreRecord] { lock.lock(); defer { lock.unlock() }; return Persist.load([RestoreRecord].self, file) ?? [] }

    static func add(_ r: RestoreRecord) {
        guard !Demo.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        var l = Persist.load([RestoreRecord].self, file) ?? []
        l.append(r)
        Persist.save(Array(l.suffix(300)), file)
    }

    static func mark(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var l = Persist.load([RestoreRecord].self, file) ?? []
        if let i = l.firstIndex(where: { $0.id == id }) { l[i].restored = true }
        Persist.save(l, file)
    }

    /// Put one item back. Returns nil on success, or what went wrong.
    static func restore(_ r: RestoreRecord) -> String? {
        if let t = r.trash, FileManager.default.fileExists(atPath: t) {
            guard !FileManager.default.fileExists(atPath: r.path) else { return "\(r.name) already exists at its old path." }
            do {
                try FileManager.default.createDirectory(atPath: (r.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: t, toPath: r.path)
            } catch { return error.localizedDescription }
            mark(r.id); return nil
        }
        guard let repo = r.repo, let branch = r.branch else { return "It is no longer in the Trash, and there is no branch to recreate it from." }
        guard !FileManager.default.fileExists(atPath: r.path) else { return "\(r.name) already exists at its old path." }
        _ = Shell.git(repo, ["fetch", "origin", branch])
        var res = Shell.git(repo, ["worktree", "add", r.path, branch])
        if res.status != 0 { res = Shell.git(repo, ["worktree", "add", "-B", branch, r.path, "origin/\(branch)"]) }
        if res.status != 0 { return res.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "git could not recreate the worktree." : res.out }
        mark(r.id); return nil
    }
}
