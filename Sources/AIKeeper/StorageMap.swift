import SwiftUI

struct Hotspot: Identifiable, Hashable, Codable {
    var id: String { path }
    let path: String
    let size: Int64
    let hint: String?
    let cleanable: Bool
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent.replacingOccurrences(of: home, with: "~") }
}

struct MapGroup: Identifiable, Codable {
    var id: String { name }
    let name: String
    let detail: String
    let size: Int64
    let colorName: String
    var color: Color {
        switch colorName {
        case "blue": Brand.accent
        case "purple": Color(red: 0.514, green: 0.380, blue: 0.929)
        case "teal": Color(red: 0.31, green: 0.66, blue: 0.96)
        case "pink": Color(red: 0.58, green: 0.64, blue: 0.72)
        case "indigo": Color(red: 0.12, green: 0.17, blue: 0.42)
        default: Color(red: 0.80, green: 0.84, blue: 0.89)
        }
    }
}

struct StorageMapResult: Codable {
    var groups: [MapGroup]
    var hotspots: [Hotspot]
    var homeTotal: Int64
    var apps: Int64
}

/// One `du` pass over the home folder, then picks the few folders that explain most of the space.
enum StorageMapper {
    /// Plain-English explanations for folders people don't recognise. `clean` = safe to empty.
    static func describe(_ path: String) -> (hint: String, clean: Bool)? {
        let name = (path as NSString).lastPathComponent
        let lower = path.lowercased()
        if lower.contains("orbstack") {
            return ("OrbStack containers, images and Linux VMs. Free space with `docker system prune -a` (add `--volumes` to drop unused volumes).", false)
        }
        if lower.contains("docker") {
            return ("Docker images and volumes. In Docker Desktop use Troubleshoot → Clean / Purge data, or run `docker system prune -a`.", false)
        }
        switch name {
        case "target": return ("Build output (Rust or Java). Safe to delete; the next build recreates it.", true)
        case "node_modules": return ("JavaScript dependencies. Reinstall any time with npm, pnpm or yarn.", true)
        case ".cache": return ("Tool and model caches. Rebuilt on demand.", true)
        case "Caches": return ("App caches. Apps recreate what they need.", true)
        case "DerivedData": return ("Xcode build products. Rebuilt on demand.", true)
        case ".npm", ".yarn": return ("Package manager cache. Re-downloaded when needed.", true)
        case ".gradle": return ("Gradle caches and wrappers. Re-downloaded when needed.", true)
        case ".rustup": return ("Installed Rust toolchains. Remove unused ones with `rustup toolchain uninstall`.", false)
        case ".cargo": return ("Cargo registry and installed binaries.", false)
        case ".codex": return ("Codex CLI sessions and logs.", false)
        case "worktrees" where path.contains("/.claude/"): return ("Claude Code git worktrees. Remove the ones you no longer need from All workspaces.", false)
        case ".claude": return ("Claude Code sessions, worktrees and history.", false)
        case ".lmstudio": return ("Language models downloaded by LM Studio.", false)
        case ".ollama": return ("Language models downloaded by Ollama.", false)
        case "Group Containers": return ("Data shared between an app and its extensions (Docker, Mail, Notes…). Explore to see which app.", false)
        case "Containers": return ("Sandboxed app data.", false)
        case "Application Support": return ("App databases, downloads and settings.", false)
        case "Downloads": return ("Your Downloads folder.", false)
        case "Movies", "Pictures", "Music", "Documents", "Desktop": return ("Your personal files.", false)
        default: return nil
        }
    }

    static func scan(used: Int64) -> StorageMapResult {
        let out = Shell.run("/usr/bin/du", ["-xk", "-d", "4", home]).out
        var sizes: [String: Int64] = [:]
        var children: [String: [String]] = [:]
        for line in out.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[..<tab]) else { continue }
            let path = String(line[line.index(after: tab)...])
            sizes[path] = kb * 1024
            if path != home { children[(path as NSString).deletingLastPathComponent, default: []].append(path) }
        }
        let homeTotal = sizes[home] ?? 0

        // Stacked-bar groups
        var dev: Int64 = 0, lib: Int64 = 0, dots: Int64 = 0, files: Int64 = 0, other: Int64 = 0
        let personal: Set<String> = ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public"]
        for p in children[home] ?? [] {
            let n = (p as NSString).lastPathComponent, s = sizes[p] ?? 0
            if ["Developer", "Projects", "code", "src"].contains(n) { dev += s }
            else if n == "Library" { lib += s }
            else if n.hasPrefix(".") { dots += s }
            else if personal.contains(n) { files += s }
            else { other += s }
        }
        let appsOut = Shell.run("/usr/bin/du", ["-xsk", "/Applications"]).out
        let apps = (Int64(appsOut.split(separator: "\t").first ?? "") ?? 0) * 1024
        let groups = [
            MapGroup(name: "Developer", detail: "Your code and build output", size: dev, colorName: "blue"),
            MapGroup(name: "Library", detail: "App data, caches and containers", size: lib, colorName: "purple"),
            MapGroup(name: "Tool folders", detail: ".cache, .codex, .rustup…", size: dots, colorName: "teal"),
            MapGroup(name: "Your files", detail: "Documents, Downloads, Movies…", size: files + other, colorName: "pink"),
            MapGroup(name: "Applications", detail: "Installed apps", size: apps, colorName: "indigo"),
        ].filter { $0.size > 0 }

        // Hotspots: expand big folders until the pieces are small, stop at known rebuildable folders.
        let threshold = max(5_000_000_000, homeTotal / 12)
        var leaves: [(String, Int64)] = []
        func visit(_ p: String, depth: Int) {
            let size = sizes[p] ?? 0
            let kids = (children[p] ?? []).filter { (sizes[$0] ?? 0) > 0 }
            let atomic = DiskModel.cleanable[(p as NSString).lastPathComponent] != nil
            if depth >= 4 || atomic || kids.isEmpty || size < threshold { leaves.append((p, size)); return }
            for k in kids { visit(k, depth: depth + 1) }
        }
        for k in children[home] ?? [] { visit(k, depth: 1) }
        let hot = leaves.filter { $0.1 >= 1_000_000_000 }.sorted { $0.1 > $1.1 }.prefix(14).map { p, s -> Hotspot in
            let d = describe(p)
            return Hotspot(path: p, size: s, hint: d?.hint, cleanable: d?.clean ?? false)
        }
        return StorageMapResult(groups: groups, hotspots: Array(hot), homeTotal: homeTotal, apps: apps)
    }
}

// MARK: - View

struct StorageMapView: View {
    @EnvironmentObject var store: Store
    let explore: (String) -> Void
    var open: (Section) -> Void = { _ in }

    var body: some View {
        let d = store.disk
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Where your space goes").font(.headline)
                Spacer()
                mapStatus
                Button { Task { await store.scanMap() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .controlSize(.small).disabled(store.mapRefreshing)
                    .help("Measure the whole disk again. This takes a minute or two and runs in the background.")
            }
            Text("\(d.used.bytesString) used · \(d.available.bytesString) free").font(.callout).foregroundStyle(.secondary)
            if let m = store.map {
                let groups = allGroups(m, used: d.used)
                bar(groups, used: d.used)
                legend(groups)
                Text("Biggest items").font(.headline).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(m.hotspots) { h in
                        row(h, used: Double(max(d.used, 1)), maxSize: Double(m.hotspots.first?.size ?? 1))
                        if h.id != m.hotspots.last?.id { Divider() }
                    }
                }.panel()
                if d.purgeable > 0 {
                    Label("\(d.purgeable.bytesString) of the used space is purgeable. macOS frees it automatically when it needs room.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Mapping your disk. The first pass takes a minute or two.").foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).panel()
            }
        }
        .task { await store.ensureMap() }   // first visit only: fetch in the background, then leave it alone
    }

    /// Measured groups plus whatever the disk reports beyond them. Recomputed from live disk numbers,
    /// so a stale map can't make the pieces add up to more than the disk.
    private func allGroups(_ m: StorageMapResult, used: Int64) -> [MapGroup] {
        let rest = used - m.homeTotal - m.apps
        guard rest > 0 else { return m.groups }
        return m.groups + [MapGroup(name: "macOS and other", detail: "System, snapshots, VM, anything outside your home", size: rest, colorName: "gray")]
    }

    /// Says how fresh the map is; it never refreshes itself after the first visit.
    @ViewBuilder private var mapStatus: some View {
        if store.mapRefreshing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Measuring in the background…") }.font(.caption).foregroundStyle(.secondary)
        } else if store.mapStale {
            Label("Out of date after a cleanup", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
        } else if let d = store.mapDate {
            Text("Measured \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bar(_ groups: [MapGroup], used: Int64) -> some View {
        // Never divide by less than the pieces sum to, or the bar overflows its container.
        let denom = Double(max(used, groups.reduce(0) { $0 + $1.size }, 1))
        return GeometryReader { geo in
            let usable = geo.size.width - Double(max(groups.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(groups) { g in
                    Rectangle().fill(g.color.opacity(0.85)).frame(width: max(0, usable * Double(g.size) / denom))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(Capsule())
            .background(Capsule().fill(.quaternary))
        }.frame(height: 12)
    }

    private func legend(_ groups: [MapGroup]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(groups.sorted { $0.size > $1.size }) { g in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(g.color.opacity(0.85)).frame(width: 9, height: 9).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) { Text(g.name).fontWeight(.medium); Text(g.size.bytesString).monospacedDigit().foregroundStyle(.secondary) }
                        Text(g.detail).font(.caption).foregroundStyle(.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func row(_ h: Hotspot, used: Double, maxSize: Double) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(h.name).fontWeight(.medium)
                    if h.parent != "~" { Text(h.parent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                }
                if let hint = h.hint { Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Capsule().fill(h.cleanable ? Brand.reclaim : Color.secondary.opacity(0.55))
                    .frame(height: 4).frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: max(0.01, Double(h.size) / maxSize), anchor: .leading)
                    .padding(.top, 2)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(h.size.bytesString).monospacedDigit().fontWeight(.medium)
                Text(String(format: "%.0f%% of disk", Double(h.size) / used * 100)).font(.caption).foregroundStyle(.secondary)
                if let g = store.growth(of: h.path, current: h.size), g > 0 {
                    Text("+\(g.bytesString) today").font(.caption).foregroundStyle(.orange)
                }
            }.frame(width: 90, alignment: .trailing)
            HStack(spacing: 6) {
                Button("Explore") { explore(h.path) }.controlSize(.small)
                if h.path.lowercased().contains("orbstack") || h.path.lowercased().contains("docker") {
                    Button("Prune…") { open(.containers) }.controlSize(.small).buttonStyle(.borderedProminent).tint(Brand.accent)
                } else {
                Button("Clean") { store.cleanHotspot(h) }.controlSize(.small).buttonStyle(.borderedProminent).tint(Brand.accent)
                    .opacity(h.cleanable ? 1 : 0).disabled(!h.cleanable)
                }
            }.frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path)]) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h.path, forType: .string) }
        }
    }
}
