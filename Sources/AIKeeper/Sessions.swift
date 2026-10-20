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
        guard UserDefaults.standard.object(forKey: "notify.agents") as? Bool ?? true else { return }
        for a in list where a.kind == .claude {
            let prev = agentStates[a.pid]
            let name = workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? "an agent"
            if a.state == .working, workStarted[a.pid] == nil { workStarted[a.pid] = Date() }
            if a.state == .needsInput, prev != .needsInput {
                Notifier.send("Claude needs you", "\(name): \(a.title ?? "waiting for approval")", id: "agent.\(a.pid).input")
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

struct SessionsView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var tool: AgentTool?
    @State private var orphansOnly = false
    @State private var matches: Set<String>?
    @State private var searching = false
    @State private var pendingDelete: SessionInfo?

    private var rows: [SessionInfo] {
        store.sessions.filter { s in
            (tool == nil || s.agent == tool) && (!orphansOnly || !s.cwdExists) &&
            (query.isEmpty || matches == nil ? (query.isEmpty || s.title.localizedCaseInsensitiveContains(query) || s.project.localizedCaseInsensitiveContains(query))
                                             : (matches!.contains(s.file) || s.title.localizedCaseInsensitiveContains(query)))
        }.sorted { $0.last > $1.last }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $tool) { Text("All").tag(AgentTool?.none); ForEach(AgentTool.enabled, id: \.self) { Text($0.rawValue).tag(AgentTool?.some($0)) } }
                    .pickerStyle(.segmented).frame(width: 190).labelsHidden()
                Toggle("Folder deleted", isOn: $orphansOnly).toggleStyle(.checkbox)
                Spacer()
                if searching { ProgressView().controlSize(.small) }
                Text("\(rows.count) sessions · \(rows.reduce(Int64(0)) { $0 + $1.bytes }.bytesString)").foregroundStyle(.secondary).font(.callout)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            List(rows) { s in
                HStack(spacing: 12) {
                    Image(systemName: s.agent == .claude ? "sparkles" : s.agent == .pi ? "p.circle" : "terminal").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).lineLimit(1)
                        HStack(spacing: 8) {
                            Text("\(s.project) · \(s.last.formatted(.relative(presentation: .named)))")
                            if !s.cwdExists { Pill(text: "Folder deleted", color: .gray) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "$%.2f", s.cost)).monospacedDigit().foregroundStyle(.secondary)
                    Text(s.bytes.bytesString).monospacedDigit().foregroundStyle(.tertiary).frame(width: 70, alignment: .trailing)
                    Button("Resume") { Resume.open(s) }.controlSize(.small).disabled(!s.cwdExists)
                }
                .contextMenu {
                    Button("Resume in Terminal") { Resume.open(s) }.disabled(!s.cwdExists)
                    Button("Reveal log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.file)]) }
                    Button("Copy session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.sessionID, forType: .string) }
                    Divider()
                    Button("Move log to Trash…", role: .destructive) { pendingDelete = s }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay { if rows.isEmpty { ContentUnavailableView(store.usageLoading ? "Reading sessions…" : "No sessions match", systemImage: "bubble.left.and.text.bubble.right") } }
        }
        .navigationTitle("Sessions")
        .searchable(text: $query, prompt: "Search titles, or text inside conversations")
        .onChange(of: query) { _, q in search(q) }
        .confirmationDialog("Move this session log to Trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let s = pendingDelete { try? FileManager.default.trashItem(at: URL(fileURLWithPath: s.file), resultingItemURL: nil); store.loadUsage() }
                pendingDelete = nil
            }
        } message: { Text(pendingDelete?.title ?? "") }
    }

    /// Full-text search through the raw logs with grep, debounced.
    private func search(_ q: String) {
        matches = nil
        guard q.count >= 3 else { return }
        searching = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard q == query else { return }
            let out = await Task.detached {
                Shell.run("/usr/bin/grep", ["-rliF", "--include=*.jsonl", "--", q, "\(home)/.claude/projects", "\(home)/.codex/sessions", "\(home)/.pi/agent/sessions"]).out
            }.value
            guard q == query else { return }
            matches = Set(out.split(separator: "\n").map(String.init))
            searching = false
        }
    }
}

enum Resume {
    /// Opens Terminal in the session's folder and resumes it. Uses a .command file so no automation permission is needed.
    static func open(_ s: SessionInfo) {
        let cmd: String
        switch s.agent {
        case .claude: cmd = "claude --resume \(s.sessionID)"
        case .codex: cmd = "codex resume \(s.sessionID)"
        case .pi: cmd = "pi --session \(shellQuote(s.file))"
        }
        let script = "#!/bin/zsh -l\ncd \(shellQuote(s.cwd)) && \(cmd)\n"
        let url = Persist.dir.appendingPathComponent("resume-\(s.sessionID.prefix(8)).command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
