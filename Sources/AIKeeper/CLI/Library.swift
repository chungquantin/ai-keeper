import Foundation

enum Pick { case found(Entry), failed(String) }

/// What every command shares: the saved scan, name resolution, a headless scan and cleanup runner.
/// All of it reuses the app's own logic (Discovery, Enricher, Classifier, Cleaner), so the CLI and the window never disagree.
enum Library {
    static var staleDays: Int {
        let v = UserDefaults.standard.integer(forKey: "staleDays"); return v == 0 ? 14 : v
    }

    static func entries() -> [Entry] { Persist.load([Entry].self, "scan.json") ?? [] }
    static func save(_ entries: [Entry]) { Persist.save(entries, "scan.json") }

    static var scanDate: Date? {
        let url = Persist.dir.appendingPathComponent("scan.json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// The saved scan, or nil (with a hint) when there isn't one yet.
    static func requireScan() -> [Entry]? {
        let e = entries()
        if e.isEmpty { Out.fail("no scan yet. Run `keeper scan` first (or open AI Keeper once).") ; return nil }
        if let d = scanDate, Date().timeIntervalSince(d) > 6 * 3600 { Out.note(Term.dim("Scan is \(Fmt.ago(d)). Run `keeper scan` to refresh.")) }
        return e
    }

    // MARK: Selecting entries

    static func tools(_ e: Entry) -> [String] { e.sources.sorted { $0.rawValue < $1.rawValue }.map { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") } }

    /// A workspace by exact path, `repo/name`, name, or a unique prefix of the name.
    static func resolve(_ sel: String, in list: [Entry], kinds: Set<Kind> = [.workspace, .repo]) -> Pick {
        let pool = list.filter { kinds.contains($0.kind) }
        let path = URL(fileURLWithPath: (sel as NSString).expandingTildeInPath).standardizedFileURL.path
        if let e = pool.first(where: { $0.path == path }) { return .found(e) }
        let s = sel.lowercased()
        var hits = pool.filter { $0.name.lowercased() == s || "\($0.repoName)/\($0.name)".lowercased() == s }
        if hits.isEmpty { hits = pool.filter { $0.name.lowercased().hasPrefix(s) } }
        if hits.count == 1 { return .found(hits[0]) }
        if hits.isEmpty { return .failed("no workspace matches '\(sel)'. Try `keeper workspaces`.") }
        let names = hits.prefix(6).map { "  \($0.repoName)/\($0.name)  \(Fmt.tilde($0.path))" }.joined(separator: "\n")
        return .failed("'\(sel)' matches \(hits.count) workspaces; use the path or repo/name:\n\(names)")
    }

    static func statusText(_ e: Entry) -> String { e.statusPill.0 }

    static func dict(_ e: Entry) -> [String: Any] {
        var o: [String: Any] = [
            "name": e.name, "repo": e.repoName, "path": e.path, "kind": e.kind.rawValue, "tools": tools(e),
            "size_bytes": e.size ?? 0, "rebuildable_bytes": e.artifactBytes, "status": statusText(e),
            "safety": ["safe", "caution", "danger"][e.safety.rawValue], "deprecated": e.verdict == .deprecated,
            "reasons": e.reasons, "exists": e.exists,
        ]
        if let b = e.branch { o["branch"] = b }
        if let l = e.lastActivity { o["last_active"] = Fmt.iso(l) }
        if let g = e.git {
            o["git"] = ["uncommitted_files": g.dirtyCount, "unpushed_commits": g.unpushed, "ahead_of_base": g.aheadOfBase, "behind_base": g.behindBase,
                        "merged": g.merged, "default_branch": g.defaultBranch, "last_commit": Fmt.iso(g.lastCommit) as Any, "last_subject": g.lastSubject as Any]
        }
        if let p = e.pr { o["pr"] = ["number": p.number, "state": p.state, "title": p.title, "url": p.url, "checks": p.checks as Any, "review": p.review as Any] }
        if !e.artifacts.isEmpty { o["artifacts"] = e.artifacts.map { ["path": $0.path, "bytes": $0.bytes] } }
        return o
    }

    // MARK: Agents

    static func agents() -> [AgentProc] { SessionPeek.assign(AgentScanner.scan()) }

    static func agents(in e: Entry, from all: [AgentProc]) -> [AgentProc] {
        all.filter { $0.kind != .mcp && ($0.cwd == e.path || ($0.cwd?.hasPrefix(e.path + "/") ?? false)) }
    }

    // MARK: Scanning

    /// The same steps as the app's Rescan: discover, measure with git and build folders, classify, look up PRs.
    static func scan(prs: Bool) -> [Entry] {
        Out.status("Discovering workspaces…")
        let found = Discovery.all()
        var results = [Entry?](repeating: nil, count: found.count)
        let lock = NSLock()
        var done = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3        // each worker spawns git and du; more only makes the rest of the Mac wait
        queue.qualityOfService = .background
        for (i, e) in found.enumerated() {
            queue.addOperation {
                let r = Enricher.enrich(e)
                lock.lock(); results[i] = r; done += 1; let n = done; lock.unlock()
                Out.status("Measuring \(n)/\(found.count)")
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        var list = results.compactMap { $0 }.sorted { $0.name < $1.name }
        for i in list.indices { Classifier.classify(&list[i], staleDays: staleDays) }

        if prs, PRService.gh != nil {
            let repos = Set(list.filter { $0.kind == .workspace }.compactMap(\.repoPath))
            for (n, repo) in repos.enumerated() {
                Out.status("Checking pull requests \(n + 1)/\(repos.count)")
                let found = PRService.fetch(repo: repo)
                guard !found.isEmpty else { continue }
                for i in list.indices where list[i].repoPath == repo && list[i].kind == .workspace {
                    list[i].pr = list[i].branch.flatMap { found[$0] }
                    if let pr = list[i].pr, pr.state == "MERGED", let m = pr.mergedAt, list[i].exists {
                        let path = list[i].path
                        list[i].git?.unpushedAfterMerge = PRService.commitsAfterMerge(path: path, mergedAt: m)
                    }
                    Classifier.classify(&list[i], staleDays: staleDays)
                }
            }
        }
        Out.endStatus()
        save(list)
        return list
    }

    // MARK: Cleaning

    /// The rules for what may be removed or cleaned, shared by every command and the interactive screens.
    static func guardTargets(_ chosen: [Entry], mode: PlanMode, includeDanger: Bool, includeRunning: Bool) -> (targets: [Entry], skipped: [(String, String)]) {
        let running = agents()
        var targets: [Entry] = [], skipped: [(String, String)] = []
        for e in chosen {
            if e.kind == .repo, mode == .removeWorkspaces { skipped.append((e.name, "a main checkout is never removed (use `keeper clean` for its build folders)")); continue }
            if !e.exists { skipped.append((e.name, "already gone")); continue }
            if mode == .removeWorkspaces, e.safety == .danger, !includeDanger { skipped.append((e.name, "has work that exists nowhere else; add --danger to remove it anyway")); continue }
            if mode == .purgeArtifacts, e.artifacts.isEmpty { continue }
            let found = agents(in: e, from: running)
            if !found.isEmpty, !includeRunning { skipped.append((e.name, "\(found.first!.kind.rawValue) is running in it (pid \(found.first!.pid))")); continue }
            targets.append(e)
        }
        return (targets, skipped)
    }

    struct Progress { var index: Int; var count: Int; var name: String; var freed: Int64; var total: Int64; var detail: String }

    struct Outcome {
        var freed: Int64 = 0
        var done: [Entry] = []
        var failures: [(name: String, error: String)] = []
    }

    /// Runs the deletion off the main thread and draws progress on stderr until it finishes. Ctrl-C stops after the current item.
    static func execute(_ mode: PlanMode, _ targets: [Entry], options: CleanupOptions, all: inout [Entry], onProgress: ((Progress) -> Void)? = nil) -> Outcome {
        var outcome = Outcome()
        let prog = CleanProgress()
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { prog.cancel() }
        sigint.resume()
        defer { sigint.cancel(); signal(SIGINT, SIG_DFL) }

        let total = targets.reduce(Int64(0)) { $0 + (mode == .removeWorkspaces ? ($1.size ?? 0) : $1.artifactBytes) }
        var settled: Int64 = 0
        for (i, e) in targets.enumerated() {
            if prog.isCancelled { break }
            var result: Result<Int64, Error> = .success(0)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                result = Result { try mode == .removeWorkspaces ? Cleaner.remove(e, options: options, progress: prog) : Cleaner.purgeArtifacts(e, permanent: options.permanent, progress: prog) }
                finished.signal()
            }
            while finished.wait(timeout: .now() + 0.2) == .timedOut {
                if let onProgress {
                    onProgress(Progress(index: i + 1, count: targets.count, name: e.name, freed: max(settled, prog.freed), total: total, detail: prog.detail))
                } else {
                    let detail = prog.detail.isEmpty ? "" : "  " + Fmt.tilde(prog.detail)
                    Out.status("[\(i + 1)/\(targets.count)] \(e.name)  \(Fmt.size(max(settled, prog.freed))) of \(Fmt.size(total))\(detail)")
                }
            }
            switch result {
            case .success(let freed) where !prog.isCancelled:
                outcome.freed += freed; settled += mode == .removeWorkspaces ? (e.size ?? 0) : e.artifactBytes
                outcome.done.append(e)
                if mode == .removeWorkspaces { all.removeAll { $0.id == e.id } }
                else if let idx = all.firstIndex(where: { $0.id == e.id }) { all[idx].size = max(0, (all[idx].size ?? 0) - freed); all[idx].artifacts = [] }
            case .success: break
            case .failure(let err): outcome.failures.append((e.name, err.localizedDescription))
            }
        }
        if onProgress == nil { Out.endStatus() }
        if prog.isCancelled, onProgress == nil { Out.note("Stopped. What was already deleted stays deleted.") }
        save(all)
        return outcome
    }

    /// Prints what a destructive command is about to do, and returns true when it was a dry run.
    static func printPlan(title: String, rows: [[Out.Cell]], headers: [String], total: Int64, skipped: [(String, String)], yes: Bool) {
        Out.line(Term.bold(title))
        Out.line(Out.table(headers, rows, right: [0]))
        Out.line()
        Out.line("Total  \(Term.bold(Fmt.size(total)))")
        for s in skipped { Out.note(Term.yellow("Skipped ") + s.0 + ": " + s.1) }
        if !yes { Out.line(); Out.line(Term.dim("Dry run. Nothing was changed. Add --yes to do it.")) }
    }
}
