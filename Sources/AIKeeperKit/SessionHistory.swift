import SwiftUI

/// Sessions › History. Real sessions from the agents' logs, in the redesigned layout: an activity chart,
/// filters, rows grouped by day, and a panel for the one you pick. Outcomes and summaries are sample data until they can be worked out.
struct SessionHistoryView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var tool: AgentTool?
    @State private var orphansOnly = false
    @State private var matches: Set<String>?
    @State private var searching = false
    @State private var selected: String?
    @State private var pendingDelete: SessionInfo?
    @State private var detailTab = 0
    @State private var sheet: SessionSheet?

    enum SessionSheet: Identifiable { case share(SessionInfo), compare(SessionInfo); var id: String { switch self { case .share: "s"; case .compare: "c" } } }

    private var rows: [SessionInfo] {
        store.sessions.filter { s in
            (tool == nil || s.agent == tool) && (!orphansOnly || !s.cwdExists) &&
            (query.isEmpty || matches == nil ? (query.isEmpty || s.title.localizedCaseInsensitiveContains(query) || s.project.localizedCaseInsensitiveContains(query))
                                             : (matches!.contains(s.file) || s.title.localizedCaseInsensitiveContains(query)))
        }.sorted { $0.last > $1.last }
    }

    /// Sample outcome, steady for a given session so the screen does not flicker between redraws.
    static func outcome(_ s: SessionInfo) -> (String, Tone) {
        let h = abs(s.sessionID.hashValue) % 10
        if Date().timeIntervalSince(s.last) < 900 { return ("Running", .blue) }
        switch h { case 0, 1, 2, 3, 4: return ("Merged", .violet); case 5, 6: return ("Abandoned", .gray); case 7: return ("Failed", .red); default: return ("Open", .blue) }
    }

    private func dayLabel(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "Today" }
        if c.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month().day())
    }

    var body: some View {
        let rows = self.rows
        let pick = rows.first { $0.id == selected } ?? rows.first
        GeometryReader { geo in
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        activity
                        filters(rows)
                        table(rows, pick: pick)
                    }.padding(.horizontal, 28).padding(.vertical, 14)
                }
            }
            if let pick, geo.size.width >= 980 {
                Divider()
                inspector(pick).frame(width: 340)
            }
        }
        }
        .onChange(of: query) { _, q in search(q) }
        .sheet(item: $sheet) { sh in
            switch sh {
            case .share(let s): ShareSheet(session: s)
            case .compare(let s): CompareSheet(session: s)
            }
        }
        .confirmationDialog("Move this session log to Trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let s = pendingDelete { try? FileManager.default.trashItem(at: URL(fileURLWithPath: s.file), resultingItemURL: nil); store.loadUsage() }
                pendingDelete = nil
            }
        } message: { Text(pendingDelete?.title ?? "") }
    }

    // MARK: Activity chart (real: sessions per day by agent)

    private var activity: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<60).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let data: [[Double]] = days.map { d in
            [AgentTool.claude, .codex, .pi].map { t in Double(store.sessions.filter { $0.agent == t && cal.isDate($0.last, inSameDayAs: d) }.count) }
        }
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    (Text("\(store.sessions.count)").font(.bBody.weight(.bold)) + Text(" sessions in the last 60 days").font(.bBody).foregroundStyle(.secondary))
                    SampleChip(text: "Outcomes are samples").fixedSize()
                    Spacer()
                    Legend(items: [("Claude", AgentColor.claude), ("Codex", AgentColor.codex), ("Pi", AgentColor.pi)])
                }
                StackedBars(data: data, colors: [AgentColor.claude, AgentColor.codex, AgentColor.pi], height: 54)
            }
        }
    }

    private func filters(_ rows: [SessionInfo]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles, or text inside conversations", text: $query).textFieldStyle(.plain)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).frame(height: 30).frame(minWidth: 160, maxWidth: 300)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.border))
            Picker("", selection: $tool) { Text("All agents").tag(AgentTool?.none); ForEach(AgentTool.enabled, id: \.self) { Text($0.rawValue).tag(AgentTool?.some($0)) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            Toggle("Folder deleted", isOn: $orphansOnly).toggleStyle(.checkbox).fixedSize()
            Spacer(minLength: 0)
        }
    }

    // MARK: Table

    private func table(_ rows: [SessionInfo], pick: SessionInfo?) -> some View {
        let groups = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.last) }.sorted { $0.key > $1.key }
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Started").frame(width: 56, alignment: .leading); Text("Title"); Spacer()
                    Text("Agent").frame(width: 80, alignment: .leading); Text("Outcome").frame(width: 90, alignment: .leading)
                    Text("Cost").frame(width: 56, alignment: .trailing); Text("Updated").frame(width: 86, alignment: .trailing)
                }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if rows.isEmpty {
                    Text(store.usageLoading ? "Reading sessions…" : "No sessions match.").font(.bCaption).foregroundStyle(.secondary).padding(24)
                }
                ForEach(groups, id: \.key) { day, list in
                    Text(dayLabel(day)).font(.brand(12, .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted)
                    ForEach(list) { s in
                        let o = Self.outcome(s)
                        Button { selected = s.id } label: {
                            HStack(spacing: 14) {
                                Text(s.first.formatted(date: .omitted, time: .shortened)).font(.bCaption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title.isEmpty ? s.project : s.title).font(.bBody.weight(.medium)).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(s.project)
                                        if !s.cwdExists { Tag(text: "Folder deleted", tone: .gray) }
                                    }.font(.bCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 6) { Circle().fill(AgentColor.of(s.agent.rawValue)).frame(width: 7, height: 7); Text(s.agent.rawValue).font(.bCaption).foregroundStyle(.secondary) }.frame(width: 80, alignment: .leading)
                                Tag(text: o.0, tone: o.1).frame(width: 90, alignment: .leading)
                                Text(String(format: "$%.2f", s.cost)).font(.bBody).monospacedDigit().frame(width: 56, alignment: .trailing)
                                Text(s.last.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))).font(.bCaption).foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(pick?.id == s.id ? Brand.primaryTint : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Resume in Terminal") { Resume.open(s) }.disabled(!s.cwdExists)
                            Button("Reveal log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.file)]) }
                            Button("Copy session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.sessionID, forType: .string) }
                            Divider()
                            Button("Move log to Trash…", role: .destructive) { pendingDelete = s }
                        }
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    // MARK: Detail panel

    private func inspector(_ s: SessionInfo) -> some View {
        let o = Self.outcome(s)
        let minutes = max(1, Int(s.last.timeIntervalSince(s.first) / 60))
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.title.isEmpty ? s.project : s.title).font(.brand(16, .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) { Tag(text: o.0, tone: o.1); Tag(text: s.agent.rawValue, tone: .gray) }
                }
                Picker("", selection: $detailTab) { Text("Highlights").tag(0); Text("Span tree").tag(1); Text("Messages").tag(2) }.pickerStyle(.segmented).labelsHidden()
                switch detailTab {
                case 0: highlights(s, minutes: minutes)
                case 1: spanTree
                default: messages(s)
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button { Resume.open(s) } label: { Text("Resume in Terminal").frame(maxWidth: .infinity) }
                        .buttonStyle(.brandProminent).controlSize(.large).disabled(!s.cwdExists)
                    HStack(spacing: 8) {
                        Button { sheet = .compare(s) } label: { Text("Compare").frame(maxWidth: .infinity) }
                        Button { sheet = .share(s) } label: { Text("Share").frame(maxWidth: .infinity) }
                    }
                }
            }.padding(20)
        }.background(Brand.card)
    }

    private func highlights(_ s: SessionInfo, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Summary, written on this Mac").font(.bCaption).foregroundStyle(.secondary); Spacer(); SampleChip() }
            Text("Added a retry policy and a dead-letter table, fixed one off-by-one the tests caught, and now waits for your OK to run a migration.")
                .font(.bBody).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                kv("Duration", "\(minutes) min"); kv("Cost", String(format: "$%.2f", s.cost)); kv("Tokens", s.tokens >= 1_000_000 ? String(format: "%.1fM", Double(s.tokens) / 1e6) : "\(s.tokens / 1000)K")
                kv("Project", s.project); kv("Log size", s.bytes.bytesString); kv("Folder", s.cwdExists ? "Still on disk" : "Deleted")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Compared with your usual").font(.bHeadline)
                kv("Cost", "1.8× a typical fix", warn: true); kv("Turns to first edit", "3 (usual 5)"); kv("Retries", "1 (usual 2)")
            }
        }
    }

    private var spanTree: some View {
        let spans: [(String, Int, Double, Double, String)] = [
            ("Turn 1: read the webhook handler", 0, 0, 0.06, "2.6 min"), ("Read src/billing/webhook.rs", 1, 0.003, 0.01, "0.4 s"), ("Search for retry in the repo", 1, 0.03, 0.01, "0.6 s"),
            ("Turn 4: write RetryPolicy", 0, 0.21, 0.12, "9 s"), ("Edit src/billing/retry.rs", 1, 0.22, 0.02, "9 s"),
            ("Turn 6: run the tests", 0, 0.5, 0.12, "1.8 min"), ("Bash cargo test billing::", 1, 0.51, 0.04, "38 s"), ("Turn 9: ask permission", 0, 0.86, 0.14, "waiting")]
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Where the time went").font(.bHeadline); Spacer(); SampleChip() }
            ForEach(spans.indices, id: \.self) { i in
                let s = spans[i]
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(s.0).font(.bCaption.weight(s.1 == 0 ? .semibold : .regular)).lineLimit(1); Spacer(); Text(s.4).font(.bCaption).foregroundStyle(.secondary) }.padding(.leading, CGFloat(s.1) * 12)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Brand.muted)
                            Capsule().fill(s.1 == 0 ? AgentColor.claude : AgentColor.codex).frame(width: max(3, g.size.width * s.3)).offset(x: g.size.width * s.2)
                        }
                    }.frame(height: 5)
                }
            }
        }
    }

    private func messages(_ s: SessionInfo) -> some View {
        let msgs: [(String, String, String)] = [("You", "5:00 PM", "Retry failed invoices with backoff and park them after five failures."),
                                                 ("Agent", "5:00 PM", "I'll read the webhook handler first, then add a retry policy."),
                                                 ("Agent", "5:21 PM", "cargo test: 14 passed, 1 failed (retry_exhausts_after_five)."),
                                                 ("Agent", "5:41 PM", "I need to run migrations/0042_retry.sql. OK to proceed?")]
        return VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Conversation").font(.bHeadline); Spacer(); SampleChip() }
            ForEach(msgs.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(msgs[i].0).font(.bCaption.weight(.semibold)); Text(msgs[i].1).font(.bCaption).foregroundStyle(.secondary) }
                    Text(msgs[i].2).font(.bBody).fixedSize(horizontal: false, vertical: true)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(msgs[i].0 == "You" ? Brand.primaryTint : Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func kv(_ k: String, _ v: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).foregroundStyle(warn ? Brand.reclaimText : Color.primary).multilineTextAlignment(.trailing) }
            .font(.bCaption).padding(.vertical, 6).overlay(alignment: .top) { Divider() }
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

// MARK: Share (sample data): what would be hidden before a trace leaves this Mac

struct ShareSheet: View {
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss
    @State private var on = [true, true, true, true, true, true]
    @State private var dest = 0
    private let found: [(String, String, String, Tone)] = [
        ("API key", "sk-ant-…••••••••••3f9a", "2 places", .red), ("Token", "ghp_••••••••••••••••c1d2", "1 place", .red),
        ("Database", "postgres://billing:••••@localhost/billing_dev", "3 places", .amber), ("Email", "a•••@example.com", "4 places", .amber),
        ("Home path", "/Users/•••••/Developer/api-server", "41 places", .gray), ("Host", "10.0.4.•••", "2 places", .gray)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Share this trace").font(.brand(20, .semibold)); Spacer(); SampleChip() }
                Text("Nothing leaves your Mac until you press Export. AI Keeper found 6 things that look private and hid them. Review them first.").font(.bCallout).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Hidden before sharing").font(.bHeadline).padding(.horizontal, 28).padding(.vertical, 10)
                    ForEach(found.indices, id: \.self) { i in
                        HStack(spacing: 12) {
                            Tag(text: found[i].0, tone: found[i].3).frame(width: 84)
                            Text(found[i].1).font(.code(12)).lineLimit(1)
                            Spacer()
                            Text(found[i].2).font(.bCaption).foregroundStyle(.secondary)
                            Toggle("", isOn: $on[i]).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }.padding(.horizontal, 28).padding(.vertical, 7)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Who can see it").font(.bHeadline)
                    ForEach([("Only me", "Saved as a file you can send yourself."), ("People with the file", "Anyone you send the export to."), ("My team server", "Upload to a server you run. Off until you add one.")].indices, id: \.self) { i in
                        let o = [("Only me", "Saved as a file you can send yourself."), ("People with the file", "Anyone you send the export to."), ("My team server", "Upload to a server you run. Off until you add one.")][i]
                        Button { dest = i } label: {
                            VStack(alignment: .leading, spacing: 1) { Text(o.0).font(.bBody.weight(.semibold)); Text(o.1).font(.bCaption).foregroundStyle(.secondary) }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(dest == i ? Brand.primaryTint : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }.padding(20).frame(width: 300)
            }
            Divider()
            HStack {
                Text("Also available: Markdown file, JSONL, or a private link on your own server.").font(.bCaption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.controlSize(.large)
                Button("Export redacted copy") { dismiss() }.buttonStyle(.brandProminent).controlSize(.large)
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }.frame(width: 860).background(Brand.popover)
    }
}

// MARK: Compare (sample data): the same prompt run by two agents

struct CompareSheet: View {
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String, String, Bool)] = [
        ("Files changed", "2 files · +61 −4", "5 files · +148 −22", false), ("Approach", "One composite index on (customer_id, status)", "Two single-column indexes and a rewritten query", false),
        ("Query time in the benchmark", "12 ms (was 940 ms)", "31 ms (was 940 ms)", true), ("Commands that failed", "0", "4, all cargo test", true),
        ("Asked you a question", "Once, about the migration", "Never", false), ("Context used at the end", "38%", "82%", false)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Compare").font(.brand(20, .semibold)); Text("Same prompt, two agents").foregroundStyle(.secondary); Spacer(); SampleChip() }
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 2) { Text("Prompt both agents got").font(.bCaption).foregroundStyle(.secondary)
                    Text(session.title.isEmpty ? "Index orders by customer and status. The slow query is in src/api/orders.rs." : session.title).font(.bBody.weight(.medium)) }
            }
            HStack(alignment: .top, spacing: 14) {
                side("Claude Code", "Claude Opus 4.1", AgentColor.claude, "Merged", .violet, [("Cost", "$1.64", true), ("Time", "11 min", true), ("Turns", "6", true), ("Tests", "Pass", true)])
                side("Codex", "GPT-5", AgentColor.codex, "Open", .blue, [("Cost", "$2.38", false), ("Time", "19 min", false), ("Turns", "11", false), ("Tests", "1 failing", false)])
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        HStack(spacing: 14) {
                            Text(rows[i].0).font(.bBody.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(rows[i].1).font(.bBody).fontWeight(rows[i].3 ? .semibold : .regular).frame(width: 230, alignment: .leading)
                            Text(rows[i].2).font(.bBody).frame(width: 230, alignment: .leading)
                        }.padding(.horizontal, 16).padding(.vertical, 9)
                        if i < rows.count - 1 { Divider() }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.controlSize(.large); Button("Keep Claude's branch") { dismiss() }.buttonStyle(.brandProminent).controlSize(.large) }
        }.padding(28).frame(width: 860).background(Brand.background)
    }

    private func side(_ name: String, _ model: String, _ c: Color, _ tag: String, _ tone: Tone, _ m: [(String, String, Bool)]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) { Circle().fill(c).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) { Text(name).font(.bBody.weight(.semibold)); Text(model).font(.bCaption).foregroundStyle(.secondary) }
                    Spacer(); Tag(text: tag, tone: tone) }
                HStack { ForEach(m.indices, id: \.self) { i in VStack(alignment: .leading, spacing: 1) { Text(m[i].0).font(.bCaption).foregroundStyle(.secondary)
                    Text(m[i].1).font(.brand(18, .semibold)).foregroundStyle(m[i].2 ? AgentColor.good : (m[i].1 == "1 failing" ? Brand.destructive : Color.primary)) }.frame(maxWidth: .infinity, alignment: .leading) } }
            }
        }
    }
}
