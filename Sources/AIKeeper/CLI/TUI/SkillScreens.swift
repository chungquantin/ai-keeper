import Foundation

final class SkillsScreen: Screen {
    var title: String { "Skills" }
    var tickInterval: Double { job != nil ? 0.3 : 0 }
    var keys: [(String, String)] {
        if job != nil { return [("↑↓", "move"), ("esc", "stop the scan")] }
        if ask != nil { return [("y", "yes"), ("any other key", "no")] }
        return [("space", "select"), ("a", "all high risk"), ("x", "remove"), ("enter", "findings"), ("s", "scan"), ("S", "scan new"), ("u", "removed"), ("f", "filter")] + (scanner == nil ? [("i", "install scanner")] : []) + [("esc", "back")]
    }

    private var skills: [SkillInfo]
    private var cache: [String: SkillScan]
    private var scanner: String?
    private var filter = 0                    // 0 all · 1 worth a look · 2 not scanned
    private var list = ListState()
    private var ask: (String, () -> Void)?

    /// A scan runs in the background while the screen stays alive: keys work, and Esc stops it.
    private final class ScanJob: @unchecked Sendable {
        let token = SkillScanner.ScanToken()
        let lock = NSLock()
        let total: Int
        let started = Date()
        var done = 0, failed = 0, finished = false
        var snapshot: [String: SkillScan]
        init(total: Int, snapshot: [String: SkillScan]) { self.total = total; self.snapshot = snapshot }
    }
    private var job: ScanJob?
    private var selected: Set<String> = []

    init(skills: [SkillInfo]? = nil, cache: [String: SkillScan]? = nil, scanner: String?? = nil) {
        self.skills = skills ?? SkillLibrary.skills()
        self.cache = cache ?? SkillScanner.loadCache()
        self.scanner = scanner ?? SkillScanner.locate()
    }

    private func verdict(_ s: SkillInfo) -> SkillVerdict { SkillLibrary.verdict(s, cache) }

    private var visible: [SkillInfo] {
        let l = skills.filter { s in
            switch filter {
            case 1: return verdict(s) == .caution || verdict(s) == .danger
            case 2: return verdict(s) == .unscanned
            default: return true
            }
        }
        return l.sorted { (SkillLibrary.sortKey(verdict($0)), $0.name.lowercased()) < (SkillLibrary.sortKey(verdict($1)), $1.name.lowercased()) }
    }

    private func color(_ v: SkillVerdict) -> String { [A.blue, A.violet, A.red, A.gray][v.rawValue] }

    func render(_ w: Int, _ h: Int) -> [String] {
        let rows = visible
        let review = skills.filter { verdict($0) == .caution || verdict($0) == .danger }.count
        var out: [String] = []
        out.append(" " + Widget.chips(["All \(skills.count)", "Worth a look \(review)", "Not scanned \(skills.filter { verdict($0) == .unscanned }.count)"], selected: filter)
                   + "   " + (scanner == nil ? A.paint("SkillSpector is not installed. Press i.", A.violet) : A.paint("Scanned with NVIDIA SkillSpector", A.gray)))
        out.append(" " + Chrome.rule(w - 2))
        let bodyH = max(3, h - 4)
        list.clamp(count: rows.count, visible: bodyH)
        let split = w >= 112, lw = split ? Int(Double(w) * 0.5) : w - 1
        let preview = split && !rows.isEmpty ? previewLines(rows[list.cursor], w - lw - 4, bodyH) : []
        if rows.isEmpty { out += ["", "   " + A.paint(skills.isEmpty ? "No skills found in ~/.claude/skills, ~/.agents/skills and the other usual places." : "Nothing matches this filter. Press f.", A.gray)] }
        let shown = rows.isEmpty ? 0 : min(bodyH, rows.count - list.offset)
        for i in 0..<shown {
            let idx = list.offset + i, s = rows[idx], cur = idx == list.cursor, v = verdict(s)
            let score = SkillScanner.current(s, in: cache).map { "\($0.score)" } ?? ""
            let sel = selected.contains(s.realPath)
            let line = (sel ? A.paint("▌", A.blue) : " ") + " " + A.paint(Ansi.pad(v.label.lowercased(), 15), color(v) + (v == .danger ? A.bold : "")) + A.paint(Ansi.pad(score, 4, right: true), A.gray) + "  "
                + (cur ? A.paint(Ansi.pad(s.name, 30), A.bold) : Ansi.pad(s.name, 30)) + A.paint(s.hasScripts ? " scripts" : "", A.amber)
            let left = cur ? Widget.band(line, lw) : Ansi.pad(line, lw)
            out.append(split ? left + A.paint(" │ ", A.gray + A.dim) + (i < preview.count ? preview[i] : "") : left)
        }
        if split { let end = min(bodyH, preview.count); if shown < end { for i in shown..<end { out.append(Ansi.pad("", lw) + A.paint(" │ ", A.gray + A.dim) + preview[i]) } } }
        while out.count < bodyH + 2 { out.append("") }
        out.append(" " + Chrome.rule(w - 2))
        if let j = job {
            j.lock.lock(); let done = j.done, failed = j.failed; j.lock.unlock()
            let elapsed = Date().timeIntervalSince(j.started)
            let eta = done > 0 ? "  about \(Fmt.clock(elapsed / Double(done) * Double(j.total - done))) left" : ""
            let now = j.token.current.prefix(2).joined(separator: ", ")
            out.append(" " + Widget.bar(Double(done) / Double(max(j.total, 1)), width: 18) + A.paint("  Scanning \(done)/\(j.total) · \(Fmt.clock(elapsed))\(eta)" + (failed > 0 ? " · \(failed) failed" : "") + "  ", A.bold) + A.paint(now, A.gray))
        } else if let q = ask { out.append(" " + A.paint(q.0 + "  (y/n)", A.bold + A.amber)) }
        else if !selected.isEmpty {
            out.append(" " + A.paint("\(selected.count) selected", A.bold) + A.paint("   x moves them to quarantine (you can restore them) · n clears the selection", A.gray))
        } else { out.append(" " + A.paint("Findings are heuristics, not verdicts. Read the lines they point at before deciding.", A.gray)) }
        return out
    }

    static func plain(_ s: String) -> String {
        var out = "", inEsc = false
        for c in s.unicodeScalars { if inEsc { if c == "m" { inEsc = false }; continue }; if c == "\u{1B}" { inEsc = true; continue }; out.unicodeScalars.append(c) }
        return out
    }

    private func previewLines(_ s: SkillInfo, _ w: Int, _ h: Int) -> [String] {
        var l: [String] = [A.paint(s.name, A.bold), A.paint(s.tools.joined(separator: ", ") + (s.plugin.map { " · plugin \($0)" } ?? ""), A.gray), ""]
        l += UI.wrap(s.description, w).prefix(4).map { $0 }
        l.append("")
        l.append(UI.label("Where") + A.paint(Fmt.tilde(s.realPath), A.gray))
        l.append(UI.label("Contents") + "\(s.files) files, \(Fmt.size(s.bytes))" + (s.hasScripts ? A.paint("  has scripts", A.amber) : ""))
        l.append("")
        guard let c = SkillScanner.current(s, in: cache) else { return (l + [A.paint("Not scanned yet. Press s.", A.gray)]).prefix(h).map { Ansi.fit($0, w) } }
        l.append(A.paint(c.verdict.label, A.bold + color(c.verdict)) + A.paint("  score \(c.score)/100 · \(c.issues.count) finding\(c.issues.count == 1 ? "" : "s") · \(Fmt.ago(c.scannedAt))", A.gray))
        if !c.complete { l.append(A.paint("Not everything could be inspected.", A.violet)) }
        for i in c.issues.prefix(4) {
            l.append("")
            l.append(A.paint(i.severity.lowercased(), i.rank >= 3 ? A.red : A.violet) + "  " + A.paint(i.finding.isEmpty ? i.category : i.finding, A.bold))
            l.append(A.paint("\(i.file):\(i.line)  \(i.rule) · \(Int(i.confidence * 100))%", A.gray))
        }
        if c.issues.count > 4 { l.append(A.paint("+\(c.issues.count - 4) more. Press enter.", A.gray)) }
        return l.prefix(h).map { Ansi.fit($0, w) }
    }

    func tick(_ ui: TUI) {
        guard let j = job else { return }
        j.lock.lock(); cache = j.snapshot; let finished = j.finished, done = j.done, failed = j.failed; j.lock.unlock()
        if finished {
            job = nil
            ui.flash(j.token.cancelled ? "Stopped after \(done) of \(j.total). Finished results are saved." : failed == 0 ? "Scanned \(j.total) skill\(j.total == 1 ? "" : "s")" : "Scanned \(done), \(failed) failed", seconds: 6)
        }
    }

    func handle(_ key: Key, _ ui: TUI) {
        if let j = job {
            switch key {
            case .esc, .char("q"): j.token.cancel(); ui.flash("Stopping…")
            case .up, .char("k"): list.move(-1, count: visible.count)
            case .down, .char("j"): list.move(1, count: visible.count)
            case .char("s"), .char("S"), .char("i"): ui.flash("A scan is running. Press Esc to stop it.")
            default: break
            }
            return
        }
        if let q = ask { ask = nil; if key == .char("y") { q.1() }; return }
        let rows = visible
        switch key {
        case .up, .char("k"): list.move(-1, count: rows.count)
        case .down, .char("j"): list.move(1, count: rows.count)
        case .pageUp: list.move(-10, count: rows.count)
        case .pageDown: list.move(10, count: rows.count)
        case .char("f"), .tab: filter = (filter + 1) % 3; list = ListState()
        case .space:
            guard rows.indices.contains(list.cursor) else { break }
            let id = rows[list.cursor].realPath
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            list.move(1, count: rows.count)
        case .char("a"):
            let risky = rows.filter { verdict($0) == .danger }
            if risky.isEmpty { ui.flash("No skill in this list is rated do-not-install.") } else { risky.forEach { selected.insert($0.realPath) }; ui.flash("Selected \(risky.count) rated do-not-install. Read their findings before you remove them.") }
        case .char("n"): selected = []
        case .char("x"):
            var chosen = rows.filter { selected.contains($0.realPath) }
            if chosen.isEmpty, rows.indices.contains(list.cursor) { chosen = [rows[list.cursor]] }
            guard !chosen.isEmpty else { break }
            ui.push(SkillRemoveScreen(skills: chosen, cache: cache, done: { [weak self] in
                self?.selected = []; self?.skills = SkillLibrary.skills()
            }))
        case .char("u"): ui.push(SkillQuarantineScreen(onChange: { [weak self] in self?.skills = SkillLibrary.skills() }))
        case .enter:
            if rows.indices.contains(list.cursor) { ui.push(SkillDetailScreen(skill: rows[list.cursor], scan: SkillScanner.current(rows[list.cursor], in: cache))) }
        case .char("s"):
            if rows.indices.contains(list.cursor) { scan([rows[list.cursor]], ui) }
        case .char("S"): scan(skills.filter { SkillScanner.current($0, in: cache) == nil }, ui)
        case .char("i"):
            guard scanner == nil else { ui.flash("SkillSpector is already installed."); break }
            ask = ("Install NVIDIA SkillSpector \(SkillScanner.pinnedRef) with uv? Downloads it and its dependencies from the internet.", { [weak self] in
                ui.flash("Installing SkillSpector… this can take a minute or two", seconds: 900); ui.draw()
                let r = SkillScanner.install()
                self?.scanner = SkillScanner.locate()
                ui.flash(r.message, seconds: 8)
            })
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }

    /// Starts a scan and returns at once. Results are saved as they arrive, so stopping loses nothing already finished.
    private func scan(_ targets: [SkillInfo], _ ui: TUI) {
        guard let binary = scanner else { ui.flash("SkillSpector is not installed. Press i to install it."); return }
        guard !targets.isEmpty else { ui.flash("Nothing to scan: every skill is up to date."); return }
        let j = ScanJob(total: targets.count, snapshot: cache)
        job = j
        if SkillScanner.lowMemory { ui.flash(SkillScanner.lowMemoryNote, seconds: 8) }
        DispatchQueue.global(qos: .utility).async {
            SkillScanner.scanAll(targets, binary: binary, token: j.token) { s, result, n in
                j.lock.lock(); defer { j.lock.unlock() }
                j.done = n
                switch result { case .success(let c): j.snapshot[s.realPath] = c; SkillScanner.saveCache(j.snapshot); case .failure: j.failed += 1 }
            }
            j.lock.lock(); j.finished = true; j.lock.unlock()
        }
    }
}

final class SkillDetailScreen: Screen {
    var title: String { "Skills  ›  " + skill.name }
    var keys: [(String, String)] { [("↑↓", "scroll"), ("esc", "back")] }
    private let skill: SkillInfo
    private let scan: SkillScan?
    private var offset = 0

    init(skill: SkillInfo, scan: SkillScan?) { self.skill = skill; self.scan = scan }

    private func lines(_ w: Int) -> [String] {
        var l: [String] = [""]
        l += UI.wrap(skill.description, w - 4).map { "  " + $0 }
        l.append(""); l.append("  " + A.paint(Fmt.tilde(skill.realPath), A.gray))
        guard let c = scan else { return l + ["", "  " + A.paint("Not scanned yet.", A.gray)] }
        l.append("")
        l.append("  " + A.paint(c.verdict.label, A.bold + [A.blue, A.violet, A.red, A.gray][c.verdict.rawValue]) + A.paint("  score \(c.score)/100 · SkillSpector \(c.scannerVersion)", A.gray))
        if c.issues.isEmpty { l.append("  No findings.") }
        for i in c.issues {
            l.append("")
            l.append("  " + A.paint(i.severity, i.rank >= 3 ? A.bold + A.red : A.bold + A.violet) + "  " + A.paint(i.finding.isEmpty ? i.category : i.finding, A.bold) + A.paint("   \(i.rule) · \(i.category) · confidence \(Int(i.confidence * 100))%", A.gray))
            l.append("  " + A.paint("\(i.file):\(i.line)", A.gray))
            for e in UI.wrap(i.explanation, w - 6) { l.append("  " + e) }
            if let code = i.snippet, !code.isEmpty { for s in code.split(separator: "\n", omittingEmptySubsequences: false).prefix(6) { l.append("  " + A.paint("│ ", A.gray) + A.paint(String(s), A.gray)) } }
            if !i.remediation.isEmpty { for r in UI.wrap("Fix: " + i.remediation, w - 6).prefix(3) { l.append("  " + A.paint(r, A.gray)) } }
        }
        return l
    }

    func render(_ w: Int, _ h: Int) -> [String] {
        let all = lines(w)
        offset = max(0, min(offset, max(0, all.count - h)))
        return Array(all.dropFirst(offset).prefix(h))
    }

    func handle(_ key: Key, _ ui: TUI) {
        switch key {
        case .up, .char("k"): offset = max(0, offset - 1)
        case .down, .char("j"): offset += 1
        case .pageUp: offset = max(0, offset - 10)
        case .pageDown: offset += 10
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}

// MARK: - Removing skills

final class SkillRemoveScreen: Screen {
    var title: String { "Skills  ›  Remove" }
    var keys: [(String, String)] { [("y", "do it"), ("p", "permanent: \(permanent ? "on" : "off")"), ("esc", "cancel")] }
    private let plan: SkillRemoval.Plan
    private let cache: [String: SkillScan]
    private let done: () -> Void
    private var permanent = false

    init(skills: [SkillInfo], cache: [String: SkillScan], done: @escaping () -> Void) { plan = SkillRemoval.plan(skills); self.cache = cache; self.done = done }

    func render(_ w: Int, _ h: Int) -> [String] {
        var out = [""]
        if plan.removable.isEmpty { out.append("  " + A.paint("None of these can be removed from here.", A.bold)) }
        else {
            out.append("  " + A.paint("These skills will be taken out of use", A.bold) + A.paint("   (\(plan.removable.count))", A.gray))
            out.append("")
            let room = max(3, h - 12 - plan.skipped.count)
            for s in plan.removable.prefix(room) {
                let c = SkillScanner.current(s, in: cache), v = SkillLibrary.verdict(s, cache)
                let top = c?.issues.first.map { "\($0.severity.lowercased()): \($0.finding.isEmpty ? $0.category : $0.finding)" } ?? ""
                out.append("    " + A.paint(Ansi.pad(v.label, 15), [A.blue, A.violet, A.red, A.gray][v.rawValue]) + Ansi.pad(s.name, 30) + A.paint(top, A.gray))
            }
            if plan.removable.count > room { out.append("    " + A.paint("and \(plan.removable.count - room) more", A.gray)) }
        }
        if !plan.skipped.isEmpty {
            out.append(""); out.append("  " + A.paint("Left alone", A.violet))
            for x in plan.skipped.prefix(5) { out.append("    " + A.paint(x.skill.name + "  " + x.reason, A.gray)) }
        }
        out.append("")
        out.append("  " + (permanent ? A.paint("Permanent: the folders are deleted with no way back.", A.red) : A.paint("They move to a quarantine. Press u on the Skills screen, or `keeper skills restore`, to bring one back.", A.gray)))
        out.append("  " + A.paint("Findings are heuristics, not verdicts: a security list can read as an attack. Check before you remove in bulk.", A.gray))
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        switch key {
        case .char("p"): permanent.toggle()
        case .char("y"):
            guard !plan.removable.isEmpty else { break }
            var ok = 0, failed = 0
            for s in plan.removable { do { try SkillRemoval.remove(s, scan: SkillScanner.current(s, in: cache), permanent: permanent); ok += 1 } catch { failed += 1 } }
            ui.pop(); done()
            ui.flash(failed == 0 ? "Removed \(ok) skill\(ok == 1 ? "" : "s")." + (permanent ? "" : " Press u to restore.") : "Removed \(ok), \(failed) failed.", seconds: 6)
        case .esc, .char("q"), .char("n"): ui.pop()
        default: break
        }
    }
}

final class SkillQuarantineScreen: Screen {
    var title: String { "Skills  ›  Removed" }
    var keys: [(String, String)] { ask != nil ? [("y", "yes"), ("any other key", "no")] : [("↑↓", "move"), ("enter", "restore"), ("d", "delete for good"), ("esc", "back")] }
    private var items = SkillRemoval.list()
    private var list = ListState()
    private var ask: (String, () -> Void)?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func render(_ w: Int, _ h: Int) -> [String] {
        var out = ["", "  " + A.paint("Removed skills wait here. Restoring puts the folder, and the links other tools use, back where they were.", A.gray), ""]
        if items.isEmpty { return out + ["  " + A.paint("Nothing removed.", A.gray)] }
        let vis = max(3, h - 8)
        list.clamp(count: items.count, visible: vis)
        for i in 0..<min(vis, max(0, items.count - list.offset)) {
            let idx = list.offset + i, q = items[idx], cur = idx == list.cursor
            let row = "  " + A.paint(Ansi.pad(Fmt.ago(q.removedAt), 12), A.gray) + Ansi.pad(q.verdict ?? "", 9) + (cur ? A.paint(Ansi.pad(q.name, 28), A.bold) : Ansi.pad(q.name, 28)) + A.paint(q.topFinding ?? "", A.gray)
            out.append(cur ? Widget.band(row, w - 2) : row)
        }
        if let a = ask { out.append(""); out.append("  " + A.paint(a.0 + "  (y/n)", A.bold + A.amber)) }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        if let a = ask { ask = nil; if key == .char("y") { a.1() }; return }
        switch key {
        case .up, .char("k"): list.move(-1, count: items.count)
        case .down, .char("j"): list.move(1, count: items.count)
        case .enter, .char("r"):
            guard items.indices.contains(list.cursor) else { break }
            let q = items[list.cursor]
            ask = ("Restore \(q.name) to \(Fmt.tilde(q.originalPath))?", { [weak self] in
                do { try SkillRemoval.restore(q); ui.flash("Restored \(q.name)") } catch { ui.flash(error.localizedDescription) }
                self?.items = SkillRemoval.list(); self?.onChange()
            })
        case .char("d"):
            guard items.indices.contains(list.cursor) else { break }
            let q = items[list.cursor]
            ask = ("Delete the saved copy of \(q.name) for good?", { [weak self] in SkillRemoval.delete(q); ui.flash("Deleted"); self?.items = SkillRemoval.list() })
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}
