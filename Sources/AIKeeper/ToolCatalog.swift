import Foundation

/// One entry per AI coding tool we know how to find. Everything else (onboarding, sidebar, scanners) reads this.
struct ToolSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let blurb: String
    var binaries: [String] = []
    var apps: [String] = []
    var dataDirs: [String] = []       // relative to the home folder
    var source: Source? = nil         // tag for workspaces this tool creates
    var workspaces = false
    var usage = false
    var agents = true
    var note: String? = nil

    var capabilities: [String] {
        (workspaces ? ["Workspaces"] : []) + (usage ? ["Usage"] : []) + (agents ? ["Running agents"] : []) + ["Disk footprint"]
    }
}

enum ToolCatalog {
    static let all: [ToolSpec] = [
        ToolSpec(id: "claude", name: "Claude Code", symbol: "sparkles", blurb: "Anthropic's coding agent, CLI and desktop app",
                 binaries: ["claude"], apps: ["Claude.app"], dataDirs: [".claude"], source: .claude, workspaces: true, usage: true),
        ToolSpec(id: "conductor", name: "Conductor", symbol: "music.note.list", blurb: "Runs Claude and Codex in parallel workspaces",
                 apps: ["Conductor.app"], dataDirs: ["conductor", "Library/Application Support/com.conductor.app"], source: .conductor, workspaces: true, agents: false),
        ToolSpec(id: "codex", name: "Codex", symbol: "terminal", blurb: "OpenAI's coding agent, CLI and app",
                 binaries: ["codex"], apps: ["Codex.app"], dataDirs: [".codex"], source: .codex, workspaces: true, usage: true),
        ToolSpec(id: "superset", name: "Superset", symbol: "rectangle.3.group", blurb: "Runs many agents side by side in git worktrees",
                 apps: ["Superset.app"], dataDirs: [".superset"], source: .superset, workspaces: true, agents: false),
        ToolSpec(id: "pi", name: "Pi", symbol: "p.circle", blurb: "Minimal terminal coding agent",
                 binaries: ["pi"], dataDirs: [".pi/agent", ".pi"], source: .pi, usage: true),
        ToolSpec(id: "zcode", name: "ZCode", symbol: "z.circle", blurb: "Z.ai's desktop coding agent",
                 binaries: ["zcode"], apps: ["ZCode.app"], dataDirs: [".zcode"], source: .zcode,
                 note: "Finds its disk footprint and running agents. Its history is an undocumented SQLite format, so usage and sessions aren't tracked yet."),
        ToolSpec(id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", blurb: "AI code editor and cursor-agent CLI",
                 binaries: ["cursor-agent"], apps: ["Cursor.app"], dataDirs: [".cursor"], note: "Monitors running agents and disk footprint."),
        ToolSpec(id: "goose", name: "Goose", symbol: "bird", blurb: "Open-source agent from Block",
                 binaries: ["goose"], dataDirs: [".config/goose", ".local/share/goose"]),
        ToolSpec(id: "gemini", name: "Gemini CLI", symbol: "diamond", blurb: "Google's terminal agent",
                 binaries: ["gemini"], dataDirs: [".gemini"]),
        ToolSpec(id: "aider", name: "Aider", symbol: "text.badge.checkmark", blurb: "Pair-programming agent in the terminal",
                 binaries: ["aider"], dataDirs: [".aider"]),
        ToolSpec(id: "opencode", name: "OpenCode", symbol: "chevron.left.forwardslash.chevron.right", blurb: "Open-source terminal agent",
                 binaries: ["opencode"], dataDirs: [".local/share/opencode", ".config/opencode"]),
    ]

    static func spec(_ id: String) -> ToolSpec? { all.first { $0.id == id } }
}

/// What auto-detection found for one tool.
struct Detection: Identifiable {
    var id: String { spec.id }
    let spec: ToolSpec
    var binary: String?
    var app: String?
    var dataPath: String?
    var running = 0
    var found: Bool { binary != nil || app != nil || dataPath != nil }

    var evidence: String {
        var parts: [String] = []
        if app != nil { parts.append("app installed") }
        if let b = binary { parts.append("command at \(b.replacingOccurrences(of: home, with: "~"))") }
        if let d = dataPath, app == nil, binary == nil { parts.append("data in \(d.replacingOccurrences(of: home, with: "~"))") }
        return parts.joined(separator: ", ")
    }
}

/// User choices, kept in UserDefaults so the CLI and MCP server see them too.
enum ToolSettings {
    static let enabledKey = "tools.enabled", onboardedKey = "onboarded", rootsKey = "repo.roots"

    static var onboarded: Bool { UserDefaults.standard.bool(forKey: onboardedKey) }
    static var storedEnabled: [String]? { UserDefaults.standard.stringArray(forKey: enabledKey) }
    /// Before onboarding every tool counts as enabled, so existing behaviour is unchanged.
    static func enabled(_ id: String) -> Bool { storedEnabled?.contains(id) ?? true }

    static let candidateRoots = ["Developer", "Projects", "code", "src", "dev", "work", "repos", "GitHub", "Documents/GitHub", "Sites"]
    static var roots: [String] { UserDefaults.standard.stringArray(forKey: rootsKey) ?? candidateRoots.map { "\(home)/\($0)" } }
}

extension ToolCatalog {
    /// Cheap file-system checks; safe to run on a background thread.
    static func detect(runningToolIDs: [String: Int] = [:]) -> [Detection] {
        let fm = FileManager.default
        var binDirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.cargo/bin",
                       "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.npm-global/bin", "\(home)/.pi/agent/bin", "\(home)/.zcode/bin"]
        binDirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let nvm = "\(home)/.nvm/versions/node"
        binDirs += ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).map { "\(nvm)/\($0)/bin" }
        let appDirs = ["/Applications", "\(home)/Applications", "/System/Applications"]

        return all.map { spec in
            var d = Detection(spec: spec)
            d.binary = spec.binaries.lazy.compactMap { b in binDirs.first { fm.isExecutableFile(atPath: "\($0)/\(b)") }.map { "\($0)/\(b)" } }.first
            d.app = spec.apps.lazy.compactMap { a in appDirs.first { fm.fileExists(atPath: "\($0)/\(a)") }.map { "\($0)/\(a)" } }.first
            // An empty folder is a leftover, not an install.
            d.dataPath = spec.dataDirs.lazy.map { "\(home)/\($0)" }.first { !((try? fm.contentsOfDirectory(atPath: $0)) ?? []).isEmpty }
            d.running = runningToolIDs[spec.id] ?? 0
            return d
        }
    }

    /// Folders that hold git repos: common names plus the parents of repos the detected tools already know about.
    static func detectProjectRoots() -> [(path: String, repos: Int, viaTool: Bool)] {
        let fm = FileManager.default
        func repoCount(_ dir: String) -> Int {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { fm.fileExists(atPath: "\(dir)/\($0)/.git") }.count
        }
        var found: [String: Bool] = [:]
        for r in ToolSettings.candidateRoots { let p = "\(home)/\(r)"; if repoCount(p) > 0 { found[p] = false } }
        // Where existing tools keep their repos.
        var viaTools = Set<String>()
        viaTools.formUnion(Discovery.conductor(force: true).compactMap { $0.repoPath })
        viaTools.formUnion(Discovery.claude(force: true).compactMap { $0.repoPath })
        viaTools.formUnion(Discovery.superset(force: true).compactMap { $0.repoPath })
        viaTools.formUnion(Discovery.codex(force: true).compactMap { $0.repoPath })
        for repo in viaTools where fm.fileExists(atPath: repo + "/.git") {
            let parent = (repo as NSString).deletingLastPathComponent
            if parent != home, found[parent] == nil, repoCount(parent) > 0 { found[parent] = true }
        }
        return found.map { ($0.key, repoCount($0.key), $0.value) }.sorted { $0.1 > $1.1 }
    }
}

extension Source {
    /// Which tool created a worktree, from where it lives.
    static func infer(from path: String) -> Source? {
        if path.contains("/.claude/worktrees/") { return .claude }
        if path.contains("/conductor/workspaces/") { return .conductor }
        if path.contains("/.codex/worktrees/") { return .codex }
        if path.contains("/.superset/worktrees/") || path.contains("/superset/worktrees/") { return .superset }
        return nil
    }
}
