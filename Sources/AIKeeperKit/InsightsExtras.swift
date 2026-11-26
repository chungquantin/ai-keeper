import SwiftUI

private let agentColors = [AgentColor.claude, AgentColor.codex, AgentColor.conductor, AgentColor.superset, AgentColor.pi]

/// One date range and one compare setting for every Insights tab.
private struct InsightsToolbar: View {
    @State private var showCatalog = false
    var body: some View {
        HStack(spacing: 8) {
            FilterPills(items: ["Last 30 days", "Compare to previous period", "All agents", "All workspaces"])
            Button("Customize metrics") { showCatalog = true }.controlSize(.small)
        }.sheet(isPresented: $showCatalog) { MetricsCatalogSheet() }
    }
}

// MARK: Speed

struct SpeedView: View {
    var body: some View {
        Page(title: "Speed", subtitle: "How long agents take, and where the time goes", action: "Export", sample: true) {
            InsightsToolbar()
            VStack(alignment: .leading, spacing: 8) {
                Text("A typical session finishes 4.1 minutes sooner than the week before, down 11%.").font(.brand(24, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Thinking time fell 3.2 min. Waiting on you rose 0.4 min. Largest step: time before the first edit, down 2.1 min.").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(["Nov 20  Claude Code 2.1 installed", "Nov 23  CLAUDE.md edited in api-server", "Nov 24  Codex switched to GPT-5"], id: \.self) { e in
                        Text(e).font(.brand(12, .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Brand.card, in: Capsule()).overlay(Capsule().strokeBorder(Brand.border))
                    }
                }
            }
            AdaptiveRow(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(title: "Where the change came from", note: "median session, 38 min to 34 min")
                        ForEach(phases, id: \.0) { p in
                            HStack(spacing: 12) {
                                HStack(spacing: 8) { Circle().fill(p.1).frame(width: 8, height: 8); Text(p.0).font(.bBody) }.frame(width: 170, alignment: .leading)
                                GeometryReader { g in
                                    let half = g.size.width / 2, w = half * min(abs(p.2) / 4, 1)
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(Brand.border).frame(width: 1, height: 22).position(x: half, y: g.size.height / 2)
                                        RoundedRectangle(cornerRadius: 3).fill(p.1).frame(width: w, height: 8).offset(x: p.2 < 0 ? half - w : half)
                                    }
                                }.frame(height: 22)
                                Text(String(format: "%@%.1f min", p.2 < 0 ? "−" : "+", abs(p.2))).font(.bBody).monospacedDigit().foregroundStyle(p.2 < 0 ? AgentColor.good : Brand.reclaimText).frame(width: 78, alignment: .trailing)
                            }.padding(.vertical, 4)
                            Divider()
                        }
                        Text("Each phase is its own median, so the phases do not add up to the whole session.").font(.bCaption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: "Where a slow session spends its time", note: "p90 session, 1 h 12 min")
                        GeometryReader { g in
                            HStack(spacing: 2) { ForEach(stack, id: \.0) { s in Rectangle().fill(s.2).frame(width: max(0, (g.size.width - 8) * s.1 / 100)) } }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.frame(height: 56)
                        HStack(alignment: .top) { ForEach(stack, id: \.0) { s in VStack(alignment: .leading, spacing: 1) { Text(s.3).font(.brand(15, .semibold)); Text(s.0).font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) } }
                        Note(text: "Waiting on you is 21 min of this session. A notification when an agent needs a reply would give most of that back.")
                    }
                }.frame(width: 380)
            }
            KPIRow(items: [
                KPI(title: "Time to first edit", value: "4.8 min", delta: "−30%", good: true, spark: MockData.series(12, 1)),
                KPI(title: "Turn time p95", value: "58 s", delta: "−8%", good: true, spark: MockData.series(12, 2)),
                KPI(title: "Session length", value: "34 min", delta: "−11%", good: true, spark: MockData.series(12, 3)),
                KPI(title: "Output speed", value: "71 tok/s", delta: "−9%", good: false, spark: MockData.series(12, 4)),
                KPI(title: "Useful turns", value: "78%", delta: "+3 pts", good: true, spark: MockData.series(12, 5)),
            ])
            Text("How speed scales with the task").font(.bHeadline)
            Card(padding: 0) {
                HStack(spacing: 0) {
                    ForEach(shapes.indices, id: \.self) { i in
                        let s = shapes[i]
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { Circle().fill(s.2).frame(width: 8, height: 8); Text(s.0).font(.bHeadline); Text(s.1).font(.bCaption).foregroundStyle(.secondary) }
                            (Text(s.3).font(.brand(24, .semibold)) + Text(" of turns").font(.bCaption).foregroundStyle(.secondary))
                            kv("First token p50 · p95", s.4); kv("Output speed p50", s.5); kv("Useful turns", s.6)
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        if i < shapes.count - 1 { Divider() }
                    }
                }
            }
            AdaptiveRow(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(title: "Context size to first token")
                        LineChart(lines: [.init(values: (0..<12).map { 0.12 + Double($0) * 0.05 }, color: Brand.mutedForeground),
                                          .init(values: (0..<12).map { 0.32 + Double($0) * 0.055 }, color: Brand.reclaim)], height: 170)
                        Legend(items: [("p50", Brand.mutedForeground), ("p95", Brand.reclaim)])
                        Note(text: "1.4 s plus 37 ms per 1k tokens up to 100k. Cache hits cut it by 54%.")
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(title: "Slowest corners of the task space", note: "p95 turn time")
                        Heatgrid(rows: Self.slowGrid, color: Brand.reclaim, cell: 22)
                        Note(text: "The slowest corner is reading over 200k tokens and writing over 4k. It is 6% of turns and 31% of waiting.")
                    }
                }
            }
            SpeedTrends()
        }
    }

    private static let slowGrid: [[Double]] = {
        var rows: [[Double]] = []
        for r in 0..<7 {
            var row: [Double] = []
            for c in 0..<10 {
                let across: Double = Double(c) / 9.0 * 0.65
                let down: Double = Double(6 - r) / 6.0 * 0.45
                let noise: Double = MockData.seeded(r * 10 + c, 5) * 0.12
                row.append(min(1.0, across + down + noise))
            }
            rows.append(row)
        }
        return rows
    }()

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.bCaption)
    }
    private let phases: [(String, Color, Double)] = [
        ("Waiting to start", AgentColor.claude, -0.2), ("Thinking before an edit", AgentColor.conductor, -2.1),
        ("Writing output", AgentColor.superset, -0.9), ("Running tools and tests", AgentColor.codex, -0.3), ("Waiting on you", Brand.reclaim, 0.4)]
    private let stack: [(String, Double, Color, String)] = [
        ("Waiting to start", 3, AgentColor.claude, "2 min"), ("Thinking", 38, AgentColor.conductor, "27 min"), ("Writing", 17, AgentColor.superset, "12 min"),
        ("Tools and tests", 12, AgentColor.codex, "9 min"), ("Waiting on you", 30, Brand.reclaim, "21 min")]
    private let shapes: [(String, String, Color, String, String, String, String)] = [
        ("Quick edits", "Small read, small write", AgentColor.claude, "41%", "0.9 s · 4.1 s", "96 tok/s", "84%"),
        ("Big reads", "Large read, small write", AgentColor.codex, "33%", "2.4 s · 14 s", "88 tok/s", "81%"),
        ("Long writes", "Small read, large write", AgentColor.superset, "9%", "1.1 s · 5 s", "64 tok/s", "72%"),
        ("Deep dives", "Large read, large write", AgentColor.conductor, "17%", "6.4 s · 53 s", "41 tok/s", "58%")]
}

// MARK: Reliability

struct ReliabilityView: View {
    var body: some View {
        Page(title: "Reliability", subtitle: "What fails, what loops, and what costs you retries", action: "Set an alert", sample: true) {
            InsightsToolbar()
            KPIRow(items: [
                KPI(title: "Failed tool calls", value: "10.4%", prior: "vs. 9.1% prior", delta: "+1.3 pts", good: false),
                KPI(title: "Retries per task", value: "1.8", prior: "vs. 2.1 prior", delta: "−14%", good: true),
                KPI(title: "Loops caught", value: "7", prior: "vs. 4 prior", delta: "+3", good: false),
                KPI(title: "Edits you rejected", value: "6%", prior: "vs. 8% prior", delta: "−2 pts", good: true),
                KPI(title: "Hook failures", value: "3.2%", prior: "vs. 3.0% prior", delta: "+0.2 pts"),
                KPI(title: "Timeouts", value: "9", prior: "MCP and shell", delta: "+2", good: false),
            ])
            AdaptiveRow(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(title: "Failed tool calls per day", note: "By kind")
                        StackedBars(data: (0..<14).map { d in (0..<4).map { k in 0.1 + MockData.seeded(d, k) * (k == 0 ? 0.8 : k == 1 ? 0.45 : 0.25) } },
                                    colors: [Brand.destructive, Brand.reclaim, Brand.merged, AgentColor.pi])
                        Legend(items: [("Tests and builds", Brand.destructive), ("Hooks and linters", Brand.reclaim), ("Permission denied", Brand.merged), ("Timeouts", AgentColor.pi)])
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: "Failure rate by agent", note: "Share of tool calls")
                        HBar(label: "Claude Code", value: "10.9%", fraction: 0.78, color: AgentColor.claude)
                        HBar(label: "Codex", value: "12.7%", fraction: 0.91, color: AgentColor.codex)
                        HBar(label: "Conductor", value: "6.1%", fraction: 0.44, color: AgentColor.conductor)
                        HBar(label: "Pi", value: "4.0%", fraction: 0.29, color: AgentColor.pi)
                    }
                }.frame(width: 360)
            }
            AdaptiveRow(spacing: 14) {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) { Text("Loops caught").font(.bHeadline); Text("The same command or edit repeated with no progress").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                        ForEach(loops.indices, id: \.self) { i in
                            HStack(spacing: 12) {
                                Dot(tone: .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loops[i].0).font(.bBody.weight(.medium)).lineLimit(1)
                                    Text(loops[i].1).font(.code(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Text(loops[i].2).font(.bBody.weight(.semibold)).monospacedDigit().frame(width: 34, alignment: .trailing)
                                Text(loops[i].3).font(.bCaption).foregroundStyle(.secondary).monospacedDigit().frame(width: 48, alignment: .trailing)
                            }.padding(.horizontal, 18).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
                        }
                    }
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) { Text("Commands that fail most").font(.bHeadline); Text("Worth fixing once so every agent benefits").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                        ForEach(cmds.indices, id: \.self) { i in
                            HStack(spacing: 12) {
                                Text(cmds[i].0).font(.code(12)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(cmds[i].1).font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                                Text(cmds[i].2).font(.bBody.weight(.semibold)).monospacedDigit().foregroundStyle(cmds[i].3 ? Brand.destructive : Brand.reclaimText).frame(width: 44, alignment: .trailing)
                            }.padding(.horizontal, 18).padding(.vertical, 11).overlay(alignment: .top) { Divider() }
                        }
                    }
                }
            }
        }
    }

    private let loops: [(String, String, String, String)] = [
        ("Re-ran the same failing test 9 times", "cargo test billing::retry_exhausts_after_five", "9×", "$1.40"),
        ("Edited the same file back and forth", "web/src/export.ts · 6 edits, same lines", "6×", "$0.90"),
        ("Retried a timed-out MCP call", "github list_pull_requests", "5×", "$0.31"),
        ("Re-read the same large file", "src/api/orders.rs · 4 reads in 10 min", "4×", "$0.62")]
    private let cmds: [(String, String, String, Bool)] = [
        ("cargo test", "412 runs", "23%", true), ("prettier --check", "288 runs", "17%", true), ("npm run build", "174 runs", "11%", false), ("psql", "96 runs", "9%", false)]
}

// MARK: Context and cache

struct ContextView: View {
    var body: some View {
        Page(title: "Context and cache", subtitle: "How full the window gets, and what the cache saves", sample: true) {
            InsightsToolbar()
            KPIRow(items: [
                KPI(title: "Context used at the end", value: "64%", prior: "of the window", delta: "+3 pts"),
                KPI(title: "Sessions over 80%", value: "22", prior: "of 231", delta: "+5", good: false),
                KPI(title: "Compactions", value: "31", prior: "summaries of old turns", delta: "+9"),
                KPI(title: "Cache hit rate", value: "78%", prior: "vs. 71% prior", delta: "+7 pts", good: true),
                KPI(title: "Saved by the cache", value: "$61.40", prior: "this week", delta: "+$9.20", good: true),
            ])
            AdaptiveRow(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(title: "How full the window gets, turn by turn", note: "Each line is one session")
                        LineChart(lines: Self.fillLines, height: 190, events: [])
                        Note(text: "Sessions that pass 80% before turn 40 cost 2.3× as much and are abandoned twice as often. Starting a fresh session around 70% would have saved about $18 this week.")
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: "What fills the window", note: "Median at turn 30")
                        GeometryReader { g in
                            HStack(spacing: 2) { ForEach(fill, id: \.0) { f in Rectangle().fill(f.2).frame(width: max(0, (g.size.width - 8) * f.1 / 100)) } }.clipShape(RoundedRectangle(cornerRadius: 10))
                        }.frame(height: 34)
                        ForEach(fill, id: \.0) { f in HStack { Circle().fill(f.2).frame(width: 8, height: 8); Text(f.0).font(.bBody); Spacer(); Text("\(Int(f.1))%").foregroundStyle(.secondary).monospacedDigit() } }
                    }
                }.frame(width: 360)
            }
            AdaptiveRow(spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: "Cache by agent", note: "Cached input as a share of all input")
                        HBar(label: "Claude Code", value: "81%  saved $41.20", fraction: 0.81, color: AgentColor.claude)
                        HBar(label: "Codex", value: "69%  saved $14.80", fraction: 0.69, color: AgentColor.codex)
                        HBar(label: "Conductor", value: "74%  saved $4.10", fraction: 0.74, color: AgentColor.conductor)
                        HBar(label: "Pi", value: "42%  saved $1.30", fraction: 0.42, color: AgentColor.pi)
                    }
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) { Text("Habits that break the cache").font(.bHeadline); Text("Each one made the next turn re-read everything").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
                        ForEach(breaks.indices, id: \.self) { i in
                            ListRow(title: breaks[i].0, subtitle: breaks[i].1) { Dot(tone: .amber) } trail: { Text(breaks[i].2).font(.bCaption).foregroundStyle(.secondary) }
                            if i < breaks.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }
                }
            }
        }
    }
    private static let fillLines: [LineChart.Line] = {
        func ramp(_ n: Int, _ slope: Double) -> [Double] { (0..<n).map { min(0.97, 0.05 + Double($0) * slope) } }
        var compacted: [Double] = []
        for i in 0..<34 { compacted.append(i < 20 ? 0.05 + Double(i) * 0.04 : 0.2 + Double(i - 20) * 0.03) }
        return [LineChart.Line(values: ramp(30, 0.03), color: AgentColor.claude), LineChart.Line(values: ramp(26, 0.035), color: AgentColor.codex),
                LineChart.Line(values: compacted, color: AgentColor.conductor), LineChart.Line(values: ramp(20, 0.02), color: AgentColor.superset)]
    }()
    private let fill: [(String, Double, Color)] = [("Files the agent read", 46, AgentColor.claude), ("Tool output", 24, AgentColor.codex), ("Conversation", 15, AgentColor.conductor),
                                                    ("Project instructions and skills", 9, AgentColor.superset), ("Thinking", 6, AgentColor.pi)]
    private let breaks: [(String, String, String)] = [
        ("Pausing longer than 5 minutes", "The cache expires, so the next turn pays full price.", "14 times"),
        ("Switching model mid-session", "A new model starts with an empty cache.", "6 times"),
        ("Editing CLAUDE.md during a session", "Changes the start of every later request.", "4 times"),
        ("Reordering MCP servers", "Changes the tool list the cache is keyed on.", "2 times")]
}

// MARK: Advisor

struct AdvisorView: View {
    @EnvironmentObject var nav: NavState
    @Environment(\.pageWidth) private var pageWidth
    private let agents = ["Claude Code", "Codex", "Conductor", "Pi"]
    private struct Row: Identifiable { let id = UUID(); let task: String; let n: Int; let cells: [(String, String)?]; let best: Int; let tip: String }
    private let rows: [Row] = [
        Row(task: "Fix a bug", n: 64, cells: [("88%", "$1.20 · 9 min"), ("74%", "$1.90 · 15 min"), ("81%", "$1.40 · 11 min"), nil], best: 0, tip: "Keep Claude Code"),
        Row(task: "Add a feature", n: 41, cells: [("71%", "$4.10 · 28 min"), ("79%", "$3.20 · 24 min"), ("68%", "$3.90 · 31 min"), nil], best: 1, tip: "Try Codex first. About $0.90 cheaper."),
        Row(task: "Refactor", n: 33, cells: [("76%", "$5.60 · 36 min"), ("52%", "$7.30 · 51 min"), ("70%", "$5.90 · 40 min"), nil], best: 0, tip: "Keep Claude Code"),
        Row(task: "Write tests", n: 29, cells: [("69%", "$1.10 · 8 min"), ("83%", "$0.80 · 6 min"), ("64%", "$1.20 · 9 min"), ("77%", "$0.40 · 12 min")], best: 1, tip: "Move to Codex. Pi is cheapest if you can wait."),
        Row(task: "Docs and release notes", n: 24, cells: [("91%", "$0.50 · 4 min"), ("88%", "$0.60 · 5 min"), nil, ("90%", "$0.12 · 7 min")], best: 3, tip: "Use Pi. Same result for a fifth of the cost."),
        Row(task: "Debug CI", n: 19, cells: [("44%", "$8.40 · 47 min"), ("29%", "$11.40 · 61 min"), nil, nil], best: 0, tip: "Hard for every agent. Start fresh at 70% context."),
        Row(task: "Database migrations", n: 13, cells: [("85%", "$2.30 · 14 min"), ("61%", "$2.80 · 22 min"), nil, nil], best: 0, tip: "Keep Claude Code"),
    ]
    private let harness: [(String, String, String, String, String, Tone)] = [
        ("github", "MCP server · Claude Code", "312 calls", "4.2K tokens", "Keep", .blue),
        ("postgres", "MCP server · Claude Code and Codex", "96 calls", "2.9K tokens", "Keep", .blue),
        ("linear", "MCP server · Claude Code", "0 calls", "3.8K tokens", "Unused for 60 days", .amber),
        ("frontend-design", "Skill · Claude Code", "22 loads", "1.1K tokens", "Keep", .blue),
        ("pdf-extract", "Skill · Codex", "0 loads", "0.9K tokens", "Unused, risky script", .red),
        ("prettier on edit", "Hook · Claude Code", "288 runs", "0", "Fails 17% of the time", .amber)]

    var body: some View {
        Page(title: "Advisor", subtitle: "What your own history says about which agent and tools to use", action: "How this is worked out", sample: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Switching 5 kinds of task to the agent that did them best would save about $64 a month.").font(.brand(24, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Based on 231 sessions in the last 30 days. Where there is too little history, the cell says so instead of guessing.").foregroundStyle(.secondary)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    CardTitle(title: "Which agent to use for which task", note: "Merged rate, cost and median time. Highlighted is the best fit for you.").padding(.horizontal, 20).padding(.vertical, 14)
                    Divider()
                    HStack(spacing: 10) {
                        Text("Kind of task").frame(width: 180, alignment: .leading); Text("Sessions").frame(width: 60, alignment: .trailing)
                        ForEach(agents, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                        if pageWidth >= 980 { Text("Suggestion").frame(width: 190, alignment: .leading) }
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
                    ForEach(rows) { r in
                        Divider()
                        HStack(spacing: 10) {
                            Text(r.task).font(.bBody.weight(.medium)).frame(width: 180, alignment: .leading)
                            Text("\(r.n)").font(.bCaption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                            ForEach(0..<4, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 1) {
                                    if let c = r.cells[i] {
                                        Text(c.0).font(.brand(15, .semibold)).foregroundStyle(i == r.best ? Brand.primaryText : .primary)
                                        Text(c.1).font(.bCaption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Too few").font(.bBody).foregroundStyle(.tertiary); Text("under 5 sessions").font(.bCaption).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(i == r.best ? Brand.primaryTint : Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            if pageWidth >= 980 { Text(r.tip).font(.bCaption).foregroundStyle(.secondary).frame(width: 190, alignment: .leading) }
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    CardTitle(title: "Harness tools: what earns its place", note: "Skills, MCP servers and hooks across your agents").padding(.horizontal, 20).padding(.vertical, 14)
                    ForEach(harness.indices, id: \.self) { i in
                        Divider()
                        ListRow(title: harness[i].0, subtitle: harness[i].1) { EmptyView() } trail: {
                            HStack(spacing: 14) {
                                Text(harness[i].2).font(.bBody).monospacedDigit().frame(width: 80, alignment: .trailing)
                                Text(harness[i].3).font(.bCaption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                                Tag(text: harness[i].4, tone: harness[i].5).frame(width: 150, alignment: .leading)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Open MCP servers") { nav.open(.agents, .mcp) }
                Button("Open hooks") { nav.open(.agents, .hooks) }
                Spacer()
            }
        }
    }
}

// MARK: Speed, over time and against last week (sample data)

struct SpeedTrends: View {
    private struct Chart: Identifiable { let id = UUID(); let title: String; let value: String; let color: Color; let k: Int }
    private let charts: [Chart] = [
        Chart(title: "Time to first edit", value: "4.8 min", color: AgentColor.codex, k: 1), Chart(title: "Turn time", value: "38 s", color: AgentColor.superset, k: 2),
        Chart(title: "Session length", value: "34 min", color: AgentColor.claude, k: 3), Chart(title: "Output speed", value: "71 tok/s", color: AgentColor.conductor, k: 4),
        Chart(title: "Turns per hour", value: "27", color: Brand.mutedForeground, k: 5)]
    private let table: [(String, String, String, String, String, String, Bool)?] = [
        nil,
        ("Time to first edit p50", "From your prompt to the first file change", "6.9 min", "4.8 min", "30% lower", "1,214 → 1,402", true),
        ("Turn time p95", "Model call, start to last token", "63 s", "58 s", "8% lower", "9,120 → 10,344", true),
        ("Session length p50", "First prompt to last message", "38 min", "34 min", "11% lower", "212 → 231", true),
        ("Useful turns", "A turn that edited a file or passed a test", "75%", "78%", "3 pts higher", "9,120 → 10,344", true),
        ("Failed commands", "Non-zero exit", "9.1%", "10.4%", "1.3 pts higher", "6,402 → 7,118", false),
        ("Cost per session p50", "At public API list prices", "$1.52", "$1.71", "12% higher", "212 → 231", false)]
    private let slow: [(String, String, [Double], String)] = [
        ("Investigate flaky CI on Windows runners", "Codex · web-app", [1, 14, 6, 1], "24 min"), ("Refactor billing webhooks for idempotency", "Claude Code · api-server", [1, 12, 4, 2], "20 min"),
        ("Upgrade dependencies and fix types", "Claude Code · docs-site", [1, 9, 7, 0], "18 min"), ("Design review: namespace analytics cards", "Claude Code · web-app", [1, 11, 2, 3], "15 min"),
        ("Cache layer for product search", "Codex · api-server", [1, 8, 4, 0], "13 min")]
    private let needs: [(String, String)] = [
        ("Stalls inside a turn", "Gaps over 1 s between streamed chunks. Needs a chunk timestamp from the agent."),
        ("Queue wait at the provider", "Time before a request starts running. Needs the provider request id."),
        ("Time to first useful token", "First token minus thinking time. Needs the end of the thinking block.")]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Over time").font(.bHeadline)
                Text("Dashed line: the period before. Dotted verticals: things you changed.").font(.bCaption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(charts) { c in
                    Card(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) { Circle().fill(c.color).frame(width: 8, height: 8); Text(c.title).font(.bBody.weight(.semibold)); Spacer(); Text(c.value).font(.bCaption).foregroundStyle(.secondary) }
                                .padding(.horizontal, 18).padding(.vertical, 11)
                            Divider()
                            LineChart(lines: [.init(values: MockData.series(50, c.k + 40, base: 0.5, spread: 0.2), color: c.color, dashed: true, width: 1.5),
                                              .init(values: MockData.series(50, c.k, base: 0.5, spread: 0.22), color: c.color)], height: 110, events: [0.25, 0.7])
                                .padding(.horizontal, 18).padding(.vertical, 10)
                        }
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) { Text("This week against the week before").font(.bHeadline); Text("Green is faster or better. Orange is slower or worse.").font(.bCaption).foregroundStyle(.secondary) }
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(table.indices.dropFirst(), id: \.self) { i in
                        if let r = table[i] {
                            Divider()
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 1) { Text(r.0).font(.bBody.weight(.medium)); Text(r.1).font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 1) { Text(r.2).monospacedDigit(); Text(r.5.components(separatedBy: " → ")[0] + " samples").font(.bCaption).foregroundStyle(.secondary) }.frame(width: 130, alignment: .trailing)
                                VStack(alignment: .trailing, spacing: 1) { Text(r.3).monospacedDigit(); Text(r.5.components(separatedBy: " → ")[1] + " samples").font(.bCaption).foregroundStyle(.secondary) }.frame(width: 130, alignment: .trailing)
                                Text(r.4).font(.bBody.weight(.medium)).foregroundStyle(r.6 ? AgentColor.good : Brand.reclaimText)
                                    .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 120, alignment: .trailing)
                                    .background(r.6 ? AgentColor.good.opacity(0.12) : Brand.reclaimTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }.padding(.horizontal, 20).padding(.vertical, 8)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) { Text("Slowest turns").font(.bHeadline); Text("One turn, start to finish. The parts add up to the total.").font(.bCaption).foregroundStyle(.secondary) }
                    ForEach(slow.indices, id: \.self) { i in
                        let s = slow[i]
                        Divider()
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 1) { Text(s.0).font(.bBody.weight(.medium)).lineLimit(1); Text(s.1).font(.bCaption).foregroundStyle(.secondary) }.frame(width: 300, alignment: .leading)
                            GeometryReader { g in
                                let total = s.2.reduce(0, +)
                                let cols: [Color] = [AgentColor.claude, AgentColor.conductor, AgentColor.codex, Brand.reclaim]
                                HStack(spacing: 1) { ForEach(s.2.indices, id: \.self) { j in Rectangle().fill(cols[j]).frame(width: max(0, g.size.width * s.2[j] / total)) } }.clipShape(RoundedRectangle(cornerRadius: 3))
                            }.frame(height: 10)
                            Text(s.3).font(.bBody).monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                    }
                    Legend(items: [("Before first token", AgentColor.claude), ("Thinking", AgentColor.conductor), ("Tools", AgentColor.codex), ("Waiting on you", Brand.reclaim)])
                }
            }
            VStack(alignment: .leading, spacing: 2) { Text("Needs more data first").font(.bHeadline); Text("Not measurable from session files yet. A one-line hook per agent would add them.").font(.bCaption).foregroundStyle(.secondary) }
            AdaptiveRow(spacing: 14) {
                ForEach(needs, id: \.0) { n in
                    Card(padding: 14) { VStack(alignment: .leading, spacing: 4) { Text(n.0).font(.bBody.weight(.semibold)); Text(n.1).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
                }
            }
        }
    }
}
