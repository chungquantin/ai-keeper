import AppKit
import SwiftUI

enum PlanMode { case removeWorkspaces, purgeArtifacts }

struct CleanupPlan: Identifiable {
    let id = UUID()
    let mode: PlanMode
    let entries: [Entry]
}

struct CleanupOptions {
    var vault = true
    var permanent = false
    var deleteMergedBranches = true
    var includeDanger = false
}

struct CleanupStatus {
    var label = ""
    var detail = ""
    var itemIndex = 1
    var itemTotal = 1
    var freed: Int64 = 0
    var total: Int64 = 1
    var started = Date()
    var cancelling = false

    var fraction: Double { min(1, Double(freed) / Double(max(total, 1))) }
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }
    var speed: Double { elapsed > 1 ? Double(freed) / elapsed : 0 }
    var remaining: TimeInterval? { speed > 0 ? Double(max(total - freed, 0)) / speed : nil }
}

struct CleanupOutcome {
    var cancelled = false
    var freed: Int64 = 0
    var failures: [(name: String, error: String)] = []
}

@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case idle, discovering, measuring(done: Int, total: Int), done }

    /// Every view reads totals from `stats`, computed once per change instead of re-filtering on each render.
    @Published var entries: [Entry] = [] { didSet { stats = Stats(entries) } }
    private(set) var stats = Stats([])
    @Published var phase: Phase = .idle
    @Published var disk = DiskInfo()
    @Published var lastScan: Date?
    @Published var plan: CleanupPlan?
    @Published var jobs: [CleanupJob] = []
    var jobRunner: Task<Void, Never>?
    @Published var mapStale = false          // cleanup changed sizes after the last disk scan
    @Published var mapDate: Date?
    nonisolated(unsafe) static weak var current: Store?
    @Published var agents: [AgentProc] = []
    @Published var usage: [UsageRow] = []
    @Published var usageLoading = false
    @Published var map: StorageMapResult?
    @Published var mapRefreshing = false
    @Published var needsOnboarding = false
    @Published var requestedSection: Section?   // set by menu commands, consumed by RootView
    @Published var prRefreshing = false
    @Published var detections: [Detection] = []
    @Published var footprints: [String: Int64] = [:]
    @Published var toolsChanged = false
    @Published var enabledTools: Set<String> = Set(ToolSettings.storedEnabled ?? ToolCatalog.all.map(\.id)) {
        didSet { UserDefaults.standard.set(enabledTools.sorted(), forKey: ToolSettings.enabledKey) }
    }
    @Published var repoRoots: [String] = ToolSettings.roots {
        didSet { UserDefaults.standard.set(repoRoots, forKey: ToolSettings.rootsKey) }
    }
    @Published var samples: [DiskSample] = Persist.load([DiskSample].self, "disk-samples.json") ?? []
    @Published var alert: GuardAlert?
    @Published var vault: [VaultItem] = []
    @Published var sessions: [SessionInfo] = []
    @Published var codexLimits: CodexLimits?
    var agentStates: [Int32: AgentState] = [:]
    var lastAgentKey: [String] = []
    var recentSamples: [DiskSample] = []   // 1-minute resolution, last 30 min, for fast-drop detection only
    var lastScanDate: Date?
    var hasCachedUsage = false
    var workStarted: [Int32: Date] = [:]
    var lastUsageLoad = Date.distantPast
    var snapshots: [SizeSnapshot] = Persist.load([SizeSnapshot].self, "sizes.json") ?? []
    var lastAlert: [String: Date] = [:]
    var lastSampleSave = Date.distantPast
    let analyzer = DiskModel()
    let dedup = DedupModel()
    private var started = false

    init() {
        Store.current = self
        if let age = Persist.age("map.json") { mapDate = Date().addingTimeInterval(-age) }
        if let u = Persist.load(UsageData.self, "usage.json") {   // last known spend, shown instantly
            usage = u.rows; sessions = u.sessions; codexLimits = u.codex; hasCachedUsage = true
            lastUsageLoad = Date()   // the guard loop must not trigger a full reload on its first tick
        }
        entries = Persist.load([Entry].self, "scan.json") ?? []   // show last results instantly while rescanning
        map = Persist.load(StorageMapResult.self, "map.json")
    }
    @Published var staleDays: Int = {
        let v = UserDefaults.standard.integer(forKey: "staleDays"); return v == 0 ? 14 : v
    }() {
        didSet {
            UserDefaults.standard.set(staleDays, forKey: "staleDays")
            reclassifyAll()
        }
    }

    var isScanning: Bool { phase == .discovering || { if case .measuring = phase { return true } else { return false } }() }

    // MARK: Derived numbers

    var workspaces: [Entry] { stats.workspaces }
    var deprecated: [Entry] { stats.deprecated }
    /// Everything that can hold rebuildable folders: worktrees and main checkouts.
    var buildHolders: [Entry] { stats.buildHolders }
    var removableWorkspaces: [Entry] { stats.removable }
    var orphanSessions: [Entry] { stats.orphans }
    var caches: [Entry] { stats.caches }

    func total(_ list: [Entry]) -> Int64 { list.reduce(0) { $0 + max($1.size ?? 0, 0) } }

    /// Rebuildable folders inside workspaces we're *keeping* (removed ones free them anyway).
    var keptArtifactBytes: Int64 { stats.keptArtifactBytes }
    var reclaimable: Int64 { stats.reclaimable }
    var managedBytes: Int64 { stats.managedBytes }
    /// False until at least one entry has real numbers, so the UI shows progress instead of "0 KB".
    var hasData: Bool { stats.measuredCount > 0 }

    // MARK: Startup, agents, usage

    /// Idempotent: the window can be closed and reopened from the menu bar.
    func bootstrap() async {
        guard !started else { return }
        started = true
        Vault.purgeExpired(days: Int(UserDefaults.standard.number("vault.days", default: 30)))
        refreshVault()
        if ToolSettings.onboarded { Notifier.requestPermission() }
        // Poll every 4s while the app is in front; every ~20s when it's in the background (the menu bar still updates).
        Task {
            var tick = 0
            while !Task.isCancelled {
                if NSApp.isActive || tick % 5 == 0 { await refreshAgents() }
                tick += 1
                try? await Task.sleep(for: .seconds(4))
            }
        }
        Task { while !Task.isCancelled { await guardTick(); try? await Task.sleep(for: .seconds(30)) } }
        guard ToolSettings.onboarded else {
            needsOnboarding = true   // first launch: let the user pick tools before anything is scanned
            await detectTools()
            return
        }
        // Cached spend is already on screen; refresh it quietly once the UI has settled.
        if hasCachedUsage { Task { try? await Task.sleep(for: .seconds(12)); loadUsage() } } else { loadUsage() }
        // A fresh cache is good enough: re-measuring everything on each launch is what made startup heavy.
        let scanAge = Persist.age("scan.json")
        if let scanAge, scanAge < 30 * 60, !entries.isEmpty {
            lastScan = Date().addingTimeInterval(-scanAge); phase = .done
        } else { await scan() }
    }

    func finishOnboarding() async {
        UserDefaults.standard.set(true, forKey: ToolSettings.onboardedKey)
        needsOnboarding = false
        toolsChanged = false
        loadUsage()
        await rescan()
    }

    /// Look for installed tools, then measure their data folders in the background.
    func detectTools() async {
        await refreshAgents()
        let running = Dictionary(grouping: agents.filter { $0.kind != .mcp }, by: { $0.kind.toolID ?? "" }).mapValues(\.count)
        detections = await Task.detached { ToolCatalog.detect(runningToolIDs: running) }.value
        let paths = detections.compactMap { d in d.dataPath.map { (d.id, $0) } }
        Task {
            for (id, path) in paths {
                footprints[id] = await Task.detached(priority: .utility) { Shell.du(path) }.value
            }
        }
    }

    /// Workspace scan and whole-disk map run side by side.
    func rescan() async {
        async let ws: () = scan()
        async let mp: () = scanMap()
        _ = await (ws, mp)
    }

    func scanMap() async {
        mapRefreshing = true
        defer { mapRefreshing = false }
        refreshDisk()
        let used = disk.used
        map = await Task.detached(priority: .utility) { StorageMapper.scan(used: used) }.value
        if let m = map { Persist.save(m, "map.json") }
        mapDate = .now
        mapStale = false
    }

    /// The disk map is fetched once, in the background, the first time it's needed. After that only the Refresh button re-measures it.
    func ensureMap() async {
        guard map == nil, !mapRefreshing else { return }
        await scanMap()
    }

    /// Offer to empty a folder the map identified as safe to clear.
    func cleanHotspot(_ h: Hotspot) {
        var e = Entry(id: "hs:" + h.path, kind: .cache, name: h.name, path: h.path, repoPath: nil,
                      repoName: h.parent, branch: nil, sources: [.dev], note: h.hint ?? "")
        e.size = h.size; e.measured = true; e.verdict = .deprecated
        plan = CleanupPlan(mode: .removeWorkspaces, entries: [e])
    }

    func refreshAgents() async {
        let list = await Task.detached { SessionPeek.assign(AgentScanner.scan()) }.value
        let shown = list.filter { $0.kind.toolID.map(ToolSettings.enabled) ?? true }.sorted { ($0.state == .needsInput ? 0 : 1) < ($1.state == .needsInput ? 0 : 1) }
        let key = shown.map(\.displayKey)
        if key != lastAgentKey { lastAgentKey = key; agents = shown }   // CPU jitter alone shouldn't re-render every view
        trackTransitions(list)
    }

    func loadUsage() {
        guard !usageLoading else { return }
        usageLoading = true
        Task {
            let d = await Task.detached(priority: .background) { UsageParser.load() }.value
            usage = d.rows; sessions = d.sessions; codexLimits = d.codex
            Task.detached(priority: .background) { Persist.save(d, "usage.json") }
            usageLoading = false
        }
    }

    /// Longest workspace path containing the agent's working directory.
    func workspace(for a: AgentProc) -> Entry? {
        guard let cwd = a.cwd else { return nil }
        return workspaces.filter { cwd == $0.path || cwd.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    func runningAgents(in e: Entry) -> [AgentProc] {
        agents.filter { $0.kind != .mcp && ($0.cwd == e.path || ($0.cwd?.hasPrefix(e.path + "/") ?? false)) }
    }

    // MARK: Scanning

    func scan() async {
        guard !isScanning else { return }
        phase = .discovering
        refreshDisk()
        let found = await Task.detached(priority: .userInitiated) { Discovery.all() }.value
        let cached = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        entries = found.sorted { $0.name < $1.name }.map { f in
            var e = f
            if let c = cached[f.id] {   // keep last known numbers visible until re-measured
                e.size = c.size; e.artifacts = c.artifacts; e.git = c.git; e.measured = c.measured
                e.lastActivity = c.lastActivity ?? e.lastActivity
                Classifier.classify(&e, staleDays: staleDays)
            }
            return e
        }
        let todo = entries
        phase = .measuring(done: 0, total: todo.count)

        // Results arrive hundreds of times; publishing each one re-rendered every view. Batch them.
        var pending: [String: Entry] = [:]
        var lastFlush = Date.distantPast
        func flush(done: Int) {
            if !pending.isEmpty {
                var copy = entries
                let index = Dictionary(uniqueKeysWithValues: copy.enumerated().map { ($1.id, $0) })
                for (id, var e) in pending {
                    guard let i = index[id] else { continue }
                    Classifier.classify(&e, staleDays: staleDays)
                    copy[i] = e
                }
                entries = copy   // one publish for the whole batch
                pending = [:]
            }
            phase = .measuring(done: done, total: todo.count)
            lastFlush = Date()
        }

        await withTaskGroup(of: Entry.self) { group in
            var next = 0, done = 0
            let width = 6
            while next < min(width, todo.count) {
                let e = todo[next]; next += 1
                group.addTask(priority: .utility) { Enricher.enrich(e) }
            }
            while let result = await group.next() {
                pending[result.id] = result
                done += 1
                if Date().timeIntervalSince(lastFlush) > 0.3 { flush(done: done) }
                if next < todo.count {
                    let e = todo[next]; next += 1
                    group.addTask(priority: .utility) { Enricher.enrich(e) }
                }
            }
            flush(done: done)
        }
        phase = .done
        lastScan = .now
        await fetchPRs()
        persistEntries()
        recordSnapshot()
        refreshDisk()
    }

    /// Encoding ~300 KB of JSON on the main thread is a visible hitch; do it in the background.
    func persistEntries() {
        let snapshot = entries
        Task.detached(priority: .utility) { Persist.save(snapshot, "scan.json") }
    }

    /// Replace one entry (used after a partial cleanup re-measures it).
    func replaceEntry(_ result: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == result.id }) else { return }
        var e = result
        Classifier.classify(&e, staleDays: staleDays)
        entries[i] = e
    }

    private func reclassifyAll() {
        var copy = entries
        for i in copy.indices { Classifier.classify(&copy[i], staleDays: staleDays) }
        entries = copy
    }

    func refreshVault() { vault = Vault.list() }

    /// Look up PR state for every branch once per repo, then re-run the classifier.
    func fetchPRs() async {
        guard PRService.gh != nil, !prRefreshing else { return }
        prRefreshing = true
        defer { prRefreshing = false }
        let repos = Set(workspaces.compactMap(\.repoPath))
        for repo in repos {
            let prs = await Task.detached(priority: .utility) { PRService.fetch(repo: repo) }.value
            guard !prs.isEmpty else { continue }
            // Work on a copy and publish once per repo, not once per field per entry.
            var copy = entries
            for i in copy.indices where copy[i].repoPath == repo && copy[i].kind == .workspace {
                copy[i].pr = copy[i].branch.flatMap { prs[$0] }
                if let pr = copy[i].pr, pr.state == "MERGED", let m = pr.mergedAt, copy[i].exists {
                    let path = copy[i].path
                    copy[i].git?.unpushedAfterMerge = await Task.detached(priority: .utility) { PRService.commitsAfterMerge(path: path, mergedAt: m) }.value
                }
                Classifier.classify(&copy[i], staleDays: staleDays)
            }
            entries = copy
        }
        persistEntries()
    }

    func refreshDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            let important = v.volumeAvailableCapacityForImportantUsage ?? 0
            let raw = Int64(v.volumeAvailableCapacity ?? 0)
            let next = DiskInfo(total: Int64(v.volumeTotalCapacity ?? 0), available: important, purgeable: max(0, important - raw))
            // Free space wobbles by a few KB constantly; only publish when it moved enough to matter.
            if abs(next.available - disk.available) > 50_000_000 || next.total != disk.total { disk = next }
        }
    }

    // MARK: Cleanup

    func propose(_ mode: PlanMode, for list: [Entry]) {
        let chosen = mode == .purgeArtifacts
            ? list.filter { ($0.kind == .workspace || $0.kind == .repo) && !$0.artifacts.isEmpty }
            : list.filter { $0.kind != .repo }   // main checkouts are never removed
        guard !chosen.isEmpty else { return }
        plan = CleanupPlan(mode: mode, entries: chosen)
    }

    /// Drop map rows for folders we just deleted so stale sizes don't linger while the rescan runs.
    func forgetFromMap(_ paths: [String]) {
        guard var m = map else { return }
        m.hotspots.removeAll { h in paths.contains { h.path == $0 || h.path.hasPrefix($0 + "/") } }
        map = m
    }

    // MARK: Finder / Terminal

    func reveal(_ e: Entry) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
    func openTerminal(_ e: Entry) {
        NSWorkspace.shared.open([URL(fileURLWithPath: e.path)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Everything derived from `entries`, computed in one pass.
struct Stats {
    var workspaces: [Entry] = []
    var buildHolders: [Entry] = []
    var deprecated: [Entry] = []
    var removable: [Entry] = []
    var orphans: [Entry] = []
    var caches: [Entry] = []
    var keptArtifactBytes: Int64 = 0
    var reclaimable: Int64 = 0
    var managedBytes: Int64 = 0
    var measuredCount = 0
    var staleCount = 0
    var bySource: [Source: Int64] = [:]
    var repoGroups: [RepoGroup] = []
    var biggestArtifact: (holder: String, label: String, bytes: Int64)?

    struct RepoGroup: Identifiable { var id: String { name }; let name: String; let total: Int64; let count: Int; let reclaim: Int64 }

    init(_ entries: [Entry]) {
        var removableBytes: Int64 = 0, orphanBytes: Int64 = 0, cacheBytes: Int64 = 0
        var groups: [String: (total: Int64, count: Int, reclaim: Int64)] = [:]
        for e in entries {
            let size = max(e.size ?? 0, 0)
            managedBytes += size
            if e.measured { measuredCount += 1 }
            switch e.kind {
            case .workspace, .repo:
                buildHolders.append(e)
                let removing = e.verdict == .deprecated && e.safety != .danger
                if e.kind == .workspace {
                    workspaces.append(e)
                    if e.verdict == .deprecated { deprecated.append(e) }
                    if removing { removable.append(e); removableBytes += size }
                }
                if e.verdict == .dangling { staleCount += 1 }
                let keeps = !removing && e.verdict != .dangling
                if keeps { keptArtifactBytes += e.artifactBytes }
                for s in e.sources { bySource[s, default: 0] += size }
                var g = groups[e.repoName] ?? (0, 0, 0)
                g.total += size; g.count += 1; g.reclaim += removing ? size : (e.verdict != .deprecated ? e.artifactBytes : 0)
                groups[e.repoName] = g
                if let a = e.artifacts.max(by: { $0.bytes < $1.bytes }), a.bytes > (biggestArtifact?.bytes ?? 0) {
                    biggestArtifact = (e.name, a.label, a.bytes)
                }
            case .sessionData: orphans.append(e); orphanBytes += size
            case .cache: caches.append(e); cacheBytes += size
            }
        }
        reclaimable = removableBytes + keptArtifactBytes + orphanBytes + cacheBytes
        repoGroups = groups.filter { $0.value.total > 0 }.map { RepoGroup(name: $0.key, total: $0.value.total, count: $0.value.count, reclaim: $0.value.reclaim) }
            .sorted { $0.total > $1.total }.prefix(8).map { $0 }
    }
}

extension AgentProc {
    /// What the UI actually shows. CPU is rounded so jitter alone doesn't count as a change.
    var displayKey: String {
        "\(pid)|\(kind.rawValue)|\(state.rawValue)|\(title ?? "")|\(Int((cost ?? 0) * 100))|\(Int(cpu.rounded()))|\(rssBytes / 20_000_000)|\(cwd ?? "")"
    }
}
