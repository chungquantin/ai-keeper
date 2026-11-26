import SwiftUI

/// Agents › Tools: every agent on this Mac in one table. Detection, running counts and today's spend are real;
/// budgets and the config summary are sample data until they can be read from each tool.
struct FleetView: View {
    @EnvironmentObject var store: Store
    @State private var selected: String?
    @State private var showDetected = false

    private struct Row: Identifiable {
        let id: String; let det: Detection; let running: Int; let spend: Double; let budget: Double?; let spent: Double
    }

    private var rows: [Row] {
        let budgets: [String: Double] = Dictionary(uniqueKeysWithValues: AgentTool.allCases.compactMap { a in let b = AgentBudget.get(a); return b > 0 ? (a.toolID, b) : nil })
        return store.detections.filter(\.found).map { d in
            let tool = AgentTool.allCases.first { $0.toolID == d.spec.id }
            let spend = tool.map { t in store.usage.filter { $0.agent == t && Calendar.current.isDateInToday($0.day) }.reduce(0) { $0 + $1.cost } } ?? 0
            let running = store.agents.filter { $0.kind.toolID == d.spec.id }.count
            return Row(id: d.id, det: d, running: running, spend: spend, budget: budgets[d.spec.id], spent: spend)
        }.sorted { ($0.running, $0.spend) > ($1.running, $1.spend) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Seg([("Fleet", false), ("Detect and choose tools", true)], selection: $showDetected)
                Spacer()
            }.padding(.horizontal, 28).padding(.vertical, 10)
            if showDetected { ToolsView() } else { fleet }
        }
        .task { if store.detections.isEmpty { await store.detectTools() } }
    }

    private var fleet: some View {
        let rows = self.rows
        let pick = rows.first { $0.id == selected } ?? rows.first
        return GeometryReader { geo in HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Text("Agent").frame(maxWidth: .infinity, alignment: .leading); Text("State").frame(width: 80, alignment: .leading)
                                Text("Running").frame(width: 64, alignment: .trailing); Text("Spend today").frame(width: 88, alignment: .trailing)
                                Text("Daily budget").frame(width: 150, alignment: .leading); Text("On").frame(width: 44)
                            }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                            ForEach(rows) { r in
                                Divider()
                                Button { selected = r.id } label: { row(r, selected: pick?.id == r.id) }.buttonStyle(.plain)
                            }
                            if rows.isEmpty { Text("No tools detected yet.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                        }
                    }
                }.padding(.horizontal, 28).padding(.vertical, 6)
            }
            if let pick, geo.size.width >= 980 {
                Divider()
                inspector(pick).frame(width: 320)
            }
        } }
    }

    private func row(_ r: Row, selected: Bool) -> some View {
        let on = Binding(get: { store.enabledTools.contains(r.id) }, set: { v in if v { store.enabledTools.insert(r.id) } else { store.enabledTools.remove(r.id) } })
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                ToolIcon(id: r.det.spec.id, fallback: r.det.spec.symbol, size: 24).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) { Text(r.det.spec.name).font(.bBody.weight(.medium)); Text(r.det.spec.blurb).font(.bCaption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Tag(text: r.running > 0 ? "Active" : "Idle", tone: r.running > 0 ? .blue : .gray).frame(width: 80, alignment: .leading)
            Text("\(r.running)").font(.bBody).monospacedDigit().frame(width: 64, alignment: .trailing)
            Text(String(format: "$%.2f", r.spend)).font(.bBody).monospacedDigit().frame(width: 88, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.budget.map { String(format: "$%.2f of $%.0f", r.spend, $0) } ?? "No budget").font(.bCaption).foregroundStyle(.secondary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Brand.muted)
                        if let b = r.budget { Capsule().fill(r.spend / b > 0.8 ? Brand.reclaim : Brand.accent).frame(width: g.size.width * min(r.spend / b, 1)) }
                    }
                }.frame(height: 5)
            }.frame(width: 150, alignment: .leading)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small).frame(width: 44)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(selected ? Brand.primaryTint : .clear).contentShape(Rectangle())
    }

    private func inspector(_ r: Row) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.det.spec.name).font(.brand(17, .semibold))
                    HStack(spacing: 6) {
                        Tag(text: "\(r.running) running", tone: r.running > 0 ? .blue : .gray)
                        let waiting = store.agents.filter { $0.kind.toolID == r.det.spec.id && $0.state == .needsInput }.count
                        if waiting > 0 { Tag(text: "\(waiting) needs you", tone: .amber) }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Found on this Mac").font(.bHeadline).padding(.bottom, 6)
                    row("Where", r.det.evidence.isEmpty ? "—" : r.det.evidence)
                    if let f = store.footprints[r.det.spec.id] { row("On disk", f.bytesString) }
                    row("Features", r.det.spec.capabilities.joined(separator: ", "))
                }
                if r.id == "claude" || r.id == "codex" {
                    let agent = r.id == "claude" ? "Claude Code" : "Codex"
                    let servers = store.mcpServers.filter { $0.agent == agent }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Set up").font(.bHeadline).padding(.bottom, 6)
                        row("MCP servers", servers.isEmpty ? "None" : Array(Set(servers.map(\.name))).sorted().prefix(4).joined(separator: ", ") + (Set(servers.map(\.name)).count > 4 ? "…" : ""))
                        row("Skills", "\(store.skills.filter { $0.tools.contains(agent) || $0.tools.contains("Shared") }.count)")
                        if r.id == "claude" { row("Hooks", "\(store.hooks.count)") }
                    }
                    if r.id == "claude", let unused = Set(servers.map(\.name)).filter({ (store.advice.agg.mcp[$0] ?? 0) == 0 }).sorted().first, store.advice.agg.sessions > 0 {
                        Note(text: "\(unused) was not called in any session in the last 30 days.")
                    }
                }
                Button { if let p = r.det.dataPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } } label: { Text("Open config folder").frame(maxWidth: .infinity) }.disabled(r.det.dataPath == nil)
            }.padding(20)
        }.background(Brand.card)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k).foregroundStyle(.secondary); Spacer(minLength: 12); Text(v).multilineTextAlignment(.trailing).lineLimit(2) }
            .font(.bCaption).padding(.vertical, 6).overlay(alignment: .top) { Divider() }
    }
}
