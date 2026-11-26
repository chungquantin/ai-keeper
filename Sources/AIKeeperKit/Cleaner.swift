import Darwin
import Foundation

/// Thread-safe counters a background delete reports into; the UI polls it.
final class CleanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _freed: Int64 = 0
    private var _label = ""
    private var _detail = ""
    private var _cancelled = false
    private var _firstError: String?

    var freed: Int64 { lock.withLock { _freed } }
    var label: String { lock.withLock { _label } }
    var detail: String { lock.withLock { _detail } }
    var isCancelled: Bool { lock.withLock { _cancelled } }
    var firstError: String? { lock.withLock { _firstError } }

    func add(_ n: Int64) { lock.withLock { _freed += n } }
    func raise(to n: Int64) { lock.withLock { _freed = max(_freed, n) } }
    func setLabel(_ s: String) { lock.withLock { _label = s; _detail = "" } }
    func setDetail(_ s: String) { lock.withLock { _detail = s } }
    func cancel() { lock.withLock { _cancelled = true } }
    func fail(_ s: String) { lock.withLock { if _firstError == nil { _firstError = s } } }
}

/// Parallel recursive delete. `FileManager.removeItem` is single-threaded and silent, which makes a
/// multi-hundred-GB `target` folder look frozen. This unlinks across threads and counts bytes as it goes.
enum FastDelete {
    static func remove(_ path: String, progress: CleanProgress) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_mode & S_IFMT != S_IFDIR {
            if unlink(path) == 0 { progress.add(Int64(st.st_blocks) * 512) } else { progress.fail("\(path): \(String(cString: strerror(errno)))") }
            return
        }
        removeDir(path, root: path, depth: 0, progress: progress)
    }

    private static func removeDir(_ path: String, root: String, depth: Int, progress: CleanProgress) {
        if progress.isCancelled { return }
        if depth <= 3 {
            let rel = path == root ? (root as NSString).lastPathComponent : (root as NSString).lastPathComponent + String(path.dropFirst(root.count))
            progress.setDetail(rel)
        }
        guard let dir = opendir(path) else { progress.fail("\(path): \(String(cString: strerror(errno)))"); return }
        var names: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(dir)

        func handle(_ name: String) {
            if progress.isCancelled { return }
            let child = path + "/" + name
            var st = stat()
            guard lstat(child, &st) == 0 else { return }
            if st.st_mode & S_IFMT == S_IFDIR {
                removeDir(child, root: root, depth: depth + 1, progress: progress)
            } else if unlink(child) == 0 {
                progress.add(Int64(st.st_blocks) * 512)
            } else {
                progress.fail("\(child): \(String(cString: strerror(errno)))")
            }
        }

        if names.count > 1 && (depth < 2 || names.count >= 256) {
            let slices = min(8, names.count)
            DispatchQueue.concurrentPerform(iterations: slices) { s in
                var i = s
                while i < names.count { handle(names[i]); i += slices }
            }
        } else {
            names.forEach(handle)
        }
        if !progress.isCancelled { rmdir(path) }
    }
}

/// Destructive operations. Always run off the main actor, after the user confirmed in the sheet.
enum Cleaner {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Workspace records come from other tools' databases. A bad or tampered record must never turn into "delete my home folder".
    static func checkRemovable(_ e: Entry) throws {
        guard e.kind == .workspace else { return }
        let p = URL(fileURLWithPath: e.path).standardizedFileURL.resolvingSymlinksInPath().path
        let h = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        let depth = { (s: String) in s.split(separator: "/").count }
        guard p.hasPrefix(h + "/"), depth(p) >= depth(h) + 2 else {
            throw Failure(message: "\(e.name) is too close to your home folder to remove safely, so nothing was removed.")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p + "/.git", isDirectory: &isDir), isDir.boolValue {
            throw Failure(message: "\(e.name) looks like a main checkout, not a worktree, so nothing was removed.")
        }
    }

    static func remove(_ e: Entry, options: CleanupOptions, progress: CleanProgress) throws -> Int64 {
        try checkRemovable(e)
        let freed = e.size ?? 0
        progress.setLabel(e.name)
        if options.vault, Vault.needsSnapshot(e) {
            progress.setDetail("Saving a recovery snapshot…")
            do { _ = try Vault.archive(e) }
            catch { throw Failure(message: "Couldn't save a recovery snapshot, so nothing was removed. \(error.localizedDescription)") }
        }
        if e.exists, e.kind == .cache {
            // Keep the folder itself (apps expect it); clear what's inside.
            let kids = (try? FileManager.default.contentsOfDirectory(atPath: e.path)) ?? []
            for k in kids where !progress.isCancelled { try dispose(e.path + "/" + k, permanent: options.permanent, progress: progress) }
        } else if e.exists {
            try dispose(e.path, permanent: options.permanent, progress: progress)
        }
        if progress.isCancelled { return 0 }
        if e.kind == .workspace, let repo = e.repoPath {
            Shell.git(repo, ["worktree", "prune"])
            if options.deleteMergedBranches, e.git?.merged == true, let b = e.branch, b != e.git?.defaultBranch {
                Shell.git(repo, ["branch", "-d", b])   // -d refuses if unmerged
            }
        }
        return freed
    }

    static func purgeArtifacts(_ e: Entry, permanent: Bool, progress: CleanProgress) throws -> Int64 {
        var freed: Int64 = 0
        for a in e.artifacts where FileManager.default.fileExists(atPath: a.path) {
            if progress.isCancelled { break }
            // Only touch folders that sit inside the workspace.
            guard a.path.hasPrefix(e.path + "/") else { continue }
            progress.setLabel("\(e.name)/\(a.path.dropFirst(e.path.count + 1))")
            try dispose(a.path, permanent: permanent, progress: progress)
            if !progress.isCancelled { freed += a.bytes }
        }
        return freed
    }

    private static func dispose(_ path: String, permanent: Bool, progress: CleanProgress) throws {
        if permanent {
            FastDelete.remove(path, progress: progress)
            if let err = progress.firstError, !progress.isCancelled, FileManager.default.fileExists(atPath: path) {
                throw Failure(message: err)
            }
        } else {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    }
}
