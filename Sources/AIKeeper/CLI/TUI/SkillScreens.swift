import Foundation

final class SkillsScreen: Screen {
    var title: String { "Skills" }
    var tickInterval: Double { 0 }
    var keys: [(String, String)] {
        if ask != nil { return [("y", "yes"), ("any other key", "no")] }
        return [("↑↓", "move"), ("enter", "findings"), ("s", "scan this"), ("S", "scan all new"), ("f", "filter")] + (scanner == nil ? [("i", "install scanner")] : []) + [("esc", "back")]
    }

    private var skills: [SkillInfo]
    private var cache: [String: SkillScan]
    private var scanner: String?
    private var filter = 0                    // 0 all · 1 worth a look · 2 not scanned
    private var list = ListState()
    private var ask: (String, () -> Void)?

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
            let line = " \(cur ? A.paint("▸", A.blue) : " ") " + A.paint(Ansi.pad("● " + v.label, 17), color(v)) + Ansi.pad(score, 4, right: true) + "  "
                + (cur ? A.paint(Ansi.pad(s.name, 30), A.bold) : Ansi.pad(s.name, 30)) + A.paint(s.hasScripts ? " scripts" : "", A.amber)
            let left = cur ? "\u{1B}[7m" + Ansi.pad(Self.plain(line), lw) + A.reset : Ansi.pad(line, lw)
            out.append(split ? left + A.paint(" │ ", A.gray + A.dim) + (i < preview.count ? preview[i] : "") : left)
        }
        if split { let end = min(bodyH, preview.count); if shown < end { for i in shown..<end { out.append(Ansi.pad("", lw) + A.paint(" │ ", A.gray + A.dim) + preview[i]) } } }
        while out.count < bodyH + 2 { out.append("") }
        out.append(" " + Chrome.rule(w - 2))
        if let q = ask { out.append(" " + A.paint(q.0 + "  (y/n)", A.bold + A.amber)) }
        else { out.append(" " + A.paint("Findings are heuristics, not verdicts. Read the lines they point at before deciding.", A.gray)) }
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

    func handle(_ key: Key, _ ui: TUI) {
        if let q = ask { ask = nil; if key == .char("y") { q.1() }; return }
        let rows = visible
        switch key {
        case .up, .char("k"): list.move(-1, count: rows.count)
        case .down, .char("j"): list.move(1, count: rows.count)
        case .pageUp: list.move(-10, count: rows.count)
        case .pageDown: list.move(10, count: rows.count)
        case .char("f"), .tab: filter = (filter + 1) % 3; list = ListState()
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

    /// Scans in the background and keeps the screen alive while it runs. Results are saved as they arrive.
    private func scan(_ targets: [SkillInfo], _ ui: TUI) {
        guard let binary = scanner else { ui.flash("SkillSpector is not installed. Press i to install it."); return }
        guard !targets.isEmpty else { ui.flash("Nothing to scan: every skill is up to date."); return }
        let lock = NSLock()
        var progress = 0, snapshot = cache, failed = 0, current = ""
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            SkillScanner.scanAll(targets, binary: binary) { s, result, n in
                lock.lock(); defer { lock.unlock() }
                progress = n; current = s.name
                switch result { case .success(let c): snapshot[s.realPath] = c; SkillScanner.saveCache(snapshot); case .failure: failed += 1 }
            }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            lock.lock(); let msg = "Scanning \(progress)/\(targets.count)  \(current)"; lock.unlock()
            ui.flash(msg, seconds: 30); ui.draw()
        }
        lock.lock(); cache = snapshot; lock.unlock()
        ui.flash(failed == 0 ? "Scanned \(targets.count) skill\(targets.count == 1 ? "" : "s")" : "Scanned \(targets.count - failed), \(failed) failed", seconds: 6)
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
