import Foundation

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: String? = nil) -> (status: Int32, out: String) {
        let r = runData(exe, args, cwd: cwd)
        return (r.status, String(decoding: r.data, as: UTF8.self))
    }

    /// Same as `run`, but the output stays as bytes (a binary patch must not be pushed through UTF-8).
    static func runData(_ exe: String, _ args: [String], cwd: String? = nil) -> (status: Int32, data: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        // Housekeeping must never compete with what you are doing: the scheduler and the disk both yield to foreground work.
        p.qualityOfService = .background
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"   // read-only status checks should not touch your repositories' index files
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Worktrees are written by agents, so never let their config run programs (core.fsmonitor) or hooks while we only read.
    private static let gitSafety = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    static func git(_ dir: String, _ args: [String]) -> (status: Int32, out: String) {
        run("/usr/bin/git", gitSafety + ["-C", dir] + args)
    }

    static func gitData(_ dir: String, _ args: [String]) -> (status: Int32, data: Data) {
        runData("/usr/bin/git", gitSafety + ["-C", dir] + args)
    }

    /// Disk usage in bytes (allocated blocks), like `du -sk`.
    static func du(_ path: String) -> Int64 {
        let r = run("/usr/bin/du", ["-sk", path])
        guard let first = r.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kb = Int64(first) else { return 0 }
        return kb * 1024
    }
}

extension Int64 {
    var bytesString: String {
        guard Demo.enabled else { return ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
        // Screenshots always use US number formatting (String(format:) is locale-independent).
        let v = Double(self)
        if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
        if v >= 1e9 { return String(format: v >= 1e10 ? "%.0f GB" : "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        return String(format: "%.0f KB", v / 1e3)
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
