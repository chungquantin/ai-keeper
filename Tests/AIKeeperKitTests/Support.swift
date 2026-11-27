import Foundation
@testable import AIKeeperKit

/// Everything the tests write goes to a throwaway folder, never to the real Application Support.
enum TestEnv {
    static let data: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        setenv("AIKEEPER_DATA", u.path, 1)
        return u
    }()
    /// Touch before anything reads `Persist.dir`.
    static func ready() { _ = data }
}

/// A fake home folder on disk, removed when the value goes away.
final class FakeHome {
    let path: String
    init() {
        TestEnv.ready()
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        path = u.resolvingSymlinksInPath().path
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    @discardableResult func dir(_ rel: String) -> String {
        let p = path + "/" + rel
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    @discardableResult func file(_ rel: String, _ text: String = "x", ageDays: Int = 0) -> String {
        let p = path + "/" + rel
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: p, atomically: true, encoding: .utf8)
        if ageDays > 0 { try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(ageDays) * 86400)], ofItemAtPath: p) }
        return p
    }
}

func daysAgo(_ n: Int) -> Date { Date().addingTimeInterval(-Double(n) * 86400) }

/// A workspace entry classified the way a scan would classify it.
func workspace(_ name: String, path: String? = nil, git: GitInfo? = GitInfo(), pr: PRInfo? = nil, size: Int64 = 1_000_000_000,
               last: Date? = daysAgo(30), artifacts: [Artifact] = [], staleDays: Int = 14) -> Entry {
    var e = Entry(id: name, kind: .workspace, name: name, path: path ?? "/Users/test/work/\(name)", repoPath: "/Users/test/work/main",
                  repoName: "main", branch: name, sources: [.conductor])
    e.git = git; e.pr = pr; e.size = size; e.lastActivity = last; e.artifacts = artifacts; e.measured = true
    Classifier.classify(&e, staleDays: staleDays)
    return e
}

func pr(_ n: Int, _ state: String, mergedAgo: Int? = nil) -> PRInfo {
    PRInfo(number: n, state: state, url: "https://example.com/\(n)", title: "PR \(n)", mergedAt: mergedAgo.map(daysAgo))
}

func other(_ kind: Kind, _ name: String, size: Int64) -> Entry {
    var e = Entry(id: name, kind: kind, name: name, path: "/Users/test/.stuff/\(name)", repoPath: nil, repoName: name, branch: nil, sources: [.dev], note: "note")
    e.size = size; e.measured = true
    Classifier.classify(&e, staleDays: 14)
    return e
}
