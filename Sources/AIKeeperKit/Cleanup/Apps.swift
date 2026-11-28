import SwiftUI

// Cleanup › Apps: uninstall an app together with everything it left in ~/Library, or sweep what apps you already removed left behind.

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All", unused = "Not opened in 90 days", large = "Large", homebrew = "From Homebrew", dev = "Developer tools"
    var id: String { rawValue }
    func matches(_ a: InstalledApp) -> Bool {
        switch self {
        case .all: true
        case .unused: a.notOpened(forDays: 90)
        case .large: a.bytes >= 1_000_000_000
        case .homebrew: a.source == .homebrew
        case .dev: a.isDeveloperTool
        }
    }
}

/// What the confirm sheet is about to move to the Trash.
struct AppRemoval: Identifiable {
    let id = UUID()
    var apps: [InstalledApp]            // an app counts with the leftovers chosen for it; `includeBundle` says whether the app itself goes
    var includeBundle: Bool
    var orphans: [OrphanGroup] = []
    var paths: [(name: String, path: String, bytes: Int64)] {
        var out: [(String, String, Int64)] = []
        for a in apps { if includeBundle { out.append((a.name, a.path, a.bytes)) }; for l in a.leftovers { out.append(("\(a.name), \(l.kind)", l.path, l.bytes)) } }
        for g in orphans { for l in g.leftovers { out.append(("\(g.bundleID), \(l.kind)", l.path, l.bytes)) } }
        return out
    }
    var bytes: Int64 { paths.reduce(0) { $0 + $1.bytes } }
}

/// The app's own icon from macOS. When the app is not on this Mac (demo data) it looks the bundle up, then falls back to a lettered tile.
struct AppIcon: View {
    let path: String?; let bundleID: String; let name: String; var size: CGFloat = 34
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]
    private static func icon(path: String?, bundleID: String) -> NSImage? {
        let key = path ?? bundleID
        if let hit = cache[key] { return hit }
        var found: String?
        if let path, FileManager.default.fileExists(atPath: path) { found = path }
        else if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { found = u.path }
        guard let found else { return nil }
        let img = NSWorkspace.shared.icon(forFile: found); cache[key] = img
        return img
    }
    var body: some View {
        if let img = Self.icon(path: path, bundleID: bundleID) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white).frame(width: size, height: size)
                .background(tileColor(bundleID), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }
}

private func tileColor(_ id: String) -> Color {
    let palette: [UInt32] = [0x4C8DF6, 0x14B8A6, 0x7B82FF, 0xEC4899, 0xF59E0B, 0x8B5CF6, 0x22C55E, 0xEF4444]
    let h = id.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    let v = palette[abs(h) % palette.count]
    return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}

struct AppsTab: View {
    @Environment(Store.self) private var store
    @State private var filter: AppFilter = .all
    @State private var query = ""
    @State private var selected: String?
    @State private var checked: Set<String> = []
    @State private var skipped: Set<String> = []          // leftovers the person unticked
    @State private var removal: AppRemoval?

    private var model: AppModel { store.apps }
    private var rows: [InstalledApp] {
        model.apps.filter { filter.matches($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    var body: some View {
        let rows = self.rows
        let pick = model.apps.first { $0.id == selected } ?? rows.first
        GeometryReader { g in
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    if model.orphanBytes > 0 { orphanBanner }
                    toolbar
                    table(rows, pick: pick)
                    selectionBar
                }.padding(.horizontal, 28).padding(.vertical, 10)
                if let pick, g.size.width >= 980 { Divider(); inspector(pick).frame(width: 360) }
            }
        }
        .task { await model.measureIfNeeded() }
        .sheet(item: $removal) { AppRemoveSheet(removal: $0).environment(store) }
    }

    // MARK: Pieces

    private var orphanBanner: some View {
        HStack(spacing: 14) {
            TierChip(symbol: "trash", tone: .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.orphanBytes.bytesString) is left over from \(model.orphans.count) app\(model.orphans.count == 1 ? "" : "s") you already removed.").font(.bBody.weight(.semibold))
                Text("Preferences, caches and support folders nothing uses any more.").font(.bCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review leftovers") { removal = AppRemoval(apps: [], includeBundle: false, orphans: model.orphans) }.buttonStyle(.brandProminent).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(Brand.primaryTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppFilter.allCases) { f in
                        let n = model.apps.filter { f.matches($0) }.count
                        Button { filter = f } label: {
                            Text(f == .all ? "All \(n)" : "\(f.rawValue) · \(n)").font(.brand(12, .medium)).lineLimit(1).fixedSize().padding(.horizontal, 10).frame(height: 26)
                                .background(f == filter ? Brand.primaryTint : Brand.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(f == filter ? Brand.accent : Brand.border))
                                .foregroundStyle(f == filter ? Brand.primaryText : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 2)
            }
            HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search apps", text: $query).textFieldStyle(.plain).frame(width: 110) }
                .padding(.horizontal, 10).frame(height: 28).background(Brand.muted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func table(_ rows: [InstalledApp], pick: InstalledApp?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 16 + 34 + 12, height: 1)
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                Text("Source").frame(width: 90, alignment: .leading)
                Text("App").frame(width: 70, alignment: .trailing)
                Text("Leftovers").frame(width: 80, alignment: .trailing)
                Text("Last opened").frame(width: 100, alignment: .trailing)
            }.font(.bCaption2).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8).overlay(alignment: .bottom) { Divider() }
            if model.loading && model.apps.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding your apps…").foregroundStyle(.secondary) }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { a in row(a, on: a.id == pick?.id) }
                        if model.loading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Measuring \(model.progress.done) of \(model.progress.total)").font(.bCaption).foregroundStyle(.secondary) }.padding(14) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.card).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }

    private func row(_ a: InstalledApp, on: Bool) -> some View {
        Button { selected = a.id } label: {
            HStack(spacing: 12) {
                Check(on: checked.contains(a.id)) { if checked.contains(a.id) { checked.remove(a.id) } else { checked.insert(a.id) } }.disabled(!a.isRemovable)
                AppIcon(path: a.path, bundleID: a.bundleID, name: a.name, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).font(.bBody.weight(.semibold)).lineLimit(1)
                    Text(a.version.isEmpty ? a.bundleID : "Version \(a.version)").font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Tag(text: a.source.rawValue).frame(width: 90, alignment: .leading)
                Text(a.bytes > 0 ? a.bytes.bytesString : "…").font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
                Text(a.leftoverBytes > 0 ? a.leftoverBytes.bytesString : "–").font(.bBody).monospacedDigit().foregroundStyle(a.leftoverBytes > 500_000_000 ? Brand.reclaimText : .secondary).frame(width: 80, alignment: .trailing)
                Text(a.lastOpened.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) } ?? "never").font(.bCaption2).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(on ? Brand.primaryTint : Color.clear).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .top) { Divider() }
    }

    private var selectionBar: some View {
        let picked = model.apps.filter { checked.contains($0.id) }
        return HStack {
            Text(picked.isEmpty ? "Tick apps to remove several at once." : "\(picked.count) app\(picked.count == 1 ? "" : "s") · \(picked.reduce(0) { $0 + $1.totalBytes }.bytesString)").font(.bCaption).foregroundStyle(.secondary)
            Spacer()
            Button("Remove \(picked.count) app\(picked.count == 1 ? "" : "s")") { removal = AppRemoval(apps: picked, includeBundle: true) }.buttonStyle(.brandProminent).disabled(picked.isEmpty)
        }.frame(height: 40)
    }

    // MARK: Inspector

    private func inspector(_ a: InstalledApp) -> some View {
        let leftovers = a.leftovers.filter { !skipped.contains($0.path) }
        let leftBytes = leftovers.reduce(0) { $0 + $1.bytes }
        var chosen = a; chosen.leftovers = leftovers
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    AppIcon(path: a.path, bundleID: a.bundleID, name: a.name, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.bHeadline)
                        Text((a.version.isEmpty ? "" : "Version \(a.version) · ") + (a.lastOpened.map { "opened \($0.formatted(.relative(presentation: .named)))" } ?? "never opened")).font(.bCaption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) { Tag(text: "Reinstallable", tone: .green); Tag(text: a.source.rawValue) }
                Note(text: note(a))
                if !a.leftovers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What goes with it · \(a.leftoverBytes.bytesString)").font(.bCaption2).foregroundStyle(.secondary)
                        ForEach(a.leftovers) { l in
                            HStack(spacing: 10) {
                                Check(on: !skipped.contains(l.path)) { if skipped.contains(l.path) { skipped.remove(l.path) } else { skipped.insert(l.path) } }
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) { Text(l.kind).font(.bBody.weight(.medium)); if l.holdsData { Tag(text: "May hold your data", tone: .amber) } }
                                    Text(l.path.replacingOccurrences(of: home, with: "~")).font(.bCaption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Text(l.bytes.bytesString).font(.bCaption).foregroundStyle(.secondary).monospacedDigit()
                            }.padding(.vertical, 6).overlay(alignment: .top) { Divider() }
                        }
                    }
                } else if model.loading { Text("Looking for leftovers…").font(.bCaption).foregroundStyle(.secondary) }
                VStack(spacing: 8) {
                    Button { removal = AppRemoval(apps: [chosen], includeBundle: true) } label: { Text("Remove app and leftovers · \((a.bytes + leftBytes).bytesString)").frame(maxWidth: .infinity) }
                        .buttonStyle(.brandProminent).controlSize(.large).disabled(!a.isRemovable)
                    Button { removal = AppRemoval(apps: [chosen], includeBundle: false) } label: { Text("Remove leftovers only · \(leftBytes.bytesString)").frame(maxWidth: .infinity) }
                        .controlSize(.large).disabled(leftovers.isEmpty || !a.isRemovable)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) } label: { Text("Reveal in Finder").frame(maxWidth: .infinity) }.controlSize(.large)
                }
            }.padding(20)
        }.background(Brand.card)
    }

    private func note(_ a: InstalledApp) -> String {
        if !a.isRemovable { return "macOS includes this app, so AI Keeper leaves it alone." }
        switch a.source {
        case .appStore: return "Safe to remove. Download it again from the App Store whenever you like."
        case .homebrew: return "Safe to remove. Reinstall it with `brew install --cask \((a.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "").lowercased().replacingOccurrences(of: " ", with: "-"))`."
        case .download: return "Safe to remove, but check what is under \"May hold your data\": those folders can hold work that lives only on this Mac."
        }
    }
}

// MARK: Confirm

struct AppRemoveSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var removal: AppRemoval
    @State private var jobs: [CleanupJob] = []
    @State private var started = Date()
    @State private var checkedOrphans: Set<String> = []

    init(removal: AppRemoval) {
        _removal = State(initialValue: removal)
        // Leftovers of removed apps: tick the ones that cannot hold anyone's work, leave the rest for the person to choose.
        _checkedOrphans = State(initialValue: Set(removal.orphans.filter { g in !g.leftovers.contains { $0.holdsData } }.map(\.bundleID)))
    }

    private var running: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }) }
    private var effective: AppRemoval {
        var r = removal; r.orphans = removal.orphans.filter { checkedOrphans.contains($0.bundleID) }
        if r.includeBundle { r.apps = r.apps.filter { !running.contains($0.path) } }
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if jobs.isEmpty { confirm } else { BasketProgress(jobs: jobs, started: started, freeBefore: 0, deleteNow: false) { dismiss() } }
        }.padding(26).frame(width: 540)
    }

    private var confirm: some View {
        let eff = effective, busy = removal.includeBundle ? removal.apps.filter { running.contains($0.path) } : []
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(removal.orphans.isEmpty ? (removal.includeBundle ? "Remove \(eff.apps.count == 1 ? eff.apps[0].name : "\(eff.apps.count) apps")?" : "Remove leftovers?") : "Clear leftovers of removed apps?").font(.bTitle2.bold())
                Text("Everything moves to the Trash. Put it back from History for 30 days.").font(.bCallout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if removal.orphans.isEmpty {
                        ForEach(eff.paths.indices, id: \.self) { i in line(eff.paths[i].name, eff.paths[i].path, eff.paths[i].bytes) }
                    } else {
                        ForEach(removal.orphans) { g in
                            HStack(spacing: 10) {
                                Check(on: checkedOrphans.contains(g.bundleID)) { if checkedOrphans.contains(g.bundleID) { checkedOrphans.remove(g.bundleID) } else { checkedOrphans.insert(g.bundleID) } }
                                VStack(alignment: .leading, spacing: 1) { Text(g.bundleID).font(.bBody.weight(.medium)); Text(g.leftovers.map(\.kind).joined(separator: ", ")).font(.bCaption).foregroundStyle(.secondary) }
                                Spacer()
                                if g.leftovers.contains(where: \.holdsData) { Tag(text: "May hold data", tone: .amber) }
                                Text(g.bytes.bytesString).font(.bBody).monospacedDigit()
                            }.padding(.vertical, 8).overlay(alignment: .top) { Divider() }
                        }
                    }
                }
            }.frame(maxHeight: 260)
            if !busy.isEmpty {
                Label("\(busy.map(\.name).joined(separator: ", ")) \(busy.count == 1 ? "is" : "are") open and will be skipped. Quit \(busy.count == 1 ? "it" : "them"), then try again.", systemImage: "bolt.slash.fill")
                    .font(.bCallout).foregroundStyle(Brand.reclaimText).fixedSize(horizontal: false, vertical: true)
            }
            if eff.paths.contains(where: { p in (removal.apps + []).contains { $0.leftovers.contains { $0.path == p.path && $0.holdsData } } }) {
                Label("Includes folders that can hold your own data. Check them first.", systemImage: "exclamationmark.triangle.fill").font(.bCallout).foregroundStyle(Brand.reclaimText)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move \(eff.bytes.bytesString) to Trash") { run(eff) }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent).controlSize(.large).disabled(eff.paths.isEmpty)
            }
        }
    }

    private func line(_ name: String, _ path: String, _ bytes: Int64) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) { Text(name).font(.bBody.weight(.medium)).lineLimit(1); Text(path.replacingOccurrences(of: home, with: "~")).font(.bCaption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Spacer(); Text(bytes.bytesString).font(.bBody).monospacedDigit()
        }.padding(.vertical, 7).overlay(alignment: .top) { Divider() }
    }

    private func run(_ r: AppRemoval) {
        let entries: [Entry] = r.paths.map { p in
            var e = Entry(id: "app:" + p.path, kind: .sessionData, name: p.name, path: p.path, repoPath: nil, repoName: "App", branch: nil, sources: [.dev])
            e.size = p.bytes; e.measured = true; e.verdict = .deprecated
            return e
        }
        var o = CleanupOptions(); o.permanent = false; o.vault = false; o.deleteMergedBranches = false
        started = Date()
        let job = store.startCleanup(CleanupPlan(mode: .removeWorkspaces, entries: entries), options: o)
        jobs = [job]
        let gone = Set(r.paths.map(\.path))
        Task { while job.state != .finished { try? await Task.sleep(for: .milliseconds(400)) }; store.apps.forget(gone) }
    }
}
