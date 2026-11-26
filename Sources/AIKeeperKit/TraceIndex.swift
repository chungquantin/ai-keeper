import Foundation

// What happened inside each Claude Code session, read from the session logs in ~/.claude/projects.
// One summary per log, cached by the file's size and date so only changed logs are read again.
// Everything stays on this Mac: this is the data behind Logs, Prompts, Speed, Reliability, Context and the session panel.

struct TracePrompt: Codable, Hashable {
    var at: Date
    var text: String
    var words: Int
    var turns = 0            // model replies before your next prompt
    var seconds = 0.0        // from the prompt to the agent's last message
    var waitBefore = 0.0     // how long the agent sat finished before you sent this
    var namesFile = false
}

struct TraceStep: Codable, Hashable {
    var at: Date
    var kind: String         // prompt, tool, text
    var title: String
    var detail: String
    var ms = 0.0
    var failed = false
}

struct TraceEvent: Codable, Hashable, Identifiable {
    var id: String
    var at: Date
    var level: String        // info, warn, error
    var message: String
}

struct TraceLoop: Codable, Hashable { var what: String; var detail: String; var count: Int }

struct TraceSummary: Codable, Identifiable {
    var id: String { file }
    var file = "", sessionID = "", cwd = "", branch = ""
    var first = Date.distantFuture, last = Date.distantPast
    var prompts: [TracePrompt] = []
    var steps: [TraceStep] = []
    var events: [TraceEvent] = []
    var lastText = ""
    var toolCalls = 0, toolErrors = 0, bashCalls = 0, bashErrors = 0, denials = 0, edits = 0
    var hookRuns = 0, hookErrors = 0, apiErrors = 0, compactions = 0, modelSwitches = 0, idleBreaks = 0
    var tools: [String: Int] = [:], cmdRuns: [String: Int] = [:], cmdFails: [String: Int] = [:]
    var mcp: [String: Int] = [:], skills: [String: Int] = [:], hooks: [String: Int] = [:], hookFails: [String: Int] = [:]
    var files: [String: Int] = [:]
    var loops: [TraceLoop] = []
    var thinkingMs = 0.0, toolMs = 0.0, waitSeconds = 0.0
    var firstEditSeconds: Double?
    var outputTokens = 0, replies = 0
    var context: [Int] = []          // prompt size at each model reply, sampled
    var peakContext = 0
    /// Failures per day: [shell commands, other tools, denied by you, API errors]. The key is days since 1970.
    var errorDays: [Int: [Int]] = [:]

    var project: String { UsageParser.project(from: cwd) }
    var title: String { prompts.first?.text ?? project }
    var activeSeconds: Double { prompts.reduce(0) { $0 + $1.seconds } }
}

enum TraceIndexer {
    private struct Disk: Codable { var items: [String: Item]; struct Item: Codable { var sig: String; var s: TraceSummary } }
    private nonisolated(unsafe) static var cache: [String: (sig: String, s: TraceSummary)] = [:]
    private nonisolated(unsafe) static var restored = false
    private static let lock = NSLock()
    static let days = 30, maxFiles = 800

    /// Session logs touched in the last 30 days, newest first.
    static func files() -> [URL] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "\(home)/.claude/projects")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var out: [(URL, Date)] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d >= cutoff { out.append((f, d)) }
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(maxFiles).map(\.0)
    }

    private static func signature(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v?.fileSize ?? 0)"
    }

    /// Reads every recent log, reusing cached summaries. `progress` is called as it goes with what is ready so far.
    static func load(progress: (@Sendable (_ done: Int, _ total: Int, _ partial: [TraceSummary]?) -> Void)? = nil) -> [TraceSummary] {
        if Demo.enabled { return demo() }
        lock.lock()
        if !restored {
            restored = true
            if let d = Persist.load(Disk.self, "traces.json") { for (k, v) in d.items { cache[k] = (v.sig, v.s) } }
        }
        lock.unlock()
        let list = files()
        var out: [TraceSummary] = []; out.reserveCapacity(list.count)
        var parsed = 0
        for (i, url) in list.enumerated() {
            let sig = signature(url)
            lock.lock(); let hit = cache[url.path]; lock.unlock()
            if let hit, hit.sig == sig { out.append(hit.s) }
            else {
                let s = parse(url)
                lock.lock(); cache[url.path] = (sig, s); lock.unlock()
                out.append(s); parsed += 1
                if parsed % 20 == 0 { progress?(i + 1, list.count, out) }
            }
            if i % 50 == 0 { progress?(i + 1, list.count, nil) }
        }
        if parsed > 0 {
            let keep = Set(list.map(\.path))
            lock.lock(); cache = cache.filter { keep.contains($0.key) }
            let d = Disk(items: cache.mapValues { .init(sig: $0.sig, s: $0.s) }); lock.unlock()
            Persist.save(d, "traces.json")
        }
        return out.filter { !$0.prompts.isEmpty || $0.toolCalls > 0 }
    }

    // MARK: One log

    private static let wanted = [Array("\"type\":\"assistant\"".utf8), Array("\"type\":\"user\"".utf8), Array("\"type\":\"system\"".utf8)]
    private static let blob = Array("\"type\":\"api-request-blob\"".utf8)
    private static let multiWord: Set<String> = ["npm", "pnpm", "yarn", "bun", "cargo", "git", "swift", "go", "make", "docker", "npx", "uv", "gh", "kubectl", "brew", "pip", "pip3", "python", "python3", "node", "xcodebuild"]

    /// "cd x && cargo test --all" becomes "cargo test": what the command is, without its arguments.
    static func commandKey(_ cmd: String) -> String {
        var c = cmd
        for sep in ["&&", ";", "|"] { if let r = c.range(of: sep), c[..<r.lowerBound].trimmingCharacters(in: .whitespaces).hasPrefix("cd ") { c = String(c[r.upperBound...]) } }
        let words = c.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
        guard let first = words.first else { return "shell" }
        let head = (first as NSString).lastPathComponent
        guard multiWord.contains(head), words.count > 1, !words[1].hasPrefix("-") else { return String(head.prefix(40)) }
        if head == "npm" || head == "pnpm" || head == "yarn" || head == "bun", words[1] == "run", words.count > 2 { return "\(head) run \(words[2])".prefix(40).description }
        return "\(head) \(words[1])".prefix(40).description
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    static func parse(_ url: URL) -> TraceSummary {
        var s = TraceSummary(); s.file = url.path
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return s }
        var pending: [String: (name: String, at: Date, detail: String, key: String)] = [:]
        var seenReplies = Set<String>(), replyOut: [String: Int] = [:]
        var lastAssistant: Date?, lastModel = "", firstPrompt: Date?
        var repliesInTurn = Set<String>()
        var failRun = (cmd: "", n: 0)
        var lastEdit = (file: "", n: 0)
        var contexts: [Int] = []
        var eventN = 0

        func event(_ at: Date, _ level: String, _ msg: String) {
            eventN += 1
            s.events.append(TraceEvent(id: "\(s.sessionID)-\(eventN)", at: at, level: level, message: clip(msg, 220)))
            if s.events.count > 90 { s.events.removeFirst(30) }
        }
        func step(_ st: TraceStep) { s.steps.append(st); if s.steps.count > 160 { s.steps.removeFirst(60) } }
        func bump(_ day: Date, _ kind: Int) {
            let k = Int(day.timeIntervalSince1970 / 86_400)
            var a = s.errorDays[k] ?? [0, 0, 0, 0]; a[kind] += 1; s.errorDays[k] = a
        }
        func closeTurn() {
            guard !s.prompts.isEmpty else { return }
            let i = s.prompts.count - 1
            s.prompts[i].turns = repliesInTurn.count
            if let la = lastAssistant, la > s.prompts[i].at { s.prompts[i].seconds = la.timeIntervalSince(s.prompts[i].at) }
            if !s.lastText.isEmpty { step(TraceStep(at: lastAssistant ?? s.prompts[i].at, kind: "text", title: "Agent", detail: clip(s.lastText, 320))) }
            repliesInTurn = []
        }

        Lines.each(data) { line in
            guard !Lines.contains(line, blob), wanted.contains(where: { Lines.contains(line, $0) }),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = o["type"] as? String, o["isSidechain"] as? Bool != true,
                  let ts = (o["timestamp"] as? String).flatMap(FastDate.parse) else { return }
            if s.sessionID.isEmpty, let id = o["sessionId"] as? String { s.sessionID = id }
            if s.cwd.isEmpty, let c = o["cwd"] as? String { s.cwd = c }
            if let b = o["gitBranch"] as? String, !b.isEmpty { s.branch = b }
            s.first = min(s.first, ts); s.last = max(s.last, ts)

            switch type {
            case "assistant":
                guard let m = o["message"] as? [String: Any] else { return }
                lastAssistant = ts
                if o["isApiErrorMessage"] as? Bool == true { s.apiErrors += 1; bump(ts, 3); event(ts, "error", "The model API returned an error"); return }
                if let ms = o["thinkingDurationMs"] as? Double { s.thinkingMs += ms }
                if let id = m["id"] as? String {
                    repliesInTurn.insert(id)
                    if let u = m["usage"] as? [String: Any] {
                        let out = u["output_tokens"] as? Int ?? 0
                        if !seenReplies.contains(id) {
                            seenReplies.insert(id)
                            let ctx = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
                            if ctx > 0 { contexts.append(ctx); s.peakContext = max(s.peakContext, ctx) }
                            if let model = m["model"] as? String, model != "<synthetic>" { if !lastModel.isEmpty, model != lastModel { s.modelSwitches += 1 }; lastModel = model }
                        }
                        replyOut[id] = max(replyOut[id] ?? 0, out)
                    }
                }
                for case let b as [String: Any] in (m["content"] as? [Any]) ?? [] {
                    switch b["type"] as? String {
                    case "text": if let t = b["text"] as? String, !t.isEmpty { s.lastText = t }
                    case "tool_use":
                        guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                        let input = b["input"] as? [String: Any] ?? [:]
                        s.toolCalls += 1; s.tools[name, default: 0] += 1
                        var detail = "", key = name
                        if name.lowercased() == "bash", let c = input["command"] as? String {
                            detail = clip(c, 140); key = commandKey(c); s.bashCalls += 1; s.cmdRuns[key, default: 0] += 1
                        } else if let p = input["file_path"] as? String {
                            detail = p.replacingOccurrences(of: s.cwd + "/", with: "").replacingOccurrences(of: home, with: "~")
                            if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name) {
                                s.edits += 1; s.files[detail, default: 0] += 1
                                if s.firstEditSeconds == nil, let fp = firstPrompt { s.firstEditSeconds = ts.timeIntervalSince(fp) }
                                if lastEdit.file == detail { lastEdit.n += 1 } else {
                                    if lastEdit.n >= 6 { s.loops.append(TraceLoop(what: "Edited the same file \(lastEdit.n) times in a row", detail: lastEdit.file, count: lastEdit.n)) }
                                    lastEdit = (detail, 1)
                                }
                            }
                        } else if name.hasPrefix("mcp__") {
                            let parts = name.components(separatedBy: "__")
                            if parts.count > 1 { s.mcp[parts[1], default: 0] += 1 }
                            detail = parts.dropFirst(2).joined(separator: " ")
                        } else if name == "Skill", let sk = input["skill"] as? String { s.skills[sk, default: 0] += 1; detail = sk }
                        else if let q = (input["pattern"] ?? input["query"] ?? input["description"] ?? input["url"]) as? String { detail = clip(q, 120) }
                        pending[id] = (name, ts, detail, key)
                    default: break
                    }
                }

            case "user":
                guard let m = o["message"] as? [String: Any] else { return }
                var text = m["content"] as? String
                var sawResult = false
                for case let b as [String: Any] in (m["content"] as? [Any]) ?? [] {
                    if b["type"] as? String == "text", text == nil { text = b["text"] as? String }
                    guard b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String else { continue }
                    sawResult = true
                    guard let p = pending.removeValue(forKey: id) else { continue }
                    let ms = ((o["toolUseResult"] as? [String: Any])?["durationMs"] as? Double) ?? max(0, ts.timeIntervalSince(p.at) * 1000)
                    s.toolMs += min(ms, 3_600_000)
                    let denied = o["toolDenialKind"] != nil
                    let failed = b["is_error"] as? Bool == true
                    let isBash = p.name.lowercased() == "bash"
                    if denied { s.denials += 1; bump(ts, 2); event(ts, "warn", "You declined \(p.name): \(p.detail)") }
                    else if failed {
                        s.toolErrors += 1; bump(ts, isBash ? 0 : 1)
                        if isBash { s.bashErrors += 1; s.cmdFails[p.key, default: 0] += 1 }
                        event(ts, "error", "\(p.name) failed: \(p.detail)")
                    }
                    if isBash {
                        if failed, p.detail == failRun.cmd { failRun.n += 1 }
                        else {
                            if failRun.n >= 3 { s.loops.append(TraceLoop(what: "Re-ran the same failing command \(failRun.n) times", detail: failRun.cmd, count: failRun.n)) }
                            failRun = failed ? (p.detail, 1) : ("", 0)
                        }
                    }
                    step(TraceStep(at: p.at, kind: "tool", title: isBash ? p.key : p.name, detail: p.detail, ms: ms, failed: failed || denied))
                }
                guard !sawResult, o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true,
                      var t = text, !t.isEmpty, let cleaned = UsageParser.cleanTitle(&t) else { return }
                closeTurn()
                var p = TracePrompt(at: ts, text: clip(cleaned, 400), words: cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" }).count)
                p.namesFile = cleaned.range(of: #"[\w\-/]+\.[a-zA-Z]{1,5}\b|[\w\-]+/[\w\-]+"#, options: .regularExpression) != nil
                if let la = lastAssistant, ts > la {
                    let gap = ts.timeIntervalSince(la)
                    p.waitBefore = gap; s.waitSeconds += min(gap, 1800)
                    if gap > 300 { s.idleBreaks += 1 }
                }
                if firstPrompt == nil { firstPrompt = ts }
                s.prompts.append(p)
                s.lastText = ""
                step(TraceStep(at: ts, kind: "prompt", title: "You", detail: p.text))

            case "system":
                switch o["subtype"] as? String {
                case "compact_boundary":
                    s.compactions += 1
                    let pre = (o["compactMetadata"] as? [String: Any])?["preTokens"] as? Int
                    event(ts, "info", "Context was compacted" + (pre.map { " at \($0 / 1000)K tokens" } ?? ""))
                case "api_error": s.apiErrors += 1; bump(ts, 3); event(ts, "error", "The model API returned an error")
                case "stop_hook_summary":
                    for case let h as [String: Any] in (o["hookInfos"] as? [Any]) ?? [] {
                        if let c = h["command"] as? String { s.hooks[clip(c, 90), default: 0] += 1; s.hookRuns += 1 }
                    }
                    let errs = (o["hookErrors"] as? [Any]) ?? []
                    if !errs.isEmpty {
                        s.hookErrors += errs.count
                        for e in errs { let msg = (e as? String) ?? ((e as? [String: Any])?["command"] as? String) ?? "hook"; s.hookFails[clip(msg, 90), default: 0] += 1; event(ts, "error", "Hook failed: \(msg)") }
                    }
                default: break
                }
            default: break
            }
        }
        closeTurn()
        if failRun.n >= 3 { s.loops.append(TraceLoop(what: "Re-ran the same failing command \(failRun.n) times", detail: failRun.cmd, count: failRun.n)) }
        if lastEdit.n >= 6 { s.loops.append(TraceLoop(what: "Edited the same file \(lastEdit.n) times in a row", detail: lastEdit.file, count: lastEdit.n)) }
        s.replies = seenReplies.count
        s.outputTokens = replyOut.values.reduce(0, +)
        // Keep at most 60 points of the context curve.
        if contexts.count > 60 { let stride = Double(contexts.count) / 60; s.context = (0..<60).map { contexts[min(contexts.count - 1, Int(Double($0) * stride))] } } else { s.context = contexts }
        if s.steps.count > 100 { s.steps = Array(s.steps.suffix(100)) }
        if s.events.count > 60 { s.events = Array(s.events.suffix(60)) }
        if s.files.count > 40 { s.files = Dictionary(uniqueKeysWithValues: s.files.sorted { $0.value > $1.value }.prefix(40).map { ($0.key, $0.value) }) }
        return s
    }
}

// MARK: Numbers for the Insights pages, for one stretch of days

struct TraceAgg {
    var sessions = 0, prompts = 0, toolCalls = 0, toolErrors = 0, denials = 0, edits = 0, hookRuns = 0, hookErrors = 0, apiErrors = 0
    var loops: [(loop: TraceLoop, session: String)] = []
    var compactions = 0, idleBreaks = 0, modelSwitches = 0, bigContext = 0
    var cmdRuns: [String: Int] = [:], cmdFails: [String: Int] = [:], mcp: [String: Int] = [:], skills: [String: Int] = [:]
    var hooks: [String: Int] = [:], hookFails: [String: Int] = [:], files: [String: Int] = [:]
    var errorDays: [Int: [Int]] = [:]
    var sessionSeconds: [Double] = [], firstEdit: [Double] = [], turnSeconds: [Double] = [], peak: [Int] = []
    var thinkingSeconds = 0.0, toolSeconds = 0.0, waitSeconds = 0.0, activeSeconds = 0.0, outputTokens = 0
    var perDay: [Int: (turn: [Double], firstEdit: [Double], session: [Double], prompts: Int)] = [:]
    var slowest: [(prompt: TracePrompt, session: TraceSummary)] = []

    var failRate: Double { toolCalls > 0 ? Double(toolErrors) / Double(toolCalls) : 0 }
    var rejectRate: Double { edits + denials > 0 ? Double(denials) / Double(edits + denials) : 0 }
    var hookFailRate: Double { hookRuns > 0 ? Double(hookErrors) / Double(hookRuns) : 0 }
    var outputSpeed: Double { let model = max(activeSeconds - toolSeconds, 1); return Double(outputTokens) / model }

    static func median(_ a: [Double]) -> Double { percentile(a, 0.5) }
    static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }

    /// Sessions that were last active inside `from..<to`.
    static func compute(_ traces: [TraceSummary], from: Date, to: Date) -> TraceAgg {
        var a = TraceAgg()
        var slow: [(TracePrompt, TraceSummary)] = []
        for t in traces where t.last >= from && t.last < to {
            a.sessions += 1; a.prompts += t.prompts.count
            a.toolCalls += t.toolCalls; a.toolErrors += t.toolErrors; a.denials += t.denials; a.edits += t.edits
            a.hookRuns += t.hookRuns; a.hookErrors += t.hookErrors; a.apiErrors += t.apiErrors
            a.compactions += t.compactions; a.idleBreaks += t.idleBreaks; a.modelSwitches += t.modelSwitches
            if t.peakContext > 150_000 { a.bigContext += 1 }
            for l in t.loops { a.loops.append((l, t.title)) }
            for (k, v) in t.cmdRuns { a.cmdRuns[k, default: 0] += v }
            for (k, v) in t.cmdFails { a.cmdFails[k, default: 0] += v }
            for (k, v) in t.mcp { a.mcp[k, default: 0] += v }
            for (k, v) in t.skills { a.skills[k, default: 0] += v }
            for (k, v) in t.hooks { a.hooks[k, default: 0] += v }
            for (k, v) in t.hookFails { a.hookFails[k, default: 0] += v }
            for (k, v) in t.files { a.files[(t.project) + "/" + k, default: 0] += v }
            for (k, v) in t.errorDays { var x = a.errorDays[k] ?? [0, 0, 0, 0]; for i in 0..<4 { x[i] += v[i] }; a.errorDays[k] = x }
            let active = t.activeSeconds
            if active > 0 { a.sessionSeconds.append(active) }
            if let f = t.firstEditSeconds, f > 0, f < 7200 { a.firstEdit.append(f) }
            if t.peakContext > 0 { a.peak.append(t.peakContext) }
            a.thinkingSeconds += t.thinkingMs / 1000; a.toolSeconds += t.toolMs / 1000; a.waitSeconds += t.waitSeconds
            a.activeSeconds += active; a.outputTokens += t.outputTokens
            let day = Int(t.last.timeIntervalSince1970 / 86_400)
            var d = a.perDay[day] ?? ([], [], [], 0)
            for p in t.prompts where p.seconds > 0 {
                a.turnSeconds.append(p.seconds); d.turn.append(p.seconds)
                if slow.count < 6 || p.seconds > (slow.last?.0.seconds ?? 0) {
                    slow.insert((p, t), at: slow.firstIndex { p.seconds > $0.0.seconds } ?? slow.count)
                    if slow.count > 6 { slow.removeLast() }
                }
            }
            if let f = t.firstEditSeconds, f > 0, f < 7200 { d.firstEdit.append(f) }
            if active > 0 { d.session.append(active) }
            d.prompts += t.prompts.count
            a.perDay[day] = d
        }
        a.loops.sort { $0.loop.count > $1.loop.count }
        a.slowest = slow.map { (prompt: $0.0, session: $0.1) }
        return a
    }
}

// MARK: Agent configuration that already exists on disk (read only)

struct MCPServerInfo: Identifiable, Hashable { var id: String { agent + "|" + name + "|" + scope }; let name: String; let agent: String; let scope: String; let kind: String }
struct HookInfo: Identifiable, Hashable { var id: String { event + "|" + matcher + "|" + command }; let event: String; let matcher: String; let command: String }

enum AgentConfig {
    /// MCP servers Claude Code and Codex are set up with: global ones and per-project ones.
    static func mcpServers() -> [MCPServerInfo] {
        if Demo.enabled {
            return [("github", "Claude Code", "All projects", "stdio"), ("postgres", "Claude Code", "api-server", "stdio"), ("linear", "Claude Code", "All projects", "http"),
                    ("filesystem", "Codex", "All projects", "stdio")].map { MCPServerInfo(name: $0.0, agent: $0.1, scope: $0.2, kind: $0.3) }
        }
        var out: [MCPServerInfo] = []
        func kind(_ v: Any) -> String { let d = v as? [String: Any] ?? [:]; return (d["type"] as? String) ?? (d["url"] != nil ? "http" : "stdio") }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in (o["mcpServers"] as? [String: Any]) ?? [:] { out.append(MCPServerInfo(name: k, agent: "Claude Code", scope: "All projects", kind: kind(v))) }
            for (path, p) in (o["projects"] as? [String: Any]) ?? [:] {
                for (k, v) in ((p as? [String: Any])?["mcpServers"] as? [String: Any]) ?? [:] {
                    out.append(MCPServerInfo(name: k, agent: "Claude Code", scope: (path as NSString).lastPathComponent, kind: kind(v)))
                }
            }
        }
        if let toml = try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8) {
            for line in toml.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("[mcp_servers."), l.hasSuffix("]") else { continue }
                let name = l.dropFirst("[mcp_servers.".count).dropLast().split(separator: ".").first.map(String.init) ?? ""
                if !name.isEmpty, !out.contains(where: { $0.agent == "Codex" && $0.name == name }) { out.append(MCPServerInfo(name: name.replacingOccurrences(of: "\"", with: ""), agent: "Codex", scope: "All projects", kind: "stdio")) }
            }
        }
        return out.sorted { ($0.agent, $0.name) < ($1.agent, $1.name) }
    }

    /// Hooks in Claude Code's settings: when each runs and what it runs.
    static func hooks() -> [HookInfo] {
        if Demo.enabled {
            return [("PostToolUse", "Edit|Write", "prettier --check \"$FILE\""), ("PostToolUse", "Edit", "cargo fmt"), ("Stop", "", "~/bin/notify.sh done"),
                    ("PermissionRequest", "Bash", "~/bin/guard-prod-db.sh")].map { HookInfo(event: $0.0, matcher: $0.1, command: $0.2) }
        }
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude/settings.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        var out: [HookInfo] = []
        for (event, v) in (o["hooks"] as? [String: Any]) ?? [:] {
            for case let g as [String: Any] in (v as? [Any]) ?? [] {
                for case let h as [String: Any] in (g["hooks"] as? [Any]) ?? [] {
                    if let c = h["command"] as? String { out.append(HookInfo(event: event, matcher: g["matcher"] as? String ?? "", command: c)) }
                }
            }
        }
        return out.sorted { ($0.event, $0.command) < ($1.event, $1.command) }
    }
}

// MARK: Demo data (AIKEEPER_DEMO=1): invented sessions, so screenshots never show real work

extension TraceIndexer {
    static func demo() -> [TraceSummary] {
        let now = Date()
        let titles = ["Add retry with backoff to the billing webhook handler", "Add a CSV export to the orders table. Reuse the existing Table component.", "Make search faster",
                      "Index orders by customer and status. The slow query is in src/api/orders.rs.", "Fix the flaky CI on Windows", "Rename the scratch workspace and update the README links",
                      "Upgrade dependencies, then run cargo test and fix any type errors", "Write release notes for 0.2.2 from the merged PRs", "Refactor billing webhooks for idempotency",
                      "Fix pagination when the cursor is empty in src/api/list.rs", "Add tests for the retry policy", "Migrate the queue to durable storage"]
        let projects = ["api-server", "web-app", "mobile-app", "docs-site"]
        let cmds = ["cargo test", "prettier", "npm run build", "psql", "cargo build", "git status", "swift build"]
        func r(_ i: Int, _ k: Int) -> Double { MockData.seeded(i, k) }
        return (0..<48).map { i in
            var s = TraceSummary()
            let hoursAgo = Double(i) * 13 + r(i, 1) * 6
            s.file = "/demo/trace-\(i)"; s.sessionID = "demo-\(i)"; s.cwd = "\(Demo.user)/Developer/\(projects[i % 4])"; s.branch = "claude/task-\(i)"
            s.last = now.addingTimeInterval(-hoursAgo * 3600)
            let n = 2 + Int(r(i, 2) * 5)
            var t = s.last.addingTimeInterval(-Double(n) * 900)
            s.first = t
            for k in 0..<n {
                let text = k == 0 ? titles[i % titles.count] : ["Run the tests again", "Use the existing helper in src/util.rs", "That failed, try the other approach", "Looks good, open a PR"][k % 4]
                var p = TracePrompt(at: t, text: text, words: text.split(separator: " ").count)
                p.turns = 2 + Int(r(i * 7 + k, 3) * 12); p.seconds = 40 + r(i * 7 + k, 4) * 900 * (i % 5 == 0 ? 2.2 : 1); p.waitBefore = k == 0 ? 0 : 30 + r(i * 7 + k, 5) * 500
                p.namesFile = text.contains("/") || text.contains(".rs")
                s.prompts.append(p); s.steps.append(TraceStep(at: t, kind: "prompt", title: "You", detail: text))
                let c = cmds[(i + k) % cmds.count], bad = r(i * 7 + k, 6) > 0.72
                s.steps.append(TraceStep(at: t.addingTimeInterval(20), kind: "tool", title: "Read", detail: "src/billing/webhook.rs", ms: 400))
                s.steps.append(TraceStep(at: t.addingTimeInterval(120), kind: "tool", title: "Edit", detail: "src/billing/retry.rs", ms: 9000))
                s.steps.append(TraceStep(at: t.addingTimeInterval(300), kind: "tool", title: c, detail: c + " --all", ms: 38_000, failed: bad))
                s.steps.append(TraceStep(at: t.addingTimeInterval(p.seconds), kind: "text", title: "Agent", detail: bad ? "One test failed: retry_exhausts_after_five expected 5 attempts and got 6. I'll fix the counter." : "Done. The retry policy is in place and the tests pass."))
                s.cmdRuns[c, default: 0] += 3; if bad { s.cmdFails[c, default: 0] += 1; s.toolErrors += 1; s.bashErrors += 1
                    s.events.append(TraceEvent(id: "d\(i)-\(k)", at: t.addingTimeInterval(300), level: "error", message: "Bash failed: \(c) --all"))
                    let day = Int(t.timeIntervalSince1970 / 86_400); var e = s.errorDays[day] ?? [0, 0, 0, 0]; e[k % 2] += 1; s.errorDays[day] = e }
                s.waitSeconds += min(p.waitBefore, 1800); if p.waitBefore > 300 { s.idleBreaks += 1 }
                t = t.addingTimeInterval(900)
            }
            s.toolCalls = 20 + Int(r(i, 7) * 90); s.bashCalls = s.toolCalls / 2; s.edits = 3 + Int(r(i, 8) * 14); s.replies = s.toolCalls + n
            s.denials = r(i, 9) > 0.8 ? 1 : 0; s.hookRuns = n * 2; s.hookErrors = r(i, 10) > 0.85 ? 1 : 0; s.compactions = r(i, 11) > 0.8 ? 1 : 0
            if s.hookErrors > 0 { s.hookFails["prettier --check \"$FILE\"", default: 0] += 1; s.events.append(TraceEvent(id: "h\(i)", at: s.last, level: "error", message: "Hook failed: prettier --check src/export.ts")) }
            if s.denials > 0 { s.events.append(TraceEvent(id: "p\(i)", at: s.last.addingTimeInterval(-60), level: "warn", message: "You declined Bash: psql -f migrations/0042_retry.sql")) }
            if s.compactions > 0 { s.events.append(TraceEvent(id: "c\(i)", at: s.last.addingTimeInterval(-600), level: "info", message: "Context was compacted at 168K tokens")) }
            s.hooks["prettier --check \"$FILE\""] = n; s.hooks["~/bin/notify.sh done"] = n
            s.mcp = i % 3 == 0 ? ["github": 4 + i % 5] : (i % 4 == 0 ? ["postgres": 2] : [:]); s.skills = i % 6 == 0 ? ["frontend-design": 1] : [:]
            s.files = ["src/billing/retry.rs": 2 + i % 6, "tests/retry_test.rs": 1 + i % 3, "src/api/orders.rs": i % 4]
            if i % 9 == 0 { s.loops = [TraceLoop(what: "Re-ran the same failing command \(4 + i % 6) times", detail: "cargo test billing::retry_exhausts_after_five", count: 4 + i % 6)] }
            s.thinkingMs = s.activeSeconds * 1000 * 0.38; s.toolMs = s.activeSeconds * 1000 * 0.22
            s.firstEditSeconds = 90 + r(i, 12) * 500 * (hoursAgo > 180 ? 1.5 : 1)
            s.outputTokens = Int(s.activeSeconds * (55 + r(i, 13) * 40))
            let steps = 12 + Int(r(i, 14) * 40), slope = 2500 + r(i, 15) * 4500
            s.context = (0..<steps).map { 14_000 + Int(Double($0) * slope) }; s.peakContext = s.context.last ?? 0
            s.lastText = s.steps.last?.detail ?? ""
            return s
        }
    }
}
