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
