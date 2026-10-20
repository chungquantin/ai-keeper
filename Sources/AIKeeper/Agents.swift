import SwiftUI

enum AgentKind: String, CaseIterable {
    case claude = "Claude Code", codex = "Codex", gemini = "Gemini CLI", aider = "Aider"
    case cursor = "Cursor Agent", opencode = "OpenCode", mcp = "MCP server"
    case pi = "Pi", zcode = "ZCode", goose = "Goose"

    /// Matches a ToolCatalog id; nil for MCP servers, which are never filtered out.
    var toolID: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .aider: "aider"
        case .cursor: "cursor"
        case .opencode: "opencode"
        case .pi: "pi"
        case .zcode: "zcode"
        case .goose: "goose"
        case .mcp: nil
        }
    }

    var symbol: String { self == .mcp ? "puzzlepiece.extension" : "terminal" }
    var color: Color {
        switch self {
        case .claude: .orange
        case .codex: .green
        case .gemini: .blue
        case .aider: .purple
        case .cursor: .teal
        case .opencode: .pink
        case .mcp: .gray
        case .pi: .indigo
        case .zcode: .mint
        case .goose: .brown
        }
    }
}

struct AgentProc: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let ppid: Int32
    let kind: AgentKind
    let elapsed: TimeInterval
    let cpu: Double
    let rssBytes: Int64
    var cwd: String?
    let command: String
    var busyChildren = false
    var state: AgentState = .unknown
    var title: String?
    var cost: Double?
    var sessionFile: String?
    var lastEvent: Date?

    /// MCP server whose parent is launchd: its client died, nothing is using it.
    var orphaned: Bool { kind == .mcp && ppid == 1 }
    var isActive: Bool { cpu >= 2 }
}

enum AgentScanner {
    static func scan() -> [AgentProc] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,etime=,pcpu=,rss=,command="]).out
        var found: [AgentProc] = []
        var table: [Int32: (ppid: Int32, cpu: Double)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]),
                  pid != getpid() else { continue }
            table[pid] = (ppid, Double(f[3]) ?? 0)
            let cmd = f[5].trimmingCharacters(in: .whitespaces)
            guard let kind = classify(cmd) else { continue }
            found.append(AgentProc(
                pid: pid, ppid: ppid, kind: kind, elapsed: parseElapsed(String(f[2])),
                cpu: Double(f[3]) ?? 0, rssBytes: (Int64(f[4]) ?? 0) * 1024, command: cmd))
        }
        guard !found.isEmpty else { return [] }

        let pids = found.map { String($0.pid) }.joined(separator: ",")
        let cwds = Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids]).out
        var map: [Int32: String] = [:]
        var cur: Int32?
        for l in cwds.split(separator: "\n") {
            if l.hasPrefix("p") { cur = Int32(l.dropFirst()) }
            else if l.hasPrefix("n"), let c = cur { map[c] = String(l.dropFirst()) }
        }
        for i in found.indices { found[i].cwd = map[found[i].pid] }
        // CPU used by an agent's child processes (builds, tests) means it is working even if its own CPU is low.
        var kids: [Int32: [Int32]] = [:]
        for (p, v) in table { kids[v.ppid, default: []].append(p) }
        func descendantCPU(_ p: Int32, depth: Int = 0) -> Double {
            guard depth < 6 else { return 0 }
            return (kids[p] ?? []).reduce(0) { $0 + (table[$1]?.cpu ?? 0) + descendantCPU($1, depth: depth + 1) }
        }
        for i in found.indices { found[i].busyChildren = descendantCPU(found[i].pid) >= 5 }
        return found.sorted { ($0.kind == .mcp ? 1 : 0, -$0.cpu) < ($1.kind == .mcp ? 1 : 0, -$1.cpu) }
    }

    static func classify(_ command: String) -> AgentKind? {
        let c = command.lowercased()
        if c.contains("helper") || c.hasPrefix("ps ") || c.contains("ai-keeper") || c.contains("aikeeper") { return nil }
        func exe(_ name: String) -> Bool { c.range(of: "(^|/)\(name)( |$)", options: .regularExpression) != nil }
        if c.contains("claude-code") || exe("claude") {
            // Desktop app main binary is not an agent; the CLI bundled under claude-code is.
            if c.contains(".app/contents/macos/claude") && !c.contains("claude-code") { return nil }
            return .claude
        }
        if exe("codex") || c.contains("@openai/codex") { return .codex }
        if exe("gemini") || c.contains("gemini-cli") { return .gemini }
        if exe("aider") { return .aider }
        if c.contains("cursor-agent") { return .cursor }
        if exe("opencode") { return .opencode }
        if exe("pi") || c.contains("pi-coding-agent") { return .pi }
        if exe("goose") { return .goose }
        if exe("zcode") || c.contains("zcode-cli") || c.contains("/.zcode/runtime") { return .zcode }
        if c.contains("mcp"), !c.contains(".app/") { return .mcp }
        return nil
    }

    /// `[[dd-]hh:]mm:ss`
    static func parseElapsed(_ s: String) -> TimeInterval {
        var days = 0.0, rest = s
        if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; rest = String(s[s.index(after: dash)...]) }
        let p = rest.split(separator: ":").compactMap { Double($0) }
        let secs = p.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86_400 + secs
    }
}

extension TimeInterval {
    var shortDuration: String {
        let s = Int(self)
        if s >= 86_400 { return "\(s / 86_400)d \(s % 86_400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 60)m \(s % 60)s"
    }
}

// MARK: - View

struct AgentsView: View {
    @EnvironmentObject var store: Store
    @State private var selection = Set<Int32>()
    @State private var pendingKill: [AgentProc] = []
    @State private var force = false

    private var agents: [AgentProc] { store.agents.filter { $0.kind != .mcp } }
    private var mcp: [AgentProc] { store.agents.filter { $0.kind == .mcp } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StatStrip(items: [
                    .init(title: "Running agents", value: "\(agents.count)"),
                    .init(title: "Needs you", value: "\(agents.filter { $0.state == .needsInput }.count)", note: "waiting on approval"),
                    .init(title: "Memory", value: agents.reduce(Int64(0)) { $0 + $1.rssBytes }.bytesString),
                    .init(title: "MCP servers", value: "\(mcp.count)",
                          note: mcp.contains(where: \.orphaned) ? "\(mcp.filter(\.orphaned).count) orphaned" : nil),
                ])
                section("Agents", agents, empty: "No coding agents running.")
                section("MCP servers", mcp, empty: "No MCP servers running.")
            }.padding(24)
        }
        .navigationTitle("Agents")
        .navigationSubtitle("Live · refreshes every 4s")
        .confirmationDialog(
            "\(force ? "Force quit" : "Stop") \(pendingKill.count) process\(pendingKill.count == 1 ? "" : "es")?",
            isPresented: Binding(get: { !pendingKill.isEmpty }, set: { if !$0 { pendingKill = [] } }),
            titleVisibility: .visible
        ) {
            Button(force ? "Force quit" : "Stop", role: .destructive) {
                for a in pendingKill { kill(a.pid, force ? SIGKILL : SIGTERM) }
                pendingKill = []
                Task { try? await Task.sleep(for: .milliseconds(600)); await store.refreshAgents() }
            }
        } message: {
            Text(pendingKill.map { "\($0.kind.rawValue) · \($0.cwd.map { ($0 as NSString).lastPathComponent } ?? "pid \($0.pid)")" }
                .joined(separator: "\n") + "\nUnsaved agent work in these sessions will be lost.")
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [AgentProc], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if list.isEmpty {
                Text(empty).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { a in
                        row(a)
                        if a.id != list.last?.id { Divider().padding(.leading, 48) }
                    }
                }
                .panel(14)
            }
        }
    }

    private func row(_ a: AgentProc) -> some View {
        let ws = store.workspace(for: a)
        return HStack(spacing: 12) {
            Image(systemName: a.kind.symbol).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(a.kind.color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.kind.rawValue).fontWeight(.medium)
                    if a.orphaned { Pill(text: "Orphaned", color: .orange) }
                    else if a.kind != .mcp { statePill(a) }
                }
                Text(ws.map { "\($0.repoName) · \($0.name)" } ?? a.cwd?.replacingOccurrences(of: home, with: "~") ?? a.command)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let t = a.title { Text(t).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer()
            if let c = a.cost { stat(String(format: "$%.2f", c), "Session") }
            stat("\(String(format: "%.1f", a.cpu))%", "CPU")
            stat(a.rssBytes.bytesString, "Memory")
            stat(a.elapsed.shortDuration, "Uptime")
            Button { force = false; pendingKill = [a] } label: { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless).help("Stop (SIGTERM)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contextMenu {
            if let cwd = a.cwd { Button("Reveal folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) } }
            Button("Copy command") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.command, forType: .string)
            }
            Divider()
            Button("Stop") { force = false; pendingKill = [a] }
            Button("Force quit", role: .destructive) { force = true; pendingKill = [a] }
        }
    }

    @ViewBuilder private func statePill(_ a: AgentProc) -> some View {
        switch a.state {
        case .needsInput: Pill(text: "Needs you", color: .orange)
        case .working: Pill(text: "Working", color: .green)
        case .idle: Pill(text: a.lastEvent.map { "Idle \(Date().timeIntervalSince($0).shortDuration)" } ?? "Idle", color: .gray)
        case .unknown: Pill(text: a.isActive ? "Active" : "Idle", color: a.isActive ? .green : .gray)
        }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(v).monospacedDigit().font(.callout)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }.frame(width: 72, alignment: .trailing)
    }
}
