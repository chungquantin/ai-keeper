import Foundation

/// Blocking per-entry measurement: git state, size, rebuildable artifacts.
enum Enricher {
    static let artifactNames = [
        "node_modules", "target", ".venv", "venv", "dist", "build", ".next", ".nuxt", ".turbo",
        ".gradle", "Pods", "DerivedData", ".build", "__pycache__", ".pytest_cache",
        ".parcel-cache", ".svelte-kit", ".cache",
    ]

    static func enrich(_ input: Entry) -> Entry {
        var e = input
        e.exists = FileManager.default.fileExists(atPath: e.path)
        guard e.exists else { e.size = 0; e.measured = true; return e }
        if e.kind == .repo {
            // Only the rebuildable folders matter for a main checkout; worktrees under .claude are separate entries.
            e.artifacts = artifacts(in: e.path, skipDotClaude: true)
            e.size = e.artifactBytes
            e.lastActivity = (try? FileManager.default.attributesOfItem(atPath: e.path)[.modificationDate]) as? Date
            e.measured = true
            return e
        }
        e.size = Shell.du(e.path)
        guard e.kind == .workspace else { e.measured = true; return e }

        var g = gitInfo(e)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: e.path)[.modificationDate]) as? Date
        e.lastActivity = [e.lastActivity, g?.lastCommit, mtime].compactMap { $0 }.max()
        if let b = g?.defaultBranch, g != nil { g?.defaultBranch = b }
        e.git = g
        e.artifacts = artifacts(in: e.path)
        e.measured = true
        return e
    }

    static func gitInfo(_ e: Entry) -> GitInfo? {
        let p = e.path
        guard Shell.git(p, ["rev-parse", "--git-dir"]).status == 0 else { return nil }
        var g = GitInfo()
        g.dirtyCount = Shell.git(p, ["status", "--porcelain"]).out.split(separator: "\n").count
        let ahead = Shell.git(p, ["rev-list", "--count", "@{u}..HEAD"])
        g.hasUpstream = ahead.status == 0
        g.ahead = Int(ahead.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if let ts = TimeInterval(Shell.git(p, ["log", "-1", "--format=%ct"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            g.lastCommit = Date(timeIntervalSince1970: ts)
        }

        let unpushedOut = Shell.git(p, ["rev-list", "--count", "HEAD", "--not", "--remotes"])
        g.unpushed = Int(unpushedOut.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        g.lastSubject = Shell.git(p, ["log", "-1", "--format=%s"]).out.trimmingCharacters(in: .whitespacesAndNewlines)

        let repo = e.repoPath ?? p
        var base = Shell.git(repo, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = ["origin/main", "origin/master", "main", "master"].first {
                Shell.git(repo, ["rev-parse", "--verify", "-q", $0]).status == 0
            } ?? ""
        }
        if !base.isEmpty {
            g.defaultBranch = base.replacingOccurrences(of: "origin/", with: "")
            let head = Shell.git(p, ["rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let tip = Shell.git(p, ["rev-parse", base]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            // Merged = branch had its own commits and they are all in the default branch now.
            // A fresh branch sitting exactly on the tip has nothing to merge, so it doesn't count.
            func count(_ range: String) -> Int { Int(Shell.git(p, ["rev-list", "--count", range]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
            g.aheadOfBase = count("\(base)..HEAD")
            g.behindBase = count("HEAD..\(base)")
            g.merged = head != tip && Shell.git(p, ["merge-base", "--is-ancestor", "HEAD", base]).status == 0
        }
        return g
    }

    /// Git-ignored, well-known build/dependency folders (safe to regenerate).
    static func artifacts(in root: String, skipDotClaude: Bool = false) -> [Artifact] {
        var args = [root, "-maxdepth", "4", "(", "-name", ".git"]
        if skipDotClaude { args += ["-o", "-name", ".claude"] }
        for n in artifactNames { args += ["-o", "-name", n] }
        args += [")", "-type", "d", "-prune", "-print"]
        let found = Shell.run("/usr/bin/find", args).out
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasSuffix("/.git") && !$0.hasSuffix("/.claude") }
        guard !found.isEmpty else { return [] }

        let rel = found.map { String($0.dropFirst(root.count + 1)) }
        let ignored = Set(Shell.git(root, ["check-ignore"] + rel).out.split(separator: "\n").map(String.init))
        return zip(found, rel).filter { ignored.contains($0.1) || ignored.contains($0.1 + "/") }
            .map { Artifact(path: $0.0, bytes: Shell.du($0.0)) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }
}

/// Decides whether an entry is deprecated and how risky removing it is.
enum Classifier {
    static func classify(_ e: inout Entry, staleDays: Int, now: Date = .now) {
        e.reasons = []
        e.safety = .safe
        switch e.kind {
        case .cache:
            e.verdict = .deprecated
            e.reasons = [e.note]
            return
        case .sessionData:
            e.verdict = .deprecated
            e.reasons = [e.note]
            return
        case .repo:
            e.verdict = .active
            return
        case .workspace:
            break
        }
        guard e.exists else {
            e.verdict = .dangling
            e.reasons = ["Folder is gone; only a stale record remains"]
            return
        }
        guard e.measured else { e.verdict = .active; return }

        // A worktree whose link to the repo is gone (repo moved, `git worktree prune` ran): git can't say what's in it.
        if e.git == nil {
            e.verdict = .deprecated
            e.reasons = ["Its link to the repository is broken, so git no longer tracks this folder"]
            e.safety = .caution
            return
        }
        let g = e.git
        let dirty = g?.dirtyCount ?? 0
        let prState = e.pr?.state
        // Squash merges leave no ancestor commit, so the PR is what proves the work landed (unless newer commits exist).
        let landed = (g?.merged ?? false) || (prState == "MERGED" && (g?.unpushedAfterMerge ?? 0) == 0)
        var why: [String] = []
        if e.conductorState == "archived" { why.append("Archived in Conductor but files are still on disk") }
        if dirty == 0 {
            // The PR is authoritative even for a folder touched today: an agent running there blocks removal separately.
            if prState == "MERGED", let n = e.pr?.number { why.append("PR #\(n) was merged") }
            else if prState == "CLOSED", let n = e.pr?.number { why.append("PR #\(n) was closed without merging") }
            else if let g, g.merged { why.append("Branch already merged into \(g.defaultBranch)") }
        }
        if let last = e.lastActivity, dirty == 0, prState != "OPEN" {
            let days = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 0
            if days >= staleDays { why.append("No activity for \(days) days") }
        }
        e.verdict = why.isEmpty ? .active : .deprecated
        e.reasons = why
        if prState == "OPEN", let n = e.pr?.number { e.reasons.append("PR #\(n) is still open") }

        if dirty > 0 {
            e.safety = .danger
            e.reasons.append("\(dirty) uncommitted change\(dirty == 1 ? "" : "s")")
        } else if let g, !landed, g.unpushed > 0 {
            e.safety = .caution
            e.reasons.append("Has commits that exist only in this folder")
        }
    }
}
