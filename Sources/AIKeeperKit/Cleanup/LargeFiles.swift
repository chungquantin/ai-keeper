import SwiftUI

// Cleanup › Files › Large and old: the biggest single files in your home folder, with a plain answer to "what if I regret it?".

struct BigFile: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case movie = "Movies", vm = "Virtual machines", archive = "Archives", image = "Disk images", other = "Other"
        var symbol: String { switch self { case .movie: "film"; case .vm: "desktopcomputer"; case .archive: "doc.zipper"; case .image: "opticaldisc"; case .other: "doc" } }
        var color: Color { switch self { case .movie: Color(red: 0.93, green: 0.28, blue: 0.6); case .vm: Color(red: 0.3, green: 0.55, blue: 0.96); case .archive: Color(red: 0.22, green: 0.74, blue: 0.97); case .image: Color(red: 0.56, green: 0.56, blue: 0.58); case .other: Color(red: 0.72, green: 0.72, blue: 0.75) } }
    }
    var path: String; var bytes: Int64; var opened: Date?; var inCloud: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent.replacingOccurrences(of: home, with: "~") }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var kind: Kind {
        switch ext {
        case "mov", "mp4", "mkv", "avi", "m4v", "webm": .movie
        case "utm", "vmdk", "vdi", "qcow2", "vhd", "vhdx", "pvm": .vm
        case "zip", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz": .archive
        case "dmg", "iso", "pkg": .image
        default: .other
        }
    }
    /// Installers can be fetched again; everything else is only here unless iCloud holds a copy.
    var tier: Tier { inCloud ? .onRemote : (ext == "dmg" || ext == "pkg") && path.hasPrefix(home + "/Downloads/") ? .rebuildable : .onlyHere }
    var regret: String { inCloud ? "In iCloud" : tier == .rebuildable ? "Download again" : "Only here" }
    func notOpened(forDays d: Int) -> Bool { (opened ?? .distantPast) < Date().addingTimeInterval(-Double(d) * 86_400) }
}

@MainActor @Observable final class FilesModel {
    var files: [BigFile] = []
    var loading = false
    var loaded = false

    func scanIfNeeded() async { if !loaded { await scan() } }

    func scan(minBytes: Int64 = 100_000_000) async {
        if Demo.enabled { files = Self.demo; loaded = true; return }
        loading = true
        let found = await Task.detached(priority: .utility) { Self.walk(minBytes: minBytes) }.value
        files = found; loaded = true; loading = false
    }

    func forget(_ paths: Set<String>) { files.removeAll { paths.contains($0.path) } }

    nonisolated private static func walk(minBytes: Int64) -> [BigFile] {
        let skip: Set<String> = ["Library", "Developer", ".Trash", "node_modules", ".git", "Applications", ".cache", ".npm", ".cargo", ".rustup", ".docker", ".orbstack"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey, .isUbiquitousItemKey, .isPackageKey]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: home), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [BigFile] = []
        for case let u as URL in en {
            if skip.contains(u.lastPathComponent) { en.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            // A package (.utm, .app, a photo library) counts as one item; measure it instead of walking inside.
            if v.isPackage == true {
                en.skipDescendants()
                if u.pathExtension == "app" { continue }
                let b = Shell.du(u.path)
                if b >= minBytes { out.append(BigFile(path: u.path, bytes: b, opened: v.contentAccessDate ?? v.contentModificationDate, inCloud: false)) }
                continue
            }
            guard v.isRegularFile == true, let n = v.fileAllocatedSize, Int64(n) >= minBytes else { continue }
            out.append(BigFile(path: u.path, bytes: Int64(n), opened: v.contentAccessDate ?? v.contentModificationDate, inCloud: v.isUbiquitousItem == true))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static var demo: [BigFile] {
        let d = { (n: Int) in Date().addingTimeInterval(-Double(n) * 86_400) }
        return [BigFile(path: home + "/Movies/Recordings/Product launch recording.mov", bytes: 4_200_000_000, opened: d(430), inCloud: false),
                BigFile(path: home + "/Downloads/Xcode_16.2.dmg", bytes: 2_400_000_000, opened: d(270), inCloud: false),
                BigFile(path: home + "/Downloads/project-backup-2024.zip", bytes: 2_900_000_000, opened: d(480), inCloud: false),
                BigFile(path: home + "/Pictures/wedding-photos-export.zip", bytes: 1_000_000_000, opened: d(700), inCloud: true)]
    }
}

private enum SizeFilter: String, CaseIterable { case over100 = "Over 100 MB", over500 = "Over 500 MB", year = "Not opened in a year", downloads = "Downloads", movies = "Movies", images = "Disk images", archives = "Archives"
    func matches(_ f: BigFile) -> Bool {
        switch self {
        case .over100: true
        case .over500: f.bytes >= 500_000_000
        case .year: f.notOpened(forDays: 365)
        case .downloads: f.path.hasPrefix(home + "/Downloads/")
        case .movies: f.kind == .movie
        case .images: f.kind == .image
        case .archives: f.kind == .archive
        }
    }
}

struct LargeFilesView: View {
    @Environment(Store.self) private var store
    @State private var filter: SizeFilter = .over500
    @State private var query = ""
    @State private var selected: String?
    @State private var checked: Set<String> = []
    @State private var removing: [BigFile]?

    private var model: FilesModel { store.files }
    private var rows: [BigFile] { model.files.filter { filter.matches($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } }

    var body: some View {
        let rows = self.rows
        let pick = model.files.first { $0.id == selected } ?? rows.first
        GeometryReader { g in
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    kinds
                    toolbar
                    list(rows, pick: pick)
                    HStack {
                        let picked = model.files.filter { checked.contains($0.id) }
                        Text(picked.isEmpty ? "\(rows.count) files · \(rows.reduce(0) { $0 + $1.bytes }.bytesString)" : "\(picked.count) selected · \(picked.reduce(0) { $0 + $1.bytes }.bytesString)").font(.bCaption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Move \(picked.count) to Trash") { removing = picked }.buttonStyle(.brandProminent).disabled(picked.isEmpty)
                    }.frame(height: 36)
                }.padding(.horizontal, 28).padding(.vertical, 6)
                if let pick, g.size.width >= 980 { Divider(); inspector(pick).frame(width: 340) }
            }
        }
        .task { await model.scanIfNeeded() }
        .sheet(item: Binding(get: { removing.map { Removal(files: $0) } }, set: { removing = $0?.files })) { FileRemoveSheet(files: $0.files, onDone: { checked.subtract($0) }).environment(store) }
    }

    private struct Removal: Identifiable { let files: [BigFile]; var id: String { files.map(\.id).joined() } }

    private var kinds: some View {
        let totals = Dictionary(grouping: model.files, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.bytes } }
        let top = max(totals.values.max() ?? 1, 1)
        return HStack(spacing: 18) {
            ForEach(BigFile.Kind.allCases, id: \.self) { k in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(k.rawValue).font(.bCaption).lineLimit(1).minimumScaleFactor(0.8); Spacer(); Text((totals[k] ?? 0).bytesString).font(.bCaption.weight(.semibold)) }
                    GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(k.color).frame(width: g.size.width * CGFloat(totals[k] ?? 0) / CGFloat(top)) } }.frame(height: 5)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 14).background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SizeFilter.allCases, id: \.self) { f in
                        Button { filter = f } label: {
                            Text(f.rawValue).font(.brand(12, .medium)).lineLimit(1).fixedSize().padding(.horizontal, 10).frame(height: 26)
                                .background(f == filter ? Brand.primaryTint : Brand.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(f == filter ? Brand.accent : Brand.border))
                                .foregroundStyle(f == filter ? Brand.primaryText : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 2)
            }
            HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search files", text: $query).textFieldStyle(.plain).frame(width: 110) }
                .padding(.horizontal, 10).frame(height: 28).background(Brand.muted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func list(_ rows: [BigFile], pick: BigFile?) -> some View {
        VStack(spacing: 0) {
            if model.loading && model.files.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for big files…").foregroundStyle(.secondary) }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else if rows.isEmpty {
                Text("Nothing matches. Try a smaller size.").foregroundStyle(.secondary).padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { LazyVStack(spacing: 0) { ForEach(rows) { f in row(f, on: f.id == pick?.id) } } }
            }
        }.frame(maxHeight: .infinity)
        .background(Brand.card).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }

    private func row(_ f: BigFile, on: Bool) -> some View {
        Button { selected = f.id } label: {
            HStack(spacing: 12) {
                Check(on: checked.contains(f.id)) { if checked.contains(f.id) { checked.remove(f.id) } else { checked.insert(f.id) } }
                Image(systemName: f.kind.symbol).foregroundStyle(f.kind.color).frame(width: 30, height: 30).background(f.kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).font(.bBody.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(f.folder).font(.bCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Tag(text: f.regret, tone: f.tier.tone).frame(width: 110, alignment: .leading)
                Text(f.bytes.bytesString).font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
                Text(f.opened.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) } ?? "unknown").font(.bCaption2).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }.padding(.horizontal, 16).padding(.vertical, 8).background(on ? Brand.primaryTint : Color.clear).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .top) { Divider() }
    }

    private func inspector(_ f: BigFile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: f.kind.symbol).font(.system(size: 20)).foregroundStyle(f.kind.color).frame(width: 44, height: 44).background(f.kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) { Text(f.name).font(.bHeadline).lineLimit(2); Text("\(f.kind.rawValue) · \(f.bytes.bytesString)").font(.bCaption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) { Tag(text: f.regret, tone: f.tier.tone); if f.notOpened(forDays: 365) { Tag(text: "Not opened in a year") } }
            VStack(spacing: 0) { kv("Where", f.folder); kv("Last opened", f.opened?.formatted(date: .abbreviated, time: .omitted) ?? "unknown"); kv("Backed up", f.inCloud ? "In iCloud" : "Not in iCloud") }
            Note(text: f.tier == .rebuildable ? "Safe to remove. Download it again from the vendor." : f.tier == .onRemote ? "A copy is in iCloud. Moving it to the Trash removes it from this Mac only if iCloud keeps it." : "Check before you remove. Nothing else has a copy. In the Trash you can put it back for 30 days.")
            Spacer(minLength: 0)
            Button { removing = [f] } label: { Text("Move to Trash · \(f.bytes.bytesString)").frame(maxWidth: .infinity) }.buttonStyle(.brandProminent).controlSize(.large)
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: { Text("Reveal in Finder").frame(maxWidth: .infinity) }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) } label: { Text("Open").frame(maxWidth: .infinity) }
            }.controlSize(.large)
        }.padding(20).frame(maxHeight: .infinity, alignment: .top).background(Brand.card)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing).lineLimit(2) }.font(.bCaption).padding(.vertical, 7).overlay(alignment: .top) { Divider() }
    }
}

struct FileRemoveSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let files: [BigFile]
    var onDone: (Set<String>) -> Void
    @State private var jobs: [CleanupJob] = []
    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if jobs.isEmpty {
                Text("Move \(files.count == 1 ? files[0].name : "\(files.count) files") to the Trash?").font(.bTitle2.bold())
                Text("Put it back from History for 30 days. Space comes back when the Trash is emptied.").font(.bCallout).foregroundStyle(.secondary)
                ScrollView { VStack(spacing: 0) { ForEach(files) { f in
                    HStack { VStack(alignment: .leading, spacing: 1) { Text(f.name).lineLimit(1); Text(f.folder).font(.bCaption2).foregroundStyle(.secondary) }; Spacer(); Tag(text: f.regret, tone: f.tier.tone); Text(f.bytes.bytesString).monospacedDigit() }
                        .padding(.vertical, 7).overlay(alignment: .top) { Divider() } } } }.frame(maxHeight: 220)
                HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Move \(files.reduce(0) { $0 + $1.bytes }.bytesString) to Trash") { run() }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent).controlSize(.large) }
            } else { BasketProgress(jobs: jobs, started: started, freeBefore: 0, deleteNow: false) { dismiss() } }
        }.padding(26).frame(width: 520)
    }

    private func run() {
        let entries: [Entry] = files.map { f in
            var e = Entry(id: "file:" + f.path, kind: .sessionData, name: f.name, path: f.path, repoPath: nil, repoName: "Files", branch: nil, sources: [.dev])
            e.size = f.bytes; e.measured = true; e.verdict = .deprecated
            return e
        }
        var o = CleanupOptions(); o.permanent = false; o.vault = false; o.deleteMergedBranches = false
        started = Date()
        let job = store.startCleanup(CleanupPlan(mode: .removeWorkspaces, entries: entries), options: o)
        jobs = [job]
        let gone = Set(files.map(\.path))
        Task { while job.state != .finished { try? await Task.sleep(for: .milliseconds(400)) }; store.files.forget(gone); onDone(gone) }
    }
}
