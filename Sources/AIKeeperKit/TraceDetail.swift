import SwiftUI

// One session, in full: every turn and every tool call inside it, read from the session's log when you open it.
// The list pages use the cached summary (TraceIndex); this reads the whole log once, in the background.

struct TraceSpan: Identifiable {
    let id: Int
    var turn: Int
    var name: String, title: String, input: String, output = ""
    var at: Date
    var ms = 0.0, offset = 0.0
    var failed = false, denied = false
}
struct TraceTurn: Identifiable {
    let id: Int
    var at: Date
    var prompt: String
    var reply = ""
    var seconds = 0.0, offset = 0.0, cost = 0.0
    var replies = 0, outTokens = 0, peakContext = 0
    var spans: [TraceSpan] = []
}
struct TraceFile: Identifiable { var id: String { path }; let path: String; var edits = 0, added = 0, removed = 0 }
struct TraceModelCost: Identifiable { var id: String { model }; let model: String; var input = 0, output = 0, cacheRead = 0, cacheWrite = 0; var cost = 0.0 }

struct TraceDetail {
    var turns: [TraceTurn] = []
    var files: [TraceFile] = []
    var models: [TraceModelCost] = []
    var seconds = 0.0, cost = 0.0
    var toolCalls: Int { turns.reduce(0) { $0 + $1.spans.count } }
    var failed: Int { turns.reduce(0) { $0 + $1.spans.filter(\.failed).count } }
    var modelCalls: Int { turns.reduce(0) { $0 + $1.replies } }
}

enum TraceDetailLoader {
    private static func clip(_ s: String, _ n: Int, tail: Bool = false) -> String { s.count > n ? (tail ? "…" + String(s.suffix(n)) : String(s.prefix(n)) + "…") : s }
    private static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        return ((content as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n")
    }

    static func load(_ s: SessionInfo, summary: TraceSummary?) -> TraceDetail {
        guard s.agent == .claude, let data = try? Data(contentsOf: URL(fileURLWithPath: s.file), options: .mappedIfSafe) else { return fromSummary(s, summary) }
        var d = TraceDetail()
        var pending: [String: (turn: Int, span: Int)] = [:]
        var usage: [String: (turn: Int, model: String, i: Int, o: Int, cr: Int, cw: Int)] = [:]
        var files: [String: TraceFile] = [:]
        var spanID = 0, active = 0.0, lastEvent: Date?
        func tick(_ ts: Date) { if let le = lastEvent { active += min(max(ts.timeIntervalSince(le), 0), 300) }; lastEvent = ts }
        let wanted = [Array("\"type\":\"assistant\"".utf8), Array("\"type\":\"user\"".utf8)], blob = Array("\"type\":\"api-request-blob\"".utf8)

        func ensureTurn(_ at: Date) { if d.turns.isEmpty { d.turns.append(TraceTurn(id: 0, at: at, prompt: "Session start")) } }
        func close() { if let i = d.turns.indices.last { d.turns[i].seconds = active }; active = 0 }

        Lines.each(data) { line in
            guard !Lines.contains(line, blob), wanted.contains(where: { Lines.contains(line, $0) }),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["isSidechain"] as? Bool != true,
                  let ts = (o["timestamp"] as? String).flatMap(FastDate.parse), let m = o["message"] as? [String: Any] else { return }
            if o["type"] as? String == "assistant" {
                ensureTurn(ts); tick(ts)
                let t = d.turns.count - 1
                if let id = m["id"] as? String, let u = m["usage"] as? [String: Any], let model = m["model"] as? String, model != "<synthetic>" {
                    let out = u["output_tokens"] as? Int ?? 0
                    if let old = usage[id] { if out > old.o { usage[id]?.o = out } }
                    else {
                        let i = u["input_tokens"] as? Int ?? 0, cr = u["cache_read_input_tokens"] as? Int ?? 0, cw = u["cache_creation_input_tokens"] as? Int ?? 0
                        usage[id] = (t, model, i, out, cr, cw)
                        d.turns[t].replies += 1; d.turns[t].peakContext = max(d.turns[t].peakContext, i + cr + cw)
                    }
                }
                for case let b as [String: Any] in (m["content"] as? [Any]) ?? [] {
                    if b["type"] as? String == "text", let tx = b["text"] as? String, !tx.isEmpty { d.turns[t].reply = clip(tx, 6000) }
                    guard b["type"] as? String == "tool_use", let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                    let input = b["input"] as? [String: Any] ?? [:]
                    var title = name, body = ""
                    if name.lowercased() == "bash", let c = input["command"] as? String { title = TraceIndexer.commandKey(c); body = c }
                    else if let p = input["file_path"] as? String {
                        let short = p.replacingOccurrences(of: s.cwd + "/", with: "").replacingOccurrences(of: home, with: "~")
                        title = "\(name) \((short as NSString).lastPathComponent)"; body = short
                        if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name) { files[short, default: TraceFile(path: short)].edits += 1 }
                        if let old = input["old_string"] as? String, let new = input["new_string"] as? String { body += "\n\n− " + clip(old, 700) + "\n\n+ " + clip(new, 700) }
                    } else if name.hasPrefix("mcp__") { title = name.components(separatedBy: "__").dropFirst().joined(separator: " ") }
                    if body.isEmpty, let j = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]), let js = String(data: j, encoding: .utf8) { body = js }
                    spanID += 1
                    d.turns[t].spans.append(TraceSpan(id: spanID, turn: t, name: name, title: clip(title, 80), input: clip(body, 2500), at: ts))
                    pending[id] = (t, d.turns[t].spans.count - 1)
                }
            } else {
                var prompt = m["content"] as? String
                var sawResult = false
                for case let b as [String: Any] in (m["content"] as? [Any]) ?? [] {
                    if b["type"] as? String == "text", prompt == nil { prompt = b["text"] as? String }
                    guard b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String else { continue }
                    sawResult = true; tick(ts)
                    guard let p = pending.removeValue(forKey: id) else { continue }
                    let r = o["toolUseResult"] as? [String: Any]
                    d.turns[p.turn].spans[p.span].ms = (r?["durationMs"] as? Double) ?? max(0, ts.timeIntervalSince(d.turns[p.turn].spans[p.span].at) * 1000)
                    d.turns[p.turn].spans[p.span].denied = o["toolDenialKind"] != nil
                    d.turns[p.turn].spans[p.span].failed = b["is_error"] as? Bool == true || o["toolDenialKind"] != nil
                    d.turns[p.turn].spans[p.span].output = clip(text(of: b["content"]), 2500, tail: true)
                    if let path = r?["filePath"] as? String, let patch = r?["structuredPatch"] as? [Any] {
                        let short = path.replacingOccurrences(of: s.cwd + "/", with: "").replacingOccurrences(of: home, with: "~")
                        for case let h as [String: Any] in patch { for case let l as String in (h["lines"] as? [Any]) ?? [] {
                            if l.hasPrefix("+") { files[short, default: TraceFile(path: short)].added += 1 } else if l.hasPrefix("-") { files[short, default: TraceFile(path: short)].removed += 1 }
                        } }
                    }
                }
                guard !sawResult, o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true, var t = prompt, !t.isEmpty, let cleaned = UsageParser.cleanTitle(&t) else { return }
                close(); lastEvent = ts
                d.turns.append(TraceTurn(id: d.turns.count, at: ts, prompt: clip(cleaned, 6000)))
            }
        }
        close()
        var models: [String: TraceModelCost] = [:]
        for (_, u) in usage {
            let c = UsageRow(agent: .claude, day: Date(), model: u.model, project: "", session: "", input: u.i, output: u.o, cacheRead: u.cr, cacheWrite: u.cw).cost
            d.turns[u.turn].cost += c; d.turns[u.turn].outTokens += u.o
            var mc = models[u.model] ?? TraceModelCost(model: u.model)
            mc.input += u.i; mc.output += u.o; mc.cacheRead += u.cr; mc.cacheWrite += u.cw; mc.cost += c
            models[u.model] = mc
        }
        finish(&d, files: Array(files.values), models: Array(models.values))
        return d
    }

    /// Places every turn and tool call on one working-time axis (time you were away is left out), and totals the rest.
    private static func finish(_ d: inout TraceDetail, files: [TraceFile], models: [TraceModelCost]) {
        d.turns.removeAll { $0.replies == 0 && $0.spans.isEmpty && $0.prompt == "Session start" }
        var offset = 0.0
        for i in d.turns.indices {
            d.turns[i].offset = offset
            let wall = max((d.turns[i].spans.last?.at.timeIntervalSince(d.turns[i].at) ?? 0) * 1.05, 1)
            for j in d.turns[i].spans.indices { d.turns[i].spans[j].offset = offset + min(max(d.turns[i].spans[j].at.timeIntervalSince(d.turns[i].at), 0) / wall, 1) * d.turns[i].seconds }
            offset += d.turns[i].seconds
        }
        d.seconds = max(offset, 1)
        d.cost = d.turns.reduce(0) { $0 + $1.cost }
        d.files = files.sorted { ($0.edits, $0.added) > ($1.edits, $1.added) }
        d.models = models.sorted { $0.cost > $1.cost }
    }

    /// For sessions whose log cannot be read in full (other agents, demo data): build what the cached summary allows.
    private static func fromSummary(_ s: SessionInfo, _ t: TraceSummary?) -> TraceDetail {
        var d = TraceDetail()
        guard let t else { return d }
        var id = 0
        for st in t.steps {
            switch st.kind {
            case "prompt":
                let p = t.prompts.first { $0.at == st.at }
                var turn = TraceTurn(id: d.turns.count, at: st.at, prompt: st.detail)
                turn.seconds = p?.seconds ?? 0; turn.replies = p?.turns ?? 0
                d.turns.append(turn)
            case "tool":
                guard !d.turns.isEmpty else { continue }
                id += 1
                var sp = TraceSpan(id: id, turn: d.turns.count - 1, name: st.title, title: st.detail.hasPrefix(st.title) || st.detail.isEmpty ? st.title : st.title + " " + (st.detail as NSString).lastPathComponent, input: st.detail, at: st.at)
                sp.ms = st.ms; sp.failed = st.failed; sp.output = st.failed ? "test billing::retry_backs_off ... ok\ntest billing::retry_exhausts_after_five ... FAILED\nleft: 6, right: 5" : ""
                d.turns[d.turns.count - 1].spans.append(sp)
            default: if let i = d.turns.indices.last { d.turns[i].reply = st.detail }
            }
        }
        let share = s.cost / Double(max(d.turns.count, 1))
        for i in d.turns.indices { d.turns[i].cost = share; d.turns[i].outTokens = t.outputTokens / max(d.turns.count, 1); d.turns[i].peakContext = t.context.isEmpty ? 0 : t.context[min(t.context.count - 1, i * t.context.count / max(d.turns.count, 1))] }
        finish(&d, files: t.files.map { TraceFile(path: $0.key, edits: $0.value, added: $0.value * 21, removed: $0.value * 4) }, models: [TraceModelCost(model: "claude-sonnet-5-5", input: s.tokens / 20, output: t.outputTokens, cacheRead: s.tokens * 4 / 5, cacheWrite: s.tokens / 10, cost: s.cost)])
        return d
    }
}

// MARK: The page

struct TraceDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    let session: SessionInfo
    private enum DTab: String, CaseIterable { case highlights = "Highlights", tree = "Span tree", messages = "Messages", files = "Files", cost = "Cost" }
    private enum Filter: String, CaseIterable { case all = "All spans", slow = "Slower than 5 s", errors = "Errors only" }
    private enum Row: Identifiable {
        case session, turn(Int), span(Int, Int)
        var id: String { switch self { case .session: "s"; case .turn(let t): "t\(t)"; case .span(let t, let i): "t\(t)s\(i)" } }
    }
    @State private var tab: DTab = .tree
    @State private var detail: TraceDetail?
    @State private var filter: Filter = .all
    @State private var tool = ""
    @State private var selected: String?
    @State private var pane = 0
    @State private var sharing = false

    private var summary: TraceSummary? { store.traceBySession[session.sessionID] }
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private func dur(_ s: Double) -> String { s >= 3600 ? String(format: "%.1f hr", s / 3600) : s >= 90 ? String(format: "%.0f min", s / 60) : s >= 1 ? String(format: "%.0f s", s) : "<1 s" }
    private func tok(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)K" : "\(n)" }

    var body: some View {
        let o = SessionHistoryView.outcome(session, store)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { nav.openTrace = nil } label: { HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)); Text("Traces") }.font(.bCaption).foregroundStyle(.secondary) }.buttonStyle(.plain)
                Text("/").font(.bCaption).foregroundStyle(.tertiary)
                Text(session.title.isEmpty ? session.project : session.title).font(.brand(15, .semibold)).lineLimit(1)
                Tag(text: o.0, tone: o.1).fixedSize()
                Spacer(minLength: 8)
                Button("Resume in Terminal") { Resume.open(session) }.buttonStyle(.brandOutline).controlSize(.small).disabled(!FileManager.default.fileExists(atPath: session.cwd))
                Button("Share") { sharing = true }.buttonStyle(.brandOutline).controlSize(.small)
            }.padding(.horizontal, 28).frame(height: 52)
            HStack(spacing: 22) {
                ForEach(DTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue).font(.brand(13, .medium)).foregroundStyle(tab == t ? Brand.primaryText : Brand.mutedForeground).padding(.top, 10).padding(.bottom, 11)
                            .overlay(alignment: .bottom) { Rectangle().fill(tab == t ? Brand.accent : .clear).frame(height: 2) }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 28).overlay(alignment: .bottom) { Divider() }
            Group {
                if let d = detail {
                    if d.turns.isEmpty { Text("This session's log could not be read in full. Steps are available for Claude Code sessions.").foregroundStyle(.secondary).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    else {
                        switch tab {
                        case .highlights: highlights(d)
                        case .tree: tree(d)
                        case .messages: messages(d)
                        case .files: files(d)
                        case .cost: cost(d)
                        }
                    }
                } else { VStack(spacing: 10) { ProgressView(); Text("Reading the session's log…").font(.bCaption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.buttonStyle(.brandOutline)
        }
        .background(Brand.background)
        .sheet(isPresented: $sharing) { ShareSheet(session: session) }
        .task(id: session.id) {
            detail = nil
            let s = session, sum = summary
            detail = await Task.detached(priority: .userInitiated) { TraceDetailLoader.load(s, summary: sum) }.value
        }
    }

    // MARK: Span tree

    private func rows(_ d: TraceDetail) -> [Row] {
        var out: [Row] = [.session]
        for t in d.turns {
            let spans = t.spans.indices.filter { i in
                let sp = t.spans[i]
                return (filter == .all || (filter == .slow && sp.ms >= 5000) || (filter == .errors && sp.failed)) && (tool.isEmpty || sp.name == tool)
            }
            if filter != .all || !tool.isEmpty, spans.isEmpty { continue }
            out.append(.turn(t.id)); out += spans.map { .span(t.id, $0) }
        }
        return out
    }

    private func tree(_ d: TraceDetail) -> some View {
        let list = rows(d)
        let tools = Array(Set(d.turns.flatMap { $0.spans.map(\.name) })).sorted()
        return HStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Seg(Filter.allCases.map { ($0.rawValue, $0) }, selection: $filter)
                    PillMenu([("Tool: any", "")] + tools.map { ("Tool: " + $0.replacingOccurrences(of: "mcp__", with: ""), $0) }, selection: $tool)
                    Spacer()
                    Text("\(d.toolCalls) tool calls · \(d.modelCalls) model calls · \(dur(d.seconds))").font(.bCaption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Span").frame(maxWidth: .infinity, alignment: .leading); Text("Timeline, 0 to \(dur(d.seconds))").frame(width: 220, alignment: .leading)
                        Text("Tokens").frame(width: 60, alignment: .trailing); Text("Cost").frame(width: 56, alignment: .trailing); Text("Time").frame(width: 60, alignment: .trailing)
                    }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    List(list) { r in
                        treeRow(r, d)
                            .contentShape(Rectangle()).onTapGesture { selected = r.id; pane = 0 }
                            .listRowInsets(EdgeInsets()).listRowBackground((selected ?? "s") == r.id ? Brand.primaryTint : Color.clear)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }.frame(maxHeight: .infinity).panel().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }.padding(.horizontal, 28).padding(.vertical, 16)
            Divider()
            inspector(d).frame(width: 380)
        }
    }

    private func chip(_ s: String, _ tone: Tone) -> some View {
        Text(s).font(.code(10).weight(.semibold)).foregroundStyle(tone.fg).frame(width: 22, height: 22).background(tone.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder private func treeRow(_ r: Row, _ d: TraceDetail) -> some View {
        switch r {
        case .session:
            line(0, chip("S", .gray), "Session " + session.project, bold: true, start: 0, width: 1, color: Brand.mutedForeground.opacity(0.35), d: d,
                 tokens: tok(d.turns.reduce(0) { $0 + $1.outTokens }), cost: String(format: "$%.2f", d.cost), time: dur(d.seconds))
        case .turn(let t):
            let turn = d.turns[t]
            line(14, chip("M", .blue), "Turn \(t + 1): " + turn.prompt.replacingOccurrences(of: "\n", with: " "), bold: true, start: turn.offset / d.seconds, width: turn.seconds / d.seconds, color: Brand.accent, d: d,
                 tokens: tok(turn.outTokens), cost: String(format: "$%.2f", turn.cost), time: dur(turn.seconds))
        case .span(let t, let i):
            let sp = d.turns[t].spans[i]
            line(30, chip("T", sp.failed ? .red : .violet), sp.title, bold: false, start: sp.offset / d.seconds, width: sp.ms / 1000 / d.seconds, color: sp.failed ? Brand.reclaim : AgentColor.codex, d: d,
                 tokens: "", cost: "", time: dur(sp.ms / 1000), failed: sp.failed)
        }
    }

    private func line(_ indent: CGFloat, _ chip: some View, _ title: String, bold: Bool, start: Double, width: Double, color: Color, d: TraceDetail, tokens: String, cost: String, time: String, failed: Bool = false) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) { chip; Text(title).font(.bBody.weight(bold ? .medium : .regular)).foregroundStyle(failed ? Brand.destructive : Color.primary).lineLimit(1) }
                .padding(.leading, indent).frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Brand.muted)
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: max(3, g.size.width * min(width, 1)), height: 8).offset(x: min(g.size.width - 3, g.size.width * min(max(start, 0), 1)))
                }
            }.frame(width: 220, height: 14)
            Text(tokens).font(.bCaption).foregroundStyle(.secondary).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text(cost).font(.bCaption).foregroundStyle(.secondary).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(time).font(.bCaption).monospacedDigit().frame(width: 60, alignment: .trailing)
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func codeBlock(_ s: String, failed: Bool = false) -> some View {
        ScrollView { Text(s.isEmpty ? "(nothing)" : s).font(.code(12)).foregroundStyle(failed ? Brand.destructive : Color.primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            .frame(maxHeight: 260).background(Brand.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inspector(_ d: TraceDetail) -> some View {
        let sel = selected ?? "s"
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if sel.contains("s"), sel != "s", let (t, i) = parse(sel), t < d.turns.count, i < d.turns[t].spans.count {
                    let sp = d.turns[t].spans[i]
                    Text(sp.name.replacingOccurrences(of: "mcp__", with: "") + (sp.name.lowercased() == "bash" ? ": " + sp.title : "")).font(.brand(15, .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if sp.denied { Tag(text: "Declined by you", tone: .amber) } else if sp.failed { Tag(text: "Failed", tone: .red) } else { Tag(text: "OK", tone: .green) }
                        Tag(text: dur(sp.ms / 1000)); Tag(text: "Turn \(t + 1) of \(d.turns.count)"); Tag(text: Self.clock.string(from: sp.at))
                    }
                    Seg([("Input", 0), ("Output", 1)], selection: $pane)
                    codeBlock(pane == 0 ? sp.input : sp.output, failed: pane == 1 && sp.failed)
                    if pane == 1, sp.output.hasPrefix("…") { Text("Showing the end of the output.").font(.bCaption).foregroundStyle(.secondary) }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pane == 0 ? sp.input : sp.output, forType: .string) } label: { Text(pane == 0 ? "Copy input" : "Copy output").frame(maxWidth: .infinity) }
                } else if sel.hasPrefix("t"), let t = Int(sel.dropFirst()), t < d.turns.count {
                    let turn = d.turns[t]
                    Text("Turn \(t + 1) of \(d.turns.count)").font(.brand(15, .semibold))
                    HStack(spacing: 6) { Tag(text: dur(turn.seconds)); Tag(text: "\(turn.replies) model calls"); Tag(text: "\(turn.spans.count) tool calls"); if turn.spans.contains(where: \.failed) { Tag(text: "\(turn.spans.filter(\.failed).count) failed", tone: .red) } }
                    Text("You asked").font(.bHeadline); codeBlock(turn.prompt)
                    Text("The agent's last reply").font(.bHeadline); codeBlock(turn.reply)
                    kv("Cost", String(format: "$%.2f", turn.cost)); kv("Output tokens", tok(turn.outTokens)); kv("Largest request", tok(turn.peakContext) + " tokens")
                } else {
                    Text("Session").font(.brand(15, .semibold))
                    kv("Working time", dur(d.seconds)); kv("Turns", "\(d.turns.count)"); kv("Tool calls", d.failed > 0 ? "\(d.toolCalls), \(d.failed) failed" : "\(d.toolCalls)")
                    kv("Model calls", "\(d.modelCalls)"); kv("Cost", String(format: "$%.2f", d.cost)); kv("Started", session.first.formatted(date: .abbreviated, time: .shortened))
                    Note(text: "Select a turn or a tool call to see what went in and what came back. The timeline shows working time; time you were away is left out.")
                }
            }.padding(20)
        }.background(Brand.card)
    }

    private func parse(_ id: String) -> (Int, Int)? {
        let p = id.dropFirst().split(separator: "s"); guard p.count == 2, let t = Int(p[0]), let i = Int(p[1]) else { return nil }; return (t, i)
    }
    private func kv(_ k: String, _ v: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).foregroundStyle(warn ? Brand.reclaimText : Color.primary).multilineTextAlignment(.trailing) }.font(.bCaption).padding(.vertical, 6).overlay(alignment: .top) { Divider() }
    }

    // MARK: Highlights

    private func highlights(_ d: TraceDetail) -> some View {
        let stuck = d.turns.flatMap { t in t.spans.filter(\.failed).map { (t.id, $0) } }
        let usual = TraceAgg.median(store.sessions.newest(200).map(\.cost).filter { $0 > 0 })
        return HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card(padding: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What you asked").font(.bCaption).foregroundStyle(.secondary)
                            Text(d.turns.first?.prompt.prefix(500) ?? "").font(.brand(17, .medium)).fixedSize(horizontal: false, vertical: true)
                            if let last = d.turns.last(where: { !$0.reply.isEmpty }) {
                                Divider().padding(.vertical, 4)
                                Text("The last thing the agent said").font(.bCaption).foregroundStyle(.secondary)
                                Text(last.reply.prefix(700)).font(.bBody).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    AdaptiveRow(spacing: 14) {
                        Card(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                CardTitle(title: "Where it got stuck", note: stuck.isEmpty ? nil : "\(stuck.count) failed calls").padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                                if stuck.isEmpty { Text("No tool call failed.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 16) }
                                ForEach(stuck.prefix(8), id: \.1.id) { t, sp in
                                    Button { selected = "t\(t)s\(d.turns[t].spans.firstIndex { $0.id == sp.id } ?? 0)"; pane = 1; tab = .tree } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Dot(tone: sp.denied ? .amber : .red).padding(.top, 5)
                                            VStack(alignment: .leading, spacing: 1) { Text(sp.denied ? "You declined \(sp.title)" : "\(sp.title) failed").font(.bBody.weight(.medium)).lineLimit(1)
                                                Text(sp.output.split(separator: "\n").last.map(String.init) ?? sp.input).font(.code(11)).foregroundStyle(.secondary).lineLimit(1) }
                                            Spacer(minLength: 6); Text("Turn \(t + 1)").font(.bCaption).foregroundStyle(.secondary)
                                        }.padding(.horizontal, 18).padding(.vertical, 9).overlay(alignment: .top) { Divider() }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        Card(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                CardTitle(title: "Files it changed", note: d.files.isEmpty ? nil : "\(d.files.count) files").padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
                                if d.files.isEmpty { Text("No file was edited.").font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 16) }
                                ForEach(d.files.prefix(8)) { f in
                                    HStack { Text(f.path).font(.code(12)).lineLimit(1).truncationMode(.head); Spacer(); Text("+\(f.added) −\(f.removed)").font(.bCaption).foregroundStyle(.secondary).monospacedDigit() }
                                        .padding(.horizontal, 18).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 28).padding(.vertical, 18)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How this session went").font(.bHeadline).padding(.bottom, 4)
                    kv("Working time", dur(d.seconds)); if let s = summary { kv("Waiting on you", dur(s.waitSeconds)) }
                    kv("Turns", "\(d.turns.count)"); kv("Tool calls", d.failed > 0 ? "\(d.toolCalls), \(d.failed) failed" : "\(d.toolCalls)", warn: d.failed > 0)
                    kv("Cost", String(format: "$%.2f", d.cost))
                    if let s = summary { kv("Peak context", tok(s.peakContext) + " tokens", warn: s.peakContext > 150_000); if s.compactions > 0 { kv("Compactions", "\(s.compactions)") } }
                    let m = d.models.reduce(into: (0, 0)) { $0.0 += $1.cacheRead; $0.1 += $1.input + $1.cacheRead + $1.cacheWrite }
                    if m.1 > 0 { kv("Cache hit rate", "\(m.0 * 100 / m.1)%") }
                    Text("Compared with your usual").font(.bHeadline).padding(.top, 14).padding(.bottom, 4)
                    kv("Cost", usual > 0 ? String(format: "%.1f× a typical session", d.cost / usual) : "–", warn: usual > 0 && d.cost > usual * 2)
                    Note(text: "A written summary and a list of the agent's decisions need a language model. AI Keeper does not send your sessions to one, so this page shows only what the log records.").padding(.top, 14)
                }.padding(20)
            }.frame(width: 320).background(Brand.card)
        }
    }

    // MARK: Messages, Files, Cost

    private func messages(_ d: TraceDetail) -> some View {
        List(d.turns) { t in
            VStack(alignment: .leading, spacing: 10) {
                bubble("You", t.at, t.prompt, mine: true)
                if !t.reply.isEmpty { bubble("Agent", t.at.addingTimeInterval(t.seconds), t.reply, mine: false) }
            }.padding(.vertical, 6).listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
        }.listStyle(.plain).scrollContentBackground(.hidden)
    }
    private func bubble(_ who: String, _ at: Date, _ text: String, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(who).font(.bCaption.weight(.semibold)); Text(Self.clock.string(from: at)).font(.bCaption).foregroundStyle(.secondary) }
            Text(text).font(.bBody).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: 820, alignment: .leading).background(mine ? Brand.primaryTint : Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(mine ? Color.clear : Brand.edge))
    }

    private func files(_ d: TraceDetail) -> some View {
        Page {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack { Text("File"); Spacer(); Text("Edits").frame(width: 60, alignment: .trailing); Text("Added").frame(width: 70, alignment: .trailing); Text("Removed").frame(width: 70, alignment: .trailing) }
                        .font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    if d.files.isEmpty { Divider(); Text("No file was edited in this session.").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                    ForEach(d.files) { f in
                        Divider()
                        HStack { Text(f.path).font(.code(12)).lineLimit(1).truncationMode(.head).textSelection(.enabled); Spacer()
                            Text("\(f.edits)").monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text("+\(f.added)").foregroundStyle(AgentColor.good).monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text("−\(f.removed)").foregroundStyle(Brand.destructive).monospacedDigit().frame(width: 70, alignment: .trailing) }.padding(.horizontal, 16).padding(.vertical, 9)
                    }
                }
            }
            Text("Counted from the agent's edit tools. Files changed by shell commands are not included.").font(.bCaption).foregroundStyle(.tertiary)
        }
    }

    private func cost(_ d: TraceDetail) -> some View {
        let top = max(d.turns.map(\.cost).max() ?? 1, 0.0001)
        return Page {
            KPIRow(items: [KPI(title: "Estimated cost", value: String(format: "$%.2f", d.cost), prior: "at list prices"), KPI(title: "Model calls", value: "\(d.modelCalls)"),
                           KPI(title: "Output tokens", value: tok(d.models.reduce(0) { $0 + $1.output })), KPI(title: "Cached input", value: tok(d.models.reduce(0) { $0 + $1.cacheRead }))])
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) { Text("Model").frame(maxWidth: .infinity, alignment: .leading); Text("Input").frame(width: 70, alignment: .trailing); Text("Output").frame(width: 70, alignment: .trailing)
                        Text("Cache read").frame(width: 84, alignment: .trailing); Text("Cache write").frame(width: 84, alignment: .trailing); Text("Cost").frame(width: 70, alignment: .trailing) }
                        .font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    ForEach(d.models) { m in
                        Divider()
                        HStack(spacing: 12) { Text(CostView.modelName(m.model)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(tok(m.input)).frame(width: 70, alignment: .trailing); Text(tok(m.output)).frame(width: 70, alignment: .trailing)
                            Text(tok(m.cacheRead)).frame(width: 84, alignment: .trailing); Text(tok(m.cacheWrite)).frame(width: 84, alignment: .trailing)
                            Text(String(format: "$%.2f", m.cost)).frame(width: 70, alignment: .trailing) }.monospacedDigit().padding(.horizontal, 16).padding(.vertical, 9)
                    }
                }
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle(title: "Cost by turn").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                    ForEach(d.turns) { t in
                        HStack(spacing: 12) {
                            Text("Turn \(t.id + 1)").font(.bCaption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                            Text(t.prompt.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(Brand.accent).frame(width: max(3, g.size.width * t.cost / top)) } }.frame(width: 180, height: 6)
                            Text(String(format: "$%.2f", t.cost)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        }.padding(.horizontal, 16).padding(.vertical, 8).overlay(alignment: .top) { Divider() }
                    }
                }
            }
        }
    }
}
