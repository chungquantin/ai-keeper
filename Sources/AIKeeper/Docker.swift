import SwiftUI

/// Docker / OrbStack usage and one-click prune, through the `docker` CLI.
enum DockerCLI {
    static var path: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Row: Identifiable { var id: String { type }; let type: String; let total: String; let active: String; let size: String; let reclaimable: String }

    static func usage() -> (rows: [Row], error: String?) {
        guard let docker = path else { return ([], "Docker isn't installed. Install Docker Desktop or OrbStack to use this.") }
        let r = Shell.run(docker, ["system", "df", "--format", "{{json .}}"])
        guard r.status == 0 else { return ([], "Docker isn't running. Start Docker Desktop or OrbStack, then refresh.") }
        let rows = r.out.split(separator: "\n").compactMap { line -> Row? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return Row(type: o["Type"] as? String ?? "?", total: o["TotalCount"] as? String ?? "", active: o["Active"] as? String ?? "",
                       size: o["Size"] as? String ?? "", reclaimable: o["Reclaimable"] as? String ?? "")
        }
        return (rows, nil)
    }

    static func prune(_ args: [String]) -> String {
        guard let docker = path else { return "docker not found" }
        let r = Shell.run(docker, args)
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DockerView: View {
    @State private var rows: [DockerCLI.Row] = []
    @State private var error: String?
    @State private var loading = false
    @State private var log = ""
    @State private var running: String?
    @State private var pending: Action?

    struct Action: Identifiable {
        let id: String, title: String, detail: String, args: [String], dangerous: Bool
    }

    private let actions: [Action] = [
        .init(id: "builder", title: "Build cache", detail: "Layers from past builds. Rebuilt on demand, so the next build is slower once.", args: ["builder", "prune", "-af"], dangerous: false),
        .init(id: "images", title: "Unused images", detail: "Images no container uses. They're pulled again when needed.", args: ["image", "prune", "-af"], dangerous: false),
        .init(id: "containers", title: "Stopped containers", detail: "Containers that aren't running. Their writable layers are lost.", args: ["container", "prune", "-f"], dangerous: false),
        .init(id: "volumes", title: "Unused volumes", detail: "Volumes no container uses. Databases and data stored there are deleted for good.", args: ["volume", "prune", "-af"], dangerous: true),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    ContentUnavailableView("Docker unavailable", systemImage: "shippingbox", description: Text(error)).padding(.top, 30)
                } else {
                    Text("What Docker and OrbStack are holding on disk. Pruning removes only things nothing is using.")
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(rows) { r in
                            HStack {
                                Text(r.type).fontWeight(.medium).frame(width: 130, alignment: .leading)
                                Text("\(r.total) total, \(r.active) active").foregroundStyle(.secondary)
                                Spacer()
                                Text(r.size).monospacedDigit()
                                Text("Reclaimable \(r.reclaimable)").foregroundStyle(Brand.accent).monospacedDigit().frame(width: 190, alignment: .trailing)
                            }.padding(.horizontal, 16).padding(.vertical, 11)
                            if r.id != rows.last?.id { Divider() }
                        }
                    }.panel()

                    Text("Clean up").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(actions) { a in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title).fontWeight(.medium)
                                    Text(a.detail).font(.callout).foregroundStyle(a.dangerous ? Color.orange : .secondary)
                                }
                                Spacer()
                                if running == a.id { ProgressView().controlSize(.small) }
                                else { Button("Prune…") { pending = a }.disabled(running != nil) }
                            }.padding(.horizontal, 16).padding(.vertical, 11)
                            if a.id != actions.last?.id { Divider() }
                        }
                    }.panel()
                    if !log.isEmpty {
                        Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("OrbStack returns freed space to macOS automatically. Docker Desktop may keep it until you restart it.").font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 62) }   // keep the first row clear of the glass toolbar
        .navigationTitle("Containers")
        .toolbar { ToolbarItem { Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(loading) } }
        .task { await refresh() }
        .confirmationDialog(pending.map { "Prune \($0.title.lowercased())?" } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let a = pending {
                Button("Prune", role: a.dangerous ? .destructive : nil) { run(a) }
            }
        } message: { Text(pending?.detail ?? "") }
    }

    private func refresh() async {
        loading = true
        let r = await Task.detached { DockerCLI.usage() }.value
        rows = r.rows; error = r.error; loading = false
    }

    private func run(_ a: Action) {
        running = a.id; pending = nil
        Task {
            let out = await Task.detached { DockerCLI.prune(a.args) }.value
            log = out; running = nil
            await refresh()
        }
    }
}
