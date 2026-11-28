import SwiftUI

// Cleanup › Optimize: what starts with the Mac, and routine maintenance that says what it does before it runs.

struct StartupItem: Identifiable, Hashable {
    enum Scope: String { case user = "Launch agent", global = "Launch agent (all users)", daemon = "Background service" }
    var label: String; var path: String; var scope: Scope; var enabled: Bool
    var appPath: String?                 // the app this item belongs to, found from its program path or its name
    var id: String { path }
    /// Only the person's own agents can be switched off without a password.
    var canToggle: Bool { scope == .user }
    /// A launch label is usually the app's bundle id with a suffix (com.docker.helper), so try its first three parts.
    var bundleHint: String { label.split(separator: ".").prefix(3).joined(separator: ".") }
    var name: String {
        let parts = label.split(separator: ".").map(String.init)
        let skip: Set<String> = ["com", "ai", "org", "io", "net", "app", "co", "dev", "plist", "helper", "agent", "daemon", "launcher", "login", "loginitem"]
        let kept = parts.filter { !skip.contains($0.lowercased()) }
        let base = kept.first ?? label
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}

enum Maintenance: String, CaseIterable, Identifiable {
    case dns, launchServices, verifyDisk, spotlight
    var id: String { rawValue }
    var title: String { switch self { case .dns: "Flush the DNS cache"; case .launchServices: "Rebuild Launch Services"; case .verifyDisk: "Verify the startup disk"; case .spotlight: "Reindex Spotlight" } }
    var detail: String {
        switch self {
        case .dns: "Fixes sites that will not load after a network change."
        case .launchServices: "Fixes duplicate entries in the Open With menu."
        case .verifyDisk: "Checks the file system for errors without changing anything."
        case .spotlight: "Rebuilds search for the startup disk. Takes a while and slows the Mac meanwhile."
        }
    }
    var symbol: String { switch self { case .dns: "network"; case .launchServices: "square.grid.2x2"; case .verifyDisk: "internaldrive"; case .spotlight: "magnifyingglass" } }
    var tone: Tone { switch self { case .dns: .blue; case .launchServices: .violet; case .verifyDisk: .blue; case .spotlight: .green } }
    var needsPassword: Bool { self == .dns || self == .spotlight }
    var key: String { "maintenance.last." + rawValue }
    var lastRun: Date? { UserDefaults.standard.object(forKey: key) as? Date }

    /// Shell command this task runs. Shown to the person before it runs.
    var command: String {
        switch self {
        case .dns: "dscacheutil -flushcache; killall -HUP mDNSResponder"
        case .launchServices: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"
        case .verifyDisk: "diskutil verifyVolume /"
        case .spotlight: "mdutil -E /"
        }
    }
}

@MainActor @Observable final class OptimizeModel {
    var items: [StartupItem] = []
    var loaded = false
    var running: Maintenance?
    var results: [Maintenance: String] = [:]
    var memory: [String: Int64] = [:]       // label → resident bytes right now, for the "uses" column

    func load() async {
        if Demo.enabled {
            items = [StartupItem(label: "com.docker.helper", path: "/demo/docker", scope: .user, enabled: true), StartupItem(label: "com.spotify.webhelper", path: "/demo/spotify", scope: .user, enabled: false), StartupItem(label: "com.google.keystone.agent", path: "/demo/google", scope: .global, enabled: true)]
            memory = ["com.docker.helper": 820_000_000]; loaded = true; return
        }
        let found = await Task.detached(priority: .utility) { Self.scan() }.value
        items = found.items; memory = found.memory; loaded = true
    }

    func setEnabled(_ item: StartupItem, _ on: Bool) {
        guard item.canToggle else { return }
        let uid = getuid()
        Task.detached(priority: .utility) {
            if on { Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(item.label)"]) }
            else { Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(item.label)"]); Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"]) }
        }
        if let i = items.firstIndex(of: item) { items[i].enabled = on }
    }

    func run(_ task: Maintenance, store: Store) async {
        running = task; defer { running = nil }
        let bg = store.beginTask(task.title, symbol: task.symbol)
        bg.note(task.needsPassword ? "Waiting for your password" : "Running")
        let cmd = task.command
        let out: (status: Int32, out: String) = await Task.detached(priority: .utility) {
            if task.needsPassword {
                let script = "do shell script \"\(cmd)\" with administrator privileges"
                return Shell.run("/usr/bin/osascript", ["-e", script])
            }
            return Shell.run("/bin/sh", ["-c", cmd])
        }.value
        if out.status == 0 { UserDefaults.standard.set(Date(), forKey: task.key); results[task] = task == .verifyDisk ? (out.out.contains("appears to be OK") ? "No problems found." : "Finished. Open Disk Utility for details.") : "Done." }
        else { results[task] = out.out.contains("User canceled") ? "Cancelled." : "Could not run. \(out.out.split(separator: "\n").last.map(String.init) ?? "")" }
        if out.status == 0 { bg.note(results[task] ?? "Done"); bg.finish() } else { bg.finish(error: results[task] ?? "Failed") }
    }

    /// /Applications/Foo.app/Contents/MacOS/helper → /Applications/Foo.app
    nonisolated private static func appContaining(_ program: String?) -> String? {
        guard let program, let r = program.range(of: ".app/") ?? program.range(of: ".app", options: .backwards) else { return nil }
        let p = String(program[..<r.upperBound]).replacingOccurrences(of: ".app/", with: ".app")
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Falls back to an installed app whose name starts with the item's (Docker → Docker.app, Google → Google Chrome.app).
    nonisolated private static func appNamed(_ name: String) -> String? {
        let n = name.lowercased()
        guard n.count > 2 else { return nil }
        for dir in ["/Applications", home + "/Applications"] {
            if let hit = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(".app") && $0.lowercased().hasPrefix(n) }) { return dir + "/" + hit }
        }
        return nil
    }

    nonisolated private static func scan() -> (items: [StartupItem], memory: [String: Int64]) {
        let uid = getuid()
        let disabled = Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out
        var off: Set<String> = []
        for line in disabled.split(separator: "\n") where line.contains("=>") && (line.contains("true") || line.contains("disabled")) {
            let parts = line.split(separator: "=>"); if parts.count == 2, parts[1].contains("true") || parts[1].contains("disabled") { off.insert(parts[0].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\""))))}
        }
        var out: [StartupItem] = []
        let dirs: [(String, StartupItem.Scope)] = [(home + "/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .global), ("/Library/LaunchDaemons", .daemon)]
        for (dir, scope) in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                let d = NSDictionary(contentsOfFile: path)
                let label = (d?["Label"] as? String) ?? String(f.dropLast(6))
                if label.hasPrefix("com.apple.") { continue }
                let runAtLoad = (d?["RunAtLoad"] as? Bool) ?? false, keepAlive = d?["KeepAlive"] != nil
                if !runAtLoad && !keepAlive && scope != .user { continue }
                let program = (d?["Program"] as? String) ?? (d?["ProgramArguments"] as? [String])?.first
                var item = StartupItem(label: label, path: path, scope: scope, enabled: !off.contains(label))
                item.appPath = appContaining(program) ?? appNamed(item.name)
                out.append(item)
            }
        }
        // Memory in use right now, by launchd label (ps shows the program, launchctl list shows the PID).
        var mem: [String: Int64] = [:]
        let list = Shell.run("/bin/launchctl", ["list"]).out
        var pidFor: [String: Int] = [:]
        for l in list.split(separator: "\n").dropFirst() { let c = l.split(separator: "\t"); if c.count >= 3, let p = Int(c[0]) { pidFor[String(c[2])] = p } }
        let ps = Shell.run("/bin/ps", ["-axo", "pid=,rss="]).out
        var rss: [Int: Int64] = [:]
        for l in ps.split(separator: "\n") { let c = l.split(separator: " "); if c.count == 2, let p = Int(c[0]), let r = Int64(c[1]) { rss[p] = r * 1024 } }
        for i in out { if let p = pidFor[i.label], let r = rss[p] { mem[i.label] = r } }
        return (out.sorted { (mem[$0.label] ?? 0) > (mem[$1.label] ?? 0) }, mem)
    }
}

struct OptimizeTab: View {
    @Environment(Store.self) private var store
    @State private var model = OptimizeModel()
    @State private var pending: Maintenance?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 14) { summary; startup }.frame(maxWidth: .infinity)
                maintenance.frame(width: 420)
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .task { await model.load() }
        .alert(item: $pending) { t in
            Alert(title: Text(t.title + "?"), message: Text(t.detail + (t.needsPassword ? " macOS asks for your password." : "") + "\n\nRuns: " + (t == .launchServices ? "lsregister -kill -r" : t.command)),
                  primaryButton: .default(Text("Run")) { Task { await model.run(t, store: store) } }, secondaryButton: .cancel())
        }
    }

    private var summary: some View {
        let on = model.items.filter(\.enabled).count
        let heavy = model.items.filter { (model.memory[$0.label] ?? 0) > 200_000_000 }.count
        return HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 2) { Text("Starts with your Mac").font(.bCaption).foregroundStyle(.secondary); HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(on)").font(.system(size: 40, weight: .bold)).monospacedDigit(); Text("items").foregroundStyle(.secondary) } }
            Text(heavy > 0 ? "\(heavy) of them use over 200 MB of memory right now." : "None of them use much memory right now.").font(.bCallout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 22).padding(.vertical, 16).background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }

    private var startup: some View {
        VStack(spacing: 0) {
            HStack { Text("Item").frame(maxWidth: .infinity, alignment: .leading); Text("Kind").frame(width: 140, alignment: .leading); Text("Memory now").frame(width: 90, alignment: .trailing); Color.clear.frame(width: 50, height: 1) }
                .font(.bCaption2).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            if !model.loaded { ProgressView().controlSize(.small).padding(24) }
            else if model.items.isEmpty { Text("Nothing besides macOS starts at login.").foregroundStyle(.secondary).padding(24) }
            ForEach(model.items) { i in
                HStack(spacing: 12) {
                    AppIcon(path: i.appPath, bundleID: i.bundleHint, name: i.name, size: 30)
                    VStack(alignment: .leading, spacing: 1) { Text(i.name).font(.bBody.weight(.medium)).lineLimit(1); Text(i.label).font(.bCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(i.scope.rawValue).font(.bCaption).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                    Text(model.memory[i.label].map(\.bytesString) ?? "not running").font(.bCaption).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    Toggle("", isOn: Binding(get: { i.enabled }, set: { model.setEnabled(i, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!i.canToggle).frame(width: 50)
                        .help(i.canToggle ? "Turn this off to stop it starting at login" : "Needs an administrator to change")
                }.padding(.horizontal, 16).padding(.vertical, 8).overlay(alignment: .top) { Divider() }
            }
        }.background(Brand.card).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Maintenance").font(.bHeadline).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
            ForEach(Maintenance.allCases) { t in
                HStack(alignment: .top, spacing: 12) {
                    TierChip(symbol: t.symbol, tone: t.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.bBody.weight(.semibold)); Text(t.detail).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(model.results[t] ?? (t.lastRun.map { "Last run \($0.formatted(.relative(presentation: .named)))" } ?? (t.needsPassword ? "Needs your password" : "Never run"))).font(.bCaption2).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    Spacer(minLength: 4)
                    if model.running == t { ProgressView().controlSize(.small) } else { Button("Run") { pending = t }.controlSize(.small).disabled(model.running != nil) }
                }.padding(.horizontal, 18).padding(.vertical, 12).overlay(alignment: .top) { Divider() }
            }
            Text("Tasks that change system files ask for your password. Each one says what it runs first.").font(.bCaption2).foregroundStyle(.secondary).padding(18).overlay(alignment: .top) { Divider() }
        }.background(Brand.card).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.edge))
    }
}
