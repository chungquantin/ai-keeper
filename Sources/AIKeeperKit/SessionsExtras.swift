import SwiftUI

// Logs and Prompts, read from the Claude Code session logs (TraceIndex).

// MARK: Logs

/// Failures, declined commands, hook errors and compactions across recent sessions, newest first.
struct LogsView: View {
    @EnvironmentObject var store: Store
    private enum Level: String, CaseIterable { case all = "All", warn = "Warnings", error = "Errors" }
    private struct Line: Identifiable { let id: String; let at: Date; let level: String; let project: String; let message: String }
    @State private var level: Level = .all
    @State private var query = ""
    @State private var lines: [Line] = []
    @State private var perSlot: [[Double]] = []
    @State private var errors24 = 0

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d  HH:mm:ss"; return f }()
    private func tone(_ l: String) -> Tone { l == "error" ? .red : l == "warn" ? .amber : .gray }

    var body: some View {
        let shown = lines.filter { l in
            (level == .all || (level == .warn && l.level == "warn") || (level == .error && l.level == "error"))
                && (query.isEmpty || l.message.localizedCaseInsensitiveContains(query) || l.project.localizedCaseInsensitiveContains(query))
        }
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search messages, commands, projects", text: $query).textFieldStyle(.plain) }
                    .padding(.horizontal, 10).frame(height: 30).frame(width: 320)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.border))
                Seg(Level.allCases.map { ($0.rawValue, $0) }, selection: $level)
                Spacer()
                Text("\(shown.count) of \(lines.count) events, last \(TraceIndexer.days) days").font(.bCaption).foregroundStyle(.secondary)
                Button("Reload") { store.loadTraces() }.controlSize(.small)
            }
            Card(padding: 14) {
                HStack(alignment: .bottom, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last 24 hours").font(.bCaption).foregroundStyle(.secondary)
                        (Text("\(perSlot.reduce(0) { $0 + Int($1[0] + $1[1]) }) events · ") + Text("\(errors24) errors").foregroundStyle(errors24 > 0 ? Brand.destructive : Color.secondary)).font(.brand(18, .semibold))
                    }.fixedSize()
                    StackedBars(data: perSlot.isEmpty ? [[0, 0]] : perSlot, colors: [Brand.destructive, Brand.mutedForeground.opacity(0.35)], height: 44)
                }
            }.fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Time").frame(width: 118, alignment: .leading); Text("Level").frame(width: 44, alignment: .leading)
                    Text("Project").frame(width: 130, alignment: .leading); Text("Message"); Spacer()
                }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if shown.isEmpty {
                    Text(store.traceProgress != nil ? "Reading your session logs…" : lines.isEmpty ? "Nothing has failed or needed you in the last \(TraceIndexer.days) days." : "No events match.")
                        .font(.bCaption).foregroundStyle(.secondary).padding(24).frame(maxHeight: .infinity, alignment: .top)
                } else {
                    List(shown) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(Self.time.string(from: l.at)).font(.code(11)).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
                            Text(l.level.uppercased()).font(.code(10).weight(.semibold)).foregroundStyle(tone(l.level).fg).frame(width: 44, alignment: .leading)
                            Text(l.project).font(.code(12)).foregroundStyle(.secondary).lineLimit(1).frame(width: 130, alignment: .leading)
                            Text(l.message).font(.code(12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 5)
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                        .listRowBackground(l.level == "error" ? Brand.destructiveTint : Color.clear)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .frame(maxHeight: .infinity).panel().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .task(id: store.traces.count) {
            let traces = store.traces
            let out = await Task.detached(priority: .userInitiated) { () -> ([Line], [[Double]], Int) in
                var all: [Line] = []
                for t in traces { for e in t.events { all.append(Line(id: t.file + e.id, at: e.at, level: e.level, project: t.project, message: e.message)) } }
                all.sort { $0.at > $1.at }
                let now = Date()
                var slots = [[Double]](repeating: [0, 0], count: 48); var errs = 0
                for l in all {
                    let ago = now.timeIntervalSince(l.at)
                    guard ago >= 0, ago < 86_400 else { continue }
                    let i = 47 - Int(ago / 1800)
                    if l.level == "error" { slots[i][0] += 1; errs += 1 } else { slots[i][1] += 1 }
                }
                return (Array(all.prefix(5000)), slots, errs)
            }.value
            lines = out.0; perSlot = out.1; errors24 = out.2
        }
    }
}

// MARK: Prompts

/// Every prompt you sent in recent Claude Code sessions, with how long the agent worked on it.
struct PromptsView: View {
    @EnvironmentObject var store: Store
    private struct Row: Identifiable { let id: String; let p: TracePrompt; let project: String; let session: String }
    private struct Pattern { var fileTurns = 0.0, plainTurns = 0.0, fileN = 0, plainN = 0, medianWords = 0.0, shortTurns = 0.0, longTurns = 0.0, shortN = 0, longN = 0 }
    @State private var query = ""
    @State private var sort = 0
    @State private var rows: [Row] = []
    @State private var pat = Pattern()

    private static let day: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()

    var body: some View {
        let shown: [Row] = {
            var l = query.isEmpty ? rows : rows.filter { $0.p.text.localizedCaseInsensitiveContains(query) || $0.project.localizedCaseInsensitiveContains(query) }
            if sort == 1 { l.sort { $0.p.seconds > $1.p.seconds } }
            if sort == 2 { l.sort { $0.p.turns > $1.p.turns } }
            return l
        }()
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                fact("Prompts that name a file", pat.fileN >= 5 && pat.plainN >= 5 ? String(format: "%.0f replies", pat.fileTurns) : "Too few yet",
                     pat.fileN >= 5 && pat.plainN >= 5 ? String(format: "Against %.0f for prompts that do not. Typical, over %d and %d prompts.", pat.plainTurns, pat.fileN, pat.plainN) : "Needs 5 prompts of each kind.")
                fact("Typical length", String(format: "%.0f words", pat.medianWords), "The middle of your \(rows.count) prompts.")
                fact("Short against long", pat.shortN >= 5 && pat.longN >= 5 ? String(format: "%.0f vs %.0f replies", pat.shortTurns, pat.longTurns) : "Too few yet",
                     "Prompts under 15 words against prompts over 40.")
            }.fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search your prompts", text: $query).textFieldStyle(.plain) }
                    .padding(.horizontal, 10).frame(height: 30).frame(width: 300)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.border))
                Spacer()
                Text("\(shown.count) prompts").font(.bCaption).foregroundStyle(.secondary)
                Seg([("Newest", 0), ("Longest work", 1), ("Most replies", 2)], selection: $sort)
            }
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("Prompt"); Spacer()
                    Text("Words").frame(width: 56, alignment: .trailing); Text("Replies").frame(width: 60, alignment: .trailing)
                    Text("Agent worked").frame(width: 90, alignment: .trailing); Text("Sent").frame(width: 80, alignment: .trailing)
                }.font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
                if shown.isEmpty {
                    Text(store.traceProgress != nil ? "Reading your session logs…" : "No prompts found.").font(.bCaption).foregroundStyle(.secondary).padding(24).frame(maxHeight: .infinity, alignment: .top)
                } else {
                    List(shown) { r in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.p.text).font(.bBody.weight(.medium)).lineLimit(1)
                                Text(r.project + (r.session == r.p.text ? "" : " · " + r.session)).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(r.p.words)").foregroundStyle(.secondary).monospacedDigit().frame(width: 56, alignment: .trailing)
                            Text("\(r.p.turns)").foregroundStyle(.secondary).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text(r.p.seconds >= 90 ? String(format: "%.0f min", r.p.seconds / 60) : String(format: "%.0f s", r.p.seconds)).font(.bBody.weight(.medium)).monospacedDigit().frame(width: 90, alignment: .trailing)
                            Text(Self.day.localizedString(for: r.p.at, relativeTo: Date())).font(.bCaption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .frame(maxHeight: .infinity).panel().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .task(id: store.traces.count) {
            let traces = store.traces
            let out = await Task.detached(priority: .userInitiated) { () -> ([Row], Pattern) in
                var all: [Row] = []
                for t in traces { for (i, p) in t.prompts.enumerated() { all.append(Row(id: "\(t.file)#\(i)", p: p, project: t.project, session: t.title)) } }
                all.sort { $0.p.at > $1.p.at }
                var pt = Pattern()
                let done = all.filter { $0.p.turns > 0 }
                let file = done.filter { $0.p.namesFile }.map { Double($0.p.turns) }, plain = done.filter { !$0.p.namesFile }.map { Double($0.p.turns) }
                let short = done.filter { $0.p.words < 15 }.map { Double($0.p.turns) }, long = done.filter { $0.p.words > 40 }.map { Double($0.p.turns) }
                pt.fileTurns = TraceAgg.median(file); pt.plainTurns = TraceAgg.median(plain); pt.fileN = file.count; pt.plainN = plain.count
                pt.shortTurns = TraceAgg.median(short); pt.longTurns = TraceAgg.median(long); pt.shortN = short.count; pt.longN = long.count
                pt.medianWords = TraceAgg.median(all.map { Double($0.p.words) })
                return (Array(all.prefix(20_000)), pt)
            }.value
            rows = out.0; pat = out.1
        }
    }

    private func fact(_ label: String, _ value: String, _ note: String) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.bCaption).foregroundStyle(.secondary)
                Text(value).font(.brand(18, .semibold))
                Text(note).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
