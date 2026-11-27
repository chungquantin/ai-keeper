import SwiftUI

enum AgentState: String {
    case working, needsInput, idle, unknown
}

/// Reads the tail of a Claude session log to tell whether the agent is working, blocked on you, or done.
enum SessionPeek {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (at: Date, mtime: Date, size: Int64, title: String, cost: Double)] = [:]

    static func projectDir(for cwd: String) -> String {
        "\(home)/.claude/projects/" + cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    private enum Tail { case toolPending, textDone, thinking, toolResult, prompt, unknown }

    /// Fills state, title and cost on Claude agents. Agents sharing a folder are paired with that folder's
    /// session files youngest-to-newest, which is a heuristic, not a guarantee.
    static func assign(_ agents: [AgentProc]) -> [AgentProc] {
        var out = agents
        var byCwd: [String: [Int]] = [:]
        for (i, a) in agents.enumerated() where a.kind == .claude { if let c = a.cwd { byCwd[c, default: []].append(i) } }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for (cwd, idxs) in byCwd {
            let dir = projectDir(for: cwd)
            let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            let files = urls.compactMap { u -> (URL, Date, Date, Int64)? in
                guard let v = try? u.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (u, v.creationDate ?? .distantPast, v.contentModificationDate ?? .distantPast, Int64(v.fileSize ?? 0))
            }.sorted { $0.1 > $1.1 }   // newest session first
            let ordered = idxs.sorted { agents[$0].elapsed < agents[$1].elapsed }   // youngest process first
            for (n, i) in ordered.enumerated() {
                guard n < files.count else { continue }
                let (url, _, mtime, size) = files[n]
                out[i].sessionFile = url.path
                out[i].lastEvent = mtime
                let (title, cost) = summary(url, mtime: mtime, size: size, iso: iso)
                out[i].title = title.isEmpty ? nil : title
                out[i].cost = cost
                out[i].state = state(tail: tail(url, size: size), age: Date().timeIntervalSince(mtime), busy: agents[i].busyChildren || agents[i].cpu > 3)
            }
        }
        // Drop cache entries for session files that no longer back a running agent's slot.
        let keep = Set(out.compactMap(\.sessionFile))
        lock.lock(); cache = cache.filter { keep.contains($0.key) || Date().timeIntervalSince($0.value.at) < 600 }; lock.unlock()
        return out
    }

    private static func summary(_ url: URL, mtime: Date, size: Int64, iso: ISO8601DateFormatter) -> (String, Double) {
        lock.lock(); let hit = cache[url.path]; lock.unlock()
        // A live session grows every few seconds. Re-reading the whole log each time is what burned CPU, so refresh at most every 30s.
        if let h = hit, (h.mtime == mtime && h.size == size) || Date().timeIntervalSince(h.at) < 30 { return (h.title, h.cost) }
        let r = UsageParser.parseClaude(url, iso: iso)
        let cost = r.items.reduce(0) { $0 + $1.row.cost }
        lock.lock(); cache[url.path] = (Date(), mtime, size, r.title, cost); lock.unlock()
        return (r.title, cost)
    }

    private static func state(tail: Tail, age: TimeInterval, busy: Bool) -> AgentState {
        if age < 20 { return .working }
        switch tail {
        case .toolPending: return busy ? .working : .needsInput   // waiting on a permission prompt
        case .textDone: return .idle
        case .thinking, .toolResult, .prompt: return busy ? .working : (age > 180 ? .idle : .working)
        case .unknown: return busy ? .working : .idle
        }
    }

    private static func tail(_ url: URL, size: Int64) -> Tail {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? h.close() }
        let window: UInt64 = 192 * 1024
        try? h.seek(toOffset: UInt64(size) > window ? UInt64(size) - window : 0)
        let data = (try? h.readToEnd()) ?? Data()
        for raw in data.split(separator: 0x0A).reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let type = o["type"] as? String, type == "assistant" || type == "user",
                  let msg = o["message"] as? [String: Any] else { continue }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            let kinds = Set(blocks.compactMap { $0["type"] as? String })
            if type == "assistant" {
                if kinds.contains("tool_use") { return .toolPending }
                return kinds.contains("text") ? .textDone : .thinking
            }
            return kinds.contains("tool_result") ? .toolResult : .prompt
        }
        return .unknown
    }
}

extension Store {
    /// Notify when an agent gets blocked on you, or finishes a long piece of work.
    func trackTransitions(_ list: [AgentProc]) {
        // Forget agents that are gone: the maps would otherwise grow for as long as the app runs, and a new process that
        // reuses a PID would inherit the old one's state and trigger a false notification.
        let live = Set(list.map(\.pid))
        agentStates = agentStates.filter { live.contains($0.key) }
        workStarted = workStarted.filter { live.contains($0.key) }
        guard UserDefaults.standard.object(forKey: Prefs.Key.notifyAgents) as? Bool ?? true else { return }
        for a in list where a.kind == .claude {
            let prev = agentStates[a.pid]
            let name = workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? "an agent"
            if a.state == .working, workStarted[a.pid] == nil { workStarted[a.pid] = Date() }
            if a.state == .needsInput, prev != .needsInput {
                Notifier.send("Claude needs you", "\(name): \(a.title ?? "waiting for approval")", id: "agent.\(a.pid).input", kind: .agent)
            }
            if a.state == .idle, prev == .working, let t = workStarted[a.pid], Date().timeIntervalSince(t) > 90 {
                Notifier.send("Claude finished", "\(name): \(a.title ?? "ready for your next prompt")", id: "agent.\(a.pid).done")
            }
            if a.state != .working { workStarted[a.pid] = nil }
            agentStates[a.pid] = a.state
        }
    }
}

// MARK: - Sessions browser

enum Resume {
    /// Opens Terminal in the session's folder and resumes it. Uses a .command file so no automation permission is needed.
    static func open(_ s: SessionInfo) {
        // The ID comes from a log file that any process can write, and ends up in a shell script: allow only what real IDs contain.
        guard s.sessionID.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { return }
        let cmd: String
        switch s.agent {
        case .claude: cmd = "claude --resume \(shellQuote(s.sessionID))"
        case .codex: cmd = "codex resume \(shellQuote(s.sessionID))"
        case .pi: cmd = "pi --session \(shellQuote(s.file))"
        }
        let script = "#!/bin/zsh -l\ncd \(shellQuote(s.cwd)) && \(cmd)\n"
        let url = Persist.dir.appendingPathComponent("resume-\(s.sessionID.prefix(8)).command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
