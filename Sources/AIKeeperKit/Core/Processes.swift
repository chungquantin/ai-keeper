import SwiftUI

struct ProcGroup: Identifiable {
    var id: String { name }
    let name: String
    var pids: [Int32] = []
    var rss: Int64 = 0
    var cpu: Double = 0
    var dev: Bool = false
}

struct MemoryInfo {
    var total: Int64 = 0
    var used: Int64 = 0
    var swapUsed: Int64 = 0
    var freePercent: Int = 0
}

enum Procs {
    static let devNames = ["rust-analyzer", "rustc", "cargo", "node", "tsserver", "esbuild", "Cursor", "Code", "Docker", "OrbStack", "claude", "codex", "java", "gradle", "Xcode", "SourceKit", "lldb", "python"]

    /// Groups by app. Reads the kernel's process table directly; no subprocess.
    static func scan() -> (groups: [ProcGroup], mem: MemoryInfo) {
        var map: [String: ProcGroup] = [:]
        for p in ProcTable.all() {
            let name = groupName(p.command)
            var g = map[name] ?? ProcGroup(name: name, dev: devNames.contains { name.localizedCaseInsensitiveContains($0) })
            g.pids.append(p.pid); g.rss += p.rss; g.cpu += p.cpu
            map[name] = g
        }
        return (map.values.sorted { $0.rss > $1.rss }, MemoryInfo())
    }

    /// Four subprocesses; only the dev command line (`--probe2`) asks for it.
    static func scanWithMemory() -> (groups: [ProcGroup], mem: MemoryInfo) {
        let r = scan(); return (r.groups, memory())
    }

    /// "/Applications/Cursor.app/Contents/..." -> "Cursor"; plain binaries -> basename.
    static func groupName(_ cmd: String) -> String {
        if let r = cmd.range(of: ".app/") {
            let head = cmd[..<r.lowerBound]
            return String(head.split(separator: "/").last ?? "app").replacingOccurrences(of: " Helper", with: "")
        }
        let first = cmd.split(separator: " ", maxSplits: 1).first.map(String.init) ?? cmd
        return (first as NSString).lastPathComponent
    }

    static func memory() -> MemoryInfo {
        var m = MemoryInfo()
        m.total = Int64(Shell.run("/usr/sbin/sysctl", ["-n", "hw.memsize"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let vm = Shell.run("/usr/bin/vm_stat", []).out
        let page = Int64(vm.firstMatch(#"page size of (\d+)"#) ?? "16384") ?? 16384
        func pages(_ key: String) -> Int64 { Int64(vm.firstMatch("\(key):\\s+(\\d+)") ?? "0") ?? 0 }
        m.used = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * page
        let swap = Shell.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).out
        if let u = swap.firstMatch(#"used = ([\d.]+)M"#), let d = Double(u) { m.swapUsed = Int64(d * 1_048_576) }
        let pr = Shell.run("/usr/bin/memory_pressure", ["-Q"]).out
        m.freePercent = Int(pr.firstMatch(#"free percentage: (\d+)"#) ?? "") ?? 0
        return m
    }
}

extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern), let m = rx.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
