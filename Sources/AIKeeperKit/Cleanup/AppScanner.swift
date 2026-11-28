import AppKit
import Foundation

// Installed apps, and every file each one leaves in ~/Library. Reading only: nothing here removes anything.

struct Leftover: Identifiable, Hashable {
    var id: String { path }
    let kind: String            // "Application Support", "Caches", "Preferences", ...
    let path: String
    var bytes: Int64
    /// Folders that can hold the person's own data, as opposed to things the app rebuilds.
    var holdsData: Bool { ["Application Support", "Containers", "Group Containers"].contains(kind) }
}

struct InstalledApp: Identifiable, Hashable {
    enum Source: String { case appStore = "App Store", homebrew = "Homebrew", download = "Download" }
    var id: String { path }
    let name: String
    let path: String
    let bundleID: String
    let version: String
    let source: Source
    var bytes: Int64 = 0
    var lastOpened: Date?
    var leftovers: [Leftover] = []
    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { bytes + leftoverBytes }
    /// Apple's own apps are only offered when they came from the App Store (Xcode, Pages), never the ones macOS ships.
    var isRemovable: Bool { !bundleID.hasPrefix("com.apple.") || source == .appStore }
    var isDeveloperTool: Bool {
        let k = (bundleID + " " + name).lowercased()
        return ["com.apple.dt", "docker", "jetbrains", "visualstudio", "vscode", "iterm", "postman", "tableplus", "sublime", "android", "xcode", "github", "orbstack", "warp", "cursor"].contains { k.contains($0) }
    }
    func notOpened(forDays d: Int, now: Date = Date()) -> Bool { (lastOpened ?? .distantPast) < now.addingTimeInterval(-Double(d) * 86_400) }
}

/// Library folders of apps that are no longer installed.
struct OrphanGroup: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    var leftovers: [Leftover]
    var bytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }
}

enum AppScanner {
    static let roots = ["/Applications", "\(home)/Applications"]
    private static let lib = "\(home)/Library"

    /// Every app bundle directly inside the application folders, without sizes. Fast.
    static func listApps() -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".app") {
                let path = root + "/" + name
                guard let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                      let id = plist["CFBundleIdentifier"] as? String else { continue }
                let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? String(name.dropLast(4))
                let version = (plist["CFBundleShortVersionString"] as? String) ?? ""
                out.append(InstalledApp(name: display, path: path, bundleID: id, version: version, source: source(of: path, name: String(name.dropLast(4)))))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func source(of path: String, name: String) -> InstalledApp.Source {
        let fm = FileManager.default
        if fm.fileExists(atPath: path + "/Contents/_MASReceipt") { return .appStore }
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        for cask in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] where fm.fileExists(atPath: "\(cask)/\(slug)") { return .homebrew }
        return .download
    }

    static func lastOpened(_ path: String) -> Date? {
        let r = Shell.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemLastUsedDate", path])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, s != "(null)", !s.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: s)
    }

    /// The paths this app's files can live at, by bundle id and by name. Only those that exist are returned.
    static func leftoverPaths(bundleID id: String, name: String, library: String = lib) -> [(kind: String, path: String)] {
        let fm = FileManager.default
        var c: [(String, String)] = [
            ("Application Support", "\(library)/Application Support/\(name)"), ("Application Support", "\(library)/Application Support/\(id)"),
            ("Caches", "\(library)/Caches/\(id)"), ("Caches", "\(library)/Caches/\(name)"),
            ("Preferences", "\(library)/Preferences/\(id).plist"),
            ("Saved state", "\(library)/Saved Application State/\(id).savedState"),
            ("Containers", "\(library)/Containers/\(id)"),
            ("Logs", "\(library)/Logs/\(name)"),
            ("Web data", "\(library)/HTTPStorages/\(id)"), ("Web data", "\(library)/WebKit/\(id)"), ("Web data", "\(library)/Cookies/\(id).binarycookies"),
            ("Scripts", "\(library)/Application Scripts/\(id)"),
        ]
        for (kind, dir, match) in [("Group Containers", "\(library)/Group Containers", id), ("Launch agent", "\(library)/LaunchAgents", id), ("Preferences", "\(library)/Preferences/ByHost", id)] {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.contains(match) { c.append((kind, "\(dir)/\(entry)")) }
        }
        var seen = Set<String>()
        return c.filter { fm.fileExists(atPath: $0.1) && seen.insert($0.1).inserted }.map { (kind: $0.0, path: $0.1) }
    }

    static func leftovers(for app: InstalledApp) -> [Leftover] {
        let name = (app.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        return (leftoverPaths(bundleID: app.bundleID, name: name) + (name == app.name ? [] : leftoverPaths(bundleID: app.bundleID, name: app.name)))
            .reduce(into: [String: Leftover]()) { $0[$1.path] = Leftover(kind: $1.kind, path: $1.path, bytes: Shell.du($1.path)) }
            .values.sorted { $0.bytes > $1.bytes }
    }

    /// Library folders named like a bundle id, for which no installed app has the same vendor. Conservative on purpose:
    /// Apple's, anything touched in the last two weeks, and anything that shares its first two id parts with an installed app are skipped.
    static func orphans(installed: [InstalledApp], library: String = lib, now: Date = Date()) -> [OrphanGroup] {
        let fm = FileManager.default
        func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".").lowercased() }
        let vendors = Set(installed.map { vendor($0.bundleID) })
        let dirs: [(String, String)] = [("Caches", "Caches"), ("Application Support", "Application Support"), ("Saved state", "Saved Application State"), ("Containers", "Containers"), ("Web data", "HTTPStorages"), ("Web data", "WebKit"), ("Preferences", "Preferences")]
        var groups: [String: [Leftover]] = [:]
        for (kind, dir) in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: "\(library)/\(dir)")) ?? [] {
                var id = entry
                for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
                let parts = id.split(separator: ".")
                guard parts.count >= 3, ["com", "org", "io", "net", "app", "co", "dev"].contains(String(parts[0]).lowercased()) else { continue }
                guard !id.lowercased().hasPrefix("com.apple."), !vendors.contains(vendor(id)) else { continue }
                let path = "\(library)/\(dir)/\(entry)"
                if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, now.timeIntervalSince(m) < 14 * 86_400 { continue }
                groups[id, default: []].append(Leftover(kind: kind, path: path, bytes: 0))
            }
        }
        return groups.map { id, l in OrphanGroup(bundleID: id, leftovers: l.map { Leftover(kind: $0.kind, path: $0.path, bytes: Shell.du($0.path)) }) }
            .filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var orphans: [OrphanGroup] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var progress = (done: 0, total: 0)

    var unused: [InstalledApp] { apps.filter { $0.isRemovable && $0.notOpened(forDays: 90) } }
    var unusedBytes: Int64 { unused.reduce(0) { $0 + $1.totalBytes } }
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.bytes } }

    func measureIfNeeded() async { if !loaded && !loading { await scan() } }

    func scan() async {
        guard !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        if Demo.enabled { apps = Self.demoApps(); orphans = Self.demoOrphans(); return }
        var list = await Task.detached(priority: .utility) { AppScanner.listApps() }.value
        apps = list
        progress = (0, list.count)
        // Sizes, last-opened dates and leftovers, a few apps at a time. The list fills in as it goes.
        let batch = 6
        var i = 0
        while i < list.count {
            let slice = Array(list[i..<min(i + batch, list.count)])
            let done = await Task.detached(priority: .utility) { () -> [InstalledApp] in
                slice.map { a in var a = a; a.bytes = Shell.du(a.path); a.lastOpened = AppScanner.lastOpened(a.path); a.leftovers = AppScanner.leftovers(for: a); return a }
            }.value
            for d in done { if let k = list.firstIndex(where: { $0.id == d.id }) { list[k] = d } }
            apps = list; i += batch; progress = (min(i, list.count), list.count)
        }
        let installed = list
        orphans = await Task.detached(priority: .utility) { AppScanner.orphans(installed: installed) }.value
    }

    /// Forget what was just removed, so the list is right before the next scan.
    func forget(_ paths: Set<String>) {
        apps.removeAll { paths.contains($0.path) }
        orphans = orphans.compactMap { g in var g = g; g.leftovers.removeAll { paths.contains($0.path) }; return g.leftovers.isEmpty ? nil : g }
        for k in apps.indices { apps[k].leftovers.removeAll { paths.contains($0.path) } }
    }

    // MARK: Demo

    private static func demoApps() -> [InstalledApp] {
        func a(_ n: String, _ id: String, _ v: String, _ s: InstalledApp.Source, _ mb: Double, _ lo: Double, _ days: Int?, _ kinds: [(String, Double)] = []) -> InstalledApp {
            var x = InstalledApp(name: n, path: "/Applications/\(n).app", bundleID: id, version: v, source: s, bytes: Int64(mb * 1e6), lastOpened: days.map { Date().addingTimeInterval(-Double($0) * 86_400) })
            x.leftovers = kinds.map { Leftover(kind: $0.0, path: "\(home)/Library/\($0.0)/\(id)", bytes: Int64($0.1 * 1e6)) }
            return x
        }
        return [
            a("Figma", "com.figma.Desktop", "124.3", .homebrew, 412, 0, 210, [("Application Support", 1100), ("Caches", 380), ("Preferences", 0.004)]),
            a("Spotify", "com.spotify.client", "1.2.60", .download, 388, 0, 21, [("Application Support", 1400), ("Caches", 700)]),
            a("Xcode", "com.apple.dt.Xcode", "26.1", .appStore, 14200, 0, 0, [("Caches", 9800)]),
            a("Docker", "com.docker.docker", "4.50", .homebrew, 2100, 0, 0, [("Containers", 24600)]),
            a("Photoshop 2023", "com.adobe.Photoshop", "24.7", .download, 6400, 0, 430, [("Application Support", 1200)]),
            a("Visual Studio Code", "com.microsoft.VSCode", "1.98", .homebrew, 412, 0, 0, [("Application Support", 1800)]),
            a("TextExpander", "com.smileonmymac.textexpander", "7.2", .download, 96, 0, 270, [("Application Support", 210)]),
            a("OBS Studio", "com.obsproject.obs-studio", "31.0", .homebrew, 312, 0, 150, [("Application Support", 640)]),
            a("Discord", "com.hnc.Discord", "0.0.340", .download, 268, 0, 2, [("Application Support", 1100)]),
        ]
    }

    private static func demoOrphans() -> [OrphanGroup] {
        (0..<22).map { i in OrphanGroup(bundleID: "com.vendor\(i).oldapp", leftovers: [Leftover(kind: "Application Support", path: "\(home)/Library/Application Support/com.vendor\(i).oldapp", bytes: Int64(140_000_000))]) }
    }
}
