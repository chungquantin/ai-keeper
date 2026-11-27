import SwiftUI

// Cleanup › Agent data: the places agents and dev tools keep things on this Mac, with what each costs to lose.

struct DataSource: Identifiable {
    let id: String
    let name: String
    let detail: String
    let tier: Tier
    let symbol: String
    let paths: [String]
    var archivable = false
}

@MainActor @Observable
final class SourcesModel {
    private(set) var sizes: [String: Int64] = [:]
    private(set) var dockerCache: Int64?       // build cache Docker would drop
    private(set) var dockerReclaimable: Int64?
    private(set) var dockerTotal: Int64?
    private(set) var dockerState = "Measuring"
    private(set) var loading = false
    private var loaded = false

    nonisolated static let all: [DataSource] = [
        .init(id: "claude", name: "Claude Code transcripts", detail: "Every session you ran, in ~/.claude/projects", tier: .onlyHere, symbol: "doc.text", paths: ["\(home)/.claude/projects"], archivable: true),
        .init(id: "codex", name: "Codex sessions", detail: "~/.codex/sessions", tier: .onlyHere, symbol: "doc.text", paths: ["\(home)/.codex/sessions"], archivable: true),
        .init(id: "xcode", name: "Xcode", detail: "DerivedData and device support", tier: .rebuildable, symbol: "hammer",
              paths: ["\(home)/Library/Developer/Xcode/DerivedData", "\(home)/Library/Developer/Xcode/iOS DeviceSupport"]),
        .init(id: "pkg", name: "Package caches", detail: "npm, pnpm, cargo registry, pip", tier: .rebuildable, symbol: "shippingbox",
              paths: ["\(home)/.npm/_cacache", "\(home)/Library/pnpm/store", "\(home)/.cargo/registry", "\(home)/Library/Caches/pip"]),
        .init(id: "brew", name: "Homebrew downloads", detail: "Installers Homebrew already used", tier: .rebuildable, symbol: "shippingbox", paths: ["\(home)/Library/Caches/Homebrew"]),
        .init(id: "browsers", name: "Browser test downloads", detail: "Playwright and Puppeteer browsers", tier: .rebuildable, symbol: "globe",
              paths: ["\(home)/Library/Caches/ms-playwright", "\(home)/.cache/puppeteer"]),
    ]

    func sources() -> [DataSource] { Self.all }
    func bytes(_ s: DataSource) -> Int64? { sizes[s.id] }

    func measureIfNeeded() async { if !loaded { await measure() } }

    func measure() async {
        guard !loading else { return }
        loading = true; loaded = true
        defer { loading = false }
        if Demo.enabled {
            sizes = ["claude": 6_200_000_000, "codex": 1_400_000_000, "xcode": 14_800_000_000, "pkg": 7_900_000_000, "brew": 900_000_000, "browsers": 2_100_000_000]
            dockerTotal = 24_600_000_000; dockerReclaimable = 13_100_000_000; dockerCache = 5_800_000_000; dockerState = ""
            return
        }
        async let docker: Void = measureDocker()
        let list = Self.all
        let result = await Task.detached(priority: .utility) { () -> [String: Int64] in
            var out: [String: Int64] = [:]
            for s in list { out[s.id] = s.paths.reduce(Int64(0)) { $0 + (FileManager.default.fileExists(atPath: $1) ? Shell.du($1) : 0) } }
            return out
        }.value
        sizes = result
        await docker
    }

    private func measureDocker() async {
        let r = await Task.detached(priority: .utility) { DockerCLI.usage() }.value
        if r.error != nil { dockerState = r.error?.contains("isn't installed") == true ? "Not installed" : "Not running"; return }
        dockerReclaimable = r.rows.reduce(0) { $0 + DockerCLI.parseBytes($1.reclaimable) }
        dockerTotal = r.rows.reduce(0) { $0 + DockerCLI.parseBytes($1.size) }
        dockerCache = r.rows.first { $0.type.lowercased().contains("build") }.map { DockerCLI.parseBytes($0.reclaimable) }
        dockerState = ""
    }

    /// A folder a source owns, as an entry the cleaner already knows how to empty.
    func entries(for s: DataSource) -> [Entry] {
        s.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { p in
            var e = Entry(id: "src:\(s.id):\(p)", kind: .cache, name: (p as NSString).lastPathComponent, path: p, repoPath: nil,
                          repoName: s.name, branch: nil, sources: [.dev], note: s.detail)
            e.size = Demo.enabled ? sizes[s.id] : Shell.du(p); e.measured = true; e.verdict = .deprecated
            return e
        }
    }
}

// MARK: Archiving old transcripts

/// Packs old session logs into one compressed file, then removes the originals. The file stays in Keeper's folder and can be unpacked from History.
enum Archiver {
    struct Plan { var root: String; var files: [String]; var bytes: Int64 }

    static var dir: URL {
        let u = Persist.dir.appendingPathComponent("Archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func root(for id: String) -> String { id == "codex" ? "\(home)/.codex/sessions" : "\(home)/.claude/projects" }

    /// Session logs not touched for `days`. Relative to `root`, so the archive unpacks back to the same place.
    static func candidates(id: String, days: Int) -> Plan { candidates(root: root(for: id), days: days) }

    static func candidates(root: String, days: Int, now: Date = Date()) -> Plan {
        var plan = Plan(root: root, files: [], bytes: 0)
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]) else { return plan }
        // The enumerator reports resolved paths, so measure them against the resolved root (a symlinked ~/.claude would otherwise shift every name).
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true,
                  let d = v.contentModificationDate, d < cutoff else { continue }
            let full = u.resolvingSymlinksInPath().path
            guard full.hasPrefix(resolvedRoot + "/") else { continue }
            plan.files.append(String(full.dropFirst(resolvedRoot.count + 1)))
            plan.bytes += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return plan
    }

    /// Returns the archive, or what went wrong. Originals are removed only after tar succeeded and listing the archive shows every file in it.
    static func archive(_ plan: Plan, id: String, into folder: URL? = nil) -> Result<URL, CleanerError> {
        guard !plan.files.isEmpty else { return .failure(.init("Nothing is old enough.")) }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let out = (folder ?? dir).appendingPathComponent("\(id)-\(f.string(from: .now)).tgz")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-archive-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        do { try plan.files.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8) } catch { return .failure(.init(error.localizedDescription)) }
        let r = Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", plan.root, "-T", list.path])
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int64) ?? 0
        guard r.status == 0, size > 0 else { try? FileManager.default.removeItem(at: out); return .failure(.init("Could not write the archive. Nothing was removed.")) }
        let listed = Shell.run("/usr/bin/tar", ["-tzf", out.path])
        let entries = Set(listed.out.split(separator: "\n").map(String.init))
        guard listed.status == 0, plan.files.allSatisfy({ entries.contains($0) }) else {
            try? FileManager.default.removeItem(at: out)
            return .failure(.init("The archive did not contain every session, so nothing was removed."))
        }
        for rel in plan.files { unlink(plan.root + "/" + rel) }
        return .success(out)
    }

    static func list() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "tgz" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func restore(_ url: URL, into root: String? = nil) -> String? {
        let id = url.lastPathComponent.hasPrefix("codex") ? "codex" : "claude"
        let r = Shell.run("/usr/bin/tar", ["-xzf", url.path, "-C", root ?? Self.root(for: id)])
        return r.status == 0 ? nil : "Could not unpack \(url.lastPathComponent)."
    }

    struct CleanerError: Error, LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }
}

// MARK: The tab

struct AgentDataTab: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @State private var archiving: (source: DataSource, plan: Archiver.Plan, days: Int)?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack { Seg([("Sources", DataMode.sources), ("Containers", DataMode.containers)], selection: Bindable(nav).dataMode); Spacer() }
                .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 2)
            if nav.dataMode == .containers { DockerView() } else { sources }
        }
        .task { await store.sources.measureIfNeeded() }
    }

    private var sources: some View {
        let m = store.sources
        let rows = m.sources()
        let known = rows.compactMap { m.bytes($0) }.reduce(0, +) + (m.dockerTotal ?? 0)
        func tierBytes(_ t: Tier) -> Int64 { rows.filter { $0.tier == t }.compactMap { m.bytes($0) }.reduce(0, +) + (t == .rebuildable ? (m.dockerTotal ?? 0) : 0) }
        return Page {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(m.loading && known == 0 ? "—" : known.byteParts.number).font(.figure(40)).monospacedDigit()
                        Text(known.byteParts.unit).font(.figure(18)).foregroundStyle(.secondary)
                        Text("across \(rows.count + 1) places. \(tierBytes(.rebuildable).bytesString) of it is rebuildable.").font(.bBody).padding(.leading, 6)
                        if m.loading { ProgressView().controlSize(.small) }
                    }
                    Ladder(parts: Tier.allCases.map { (Double(tierBytes($0)), $0.color) }, height: 12, label: Tier.allCases.map { "\($0.title) \(tierBytes($0).bytesString)" }.joined(separator: ", "))
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    header
                    ForEach(rows) { s in sourceRow(s, m.bytes(s)) }
                    dockerRow(m)
                }
            }
            Note(text: "Not listed on purpose: your Documents, Photos, iCloud Drive, Mail and system files. If an agent or dev tool did not make it, it is not ours to remove.")
            if let message { Text(message).font(.bCaption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } })) { archiveSheet }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Source").frame(maxWidth: .infinity, alignment: .leading)
            Text("Trust").frame(width: 110, alignment: .leading)
            Text("Keep for").frame(width: 170, alignment: .leading)
            Text("Size").frame(width: 70, alignment: .trailing)
            Color.clear.frame(width: 78)
        }.font(.bCaption2).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9).overlay(alignment: .bottom) { Divider() }
    }

    private func sourceRow(_ s: DataSource, _ bytes: Int64?) -> some View {
        HStack(spacing: 12) {
            TierChip(symbol: s.symbol, tone: s.tier.tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.bBody.weight(.medium))
                Text(s.detail).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Tag(text: s.tier.title, tone: s.tier.tone).frame(width: 110, alignment: .leading)
            Group {
                if s.archivable { KeepMenu(id: s.id) } else { Text("Rebuilt when needed").font(.bCaption).foregroundStyle(.secondary) }
            }.frame(width: 170, alignment: .leading)
            Text(bytes.map { $0.bytesString } ?? "…").font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button(s.archivable ? "Archive" : "Clear") { act(s) }.disabled((bytes ?? 0) == 0 || working).frame(width: 78)
        }
        .padding(.horizontal, 20).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
    }

    private func dockerRow(_ m: SourcesModel) -> some View {
        HStack(spacing: 12) {
            TierChip(symbol: "shippingbox", tone: .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Docker and OrbStack").font(.bBody.weight(.medium))
                Text(m.dockerReclaimable.map { "\($0.bytesString) reclaimable. The disk image shrinks after Docker compacts it." } ?? m.dockerState).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Tag(text: Tier.rebuildable.title, tone: .green).frame(width: 110, alignment: .leading)
            Text("Rebuilt when needed").font(.bCaption).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
            Text(m.dockerTotal.map { $0.bytesString } ?? "—").font(.bBody).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button("Prune") { nav.dataMode = .containers }.disabled(m.dockerTotal == nil).frame(width: 78)
        }
        .padding(.horizontal, 20).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
    }

    private func act(_ s: DataSource) {
        if s.archivable {
            let days = KeepMenu.days(s.id)
            let id = s.id
            working = true
            Task {
                let plan = await Task.detached { Archiver.candidates(id: id, days: days) }.value
                working = false
                if plan.files.isEmpty { message = "No \(s.name.lowercased()) are older than \(days) days." } else { archiving = (s, plan, days) }
            }
        } else {
            store.propose(.removeWorkspaces, for: store.sources.entries(for: s))
        }
    }

    private var archiveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let a = archiving {
                Text("Archive \(a.plan.files.count) sessions?").font(.bTitle2.bold())
                Text("Sessions not touched for \(a.days) days, \(a.plan.bytes.bytesString) in all, are packed into one compressed file in Keeper's folder and removed from \(a.plan.root.replacingOccurrences(of: home, with: "~")). They stop appearing in Traces and cannot be resumed until you restore the archive from History.")
                    .font(.bCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { archiving = nil }.keyboardShortcut(.cancelAction)
                    Button(working ? "Archiving…" : "Archive \(a.plan.bytes.bytesString)") {
                        working = true
                        let id = a.source.id, plan = a.plan
                        Task {
                            let r = await Task.detached(priority: .utility) { Archiver.archive(plan, id: id) }.value
                            working = false; archiving = nil
                            switch r {
                            case .success(let u): message = "Archived \(plan.files.count) sessions to \(u.lastPathComponent)."; await store.sources.measure(); store.loadTraces()
                            case .failure(let e): message = e.localizedDescription
                            }
                        }
                    }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent).disabled(working)
                }
            }
        }.padding(24).frame(width: 480)
    }
}

/// "Archive after 60 days": the one policy a person sets per source. Stored under `keep.<id>`.
struct KeepMenu: View {
    let id: String
    @AppStorage private var days: Int
    init(id: String) { self.id = id; _days = AppStorage(wrappedValue: 60, Prefs.Key.keepDays(id)) }
    static func days(_ id: String) -> Int { let v = UserDefaults.standard.integer(forKey: Prefs.Key.keepDays(id)); return v == 0 ? 60 : v }
    var body: some View {
        Menu {
            ForEach([14, 30, 60, 90, 180], id: \.self) { d in Button("Archive after \(d) days") { days = d } }
        } label: {
            HStack(spacing: 4) { Text("Archive after \(days) days").font(.bCaption.weight(.medium)); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)) }
                .padding(.horizontal, 9).frame(height: 26).background(Brand.muted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
