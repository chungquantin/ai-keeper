import SwiftUI

struct EntryListView: View {
    @EnvironmentObject var store: Store
    let section: Section
    @State private var selection = Set<Entry.ID>()
    @State private var search = ""
    @State private var order = [KeyPathComparator(\Entry.sizeValue, order: .reverse)]
    @State private var showInspector = false
    @State private var showStale = false

    private var rows: [Entry] {
        var list = store.entries
        switch section {
        case .all: list = list.filter { $0.kind == .workspace || $0.kind == .repo }
        case .deprecated: list = list.filter { $0.kind == .workspace && $0.verdict != .active }
        case .tool(let s): list = list.filter { ($0.kind == .workspace || $0.kind == .repo) && $0.sources.contains(s) }
        case .leftovers: list = list.filter { $0.kind != .workspace }
        case .overview, .agents, .usage, .disk, .vault, .sessions, .dedupe, .containers, .memory, .integrations: break
        }
        if !showStale { list = list.filter { $0.verdict != .dangling } }
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search) || $0.repoName.localizedCaseInsensitiveContains(search)
                    || ($0.branch ?? "").localizedCaseInsensitiveContains(search)
            }
        }
        return list.sorted(using: order)
    }

    private var staleCount: Int { store.stats.staleCount }
    private var selected: [Entry] { store.entries.filter { selection.contains($0.id) } }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView(store.isScanning ? "Scanning…" : "Nothing here",
                                       systemImage: store.isScanning ? "magnifyingglass" : "checkmark.seal",
                                       description: Text(store.isScanning ? "Results appear as they are measured." : "Nothing matches. Clear the search or change the view options."))
            } else {
                table(rows)
            }
            actionBar(rows)
        }
        .navigationTitle(section.title)
        .navigationSubtitle("\(rows.count) items · \(store.total(rows).bytesString)")
        .searchable(text: $search, prompt: "Search name, repo or branch")
        .inspector(isPresented: $showInspector) {
            Group {
                if selected.count == 1, let e = selected.first {
                    DetailView(entry: e)
                } else {
                    VStack(spacing: 6) {
                        Text(selected.isEmpty ? "No selection" : "\(selected.count) selected").font(.headline)
                        Text(selected.isEmpty ? "Select a row to see its details." : "Removing them frees up to \(store.total(selected).bytesString).")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
        .onChange(of: selection) { _, new in if new.count == 1 { showInspector = true } }
        .toolbar {
            ToolbarItem { Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") } }
            ToolbarItem {
                Menu {
                    Stepper("Idle after \(store.staleDays) days", value: $store.staleDays, in: 3...180)
                    Toggle("Show \(staleCount) stale records", isOn: $showStale)
                    Divider()
                    Button(store.prRefreshing ? "Refreshing pull requests…" : "Refresh pull requests") { Task { await store.fetchPRs() } }
                        .disabled(store.prRefreshing || PRService.gh == nil)
                } label: { Label("View options", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
    }

    // MARK: Table

    private func table(_ rows: [Entry]) -> some View {
        let maxSize = Double(max(rows.map(\.sizeValue).max() ?? 1, 1))
        return Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { e in
                HStack(spacing: 10) {
                    Image(systemName: icon(e)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(e.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            if !store.runningAgents(in: e).isEmpty { Pill(text: "Agent running", color: .green) }
                        }
                        Text(subtitle(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }.width(min: 170, ideal: 300)
            TableColumn("Git") { e in
                if let g = e.gitSummary { Pill(text: g.text, color: g.color) }
            }.width(min: 120, ideal: 150)
            TableColumn("Size", value: \.sizeValue) { e in
                if e.measured {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((e.size ?? 0).bytesString).monospacedDigit()
                        if e.artifactBytes > 0 {
                            // Icon instead of the word "rebuildable": the full label clipped in a narrow column.
                            Label(e.artifactBytes.bytesString, systemImage: "shippingbox")
                                .font(.caption).foregroundStyle(.orange).monospacedDigit().lineLimit(1)
                                .help("\(e.artifactBytes.bytesString) of rebuildable build folders")
                        }
                    }
                } else { ProgressView().controlSize(.mini) }
            }.width(min: 90, ideal: 110)
            TableColumn("Last active", value: \.activityValue) { e in
                if let d = e.lastActivity { Text(d.formatted(.relative(presentation: .numeric))).foregroundStyle(.secondary) }
            }.width(min: 80, ideal: 100)
            TableColumn("Status") { e in
                let (t, c) = e.statusPill
                Pill(text: t, color: c)
            }.width(min: 110, ideal: 125)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            let list = store.entries.filter { ids.contains($0.id) }
            if let first = list.first, list.count == 1 {
                Button("Reveal in Finder") { store.reveal(first) }
                if first.kind == .workspace { Button("Open in Terminal") { store.openTerminal(first) } }
                Divider()
            }
            if list.contains(where: { !$0.artifacts.isEmpty }) {
                Button("Clean build artifacts…") { store.propose(.purgeArtifacts, for: list) }
            }
            if list.contains(where: { $0.kind != .repo }) {
                Button("Remove…", role: .destructive) { store.propose(.removeWorkspaces, for: list) }
            }
        }
    }

    private func subtitle(_ e: Entry) -> String {
        switch e.kind {
        case .workspace: [e.repoName, e.branch].compactMap { $0 }.joined(separator: " · ")
        default: e.note
        }
    }

    private func icon(_ e: Entry) -> String {
        switch e.kind {
        case .sessionData: "bubble.left.and.text.bubble.right"
        case .cache: "internaldrive"
        case .repo: "externaldrive.connected.to.line.below"
        case .workspace: e.sources.contains(.conductor) ? Source.conductor.symbol :
            e.sources.contains(.claude) ? Source.claude.symbol : Source.git.symbol
        }
    }

    // MARK: Action bar

    private func actionBar(_ rows: [Entry]) -> some View {
        let sel = selected
        let safe = rows.filter { $0.verdict == .deprecated && $0.safety != .danger && ($0.size ?? 0) > 0 }
        let artifactBytes = sel.reduce(Int64(0)) { $0 + $1.artifactBytes }
        let removable = sel.filter { $0.kind != .repo }

        // Wide: everything. Narrow: drop the summary text, then shorten the labels. Buttons never truncate.
        return ViewThatFits(in: .horizontal) {
            barLayout(sel: sel, safe: safe, removable: removable, artifactBytes: artifactBytes, compact: false)
            barLayout(sel: sel, safe: safe, removable: removable, artifactBytes: artifactBytes, compact: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func barLayout(sel: [Entry], safe: [Entry], removable: [Entry], artifactBytes: Int64, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button { selection = Set(safe.map(\.id)) } label: {
                Label(compact ? "Safe (\(safe.count))" : "Select all safe (\(safe.count))", systemImage: "checkmark.circle")
            }.disabled(safe.isEmpty).fixedSize()
            if !selection.isEmpty { Button("Clear") { selection = [] }.buttonStyle(.link).fixedSize() }
            Spacer(minLength: 8)
            if sel.isEmpty {
                if !compact { Text("Select items to clean up").foregroundStyle(.secondary).lineLimit(1) }
            } else {
                if !compact {
                    Text("\(sel.count) selected · \(store.total(sel).bytesString)").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if artifactBytes > 0 {
                    Button(compact ? "Clean · \(artifactBytes.bytesString)" : "Clean build folders · \(artifactBytes.bytesString)") {
                        store.propose(.purgeArtifacts, for: sel)
                    }.fixedSize()
                }
                if !removable.isEmpty {
                    Button(role: .destructive) { store.propose(.removeWorkspaces, for: sel) } label: {
                        Text("Remove · \(store.total(removable).bytesString)")
                    }.buttonStyle(.borderedProminent).tint(.red).fixedSize()
                }
            }
        }
    }
}

// MARK: - Inspector

struct DetailView: View {
    @EnvironmentObject var store: Store
    let entry: Entry

    var body: some View {
        let e = entry
        let (pillText, pillColor) = e.statusPill
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(e, pillText, pillColor)
                if let n = e.neededness { needCard(n) }
                if let g = e.git, e.kind == .workspace { gitSection(e, g) }
                if !e.reasons.isEmpty { whySection(e) }
                storage(e)
                details(e)
                actions(e)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Header

    private func header(_ e: Entry, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e.name).font(.title3.bold()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            HStack(spacing: 10) {
                Pill(text: text, color: color)
                ForEach(Source.allCases.filter(e.sources.contains), id: \.self) { s in
                    Label(s.rawValue, systemImage: s.symbol).font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            if !store.runningAgents(in: e).isEmpty { Pill(text: "An agent is running here", color: .green) }
        }
    }

    // MARK: Still needed?

    private func needCard(_ n: Neededness) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: n.symbol).font(.title3).foregroundStyle(n.color).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.headline).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                Text(n.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(n.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(n.color.opacity(0.35), lineWidth: 0.5))
    }

    // MARK: Git

    private func gitSection(_ e: Entry, _ g: GitInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Git").font(.headline)
                Spacer()
                if store.prRefreshing { ProgressView().controlSize(.mini) }
                else if PRService.gh != nil { Button { Task { await store.fetchPRs() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh pull requests") }
            }
            VStack(spacing: 0) {
                fact("Working tree", g.dirtyCount == 0 ? "Clean" : "\(g.dirtyCount) uncommitted", g.dirtyCount == 0 ? .green : .orange)
                Divider()
                fact("Pushed", g.unpushed == 0 ? "All on a remote" : "\(g.unpushed) only here", g.unpushed == 0 ? .green : .orange)
                Divider()
                fact("Versus \(g.defaultBranch)", versus(g, pr: e.pr), (g.merged || (e.pr?.state == "MERGED" && g.unpushedAfterMerge == 0)) ? .green : .secondary)
                if let s = g.lastSubject, !s.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last commit" + (g.lastCommit.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(s).font(.callout).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                }
            }.panel(10)

            if let pr = e.pr {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Pill(text: pr.state == "OPEN" ? (pr.isDraft == true ? "Draft" : "Open") : pr.state.capitalized,
                             color: pr.state == "OPEN" ? .blue : pr.state == "MERGED" ? .green : .gray)
                        Text("#\(pr.number)").fontWeight(.medium)
                        Spacer(minLength: 4)
                        Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: { Label("GitHub", systemImage: "arrow.up.right.square") }
                            .controlSize(.small).fixedSize().help("Open pull request on GitHub")
                    }
                    Text(pr.title).font(.callout).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    if !pr.detailLine.isEmpty { Text(pr.detailLine).font(.caption).foregroundStyle(.secondary) }
                }.padding(12).panel(10)
            } else {
                Text(PRService.gh == nil ? "Install the GitHub CLI (gh) to see pull request status." : "No pull request found for this branch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func versus(_ g: GitInfo, pr: PRInfo?) -> String {
        if g.merged { return "Merged" }
        // After a squash merge git still counts the branch's own commits as "ahead"; the PR is the real answer.
        if let pr, pr.state == "MERGED", g.unpushedAfterMerge == 0 { return "Landed via #\(pr.number)" }
        switch (g.aheadOfBase, g.behindBase) {
        case (0, 0): return "Same as \(g.defaultBranch)"
        case (let a, 0): return "\(a) ahead"
        case (0, let b): return "\(b) behind"
        case (let a, let b): return "\(a) ahead, \(b) behind"
        }
    }

    private func fact(_ k: String, _ v: String, _ dot: Color) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(width: 92, alignment: .leading)
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(v).font(.callout).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Why

    private func whySection(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why it's flagged").font(.headline)
            ForEach(e.reasons, id: \.self) { r in
                Label(r, systemImage: "circle.fill").labelStyle(BulletStyle()).font(.callout)
            }
        }
    }

    // MARK: Storage

    private func storage(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.headline)
                Spacer()
                Text((e.size ?? 0).bytesString).font(.figure(22)).monospacedDigit()
            }
            if e.artifactBytes > 0, let size = e.size, size > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Rectangle().fill(.secondary.opacity(0.5))
                            .frame(width: geo.size.width * Double(max(0, size - e.artifactBytes)) / Double(size))
                        Rectangle().fill(Color.orange)
                    }.clipShape(Capsule())
                }.frame(height: 6)
                ForEach(e.artifacts.prefix(6)) { a in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox").foregroundStyle(.orange).frame(width: 16)
                        Text(a.path.replacingOccurrences(of: e.path + "/", with: ""))
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(a.bytes.bytesString).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }.font(.callout)
                }
                if e.artifacts.count > 6 { Text("and \(e.artifacts.count - 6) more").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    // MARK: Details

    private func details(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.headline)
            kv("Repository", e.repoName)
            if let b = e.branch { kv("Branch", b) }
            if let d = e.lastActivity { kv("Last activity", d.formatted(date: .abbreviated, time: .shortened)) }
            if e.sources.contains(.conductor), let s = e.conductorState { kv("Conductor", s) }
            kv("Path", e.path)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private func actions(_ e: Entry) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button("Reveal in Finder") { store.reveal(e) }
                if e.kind == .workspace { Button("Terminal") { store.openTerminal(e) } }
                Spacer(minLength: 0)
            }
            if !e.artifacts.isEmpty {
                Button { store.propose(.purgeArtifacts, for: [e]) } label: {
                    Label("Clean build folders · \(e.artifactBytes.bytesString)", systemImage: "wind").frame(maxWidth: .infinity)
                }.controlSize(.large)
            }
            if e.kind != .repo {
                Button(role: .destructive) { store.propose(.removeWorkspaces, for: [e]) } label: {
                    Label(e.exists ? "Remove · \((e.size ?? 0).bytesString)" : "Clean up record", systemImage: "trash").frame(maxWidth: .infinity)
                }.controlSize(.large).buttonStyle(.borderedProminent).tint(.red)
            }
        }
    }
}

struct BulletStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
