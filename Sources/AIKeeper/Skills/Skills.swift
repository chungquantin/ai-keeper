import CryptoKit
import Foundation

// MARK: - Model

struct SkillInfo: Identifiable, Codable, Hashable {
    enum Scope: String, Codable { case user, plugin, project }

    var id: String { realPath }
    var name: String
    var description: String
    var tools: [String]            // who can load it: "Claude Code", "Codex", "Shared"…
    var scope: Scope
    var plugin: String?            // "caveman@caveman" for plugin skills
    var pluginVersion: String?
    var locations: [String]        // every place it is listed (several tools often link to one folder)
    var realPath: String           // the real folder: SkillSpector refuses symlinks, and this is what gets scanned
    var files: Int
    var bytes: Int64
    var hasScripts: Bool
    var modified: Date
    var signature: String          // changes whenever a file inside changes; keys the scan cache
}

struct SkillIssue: Codable, Hashable, Identifiable {
    var id: String { "\(rule)|\(file)|\(line)|\(finding)" }
    var rule: String
    var category: String
    var severity: String           // LOW | MEDIUM | HIGH | CRITICAL
    var confidence: Double
    var file: String
    var line: Int
    var finding: String
    var explanation: String
    var remediation: String
    var snippet: String?           // the surrounding lines, so you can judge it yourself

    var rank: Int { ["LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4][severity] ?? 0 }
}

struct SkillScan: Codable, Hashable {
    var score: Int
    var severity: String           // LOW | MEDIUM | HIGH | CRITICAL
    var recommendation: String     // SAFE | CAUTION | DO_NOT_INSTALL
    var issues: [SkillIssue]
    var scannedAt: Date
    var scannerVersion: String
    var signature: String          // of the skill when it was scanned
    var complete: Bool             // false when the scanner could not inspect everything

    /// How the page and the CLI word it.
    var verdict: SkillVerdict { SkillVerdict(recommendation) }
}

enum SkillVerdict: Int, Comparable {
    case safe, caution, danger, unscanned
    init(_ recommendation: String) { self = ["SAFE": .safe, "CAUTION": .caution, "DO_NOT_INSTALL": .danger][recommendation] ?? .caution }
    static func < (a: SkillVerdict, b: SkillVerdict) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Looks safe", "Review", "Do not install", "Not scanned"][rawValue] }
    var key: String { ["safe", "caution", "danger", "unscanned"][rawValue] }
}

// MARK: - Untrusted text

/// Skill files and scanner reports are written by strangers. Before any of it reaches a terminal or a window, strip
/// control characters, escape sequences and the Unicode tricks that make text lie about itself (bidi overrides).
enum Sanitize {
    static func text(_ s: String, max: Int = 600) -> String {
        var out = String.UnicodeScalarView()
        var inEscape = false
        for u in s.unicodeScalars {
            if inEscape { if (0x40...0x7E).contains(u.value) && u != "[" { inEscape = false }; continue }
            if u == "\u{1B}" { inEscape = true; continue }
            let v = u.value
            if v == 0x0A || v == 0x09 { out.append(u); continue }
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { continue }       // control characters
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F { continue }   // bidi overrides
            out.append(u)
        }
        let clean = String(out)
        return clean.count > max ? String(clean.prefix(max - 1)) + "…" : clean
    }

    /// One line: for list rows and terminal tables.
    static func line(_ s: String, max: Int = 200) -> String {
        text(s, max: max).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}

// MARK: - Finding skills

enum SkillCatalog {
    /// Folders that hold skills, per tool. `AIKEEPER_SKILL_ROOTS` (colon separated) replaces them, so tests never read real skills.
    static func roots() -> [(tool: String, toolID: String?, path: String)] {
        if let custom = ProcessInfo.processInfo.environment["AIKEEPER_SKILL_ROOTS"], !custom.isEmpty {
            return custom.split(separator: ":").map { (String($0).components(separatedBy: "/").last ?? "Custom", nil, String($0)) }
        }
        return [
            ("Claude Code", "claude", "\(home)/.claude/skills"),
            ("Shared", nil, "\(home)/.agents/skills"),
            ("Codex", "codex", "\(home)/.codex/skills"),
            ("Pi", "pi", "\(home)/.pi/agent/skills"),
            ("Gemini CLI", "gemini", "\(home)/.gemini/skills"),
            ("OpenCode", "opencode", "\(home)/.config/opencode/skills"),
            ("OpenCode", "opencode", "\(home)/.config/opencode/skill"),
            ("Cursor", "cursor", "\(home)/.cursor/skills"),
            ("Goose", "goose", "\(home)/.config/goose/skills"),
        ]
    }

    /// Every installed skill, one record per real folder (several tools linking to one folder show as one skill).
    /// `projects` are main checkouts to look in for project skills.
    static func discover(projects: [String] = []) -> [SkillInfo] {
        var byReal: [String: SkillInfo] = [:]
        func add(dir: String, tool: String, scope: SkillInfo.Scope, plugin: String? = nil, version: String? = nil) {
            let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue,
                  let manifest = manifest(in: real) else { return }
            if var e = byReal[real] {
                if !e.tools.contains(tool) { e.tools.append(tool) }
                if !e.locations.contains(dir) { e.locations.append(dir) }
                if scope.order < e.scope.order { e.scope = scope }
                byReal[real] = e
                return
            }
            let fm = frontmatter(manifest)
            let stats = measure(real)
            byReal[real] = SkillInfo(
                name: Sanitize.line(fm["name"] ?? (real as NSString).lastPathComponent, max: 80),
                description: Sanitize.line(fm["description"] ?? "", max: 500),
                tools: [tool], scope: scope, plugin: plugin.map { Sanitize.line($0, max: 80) }, pluginVersion: version.map { Sanitize.line($0, max: 40) },
                locations: [dir], realPath: real, files: stats.files, bytes: stats.bytes, hasScripts: stats.scripts, modified: stats.modified, signature: stats.signature)
        }

        func skillDirs(in root: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted().map { "\(root)/\($0)" }
        }

        for r in roots() where r.toolID.map(ToolSettings.enabled) ?? true { for d in skillDirs(in: r.path) { add(dir: d, tool: r.tool, scope: .user) } }

        if ProcessInfo.processInfo.environment["AIKEEPER_SKILL_ROOTS"] == nil {
            // Plugins you installed in Claude Code. Only the installed version of each, not every cached copy.
            if ToolSettings.enabled("claude"), let data = FileManager.default.contents(atPath: "\(home)/.claude/plugins/installed_plugins.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let plugins = json["plugins"] as? [String: Any] {
                for (key, value) in plugins {
                    for install in value as? [[String: Any]] ?? [] {
                        guard let base = install["installPath"] as? String, base.hasPrefix("\(home)/") else { continue }   // never wander outside home
                        for d in skillDirs(in: base + "/skills") { add(dir: d, tool: "Claude Code", scope: .plugin, plugin: key, version: install["version"] as? String) }
                    }
                }
            }
            for repo in projects {
                for sub in [".claude/skills", ".agents/skills"] { for d in skillDirs(in: "\(repo)/\(sub)") { add(dir: d, tool: "Project", scope: .project) } }
            }
        }
        return byReal.values.sorted { ($0.name.lowercased(), $0.realPath) < ($1.name.lowercased(), $1.realPath) }
    }

    private static func manifest(in dir: String) -> String? {
        for name in ["SKILL.md", "skill.md"] {
            let p = "\(dir)/\(name)"
            if let h = FileHandle(forReadingAtPath: p) {
                defer { try? h.close() }
                if let d = try? h.read(upToCount: 16 * 1024) { return String(decoding: d, as: UTF8.self) }
            }
        }
        return nil
    }

    /// The leading `---` block: name, description, including folded and block scalars.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(value) {
                var parts: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") || lines[i].isEmpty, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                value = parts.filter { !$0.isEmpty }.joined(separator: " ")
            } else if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    private static let scriptExtensions: Set<String> = ["py", "sh", "bash", "zsh", "js", "mjs", "ts", "rb", "pl", "command", "ps1"]

    /// Size, file count and a signature that changes whenever anything inside changes. Symlinks are listed, never followed.
    private static func measure(_ dir: String) -> (files: Int, bytes: Int64, scripts: Bool, modified: Date, signature: String) {
        var files = 0, bytes: Int64 = 0, scripts = false, newest = Date.distantPast
        var hasher = SHA256()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let base = URL(fileURLWithPath: dir)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return (0, 0, false, .distantPast, "")
        }
        var entries: [String] = []
        for case let url as URL in walker {
            if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let rel = String(url.path.dropFirst(dir.count))
            if v.isSymbolicLink == true { entries.append("l|\(rel)"); walker.skipDescendants(); continue }
            guard v.isRegularFile == true else { continue }
            files += 1
            let size = Int64(v.fileSize ?? 0), mod = v.contentModificationDate ?? .distantPast
            bytes += size; newest = max(newest, mod)
            if scriptExtensions.contains(url.pathExtension.lowercased()) || FileManager.default.isExecutableFile(atPath: url.path) { scripts = true }
            entries.append("f|\(rel)|\(size)|\(Int(mod.timeIntervalSince1970))")
            if files >= 5000 { break }   // a skill is a handful of files; a huge folder is itself worth a look
        }
        for e in entries.sorted() { hasher.update(data: Data(e.utf8)) }
        return (files, bytes, scripts, newest, hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(24).description)
    }
}

private extension SkillInfo.Scope {
    var order: Int { self == .user ? 0 : self == .plugin ? 1 : 2 }
}
