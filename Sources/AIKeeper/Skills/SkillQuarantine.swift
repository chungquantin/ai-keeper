import Foundation

/// A skill that was taken out of use. The folder is moved here, not deleted, with a record of every link that pointed at it,
/// so restoring puts everything back exactly. Scanner findings are heuristics: removal has to be reversible.
struct QuarantinedSkill: Codable, Identifiable, Hashable {
    struct Link: Codable, Hashable { var path: String; var target: String }
    var id: String
    var name: String
    var originalPath: String
    var links: [Link]
    var tools: [String]
    var removedAt: Date
    var bytes: Int64
    var verdict: String?          // what the scan said when it was removed
    var score: Int?
    var topFinding: String?
}

enum SkillRemoval {
    static var directory: URL {
        let u = Persist.dir.appendingPathComponent("SkillQuarantine", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    struct Plan {
        var removable: [SkillInfo] = []
        var skipped: [(skill: SkillInfo, reason: String)] = []
    }

    /// Which of these may be removed. Plugin and project skills are not yours to delete from here: a plugin puts its skills
    /// back on the next update, and a project's live in a git repository.
    static func plan(_ skills: [SkillInfo]) -> Plan {
        var plan = Plan()
        let roots = SkillCatalog.roots().map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        let h = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        for s in skills {
            switch s.scope {
            case .plugin: plan.skipped.append((s, "part of the plugin \(s.plugin ?? ""): uninstall the plugin instead, or it comes back on the next update"))
            case .project: plan.skipped.append((s, "lives in a project repository: delete it there so git shows the change"))
            case .user:
                let real = URL(fileURLWithPath: s.realPath).resolvingSymlinksInPath().path
                let parent = (real as NSString).deletingLastPathComponent
                var isLink = false
                if let attrs = try? FileManager.default.attributesOfItem(atPath: s.realPath), attrs[.type] as? FileAttributeType == .typeSymbolicLink { isLink = true }
                guard real.hasPrefix(h + "/"), roots.contains(parent), !isLink,
                      FileManager.default.fileExists(atPath: real + "/SKILL.md") || FileManager.default.fileExists(atPath: real + "/skill.md") else {
                    plan.skipped.append((s, "not a skill folder in a known skills location, so I won't touch it")); continue
                }
                plan.removable.append(s)
            }
        }
        return plan
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Takes one skill out of use. `permanent` deletes instead of keeping a copy.
    @discardableResult
    static func remove(_ s: SkillInfo, scan: SkillScan?, permanent: Bool) throws -> QuarantinedSkill? {
        let fm = FileManager.default
        // Links from other tools (~/.claude/skills/x -> ~/.agents/skills/x). Only real symlinks that point at this folder.
        var links: [QuarantinedSkill.Link] = []
        for loc in s.locations where loc != s.realPath && isSymlink(loc) {
            if let t = try? fm.destinationOfSymbolicLink(atPath: loc) {
                let resolved = URL(fileURLWithPath: t, relativeTo: URL(fileURLWithPath: (loc as NSString).deletingLastPathComponent)).resolvingSymlinksInPath().path
                if resolved == s.realPath { links.append(.init(path: loc, target: t)) }
            }
        }
        if permanent {
            try fm.removeItem(atPath: s.realPath)
            for l in links where isSymlink(l.path) { try? fm.removeItem(atPath: l.path) }
            return nil
        }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = String(s.name.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "-" }.prefix(40))
        let id = "\(stamp.string(from: .now))-\(safeName)-\(String(s.signature.prefix(6)))"
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { try fm.moveItem(atPath: s.realPath, toPath: folder.appendingPathComponent("skill").path) }
        catch { try? fm.removeItem(at: folder); throw error }   // nothing changed
        for l in links where isSymlink(l.path) { try? fm.removeItem(atPath: l.path) }
        let q = QuarantinedSkill(id: id, name: s.name, originalPath: s.realPath, links: links, tools: s.tools, removedAt: .now, bytes: s.bytes,
                                 verdict: scan?.verdict.key, score: scan?.score, topFinding: scan?.issues.first.map { $0.finding.isEmpty ? $0.category : $0.finding })
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(q).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
        return q
    }

    static func list() -> [QuarantinedSkill] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d -> QuarantinedSkill? in
            guard let q = try? dec.decode(QuarantinedSkill.self, from: Data(contentsOf: d.appendingPathComponent("record.json"))), q.id == d.lastPathComponent else { return nil }
            return q
        }.sorted { $0.removedAt > $1.removedAt }
    }

    struct RestoreError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Puts the folder back where it was, and the links that pointed at it.
    static func restore(_ q: QuarantinedSkill) throws {
        let fm = FileManager.default
        guard q.id == (q.id as NSString).lastPathComponent, !q.id.contains("..") else { throw RestoreError(message: "This record is damaged.") }
        let folder = directory.appendingPathComponent(q.id, isDirectory: true), skill = folder.appendingPathComponent("skill")
        guard fm.fileExists(atPath: skill.path) else { throw RestoreError(message: "The saved copy is gone.") }
        let h = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard q.originalPath.hasPrefix(h + "/") else { throw RestoreError(message: "The original location is outside your home folder, so I won't restore it automatically.") }
        guard !fm.fileExists(atPath: q.originalPath) else { throw RestoreError(message: "\(Fmt.tilde(q.originalPath)) already exists. Move it away first.") }
        try fm.createDirectory(atPath: (q.originalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.moveItem(atPath: skill.path, toPath: q.originalPath)
        for l in q.links where l.path.hasPrefix(h + "/") && !fm.fileExists(atPath: l.path) && !isSymlink(l.path) {
            try? fm.createDirectory(atPath: (l.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: l.path, withDestinationPath: l.target)
        }
        try? fm.removeItem(at: folder)
    }

    static func delete(_ q: QuarantinedSkill) {
        guard q.id == (q.id as NSString).lastPathComponent, !q.id.contains("..") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(q.id, isDirectory: true))
    }
}
