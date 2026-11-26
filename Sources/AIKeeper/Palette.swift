import SwiftUI

/// ⌘K: reaches any page, workspace, session or action by name, so rarely used things need no place in the sidebar.
struct PaletteView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked = 0
    @FocusState private var focused: Bool

    private struct Result: Identifiable {
        let id: String; let group: String; let title: String; let subtitle: String; let symbol: String; let kind: String; let run: () -> Void
    }

    private var all: [Result] {
        var r: [Result] = []
        for a in Area.allCases {
            for t in a.tabs {
                r.append(Result(id: "go-\(a.rawValue)-\(t.rawValue)", group: "Go to", title: t == a.firstTab ? a.rawValue : "\(a.rawValue): \(t.rawValue)", subtitle: "", symbol: a.symbol, kind: "Page") { nav.open(a, t) })
            }
        }
        r.append(Result(id: "act-rescan", group: "Actions", title: "Rescan everything", subtitle: "Workspaces, pull requests and the disk map", symbol: "arrow.clockwise", kind: "Action") { Task { await store.rescan() } })
        if !store.buildHolders.isEmpty {
            r.append(Result(id: "act-build", group: "Actions", title: "Clean build folders", subtitle: store.keptArtifactBytes.bytesString, symbol: "trash", kind: "Action") { store.propose(.purgeArtifacts, for: store.buildHolders) })
        }
        if !store.removableWorkspaces.isEmpty {
            r.append(Result(id: "act-ws", group: "Actions", title: "Review workspaces that are safe to remove", subtitle: "\(store.removableWorkspaces.count) · \(store.total(store.removableWorkspaces).bytesString)", symbol: "archivebox", kind: "Action") { nav.go(.deprecated) })
        }
        r.append(Result(id: "act-budget", group: "Actions", title: "Set a daily budget", subtitle: "Agents, Budgets", symbol: "dollarsign.circle", kind: "Action") { nav.open(.agents, .budgets) })
        for e in store.entries.filter({ $0.kind == .workspace }).prefix(300) {
            r.append(Result(id: "ws-\(e.id)", group: "Workspaces", title: e.name, subtitle: "\(e.repoName) · \((e.size ?? 0).bytesString)", symbol: "square.stack.3d.up", kind: "Workspace") { nav.go(.all); store.requestedSelection = e.id })
        }
        for s in store.sessions.sorted(by: { $0.last > $1.last }).prefix(100) {
            r.append(Result(id: "ses-\(s.id)", group: "Sessions", title: s.title.isEmpty ? s.project : s.title, subtitle: "\(s.agent.rawValue) · \(s.project)", symbol: "text.justify.left", kind: "Session") { nav.open(.sessions, .history) })
        }
        return r
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            let areas = Area.allCases.map { "go-\($0.rawValue)-\($0.firstTab.rawValue)" }
            return all.filter { $0.group == "Actions" } + all.filter { areas.contains($0.id) }
        }
        return Array(all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }.prefix(14))
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("Search pages, workspaces, sessions and actions", text: $query)
                    .textFieldStyle(.plain).font(.brand(16, .medium)).focused($focused)
                    .onSubmit { run(list) }
                    .onChange(of: query) { _, _ in picked = 0 }
                Text("esc").font(.brand(11, .medium)).padding(.horizontal, 7).padding(.vertical, 2).background(Brand.muted, in: Capsule()).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                        if i == 0 || list[i - 1].group != r.group {
                            Text(r.group).font(.brand(11, .medium)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
                        }
                        Button { picked = i; run(list) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: r.symbol).frame(width: 26, height: 26).background(Brand.muted, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.title).font(.bBody.weight(.medium)).lineLimit(1)
                                    if !r.subtitle.isEmpty { Text(r.subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Text(r.kind).font(.bCaption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(i == picked ? Brand.primaryTint : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.horizontal, 8)
                        }.buttonStyle(.plain)
                    }
                    if list.isEmpty { Text("Nothing matches \"\(query)\".").font(.bCaption).foregroundStyle(.secondary).padding(20) }
                }.padding(.bottom, 8)
            }.frame(maxHeight: 420)
            Divider()
            HStack(spacing: 18) { Text("↵ Open"); Text("esc Close") }.font(.bCaption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted)
        }
        .frame(width: 640)
        .background(Brand.popover)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { picked = min(picked + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { picked = max(picked - 1, 0); return .handled }
    }

    private func run(_ list: [Result]) {
        guard picked < list.count else { return }
        let r = list[picked]
        dismiss()
        DispatchQueue.main.async { r.run() }
    }
}
