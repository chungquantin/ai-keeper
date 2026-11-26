import SwiftUI

// MARK: MCP servers (sample data)

struct MCPView: View {
    private struct Server: Identifiable { let id = UUID(); let name: String; let agents: String; let calls: Int; let tokens: String; let fail: String; var on: Bool; let verdict: String; let tone: Tone }
    @State private var servers: [Server] = [
        Server(name: "github", agents: "Claude Code", calls: 312, tokens: "4.2K", fail: "2%", on: true, verdict: "Keep", tone: .blue),
        Server(name: "postgres", agents: "Claude Code, Codex", calls: 96, tokens: "2.9K", fail: "1%", on: true, verdict: "Keep", tone: .blue),
        Server(name: "linear", agents: "Claude Code", calls: 0, tokens: "3.8K", fail: "—", on: true, verdict: "Unused for 60 days", tone: .amber),
        Server(name: "filesystem", agents: "Codex", calls: 41, tokens: "1.2K", fail: "0%", on: true, verdict: "Keep", tone: .blue),
        Server(name: "browser", agents: "Claude Code", calls: 3, tokens: "5.1K", fail: "33%", on: false, verdict: "Off", tone: .gray),
    ]
    var body: some View {
        Page(title: "MCP servers", subtitle: "What each server adds to every session, and whether it is used", sample: true) {
            HStack(spacing: 12) {
                KPI(title: "Servers", value: "5", prior: "4 on")
                KPI(title: "Calls this month", value: "452", prior: "across all agents")
                KPI(title: "Added to every session", value: "13.2K", prior: "tokens, servers that are on")
                KPI(title: "Unused", value: "1", prior: "linear, 3.8K tokens", delta: "$9 a month", good: true)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Server").frame(maxWidth: .infinity, alignment: .leading); Text("Calls").frame(width: 70, alignment: .trailing)
                        Text("Adds").frame(width: 70, alignment: .trailing); Text("Fails").frame(width: 60, alignment: .trailing)
                        Text("Verdict").frame(width: 160, alignment: .leading); Text("On").frame(width: 50, alignment: .center)
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    ForEach($servers) { $s in
                        Divider()
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) { Text(s.name).font(.bBody.weight(.medium)); Text(s.agents).font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(s.calls)").monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(s.tokens).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(s.fail).foregroundStyle(.secondary).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Tag(text: s.verdict, tone: s.tone).frame(width: 160, alignment: .leading)
                            Toggle("", isOn: $s.on).labelsHidden().toggleStyle(.switch).controlSize(.small).frame(width: 50)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            Note(text: "Turning a server off edits that agent's own config file. AI Keeper keeps a copy so you can turn it back on.")
        }
    }
}

// MARK: Hooks (sample data)

struct HooksView: View {
    private struct Hook: Identifiable { let id = UUID(); let name: String; let agent: String; let when: String; let runs: Int; let fail: String; let time: String; let tone: Tone; let verdict: String }
    private let hooks: [Hook] = [
        Hook(name: "prettier --check on edit", agent: "Claude Code", when: "After every file edit", runs: 288, fail: "17%", time: "0.9 s", tone: .amber, verdict: "Fails often"),
        Hook(name: "cargo fmt on save", agent: "Claude Code", when: "After every Rust edit", runs: 141, fail: "0%", time: "0.4 s", tone: .blue, verdict: "Healthy"),
        Hook(name: "notify when waiting", agent: "Codex", when: "When a reply is needed", runs: 33, fail: "0%", time: "0.1 s", tone: .blue, verdict: "Healthy"),
        Hook(name: "block production databases", agent: "Claude Code, Codex", when: "Before a shell command", runs: 96, fail: "0%", time: "0.1 s", tone: .blue, verdict: "Healthy"),
    ]
    var body: some View {
        Page(title: "Hooks", subtitle: "Commands that run around an agent's tool use", sample: true) {
            HStack(spacing: 12) {
                KPI(title: "Hooks", value: "4", prior: "across 2 agents")
                KPI(title: "Runs this month", value: "558")
                KPI(title: "Failure rate", value: "6.6%", prior: "all caused by prettier", delta: "+0.4 pts", good: false)
                KPI(title: "Time added to turns", value: "0.5 s", prior: "median")
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(hooks) { h in
                        ListRow(title: h.name, subtitle: "\(h.agent) · \(h.when)") { Dot(tone: h.tone) } trail: {
                            HStack(spacing: 14) {
                                Text("\(h.runs) runs").font(.bCaption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                                Text("\(h.fail) fail").font(.bCaption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                                Text(h.time).font(.bCaption).foregroundStyle(.secondary).monospacedDigit().frame(width: 50, alignment: .trailing)
                                Tag(text: h.verdict, tone: h.tone).frame(width: 100, alignment: .leading)
                                Button("Open") {}.controlSize(.small)
                            }
                        }
                        if h.id != hooks.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
            Note(text: "The prettier hook fails 17% of the time, and each failure costs the agent a retry. Fixing it once helps every session.")
        }
    }
}

// MARK: Budgets (your daily and weekly limits are real; the per-agent split is sample data)

struct BudgetsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("budget.daily") private var daily = 0.0
    @AppStorage("budget.weekly") private var weekly = 0.0
    private var spentToday: Double { TodayData.spentToday(store) }
    private var spentWeek: Double {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return store.usage.filter { $0.day >= from }.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        Page(title: "Budgets", subtitle: "Spend limits for you, then for each agent") {
            AdaptiveRow(spacing: 14) {
                limit("Daily budget", spent: spentToday, value: $daily, step: 5, max: 1000)
                limit("Weekly budget", spent: spentWeek, value: $weekly, step: 25, max: 5000)
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("By agent").font(.bHeadline); Spacer(); SampleChip() }.padding(.horizontal, 20).padding(.vertical, 14)
                    ForEach([("Claude Code", "Version 2.1", "$17.10 of $20", 0.85, AgentColor.claude), ("Codex", "Version 0.9", "$5.64 of $10", 0.56, AgentColor.codex),
                             ("Conductor", "Version 0.4", "No budget", 0, AgentColor.conductor), ("Pi", "Version 1.2", "No budget", 0, AgentColor.pi)], id: \.0) { a in
                        Divider()
                        HStack(spacing: 14) {
                            Circle().fill(a.4).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) { Text(a.0).font(.bBody.weight(.medium)); Text(a.1).font(.bCaption).foregroundStyle(.secondary) }.frame(width: 200, alignment: .leading)
                            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(a.3 > 0.8 ? Brand.reclaim : a.4).frame(width: max(0, g.size.width * a.3)) } }.frame(height: 6)
                            Text(a.2).font(.bCaption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            Button("Set") {}.controlSize(.small)
                        }.padding(.horizontal, 20).padding(.vertical, 10)
                    }
                }
            }
            GuardrailsCard()
        }
    }

    private func limit(_ title: String, spent: Double, value: Binding<Double>, step: Double, max: Double) -> some View {
        let on = value.wrappedValue > 0
        let f = on ? min(spent / value.wrappedValue, 1) : 0
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.bCallout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "$%.2f", spent)).font(.figure(40)).monospacedDigit()
                    Text(on ? String(format: "of $%.0f", value.wrappedValue) : "no limit set").font(.bBody).foregroundStyle(.secondary)
                }
                PixelMeter(value: f, tint: f > 0.8 ? Brand.reclaim : Brand.accent, height: 10)
                Stepper(value: value, in: 0...max, step: step) { Text(on ? "Limit **\(String(format: "$%.0f", value.wrappedValue))**" : "Limit **off**").font(.bCaption) }
            }
        }
    }
}

/// Rules that apply to every agent through its own config. Sample data until they can be written to each tool.
struct GuardrailsCard: View {
    @State private var rules: [(String, String, String, Bool)] = [
        ("Stop an agent that is idle for 30 minutes", "Frees its worktree for cleanup", "All agents", true),
        ("Ask before any session spends more than $10", "Pauses the session and notifies you", "All agents", true),
        ("Block shell commands that touch production databases", "Matches the hosts you list", "Claude Code, Codex", true),
        ("Remove a workspace after its PR merges", "Moves it to the Trash after 24 hours", "All agents", false),
    ]
    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack { VStack(alignment: .leading, spacing: 1) { Text("Guardrails").font(.bHeadline); Text("Applied to every agent through its own config").font(.bCaption).foregroundStyle(.secondary) }; Spacer(); SampleChip() }.padding(.horizontal, 20).padding(.vertical, 14)
                ForEach(rules.indices, id: \.self) { i in
                    Divider()
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 1) { Text(rules[i].0).font(.bBody.weight(.medium)); Text(rules[i].1).font(.bCaption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(rules[i].2).font(.bCaption).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(get: { rules[i].3 }, set: { rules[i].3 = $0 })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
        }
    }
}
