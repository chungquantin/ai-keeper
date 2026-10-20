import Foundation

enum Source: String, CaseIterable, Hashable, Codable {
    case claude = "Claude", conductor = "Conductor", git = "Git", dev = "Dev tools"
    case codex = "Codex", superset = "Superset", pi = "Pi", zcode = "ZCode"

    var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .conductor: "music.note.list"
        case .git: "arrow.triangle.branch"
        case .dev: "wrench.and.screwdriver"
        case .codex: "terminal"
        case .superset: "rectangle.3.group"
        case .pi: "p.circle"
        case .zcode: "z.circle"
        }
    }
}

/// `.repo` = a main checkout: never removable, only its rebuildable folders are.
enum Kind: String, Codable { case workspace, repo, sessionData, cache }

/// How risky removing the whole entry is.
enum Safety: Int, Comparable, Codable {
    case safe, caution, danger
    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }
}

enum Verdict: Codable { case active, deprecated, dangling }

struct GitInfo: Hashable, Codable {
    var dirtyCount = 0
    var ahead = 0
    var hasUpstream = false
    var merged = false
    var defaultBranch = "main"
    var lastCommit: Date?
    var unpushed = 0          // commits on no remote at all: lost if this folder is deleted
    var aheadOfBase = 0       // commits beyond the default branch
    var behindBase = 0
    var lastSubject: String?
    var unpushedAfterMerge = 0   // for a merged PR: commits made after the merge (the rest landed via squash)
}

struct Artifact: Hashable, Identifiable, Codable {
    var id: String { path }
    let path: String
    let bytes: Int64
    var label: String { (path as NSString).lastPathComponent }
}

struct Entry: Identifiable, Hashable, Codable {
    var id: String
    var kind: Kind
    var name: String
    var path: String
    var repoPath: String?
    var repoName: String
    var branch: String?
    var sources: Set<Source>
    var conductorState: String?
    var note: String = ""
    var lastActivity: Date?
    var exists = true
    var git: GitInfo?
    var pr: PRInfo?
    var size: Int64?
    var artifacts: [Artifact] = []
    var measured = false
    var verdict: Verdict = .active
    var reasons: [String] = []
    var safety: Safety = .safe

    var artifactBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    var sizeValue: Int64 { size ?? -1 }
    var activityValue: Date { lastActivity ?? .distantPast }
    var isGitWorktree: Bool { kind == .workspace && repoPath != nil }
}

struct Candidate {
    var path: String
    var repoPath: String?
    var repoName: String?
    var branch: String?
    var source: Source
    var conductorState: String?
    var lastActivity: Date?
}

struct DiskInfo {
    var total: Int64 = 0
    var available: Int64 = 0
    var purgeable: Int64 = 0
    var used: Int64 { max(0, total - available) }
}
