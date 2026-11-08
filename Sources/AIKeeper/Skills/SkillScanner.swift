import Foundation

/// Runs NVIDIA's SkillSpector (https://github.com/NVIDIA/SkillSpector, Apache-2.0) over skills.
/// AI Keeper does not bundle it. It is a separate program the user installs, and every scan is a static one
/// (`--no-llm`): nothing from a skill is sent to a language model. SkillSpector's dependency check does ask
/// api.osv.dev about the package names and versions a skill lists, and the page says so.
enum SkillScanner {
    /// A reviewed release. Installing "whatever is on main" would run code nobody looked at.
    static let pinnedRef = "v2.13.4"
    static let source = "git+https://github.com/NVIDIA/skillspector.git"
    static let projectURL = "https://github.com/NVIDIA/SkillSpector"

    static var installCommand: String { "uv tool install --python 3.12 \(source)@\(pinnedRef)" }

    private static func search(_ name: String) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"]
        return (path + extra).map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func locate() -> String? {
        if Demo.enabled { return "/opt/homebrew/bin/skillspector" }
        if let custom = ProcessInfo.processInfo.environment["AIKEEPER_SKILLSPECTOR"], FileManager.default.isExecutableFile(atPath: custom) { return custom }
        return search("skillspector")
    }
    static func uv() -> String? { search("uv") }

    /// 1 normal, 2 warning, 4 critical: how hard the Mac is working to find memory.
    static func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 1
    }
    /// Each scanner is a Python process of a few hundred MB. On a Mac that is already short of memory, two at once make it worse for everything.
    static var lowMemory: Bool { memoryPressure() >= 2 }
    static var suggestedConcurrency: Int { lowMemory ? 1 : 2 }
    static let lowMemoryNote = "This Mac is short on memory, so scanning will be slow. Scanning one at a time. Finished results are kept if you stop."

    // MARK: Stopping a scan

    /// Lets a scan be stopped from outside: Esc in the dashboard, Ctrl-C, quitting the app. Stopping ends the scanner
    /// processes too, so nothing keeps running in the background.
    final class ScanToken: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []
        private var _cancelled = false
        private var _current: [String] = []
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        var current: [String] { get { lock.lock(); defer { lock.unlock() }; return _current } set { lock.lock(); _current = newValue; lock.unlock() } }
        fileprivate func register(_ p: Process) -> Bool { lock.lock(); defer { lock.unlock() }; if _cancelled { return false }; processes.append(p); return true }
        fileprivate func forget(_ p: Process) { lock.lock(); processes.removeAll { $0 === p }; lock.unlock() }
        func cancel() {
            lock.lock(); _cancelled = true; let running = processes; lock.unlock()
            for p in running where p.isRunning { p.terminate() }
            SkillScanner.forget(self)
        }
    }

    private nonisolated(unsafe) static var tokens: [ScanToken] = []
    private static let tokensLock = NSLock()
    static func track(_ t: ScanToken) { tokensLock.lock(); tokens.append(t); tokensLock.unlock() }
    fileprivate static func forget(_ t: ScanToken) { tokensLock.lock(); tokens.removeAll { $0 === t }; tokensLock.unlock() }
    /// Called when the app or the dashboard exits.
    static func cancelAll() { tokensLock.lock(); let all = tokens; tokensLock.unlock(); all.forEach { $0.cancel() } }

    // MARK: Running a process safely

    struct Result { var status: Int32; var out: Data; var err: String; var timedOut: Bool }

    /// The scanner is third-party code reading untrusted files: it gets a bare environment, never your API keys.
    static func cleanEnvironment(for binary: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "\((binary as NSString).deletingLastPathComponent):\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home, "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(), "NO_COLOR": "1", "PYTHONNOUSERSITE": "1",
        ]
        for k in ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"] { if let v = inherited[k] { env[k] = v } }   // corporate networks
        return env
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, maxOutput: Int = 24 << 20, token: ScanToken? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = cleanEnvironment(for: exe)
        // Utility, not background: a scan is something you are waiting for. At background priority a busy Mac starves the
        // scanner almost completely (throttled disk, near-zero CPU), which looks exactly like a freeze.
        p.qualityOfService = .utility
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let lock = NSLock()
        var outData = Data(), errData = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; lock.lock(); if outData.count < maxOutput { outData.append(d) }; lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; lock.lock(); if errData.count < 64 << 10 { errData.append(d) }; lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return Result(status: -1, out: Data(), err: "Couldn't start: \(error.localizedDescription)", timedOut: false) }
        if let token, !token.register(p) { p.terminate(); return Result(status: -1, out: Data(), err: "Stopped.", timedOut: false) }
        defer { token?.forget(p) }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut { timedOut = true; p.terminate(); _ = done.wait(timeout: .now() + 3); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        outData.append(out.fileHandleForReading.availableData)
        return Result(status: p.terminationStatus, out: outData, err: Sanitize.text(String(decoding: errData, as: UTF8.self), max: 800), timedOut: timedOut)
    }

    // MARK: Install (only ever called after the user said yes)

    static func install() -> (ok: Bool, message: String) {
        guard let uv = uv() else { return (false, "`uv` is not installed. Install it with `brew install uv`, then try again.") }
        let r = run(uv, ["tool", "install", "--python", "3.12", "\(source)@\(pinnedRef)"], timeout: 900)
        if r.timedOut { return (false, "The install took too long and was stopped. Run it yourself: \(installCommand)") }
        guard r.status == 0 else { return (false, "The install failed: \(r.err.isEmpty ? "exit \(r.status)" : r.err)") }
        return (locate() != nil, locate() != nil ? "SkillSpector \(pinnedRef) is installed." : "Installed, but it isn't on your PATH. Run `uv tool update-shell` and open a new terminal.")
    }

    // MARK: Scanning

    enum ScanError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    /// Scans one skill folder. Always the real path: SkillSpector refuses symlinks on purpose.
    static func scan(_ skill: SkillInfo, binary: String, token: ScanToken? = nil) -> Swift.Result<SkillScan, ScanError> {
        let r = run(binary, ["scan", skill.realPath, "--no-llm", "--format", "json"], timeout: 240, token: token)
        if token?.cancelled == true { return .failure(.failed("Stopped.")) }
        if r.timedOut { return .failure(.failed("The scan took more than four minutes and was stopped.")) }
        // Exit 0 and 1 both mean the scan finished (1 = risky); 2 is an error.
        guard r.status == 0 || r.status == 1 else { return .failure(.failed(r.err.isEmpty ? "SkillSpector exited with \(r.status)." : r.err)) }
        guard let scan = parse(r.out, signature: skill.signature) else { return .failure(.failed("Couldn't read SkillSpector's report.")) }
        return .success(scan)
    }

    static func parse(_ data: Data, signature: String) -> SkillScan? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object: o, signature: signature)
    }

    static func parse(object o: [String: Any], signature: String) -> SkillScan? {
        guard let ra = o["risk_assessment"] as? [String: Any] else { return nil }
        let issues: [SkillIssue] = (o["issues"] as? [[String: Any]] ?? []).prefix(300).map { i in
            let loc = i["location"] as? [String: Any]
            return SkillIssue(rule: Sanitize.line(i["id"] as? String ?? "?", max: 24), category: Sanitize.line(i["category"] as? String ?? "", max: 80),
                              severity: (i["severity"] as? String ?? "LOW").uppercased(), confidence: i["confidence"] as? Double ?? 0,
                              file: Sanitize.line(loc?["file"] as? String ?? "", max: 200), line: loc?["start_line"] as? Int ?? 0,
                              finding: Sanitize.line(i["finding"] as? String ?? "", max: 240), explanation: Sanitize.text(i["explanation"] as? String ?? "", max: 700),
                              remediation: Sanitize.text(i["remediation"] as? String ?? "", max: 500),
                              snippet: (i["code_snippet"] as? String).map { Sanitize.text($0.trimmingCharacters(in: .whitespacesAndNewlines), max: 900) })
        }.sorted { ($0.rank, $0.confidence) > ($1.rank, $1.confidence) }
        let meta = o["metadata"] as? [String: Any]
        let completeness = o["analysis_completeness"] as? [String: Any]
        return SkillScan(score: ra["score"] as? Int ?? 0, severity: (ra["severity"] as? String ?? "LOW").uppercased(), recommendation: ra["recommendation"] as? String ?? "CAUTION",
                         issues: issues, scannedAt: .now, scannerVersion: Sanitize.line(meta?["skillspector_version"] as? String ?? "?", max: 20), signature: signature,
                         complete: (completeness?["is_complete"] as? Bool ?? true) && (o["execution_successful"] as? Bool ?? true))
    }

    // MARK: Results on disk

    private static let cacheLock = NSLock()
    static func loadCache() -> [String: SkillScan] {
        if Demo.enabled { return MainActor.assumeIsolated { let s = Store(); s.loadDemo(); return s.skillScans } }
        return Persist.load([String: SkillScan].self, "skill-scans.json") ?? [:]
    }
    static func saveCache(_ c: [String: SkillScan]) { cacheLock.lock(); Persist.save(c, "skill-scans.json"); cacheLock.unlock() }

    /// A saved result only counts while the skill's files are unchanged.
    static func current(_ skill: SkillInfo, in cache: [String: SkillScan]) -> SkillScan? {
        guard let s = cache[skill.realPath], s.signature == skill.signature else { return nil }
        return s
    }

    // MARK: Batches

    /// Starting Python once per skill is most of a scan's cost. SkillSpector can scan a folder of skills in one process, so
    /// small skills are copied into a temporary folder (symlinks stay symlinks) and scanned together. Anything that doesn't
    /// come back cleanly is scanned on its own, so batching can only make a scan faster, never less complete.
    private static let batchSize = 8
    private static let maxBatchedBytes: Int64 = 30 << 20

    private static func scanBatch(_ skills: [SkillInfo], binary: String, token: ScanToken) -> [String: SkillScan] {
        let fm = FileManager.default
        guard let stage = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true) else { return [:] }
        defer { try? fm.removeItem(at: stage) }
        var staged: [String: SkillInfo] = [:]
        for (i, sk) in skills.enumerated() {
            let name = String(format: "s%03d", i)
            guard Skills.copy(sk.realPath, to: stage.appendingPathComponent(name).path) else { continue }
            staged[name] = sk
        }
        guard staged.count > 1 else { return [:] }
        let r = run(binary, ["scan", stage.path, "--recursive", "--max-skills", "\(max(staged.count, 2))", "--no-llm", "--format", "json"], timeout: 120 + Double(staged.count) * 30, token: token)
        guard !token.cancelled, r.status == 0 || r.status == 1, !r.timedOut,
              let o = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any], let entries = o["skills"] as? [[String: Any]] else { return [:] }
        var out: [String: SkillScan] = [:]
        for e in entries {
            guard let path = e["path"] as? String, let skill = staged[(path as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] ?? staged[path.replacingOccurrences(of: "/", with: "")],
                  let scan = parse(object: e, signature: skill.signature) else { continue }
            out[skill.realPath] = scan
        }
        return out
    }

    /// Scans skills in the background at low priority. `onResult` is called for each as it finishes. Stop it with `token.cancel()`.
    static func scanAll(_ skills: [SkillInfo], binary: String, concurrency: Int = SkillScanner.suggestedConcurrency, token: ScanToken = ScanToken(), onResult: @escaping (SkillInfo, Swift.Result<SkillScan, ScanError>, Int) -> Void) {
        track(token)
        defer { forget(token) }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, concurrency)
        queue.qualityOfService = .utility
        let lock = NSLock()
        var done = 0
        func report(_ s: SkillInfo, _ r: Swift.Result<SkillScan, ScanError>) {
            guard !token.cancelled else { return }
            lock.lock(); done += 1; let n = done; lock.unlock()
            onResult(s, r, n)
        }
        let small = skills.filter { $0.bytes <= maxBatchedBytes && $0.files <= 2000 }
        let large = skills.filter { $0.bytes > maxBatchedBytes || $0.files > 2000 }
        var groups: [[SkillInfo]] = stride(from: 0, to: small.count, by: batchSize).map { Array(small[$0..<min($0 + batchSize, small.count)]) }
        groups += large.map { [$0] }
        for group in groups {
            queue.addOperation {
                guard !token.cancelled else { return }
                token.current = group.map(\.name)
                var results = group.count > 1 ? scanBatch(group, binary: binary, token: token) : [:]
                for s in group {
                    guard !token.cancelled else { return }
                    if let r = results.removeValue(forKey: s.realPath) { report(s, .success(r)) }
                    else { token.current = [s.name]; report(s, scan(s, binary: binary, token: token)) }   // not in the batch report: scan it alone
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
    }
}

/// Small file helpers for staging.
enum Skills {
    /// Copies a folder, keeping symlinks as symlinks (`ditto`), so a skill is scanned exactly as it is on disk.
    static func copy(_ from: String, to: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [from, to]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
