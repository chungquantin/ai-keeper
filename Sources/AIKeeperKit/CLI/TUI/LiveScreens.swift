import Foundation

// MARK: - Agents (live)

final class AgentsScreen: Screen {
    var title: String { "Agents" }
    var tickInterval: Double { 2 }
    var keys: [(String, String)] {
        ask != nil ? [("y", "yes"), ("any other key", "no")] : [("↑↓", "move"), ("x", "stop"), ("m", showMCP ? "hide MCP servers" : "show MCP servers"), ("esc", "back")]
    }
    private var agents: [AgentProc] = []
    private var list = ListState()
    private var showMCP = false
    private var ask: (String, () -> Void)?

    init(preload: [AgentProc]? = nil) { agents = preload ?? Library.agents() }
    func tick(_ ui: TUI) { agents = Library.agents() }

    private var shown: [AgentProc] { agents.filter { showMCP || $0.kind != .mcp } }

    func render(_ w: Int, _ h: Int) -> [String] {
        let rows = shown
        list.clamp(count: rows.count, visible: max(3, h - 6))
        var out = [""]
        if rows.isEmpty { return out + ["  " + A.paint("No coding agents are running.", A.gray)] }
        out.append("  " + A.paint(Ansi.pad("", 3) + Ansi.pad("TOOL", 13) + Ansi.pad("STATE", 11) + Ansi.pad("CPU", 6, right: true) + Ansi.pad("MEMORY", 10, right: true) + Ansi.pad("COST", 9, right: true) + Ansi.pad("UP", 8, right: true) + "   TASK", A.gray))
        for i in 0..<min(max(3, h - 6), max(0, rows.count - list.offset)) {
            let idx = list.offset + i, a = rows[idx], cur = idx == list.cursor
            let (state, color): (String, String) = a.orphaned ? ("orphaned", A.red) : a.state == .working ? ("working", A.blue) : a.state == .needsInput ? ("needs you", A.violet) : a.state == .idle ? ("idle", A.gray) : ("running", A.gray)
            let task = a.title ?? a.cwd.map(Fmt.tilde) ?? ""
            let line = "  " + Ansi.pad(a.kind.rawValue, 13) + A.paint(Ansi.pad(state, 11), color) + Ansi.pad(String(format: "%.0f%%", a.cpu), 6, right: true)
                + Ansi.pad(Fmt.size(a.rssBytes), 10, right: true) + Ansi.pad(a.cost.map(Fmt.usd) ?? "", 9, right: true) + Ansi.pad(Fmt.duration(a.elapsed), 8, right: true) + "   " + A.paint(task, cur ? "" : A.gray)
            out.append("  " + (cur ? Widget.band(line, w - 4) : line))
        }
        out.append("")
        let needs = rows.filter { $0.state == .needsInput }.count
        out.append("  " + A.paint("\(rows.count) running", A.gray) + (needs > 0 ? A.paint("  ·  \(needs) waiting for you", A.violet) : ""))
        if let q = ask { out.append(""); out.append("  " + A.paint(q.0 + "  (y/n)", A.bold + A.amber)) }
        return out
    }

    private func stripEsc(_ s: String) -> String {
        var out = "", inEsc = false
        for c in s.unicodeScalars { if inEsc { if c == "m" { inEsc = false }; continue }; if c == "\u{1B}" { inEsc = true; continue }; out.unicodeScalars.append(c) }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        if let q = ask { ask = nil; if key == .char("y") { q.1() }; return }
        let rows = shown
        switch key {
        case .up, .char("k"): list.move(-1, count: rows.count)
        case .down, .char("j"): list.move(1, count: rows.count)
        case .char("m"): showMCP.toggle()
        case .char("x"):
            guard rows.indices.contains(list.cursor) else { break }
            let a = rows[list.cursor]
            ask = ("Stop \(a.kind.rawValue) (pid \(a.pid))" + (a.state == .working ? ", it is working right now" : "") + "?", { [weak self] in
                if kill(a.pid, SIGTERM) == 0 { ui.flash("Stopped \(a.kind.rawValue) (pid \(a.pid))") } else { ui.flash("Couldn't stop it: \(String(cString: strerror(errno)))") }
                self?.agents = Library.agents()
            })
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}

// MARK: - System (live)

final class SystemScreen: Screen {
    var title: String { "System" }
    var tickInterval: Double { 1 }
    var keys: [(String, String)] { [("esc", "back")] }
    private let sampler = SystemSampler()
    private var snap = SystemSnapshot()
    private var groups: [ProcGroup] = []
    private var machine = MachineInfo.read()
    private var cpuHistory: [Double] = []
    private var ticks = 0

    init(frozen: (SystemSnapshot, [ProcGroup])? = nil) {
        if let f = frozen { snap = f.0; groups = f.1; cpuHistory = Array(repeating: f.0.cpuTotal, count: 30) }
        else { _ = sampler.sample(); Thread.sleep(forTimeInterval: 1); snap = sampler.sample(); groups = Procs.scan().groups; cpuHistory = [snap.cpuTotal] }
    }

    func tick(_ ui: TUI) {
        snap = sampler.sample()
        cpuHistory.append(snap.cpuTotal); if cpuHistory.count > 40 { cpuHistory.removeFirst() }
        ticks += 1
        if ticks % 3 == 0 { groups = Procs.scan().groups }
    }

    func render(_ w: Int, _ h: Int) -> [String] {
        let bw = min(34, w - 50)
        func gauge(_ name: String, _ f: Double, _ detail: String, warn: Double = 0.85) -> String {
            "  " + UI.label(name) + Widget.bar(f, width: bw, color: f >= warn ? A.red : A.blue) + "  " + Ansi.pad(String(format: "%.0f%%", f * 100), 5, right: true) + A.paint("  " + detail, A.gray)
        }
        let health = Health.evaluate(snap, topCPU: groups.max { $0.cpu < $1.cpu }.map { "\($0.name) (\(Int($0.cpu))%)" }, topMemory: groups.first.map { "\($0.name) (\(Fmt.size($0.rss)))" })
        var out = ["", "  " + A.paint("\(machine.model) · \(machine.chip) · \(machine.cores) cores · \(Fmt.size(machine.memory)) · up \(Fmt.duration(machine.uptime))", A.gray), ""]
        out.append("  " + UI.label("Health") + A.paint("\(health.score)", A.bold + (health.score >= 80 ? A.blue : health.score >= 60 ? A.violet : A.red)) + "  " + health.reason)
        for t in health.tips.prefix(2) { out.append("  " + String(repeating: " ", count: 13) + A.paint("· " + t.text, A.violet)) }
        out.append("")
        out.append(gauge("CPU", snap.cpuTotal, "load " + String(format: "%.1f %.1f %.1f", snap.load.0, snap.load.1, snap.load.2)))
        out.append("  " + String(repeating: " ", count: 13) + A.paint(Widget.spark(cpuHistory), A.blue))
        out.append(gauge("Memory", snap.memFraction, "\(Fmt.size(snap.memUsed)) of \(Fmt.size(snap.memTotal))"))
        out.append(gauge("Swap", snap.swapFraction, "\(Fmt.size(snap.swapUsed)) of \(Fmt.size(snap.swapTotal))", warn: 0.7))
        out.append(gauge("Disk", snap.diskTotal > 0 ? Double(snap.diskUsed) / Double(snap.diskTotal) : 0, "\(Fmt.size(snap.diskTotal - snap.diskUsed)) free", warn: 0.92))
        out.append("  " + UI.label("Disk I/O") + A.paint("read ", A.gray) + Fmt.size(Int64(snap.readBps)) + A.paint("/s   write ", A.gray) + Fmt.size(Int64(snap.writeBps)) + "/s")
        out.append("  " + UI.label("Network") + A.paint("↓ ", A.gray) + Fmt.size(Int64(snap.netDown)) + A.paint("/s   ↑ ", A.gray) + Fmt.size(Int64(snap.netUp)) + "/s")
        if let b = snap.battery { out.append("  " + UI.label("Battery") + "\(Int(b.level * 100))%" + A.paint(b.charging ? "  charging" : b.onAC ? "  on power" : "  on battery", A.gray)) }
        out.append("")
        out.append("  " + A.paint(Ansi.pad("MEMORY", 10, right: true) + Ansi.pad("CPU", 6, right: true) + Ansi.pad("PROCS", 7, right: true) + "   APP", A.gray))
        for g in groups.prefix(max(3, h - out.count - 3)) {
            out.append("  " + Ansi.pad(Fmt.size(g.rss), 10, right: true) + Ansi.pad("\(Int(g.cpu))%", 6, right: true) + A.paint(Ansi.pad("\(g.pids.count)", 7, right: true), A.gray) + "   " + g.name + (g.dev ? A.paint("  dev", A.sky) : ""))
        }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) { if key == .esc || key == .char("q") { ui.pop() } }
}

// MARK: - Usage

final class UsageScreen: Screen {
    var title: String { "AI usage" }
    var keys: [(String, String)] { [("1 2 3", "7, 14 or 30 days"), ("tab", "group by \(["tool", "model", "project"][by])"), ("esc", "back")] }
    private var data: UsageData
    private var days = 14
    private var by = 0

    init(data: UsageData? = nil) { self.data = data ?? StatusCommands.usageData() }

    func render(_ w: Int, _ h: Int) -> [String] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: .now))!
        let rows = data.rows.filter { $0.day >= start }
        var perDay: [Double] = []
        for i in 0..<days { let d = cal.date(byAdding: .day, value: i, to: start)!; perDay.append(rows.filter { cal.isDate($0.day, inSameDayAs: d) }.reduce(0) { $0 + $1.cost }) }
        let total = perDay.reduce(0, +), tokens = rows.reduce(0) { $0 + $1.tokens }
        var out = ["", "  " + A.paint(Fmt.usd(total), A.bold) + A.paint("  in the last \(days) days  ·  \(String(format: "%.1fM", Double(tokens) / 1e6)) tokens  ·  estimated at API list prices", A.gray), ""]
        let (today, week) = StatusCommands.spend(data)
        let daily = UserDefaults.standard.number("budget.daily", default: 0), weekly = UserDefaults.standard.number("budget.weekly", default: 0)
        out.append("  " + UI.label("Today") + Fmt.usd(today) + (daily > 0 ? A.paint("  of \(Fmt.usd(daily))  ", A.gray) + Widget.bar(today / daily, width: 16, color: today >= daily ? A.red : A.blue) : ""))
        out.append("  " + UI.label("This week") + Fmt.usd(week) + (weekly > 0 ? A.paint("  of \(Fmt.usd(weekly))  ", A.gray) + Widget.bar(week / weekly, width: 16, color: week >= weekly ? A.red : A.blue) : ""))
        out.append("")
        out.append("  " + A.paint("Per day", A.gray))
        let barRows = 5, mx = max(perDay.max() ?? 1, 0.01), cols = Array(perDay.enumerated())
        for r in stride(from: barRows - 1, through: 0, by: -1) {
            out.append("  " + (r == barRows - 1 ? A.paint(Ansi.pad(Fmt.usd(mx), 8, right: true), A.gray) : String(repeating: " ", count: 8)) + "  " + cols.map { _, v in
                let level = v / mx * Double(barRows), cell = level - Double(r)
                return cell >= 1 ? A.paint("██ ", A.blue) : cell > 0 ? A.paint(String(Array("▁▂▃▄▅▆▇")[min(6, Int(cell * 7))]) + String(Array("▁▂▃▄▅▆▇")[min(6, Int(cell * 7))]) + " ", A.blue) : "   "
            }.joined())
        }
        let fmt = DateFormatter(); fmt.dateFormat = "d"
        out.append(String(repeating: " ", count: 10) + (0..<days).map { Ansi.pad(fmt.string(from: cal.date(byAdding: .day, value: $0, to: start)!), 3) }.joined().prefix(w - 12))
        out.append("")
        var groups: [String: Double] = [:]
        for r in rows { groups[[r.agent.rawValue, r.model, r.project.isEmpty ? "(none)" : r.project][by], default: 0] += r.cost }
        let ordered = groups.sorted { $0.value > $1.value }.prefix(max(3, h - out.count - 3))
        let mxg = ordered.first?.value ?? 1
        for (k, v) in ordered {
            out.append("  " + Ansi.pad(Fmt.usd(v), 9, right: true) + "  " + Widget.bar(v / mxg, width: 18, color: A.blue) + "  " + Ansi.pad(total > 0 ? Fmt.pct(v / total) : "", 5, right: true) + "  " + k)
        }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        switch key {
        case .char("1"): days = 7
        case .char("2"): days = 14
        case .char("3"): days = 30
        case .tab, .char("g"): by = (by + 1) % 3
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}

// MARK: - Disk map and explorer

final class DiskScreen: Screen {
    var title: String { "Disk map" }
    var keys: [(String, String)] { [("↑↓", "move"), ("enter", "explore"), ("c", "clear safe folder"), ("r", "re-measure"), ("esc", "back")] }
    private var map: StorageMapResult?
    private var measured: Date?
    private var list = ListState()
    private let colors = [A.blue, A.violet, A.sky, A.gray, A.fg(70, 90, 190, 61)]

    init(preload: (StorageMapResult, Date)? = nil) {
        if let p = preload { map = p.0; measured = p.1; return }
        let url = Persist.dir.appendingPathComponent("map.json")
        map = Persist.load(StorageMapResult.self, "map.json")
        measured = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    func render(_ w: Int, _ h: Int) -> [String] {
        guard let m = map else { return ["", "  " + A.paint("The disk has not been measured yet. Press r (it reads your whole home folder, so it takes a minute or two).", A.gray)] }
        let d = Tools.diskInfo()
        var out = ["", "  " + A.paint(Fmt.size(d.used), A.bold) + A.paint(" used  ·  \(Fmt.size(d.available)) free  ·  measured \(Fmt.ago(measured))", A.gray), ""]
        let bw = min(w - 6, 100)
        out.append("  " + A.paint(Widget.segments(m.groups.enumerated().map { (Double($1.size), "") }, width: bw), A.blue))
        out.append("")
        let total = max(1, m.groups.reduce(Int64(0)) { $0 + $1.size })
        for (i, g) in m.groups.enumerated() {
            out.append("  " + Widget.texture(i) + Widget.texture(i) + " " + Ansi.pad(g.name, 14) + Ansi.pad(Fmt.size(g.size), 9, right: true) + A.paint(Ansi.pad(Fmt.pct(Double(g.size) / Double(total)), 6, right: true) + "   " + g.detail, A.gray))
        }
        out.append("")
        out.append("  " + A.paint("Biggest folders", A.bold))
        let rows = m.hotspots, vis = max(3, h - out.count - 4)
        list.clamp(count: rows.count, visible: vis)
        for i in 0..<min(vis, max(0, rows.count - list.offset)) {
            let idx = list.offset + i, hs = rows[idx], cur = idx == list.cursor
            let line = "  " + Ansi.pad(Fmt.size(hs.size), 9, right: true) + "  " + A.paint(Ansi.pad(hs.cleanable ? "safe" : "", 6), A.blue) + Fmt.tilde(hs.path) + A.paint(hs.hint.map { "  \($0)" } ?? "", A.gray)
            out.append("  " + (cur ? Widget.band(line, w - 4) : line))
        }
        return out
    }

    private func strip(_ s: String) -> String {
        var out = "", inEsc = false
        for c in s.unicodeScalars { if inEsc { if c == "m" { inEsc = false }; continue }; if c == "\u{1B}" { inEsc = true; continue }; out.unicodeScalars.append(c) }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        let rows = map?.hotspots ?? []
        switch key {
        case .up, .char("k"): list.move(-1, count: rows.count)
        case .down, .char("j"): list.move(1, count: rows.count)
        case .enter, .right: if rows.indices.contains(list.cursor) { ui.push(ExploreScreen(path: rows[list.cursor].path)) }
        case .char("c"):
            guard rows.indices.contains(list.cursor) else { break }
            let hs = rows[list.cursor]
            guard hs.cleanable || DiskModel.cleanable[(hs.path as NSString).lastPathComponent] != nil else { ui.flash("That folder is not one I know is safe to clear. Press enter to look inside."); break }
            var e = Entry(id: "hs:" + hs.path, kind: .cache, name: (hs.path as NSString).lastPathComponent, path: hs.path, repoPath: nil, repoName: "", branch: nil, sources: [.dev], note: hs.hint ?? "")
            e.size = hs.size; e.measured = true; e.verdict = .deprecated
            ui.push(ConfirmScreen(mode: .removeWorkspaces, chosen: [e], allowDanger: true, snapshot: false, done: {}))
        case .char("r"):
            Out.statusHook = { ui.flash($0, seconds: 300); ui.draw() }
            Out.status("Measuring your home folder… this can take a minute or two")
            let r = StorageMapper.scan(used: Tools.diskInfo().used)
            Out.statusHook = nil
            Persist.save(r, "map.json"); map = r; measured = .now; ui.flash("Measured")
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}

final class ExploreScreen: Screen {
    var title: String { "Explore  ›  " + Fmt.tilde(path) }
    var tickInterval: Double { measuring ? 0.4 : 0 }
    var keys: [(String, String)] { [("↑↓", "move"), ("enter", "open folder"), ("←", "up"), ("esc", "back")] }
    private var path: String
    private var nodes: [DiskNode] = []
    private var list = ListState()
    private var measuring = false
    private let lock = NSLock()
    private var generation = 0

    init(path: String) { self.path = path; load() }

    private func load() {
        generation += 1
        let g = generation
        nodes = DiskModel.list(path).sorted { $0.name.lowercased() < $1.name.lowercased() }
        list = ListState(); measuring = true
        let dirs = nodes.indices.filter { nodes[$0].size == nil }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .utility
        var pending = dirs.count
        if pending == 0 { measuring = false }
        for i in dirs {
            let p = nodes[i].path
            queue.addOperation { [weak self] in
                let s = Shell.du(p)
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard g == self.generation, let idx = self.nodes.firstIndex(where: { $0.path == p }) else { return }
                self.nodes[idx].size = s; pending -= 1
                if pending == 0 { self.measuring = false }
            }
        }
    }

    func tick(_ ui: TUI) {}

    func render(_ w: Int, _ h: Int) -> [String] {
        lock.lock(); let items = nodes.sorted { ($0.size ?? -1) > ($1.size ?? -1) }; lock.unlock()
        let vis = max(3, h - 5)
        list.clamp(count: items.count, visible: vis)
        let mx = Double(max(items.compactMap(\.size).max() ?? 1, 1))
        var out = ["", "  " + A.paint(measuring ? "Measuring…" : "\(items.count) items · \(Fmt.size(items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }))", A.gray), ""]
        for i in 0..<min(vis, max(0, items.count - list.offset)) {
            let idx = list.offset + i, n = items[idx], cur = idx == list.cursor
            let size = n.size.map { Fmt.size($0) } ?? "…"
            let line = "  " + Ansi.pad(size, 9, right: true) + "  " + Widget.bar(Double(n.size ?? 0) / mx, width: 14, color: n.hint != nil ? A.amber : A.blue) + "  " + (n.isDir ? A.paint(n.name + "/", cur ? A.bold : "") : n.name) + A.paint(n.hint.map { "   \($0)" } ?? "", A.gray)
            out.append("  " + (cur ? Widget.band(line, w - 4) : line))
        }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        lock.lock(); let items = nodes.sorted { ($0.size ?? -1) > ($1.size ?? -1) }; lock.unlock()
        switch key {
        case .up, .char("k"): list.move(-1, count: items.count)
        case .down, .char("j"): list.move(1, count: items.count)
        case .enter, .right: if items.indices.contains(list.cursor), items[list.cursor].isDir { path = items[list.cursor].path; load() }
        case .left, .backspace:
            let parent = (path as NSString).deletingLastPathComponent
            if parent.count >= home.count - 1, parent != path { path = parent; load() } else { ui.pop() }
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }
}

// MARK: - Vault

final class VaultScreen: Screen {
    var title: String { "Recently removed" }
    var keys: [(String, String)] { ask != nil ? [("y", "yes"), ("any other key", "no")] : [("↑↓", "move"), ("enter", "restore"), ("d", "delete"), ("esc", "back")] }
    private var items: [VaultItem] = []
    private var list = ListState()
    private var ask: (String, () -> Void)?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void = {}, preload: [VaultItem]? = nil) { self.onChange = onChange; items = preload ?? Vault.list() }

    func render(_ w: Int, _ h: Int) -> [String] {
        var out = ["", "  " + A.paint("Before a workspace with unsaved work is removed, its commits, changes and untracked files are saved here.", A.gray), ""]
        if items.isEmpty { out.append("  " + A.paint("Nothing saved. Snapshots appear here after you remove a workspace that had unsaved work.", A.gray)); return out }
        let vis = max(3, h - 8)
        list.clamp(count: items.count, visible: vis)
        for i in 0..<min(vis, max(0, items.count - list.offset)) {
            let idx = list.offset + i, v = items[idx], cur = idx == list.cursor
            let holds = [v.hasBundle ? "commits" : nil, v.hasPatch ? "changes" : nil, v.hasUntracked ? "untracked" : nil].compactMap { $0 }.joined(separator: ", ")
            let row = "  " + A.paint(Ansi.pad(Fmt.ago(v.date), 12), A.gray) + Ansi.pad(Fmt.size(v.bytes), 9, right: true) + "  " + A.paint(Ansi.pad(holds, 28), A.gray) + (cur ? A.paint(v.name, A.bold) : v.name)
            out.append(cur ? Widget.band(row, w - 2) : row)
        }
        if let q = ask { out.append(""); out.append("  " + A.paint(q.0 + "  (y/n)", A.bold + A.amber)) }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) {
        if let q = ask { ask = nil; if key == .char("y") { q.1() }; return }
        switch key {
        case .up, .char("k"): list.move(-1, count: items.count)
        case .down, .char("j"): list.move(1, count: items.count)
        case .enter, .char("r"):
            guard items.indices.contains(list.cursor) else { break }
            let v = items[list.cursor]
            ask = ("Restore \(v.name) to \(Fmt.tilde(v.path))?", { [weak self] in
                do { try Vault.restore(v); ui.flash("Restored \(v.name)") } catch { ui.flash(error.localizedDescription) }
                self?.reload()
            })
        case .char("d"):
            guard items.indices.contains(list.cursor) else { break }
            let v = items[list.cursor]
            ask = ("Delete the snapshot of \(v.name) for good?", { [weak self] in Vault.delete(v); ui.flash("Deleted"); self?.reload() })
        case .char("q"), .esc: ui.pop()
        default: break
        }
    }

    private func reload() { items = Vault.list(); onChange() }
}

// MARK: - History

/// A year of cleanups as a contribution chart, with the running total of space given back.
final class HistoryScreen: Screen {
    var title: String { "History" }
    var keys: [(String, String)] { [("esc", "back")] }
    private let s = CleanLog.summary(CleanLog.all())

    func render(_ w: Int, _ h: Int) -> [String] {
        guard s.runs > 0 else {
            return ["", "  " + A.paint("Nothing cleaned yet.", A.bold), "  " + A.paint("Each day you remove something gets a square here. Start from Workspaces.", A.gray)]
        }
        let parts = Fmt.size(s.totalBytes).split(separator: " ").map(String.init)
        var out = [""]
        for (i, row) in Widget.bigNumber(parts[0]).enumerated() {
            out.append("   " + A.paint(row, A.amber) + (i == 1 ? "  " + A.paint(parts.count > 1 ? parts[1] : "", A.bold) : i == 2 ? "  " + A.paint("freed" + (s.first.map { " since " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""), A.gray) : ""))
        }
        out.append("")
        let paint: (String, Int) -> String = { t, lv in lv == 0 ? A.paint(t, A.gray) : A.paint(t, lv == 4 ? A.bold + A.amber : A.amber) }
        let dim: (String) -> String = { A.paint($0, A.gray) }
        for l in HistoryCommands.grid(s, weeks: HistoryCommands.weekCount(width: w - 4), paint: paint, dim: dim) { out.append("  " + l) }
        out.append("")
        out.append("      " + HistoryCommands.legend(paint: paint, dim: dim))
        out.append("")
        func stat(_ k: String, _ v: String) { out.append("  " + UI.label(k) + v) }
        stat("Cleanups", "\(s.runs) on \(HistoryCommands.days(s.activeDays))")
        stat("Streak", "\(HistoryCommands.days(s.currentStreak)) now, \(HistoryCommands.days(s.longestStreak)) longest")
        if let b = s.best { stat("Best day", Fmt.size(b.bytes) + A.paint("  " + b.day.formatted(.dateTime.month(.abbreviated).day().year()), A.gray)) }
        return out
    }

    func handle(_ key: Key, _ ui: TUI) { if key == .esc || key == .char("q") { ui.pop() } }
}
