import Foundation
import SQLite3

/// Finds workspace candidates from Conductor, Claude and plain Git worktrees.
enum Discovery {
    static let conductorDB = "\(home)/Library/Application Support/com.conductor.app/conductor.db"
    static let claudeWorktreeIndex = "\(home)/Library/Application Support/Claude/git-worktrees.json"
    static var repoRoots: [String] { ToolSettings.roots }
    static let supersetDB = "\(home)/.superset/local.db"

    static func all() -> [Entry] {
        var byPath: [String: Candidate] = [:]
        func merge(_ c: Candidate) {
            let key = URL(fileURLWithPath: c.path).standardizedFileURL.path
            guard var cur = byPath[key] else {
                var n = c; n.path = key; byPath[key] = n; return
            }
            cur.repoPath = cur.repoPath ?? c.repoPath
            cur.repoName = cur.repoName ?? c.repoName
            cur.branch = cur.branch ?? c.branch
            cur.conductorState = cur.conductorState ?? c.conductorState
            if let l = c.lastActivity { cur.lastActivity = max(cur.lastActivity ?? l, l) }
            byPath[key] = cur
        }

        var sources: [String: Set<Source>] = [:]
        func tag(_ c: Candidate) {
            merge(c)
            let key = URL(fileURLWithPath: c.path).standardizedFileURL.path
            sources[key, default: []].insert(c.source)
            if let s = Source.infer(from: key) { sources[key, default: []].insert(s) }
        }

        var repos = Set<String>()
        for c in conductor() { tag(c); if let r = c.repoPath { repos.insert(r) } }
        for c in claude() { tag(c); if let r = c.repoPath { repos.insert(r) } }
        for c in codex() { tag(c); if let r = c.repoPath { repos.insert(r) } }
        for c in superset() { tag(c); if let r = c.repoPath { repos.insert(r) } }
        repos.formUnion(localRepos())
        for repo in repos where FileManager.default.fileExists(atPath: repo + "/.git") {
            for c in gitWorktrees(repo: repo) { tag(c) }
        }

        // Main checkouts have a `.git` directory; linked worktrees have a `.git` file.
        func isMainCheckout(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p + "/.git", isDirectory: &isDir) && isDir.boolValue
        }
        var out: [Entry] = byPath.filter { !isMainCheckout($0.key) }.map { path, c in
            let repoName = c.repoName ?? c.repoPath.map { ($0 as NSString).lastPathComponent } ?? "—"
            return Entry(
                id: "ws:" + path, kind: .workspace,
                name: (path as NSString).lastPathComponent, path: path,
                repoPath: c.repoPath, repoName: repoName, branch: c.branch,
                sources: sources[path] ?? [c.source], conductorState: c.conductorState,
                lastActivity: c.lastActivity,
                exists: FileManager.default.fileExists(atPath: path))
        }
        for repo in repos where FileManager.default.fileExists(atPath: repo + "/.git") {
            let name = (repo as NSString).lastPathComponent
            out.append(Entry(id: "repo:" + repo, kind: .repo, name: name, path: repo, repoPath: repo,
                             repoName: name, branch: nil, sources: [.git], note: "Main checkout"))
        }
        out += orphanSessions()
        out += caches()
        return out
    }

    // MARK: Conductor

    static func conductor(force: Bool = false) -> [Candidate] {
        guard force || ToolSettings.enabled("conductor") else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(conductorDB, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT w.directory_name, w.state, w.branch, w.updated_at, w.workspace_path, r.name, r.root_path
        FROM workspaces w LEFT JOIN repos r ON r.id = w.repository_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        func col(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            let s = String(cString: c)
            return s.isEmpty ? nil : s
        }
        var out: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dir = col(0) else { continue }
            let repoName = col(5)
            let path = col(4) ?? "\(home)/conductor/workspaces/\(repoName ?? "")/\(dir)"
            out.append(Candidate(
                path: path, repoPath: col(6), repoName: repoName, branch: col(2),
                source: .conductor, conductorState: col(1), lastActivity: parseDate(col(3))))
        }
        return out
    }

    // MARK: Claude

    static func claude(force: Bool = false) -> [Candidate] {
        guard force || ToolSettings.enabled("claude") else { return [] }
        var out: [Candidate] = []
        if let data = FileManager.default.contents(atPath: claudeWorktreeIndex),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let wts = json["worktrees"] as? [String: [String: Any]] {
            for (_, w) in wts {
                guard let path = w["path"] as? String else { continue }
                let base = w["baseRepo"] as? String
                let created = (w["createdAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                out.append(Candidate(
                    path: path, repoPath: base, repoName: base.map { ($0 as NSString).lastPathComponent },
                    branch: w["branch"] as? String, source: .claude, lastActivity: created))
            }
        }
        // Worktrees on disk the index doesn't know about.
        for repo in localRepos() {
            let dir = repo + "/.claude/worktrees"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                out.append(Candidate(
                    path: dir + "/" + name, repoPath: repo,
                    repoName: (repo as NSString).lastPathComponent, source: .claude))
            }
        }
        return out
    }

    // MARK: Codex

    /// `~/.codex/worktrees/<id>/<repo>`: each is a git worktree whose `.git` file names the owning repo.
    static func codex(force: Bool = false) -> [Candidate] {
        guard force || ToolSettings.enabled("codex") else { return [] }
        let root = "\(home)/.codex/worktrees"
        var out: [Candidate] = []
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !id.hasPrefix(".") {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(id)")) ?? [] where !name.hasPrefix(".") {
                let path = "\(root)/\(id)/\(name)"
                let repo = owningRepo(ofWorktree: path)
                out.append(Candidate(path: path, repoPath: repo, repoName: repo.map { ($0 as NSString).lastPathComponent } ?? name,
                                     source: .codex))
            }
        }
        return out
    }

    /// `.git` file of a linked worktree: `gitdir: /repo/.git/worktrees/<name>`.
    static func owningRepo(ofWorktree path: String) -> String? {
        guard let s = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let r = s.range(of: "/.git/worktrees/") else { return nil }
        let head = s[..<r.lowerBound]
        guard let colon = head.range(of: "gitdir: ") else { return nil }
        return String(head[colon.upperBound...])
    }

    // MARK: Superset

    /// Worktrees registered in Superset's local database, plus folders on disk it may have lost track of.
    static func superset(force: Bool = false) -> [Candidate] {
        guard force || ToolSettings.enabled("superset") else { return [] }
        var out: [Candidate] = []
        var db: OpaquePointer?
        if sqlite3_open_v2(supersetDB, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            let sql = "SELECT w.path, w.branch, w.created_at, p.name, p.main_repo_path FROM worktrees w JOIN projects p ON p.id = w.project_id"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                func col(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let path = col(0) else { continue }
                    let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000)
                    out.append(Candidate(path: path, repoPath: col(4), repoName: col(3), branch: col(1), source: .superset, lastActivity: created))
                }
            }
        }
        // On-disk worktrees (a `.git` file) up to three levels under ~/.superset/worktrees.
        let known = Set(out.map(\.path))
        func walk(_ dir: String, depth: Int) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let p = "\(dir)/\(name)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                if FileManager.default.fileExists(atPath: p + "/.git") {
                    if !known.contains(p) {
                        let repo = owningRepo(ofWorktree: p)
                        out.append(Candidate(path: p, repoPath: repo, repoName: repo.map { ($0 as NSString).lastPathComponent }, source: .superset))
                    }
                } else if depth < 3 { walk(p, depth: depth + 1) }
            }
        }
        walk("\(home)/.superset/worktrees", depth: 1)
        return out
    }

    // MARK: Git

    static func localRepos() -> [String] {
        var repos: [String] = []
        for root in repoRoots {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                let p = root + "/" + name
                if FileManager.default.fileExists(atPath: p + "/.git") { repos.append(p) }
            }
        }
        return repos
    }

    static func gitWorktrees(repo: String) -> [Candidate] {
        let r = Shell.git(repo, ["worktree", "list", "--porcelain"])
        guard r.status == 0 else { return [] }
        var out: [Candidate] = []
        var path: String?, branch: String?
        func flush() {
            if let p = path, p != repo {
                out.append(Candidate(path: p, repoPath: repo, repoName: (repo as NSString).lastPathComponent,
                                     branch: branch, source: .git))
            }
            path = nil; branch = nil
        }
        for line in r.out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
        }
        flush()
        return out
    }

    // MARK: Leftovers

    /// Claude transcripts whose project folder no longer exists.
    static func orphanSessions() -> [Entry] {
        let root = "\(home)/.claude/projects"
        var out: [Entry] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + name
            guard let cwd = sessionCwd(in: dir), !FileManager.default.fileExists(atPath: cwd) else { continue }
            let short = cwd.split(separator: "/").suffix(2).joined(separator: "/")
            out.append(Entry(
                id: "ss:" + dir, kind: .sessionData, name: short, path: dir,
                repoPath: nil, repoName: "Claude sessions", branch: nil, sources: [.claude],
                note: "Chat history for a folder that no longer exists",
                lastActivity: newestMTime(in: dir)))
        }
        return out
    }

    static func sessionCwd(in dir: String) -> String? {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }
        for f in files.prefix(5) {
            guard let h = FileHandle(forReadingAtPath: dir + "/" + f) else { continue }
            defer { try? h.close() }
            let data = h.readData(ofLength: 256 * 1024)
            let s = String(decoding: data, as: UTF8.self)
            if let r = s.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) {
                return String(s[r]).dropFirst(7).dropLast().replacingOccurrences(of: "\\/", with: "/")
            }
        }
        return nil
    }

    static func newestMTime(in dir: String) -> Date? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    static let cacheTargets: [(String, String, String, Source)] = [
        ("Claude edit-rewind history", "\(home)/.claude/file-history", "File snapshots used to rewind edits", .claude),
        ("Claude shell snapshots", "\(home)/.claude/shell-snapshots", "Recreated on next session", .claude),
        ("Claude telemetry queue", "\(home)/.claude/telemetry", "Unsent usage events", .claude),
        ("Claude desktop cache", "\(home)/Library/Application Support/Claude/Cache", "Chromium cache, rebuilt automatically", .claude),
        ("Claude desktop code cache", "\(home)/Library/Application Support/Claude/Code Cache", "Chromium cache, rebuilt automatically", .claude),
        ("Conductor logs", "\(home)/Library/Application Support/com.conductor.app/logs", "App logs", .conductor),
        ("Xcode DerivedData", "\(home)/Library/Developer/Xcode/DerivedData", "Build products, rebuilt on demand", .dev),
        ("Xcode device support", "\(home)/Library/Developer/Xcode/iOS DeviceSupport", "Symbols re-downloaded on device connect", .dev),
        ("npm cache", "\(home)/.npm/_cacache", "Re-downloaded when needed", .dev),
        ("pnpm store", "\(home)/Library/pnpm/store", "Re-downloaded when needed", .dev),
        ("Yarn cache", "\(home)/Library/Caches/Yarn", "Re-downloaded when needed", .dev),
        ("Homebrew downloads", "\(home)/Library/Caches/Homebrew", "Old bottles and downloads", .dev),
        ("pip cache", "\(home)/Library/Caches/pip", "Re-downloaded when needed", .dev),
        ("Cargo registry cache", "\(home)/.cargo/registry/cache", "Crates re-downloaded when needed", .dev),
        ("User logs", "\(home)/Library/Logs", "App and crash logs", .dev),
        ("Trash", "\(home)/.Trash", "Already deleted items", .dev),
    ]

    static func caches() -> [Entry] {
        cacheTargets.compactMap { name, path, note, src in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Entry(id: "ca:" + path, kind: .cache, name: name, path: path, repoPath: nil,
                         repoName: "App caches", branch: nil, sources: [src], note: note)
        }
    }

    // MARK: Dates

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }
}
