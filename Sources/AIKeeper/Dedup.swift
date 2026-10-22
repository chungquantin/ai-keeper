import CryptoKit
import Darwin
import SwiftUI

struct DupReport {
    struct Group { let size: Int64; let paths: [String]; var reclaim: Int64 { size * Int64(paths.count - 1) } }
    var groups: [Group]
    var scannedFiles: Int
    var reclaim: Int64 { groups.reduce(0) { $0 + $1.reclaim } }
    var duplicateFiles: Int { groups.reduce(0) { $0 + $1.paths.count - 1 } }
}

/// Finds identical files across `node_modules`-style folders and replaces copies with APFS clones
/// (copy-on-write: same bytes on disk until one copy changes).
enum Dedup {
    static let rootNames: Set<String> = ["node_modules", ".venv", "venv", "Pods"]
    static let minSize: Int64 = 8 * 1024

    private struct F { let path: String; let size: Int64; let mode: UInt16 }

    private final class Flag: @unchecked Sendable {
        private let l = NSLock(); private var v = false
        var isSet: Bool { l.withLock { v } }
        func set() { l.withLock { v = true } }
    }

    static func roots(from holders: [Entry]) -> [String] {
        holders.flatMap(\.artifacts).filter { rootNames.contains($0.label) }.map(\.path)
    }

    /// Persisted: files we already cloned, so they aren't counted as savings again.
    static var done: Set<String> {
        get { Set(Persist.load([String].self, "dedup-done.json") ?? []) }
        set { Persist.save(Array(newValue), "dedup-done.json") }
    }

    static func analyze(roots: [String], flag: DedupModel.CancelFlag, progress: @escaping @Sendable (DedupModel.Phase) -> Void) -> DupReport {
        var files: [F] = []
        var stack = roots
        var seen = 0
        while let dir = stack.popLast() {
            if flag.isSet { break }
            guard let d = opendir(dir) else { continue }
            while let ent = readdir(d) {
                let name = withUnsafePointer(to: &ent.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let p = dir + "/" + name
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: stack.append(p)
                case S_IFREG where st.st_nlink == 1 && Int64(st.st_size) >= minSize:
                    files.append(F(path: p, size: Int64(st.st_size), mode: st.st_mode & 0o7777))
                default: break
                }
                seen += 1
                if seen % 5000 == 0 { progress(.scanning(files: seen)) }
            }
            closedir(d)
        }

        // Only files whose size+mode appear more than once can be duplicates.
        let bySize = Dictionary(grouping: files) { "\($0.size)|\($0.mode)" }.values.filter { $0.count > 1 }
        let candidates = bySize.flatMap { $0 }
        var hashed = 0
        let lock = NSLock()
        var byHash: [String: [F]] = [:]
        let total = candidates.count
        let slices = 8
        DispatchQueue.concurrentPerform(iterations: slices) { s in
            var i = s
            while i < candidates.count {
                if flag.isSet { return }
                let f = candidates[i]
                if let h = sha(f.path) {
                    lock.withLock { byHash["\(f.size)|\(f.mode)|\(h)", default: []].append(f); hashed += 1; if hashed % 500 == 0 { progress(.hashing(done: hashed, total: total)) } }
                }
                i += slices
            }
        }
        let cloned = Self.done
        let groups: [DupReport.Group] = byHash.values.compactMap { g in
            guard g.count > 1 else { return nil }
            // Files we cloned earlier already share storage. Keep one of them as the master so new copies join that set.
            let fresh = g.filter { !cloned.contains($0.path) }
            let master = g.first { cloned.contains($0.path) }.map { [$0.path] } ?? []
            let paths = master + fresh.map(\.path)
            return paths.count > 1 ? DupReport.Group(size: g[0].size, paths: paths) : nil
        }
        return DupReport(groups: groups.sorted { $0.reclaim > $1.reclaim }, scannedFiles: files.count)
    }

    private static func sha(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Byte-for-byte comparison, read again right before a file is replaced: it may have changed since the analysis.
    private static func sameContent(_ a: String, _ b: String) -> Bool {
        guard let fa = fopen(a, "rb"), let fb = fopen(b, "rb") else { return false }
        defer { fclose(fa); fclose(fb) }
        let n = 1 << 20
        let ba = UnsafeMutablePointer<UInt8>.allocate(capacity: n), bb = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        defer { ba.deallocate(); bb.deallocate() }
        while true {
            let ra = fread(ba, 1, n, fa), rb = fread(bb, 1, n, fb)
            if ra != rb || memcmp(ba, bb, ra) != 0 { return false }
            if ra == 0 { return true }
        }
    }

    /// Replace each duplicate with a clone of the first file in its group. Atomic per file (clone to temp, rename over).
    static func merge(_ report: DupReport, flag: DedupModel.CancelFlag, progress: @escaping @Sendable (Int, Int, Int64) -> Void) -> (freed: Int64, failed: Int) {
        var freed: Int64 = 0, failed = 0, done = 0
        var cloned = Self.done
        let total = report.groups.count
        for g in report.groups {
            if flag.isSet { break }
            let master = g.paths[0]
            for p in g.paths.dropFirst() {
                let tmp = p + ".aikeeper-clone"
                var a = stat(), b = stat()
                guard lstat(master, &a) == 0, lstat(p, &b) == 0, a.st_size == b.st_size, a.st_dev == b.st_dev, sameContent(master, p) else { failed += 1; continue }
                if clonefile(master, tmp, 0) == 0 {
                    if rename(tmp, p) == 0 { freed += g.size; cloned.insert(p) } else { unlink(tmp); failed += 1 }
                } else { failed += 1 }
            }
            cloned.insert(master)
            done += 1
            progress(done, total, freed)
        }
        Self.done = cloned
        return (freed, failed)
    }
}

@MainActor
final class DedupModel: ObservableObject {
    enum Phase { case idle, scanning(files: Int), hashing(done: Int, total: Int), ready, merging(done: Int, total: Int, freed: Int64), finished(freed: Int64, failed: Int) }
    final class CancelFlag: @unchecked Sendable {
        private let l = NSLock(); private var v = false
        var isSet: Bool { l.withLock { v } }
        func set() { l.withLock { v = true } }
    }

    @Published var phase: Phase = .idle
    @Published var report: DupReport?
    private var flag = CancelFlag()

    var busy: Bool {
        switch phase { case .scanning, .hashing, .merging: return true; default: return false }
    }

    func analyze(roots: [String]) {
        guard !busy else { return }
        flag = CancelFlag()
        let f = flag
        phase = .scanning(files: 0)
        Task.detached(priority: .utility) {
            let r = Dedup.analyze(roots: roots, flag: f) { p in DispatchQueue.main.async { [weak self] in if self?.busy == true { self?.phase = p } } }
            await MainActor.run { self.report = r; self.phase = f.isSet ? .idle : .ready }
        }
    }

    func merge() {
        guard let r = report, !busy else { return }
        flag = CancelFlag()
        let f = flag
        phase = .merging(done: 0, total: r.groups.count, freed: 0)
        Task.detached(priority: .utility) {
            let res = Dedup.merge(r, flag: f) { d, t, fr in DispatchQueue.main.async { [weak self] in if self?.busy == true { self?.phase = .merging(done: d, total: t, freed: fr) } } }
            await MainActor.run { self.phase = .finished(freed: res.freed, failed: res.failed); self.report = nil }
        }
    }

    func cancel() { flag.set() }
}

struct DedupView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var model: DedupModel
    @State private var confirm = false

    private var roots: [String] { Dedup.roots(from: store.buildHolders) }
    private var rustTargets: [Artifact] { store.buildHolders.flatMap(\.artifacts).filter { $0.label == "target" } }
    private var nodeModules: [Artifact] { store.buildHolders.flatMap(\.artifacts).filter { $0.label == "node_modules" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Each worktree keeps its own copy of dependencies. Most of those files are identical. Merging replaces the copies with APFS clones, so they share disk space until one of them changes. Nothing about how your projects run changes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                analyzer
                tips
            }.padding(28).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 62) }   // keep the first row clear of the glass toolbar
        .navigationTitle("Duplicates")
        .confirmationDialog("Merge duplicate files?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Merge and free \((model.report?.reclaim ?? 0).bytesString)") { model.merge() }
        } message: { Text("Identical files are replaced by copy-on-write clones. Contents stay byte-for-byte the same, and editing a file only changes that copy.") }
    }

    @ViewBuilder private var analyzer: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .idle:
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Find duplicates").font(.headline)
                        Text("Scans \(roots.count) dependency folders (node_modules, .venv, Pods).").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Analyze") { model.analyze(roots: roots) }.buttonStyle(.borderedProminent).disabled(roots.isEmpty)
                }
            case .scanning(let n):
                progress("Listing files", "\(n) entries seen")
            case .hashing(let d, let t):
                progress("Comparing contents", "\(d) of \(t) candidate files", value: Double(d) / Double(max(t, 1)))
            case .ready:
                if let r = model.report, r.reclaim > 0 {
                    let p = r.reclaim.byteParts
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(p.number).font(.figure(54)).monospacedDigit()
                        Text(p.unit).font(.figure(24, .regular)).foregroundStyle(.secondary)
                        Text("can be shared").foregroundStyle(.secondary).padding(.leading, 4)
                    }
                    Text("\(r.duplicateFiles) duplicate files in \(r.groups.count) groups, out of \(r.scannedFiles) files scanned.").foregroundStyle(.secondary)
                    HStack {
                        Button("Merge duplicates") { confirm = true }.buttonStyle(.borderedProminent).tint(Brand.accent).controlSize(.large)
                        Button("Analyze again") { model.analyze(roots: roots) }.controlSize(.large)
                    }
                } else {
                    Label("No meaningful duplicates found.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                    Button("Analyze again") { model.analyze(roots: roots) }
                }
            case .merging(let d, let t, let freed):
                progress("Merging", "\(freed.bytesString) shared so far", value: Double(d) / Double(max(t, 1)))
            case .finished(let freed, let failed):
                Label("\(freed.bytesString) now shared", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(Brand.accent)
                if failed > 0 { Text("\(failed) files were skipped (changed or on another volume).").foregroundStyle(.secondary) }
                Text("Free space updates as macOS reclaims the blocks. Run Analyze again any time.").font(.callout).foregroundStyle(.secondary)
                Button("Done") { model.phase = .idle }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).panel(14)
    }

    private func progress(_ title: String, _ detail: String, value: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Button("Stop") { model.cancel() } }
            if let value { ProgressView(value: value) } else { ProgressView().progressViewStyle(.linear) }
            Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: Tips

    @ViewBuilder private var tips: some View {
        let rustBytes = rustTargets.reduce(Int64(0)) { $0 + $1.bytes }
        if rustTargets.count >= 2 {
            tip("Share one Rust build cache", "\(rustTargets.count) separate `target` folders use \(rustBytes.bytesString). Point them at one folder, or cache compiled crates with sccache.",
                "export CARGO_TARGET_DIR=\"$HOME/.cache/cargo-target\"\n# or\nbrew install sccache && export RUSTC_WRAPPER=sccache")
        }
        if nodeModules.count >= 2 {
            tip("Use a shared package store", "\(nodeModules.count) `node_modules` folders hold \(nodeModules.reduce(Int64(0)) { $0 + $1.bytes }.bytesString). pnpm keeps one copy of each package and links it into every project.",
                "corepack enable && corepack prepare pnpm@latest --activate\npnpm import && pnpm install")
        }
    }

    private func tip(_ title: String, _ body: String, _ snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text(snippet).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snippet, forType: .string) }.controlSize(.small)
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }.padding(16).panel(14)
    }
}
