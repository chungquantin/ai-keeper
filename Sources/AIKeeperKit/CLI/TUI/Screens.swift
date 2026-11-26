import Foundation

// MARK: - Shared bits

enum UI {
    static func statusStyle(_ e: Entry) -> String {
        if e.kind == .repo || e.verdict == .dangling { return A.gray }
        if e.safety == .danger { return A.red }
        if e.verdict == .deprecated { return e.safety == .caution ? A.violet : A.blue }
        return e.safety == .caution ? A.violet : A.gray
    }

    static func wrap(_ text: String, _ width: Int) -> [String] {
        guard width > 4 else { return [text] }
        var lines: [String] = [], cur = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if cur.isEmpty { cur = String(word) }
            else if cur.count + 1 + word.count <= width { cur += " " + word }
            else { lines.append(cur); cur = String(word) }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.isEmpty ? [""] : lines
    }

    static func label(_ s: String) -> String { A.paint(s.padding(toLength: 13, withPad: " ", startingAt: 0), A.gray) }
}

/// What the home screen and `keeper status` show.
struct Summary {
    var disk = DiskInfo()
    var stats = Stats([])
    var agents: [AgentProc] = []
    var today = 0.0, week = 0.0
    var scanDate: Date?
    var vaultCount = 0
    var health: Int?
    var skillCount = 0, skillsScanned = 0, skillsToReview = 0
    var cleaned = CleanLog.summary([])

    static func load(withAgents: Bool = true) -> Summary {
        var s = Summary()
        s.disk = Tools.diskInfo()
        let entries = Library.entries()
        s.stats = Stats(entries)
        s.scanDate = Library.scanDate
        if withAgents { s.agents = Library.agents().filter { $0.kind != .mcp } }
        (s.today, s.week) = StatusCommands.spend(StatusCommands.cachedUsage() ?? UsageData())
        s.vaultCount = Vault.list().count
        s.cleaned = CleanLog.summary(CleanLog.all())
        let skills = SkillLibrary.skills(), cache = SkillScanner.loadCache()
        s.skillCount = skills.count
        let verdicts = skills.map { SkillLibrary.verdict($0, cache) }
        s.skillsScanned = verdicts.filter { $0 != .unscanned }.count
        s.skillsToReview = verdicts.filter { $0 == .caution || $0 == .danger }.count
        return s
    }
}

// MARK: - Home

final class HomeScreen: Screen {
    var title: String { "Overview" }
    var tickInterval: Double { 5 }
    var keys: [(String, String)] { [("↑↓", "move"), ("enter", "open"), ("r", "rescan"), ("q", "quit")] }
    private var summary: Summary
    private var cursor = 0
    private let items: [(String, String)] = [("Workspaces", "w"), ("Leftovers", "l"), ("Agents", "a"), ("Skills", "c"), ("AI usage", "u"), ("Disk map", "d"), ("System", "s"), ("History", "h"), ("Recently removed", "v")]

    init(summary: Summary = .load()) { self.summary = summary }

    func tick(_ ui: TUI) { summary.agents = Library.agents().filter { $0.kind != .mcp } }

    private func subtitle(_ i: Int) -> String {
        let st = summary.stats
        let removable = st.removable.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let leftovers = (st.orphans + st.caches).reduce(Int64(0)) { $0 + max($1.size ?? 0, 0) }
        switch i {
        case 0: return st.removable.isEmpty ? "nothing is waiting to be removed" : "\(st.removable.count) safe to remove, " + A.paint(Fmt.size(removable), A.amber)
        case 1: return leftovers > 0 ? A.paint(Fmt.size(leftovers), A.amber) + " of old chat history and caches" : "nothing left behind"
        case 2: let n = summary.agents.filter { $0.state == .needsInput }.count; return "\(summary.agents.count) running" + (n > 0 ? ", " + A.paint("\(n) waiting for you", A.bold) : "")
        case 3:
            let n = summary.skillCount, bad = summary.skillsToReview
            return n == 0 ? "none found" : "\(n) installed" + (summary.skillsScanned == 0 ? ", not scanned yet" : bad > 0 ? ", " + A.paint("\(bad) worth a look", A.bold) : ", all scanned look safe")
        case 4: return "\(Fmt.usd(summary.today)) today, \(Fmt.usd(summary.week)) this week"
        case 5: return "where the space went"
        case 6: return "cpu, memory, disk, the heaviest apps"
        case 7: return summary.cleaned.runs == 0 ? "no cleanups yet" : A.paint(Fmt.size(summary.cleaned.totalBytes), A.amber) + " freed on \(summary.cleaned.activeDays) days"
        default: return summary.vaultCount == 0 ? "nothing saved" : "\(summary.vaultCount) snapshots you can bring back"
        }
    }

    func render(_ w: Int, _ h: Int) -> [String] {
        let st = summary.stats
        let inner = min(w - 6, 96)
        let kept = st.keptArtifactBytes, removable = st.removable.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let left = (st.orphans + st.caches).reduce(Int64(0)) { $0 + max($1.size ?? 0, 0) }
        var out = [""]

        // The one big thing: how much you can get back.
        let (num, unit) = Fmt.size(st.reclaimable).split(separator: " ").map(String.init).count == 2 ? (Fmt.size(st.reclaimable).split(separator: " ").map(String.init)[0], Fmt.size(st.reclaimable).split(separator: " ").map(String.init)[1]) : ("0", "B")
        let big = Widget.bigNumber(num)
        for (i, row) in big.enumerated() {
            let tail = i == 1 ? "  " + A.paint(unit, A.bold) : i == 2 ? "  " + A.paint("you can get back", A.gray) : ""
            out.append("   " + A.paint(row, A.amber) + tail)
        }
        out.append("   " + A.paint(summary.scanDate.map { "scanned \(Fmt.ago($0))" } ?? "not scanned yet, press r", A.gray))
        out.append("")

        // Where it comes from, as line weights drawn to the same scale.
        out.append("   " + Chrome.titled("where it comes from", inner))
        let mx = Double(max(kept, removable, left, 1))
        func ledger(_ name: String, _ bytes: Int64, _ note: String = "") {
            out.append("   " + Ansi.pad(name, 15) + Widget.bar(Double(bytes) / mx, width: min(30, inner - 40), color: A.amber) + "  " + Ansi.pad(Fmt.size(bytes), 9, right: true) + A.paint(note.isEmpty ? "" : "  " + note, A.gray))
        }
        ledger("build folders", kept)
        ledger("workspaces", removable, "\(st.removable.count) safe to remove")
        ledger("leftovers", left)
        out.append("")

        out.append("   " + Chrome.titled("go to", inner))
        for (i, item) in items.enumerated() {
            let row = "   " + A.paint(String(i + 1), A.gray) + "  " + A.paint(Ansi.pad(item.0, 18), i == cursor ? A.bold : "") + subtitle(i)
            out.append(i == cursor ? Widget.band(row, inner + 4) : row)
        }
        if let d = summary.scanDate, Date().timeIntervalSince(d) > 6 * 3600 { out.append(""); out.append("   " + A.paint("the scan is \(Fmt.ago(d)): press r to refresh it", A.bold)) }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        switch key {
        case .up, .char("k"): cursor = (cursor + items.count - 1) % items.count
        case .down, .char("j"): cursor = (cursor + 1) % items.count
        case .char("q"), .esc: ui.quit = true
        case .char("r"): rescan(ui)
        case .enter: open(cursor, ui)
        case .char(let c):
            if let i = items.firstIndex(where: { $0.1 == String(c) }) { cursor = i; open(i, ui) }
            else if let n = Int(String(c)), n >= 1, n <= items.count { cursor = n - 1; open(n - 1, ui) }
        default: break
        }
    }

    private func open(_ i: Int, _ ui: TUI) {
        switch i {
        case 0: ui.push(WorkspacesScreen(onChange: { [weak self] in self?.summary = .load() }))
        case 1: ui.push(LeftoversScreen(onChange: { [weak self] in self?.summary = .load() }))
        case 2: ui.push(AgentsScreen())
        case 3: ui.push(SkillsScreen())
        case 4: ui.push(UsageScreen())
        case 5: ui.push(DiskScreen())
        case 6: ui.push(SystemScreen())
        case 7: ui.push(HistoryScreen())
        default: ui.push(VaultScreen(onChange: { [weak self] in self?.summary = .load() }))
        }
    }

    private func rescan(_ ui: TUI) {
        TUIActions.scan(ui)
        summary = .load()
    }
}

enum TUIActions {
    /// Runs a scan, showing its progress on the bottom line.
    static func scan(_ ui: TUI) {
        Out.statusHook = { ui.flash($0, seconds: 120); ui.draw() }
        _ = Library.scan(prs: true)
        Out.statusHook = nil
        ui.flash("Scan finished")
    }
}

// MARK: - Workspaces

final class WorkspacesScreen: Screen {
    var title: String { "Workspaces" }
    var keys: [(String, String)] {
        searching ? [("type", "to filter"), ("enter", "done"), ("esc", "clear")]
                  : [("space", "select"), ("a", "all safe"), ("x", "remove"), ("c", "clean builds"), ("f", "filter"), ("/", "search"), ("esc", "back")]
    }

    private var all: [Entry] = []
    private var filter = 1                    // 0 safe to remove · 1 deprecated · 2 all
    private var sort = 0                      // 0 size · 1 activity · 2 name
    private var query = ""
    private var searching = false
    private var selected: Set<String> = []
    private var list = ListState()
    private var allowDanger = false
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void = {}, preselect: Int = 0) {
        self.onChange = onChange
        reload()
        if preselect > 0 { for e in visible.filter({ $0.verdict == .deprecated && $0.safety == .safe }).prefix(preselect) { selected.insert(e.id) } }
    }

    private func reload() {
        all = Library.entries().filter { ($0.kind == .workspace || $0.kind == .repo) && (($0.size ?? 0) > 0 || $0.artifactBytes > 0) }
        selected = selected.filter { id in all.contains { $0.id == id } }
    }

    private var visible: [Entry] {
        var l = all
        switch filter {
        case 0: l = l.filter { $0.kind == .workspace && $0.verdict == .deprecated && $0.safety == .safe }
        case 1: l = l.filter { $0.verdict == .deprecated && $0.kind == .workspace }
        default: break
        }
        if !query.isEmpty { let q = query.lowercased(); l = l.filter { $0.name.lowercased().contains(q) || $0.repoName.lowercased().contains(q) } }
        switch sort {
        case 1: l.sort { $0.activityValue > $1.activityValue }
        case 2: l.sort { $0.name.lowercased() < $1.name.lowercased() }
        default: l.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        }
        return l
    }

    func render(_ w: Int, _ h: Int) -> [String] {
        let rows = visible
        let selBytes = rows.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let selCount = selected.count
        var out: [String] = []
        out.append(" " + Widget.chips(["Safe to remove", "Deprecated", "All"], selected: filter) + A.paint("   sorted by " + ["size", "activity", "name"][sort], A.gray)
                   + (searching || !query.isEmpty ? "   " + A.paint("/ " + query + (searching ? "▏" : ""), A.blue) : ""))
        out.append(" " + Chrome.rule(w - 2))
        let bodyH = max(3, h - 4)
        let heaviest = rows.compactMap(\.size).max() ?? 1
        list.clamp(count: rows.count, visible: bodyH)
        let split = w >= 110
        let lw = split ? Int(Double(w) * 0.56) : w - 1
        let preview = split && !rows.isEmpty ? previewLines(rows[list.cursor], w - lw - 4, bodyH) : []
        if rows.isEmpty { out.append(""); out.append("   " + A.paint(all.isEmpty ? "No scan yet. Go back and press r." : "Nothing matches this filter. Press f to change it.", A.gray)) }
        for i in 0..<(rows.isEmpty ? 0 : min(bodyH, rows.count - list.offset)) {
            let idx = list.offset + i, e = rows[idx]
            let isCursor = idx == list.cursor, isSel = selected.contains(e.id)
            let gutter = isSel ? A.paint("▌", A.blue) : " "                       // a selected row has a cobalt bar in the margin
            let danger = e.safety == .danger && !allowDanger
            let status = A.paint(Ansi.pad(Library.statusText(e).lowercased(), 16), danger ? A.gray + A.dim : UI.statusStyle(e))
            let weight = Widget.bar(Double(e.size ?? 0) / Double(max(heaviest, 1)), width: 5, color: A.amber)   // size drawn to the scale of this list
            let line = gutter + " " + A.paint(Ansi.pad(Fmt.size(e.size ?? 0), 8, right: true), isSel ? A.bold + A.amber : "") + " " + weight + "  " + status
                + Ansi.fit(A.paint(e.repoName + "/", A.gray) + (isCursor ? A.paint(e.name, A.bold) : e.name), lw - 38)
            let left = isCursor ? Widget.band(line, lw) : Ansi.pad(line, lw)
            out.append(split ? left + A.paint(" │ ", A.gray + A.dim) + (i < preview.count ? preview[i] : "") : left)
        }
        if split {   // the preview can be taller than the list when few rows match
            let start = min(bodyH, max(0, rows.count - list.offset)), end = min(bodyH, preview.count)
            if start < end { for i in start..<end { out.append(Ansi.pad("", lw) + A.paint(" │ ", A.gray + A.dim) + preview[i]) } }
        }
        while out.count < bodyH + 2 { out.append("") }
        out.append(" " + Chrome.rule(w - 2))
        out.append(selCount > 0
                   ? " " + A.paint("\(selCount) selected", A.bold) + A.paint(" · ", A.gray) + A.paint(Fmt.size(selBytes), A.bold + A.amber) + A.paint(" can be freed   x remove · c clean build folders only · n clear", A.gray)
                   : " " + A.paint("\(rows.count) workspaces · \(Fmt.size(rows.reduce(Int64(0)) { $0 + ($1.size ?? 0) }))", A.gray) + A.paint("   space marks a workspace, a marks every safe one", A.gray))
        return out
    }

    private func stripStyle(_ s: String) -> String {
        var out = "", inEsc = false
        for c in s.unicodeScalars { if inEsc { if c == "m" { inEsc = false }; continue }; if c == "\u{1B}" { inEsc = true; continue }; out.unicodeScalars.append(c) }
        return out
    }

    private func previewLines(_ e: Entry, _ w: Int, _ h: Int) -> [String] {
        var l: [String] = []
        l.append(A.paint(e.name, A.bold))
        l.append(A.paint(e.repoName + (e.branch.map { " · \($0)" } ?? ""), A.gray))
        l.append("")
        l.append(A.paint(Library.statusText(e), UI.statusStyle(e)) + A.paint("  ·  active \(Fmt.ago(e.lastActivity))", A.gray))
        if let n = e.neededness {
            l.append(A.paint(n.headline, A.bold))
            l += UI.wrap(n.detail, w).map { A.paint($0, A.gray) }
        }
        if let g = e.git {
            l.append("")
            l.append(UI.label("Working tree") + (g.dirtyCount == 0 ? "clean" : A.paint("\(g.dirtyCount) uncommitted", A.red)))
            l.append(UI.label("Not pushed") + (g.unpushed == 0 ? "nothing" : A.paint("\(g.unpushed) commits", A.red)))
            l.append(UI.label("Versus \(g.defaultBranch)") + (g.merged ? "landed" : "\(g.aheadOfBase) ahead · \(g.behindBase) behind"))
        }
        if let p = e.pr { l.append(UI.label("Pull request") + "#\(p.number) \(p.state.lowercased())" + (p.detailLine.isEmpty ? "" : A.paint("  \(p.detailLine)", A.gray))) }
        if !e.artifacts.isEmpty {
            l.append("")
            l.append(A.paint("Rebuildable  ", A.gray) + A.paint(Fmt.size(e.artifactBytes), A.amber))
            let top = e.artifacts.sorted { $0.bytes > $1.bytes }.prefix(4)
            let mx = Double(top.first?.bytes ?? 1)
            for a in top { l.append("  " + Widget.bar(Double(a.bytes) / mx, width: 10, color: A.amber) + " " + Ansi.pad(Fmt.size(a.bytes), 8, right: true) + " " + a.label) }
        }
        return Array(l.prefix(h)).map { Ansi.fit($0, w) }
    }

    func handle(_ key: Key, _ ui: TUI) {
        let rows = visible
        if searching {
            switch key {
            case .esc: searching = false; query = ""; list = ListState()
            case .enter: searching = false
            case .backspace: if !query.isEmpty { query.removeLast() }; list = ListState()
            case .char(let c): query.append(c); list = ListState()
            case .up: list.move(-1, count: rows.count)
            case .down: list.move(1, count: rows.count)
            default: break
            }
            return
        }
        switch key {
        case .up, .char("k"): list.move(-1, count: rows.count)
        case .down, .char("j"): list.move(1, count: rows.count)
        case .pageUp: list.move(-10, count: rows.count)
        case .pageDown: list.move(10, count: rows.count)
        case .home: list.cursor = 0
        case .end: list.cursor = max(0, rows.count - 1)
        case .space, .enter:
            guard rows.indices.contains(list.cursor), rows[list.cursor].kind != .repo else { break }
            let id = rows[list.cursor].id
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            if key == .space { list.move(1, count: rows.count) }
        case .char("a"): for e in rows where e.kind == .workspace && e.verdict == .deprecated && e.safety == .safe { selected.insert(e.id) }
        case .char("n"): selected = []
        case .char("D"): allowDanger.toggle(); ui.flash(allowDanger ? "Workspaces with unsaved work can now be selected. They are saved to the vault first." : "Unsaved work is protected again")
        case .char("f"), .tab: filter = (filter + 1) % 3; list = ListState()
        case .char("s"): sort = (sort + 1) % 3
        case .char("/"): searching = true
        case .char("r"): TUIActions.scan(ui); reload(); onChange()
        case .char("x"): act(.removeWorkspaces, rows, ui)
        case .char("c"): act(.purgeArtifacts, rows, ui)
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }

    private func act(_ mode: PlanMode, _ rows: [Entry], _ ui: TUI) {
        var chosen = rows.filter { selected.contains($0.id) }
        if chosen.isEmpty, rows.indices.contains(list.cursor) { chosen = [rows[list.cursor]] }
        guard !chosen.isEmpty else { return }
        ui.push(ConfirmScreen(mode: mode, chosen: chosen, allowDanger: allowDanger, done: { [weak self] in self?.selected = []; self?.reload(); self?.onChange() }))
    }
}

// MARK: - Leftovers

final class LeftoversScreen: Screen {
    var title: String { "Leftovers" }
    var keys: [(String, String)] { [("space", "select"), ("a", "all"), ("x", "clear"), ("esc", "back")] }
    private var items: [Entry] = []
    private var selected: Set<String> = []
    private var list = ListState()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void = {}) { self.onChange = onChange; reload() }
    private func reload() { items = Library.entries().filter { $0.kind == .sessionData || $0.kind == .cache }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }; selected = selected.filter { id in items.contains { $0.id == id } } }

    func render(_ w: Int, _ h: Int) -> [String] {
        var out = ["", "  " + A.paint("Chat history of workspaces that no longer exist, and caches your agent tools rebuild on demand.", A.gray), ""]
        list.clamp(count: items.count, visible: max(3, h - 7))
        if items.isEmpty { out.append("  " + A.paint("Nothing left behind.", A.gray)) }
        for i in 0..<min(max(3, h - 7), max(0, items.count - list.offset)) {
            let idx = list.offset + i, e = items[idx], cur = idx == list.cursor
            let sel = selected.contains(e.id)
            let line = (sel ? A.paint("▌", A.blue) : " ") + " " + A.paint(Ansi.pad(Fmt.size(e.size ?? 0), 8, right: true), sel ? A.bold + A.amber : "") + "  "
                + A.paint(Ansi.pad(e.kind == .cache ? "cache" : "history", 9), A.gray) + (cur ? A.paint(e.name, A.bold) : e.name) + A.paint("   " + e.note, A.gray)
            out.append("  " + (cur ? Widget.band(line, w - 4) : line))
        }
        out.append("")
        let n = selected.count, b = items.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        out.append("  " + (n > 0 ? A.paint("\(n) selected", A.bold) + A.paint(" · ", A.gray) + A.paint(Fmt.size(b), A.bold + A.amber) + A.paint(" can be freed", A.gray) : A.paint("\(items.count) items", A.gray)))
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        switch key {
        case .up, .char("k"): list.move(-1, count: items.count)
        case .down, .char("j"): list.move(1, count: items.count)
        case .space, .enter:
            guard items.indices.contains(list.cursor) else { break }
            let id = items[list.cursor].id
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            if key == .space { list.move(1, count: items.count) }
        case .char("a"): selected = Set(items.map(\.id))
        case .char("x"):
            var chosen = items.filter { selected.contains($0.id) }
            if chosen.isEmpty, items.indices.contains(list.cursor) { chosen = [items[list.cursor]] }
            guard !chosen.isEmpty else { break }
            ui.push(ConfirmScreen(mode: .removeWorkspaces, chosen: chosen, allowDanger: true, snapshot: false, done: { [weak self] in self?.selected = []; self?.reload(); self?.onChange() }))
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}

// MARK: - Confirm, progress, result

final class ConfirmScreen: Screen {
    var title: String { mode == .removeWorkspaces ? "Confirm removal" : "Confirm cleaning build folders" }
    var keys: [(String, String)] { [("y", "do it"), ("p", "permanent: \(permanent ? "on" : "off")")] + (mode == .removeWorkspaces && hasWorkspaces ? [("s", "snapshot: \(snapshot ? "on" : "off")")] : []) + [("esc", "cancel")] }
    private let mode: PlanMode
    private let plan: (targets: [Entry], skipped: [(String, String)])
    private var permanent = false
    private var snapshot: Bool
    private let done: () -> Void
    private let hasWorkspaces: Bool

    init(mode: PlanMode, chosen: [Entry], allowDanger: Bool, snapshot: Bool = true, done: @escaping () -> Void) {
        self.mode = mode
        self.snapshot = snapshot
        self.done = done
        hasWorkspaces = chosen.contains { $0.kind == .workspace }
        plan = Library.guardTargets(chosen, mode: mode, includeDanger: allowDanger, includeRunning: false)
    }

    private func bytes(_ e: Entry) -> Int64 { mode == .removeWorkspaces ? (e.size ?? 0) : e.artifactBytes }

    func render(_ w: Int, _ h: Int) -> [String] {
        let total = plan.targets.reduce(Int64(0)) { $0 + bytes($1) }
        var out = [""]
        if plan.targets.isEmpty {
            out.append("  " + A.paint("Nothing here can be removed right now.", A.bold))
        } else {
            out.append("  " + A.paint(mode == .removeWorkspaces ? "These will be removed" : "Build folders in these will be deleted", A.bold) + A.paint("   (\(plan.targets.count))", A.gray))
            out.append("")
            let room = max(3, h - 14 - plan.skipped.count)
            for e in plan.targets.prefix(room) {
                out.append("    " + Ansi.pad(Fmt.size(bytes(e)), 9, right: true) + "  " + A.paint(Ansi.pad(mode == .removeWorkspaces ? Library.statusText(e) : "\(e.artifacts.count) folders", 15), UI.statusStyle(e)) + " " + A.paint(e.repoName + "/", A.gray) + e.name)
            }
            if plan.targets.count > room { out.append("    " + A.paint("and \(plan.targets.count - room) more", A.gray)) }
            out.append("")
            out.append("    " + A.paint("Total", A.gray) + "  " + A.paint(Fmt.size(total), A.bold + A.amber))
        }
        if !plan.skipped.isEmpty {
            out.append("")
            out.append("  " + A.paint("Left alone", A.violet))
            for s in plan.skipped.prefix(6) { out.append("    " + A.paint(s.0 + "  " + s.1, A.gray)) }
        }
        out.append("")
        out.append("  " + A.paint(permanent ? "Files are deleted for good." : "Files move to the Trash.", permanent ? A.red : A.gray)
                   + (mode == .removeWorkspaces && snapshot && hasWorkspaces ? A.paint(" Unsaved work is saved to the vault first.", A.gray) : ""))
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        switch key {
        case .char("p"): permanent.toggle()
        case .char("s"): if mode == .removeWorkspaces { snapshot.toggle() }
        case .char("y"):
            guard !plan.targets.isEmpty else { break }
            run(ui)
        case .esc, .char("q"), .char("n"): ui.pop()
        default: break
        }
    }

    private func run(_ ui: TUI) {
        var options = CleanupOptions()
        options.permanent = permanent; options.vault = snapshot; options.deleteMergedBranches = true; options.includeDanger = true
        let screen = ProgressScreen()
        ui.pop(); ui.push(screen)
        var all = Library.entries()
        let outcome = Library.execute(mode, plan.targets, options: options, all: &all) { p in screen.progress = p; ui.draw() }
        ui.pop()
        ui.push(ResultScreen(mode: mode, outcome: outcome, count: plan.targets.count, onClose: done))
    }
}

final class ProgressScreen: Screen {
    var title: String { "Working" }
    var keys: [(String, String)] { [("ctrl-c", "stop after this item")] }
    var progress: Library.Progress?
    func render(_ w: Int, _ h: Int) -> [String] {
        guard let p = progress else { return ["", "  Starting…"] }
        let frac = p.total > 0 ? Double(p.freed) / Double(p.total) : 0
        let bw = min(60, w - 16)
        return ["", "  " + A.paint("Item \(p.index) of \(p.count)", A.gray) + "   " + A.paint(p.name, A.bold), "",
                "  " + Widget.bar(frac, width: bw, color: A.blue) + "  " + A.paint(String(format: "%.0f%%", frac * 100), A.bold), "",
                "  " + A.paint(Fmt.size(p.freed), A.bold + A.amber) + A.paint(" of \(Fmt.size(p.total))", A.gray), "",
                "  " + A.paint(p.detail.isEmpty ? "" : Fmt.tilde(p.detail), A.gray)]
    }
    func handle(_ key: Key, _ ui: TUI) {}
}

final class ResultScreen: Screen {
    var title: String { "Done" }
    var keys: [(String, String)] { [("any key", "continue")] }
    private let mode: PlanMode, outcome: Library.Outcome, count: Int, onClose: () -> Void
    init(mode: PlanMode, outcome: Library.Outcome, count: Int, onClose: @escaping () -> Void) { self.mode = mode; self.outcome = outcome; self.count = count; self.onClose = onClose }
    func render(_ w: Int, _ h: Int) -> [String] {
        var out = ["", "  " + A.paint("Freed ", A.gray) + A.paint(Fmt.size(outcome.freed), A.bold + A.amber),
                   "  " + A.paint(mode == .removeWorkspaces ? "by removing \(outcome.done.count) item\(outcome.done.count == 1 ? "" : "s")" : "from build folders in \(outcome.done.count) workspace\(outcome.done.count == 1 ? "" : "s")", A.gray)]
        if outcome.failures.isEmpty == false {
            out.append(""); out.append("  " + A.paint("Couldn't finish \(outcome.failures.count)", A.red))
            for f in outcome.failures.prefix(6) { out.append("    " + f.name + A.paint("  " + f.error, A.gray)) }
        }
        out.append(""); out.append("  " + A.paint("Free space is now " + Fmt.size(Tools.diskInfo().available), A.gray))
        return out
    }
    func handle(_ key: Key, _ ui: TUI) { ui.pop(); onClose() }
}
