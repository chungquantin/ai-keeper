import SwiftUI

struct DiskNode: Identifiable, Hashable, Codable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    var size: Int64?
    var hint: String? { DiskModel.cleanable[name] }
}

@MainActor
final class DiskModel: ObservableObject {
    @Published var path = home
    @Published var nodes: [DiskNode] = []
    @Published var measuring = false
    @Published var large: [DiskNode] = []
    @Published var scanningLarge = false

    @Published var measuredAt: Date?

    /// Results are kept on disk. A folder is measured the first time it's opened, and again only when Refresh is pressed.
    struct CachedDir: Codable { var date: Date; var nodes: [DiskNode] }
    private var cache: [String: CachedDir] = Persist.load([String: CachedDir].self, "disk-analyzer.json") ?? [:]
    private var generation = 0

    private func saveCache() {
        if cache.count > 150 {   // keep the most recently measured folders
            for k in cache.sorted(by: { $0.value.date < $1.value.date }).prefix(cache.count - 150).map(\.key) { cache[k] = nil }
        }
        let snapshot = cache
        Task.detached(priority: .background) { Persist.save(snapshot, "disk-analyzer.json") }
    }

    /// Something under `path` was deleted: drop it from cached listings and shrink the folders above it, without re-measuring.
    func forget(path: String, bytes: Int64) {
        cache[path] = nil
        for k in Array(cache.keys) where path.hasPrefix(k + "/") {
            guard var dir = cache[k] else { continue }
            if let i = dir.nodes.firstIndex(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                if dir.nodes[i].path == path { dir.nodes.remove(at: i) }
                else { dir.nodes[i].size = max(0, (dir.nodes[i].size ?? 0) - bytes) }
                dir.nodes.sort { ($0.size ?? -1) > ($1.size ?? -1) }
                cache[k] = dir
                if k == self.path { nodes = dir.nodes }
            }
        }
        saveCache()
    }

    /// Folder names that are regenerated on demand.
    nonisolated static let cleanable: [String: String] = [
        "node_modules": "Dependencies", "DerivedData": "Xcode build", "Caches": "Caches", ".cache": "Caches",
        ".npm": "npm cache", ".gradle": "Gradle cache", "target": "Build output", ".next": "Build output",
        ".build": "Build output", "Pods": "Dependencies", ".Trash": "Trash", "__pycache__": "Bytecode",
        ".venv": "Virtualenv", "Logs": "Logs", "CoreSimulator": "Simulators",
    ]

    var total: Int64 { nodes.reduce(0) { $0 + ($1.size ?? 0) } }
    var crumbs: [(name: String, path: String)] {
        var acc = "", out: [(String, String)] = [("/", "/")]
        for c in path.split(separator: "/") { acc += "/" + c; out.append((String(c), acc)) }
        return out
    }

    func open(_ p: String, force: Bool = false) {
        generation += 1
        let g = generation
        path = p
        large = []
        if !force, let c = cache[p] { nodes = c.nodes; measuredAt = c.date; measuring = false; return }
        nodes = []
        measuredAt = nil
        measuring = true

        Task {
            let listed = await Task.detached { Self.list(p) }.value
            guard g == generation else { return }
            nodes = listed.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
            let dirs = listed.filter { $0.size == nil }

            await withTaskGroup(of: (String, Int64).self) { group in
                var next = 0
                func feed() {
                    guard next < dirs.count else { return }
                    let d = dirs[next]; next += 1
                    group.addTask(priority: .utility) { (d.path, Shell.du(d.path)) }
                }
                for _ in 0..<6 { feed() }
                while let (path, size) = await group.next() {
                    guard g == generation else { group.cancelAll(); return }
                    if let i = nodes.firstIndex(where: { $0.path == path }) { nodes[i].size = size }
                    nodes.sort { ($0.size ?? -1) > ($1.size ?? -1) }
                    feed()
                }
            }
            guard g == generation else { return }
            measuring = false
            measuredAt = .now
            cache[p] = CachedDir(date: .now, nodes: nodes)
            saveCache()
        }
    }

    nonisolated static func list(_ p: String) -> [DiskNode] {
        let url = URL(fileURLWithPath: p)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return items.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
            return DiskNode(name: u.lastPathComponent, path: u.path, isDir: isDir,
                            size: isDir ? nil : Int64(v?.totalFileAllocatedSize ?? 0))
        }
    }

    func trash(_ n: DiskNode) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: n.path), resultingItemURL: nil)
        nodes.removeAll { $0.id == n.id }
        large.removeAll { $0.id == n.id }
        forget(path: n.path, bytes: n.size ?? 0)
    }

    func findLarge() {
        let p = path
        scanningLarge = true
        Task {
            let out = await Task.detached {
                Shell.run("/usr/bin/find", [p, "-xdev", "-type", "f", "-size", "+100M",
                                            "-exec", "stat", "-f", "%z\t%N", "{}", "+"]).out
            }.value
            large = out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 1)
                guard f.count == 2, let s = Int64(f[0]) else { return nil }
                let path = String(f[1])
                return DiskNode(name: (path as NSString).lastPathComponent, path: path, isDir: false, size: s)
            }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            scanningLarge = false
        }
    }
}

struct DiskView: View {
    @ObservedObject var model: DiskModel
    @State private var showLarge = false
    @State private var pendingDelete: DiskNode?
    @State private var error: String?

    private let places: [(String, String, String)] = [
        ("Home", "house", home), ("Developer", "hammer", "\(home)/Developer"),
        ("Library", "books.vertical", "\(home)/Library"), ("Downloads", "arrow.down.circle", "\(home)/Downloads"),
        ("Applications", "app.badge", "/Applications"), ("Conductor", "music.note.list", "\(home)/conductor"),
        ("Claude", "sparkles", "\(home)/.claude"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showLarge { largeList } else { folderList }
        }
        .navigationTitle("Disk Analyzer")
        .navigationSubtitle(model.measuring ? "Measuring in the background…" : "\(model.total.bytesString)" + (model.measuredAt.map { " · measured \($0.formatted(.relative(presentation: .named)))" } ?? ""))
        .onAppear { if model.nodes.isEmpty { model.open(model.path) } }
        .confirmationDialog("Move “\(pendingDelete?.name ?? "")” to Trash?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash (\((pendingDelete?.size ?? 0).bytesString))", role: .destructive) {
                if let n = pendingDelete { do { try model.trash(n) } catch { self.error = error.localizedDescription } }
                pendingDelete = nil
            }
        } message: { Text(pendingDelete?.path ?? "") }
        .alert("Couldn't remove", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { model.open((model.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "chevron.up") }
                    .disabled(model.path == "/").help("Up one level")
                Menu {
                    ForEach(places, id: \.0) { p in Button { model.open(p.2) } label: { Label(p.0, systemImage: p.1) } }
                } label: { Label("Jump to", systemImage: "star") }.fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.crumbs.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Button(c.name) { model.open(c.path) }.buttonStyle(.link)
                        }
                    }
                }
                Spacer()
                Picker("", selection: $showLarge) {
                    Text("Folders").tag(false); Text("Large files").tag(true)
                }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
                Button { model.open(model.path, force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Measure this folder again. Results are otherwise kept until you refresh.").disabled(model.measuring)
            }
            if model.measuring { ProgressView().controlSize(.small).progressViewStyle(.linear) }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Folder list

    private var folderList: some View {
        let total = Double(max(model.total, 1))
        return List {
            ForEach(model.nodes) { n in
                HStack(spacing: 10) {
                    Image(systemName: n.isDir ? "folder.fill" : "doc").foregroundStyle(n.isDir ? Color.blue : .secondary).frame(width: 20)
                    Text(n.name).lineLimit(1).frame(minWidth: 140, alignment: .leading)
                    if let h = n.hint { Pill(text: h, color: .orange) }
                    GeometryReader { geo in
                        Capsule().fill(.indigo.opacity(0.8))
                            .frame(width: geo.size.width * Double(n.size ?? 0) / total, height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }.frame(height: 18)
                    Group {
                        if let s = n.size { Text(s.bytesString) } else { ProgressView().controlSize(.mini) }
                    }.monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(n.size.map { String(format: "%.0f%%", Double($0) / total * 100) } ?? "")
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).opacity(n.isDir ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if n.isDir { model.open(n.path) } else { reveal(n) } }
                .contextMenu { actions(n) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay { if model.nodes.isEmpty && !model.measuring { ContentUnavailableView("Empty or no access", systemImage: "folder") } }
    }

    // MARK: Large files

    private var largeList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files over 100 MB under \(model.path.replacingOccurrences(of: home, with: "~"))").foregroundStyle(.secondary)
                Spacer()
                Button(model.scanningLarge ? "Searching…" : "Search") { model.findLarge() }.disabled(model.scanningLarge)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            List(model.large) { n in
                HStack {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(n.name).lineLimit(1)
                        Text(n.path.replacingOccurrences(of: home, with: "~")).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text((n.size ?? 0).bytesString).monospacedDigit()
                }.contextMenu { actions(n) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay { if model.scanningLarge { ProgressView() } else if model.large.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "magnifyingglass", description: Text("Press Search to look for big files."))
            } }
        }
    }

    @ViewBuilder private func actions(_ n: DiskNode) -> some View {
        if n.isDir { Button("Open") { model.open(n.path) } }
        Button("Reveal in Finder") { reveal(n) }
        Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.path, forType: .string) }
        Divider()
        Button("Move to Trash…", role: .destructive) { pendingDelete = n }
    }

    private func reveal(_ n: DiskNode) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)]) }
}
