import SwiftUI

/// Everything the History page shows, worked out off the main thread. The window never filters, sorts, groups or counts sessions itself:
/// with 100,000 of them that would freeze it on every redraw. It only draws the rows that are on screen.
@MainActor
final class SessionHistoryModel: ObservableObject {
    enum Item: Identifiable {
        case header(id: String, label: String, count: Int)
        case session(SessionInfo)
        var id: String { switch self { case .header(let id, _, _): id; case .session(let s): s.id } }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var shown = 0
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var chart: [[Double]] = Array(repeating: [0, 0, 0], count: 60)
    @Published private(set) var total = 0
    private var byID: [String: SessionInfo] = [:]
    private var folderExists: [String: Bool] = [:]
    private var generation = 0

    func session(_ id: String?) -> SessionInfo? { id.flatMap { byID[$0] } }
    var first: SessionInfo? { for case .session(let s) in items.prefix(2) { return s }; return nil }
    func exists(_ s: SessionInfo) -> Bool { folderExists[s.cwd] ?? true }

    struct Inputs { let tool: AgentTool?; let orphansOnly: Bool; let query: String; let matches: Set<String>? }

    func update(_ sessions: [SessionInfo], _ i: Inputs) async {
        generation += 1
        let g = generation, cached = folderExists
        let t0 = Date()
        let out = await Task.detached(priority: .userInitiated) { Self.compute(sessions, i, cached) }.value
        #if DEBUG
        if ProcessInfo.processInfo.environment["AIKEEPER_TIMING"] != nil { FileHandle.standardError.write(Data("HISTORY \(sessions.count) sessions: \(Int(Date().timeIntervalSince(t0) * 1000)) ms in the background\n".utf8)) }
        #endif
        guard g == generation else { return }   // a newer request is already on its way
        items = out.items; shown = out.shown; bytes = out.bytes; chart = out.chart; total = sessions.count
        byID = out.byID; folderExists = out.folderExists
    }

    private struct Output { let items: [Item]; let shown: Int; let bytes: Int64; let chart: [[Double]]; let byID: [String: SessionInfo]; let folderExists: [String: Bool] }

    nonisolated private static func compute(_ all: [SessionInfo], _ i: Inputs, _ cached: [String: Bool]) -> Output {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Does the folder still exist? One check per distinct folder, not per session, and remembered between runs.
        var exists = cached
        for cwd in Set(all.map(\.cwd)) where exists[cwd] == nil { exists[cwd] = FileManager.default.fileExists(atPath: cwd) }
        // Start of day for a date, remembered per 15-minute slot: every time zone's midnight falls on one, so the answer cannot differ inside a slot.
        var dayCache: [Int: Date] = [:]
        func dayStart(_ d: Date) -> Date {
            let k = Int(d.timeIntervalSince1970 / 900)
            if let v = dayCache[k] { return v }
            let v = cal.startOfDay(for: d); dayCache[k] = v; return v
        }
        // The 60-day activity chart counts every session, not just the filtered ones.
        var counts = [[Double]](repeating: [0, 0, 0], count: 60)
        for s in all {
            let d = Int((today.timeIntervalSince(dayStart(s.last)) / 86_400).rounded())
            guard d >= 0, d < 60 else { continue }
            counts[59 - d][s.agent == .claude ? 0 : s.agent == .codex ? 1 : 2] += 1
        }
        let q = i.query
        let rows = all.filter { s in
            if let t = i.tool, s.agent != t { return false }
            if i.orphansOnly, exists[s.cwd] == true { return false }
            if q.isEmpty { return true }
            if let m = i.matches { return m.contains(s.file) || s.title.localizedCaseInsensitiveContains(q) }
            return s.title.localizedCaseInsensitiveContains(q) || s.project.localizedCaseInsensitiveContains(q)
        }.sorted { $0.last > $1.last }
        var items: [Item] = []; items.reserveCapacity(rows.count + 400)
        var bytes: Int64 = 0, day: Date?, label = "", n = 0, headerAt = 0
        var byID: [String: SessionInfo] = [:]; byID.reserveCapacity(rows.count)
        for s in rows {
            let d = dayStart(s.last)
            if d != day {
                if day != nil, case .header(let id, let l, _) = items[headerAt] { items[headerAt] = .header(id: id, label: l, count: n) }
                day = d; n = 0; headerAt = items.count
                label = Self.dayLabel(d, today: today, cal: cal)
                items.append(.header(id: "day-\(d.timeIntervalSince1970)", label: label, count: 0))
            }
            n += 1; bytes += s.bytes; byID[s.id] = s; items.append(.session(s))
        }
        if day != nil, case .header(let id, let l, _) = items[headerAt] { items[headerAt] = .header(id: id, label: l, count: n) }
        return Output(items: items, shown: rows.count, bytes: bytes, chart: counts, byID: byID, folderExists: exists)
    }

    nonisolated private static func dayLabel(_ d: Date, today: Date, cal: Calendar) -> String {
        if d == today { return "Today" }
        if cal.date(byAdding: .day, value: -1, to: today) == d { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMM"
        return f.string(from: d)
    }
}

/// Formatters are slow to make and cheap to reuse; a scrolling list asks for them dozens of times a second.
private enum SessionFmt {
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()
    static let count: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
}

/// Sessions › History. Real sessions from the agents' logs, in the redesigned layout: an activity chart,
/// filters, rows grouped by day, and a panel for the one you pick. Outcomes and summaries are sample data until they can be worked out.
struct SessionHistoryView: View {
    @EnvironmentObject var store: Store
    @StateObject private var model = SessionHistoryModel()
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

    /// Sample outcome, steady for a given session across launches (Swift's own hash is reseeded every run, so it cannot be used).
    static func outcome(_ s: SessionInfo) -> (String, Tone) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.sessionID.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        if Date().timeIntervalSince(s.last) < 900 { return ("Running", .blue) }
        switch h % 10 { case 0, 1, 2, 3, 4: return ("Merged", .violet); case 5, 6: return ("Abandoned", .gray); case 7: return ("Failed", .red); default: return ("Open", .blue) }
    }

    /// Changes when anything that decides which rows are shown changes. The model reruns only then, and never on a plain redraw.
    private var key: [AnyHashable] {
        [store.sessions.count, store.sessions.first?.last.timeIntervalSince1970 ?? 0, tool?.rawValue ?? "", orphansOnly, query, matches?.count ?? -1]
    }

    var body: some View {
        let pick = model.session(selected) ?? model.first
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 14) {
                    activity
                    filters
                    table(pick: pick)
                }.padding(.horizontal, 28).padding(.vertical, 14)
                if let pick, geo.size.width >= 980 {
                    Divider()
                    inspector(pick).frame(width: 340)
                }
            }
        }
        .task(id: key) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }   // wait for a pause in typing
            if Task.isCancelled { return }
            await model.update(store.sessions, .init(tool: tool, orphansOnly: orphansOnly, query: query, matches: matches))
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

    // MARK: Activity chart (real: sessions per day by agent, counted once in the model)

    private var activity: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    (Text(SessionFmt.count.string(from: NSNumber(value: model.total)) ?? "\(model.total)").font(.bBody.weight(.bold)) + Text(" sessions, \(SessionFmt.count.string(from: NSNumber(value: Int(model.chart.reduce(0) { $0 + $1.reduce(0, +) }))) ?? "0") in 60 days").font(.bBody).foregroundStyle(.secondary)).lineLimit(1).fixedSize()
                    SampleChip(text: "Outcomes are samples").fixedSize()
                    Spacer()
                    Legend(items: [("Claude", AgentColor.claude), ("Codex", AgentColor.codex), ("Pi", AgentColor.pi)])
                }
                StackedBars(data: model.chart, colors: [AgentColor.claude, AgentColor.codex, AgentColor.pi], height: 54)
            }
        }
    }

    private var filters: some View {
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
            Text("\(SessionFmt.count.string(from: NSNumber(value: model.shown)) ?? "") shown · \(model.bytes.bytesString)").font(.bCaption).foregroundStyle(.secondary).fixedSize()
        }
    }

    // MARK: Table (virtualized: a List only builds the rows that are on screen)

    private func table(pick: SessionInfo?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Started").frame(width: 56, alignment: .leading); Text("Title"); Spacer()
                Text("Agent").frame(width: 80, alignment: .leading); Text("Outcome").frame(width: 90, alignment: .leading)
                Text("Cost").frame(width: 56, alignment: .trailing); Text("Updated").frame(width: 86, alignment: .trailing)
            }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if model.items.isEmpty {
                Text(store.usageLoading ? "Reading sessions…" : "No sessions match.").font(.bCaption).foregroundStyle(.secondary).padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else {
                List {
                    ForEach(model.items) { item in
                        switch item {
                        case .header(_, let label, let count):
                            HStack { Text(label).font(.brand(12, .semibold)); Text("\(count)").font(.brand(11)).foregroundStyle(.tertiary); Spacer() }
                                .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Brand.muted)
                                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                        case .session(let s):
                            SessionRow(s: s, folderExists: model.exists(s), selected: pick?.id == s.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = s.id }
                                .contextMenu {
                                    Button("Resume in Terminal") { Resume.open(s) }.disabled(!model.exists(s))
                                    Button("Reveal log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.file)]) }
                                    Button("Copy session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.sessionID, forType: .string) }
                                    Divider()
                                    Button("Move log to Trash…", role: .destructive) { pendingDelete = s }
                                }
                                .listRowInsets(EdgeInsets()).listRowSeparator(.visible).listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
        .panel()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                        .buttonStyle(.brandProminent).controlSize(.large).disabled(!model.exists(s))
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
                kv("Project", s.project); kv("Log size", s.bytes.bytesString); kv("Folder", model.exists(s) ? "Still on disk" : "Deleted")
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

/// One row of the history list. Cheap on purpose: it is made for every row that scrolls into view.
private struct SessionRow: View {
    let s: SessionInfo
    let folderExists: Bool
    let selected: Bool
    var body: some View {
        let o = SessionHistoryView.outcome(s)
        HStack(spacing: 14) {
            Text(SessionFmt.time.string(from: s.first)).font(.bCaption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title.isEmpty ? s.project : s.title).font(.bBody.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(s.project)
                    if !folderExists { Tag(text: "Folder deleted", tone: .gray) }
                }.font(.bCaption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) { Circle().fill(AgentColor.of(s.agent.rawValue)).frame(width: 7, height: 7); Text(s.agent.rawValue).font(.bCaption).foregroundStyle(.secondary) }.frame(width: 80, alignment: .leading)
            Tag(text: o.0, tone: o.1).frame(width: 90, alignment: .leading)
            Text(String(format: "$%.2f", s.cost)).font(.bBody).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(SessionFmt.relative.localizedString(for: s.last, relativeTo: Date())).font(.bCaption).foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(selected ? Brand.primaryTint : Color.clear)
    }
}
