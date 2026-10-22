import SwiftUI

struct PRInfo: Codable, Hashable {
    var number: Int
    var state: String      // OPEN, MERGED, CLOSED
    var url: String
    var title: String
    var isDraft: Bool?
    var review: String?    // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    var checks: String?    // pass, fail, pending (open PRs only)
    var mergedAt: Date?
    var closedAt: Date?
    var updatedAt: Date?
}

/// Pull request state per branch, via the GitHub CLI when it's installed and signed in.
enum PRService {
    static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fetch(repo: String) -> [String: PRInfo] {
        guard let gh else { return [:] }
        let r = Shell.run(gh, ["pr", "list", "--state", "all", "--limit", "300", "--json",
                               "headRefName,number,state,url,title,isDraft,reviewDecision,mergedAt,closedAt,updatedAt"], cwd: repo)
        guard r.status == 0, let arr = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]] else { return [:] }
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        var out: [String: PRInfo] = [:]
        for p in arr {
            guard let b = p["headRefName"] as? String, let n = p["number"] as? Int,
                  let s = p["state"] as? String, let u = p["url"] as? String else { continue }
            if let old = out[b], old.number > n { continue }   // newest PR for the branch wins
            let review = (p["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out[b] = PRInfo(number: n, state: s, url: u, title: p["title"] as? String ?? "", isDraft: p["isDraft"] as? Bool,
                            review: review, checks: nil, mergedAt: date(p["mergedAt"]), closedAt: date(p["closedAt"]), updatedAt: date(p["updatedAt"]))
        }
        // CI state is a heavier query, so only ask for open PRs.
        let o = Shell.run(gh, ["pr", "list", "--state", "open", "--limit", "100", "--json", "headRefName,statusCheckRollup"], cwd: repo)
        if o.status == 0, let open = (try? JSONSerialization.jsonObject(with: Data(o.out.utf8))) as? [[String: Any]] {
            for p in open {
                guard let b = p["headRefName"] as? String, out[b] != nil else { continue }
                out[b]?.checks = rollup(p["statusCheckRollup"] as? [[String: Any]] ?? [])
            }
        }
        return out
    }

    /// Commits on no remote that were made after the PR merged. A squash merge leaves the branch's own commits
    /// "unpushed" once GitHub deletes the remote branch, so only newer commits are real unsaved work.
    static func commitsAfterMerge(path: String, mergedAt: Date) -> Int {
        let since = ISO8601DateFormatter().string(from: mergedAt)
        let r = Shell.git(path, ["rev-list", "--count", "HEAD", "--not", "--remotes", "--since=\(since)"])
        return Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Collapse GitHub's per-check results into one word.
    static func rollup(_ checks: [[String: Any]]) -> String? {
        guard !checks.isEmpty else { return nil }
        var pending = false
        for c in checks {
            let conclusion = (c["conclusion"] as? String ?? "").uppercased(), status = (c["status"] as? String ?? "").uppercased(), state = (c["state"] as? String ?? "").uppercased()
            if ["FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE"].contains(conclusion) || ["FAILURE", "ERROR"].contains(state) { return "fail" }
            if ["IN_PROGRESS", "QUEUED", "PENDING", "WAITING"].contains(status) || state == "PENDING" { pending = true }
        }
        return pending ? "pending" : "pass"
    }
}

struct VaultItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var repoPath: String
    var branch: String?
    var headSHA: String
    var date: Date
    var hasBundle: Bool
    var hasPatch: Bool
    var hasUntracked: Bool
    var bytes: Int64
    var notes: [String]
}

/// Recovery snapshots taken before a workspace is removed: unpushed commits, uncommitted diff, untracked files.
enum Vault {
    struct VaultError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let root: URL = {
        let u = Persist.dir.appendingPathComponent("Vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func needsSnapshot(_ e: Entry) -> Bool {
        guard e.kind == .workspace, e.exists, let g = e.git else { return false }
        return g.dirtyCount > 0 || (!g.merged && e.pr?.state != "MERGED" && g.unpushed > 0)
    }

    /// Returns nil when there is nothing worth saving.
    static func archive(_ e: Entry) throws -> VaultItem? {
        guard needsSnapshot(e), let repo = e.repoPath else { return nil }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let id = "\(stamp.string(from: .now))-\(e.name)"
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var item = VaultItem(id: id, name: e.name, path: e.path, repoPath: repo, branch: e.branch,
                             headSHA: Shell.git(e.path, ["rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines),
                             date: .now, hasBundle: false, hasPatch: false, hasUntracked: false, bytes: 0, notes: [])

        // Anything the snapshot was supposed to hold but couldn't is a reason to stop: the caller deletes the folder next.
        var problems: [String] = []
        let bundle = dir.appendingPathComponent("commits.bundle").path
        if Shell.git(e.path, ["bundle", "create", bundle, "HEAD", "--not", "--remotes"]).status == 0 {
            if fileSize(bundle) > 500_000_000 { try? FileManager.default.removeItem(atPath: bundle); problems.append("the unpushed commits are over 500 MB") }
            else { item.hasBundle = true }
        } else if (e.git?.unpushed ?? 0) > 0 {
            problems.append("the unpushed commits couldn't be bundled")
        }
        let diff = Shell.gitData(e.path, ["diff", "HEAD", "--binary"])
        if diff.status != 0 { problems.append("the uncommitted changes couldn't be read") }
        else if !diff.data.isEmpty {
            try diff.data.write(to: dir.appendingPathComponent("changes.patch"), options: .atomic)   // bytes, not text: binary hunks must survive
            item.hasPatch = true
        }
        let untracked = Shell.git(e.path, ["ls-files", "--others", "--exclude-standard", "-z"]).out
        if !untracked.isEmpty {
            let list = dir.appendingPathComponent("untracked.list")
            try untracked.write(to: list, atomically: true, encoding: .utf8)
            let tgz = dir.appendingPathComponent("untracked.tgz").path
            if Shell.run("/usr/bin/tar", ["-czf", tgz, "-C", e.path, "--null", "-T", list.path]).status == 0 {
                if fileSize(tgz) > 300_000_000 { try? FileManager.default.removeItem(atPath: tgz); problems.append("the untracked files are over 300 MB") }
                else { item.hasUntracked = true }
            } else { problems.append("the untracked files couldn't be archived") }
            try? FileManager.default.removeItem(at: list)
        }
        if !problems.isEmpty {
            try? FileManager.default.removeItem(at: dir)
            throw Cleaner.Failure(message: "Not everything could be saved (\(problems.joined(separator: "; "))). Turn off recovery snapshots to remove it anyway.")
        }
        guard item.hasBundle || item.hasPatch || item.hasUntracked else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        item.bytes = Shell.du(dir.path)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(item).write(to: dir.appendingPathComponent("meta.json"))
        return item
    }

    /// ids name a folder inside the vault and a git ref, and meta.json is just a file: never trust it to point elsewhere.
    static func validID(_ id: String, folder: String? = nil) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..") && id != "." && (folder == nil || folder == id)
    }
    private static func refName(_ id: String) -> String {
        "refs/vault/" + String(id.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
    }

    static func list() -> [VaultItem] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d -> VaultItem? in
            guard let item = try? dec.decode(VaultItem.self, from: Data(contentsOf: d.appendingPathComponent("meta.json"))),
                  validID(item.id, folder: d.lastPathComponent) else { return nil }
            return item
        }.sorted { $0.date > $1.date }
    }

    static func purgeExpired(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for i in list() where i.date < cutoff { delete(i) }
    }

    static func delete(_ i: VaultItem) { guard validID(i.id) else { return }; try? FileManager.default.removeItem(at: root.appendingPathComponent(i.id)) }

    static func restore(_ i: VaultItem) throws {
        guard validID(i.id), i.headSHA.range(of: #"^[0-9a-f]{7,64}$"#, options: .regularExpression) != nil else {
            throw VaultError(message: "This snapshot's record is damaged, so it can't be restored automatically.")
        }
        let dir = root.appendingPathComponent(i.id)
        guard FileManager.default.fileExists(atPath: i.repoPath + "/.git") else { throw VaultError(message: "The repository \(i.repoPath) no longer exists.") }
        guard !FileManager.default.fileExists(atPath: i.path) else { throw VaultError(message: "\(i.path) already exists.") }
        if i.hasBundle {
            let r = Shell.git(i.repoPath, ["fetch", dir.appendingPathComponent("commits.bundle").path, "HEAD:\(refName(i.id))"])
            guard r.status == 0 else { throw VaultError(message: "Couldn't import the saved commits.") }
        }
        guard Shell.git(i.repoPath, ["worktree", "add", "--detach", i.path, i.headSHA]).status == 0 else {
            throw VaultError(message: "Couldn't recreate the worktree at commit \(i.headSHA.prefix(8)).")
        }
        if let b = i.branch {
            let tip = Shell.git(i.repoPath, ["rev-parse", "--verify", "-q", "refs/heads/\(b)"])
            if tip.status != 0 { Shell.git(i.path, ["checkout", "-b", b]) }
            else if tip.out.trimmingCharacters(in: .whitespacesAndNewlines) == i.headSHA { Shell.git(i.path, ["checkout", b]) }
            // Branch moved on since: leave the worktree detached at the saved commit rather than guess.
        }
        if i.hasPatch, Shell.git(i.path, ["apply", "--binary", dir.appendingPathComponent("changes.patch").path]).status != 0 {
            throw VaultError(message: "Worktree restored, but the saved changes didn't apply cleanly. The patch is still in the vault.")
        }
        if i.hasUntracked { Shell.run("/usr/bin/tar", ["-xzf", dir.appendingPathComponent("untracked.tgz").path, "-C", i.path]) }
    }

    private static func fileSize(_ p: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? Int64) ?? 0
    }
}

struct VaultView: View {
    @EnvironmentObject var store: Store
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Before a workspace with unsaved work is removed, AI Keeper saves its unpushed commits, uncommitted changes and untracked files here. Restore recreates the folder.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.vault.isEmpty {
                    ContentUnavailableView("Nothing saved", systemImage: "arrow.uturn.backward.circle",
                                           description: Text("Snapshots appear here after you remove a workspace that had unsaved work."))
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.vault) { i in
                            row(i)
                            if i.id != store.vault.last?.id { Divider() }
                        }
                    }.panel()
                }
            }.padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 62) }   // keep the first row clear of the glass toolbar
        .navigationTitle("Recently removed")
        .alert("Restore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func row(_ i: VaultItem) -> some View {
        let days = Int(UserDefaults.standard.number("vault.days", default: 30))
        let left = max(0, days - (Calendar.current.dateComponents([.day], from: i.date, to: .now).day ?? 0))
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(i.name).fontWeight(.medium)
                Text(i.path.replacingOccurrences(of: home, with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    if i.hasBundle { Pill(text: "Unpushed commits", color: .blue) }
                    if i.hasPatch { Pill(text: "Uncommitted changes", color: .orange) }
                    if i.hasUntracked { Pill(text: "Untracked files", color: .teal) }
                }.padding(.top, 2)
                ForEach(i.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(i.bytes.bytesString).monospacedDigit()
                Text("\(i.date.formatted(.relative(presentation: .named))) · \(left)d left").font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore") {
                do { try Vault.restore(i); message = "Restored to \(i.path)."; Task { await store.rescan() } }
                catch { message = error.localizedDescription }
            }.buttonStyle(.borderedProminent)
            Button(role: .destructive) { Vault.delete(i); store.refreshVault() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete snapshot now").accessibilityLabel("Delete snapshot")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}
