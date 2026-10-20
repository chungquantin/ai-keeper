import Foundation

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func git(_ dir: String, _ args: [String]) -> (status: Int32, out: String) {
        run("/usr/bin/git", ["-C", dir] + args)
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
    var bytesString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
