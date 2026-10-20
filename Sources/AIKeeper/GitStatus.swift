import SwiftUI

/// Answers "do I still need this worktree?" from git state and the pull request.
struct Neededness {
    enum Level { case needed, attention, done, idle }
    let level: Level
    let headline: String
    let detail: String

    var color: Color {
        switch level {
        case .needed: .gray
        case .attention: .orange
        case .done: Brand.accent
        case .idle: .gray
        }
    }
    var symbol: String {
        switch level {
        case .needed: "arrow.triangle.pull"
        case .attention: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "moon.zzz.fill"
        }
    }
}

extension PRInfo {
    var detailLine: String {
        var parts: [String] = []
        if isDraft == true { parts.append("Draft") }
        switch checks { case "pass": parts.append("Checks passing"); case "fail": parts.append("Checks failing"); case "pending": parts.append("Checks running"); default: break }
        switch review { case "APPROVED": parts.append("Approved"); case "CHANGES_REQUESTED": parts.append("Changes requested"); case "REVIEW_REQUIRED": parts.append("Waiting for review"); default: break }
        return parts.joined(separator: " · ")
    }
    var whenDone: String? {
        (mergedAt ?? closedAt).map { $0.formatted(.relative(presentation: .named)) }
    }
}

extension Entry {
    /// nil for entries that aren't git worktrees or haven't been measured yet.
    var neededness: Neededness? {
        guard kind == .workspace, measured, exists, let g = git else { return nil }
        let dirty = g.dirtyCount, unpushed = g.unpushed
        func unsaved() -> String {
            [dirty > 0 ? "\(dirty) uncommitted file\(dirty == 1 ? "" : "s")" : nil,
             unpushed > 0 ? "\(unpushed) commit\(unpushed == 1 ? "" : "s") not on any remote" : nil].compactMap { $0 }.joined(separator: " and ")
        }
        let base = g.defaultBranch

        if let pr {
            switch pr.state {
            case "OPEN":
                let d = pr.detailLine
                return Neededness(level: .needed, headline: pr.isDraft == true ? "In use: draft PR #\(pr.number)" : "In use: PR #\(pr.number) is open",
                                  detail: (d.isEmpty ? "" : d + ". ") + (dirty + unpushed > 0 ? "Unsaved here: \(unsaved())." : "Everything is pushed."))
            case "MERGED":
                let after = g.unpushedAfterMerge
                if dirty + after > 0 {
                    let parts = [dirty > 0 ? "\(dirty) uncommitted file\(dirty == 1 ? "" : "s")" : nil,
                                 after > 0 ? "\(after) commit\(after == 1 ? "" : "s") made after the merge" : nil].compactMap { $0 }.joined(separator: " and ")
                    return Neededness(level: .attention, headline: "PR #\(pr.number) merged, but there is newer work",
                                      detail: "\(parts.prefix(1).uppercased() + parts.dropFirst()). Check it before removing.")
                }
                return Neededness(level: .done, headline: "Not needed: PR #\(pr.number) merged" + (pr.whenDone.map { " \($0)" } ?? ""),
                                  detail: "The work is on \(base) and nothing here is unsaved. Safe to remove.")
            default:
                if dirty + unpushed > 0 {
                    return Neededness(level: .attention, headline: "PR #\(pr.number) was closed, but this folder has changes",
                                      detail: "\(unsaved().prefix(1).uppercased() + unsaved().dropFirst()). Remove it only if the work is abandoned.")
                }
                return Neededness(level: .done, headline: "Probably not needed: PR #\(pr.number) was closed",
                                  detail: "It was closed without merging and nothing here is unsaved.")
            }
        }
        let noGH = PRService.gh == nil ? " Install the GitHub CLI to see pull requests." : ""
        if g.merged {
            if dirty > 0 {
                return Neededness(level: .attention, headline: "Merged into \(base), but \(dirty) file\(dirty == 1 ? " is" : "s are") uncommitted",
                                  detail: "Its commits are on \(base). The uncommitted changes exist only here.")
            }
            return Neededness(level: .done, headline: "Not needed: merged into \(base)", detail: "Its commits are all on \(base) and nothing here is unsaved. Safe to remove.")
        }
        if dirty + unpushed > 0 {
            return Neededness(level: .attention, headline: "Has work and no pull request", detail: "\(unsaved().prefix(1).uppercased() + unsaved().dropFirst()). Open a PR or push it to keep it.\(noGH)")
        }
        if g.aheadOfBase == 0 {
            return Neededness(level: .idle, headline: "Nothing here", detail: "No commits beyond \(base) and no changes. Remove it if you're not using it.\(noGH)")
        }
        return Neededness(level: .attention, headline: "Pushed, but no pull request", detail: "\(g.aheadOfBase) commit\(g.aheadOfBase == 1 ? "" : "s") beyond \(base), all on a remote. Open a PR or remove it.\(noGH)")
    }

    /// One short line for the list.
    var gitSummary: (text: String, color: Color)? {
        guard kind == .workspace, measured, exists, let g = git else { return nil }
        if let pr {
            switch pr.state {
            case "OPEN":
                let c = pr.checks.map { $0 == "pass" ? " · passing" : $0 == "fail" ? " · failing" : " · running" } ?? ""
                return ("PR #\(pr.number) open\(c)", pr.checks == "fail" ? .red : .gray)
            case "MERGED": return ("PR #\(pr.number) merged" + (g.unpushedAfterMerge > 0 ? " + newer work" : ""), g.unpushedAfterMerge > 0 ? .orange : Brand.merged)
            default: return ("PR #\(pr.number) closed", .gray)
            }
        }
        if g.dirtyCount > 0 { return ("\(g.dirtyCount) uncommitted", .orange) }
        if g.unpushed > 0 { return ("\(g.unpushed) unpushed", .orange) }
        if g.merged { return ("Merged", Brand.merged) }
        if g.aheadOfBase == 0 { return ("No changes", .gray) }
        return ("Pushed, no PR", .gray)
    }
}
