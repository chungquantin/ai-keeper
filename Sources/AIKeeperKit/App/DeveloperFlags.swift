import SwiftUI

// Command-line switches for developing the app: headless scans, timing runs and (in debug builds only) destructive tests.
// They run before any window exists, and each one prints and exits.
enum DeveloperFlags {
    @MainActor static func run() {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--pixelshots"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { PixelShots.run(CommandLine.arguments[i + 1]) }
            exit(0)
        }
        #endif
        #if DEBUG   // destructive developer tests never ship in the release binary
        if let i = CommandLine.arguments.firstIndex(of: "--deltest"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let p = CleanProgress(); let t0 = Date()
            FastDelete.remove(path, progress: p)
            print("DELTEST freed=\(p.freed.bytesString) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s exists=\(FileManager.default.fileExists(atPath: path)) err=\(p.firstError ?? "none") detail=\(p.detail)")
            exit(0)
        }
        #endif
        #if DEBUG   // destructive developer tests never ship in the release binary
        if let i = CommandLine.arguments.firstIndex(of: "--vaulttest"), i + 2 < CommandLine.arguments.count {
            let repo = CommandLine.arguments[i + 1], wt = CommandLine.arguments[i + 2]
            var e = Entry(id: "t", kind: .workspace, name: "vt", path: wt, repoPath: repo, repoName: "r", branch: "feat", sources: [.git])
            e.git = Enricher.gitInfo(e); e.exists = true
            print("needs=\(Vault.needsSnapshot(e)) git=\(String(describing: e.git))")
            do {
                let item = try Vault.archive(e)
                print("ARCHIVED bundle=\(item?.hasBundle ?? false) patch=\(item?.hasPatch ?? false) untracked=\(item?.hasUntracked ?? false) bytes=\(item?.bytes ?? 0)")
                try FileManager.default.removeItem(atPath: wt); _ = Shell.git(repo, ["worktree", "prune"])
                try Vault.restore(item!)
                print("RESTORED")
            } catch { print("ERR \(error)") }
            exit(0)
        }
        #endif
        #if DEBUG   // destructive developer tests never ship in the release binary
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
        #endif
        if CommandLine.arguments.contains("--probe2") {
            let d = DockerCLI.usage(); print("DOCKER err=\(d.error ?? "none") rows=\(d.rows.map { "\($0.type) \($0.size) rec \($0.reclaimable)" })")
            let p = Procs.scanWithMemory(); print("MEM used=\(p.mem.used.bytesString)/\(p.mem.total.bytesString) swap=\(p.mem.swapUsed.bytesString) free=\(p.mem.freePercent)%")
            for g in p.groups.prefix(6) { print("  \(g.name) n=\(g.pids.count) \(g.rss.bytesString) cpu=\(String(format: "%.0f", g.cpu)) dev=\(g.dev)") }
            exit(0)
        }
        // `AIKeeper --traces`: reads the session logs and prints totals only (never their text), to check the index and how long it takes.
        if CommandLine.arguments.contains("--traces") {
            let t0 = Date()
            let all = TraceIndexer.load()
            let a = TraceAgg.compute(all, from: Date().addingTimeInterval(-30 * 86_400), to: Date().addingTimeInterval(60))
            print("TRACES \(all.count) sessions of \(TraceIndexer.files().count) logs in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            print("  prompts=\(a.prompts) toolCalls=\(a.toolCalls) failed=\(a.toolErrors) (\(String(format: "%.1f", a.failRate * 100))%) denied=\(a.denials) edits=\(a.edits) loops=\(a.loops.count)")
            print("  hooks: runs=\(a.hookRuns) failed=\(a.hookErrors) apiErrors=\(a.apiErrors) compactions=\(a.compactions) idleBreaks=\(a.idleBreaks) over150K=\(a.bigContext)")
            print("  median session=\(Int(TraceAgg.median(a.sessionSeconds) / 60))min firstEdit=\(Int(TraceAgg.median(a.firstEdit)))s turn p50=\(Int(TraceAgg.median(a.turnSeconds)))s p95=\(Int(TraceAgg.percentile(a.turnSeconds, 0.95)))s out=\(Int(a.outputSpeed)) tok/s")
            print("  commands=\(a.cmdRuns.count) failing=\(a.cmdFails.count) mcpServersUsed=\(a.mcp.count) skillsUsed=\(a.skills.count) hooksSeen=\(a.hooks.count)")
            print("  config: mcp=\(AgentConfig.mcpServers().count) hooks=\(AgentConfig.hooks().count)")
            exit(0)
        }
        // `AIKeeper --tracedetail`: reads the newest Claude Code log in full and prints counts only, to check the trace page's loader.
        if CommandLine.arguments.contains("--tracedetail") {
            guard let f = TraceIndexer.files().first else { print("no logs"); exit(0) }
            let t0 = Date()
            let s = SessionInfo(file: f.path, sessionID: "", agent: .claude, title: "", cwd: "", project: "", first: Date(), last: Date(), cost: 0, tokens: 0, bytes: 0)
            let d = TraceDetailLoader.load(s, summary: nil)
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("DETAIL \(size / 1_000_000) MB log in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: turns=\(d.turns.count) toolCalls=\(d.toolCalls) failed=\(d.failed) modelCalls=\(d.modelCalls) files=\(d.files.count) models=\(d.models.count) cost=$\(String(format: "%.2f", d.cost)) working=\(Int(d.seconds / 60))min")
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
        #if DEBUG   // destructive developer tests never ship in the release binary
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
        #endif
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
}
