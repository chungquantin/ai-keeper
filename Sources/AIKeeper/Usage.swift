import Charts
import SwiftUI

enum AgentTool: String, CaseIterable, Codable {
    case claude = "Claude", codex = "Codex", pi = "Pi"
    var toolID: String { rawValue.lowercased() }
    static var enabled: [AgentTool] { allCases.filter { ToolSettings.enabled($0.toolID) } }
}

struct UsageRow: Codable {
    let agent: AgentTool
    let day: Date
    let model: String
    let project: String
    let session: String
    let input: Int        // uncached prompt tokens
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    var costOverride: Double? = nil   // Pi reports its own cost per message

    var family: String {
        let m = model.lowercased()
        if agent == .codex { return "Codex" }
        if agent == .pi { return "Pi" }
        for f in ["opus", "sonnet", "haiku", "fable"] where m.contains(f) { return f.capitalized }
        return "Other"
    }
    var tokens: Int { input + output + cacheRead + cacheWrite }

    /// Estimated at public API list prices ($/MTok). Cache read = 0.1x input, cache write = 1.25x (Claude).
    var cost: Double {
        if let c = costOverride { return c }
        let (i, o): (Double, Double) = switch family {
        case "Haiku": (1, 5)
        case "Sonnet": (3, 15)
        case "Codex": (1.25, 10)
        default: (5, 25)
        }
        let write = agent == .claude ? 1.25 : 0
        return (Double(input) * i + Double(output) * o + Double(cacheRead) * i * 0.1 + Double(cacheWrite) * i * write) / 1e6
    }
}

struct SessionInfo: Identifiable, Hashable, Codable {
    var id: String { file }
    let file: String
    let sessionID: String
    let agent: AgentTool
    let title: String
    let cwd: String
    let project: String
    let first: Date
    let last: Date
    let cost: Double
    let tokens: Int
    let bytes: Int64
    var cwdExists: Bool { FileManager.default.fileExists(atPath: cwd) }
}

struct CodexLimits: Codable {
    let primaryPct: Double, primaryResets: Date
    let weeklyPct: Double, weeklyResets: Date
}

struct UsageData: Codable {
    var rows: [UsageRow] = []
    var sessions: [SessionInfo] = []
    var codex: CodexLimits?
}

enum UsageParser {
    private struct Line: Decodable {
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let message: Msg?
        struct Msg: Decodable { let id: String?; let model: String?; let usage: Usage? }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
    }

    struct FileResult {
        var items: [(id: String, row: UsageRow)] = []
        var title = ""
        var cwd = ""
        var sessionID = ""
        var first = Date.distantFuture
        var last = Date.distantPast
    }

    /// Parsed results keyed by file path, valid while size and modification time are unchanged.
    /// A reload then only re-reads the few session logs that are still being written.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var claudeCache: [String: (sig: String, r: FileResult)] = [:]
    private nonisolated(unsafe) static var codexCache: [String: (sig: String, v: ([UsageRow], SessionInfo?, (Date, CodexLimits)?))] = [:]
    private nonisolated(unsafe) static var piCache: [String: (sig: String, v: ([UsageRow], SessionInfo?))] = [:]

    // The caches above also live on disk, so a relaunch re-reads only the logs that changed. Parsing all of a busy
    // machine's session logs from scratch takes seconds of CPU, and it used to happen at every launch.
    private struct DiskCache: Codable {
        struct Item: Codable { var id: String; var row: UsageRow }
        struct C: Codable { var sig: String; var items: [Item]; var title: String; var cwd: String; var sessionID: String; var first: Date; var last: Date }
        struct X: Codable { var sig: String; var rows: [UsageRow]; var info: SessionInfo?; var limDate: Date?; var lim: CodexLimits? }
        var claude: [String: C] = [:]
        var codex: [String: X] = [:]
        var pi: [String: X] = [:]
    }
    private nonisolated(unsafe) static var diskRestored = false
    private nonisolated(unsafe) static var cacheDirty = false

    private static func restoreDiskCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard !diskRestored else { return }
        diskRestored = true
        guard let d = Persist.load(DiskCache.self, "usage-files.json") else { return }
        for (k, c) in d.claude {
            claudeCache[k] = (c.sig, FileResult(items: c.items.map { ($0.id, $0.row) }, title: c.title, cwd: c.cwd, sessionID: c.sessionID, first: c.first, last: c.last))
        }
        for (k, x) in d.codex { codexCache[k] = (x.sig, (x.rows, x.info, x.limDate.flatMap { dt in x.lim.map { (dt, $0) } })) }
        for (k, x) in d.pi { piCache[k] = (x.sig, (x.rows, x.info)) }
    }

    /// Logs that were deleted or rotated away must not stay in memory and on disk forever.
    private static func pruneCaches(claude: Set<String>?, codex: Set<String>?, pi: Set<String>?) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let claude, claudeCache.keys.contains(where: { !claude.contains($0) }) { claudeCache = claudeCache.filter { claude.contains($0.key) }; cacheDirty = true }
        if let codex, codexCache.keys.contains(where: { !codex.contains($0) }) { codexCache = codexCache.filter { codex.contains($0.key) }; cacheDirty = true }
        if let pi, piCache.keys.contains(where: { !pi.contains($0) }) { piCache = piCache.filter { pi.contains($0.key) }; cacheDirty = true }
    }

    private nonisolated(unsafe) static var lastDiskSave = Date.distantPast

    private static func saveDiskCache() {
        cacheLock.lock()
        // A live session log changes every few seconds, and the cache is several MB of JSON: write it at most every 10 minutes.
        guard cacheDirty, Date().timeIntervalSince(lastDiskSave) > 600 else { cacheLock.unlock(); return }
        cacheDirty = false
        lastDiskSave = Date()
        var d = DiskCache()
        for (k, v) in claudeCache {
            d.claude[k] = .init(sig: v.sig, items: v.r.items.map { .init(id: $0.id, row: $0.row) }, title: v.r.title, cwd: v.r.cwd, sessionID: v.r.sessionID, first: v.r.first, last: v.r.last)
        }
        for (k, v) in codexCache { d.codex[k] = .init(sig: v.sig, rows: v.v.0, info: v.v.1, limDate: v.v.2?.0, lim: v.v.2?.1) }
        for (k, v) in piCache { d.pi[k] = .init(sig: v.sig, rows: v.v.0, info: v.v.1) }
        cacheLock.unlock()
        Persist.save(d, "usage-files.json")
    }

    private static func signature(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v?.fileSize ?? 0)"
    }

    private static func cached<T>(_ url: URL, _ store: inout [String: (sig: String, v: T)], parse: () -> T) -> T {
        let sig = signature(url)
        cacheLock.lock(); let hit = store[url.path]; cacheLock.unlock()
        if let hit, hit.sig == sig { return hit.v }
        let v = parse()
        cacheLock.lock(); store[url.path] = (sig, v); cacheDirty = true; cacheLock.unlock()
        return v
    }

    static func load() -> UsageData {
        restoreDiskCache()
        defer { saveDiskCache() }
        var out = UsageData()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Claude: one API message is logged once per content block, so dedupe by message id across files.
        var byID: [String: (row: UsageRow, file: Int)] = [:]
        var files: [(url: URL, r: FileResult)] = []
        var liveClaude: Set<String>?, liveCodex: Set<String>?, livePi: Set<String>?   // nil: that tool wasn't scanned, keep its cache
        if ToolSettings.enabled("claude"), let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: "\(home)/.claude/projects"), includingPropertiesForKeys: nil) {
            liveClaude = []
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                liveClaude?.insert(url.path)
                let sig = signature(url)
                cacheLock.lock(); let hit = claudeCache[url.path]; cacheLock.unlock()
                let r: FileResult
                if let hit, hit.sig == sig { r = hit.r } else {
                    r = parseClaude(url, iso: iso)
                    cacheLock.lock(); claudeCache[url.path] = (sig, r); cacheDirty = true; cacheLock.unlock()
                }
                files.append((url, r))
                for (id, row) in r.items {
                    if let old = byID[id]?.row, old.output >= row.output { continue }
                    byID[id] = (row, files.count - 1)
                }
            }
        }
        out.rows = byID.values.map(\.row)
        var perFile: [Int: (cost: Double, tokens: Int)] = [:]
        for (_, v) in byID { perFile[v.file, default: (0, 0)].cost += v.row.cost; perFile[v.file, default: (0, 0)].tokens += v.row.tokens }
        for (i, f) in files.enumerated() where f.r.first != .distantFuture {
            let size = ((try? FileManager.default.attributesOfItem(atPath: f.url.path)[.size]) as? Int64) ?? 0
            out.sessions.append(SessionInfo(
                file: f.url.path, sessionID: f.r.sessionID.isEmpty ? f.url.deletingPathExtension().lastPathComponent : f.r.sessionID,
                agent: .claude, title: f.r.title.isEmpty ? "Untitled session" : f.r.title, cwd: f.r.cwd,
                project: project(from: f.r.cwd), first: f.r.first, last: f.r.last,
                cost: perFile[i]?.cost ?? 0, tokens: perFile[i]?.tokens ?? 0, bytes: size))
        }

        // Codex
        var newest: (Date, CodexLimits)?
        if ToolSettings.enabled("codex"), let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: "\(home)/.codex/sessions"), includingPropertiesForKeys: nil) {
            liveCodex = []
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                liveCodex?.insert(url.path)
                let (rows, info, lim) = cached(url, &codexCache) { parseCodex(url, iso: iso) }
                out.rows += rows
                if let info { out.sessions.append(info) }
                if let lim, newest == nil || lim.0 > newest!.0 { newest = lim }
            }
        }
        if ToolSettings.enabled("pi"), let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: "\(home)/.pi/agent/sessions"), includingPropertiesForKeys: nil) {
            livePi = []
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                livePi?.insert(url.path)
                let (rows, info) = cached(url, &piCache) { parsePi(url) }
                out.rows += rows
                if let info { out.sessions.append(info) }
            }
        }
        pruneCaches(claude: liveClaude, codex: liveCodex, pi: livePi)
        if let n = newest, n.1.primaryResets > .now || n.1.weeklyResets > .now { out.codex = n.1 }
        return out
    }

    /// Cost, title and activity for a single Claude session file (used for live agent rows).
    static func parseClaude(_ url: URL, iso: ISO8601DateFormatter) -> FileResult {
        var r = FileResult()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return r }
        let needle = Array("\"usage\"".utf8), userNeedle = Array("\"type\":\"user\"".utf8)
        let decoder = JSONDecoder()
        var local: [String: UsageRow] = [:]
        Lines.each(data) { line in
            if r.title.isEmpty, Lines.contains(line, userNeedle), let t = userTitle(Data(line)) { r.title = t }
            guard Lines.contains(line, needle), let l = try? decoder.decode(Line.self, from: Data(line)),
                  let m = l.message, let u = m.usage, let id = m.id, let model = m.model, model != "<synthetic>",
                  let ts = l.timestamp, let date = FastDate.parse(ts) else { return }
            if r.cwd.isEmpty, let c = l.cwd { r.cwd = c }
            if r.sessionID.isEmpty, let s = l.sessionId { r.sessionID = s }
            r.first = min(r.first, date); r.last = max(r.last, date)
            let row = UsageRow(agent: .claude, day: Calendar.current.startOfDay(for: date), model: model, project: project(from: l.cwd ?? r.cwd),
                               session: l.sessionId ?? url.lastPathComponent, input: u.input_tokens ?? 0, output: u.output_tokens ?? 0,
                               cacheRead: u.cache_read_input_tokens ?? 0, cacheWrite: u.cache_creation_input_tokens ?? 0)
            if let old = local[id], old.output >= row.output { return }
            local[id] = row
        }
        r.items = local.map { ($0.key, $0.value) }
        return r
    }

    private static func userTitle(_ line: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], o["type"] as? String == "user",
              let msg = o["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String { text = s }
        else if let arr = msg["content"] as? [[String: Any]] { text = arr.first { $0["type"] as? String == "text" }?["text"] as? String }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[Request") else { return nil }
        return cleanTitle(&t)
    }

    /// Skill/slash-command expansions bury the real request after `ARGUMENTS:`; pasted images lead with `[Image: …]`.
    static func cleanTitle(_ t: inout String) -> String? {
        if let r = t.range(of: "ARGUMENTS:") { t = String(t[r.upperBound...]) }
        else if t.hasPrefix("Base directory for this skill") { return nil }
        while t.hasPrefix("[Image"), let end = t.firstIndex(of: "]") { t = String(t[t.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        t = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(100))
    }

    static func parseCodex(_ url: URL, iso: ISO8601DateFormatter) -> ([UsageRow], SessionInfo?, (Date, CodexLimits)?) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return ([], nil, nil) }
        var cwd = "", sid = "", model = "gpt-5", title = ""
        var prev = (inp: 0, cached: 0, out: 0)
        var perDay: [Date: (inp: Int, cached: Int, out: Int)] = [:]
        var first = Date.distantFuture, last = Date.distantPast
        var limits: (Date, CodexLimits)?
        let tc = Array("\"token_count\"".utf8), tctx = Array("\"turn_context\"".utf8), meta = Array("\"session_meta\"".utf8), user = Array("\"role\":\"user\"".utf8)
        var dayCache: [Int: Date] = [:]   // startOfDay per calendar day; Calendar is slow to call per line
        func startOfDay(_ d: Date) -> Date {
            let k = Int(d.timeIntervalSince1970 / 3600)
            if let hit = dayCache[k], Calendar.current.isDate(hit, inSameDayAs: d) { return hit }
            let v = Calendar.current.startOfDay(for: d); dayCache[k] = v; return v
        }

        Lines.each(data) { line in
            let isTC = Lines.contains(line, tc)
            let isMeta = cwd.isEmpty && Lines.contains(line, meta)
            let isCtx = Lines.contains(line, tctx)
            let isUser = title.isEmpty && Lines.contains(line, user)
            guard isTC || isMeta || isCtx || isUser,
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { return }
            let date = (o["timestamp"] as? String).flatMap { FastDate.parse($0) }
            if isMeta { cwd = p["cwd"] as? String ?? ""; sid = p["id"] as? String ?? "" }
            if isCtx, let m = p["model"] as? String { model = m }
            if isUser, p["type"] as? String == "message", p["role"] as? String == "user",
               let arr = p["content"] as? [[String: Any]], var t = arr.first?["text"] as? String {
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.hasPrefix("<"), !t.hasPrefix("#"), !t.isEmpty { title = String(t.replacingOccurrences(of: "\n", with: " ").prefix(100)) }
            }
            guard isTC, p["type"] as? String == "token_count", let d = date else { return }
            first = min(first, d); last = max(last, d)
            if let info = p["info"] as? [String: Any], let tot = info["total_token_usage"] as? [String: Any] {
                let cur = (inp: tot["input_tokens"] as? Int ?? 0, cached: tot["cached_input_tokens"] as? Int ?? 0, out: tot["output_tokens"] as? Int ?? 0)
                if cur.inp >= prev.inp {
                    let day = startOfDay(d)
                    var acc = perDay[day] ?? (0, 0, 0)
                    acc.inp += cur.inp - prev.inp; acc.cached += cur.cached - prev.cached; acc.out += cur.out - prev.out
                    perDay[day] = acc
                    prev = cur
                }
            }
            if let rl = p["rate_limits"] as? [String: Any], let pr = rl["primary"] as? [String: Any], let se = rl["secondary"] as? [String: Any],
               let pp = pr["used_percent"] as? Double, let sp = se["used_percent"] as? Double,
               let pre = pr["resets_at"] as? Double, let sre = se["resets_at"] as? Double, limits == nil || d > limits!.0 {
                limits = (d, CodexLimits(primaryPct: pp, primaryResets: Date(timeIntervalSince1970: pre), weeklyPct: sp, weeklyResets: Date(timeIntervalSince1970: sre)))
            }
        }
        guard first != .distantFuture else { return ([], nil, limits) }
        let proj = project(from: cwd)
        let rows = perDay.map { day, a in
            UsageRow(agent: .codex, day: day, model: model, project: proj, session: sid, input: max(0, a.inp - a.cached),
                     output: a.out, cacheRead: a.cached, cacheWrite: 0)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
        let info = SessionInfo(file: url.path, sessionID: sid, agent: .codex, title: title.isEmpty ? "Codex session" : title, cwd: cwd,
                               project: proj, first: first, last: last, cost: rows.reduce(0) { $0 + $1.cost },
                               tokens: rows.reduce(0) { $0 + $1.tokens }, bytes: size)
        return (rows, info, limits)
    }

    /// Pi logs one `message` line per turn; assistant turns carry `usage` and a USD `cost` Pi computed itself.
    static func parsePi(_ url: URL) -> ([UsageRow], SessionInfo?) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return ([], nil) }
        var cwd = "", sid = url.deletingPathExtension().lastPathComponent, title = ""
        var rows: [UsageRow] = []
        var first = Date.distantFuture, last = Date.distantPast
        let usageKey = Array("\"usage\"".utf8), userKey = Array("\"role\":\"user\"".utf8), sessionKey = Array("\"type\":\"session\"".utf8)
        Lines.each(data) { line in
            let isUsage = Lines.contains(line, usageKey)
            let isUser = title.isEmpty && Lines.contains(line, userKey)
            let isSession = cwd.isEmpty && Lines.contains(line, sessionKey)
            guard isUsage || isUser || isSession, let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
            if isSession { cwd = o["cwd"] as? String ?? ""; sid = o["id"] as? String ?? sid }
            guard let m = o["message"] as? [String: Any] else { return }
            if isUser, m["role"] as? String == "user" {
                var t: String?
                if let s = m["content"] as? String { t = s }
                else if let arr = m["content"] as? [[String: Any]] { t = arr.first { $0["type"] as? String == "text" }?["text"] as? String }
                if var s = t?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, let c = cleanTitle(&s) { title = c }
            }
            guard m["role"] as? String == "assistant", let u = m["usage"] as? [String: Any], let ms = m["timestamp"] as? Double else { return }
            let d = Date(timeIntervalSince1970: ms / 1000)
            first = min(first, d); last = max(last, d)
            let cost = (u["cost"] as? [String: Any])?["total"] as? Double ?? 0
            rows.append(UsageRow(agent: .pi, day: Calendar.current.startOfDay(for: d), model: m["model"] as? String ?? "pi",
                                 project: project(from: cwd), session: sid, input: u["input"] as? Int ?? 0, output: u["output"] as? Int ?? 0,
                                 cacheRead: u["cacheRead"] as? Int ?? 0, cacheWrite: u["cacheWrite"] as? Int ?? 0, costOverride: cost))
        }
        guard first != .distantFuture else { return ([], nil) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
        return (rows, SessionInfo(file: url.path, sessionID: sid, agent: .pi, title: title.isEmpty ? "Pi session" : title, cwd: cwd,
                                  project: project(from: cwd), first: first, last: last, cost: rows.reduce(0) { $0 + $1.cost },
                                  tokens: rows.reduce(0) { $0 + $1.tokens }, bytes: size))
    }

    static func project(from cwd: String) -> String {
        func last(_ s: String) -> String { (s as NSString).lastPathComponent }
        if let r = cwd.range(of: "/.claude/worktrees/") { return last(String(cwd[..<r.lowerBound])) }
        if let r = cwd.range(of: "/conductor/workspaces/") { return String(cwd[r.upperBound...].split(separator: "/").first ?? "") }
        return cwd.isEmpty ? "unknown" : last(cwd)
    }
}

// MARK: - View

struct UsageView: View {
    @EnvironmentObject var store: Store
    enum Range: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All time"
        var id: String { rawValue }
        var days: Int? { self == .week ? 7 : self == .month ? 30 : nil }
    }
    enum Metric: String, CaseIterable, Identifiable {
        case cost = "Est. cost", tokens = "Tokens"
        var id: String { rawValue }
    }
    @State private var range = Range.month
    @State private var metric = Metric.cost
    @State private var tool: AgentTool?
    @AppStorage("budget.daily") private var storedDaily = 0.0
    @AppStorage("budget.weekly") private var storedWeekly = 0.0
    private var dailyBudget: Double { Demo.enabled ? 40 : storedDaily }
    private var weeklyBudget: Double { Demo.enabled ? 260 : storedWeekly }

    private var scoped: [UsageRow] { tool == nil ? store.usage : store.usage.filter { $0.agent == tool } }
    private var rows: [UsageRow] {
        guard let d = range.days else { return scoped }
        let cutoff = Calendar.current.date(byAdding: .day, value: -(d - 1), to: Calendar.current.startOfDay(for: .now))!
        return scoped.filter { $0.day >= cutoff }
    }

    var body: some View {
        let rows = self.rows
        let cost = rows.reduce(0) { $0 + $1.cost }
        let tokens = rows.reduce(0) { $0 + $1.tokens }
        let cacheRead = rows.reduce(0) { $0 + $1.cacheRead }
        let promptTokens = rows.reduce(0) { $0 + $1.input + $1.cacheRead + $1.cacheWrite }
        let sessions = Set(rows.map(\.session)).count
        let today = scoped.filter { Calendar.current.isDateInToday($0.day) }

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.usage.isEmpty {
                    ContentUnavailableView(store.usageLoading ? "Reading agent logs…" : "No usage found", systemImage: "chart.bar.xaxis",
                                           description: Text("Reads Claude Code logs in ~/.claude/projects and Codex logs in ~/.codex/sessions."))
                } else {
                    budgets
                    StatStrip(items: [
                        .init(title: "Estimated cost", value: String(format: "$%.2f", cost), note: String(format: "$%.2f today", today.reduce(0) { $0 + $1.cost })),
                        .init(title: "Tokens", value: compact(tokens), note: "\(compact(today.reduce(0) { $0 + $1.tokens })) today"),
                        .init(title: "Sessions", value: "\(sessions)"),
                        .init(title: "Cache hit rate", value: promptTokens == 0 ? "–" : "\(cacheRead * 100 / promptTokens)%",
                              note: promptTokens > 0 && cacheRead * 100 / promptTokens < 60 ? "low: long prompts are re-billed" : "of prompt tokens"),
                    ])
                    if let c = store.codexLimits, tool != .claude { codexLimits(c) }
                    chart(rows)
                    expensive
                    HStack(alignment: .top, spacing: 14) {
                        breakdown("By model", Dictionary(grouping: rows, by: \.model))
                        breakdown("By project", Dictionary(grouping: rows, by: \.project))
                    }
                    Text("Costs are estimates at public API list prices from local logs. Subscription plans bill differently. Claude cache writes use the 5-minute rate.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(24)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 62) }   // keep the first row clear of the glass toolbar
        .navigationTitle("AI Usage")
        .toolbar {
            ToolbarItem { Picker("Tool", selection: $tool) { Text("All").tag(AgentTool?.none); ForEach(AgentTool.enabled, id: \.self) { Text($0.rawValue).tag(AgentTool?.some($0)) } }.pickerStyle(.segmented) }
            ToolbarItem { Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented) }
            ToolbarItem { Picker("Metric", selection: $metric) { ForEach(Metric.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented) }
            ToolbarItem { Button { store.loadUsage() } label: { Label("Reload", systemImage: "arrow.clockwise") } }
        }
    }

    // MARK: Budgets

    @ViewBuilder private var budgets: some View {
        let week = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now))!
        let dayCost = store.usage.filter { Calendar.current.isDateInToday($0.day) }.reduce(0) { $0 + $1.cost }
        let weekCost = store.usage.filter { $0.day >= week }.reduce(0) { $0 + $1.cost }
        if dailyBudget > 0 || weeklyBudget > 0 {
            VStack(spacing: 12) {
                if dailyBudget > 0 { meter("Today", dayCost, dailyBudget) }
                if weeklyBudget > 0 { meter("Last 7 days", weekCost, weeklyBudget) }
            }.padding(16).panel()
        } else {
            HStack {
                Image(systemName: "dollarsign.circle").foregroundStyle(.secondary)
                Text("Set a daily or weekly budget in Settings (⌘,) to get an alert before spend runs away.").foregroundStyle(.secondary)
                Spacer()
            }.font(.callout).padding(14).panel()
        }
    }

    private func meter(_ title: String, _ value: Double, _ budget: Double) -> some View {
        let f = value / budget
        return VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).fontWeight(.medium); Spacer()
                Text(String(format: "$%.2f of $%.0f", value, budget)).monospacedDigit().foregroundStyle(f >= 1 ? Color.red : .secondary) }
            ProgressView(value: min(f, 1)).tint(f >= 1 ? .red : f >= 0.8 ? .orange : Brand.accent)
        }
    }

    private func codexLimits(_ c: CodexLimits) -> some View {
        HStack(spacing: 24) {
            limit("Codex 5-hour window", c.primaryPct, c.primaryResets)
            limit("Codex weekly", c.weeklyPct, c.weeklyResets)
        }.padding(16).panel()
    }

    private func limit(_ title: String, _ pct: Double, _ resets: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).fontWeight(.medium); Spacer(); Text("\(Int(pct))% used").monospacedDigit().foregroundStyle(.secondary) }
            ProgressView(value: min(pct / 100, 1)).tint(pct >= 90 ? .red : pct >= 70 ? .orange : Brand.accent)
            Text(resets > .now ? "Resets \(resets.formatted(.relative(presentation: .named)))" : "Window has reset").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: Expensive sessions

    private var expensive: some View {
        let cutoff = range.days.map { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: Calendar.current.startOfDay(for: .now))! } ?? .distantPast
        let list = store.sessions.filter { $0.last >= cutoff && (tool == nil || $0.agent == tool) }
            .sorted { $0.cost > $1.cost }.prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Most expensive sessions").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(list)) { s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).lineLimit(1)
                            Text("\(s.agent.rawValue) · \(s.project) · \(s.last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "$%.2f", s.cost)).monospacedDigit().fontWeight(.medium)
                        Text(compact(s.tokens)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }.padding(.horizontal, 16).padding(.vertical, 9)
                    if s.id != list.last?.id { Divider() }
                }
            }.panel()
        }
    }

    // MARK: Charts

    private func value(_ rs: [UsageRow]) -> Double {
        metric == .cost ? rs.reduce(0) { $0 + $1.cost } : Double(rs.reduce(0) { $0 + $1.tokens })
    }

    private func chart(_ rows: [UsageRow]) -> some View {
        struct Bar: Identifiable { var id: String { "\(day.timeIntervalSince1970)|\(family)" }; let day: Date; let family: String; let v: Double }
        let bars = Dictionary(grouping: rows, by: { "\($0.day.timeIntervalSince1970)|\($0.family)" }).values.map {
            Bar(day: $0[0].day, family: $0[0].family, v: value($0))
        }
        return VStack(alignment: .leading) {
            Text("Daily \(metric.rawValue.lowercased())").font(.headline)
            Chart(bars) { b in
                BarMark(x: .value("Day", b.day, unit: .day), y: .value(metric.rawValue, b.v)).foregroundStyle(by: .value("Model", b.family))
            }
            .chartForegroundStyleScale(["Opus": Color(red: 0.514, green: 0.380, blue: 0.929), "Sonnet": Brand.accent, "Haiku": Color(red: 0.31, green: 0.66, blue: 0.96),
                                        "Fable": Color(red: 0.93, green: 0.36, blue: 0.62), "Codex": Color(red: 0.39, green: 0.45, blue: 0.55), "Pi": Color(red: 0.58, green: 0.64, blue: 0.72), "Other": Color(red: 0.80, green: 0.84, blue: 0.89)])
            .chartYAxis { AxisMarks { v in
                AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(metric == .cost ? "$\(Int(d))" : compact(Int(d))) } }
            } }
            .frame(height: 220)
        }
        .padding(16).panel(16)
    }

    private func breakdown(_ title: String, _ groups: [String: [UsageRow]]) -> some View {
        let items = groups.map { (name: $0.key, v: value($0.value)) }.sorted { $0.v > $1.v }.prefix(8)
        let maxV = items.first?.v ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(Array(items), id: \.name) { i in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(i.name.replacingOccurrences(of: "claude-", with: "")).lineLimit(1)
                        Spacer()
                        Text(metric == .cost ? String(format: "$%.2f", i.v) : compact(Int(i.v))).monospacedDigit()
                    }
                    Capsule().fill(.secondary.opacity(0.6)).frame(height: 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: max(0.01, i.v / maxV), anchor: .leading)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading).panel(16)
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000_000 ? String(format: "%.1fB", Double(n) / 1e9)
        : n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
        : n >= 1_000 ? String(format: "%.1fK", Double(n) / 1e3) : "\(n)"
    }
}
