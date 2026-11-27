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
    /// How many sessions load at a time. Scrolling to the end of the list asks for the next page.
    nonisolated static let pageSize = 100
    /// `pageEnds[k]` is the number of items (day headers and sessions) that make up the first k + 1 pages.
    @Published private(set) var pageEnds: [Int] = []
    private var byID: [String: SessionInfo] = [:]
    private var folderExists: [String: Bool] = [:]
    private var generation = 0

    func session(_ id: String?) -> SessionInfo? { id.flatMap { byID[$0] } }
    /// The items for the first `pages` pages.
    func visible(pages: Int) -> ArraySlice<Item> { items[..<(pages >= pageEnds.count ? items.count : pageEnds[max(pages, 1) - 1])] }
    func hasMore(pages: Int) -> Bool { pages < pageEnds.count }
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
        items = out.items; pageEnds = out.pageEnds; shown = out.shown; bytes = out.bytes; chart = out.chart; total = sessions.count
        byID = out.byID; folderExists = out.folderExists
    }

    private struct Output { let items: [Item]; let pageEnds: [Int]; let shown: Int; let bytes: Int64; let chart: [[Double]]; let byID: [String: SessionInfo]; let folderExists: [String: Bool] }

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
        var pageEnds: [Int] = [], count = 0
        for s in rows {
            let d = dayStart(s.last)
            if d != day {
                if day != nil, case .header(let id, let l, _) = items[headerAt] { items[headerAt] = .header(id: id, label: l, count: n) }
                day = d; n = 0; headerAt = items.count
                label = Self.dayLabel(d, today: today, cal: cal)
                items.append(.header(id: "day-\(d.timeIntervalSince1970)", label: label, count: 0))
            }
            n += 1; count += 1; bytes += s.bytes; byID[s.id] = s; items.append(.session(s))
            if count % pageSize == 0 || count == rows.count { pageEnds.append(items.count) }
        }
        if day != nil, case .header(let id, let l, _) = items[headerAt] { items[headerAt] = .header(id: id, label: l, count: n) }
        return Output(items: items, pageEnds: pageEnds, shown: rows.count, bytes: bytes, chart: counts, byID: byID, folderExists: exists)
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
    nonisolated(unsafe) static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()
    static let count: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
}

/// Sessions › History. Real sessions from the agents' logs, in the redesigned layout: an activity chart,
/// filters, rows grouped by day, and a panel for the one you pick. Outcomes and summaries are sample data until they can be worked out.
struct SessionHistoryView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @StateObject private var model = SessionHistoryModel()
    @State private var query = ""
    @State private var tool: AgentTool?
    @State private var orphansOnly = false
    @State private var matches: Set<String>?
    @State private var searching = false
    @State private var selected: String?
    @State private var pages = 1
    @State private var pendingDelete: SessionInfo?
    @State private var detailTab = 0
    @State private var sheet: SessionSheet?

    enum SessionSheet: Identifiable { case share(SessionInfo), compare(SessionInfo); var id: String { switch self { case .share: "s"; case .compare: "c" } } }

    /// Where the session ended up: still running, or the state of the pull request for the workspace it ran in.
    @MainActor static func outcome(_ s: SessionInfo, _ store: Store) -> (String, Tone) {
        if Date().timeIntervalSince(s.last) < 900 { return ("Running", .blue) }
        guard let pr = store.pr(forCwd: s.cwd) else { return ("No PR found", .gray) }
        switch pr.state { case "MERGED": return ("Merged", .violet); case "OPEN": return ("PR open", .blue); default: return ("PR closed", .gray) }
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
                    activity.fixedSize(horizontal: false, vertical: true)
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
            pages = 1   // a different filter starts again from the newest 100
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }   // wait for a pause in typing
            if Task.isCancelled { return }
            await model.update(store.sessions, .init(tool: tool, orphansOnly: orphansOnly, query: query, matches: matches))
        }
        .onChange(of: query) { _, q in search(q) }
        .sheet(item: $sheet) { sh in
            switch sh {
            case .share(let s): ShareSheet(session: s)
            case .compare(let s): CompareSheet(session: s).environment(store)
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
            Seg([("All agents", AgentTool?.none)] + AgentTool.enabled.map { ($0.rawValue, AgentTool?.some($0)) }, selection: $tool)
            Toggle("Folder deleted", isOn: $orphansOnly).toggleStyle(.checkbox).fixedSize()
            Spacer(minLength: 0)
            Text("\(SessionFmt.count.string(from: NSNumber(value: model.shown)) ?? "") shown · \(model.bytes.bytesString)").font(.bCaption).foregroundStyle(.secondary).fixedSize()
        }
    }

    // MARK: Table (pages of 100 that load as you reach the end)

    /// Width the scroll bar takes from the rows: 0 with overlay scroll bars, about 15 when the Mac always shows them.
    private static var scrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    private struct DayGroup: Identifiable { let id: String; let label: String; let count: Int; var sessions: [SessionInfo] }

    /// The loaded items regrouped by day, for pinned day headers.
    private func groups(_ items: ArraySlice<SessionHistoryModel.Item>) -> [DayGroup] {
        var out: [DayGroup] = []
        for item in items {
            switch item {
            case .header(let id, let label, let count): out.append(DayGroup(id: id, label: label, count: count, sessions: []))
            case .session(let s): if !out.isEmpty { out[out.count - 1].sessions.append(s) }
            }
        }
        return out
    }

    private func table(pick: SessionInfo?) -> some View {
        let loaded = model.visible(pages: pages)
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Started").frame(width: 56, alignment: .leading)
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                Text("Agent").frame(width: 80, alignment: .leading)
                Text("Outcome").frame(width: 90, alignment: .leading)
                Text("Cost").frame(width: 56, alignment: .trailing)
                Text("Updated").frame(width: 86, alignment: .trailing)
            }
            .font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            .padding(.trailing, Self.scrollerWidth)   // the rows lose this much to the scroll bar when it is always shown; keep the columns lined up
            .overlay(alignment: .bottom) { Divider() }
            if model.items.isEmpty {
                Text(store.usageLoading ? "Reading sessions…" : "No sessions match.").font(.bCaption).foregroundStyle(.secondary).padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups(loaded)) { g in
                            Section {
                                ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                                    SessionRow(s: s, outcome: Self.outcome(s, store), folderExists: model.exists(s), selected: pick?.id == s.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { nav.openTrace = s }
                                        .onTapGesture { selected = s.id }
                                        .contextMenu {
                                            Button("Resume in Terminal") { Resume.open(s) }.disabled(!model.exists(s))
                                            Button("Reveal log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.file)]) }
                                            Button("Copy session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.sessionID, forType: .string) }
                                            Divider()
                                            Button("Move log to Trash…", role: .destructive) { pendingDelete = s }
                                        }
                                        .overlay(alignment: .top) { if i > 0 { Divider().padding(.leading, 16) } }
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(g.label).font(.brand(12, .semibold))
                                    Text("\(g.count)").font(.brand(11)).foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Brand.muted)
                            }
                        }
                        if model.hasMore(pages: pages) {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the next \(SessionHistoryModel.pageSize)…").font(.bCaption).foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .onAppear { pages += 1 }
                        } else if model.shown > SessionHistoryModel.pageSize {
                            Text("All \(SessionFmt.count.string(from: NSNumber(value: model.shown)) ?? "") sessions are loaded.").font(.bCaption).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }

    // MARK: Detail panel (real: read from the session's own log)

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    private func inspector(_ s: SessionInfo) -> some View {
        let o = Self.outcome(s, store)
        let tr = store.traceBySession[s.sessionID]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.title.isEmpty ? s.project : s.title).font(.brand(16, .semibold)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) { Tag(text: o.0, tone: o.1); Tag(text: Advisor.name(s.agent), tone: .gray) }
                }
                Seg([("Highlights", 0), ("Steps", 1), ("Messages", 2)], selection: $detailTab)
                if let tr {
                    switch detailTab {
                    case 0: highlights(s, tr)
                    case 1: steps(tr)
                    default: messages(tr)
                    }
                } else {
                    basics(s)
                    Note(text: s.agent == .claude ? (store.traceProgress != nil ? "Reading this session's log…" : "Details are read for sessions from the last \(TraceIndexer.days) days.") : "Steps and messages are read for Claude Code sessions so far.")
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button { nav.openTrace = s } label: { Text("Open trace").frame(maxWidth: .infinity) }
                        .buttonStyle(.brandProminent).controlSize(.large)
                    HStack(spacing: 8) {
                        Button { Resume.open(s) } label: { Text("Resume").frame(maxWidth: .infinity) }.disabled(!model.exists(s))
                        Button { sheet = .compare(s) } label: { Text("Compare").frame(maxWidth: .infinity) }
                        Button { sheet = .share(s) } label: { Text("Share").frame(maxWidth: .infinity) }
                    }
                }
            }.padding(20)
        }.background(Brand.card)
    }

    private func basics(_ s: SessionInfo) -> some View {
        VStack(spacing: 0) {
            kv("Started", s.first.formatted(date: .abbreviated, time: .shortened)); kv("Cost", String(format: "$%.2f", s.cost))
            kv("Tokens", s.tokens >= 1_000_000 ? String(format: "%.1fM", Double(s.tokens) / 1e6) : "\(s.tokens / 1000)K")
            kv("Project", s.project); kv("Log size", s.bytes.bytesString); kv("Folder", model.exists(s) ? "Still on disk" : "Deleted")
        }
    }

    private func highlights(_ s: SessionInfo, _ tr: TraceSummary) -> some View {
        let usual = TraceAgg.median(store.sessions.newest(200).map(\.cost).filter { $0 > 0 })
        return VStack(alignment: .leading, spacing: 14) {
            if !tr.lastText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The last thing the agent said").font(.bCaption).foregroundStyle(.secondary)
                    Text(tr.lastText.prefix(420)).font(.bBody).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                kv("Working time", tr.activeSeconds >= 90 ? String(format: "%.0f min", tr.activeSeconds / 60) : String(format: "%.0f s", tr.activeSeconds))
                kv("Waiting on you", String(format: "%.0f min", tr.waitSeconds / 60))
                kv("Prompts", "\(tr.prompts.count)"); kv("Tool calls", tr.toolErrors > 0 ? "\(tr.toolCalls), \(tr.toolErrors) failed" : "\(tr.toolCalls)", warn: tr.toolErrors > 0)
                kv("Cost", String(format: "$%.2f", s.cost) + (usual > 0 && s.cost > usual * 1.5 ? String(format: " · %.1f× your usual", s.cost / usual) : ""), warn: usual > 0 && s.cost > usual * 2)
                kv("Peak context", "\(tr.peakContext / 1000)K tokens", warn: tr.peakContext > 150_000)
                if tr.compactions > 0 { kv("Compactions", "\(tr.compactions)") }
                if !tr.branch.isEmpty { kv("Branch", tr.branch) }
                kv("Folder", model.exists(s) ? "Still on disk" : "Deleted")
            }
            if !tr.files.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Files it changed").font(.bHeadline).padding(.bottom, 4)
                    ForEach(tr.files.sorted { $0.value > $1.value }.prefix(6), id: \.key) { f in
                        HStack { Text(f.key).font(.code(11)).lineLimit(1).truncationMode(.head); Spacer(); Text("\(f.value) edit\(f.value == 1 ? "" : "s")").font(.bCaption).foregroundStyle(.secondary) }
                            .padding(.vertical, 5).overlay(alignment: .top) { Divider() }
                    }
                }
            }
            if !tr.loops.isEmpty { Note(text: tr.loops[0].what + ": " + tr.loops[0].detail) }
        }
    }

    private func steps(_ tr: TraceSummary) -> some View {
        let list = tr.steps.filter { $0.kind != "text" }.suffix(60)
        let top = max(list.map(\.ms).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("The last \(list.count) steps").font(.bHeadline)
            ForEach(Array(list.enumerated()), id: \.offset) { _, st in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Self.clock.string(from: st.at)).font(.code(10)).foregroundStyle(.tertiary)
                        Text(st.title).font(.bCaption.weight(.semibold)).foregroundStyle(st.failed ? Brand.destructive : st.kind == "prompt" ? Brand.primaryText : Color.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        if st.ms > 0 { Text(st.ms >= 60_000 ? String(format: "%.0f min", st.ms / 60_000) : st.ms >= 1000 ? String(format: "%.0f s", st.ms / 1000) : "<1 s").font(.bCaption).foregroundStyle(.secondary) }
                    }
                    if !st.detail.isEmpty { Text(st.detail).font(st.kind == "prompt" ? .bCaption : .code(11)).foregroundStyle(.secondary).lineLimit(2) }
                    if st.kind == "tool" {
                        GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(st.failed ? Brand.destructive : AgentColor.codex).frame(width: max(3, g.size.width * st.ms / top)) } }.frame(height: 4)
                    }
                }
            }
        }
    }

    private func messages(_ tr: TraceSummary) -> some View {
        let list = tr.steps.filter { $0.kind == "prompt" || $0.kind == "text" }.suffix(30)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Conversation").font(.bHeadline)
            if list.isEmpty { Text("No messages in the log.").font(.bCaption).foregroundStyle(.secondary) }
            ForEach(Array(list.enumerated()), id: \.offset) { _, st in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(st.title).font(.bCaption.weight(.semibold)); Text(Self.clock.string(from: st.at)).font(.bCaption).foregroundStyle(.secondary) }
                    Text(st.detail).font(.bBody).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(st.kind == "prompt" ? Brand.primaryTint : Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

// MARK: Share: scan the session's log for private-looking text, then save a redacted copy

enum Redactor {
    struct Kind: Identifiable { let id: String; let label: String; let tone: Tone; let pattern: String; let replace: String }
    static var kinds: [Kind] {
        [Kind(id: "key", label: "API key", tone: .red, pattern: #"\b(sk-[A-Za-z0-9_\-]{16,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9\-]{10,})"#, replace: "[API key]"),
         Kind(id: "token", label: "Token", tone: .red, pattern: #"\b(gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_\-]{16,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{6,})"#, replace: "[token]"),
         Kind(id: "db", label: "Database", tone: .amber, pattern: #"\b(postgres(ql)?|mysql|mongodb(\+srv)?|redis)://[^\s"']+"#, replace: "[database URL]"),
         Kind(id: "email", label: "Email", tone: .amber, pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, replace: "[email]"),
         Kind(id: "home", label: "Home path", tone: .gray, pattern: NSRegularExpression.escapedPattern(for: home), replace: "~"),
         Kind(id: "ip", label: "IP address", tone: .gray, pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, replace: "[IP]")]
    }

    /// The conversation as Markdown: your prompts, the agent's replies and the commands it ran. No file contents or tool output.
    static func transcript(_ file: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe) else { return "" }
        var out = ""
        let wanted = [Array("\"type\":\"assistant\"".utf8), Array("\"type\":\"user\"".utf8)], blob = Array("\"type\":\"api-request-blob\"".utf8)
        Lines.each(data) { line in
            guard !Lines.contains(line, blob), wanted.contains(where: { Lines.contains(line, $0) }),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { return }
            if o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true {
                var text = m["content"] as? String
                for case let b as [String: Any] in (m["content"] as? [Any]) ?? [] {
                    if b["type"] as? String == "tool_result" { return }
                    if b["type"] as? String == "text", text == nil { text = b["text"] as? String }
                }
                if var t = text, let c = UsageParser.cleanTitle(&t) { out += "\n## You\n\n\(c)\n" }
            } else if o["type"] as? String == "assistant" {
                for case let b as [String: Any] in (m["content"] as? [Any]) ?? [] {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty { out += "\n## Agent\n\n\(t)\n" }
                    if b["type"] as? String == "tool_use", let n = b["name"] as? String {
                        let i = b["input"] as? [String: Any] ?? [:]
                        let d = (i["command"] ?? i["file_path"] ?? i["pattern"] ?? i["query"]) as? String ?? ""
                        out += "\n- \(n)\(d.isEmpty ? "" : ": `\(d.replacingOccurrences(of: "\n", with: " ").prefix(200))`")\n"
                    }
                }
            }
        }
        return out
    }

    static func count(_ text: String, _ k: Kind) -> (Int, String?) {
        guard let re = try? NSRegularExpression(pattern: k.pattern) else { return (0, nil) }
        let ns = text as NSString
        let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let first = m.first else { return (0, nil) }
        let s = ns.substring(with: first.range)
        return (m.count, k.id == "home" ? s : String(s.prefix(6)) + "…" + String(repeating: "•", count: 6))
    }

    static func apply(_ text: String, _ on: [Kind]) -> String {
        var t = text
        for k in on { if let re = try? NSRegularExpression(pattern: k.pattern) { t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: k.replace) } }
        return t
    }
}

struct ShareSheet: View {
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var found: [(Redactor.Kind, Int, String)] = []
    @State private var on: Set<String> = Set(Redactor.kinds.map(\.id))
    @State private var saved: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share this session").font(.brand(20, .semibold))
                Text(session.agent == .claude ? "Saves your prompts, the agent's replies and the commands it ran as a Markdown file. Nothing is uploaded. File contents and tool output are left out."
                     : "Sharing is built for Claude Code sessions so far.").font(.bCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(text == nil ? "Reading the session…" : found.isEmpty ? "Nothing that looks private was found" : "Found in the conversation, and replaced in the copy").font(.bHeadline).padding(.horizontal, 28).padding(.vertical, 12)
                ForEach(found, id: \.0.id) { f in
                    HStack(spacing: 12) {
                        Tag(text: f.0.label, tone: f.0.tone).frame(width: 90, alignment: .leading)
                        Text(f.2).font(.code(12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(f.1) place\(f.1 == 1 ? "" : "s")").font(.bCaption).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(get: { on.contains(f.0.id) }, set: { if $0 { on.insert(f.0.id) } else { on.remove(f.0.id) } })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }.padding(.horizontal, 28).padding(.vertical, 7)
                }
                Text("These are pattern matches, not a guarantee. Read the file before you send it.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 12)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                if let saved { Text("Saved to \(saved)").font(.bCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button("Close") { dismiss() }.controlSize(.large)
                Button("Save redacted copy…") { save() }.buttonStyle(.brandProminent).controlSize(.large).disabled(text == nil || text?.isEmpty == true)
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 720).background(Brand.popover)
        .task {
            guard session.agent == .claude else { text = ""; return }
            let file = session.file
            let t = await Task.detached(priority: .userInitiated) { Redactor.transcript(file) }.value
            let f = await Task.detached { Redactor.kinds.compactMap { k -> (Redactor.Kind, Int, String)? in let c = Redactor.count(t, k); return c.0 > 0 ? (k, c.0, c.1 ?? "") : nil } }.value
            text = t; found = f
        }
    }

    private func save() {
        guard let text else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "session-\(session.sessionID.prefix(8)).md"
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        let body = "# \(session.title)\n\n\(Advisor.name(session.agent)) · \(session.project) · \(session.first.formatted(date: .abbreviated, time: .shortened))\n" + Redactor.apply(text, Redactor.kinds.filter { on.contains($0.id) })
        do { try body.write(to: url, atomically: true, encoding: .utf8); saved = url.path.replacingOccurrences(of: home, with: "~") } catch { saved = nil }
    }
}

// MARK: Compare: this session beside another one of yours

struct CompareSheet: View {
    @Environment(Store.self) private var store
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss
    @State private var otherID: String?

    private var candidates: [SessionInfo] {
        let kind = Advisor.kind(session.title)
        let all = store.sessions.newest(400).filter { $0.id != session.id && $0.cost > 0 }
        let same = all.filter { Advisor.kind($0.title) == kind }
        return Array((same.count >= 3 ? same : all).prefix(25))
    }

    var body: some View {
        let list = candidates
        let other = list.first { $0.id == otherID } ?? list.first
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Compare").font(.brand(20, .semibold)); Text("This session beside another of the same kind").foregroundStyle(.secondary)
                Spacer()
                if !list.isEmpty {
                    PillMenu(list.map { (String(($0.title.isEmpty ? $0.project : $0.title).prefix(60)), Optional($0.id)) }, selection: Binding(get: { otherID ?? list.first?.id }, set: { otherID = $0 }))
                }
            }
            if let other {
                HStack(alignment: .top, spacing: 14) { side(session); side(other) }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        let a = store.traceBySession[session.sessionID], b = store.traceBySession[other.sessionID]
                        row("Cost", String(format: "$%.2f", session.cost), String(format: "$%.2f", other.cost), lower: session.cost < other.cost)
                        row("Start to finish", span(session), span(other), lower: session.last.timeIntervalSince(session.first) < other.last.timeIntervalSince(other.first))
                        row("Tokens", tok(session.tokens), tok(other.tokens), lower: session.tokens < other.tokens)
                        if let a, let b {
                            row("Prompts from you", "\(a.prompts.count)", "\(b.prompts.count)", lower: a.prompts.count < b.prompts.count)
                            row("Tool calls", "\(a.toolCalls)", "\(b.toolCalls)", lower: a.toolCalls < b.toolCalls)
                            row("Failed tool calls", "\(a.toolErrors)", "\(b.toolErrors)", lower: a.toolErrors < b.toolErrors)
                            row("Files changed", "\(a.files.count)", "\(b.files.count)", lower: nil)
                            row("Peak context", "\(a.peakContext / 1000)K", "\(b.peakContext / 1000)K", lower: a.peakContext < b.peakContext)
                        } else {
                            Text("Tool calls, failures and context are shown when both are Claude Code sessions from the last \(TraceIndexer.days) days.").font(.bCaption).foregroundStyle(.secondary).padding(14)
                        }
                    }
                }
            } else { Card { Text("There is no other session to compare with yet.").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("Close") { dismiss() }.controlSize(.large) }
        }.padding(28).frame(width: 860).background(Brand.background)
    }

    private func span(_ s: SessionInfo) -> String { let m = s.last.timeIntervalSince(s.first) / 60; return m >= 120 ? String(format: "%.1f hr", m / 60) : String(format: "%.0f min", m) }
    private func tok(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : "\(n / 1000)K" }

    private func side(_ s: SessionInfo) -> some View {
        let o = SessionHistoryView.outcome(s, store)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { Circle().fill(AgentColor.of(s.agent.rawValue)).frame(width: 10, height: 10); Text(Advisor.name(s.agent)).font(.bBody.weight(.semibold)); Spacer(); Tag(text: o.0, tone: o.1) }
                Text(s.title.isEmpty ? s.project : s.title).font(.bBody).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text("\(s.project) · \(s.last.formatted(date: .abbreviated, time: .shortened))").font(.bCaption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ a: String, _ b: String, lower: Bool?) -> some View {
        HStack(spacing: 14) {
            Text(label).font(.bBody.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            Text(a).font(.bBody).fontWeight(lower == true ? .semibold : .regular).foregroundStyle(lower == true ? AgentColor.good : Color.primary).monospacedDigit().frame(width: 200, alignment: .leading)
            Text(b).font(.bBody).fontWeight(lower == false ? .semibold : .regular).foregroundStyle(lower == false ? AgentColor.good : Color.primary).monospacedDigit().frame(width: 200, alignment: .leading)
        }.padding(.horizontal, 16).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
    }
}

/// One row of the history list. Cheap on purpose: it is made for every row that scrolls into view.
private struct SessionRow: View {
    let s: SessionInfo
    let outcome: (String, Tone)
    let folderExists: Bool
    let selected: Bool
    @State private var hovering = false
    var body: some View {
        let o = outcome
        HStack(spacing: 14) {
            Text(SessionFmt.time.string(from: s.first)).font(.bCaption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title.isEmpty ? s.project : s.title).font(.bBody.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(s.project)
                    if !folderExists { Tag(text: "Folder deleted", tone: .gray) }
                }.font(.bCaption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { Circle().fill(AgentColor.of(s.agent.rawValue)).frame(width: 7, height: 7); Text(s.agent.rawValue).font(.bCaption).foregroundStyle(.secondary) }.frame(width: 80, alignment: .leading)
            Tag(text: o.0, tone: o.1).frame(width: 90, alignment: .leading)
            Text(String(format: "$%.2f", s.cost)).font(.bBody).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(SessionFmt.relative.localizedString(for: s.last, relativeTo: Date())).font(.bCaption).foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(selected ? Brand.primaryTint : hovering ? Brand.hover : Color.clear)
        .onHover { hovering = $0 }
    }
}
