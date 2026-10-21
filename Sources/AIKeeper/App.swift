import ServiceManagement
import SwiftUI

@main
struct AIKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

    init() {
        Migration.run()   // before anything reads settings
        if Headless.handle(CommandLine.arguments) { exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--deltest"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let p = CleanProgress(); let t0 = Date()
            FastDelete.remove(path, progress: p)
            print("DELTEST freed=\(p.freed.bytesString) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s exists=\(FileManager.default.fileExists(atPath: path)) err=\(p.firstError ?? "none") detail=\(p.detail)")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--vaulttest"), i + 2 < CommandLine.arguments.count {
            let repo = CommandLine.arguments[i + 1], wt = CommandLine.arguments[i + 2]
            var e = Entry(id: "t", kind: .workspace, name: "vt", path: wt, repoPath: repo, repoName: "r", branch: "feat", sources: [.git])
            e.git = Enricher.gitInfo(e); e.exists = true
            print("needs=\(Vault.needsSnapshot(e)) git=\(String(describing: e.git))")
            do {
                let item = try Vault.archive(e)
                print("ARCHIVED bundle=\(item?.hasBundle ?? false) patch=\(item?.hasPatch ?? false) untracked=\(item?.hasUntracked ?? false) bytes=\(item?.bytes ?? 0)")
                try FileManager.default.removeItem(atPath: wt); Shell.git(repo, ["worktree", "prune"])
                try Vault.restore(item!)
                print("RESTORED")
            } catch { print("ERR \(error)") }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--deduptest"), i + 2 < CommandLine.arguments.count {
            let roots = [CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]]
            func free() -> Int64 { Int64((try? URL(fileURLWithPath: "/private/tmp").resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0) }
            let flag = DedupModel.CancelFlag()
            let r = Dedup.analyze(roots: roots, flag: flag) { _ in }
            print("DEDUP groups=\(r.groups.count) dupFiles=\(r.duplicateFiles) reclaim=\(r.reclaim.bytesString) scanned=\(r.scannedFiles)")
            let before = free()
            let m = Dedup.merge(r, flag: flag) { _, _, _ in }
            Thread.sleep(forTimeInterval: 2)
            print("MERGED freedClaimed=\(m.freed.bytesString) failed=\(m.failed) actualFreeDelta=\((free() - before).bytesString)")
            let r2 = Dedup.analyze(roots: roots, flag: flag) { _ in }
            print("AGAIN reclaim=\(r2.reclaim.bytesString)")
            exit(0)
        }
        if CommandLine.arguments.contains("--probe2") {
            let d = DockerCLI.usage(); print("DOCKER err=\(d.error ?? "none") rows=\(d.rows.map { "\($0.type) \($0.size) rec \($0.reclaimable)" })")
            let p = Procs.scanWithMemory(); print("MEM used=\(p.mem.used.bytesString)/\(p.mem.total.bytesString) swap=\(p.mem.swapUsed.bytesString) free=\(p.mem.freePercent)%")
            for g in p.groups.prefix(6) { print("  \(g.name) n=\(g.pids.count) \(g.rss.bytesString) cpu=\(String(format: "%.0f", g.cpu)) dev=\(g.dev)") }
            exit(0)
        }
        if CommandLine.arguments.contains("--tools") {
            let procs = Dictionary(grouping: AgentScanner.scan().filter { $0.kind != .mcp }, by: { $0.kind.toolID ?? "" }).mapValues(\.count)
            for d in ToolCatalog.detect(runningToolIDs: procs) { print("TOOL \(d.found ? "FOUND" : "  -  ") \(d.spec.name.padding(toLength: 12, withPad: " ", startingAt: 0)) running=\(d.running) \(d.evidence)") }
            for r in ToolCatalog.detectProjectRoots() { print("ROOT \(r.path.replacingOccurrences(of: home, with: "~")) repos=\(r.repos) viaTool=\(r.viaTool)") }
            for c in Discovery.codex(force: true) { print("CODEX \(c.path.replacingOccurrences(of: home, with: "~")) repo=\(c.repoPath ?? "BROKEN LINK")") }
            for c in Discovery.superset(force: true) { print("SUPERSET \(c.path.replacingOccurrences(of: home, with: "~")) branch=\(c.branch ?? "-") repo=\(c.repoName ?? "-")") }
            let u = UsageParser.load()
            for t in AgentTool.allCases { let r = u.rows.filter { $0.agent == t }; print("USAGE \(t.rawValue): rows=\(r.count) tokens=\(r.reduce(0) { $0 + $1.tokens }) cost=$\(String(format: "%.2f", r.reduce(0) { $0 + $1.cost }))") }
            for s in u.sessions where s.agent == .pi { print("PI SESSION \(s.title.prefix(50)) | \(s.project) | tokens=\(s.tokens)") }
            let all = Discovery.all().filter { $0.kind == .workspace }
            let counts = Dictionary(grouping: all.flatMap { e in e.sources.map { ($0, e) } }, by: { $0.0 }).mapValues(\.count)
            print("WORKSPACES by source: \(counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted())")
            exit(0)
        }
        if CommandLine.arguments.contains("--gitstatus") {
            var list = Discovery.all().filter { $0.kind == .workspace && $0.exists && ($0.repoPath ?? "").hasSuffix("inferx") || ($0.kind == .workspace && $0.exists && $0.sources.contains(.codex)) || ($0.kind == .workspace && $0.exists && $0.sources.contains(.superset)) }
            var prs: [String: [String: PRInfo]] = [:]
            for i in list.indices {
                var e = list[i]
                e.git = Enricher.gitInfo(e)
                if let r = e.repoPath { if prs[r] == nil { prs[r] = PRService.fetch(repo: r) }; e.pr = e.branch.flatMap { prs[r]?[$0] } }
                if let pr = e.pr, pr.state == "MERGED", let m = pr.mergedAt { e.git?.unpushedAfterMerge = PRService.commitsAfterMerge(path: e.path, mergedAt: m) }
                e.measured = true; e.size = 1
                Classifier.classify(&e, staleDays: 14)
                list[i] = e
            }
            for e in list.sorted(by: { $0.name < $1.name }).prefix(40) {
                let n = e.neededness
                print("\(e.name.padding(toLength: 34, withPad: " ", startingAt: 0)) | \(e.statusPill.0.padding(toLength: 15, withPad: " ", startingAt: 0)) | \((e.gitSummary?.text ?? "-").padding(toLength: 24, withPad: " ", startingAt: 0)) | \(n?.headline ?? "-")")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--system") {
            let sampler = SystemSampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 1.5)
            let s = sampler.sample(); let m = MachineInfo.read()
            print("MACHINE \(m.model) | \(m.chip) | \(m.cores) cores | \(m.memory.bytesString) | \(m.os) | up \(Int(m.uptime / 3600))h")
            print("CPU \(Int(s.cpuTotal * 100))% cores=\(s.cores.count) top=\(s.cores.sorted(by: >).prefix(3).map { "\(Int($0 * 100))%" }) load=\(s.load)")
            print("MEM used=\(s.memUsed.bytesString)/\(s.memTotal.bytesString) avail=\(s.memAvailable.bytesString) swap=\(s.swapUsed.bytesString)/\(s.swapTotal.bytesString) pressure=\(s.pressure)")
            print("DISK used=\(s.diskUsed.bytesString)/\(s.diskTotal.bytesString) read=\(Int64(s.readBps).bytesString)/s write=\(Int64(s.writeBps).bytesString)/s")
            print("NET down=\(Int64(s.netDown).bytesString)/s up=\(Int64(s.netUp).bytesString)/s if=\(s.netInterface ?? "-") ip=\(s.netIP ?? "-")")
            if let b = s.battery { print("BATTERY \(Int(b.level * 100))% charging=\(b.charging) ac=\(b.onAC) mins=\(b.minutesRemaining.map(String.init) ?? "-") cycles=\(b.cycles.map(String.init) ?? "-") health=\(b.healthPercent.map(String.init) ?? "-")% temp=\(b.temperatureC.map { String(format: "%.1f", $0) } ?? "-")") } else { print("BATTERY none") }
            let h = Health.evaluate(s, topCPU: nil, topMemory: nil); print("HEALTH \(h.score) \(h.reason) tips=\(h.tips.map(\.text))")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--jobtest"), i + 3 < CommandLine.arguments.count {
            let dirs = Array(CommandLine.arguments[(i + 1)...(i + 3)])
            Task { @MainActor in
                let store = Store()
                func ws(_ d: String) -> Entry {
                    var e = Entry(id: "t:" + d, kind: .workspace, name: (d as NSString).lastPathComponent, path: d, repoPath: nil, repoName: "t", branch: nil, sources: [.git])
                    e.artifacts = [Artifact(path: d + "/node_modules", bytes: 100_000_000)]; e.size = 100_000_000; e.measured = true
                    return e
                }
                var o = CleanupOptions(); o.permanent = true
                let jobs = dirs.map { store.startCleanup(CleanupPlan(mode: .purgeArtifacts, entries: [ws($0)]), options: o) }
                print("started: \(jobs.map { "\($0.state)" })")
                store.cancelJob(jobs[2])   // queued, so it should cancel without touching its folder
                var last = ""
                for _ in 0..<400 {
                    let now = jobs.map { "\($0.state)" }.joined(separator: ",")
                    if now != last { print("t: \(now)"); last = now }
                    if jobs.allSatisfy({ $0.state == .finished }) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                for (n, j) in jobs.enumerated() { print("job\(n): freed=\(j.outcome?.freed.bytesString ?? "-") cancelled=\(j.outcome?.cancelled ?? false) failures=\(j.outcome?.failures.count ?? -1)") }
                print("active=\(store.activeJobs.count) total=\(store.jobs.count)")
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--disktest"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            Task { @MainActor in
                @MainActor func wait(_ m: DiskModel) async { for _ in 0..<200 { if !m.measuring, !m.nodes.isEmpty { return }; try? await Task.sleep(for: .milliseconds(50)) } }
                let a = DiskModel(); a.open(dir); await wait(a)
                print("1 first visit: \(a.nodes.count) items, measuredAt set=\(a.measuredAt != nil)")
                try? await Task.sleep(for: .milliseconds(600))   // let the background save land
                try? "new".write(toFile: dir + "/added-later.txt", atomically: true, encoding: .utf8)
                let b = DiskModel()   // simulates a relaunch: loads the persisted cache
                b.open(dir)
                print("2 after relaunch, no wait: \(b.nodes.count) items, measuring=\(b.measuring) (cached, no refetch; new file not shown: \(!b.nodes.contains { $0.name == "added-later.txt" }))")
                b.open(dir, force: true); await wait(b)
                try? await Task.sleep(for: .milliseconds(300))
                print("3 after Refresh: \(b.nodes.count) items, shows new file: \(b.nodes.contains { $0.name == "added-later.txt" })")
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--map") {
            let t0 = Date()
            let r = StorageMapper.scan(used: 913_000_000_000)
            print("MAP \(String(format: "%.0f", Date().timeIntervalSince(t0)))s home=\(r.homeTotal.bytesString)")
            for g in r.groups { print("  group \(g.name): \(g.size.bytesString)") }
            for h in r.hotspots { print("  \(h.size.bytesString)  \(h.path.replacingOccurrences(of: home, with: "~")) clean=\(h.cleanable) \(h.hint ?? "")") }
            let repo = Enricher.enrich(Entry(id: "r", kind: .repo, name: "inferx", path: "\(home)/Developer/inferx", repoPath: "\(home)/Developer/inferx", repoName: "inferx", branch: nil, sources: [.git]))
            print("REPO inferx artifacts: \(repo.artifacts.map { "\($0.label)=\($0.bytes.bytesString)" })")
            exit(0)
        }
        if CommandLine.arguments.contains("--probe") {
            for a in SessionPeek.assign(AgentScanner.scan()) where a.kind != .mcp {
                print("AGENT \(a.kind.rawValue) pid=\(a.pid) state=\(a.state) cpu=\(a.cpu) kids=\(a.busyChildren) cost=\(a.cost.map { String(format: "$%.2f", $0) } ?? "-") title=\(a.title ?? "-") cwd=\((a.cwd ?? "?").replacingOccurrences(of: home, with: "~"))")
            }
            let t0 = Date(); let d = UsageParser.load()
            print("USAGE rows=\(d.rows.count) sessions=\(d.sessions.count) parse=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            for tool in AgentTool.allCases {
                let r = d.rows.filter { $0.agent == tool }
                print("  \(tool.rawValue): tokens=\(r.reduce(0) { $0 + $1.tokens }) cost=$\(String(format: "%.2f", r.reduce(0) { $0 + $1.cost })) models=\(Set(r.map(\.model)))")
            }
            for s in d.sessions.sorted(by: { $0.cost > $1.cost }).prefix(5) { print("  TOP \(s.agent.rawValue) $\(String(format: "%.2f", s.cost)) \(s.project) | \(s.title.prefix(60))") }
            if let c = d.codex { print("  CODEX LIMITS 5h=\(c.primaryPct)% weekly=\(c.weeklyPct)% resets=\(c.primaryResets)") }
            exit(0)
        }
        // `AIKeeper --dump`: headless scan, prints a table, for verifying the scanner.
        if CommandLine.arguments.contains("--dump") {
            Task { @MainActor in
                let s = Store()
                await s.scan()
                for e in s.entries.sorted(by: { $0.sizeValue > $1.sizeValue }).prefix(40) {
                    print(String(format: "%9@ %-10@ %-12@ %@ [%@] %@",
                                 (e.size ?? 0).bytesString, "\(e.verdict)", "\(e.safety)", e.name,
                                 e.sources.map(\.rawValue).sorted().joined(separator: "+"), e.reasons.joined(separator: "; ") + " | last=\(e.lastActivity?.description ?? "nil") merged=\(e.git?.merged ?? false) dirty=\(e.git?.dirtyCount ?? -1) art=\(e.artifactBytes.bytesString)"))
                }
                print("workspaces=\(s.workspaces.count) deprecated=\(s.deprecated.count) reclaimable=\(s.reclaimable.bytesString) managed=\(s.managedBytes.bytesString) artifacts_kept=\(s.keptArtifactBytes.bytesString)")
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 620)
                .task {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    await store.bootstrap()
                }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)   // the window can never be narrower than its content needs
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await store.rescan() } }.keyboardShortcut("r")
            }
            CommandMenu("Go") {
                Button("Overview") { store.requestedSection = .overview }.keyboardShortcut("1")
                Button("All workspaces") { store.requestedSection = .all }.keyboardShortcut("2")
                Button("Agents") { store.requestedSection = .agents }.keyboardShortcut("3")
                Button("AI usage") { store.requestedSection = .usage }.keyboardShortcut("4")
                Button("Disk analyzer") { store.requestedSection = .disk }.keyboardShortcut("5")
                Button("System") { store.requestedSection = .memory }.keyboardShortcut("6")
            }
        }

        Settings { SettingsView().environmentObject(store) }

        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            Image(systemName: store.agents.contains { $0.state == .needsInput } ? "exclamationmark.bubble.fill"
                  : store.agents.contains { $0.kind != .mcp } ? "bolt.horizontal.circle.fill" : "externaldrive.badge.checkmark")
        }
        .menuBarExtraStyle(.window)
    }
}

enum Section: Hashable {
    case overview, all, deprecated, tool(Source), leftovers, agents, usage, disk, vault, sessions, dedupe, containers, memory, integrations

    var title: String {
        switch self {
        case .overview: "Overview"
        case .all: "All workspaces"
        case .deprecated: "Deprecated"
        case .tool(let s): s.rawValue
        case .leftovers: "Leftovers"
        case .agents: "Agents"
        case .usage: "AI Usage"
        case .disk: "Disk Analyzer"
        case .vault: "Recently removed"
        case .sessions: "Sessions"
        case .dedupe: "Duplicates"
        case .containers: "Containers"
        case .memory: "System"
        case .integrations: "Tools"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .all: "square.stack.3d.up"
        case .deprecated: "archivebox"
        case .tool(let s): s.symbol
        case .leftovers: "trash.slash"
        case .agents: "bolt.horizontal"
        case .usage: "chart.bar.xaxis"
        case .disk: "chart.pie"
        case .vault: "arrow.uturn.backward.circle"
        case .sessions: "text.bubble"
        case .dedupe: "square.on.square"
        case .containers: "shippingbox"
        case .memory: "gauge.with.dots.needle.67percent"
        case .integrations: "puzzlepiece.extension"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var section: Section? = .overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            ZStack {
            switch section ?? .overview {
            case .overview: OverviewView(go: { section = $0 }, explore: { store.analyzer.open($0); section = .disk })
            case .agents: AgentsView()
            case .usage: UsageView()
            case .disk: DiskView(model: store.analyzer)
            case .vault: VaultView()
            case .sessions: SessionsView()
            case .dedupe: DedupView(model: store.dedup)
            case .containers: DockerView()
            case .memory: SystemView()
            case .integrations: ToolsView()
            case let s: EntryListView(section: s).id(s)
            }
            }
            .id(section)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: section)
            // Inside the content column, not over the sidebar or toolbar.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let a = store.alert {
                    AlertBanner(alert: a, go: { section = $0 })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: store.alert?.id)
        }
        .onChange(of: store.requestedSection) { _, s in if let s { section = s; store.requestedSection = nil } }
        .task {
            if let dir = Screenshots.outDir { await Screenshots.run(store: store, dir: dir) }
            else if let dir = Recording.outDir { await Recording.run(store: store, dir: dir) }
        }
        .sheet(item: $store.plan) { CleanupSheet(plan: $0) }
        .sheet(isPresented: $store.needsOnboarding) { OnboardingView().environmentObject(store).interactiveDismissDisabled() }
        .toolbar {
        }
    }
}

struct ScanFooter: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch store.phase {
                case .discovering:
                    ProgressView().controlSize(.small)
                    Text("Finding workspaces")
                case .measuring(let d, let t):
                    ProgressView(value: Double(d), total: Double(max(t, 1))).frame(width: 60)
                    Text("Measuring \(d) of \(t)").monospacedDigit()
                case .done, .idle:
                    Text(store.lastScan.map { "Scanned \($0.formatted(.relative(presentation: .named)))" } ?? "Not scanned yet")
                        .foregroundStyle(store.lastScan.map { Date().timeIntervalSince($0) > 3600 } ?? true ? Color.orange : .secondary)
                }
            }.font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await store.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(store.isScanning).help("Rescan (⌘R)").accessibilityLabel("Rescan")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var selection: Section?

    /// Tools the user enabled that create workspaces, plus plain Git.
    private var workspaceSources: [Source] {
        ToolCatalog.all.filter { store.enabledTools.contains($0.id) && $0.workspaces }.compactMap(\.source) + [.git]
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarList
            ActivityBar()
            ScanFooter()
        }
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            row(.overview, badge: store.reclaimable > 0 ? store.reclaimable.bytesString : nil, accent: true)
            SwiftUI.Section("Monitor") {
                let running = store.agents.filter { $0.kind != .mcp }
                row(.agents, badge: running.isEmpty ? nil : "\(running.count) running", accent: true)
                row(.memory, badge: nil)
                row(.sessions, badge: store.sessions.isEmpty ? nil : "\(store.sessions.count)")
                row(.usage, badge: String(format: "$%.2f today", store.usage.filter { Calendar.current.isDateInToday($0.day) }.reduce(0) { $0 + $1.cost }))
            }
            SwiftUI.Section("Workspaces") {
                row(.all, badge: "\(store.workspaces.count)")
                row(.deprecated, badge: store.deprecated.isEmpty ? nil : store.total(store.deprecated).bytesString, accent: true)
            }
            SwiftUI.Section("By tool") {
                ForEach(workspaceSources, id: \.self) { s in
                    row(.tool(s), badge: (store.stats.bySource[s] ?? 0).bytesString)
                }
            }
            SwiftUI.Section("Cleanup") {
                row(.leftovers, badge: (store.total(store.orphanSessions) + store.total(store.caches)).bytesString)
                row(.dedupe, badge: nil)
                row(.containers, badge: nil)
                row(.disk, badge: nil)
                row(.vault, badge: store.vault.isEmpty ? nil : "\(store.vault.count)")
            }
            SwiftUI.Section("Setup") {
                row(.integrations, badge: "\(store.enabledTools.count) on")
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ s: Section, badge: String?, accent: Bool = false) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(badge.map { Text($0) })   // no custom color: it stays readable on the selected row
            .tag(s)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("guard.floorGB") private var floorGB = 50.0
    @AppStorage("guard.rateGB") private var rateGB = 10.0
    @AppStorage("notify") private var notify = true
    @AppStorage("budget.daily") private var daily = 0.0
    @AppStorage("budget.weekly") private var weekly = 0.0
    @AppStorage("vault.days") private var vaultDays = 30
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var cliMessage: String?

    var body: some View {
        Form {
            SwiftUI.Section("Workspaces") {
                Stepper(value: $store.staleDays, in: 3...180) { Text("Deprecated after **\(store.staleDays) days** idle") }
                Text("Workspaces with uncommitted changes are never marked safe to remove.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("App") {
                Text("The menu-bar icon can be hidden in System Settings → Menu Bar. If it's missing, your menu bar is full: macOS hides items that don't fit beside the notch. AI Keeper is always in the Dock and in Applications.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = on; loginError = nil }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled; loginError = error.localizedDescription }
                }))
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            SwiftUI.Section("Tools") {
                Text("\(store.enabledTools.count) tools tracked. Change them on the Tools page in the sidebar.").font(.caption).foregroundStyle(.secondary)
                Button("Run setup again") { store.needsOnboarding = true }
            }
            SwiftUI.Section("Disk guard") {
                Stepper(value: $floorGB, in: 5...500, step: 5) { Text("Alert when free space drops below **\(Int(floorGB)) GB**") }
                Stepper(value: $rateGB, in: 1...100) { Text("Alert when **\(Int(rateGB)) GB** disappears in 10 minutes") }
                Toggle("Send notifications", isOn: $notify)
            }
            SwiftUI.Section("AI spend (0 = off)") {
                Stepper(value: $daily, in: 0...1000, step: 5) { Text("Daily budget: **\(daily == 0 ? "off" : String(format: "$%.0f", daily))**") }
                Stepper(value: $weekly, in: 0...5000, step: 25) { Text("Weekly budget: **\(weekly == 0 ? "off" : String(format: "$%.0f", weekly))**") }
            }
            SwiftUI.Section("Agent access") {
                Text("Let your coding agents check disk space and clean their own build folders. Everything is a dry run unless the agent passes confirm.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Install command-line tool") { cliMessage = CLIInstaller.install() }
                    if let m = cliMessage { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                HStack(alignment: .top) {
                    Text(CLIInstaller.mcpCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(CLIInstaller.mcpCommand, forType: .string) }.controlSize(.small)
                }
            }
            SwiftUI.Section("Recovery") {
                Stepper(value: $vaultDays, in: 1...365) { Text("Keep removed-workspace snapshots **\(vaultDays) days**") }
            }
        }
        .formStyle(.grouped).frame(width: 520, height: 740)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = store.agents.filter { $0.kind != .mcp }
        VStack(alignment: .leading, spacing: 10) {
            Label("\(running.count) agent\(running.count == 1 ? "" : "s") running", systemImage: "bolt.horizontal")
            ForEach(running.prefix(5)) { a in
                Text("\(a.kind.rawValue) · \(store.workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? "—")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            ForEach(store.activeJobs.prefix(1)) { JobMenuLine(job: $0) }
            Label("\(store.disk.available.bytesString) free", systemImage: "internaldrive")
            Label("\(store.reclaimable.bytesString) reclaimable", systemImage: "leaf").foregroundStyle(Brand.reclaim)
            Divider()
            Button("Open AI Keeper") {
                openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14).frame(width: 260, alignment: .leading)
    }
}
