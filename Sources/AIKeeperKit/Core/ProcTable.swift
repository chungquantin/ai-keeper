import Darwin
import Foundation

/// The process list, read straight from the kernel through libproc. Spawning `ps` and `lsof` every few seconds
/// costs far more than the data is worth, and every spawn is also inspected by endpoint-security tools.
enum ProcTable {
    struct Proc {
        let pid: Int32
        let ppid: Int32
        let started: Date
        let rss: Int64
        let cpu: Double        // percent of one core since the previous call (lifetime average the first time)
        let command: String    // full command line when readable, else the executable path
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var last: [Int32: (cpuNs: UInt64, at: Date)] = [:]
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    static func all() -> [Proc] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let now = Date()
        lock.lock(); let previous = last; lock.unlock()
        var seen: [Int32: (cpuNs: UInt64, at: Date)] = [:]
        var out: [Proc] = []
        out.reserveCapacity(Int(got))
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            var task = proc_taskinfo()
            let haveTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size)
            let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
            var cpu = 0.0, rss: Int64 = 0
            if haveTask {
                let ns = (task.pti_total_user &+ task.pti_total_system) &* timebase.numer / timebase.denom
                seen[pid] = (ns, now)
                if let p = previous[pid], now.timeIntervalSince(p.at) > 0.2, ns >= p.cpuNs {
                    cpu = Double(ns - p.cpuNs) / 1e9 / now.timeIntervalSince(p.at) * 100
                } else {
                    cpu = Double(ns) / 1e9 / max(now.timeIntervalSince(started), 1) * 100
                }
                rss = Int64(task.pti_resident_size)
            }
            out.append(Proc(pid: pid, ppid: Int32(bsd.pbi_ppid), started: started, rss: rss, cpu: cpu, command: commandLine(pid) ?? path(pid) ?? name(bsd)))
        }
        lock.lock(); last = seen; lock.unlock()
        return out
    }

    /// Working directory of one process (what `lsof -d cwd` printed).
    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }.nilIfEmpty
    }

    private static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private static func name(_ bsd: proc_bsdinfo) -> String {
        var n = bsd.pbi_name
        return withUnsafePointer(to: &n) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
    }

    /// argv joined by spaces, like the `command` column of `ps`. Only readable for your own processes.
    private static func commandLine(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 8 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }      // executable path
        while i < size, buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while i < size, args.count < argc {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
