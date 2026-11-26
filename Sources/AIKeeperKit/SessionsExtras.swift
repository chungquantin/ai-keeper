import SwiftUI

// MARK: Logs (sample data)

struct LogsView: View {
    private enum Level: String, CaseIterable { case all = "All", warn = "Warnings", error = "Errors" }
    private struct Line: Identifiable {
        let id = UUID(); let time: String; let level: String; let source: String; let workspace: String; let message: String
        var tone: Tone { level == "error" ? .red : (level == "warn" ? .amber : (level == "ok" ? .green : .gray)) }
    }
    @State private var level: Level = .all
    @State private var query = ""
    @State private var paused = false

    private let lines: [Line] = [
        Line(time: "17:41:08", level: "warn", source: "Claude Code", workspace: "api-server", message: "permission requested: Bash(psql -f migrations/0042_retry.sql)"),
        Line(time: "17:40:52", level: "info", source: "Claude Code", workspace: "api-server", message: "tool_result Edit src/billing/retry.rs · 3 hunks applied"),
        Line(time: "17:40:31", level: "error", source: "Codex", workspace: "api-server", message: "cargo build failed: error[E0382]: borrow of moved value: `policy`"),
        Line(time: "17:40:12", level: "info", source: "Codex", workspace: "api-server", message: "running: cargo build --workspace"),
        Line(time: "17:39:47", level: "ok", source: "AI Keeper", workspace: "", message: "cleanup job 218 finished: 8.3 GB from web-app/target in 4.1 s"),
        Line(time: "17:39:20", level: "info", source: "Conductor", workspace: "mobile-app", message: "workspace mobile-onboarding synced with origin/main"),
        Line(time: "17:38:55", level: "error", source: "Claude Code", workspace: "web-app", message: "hook PostToolUse failed (exit 2): prettier --check src/export.ts"),
        Line(time: "17:38:10", level: "info", source: "Claude Code", workspace: "web-app", message: "tool_use Write src/export.ts · 212 lines"),
        Line(time: "17:37:42", level: "warn", source: "AI Keeper", workspace: "", message: "skill pdf-extract has a script that downloads and runs a remote file"),
        Line(time: "17:37:03", level: "info", source: "Codex", workspace: "api-server", message: "session perf-cache-layer resumed after 11 min idle"),
        Line(time: "17:36:30", level: "error", source: "Claude Code", workspace: "api-server", message: "MCP server github timed out after 30 s (request: list_pull_requests)"),
        Line(time: "17:35:58", level: "info", source: "AI Keeper", workspace: "", message: "scan finished: 16 workspaces, 108 GB reclaimable"),
    ]

    private var shown: [Line] {
        lines.filter { l in
            (level == .all || (level == .warn && l.level == "warn") || (level == .error && l.level == "error"))
                && (query.isEmpty || l.message.localizedCaseInsensitiveContains(query) || l.source.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Page(title: "Logs", subtitle: "Agent output, hooks and AI Keeper's own jobs", sample: true) {
            HStack(spacing: 10) {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search messages, agents, commands", text: $query).textFieldStyle(.plain) }
                    .padding(.horizontal, 10).frame(height: 30).frame(width: 340)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.border))
                Picker("Level", selection: $level) { ForEach(Level.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                HStack(spacing: 6) { Circle().fill(paused ? Brand.mutedForeground : AgentColor.good).frame(width: 7, height: 7); Text(paused ? "Paused" : "Live").font(.bCaption) }
                Button(paused ? "Resume" : "Pause") { paused.toggle() }.controlSize(.small)
                Button("Export") {}.controlSize(.small)
            }
            Card(padding: 14) {
                HStack(alignment: .bottom, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last 30 minutes").font(.bCaption).foregroundStyle(.secondary)
                        (Text("1,284 lines · ") + Text("9 errors").foregroundStyle(Brand.destructive)).font(.brand(18, .semibold))
                    }
                    StackedBars(data: (0..<60).map { [MockData.seeded($0, 9) > 0.86 ? 0.2 + MockData.seeded($0, 3) * 0.4 : 0, 0.2 + MockData.seeded($0, 1) * 0.8] },
                                colors: [Brand.destructive, Brand.muted.opacity(1)], height: 44)
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Text("Time").frame(width: 72, alignment: .leading); Text("Level").frame(width: 44, alignment: .leading)
                        Text("Source").frame(width: 110, alignment: .leading); Text("Workspace").frame(width: 120, alignment: .leading); Text("Message")
                        Spacer()
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    ForEach(shown) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(l.time).font(.code(12)).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                            Text(l.level).font(.code(11).weight(.medium)).foregroundStyle(l.tone.fg).frame(width: 44, alignment: .leading)
                            HStack(spacing: 6) { Circle().fill(AgentColor.of(l.source)).frame(width: 7, height: 7); Text(l.source).font(.bCaption) }.frame(width: 110, alignment: .leading)
                            Text(l.workspace).font(.code(12)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            Text(l.message).font(.code(12)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(l.level == "error" ? Brand.destructiveTint : .clear)
                    }
                    if shown.isEmpty { Text("No lines match.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                }
            }
        }
    }
}

// MARK: Prompts (sample data)

struct PromptsView: View {
    private struct P: Identifiable { let id = UUID(); let text: String; let meta: String; let words: Int; let turns: Int; let cost: String; let outcome: String; let tone: Tone }
    @State private var query = ""
    @State private var sort = 0

    private let prompts: [P] = [
        P(text: "Retry failed invoices with backoff and park them after five failures", meta: "api-server · Claude Code · today", words: 62, turns: 14, cost: "$6.12", outcome: "Running", tone: .blue),
        P(text: "Add a CSV export to the orders table. Reuse the existing Table component.", meta: "web-app · Claude Code · today", words: 41, turns: 9, cost: "$4.80", outcome: "Running", tone: .blue),
        P(text: "Make search faster", meta: "api-server · Codex · today", words: 4, turns: 22, cost: "$3.41", outcome: "Running", tone: .blue),
        P(text: "Index orders by customer and status. The slow query is in src/api/orders.rs.", meta: "api-server · Claude Code · yesterday", words: 57, turns: 6, cost: "$1.64", outcome: "Merged", tone: .violet),
        P(text: "Fix the flaky CI on Windows", meta: "web-app · Codex · yesterday", words: 7, turns: 31, cost: "$11.40", outcome: "Abandoned", tone: .gray),
        P(text: "Rename the scratch workspace and update the README links", meta: "web-app · Superset · yesterday", words: 14, turns: 3, cost: "$0.31", outcome: "Merged", tone: .violet),
        P(text: "Upgrade dependencies, then run cargo test and fix any type errors", meta: "docs-site · Claude Code · 2 days ago", words: 36, turns: 12, cost: "$1.12", outcome: "Failed", tone: .red),
        P(text: "Write release notes for 0.2.2 from the merged PRs", meta: "docs-site · Claude Code · 2 days ago", words: 24, turns: 4, cost: "$0.48", outcome: "Merged", tone: .violet),
    ]

    private var shown: [P] {
        var l = prompts.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        if sort == 1 { l.sort { ($0.outcome == "Merged" ? 0 : 1) < ($1.outcome == "Merged" ? 0 : 1) } }
        if sort == 2 { l.sort { $0.cost > $1.cost } }
        return l
    }

    var body: some View {
        Page(title: "Prompts", subtitle: "Every instruction you gave an agent, and how it turned out", sample: true) {
            HStack(spacing: 12) {
                ForEach([("Prompts that name a file", "2.1× more merged", "Than prompts that describe the feature only."),
                         ("Best length", "40 to 90 words", "Under 15 words ran 3.4 extra turns on average."),
                         ("Prompts with a test to pass", "31% cheaper", "Agents stop sooner when they have a finish line.")], id: \.0) { p in
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.0).font(.bCaption).foregroundStyle(.secondary)
                            Text(p.1).font(.brand(18, .semibold))
                            Text(p.2).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search your prompts", text: $query).textFieldStyle(.plain) }
                    .padding(.horizontal, 10).frame(height: 30).frame(width: 300)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.border))
                Spacer()
                Picker("Sort", selection: $sort) { Text("Newest").tag(0); Text("Best result").tag(1); Text("Costliest").tag(2) }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(shown) { p in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.text).font(.bBody.weight(.medium)).lineLimit(1)
                                Text(p.meta).font(.bCaption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(p.words) words").font(.bCaption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            Text("\(p.turns) turns").font(.bCaption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                            Text(p.cost).font(.bBody).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Tag(text: p.outcome, tone: p.tone).frame(width: 90, alignment: .leading)
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                        if p.id != shown.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(title: "What tends to work for you", note: "Found by comparing 212 sessions")
                    HStack(alignment: .top, spacing: 12) {
                        ForEach([("Name the file or the failing test", "Sessions that did this finished in 6 turns instead of 14."),
                                 ("Say when you are done", "\"Stop when cargo test passes\" cut cost by 31%."),
                                 ("Split prompts over 150 words", "Long prompts were abandoned twice as often.")], id: \.0) { t in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.0).font(.bBody.weight(.semibold))
                                Text(t.1).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}
