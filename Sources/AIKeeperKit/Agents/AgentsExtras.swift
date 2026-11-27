import SwiftUI

// MCP servers, Hooks and Budgets. The servers and hooks are read from each agent's own config files and are not changed from here.

// MARK: MCP servers

struct MCPView: View {
    @Environment(Store.self) private var store
    var body: some View {
        let a = store.advice.agg, servers = store.mcpServers
        let claude = servers.filter { $0.agent == "Claude Code" }
        let unused = Set(claude.map(\.name)).filter { (a.mcp[$0] ?? 0) == 0 }
        Page {
            KPIRow(items: [
                KPI(title: "Servers set up", value: "\(servers.count)", prior: "\(Set(servers.map(\.agent)).count) agent\(Set(servers.map(\.agent)).count == 1 ? "" : "s")"),
                KPI(title: "Calls in 30 days", value: "\(a.mcp.values.reduce(0, +))", prior: "from Claude Code sessions"),
                KPI(title: "Servers used", value: "\(a.mcp.count)", prior: "including ones no longer set up"),
                KPI(title: "Never called", value: "\(unused.count)", prior: unused.sorted().prefix(2).joined(separator: ", ")),
            ])
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Server").frame(maxWidth: .infinity, alignment: .leading); Text("Agent").frame(width: 110, alignment: .leading)
                        Text("Where").frame(width: 150, alignment: .leading); Text("Calls, 30 days").frame(width: 100, alignment: .trailing); Text("").frame(width: 150)
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    if servers.isEmpty { Divider(); Text("No MCP servers are set up in Claude Code or Codex.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                    ForEach(servers) { s in
                        let calls = s.agent == "Claude Code" ? a.mcp[s.name] ?? 0 : nil
                        Divider()
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) { Text(s.name).font(.bBody.weight(.medium)); Text(s.kind).font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.agent).font(.bCaption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(s.scope).font(.bCaption).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .leading)
                            Text(calls.map { "\($0)" } ?? "–").monospacedDigit().frame(width: 100, alignment: .trailing)
                            Group { if let calls { Tag(text: calls == 0 ? "Unused in 30 days" : "In use", tone: calls == 0 ? .amber : .blue) } else { Tag(text: "Not measured", tone: .gray) } }.frame(width: 150, alignment: .leading)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            Note(text: "Read from ~/.claude.json and ~/.codex/config.toml. To remove a server, use the agent's own command, for example `claude mcp remove <name>`. Calls are counted for Claude Code only.")
        }
    }
}

// MARK: Hooks

struct HooksView: View {
    @Environment(Store.self) private var store
    var body: some View {
        let a = store.advice.agg, hooks = store.hooks
        Page {
            KPIRow(items: [
                KPI(title: "Hooks set up", value: "\(hooks.count)", prior: "in Claude Code"),
                KPI(title: "Runs in 30 days", value: "\(a.hookRuns)", prior: "hooks that run when the agent stops"),
                KPI(title: "Failures", value: "\(a.hookErrors)", prior: a.hookRuns > 0 ? String(format: "%.1f%% of runs", a.hookFailRate * 100) : nil, good: a.hookErrors == 0 ? nil : false),
            ])
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Command").frame(maxWidth: .infinity, alignment: .leading); Text("Runs when").frame(width: 150, alignment: .leading)
                        Text("Matches").frame(width: 110, alignment: .leading); Text("Runs").frame(width: 60, alignment: .trailing); Text("Failed").frame(width: 60, alignment: .trailing)
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    if hooks.isEmpty { Divider(); Text("No hooks in ~/.claude/settings.json.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                    ForEach(hooks) { h in
                        let key = String(h.command.prefix(30))
                        let runs = a.hooks.first { $0.key.contains(key) }?.value, fails = a.hookFails.first { $0.key.contains(key) }?.value ?? 0
                        Divider()
                        HStack(spacing: 12) {
                            Text(h.command).font(.code(12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(h.command)
                            Text(h.event).font(.bCaption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                            Text(h.matcher.isEmpty ? "Everything" : h.matcher).font(.bCaption).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading)
                            Text(runs.map { "\($0)" } ?? "–").monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text("\(fails)").monospacedDigit().foregroundStyle(fails > 0 ? Brand.destructive : Color.secondary).frame(width: 60, alignment: .trailing)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }
            HStack {
                Button("Open settings.json") { NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/.claude/settings.json")) }
                Spacer()
                Text("Run counts are logged for hooks that fire when the agent stops. Others show a dash.").font(.bCaption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Budgets

enum AgentBudget {
    static func key(_ a: AgentTool) -> String { Prefs.Key.agentBudget(a.toolID) }
    static func get(_ a: AgentTool) -> Double { UserDefaults.standard.double(forKey: key(a)) }
}

struct BudgetsView: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.Key.budgetDaily) private var daily = 0.0
    @AppStorage(Prefs.Key.budgetWeekly) private var weekly = 0.0
    @AppStorage(Prefs.Key.agentBudget("claude")) private var claude = 0.0
    @AppStorage(Prefs.Key.agentBudget("codex")) private var codex = 0.0
    @AppStorage(Prefs.Key.agentBudget("pi")) private var pi = 0.0
    @State private var today: [AgentTool: Double] = [:]

    var body: some View {
        Page {
            AdaptiveRow(spacing: 14) {
                limit("Daily budget", spent: store.spentToday, value: $daily, step: 5, max: 1000)
                limit("Weekly budget", spent: store.spentWeek, value: $weekly, step: 25, max: 5000)
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle(title: "By agent, today", note: "A daily limit for each agent").padding(.horizontal, 20).padding(.vertical, 14)
                    agentRow(.claude, $claude); agentRow(.codex, $codex); agentRow(.pi, $pi)
                }
            }
            Note(text: "Budgets are a warning, not a block: AI Keeper shows the bar turning amber here, on Today and in Cost. It does not pause or stop an agent.")
        }
        .task(id: store.usage.count) {
            let rows = store.usage
            today = await Task.detached { () -> [AgentTool: Double] in
                let start = Calendar.current.startOfDay(for: Date()); var out: [AgentTool: Double] = [:]
                for r in rows where r.day >= start { out[r.agent, default: 0] += r.cost }
                return out
            }.value
        }
    }

    private func agentRow(_ a: AgentTool, _ budget: Binding<Double>) -> some View {
        let spent = today[a] ?? 0, b = budget.wrappedValue, f = b > 0 ? min(spent / b, 1) : 0
        return HStack(spacing: 14) {
            Circle().fill(AgentColor.of(a.rawValue)).frame(width: 9, height: 9)
            Text(Advisor.name(a)).font(.bBody.weight(.medium)).frame(width: 140, alignment: .leading)
            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(f >= 1 ? Brand.destructive : f > 0.8 ? Brand.reclaim : AgentColor.of(a.rawValue)).frame(width: max(0, g.size.width * f)) } }.frame(height: 6)
            Text(b > 0 ? String(format: "$%.2f of $%.0f", spent, b) : String(format: "$%.2f · no limit", spent)).font(.bCaption).foregroundStyle(.secondary).monospacedDigit().frame(width: 130, alignment: .trailing)
            Stepper("", value: budget, in: 0...500, step: 5).labelsHidden()
        }.padding(.horizontal, 20).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
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
                PixelMeter(value: f, tint: f >= 1 ? Brand.destructive : Brand.accent, height: 9, warnTail: f > 0.8 && f < 1, segments: 24)
                Stepper(value: value, in: 0...max, step: step) { Text(on ? "Limit **\(String(format: "$%.0f", value.wrappedValue))**" : "Limit **off**").font(.bCaption) }
            }
        }
    }
}
