import Foundation

enum DiskCommands {
    static var all: [Command] { [disk] }

    private static func map(refresh: Bool) -> (StorageMapResult, Date)? {
        let url = Persist.dir.appendingPathComponent("map.json")
        let saved = Persist.load(StorageMapResult.self, "map.json")
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let saved, let date, !refresh { return (saved, date) }
        Out.status("Measuring your home folder… this can take a minute or two")
        let r = StorageMapper.scan(used: Tools.diskInfo().used)
        Out.endStatus()
        Persist.save(r, "map.json")
        return (r, .now)
    }

    private static func dir(_ arg: String?) -> String? {
        let p = URL(fileURLWithPath: ((arg ?? home) as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { Out.fail("\(arg ?? p) is not a folder."); return nil }
        return p
    }

    static let disk = Command(
        name: "disk", group: "Disk and system", summary: "Where the space went: map, explore any folder, find big files, clear safe folders",
        usage: ["keeper disk [--refresh] [--json]                    Disk map: categories and the biggest folders",
                "keeper disk explore [folder] [--limit N] [--json]   Sizes of what is inside a folder (default: home)",
                "keeper disk large [folder] [--min MB] [--limit N]   Files over a size (default 100 MB, whole home)",
                "keeper disk clean <folder> [--yes] [--permanent]    Empty a folder the map marks as safe to clear", "",
                "  The map is measured once and reused; --refresh measures again (slow, reads your whole home folder)."],
        valueOptions: ["limit", "min"],
        flags: ["refresh", "permanent"],
        run: { a in
            switch a.positional.first {
            case "explore":
                guard let path = dir(a.positional.dropFirst().first) else { return 2 }
                var nodes = DiskModel.list(path)
                let dirs = nodes.indices.filter { nodes[$0].size == nil }
                let q = OperationQueue(); q.maxConcurrentOperationCount = 4; q.qualityOfService = .utility
                let lock = NSLock(); var done = 0
                for i in dirs {
                    let p = nodes[i].path
                    q.addOperation {
                        let s = Shell.du(p)
                        lock.lock(); nodes[i].size = s; done += 1; let n = done; lock.unlock()
                        Out.status("Measuring \(n)/\(dirs.count)")
                    }
                }
                q.waitUntilAllOperationsAreFinished(); Out.endStatus()
                nodes.sort { ($0.size ?? 0) > ($1.size ?? 0) }
                let shown = Array(nodes.prefix(a.int("limit") ?? 25))
                if a.json { Out.json(["path": path, "total_bytes": nodes.reduce(Int64(0)) { $0 + ($1.size ?? 0) },
                                      "items": shown.map { ["name": $0.name, "path": $0.path, "directory": $0.isDir, "bytes": $0.size ?? 0, "hint": $0.hint as Any] as [String: Any] }] as [String: Any]); return 0 }
                Out.line(Term.bold(Fmt.tilde(path)) + Term.dim("  \(Fmt.size(nodes.reduce(Int64(0)) { $0 + ($1.size ?? 0) })) in \(nodes.count) items"))
                Out.line(Out.table(["SIZE", "", "NAME"], shown.map { [Out.Cell(Fmt.size($0.size ?? 0)), Out.Cell($0.isDir ? "dir" : "", Term.dim), Out.Cell($0.name + ($0.hint.map { "  " + Term.dim("· \($0)") } ?? ""))] }, right: [0]))
                return 0
            case "large":
                guard let path = dir(a.positional.dropFirst().first) else { return 2 }
                let mb = max(1, a.int("min") ?? 100)
                Out.status("Looking for files over \(mb) MB…")
                let out = Shell.run("/usr/bin/find", [path, "-xdev", "-type", "f", "-size", "+\(mb)M", "-exec", "stat", "-f", "%z\t%N", "{}", "+"]).out
                Out.endStatus()
                let files = out.split(separator: "\n").compactMap { l -> (Int64, String)? in
                    let f = l.split(separator: "\t", maxSplits: 1); guard f.count == 2, let s = Int64(f[0]) else { return nil }; return (s, String(f[1]))
                }.sorted { $0.0 > $1.0 }.prefix(a.int("limit") ?? 25)
                if a.json { Out.json(files.map { ["path": $0.1, "bytes": $0.0] as [String: Any] }); return 0 }
                guard !files.isEmpty else { Out.line("No files over \(mb) MB."); return 0 }
                Out.line(Out.table(["SIZE", "FILE"], files.map { [Out.Cell(Fmt.size($0.0)), Out.Cell(Fmt.tilde($0.1))] }, right: [0]))
                return 0
            case "clean":
                guard let sel = a.positional.dropFirst().first else { Out.fail("which folder? `keeper disk clean <folder>` (see the hotspots in `keeper disk`)."); return 2 }
                guard let path = dir(sel) else { return 2 }
                let name = (path as NSString).lastPathComponent
                guard StorageMapper.describe(path)?.clean == true || DiskModel.cleanable[name] != nil else {
                    Out.fail("\(Fmt.tilde(path)) is not a folder I know is safe to clear. Look at it with `keeper disk explore` and remove it yourself."); return 1
                }
                var e = Entry(id: "hs:" + path, kind: .cache, name: name, path: path, repoPath: nil, repoName: (path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? "",
                              branch: nil, sources: [.dev], note: StorageMapper.describe(path)?.hint ?? "")
                e.size = Shell.du(path); e.measured = true; e.verdict = .deprecated
                if !a.yes {
                    Out.line("Would empty \(Term.bold(Fmt.tilde(path))) (\(Fmt.size(e.size ?? 0))). The folder itself stays." + (e.note.isEmpty ? "" : "\n" + Term.dim(e.note)))
                    Out.line(Term.dim("\nDry run. Add --yes to do it.")); return 0
                }
                var o = CleanupOptions(); o.vault = false; o.permanent = a.flag("permanent")
                var scratch = Library.entries()
                let r = Library.execute(.removeWorkspaces, [e], options: o, all: &scratch)
                if a.json { Out.json(["freed_bytes": r.freed, "failures": r.failures.map { ["name": $0.name, "error": $0.error] }] as [String: Any]) }
                else { Out.line("Freed " + Term.bold(Fmt.size(r.freed))); for f in r.failures { Out.fail(f.error) } }
                return r.failures.isEmpty ? 0 : 1
            case nil:
                guard let (m, date) = map(refresh: a.flag("refresh")) else { return 1 }
                let free = Tools.diskInfo()
                if a.json {
                    Out.json(["measured": Fmt.iso(date) as Any, "home_bytes": m.homeTotal, "applications_bytes": m.apps, "free_bytes": free.available,
                              "groups": m.groups.map { ["name": $0.name, "bytes": $0.size] as [String: Any] },
                              "hotspots": m.hotspots.map { ["path": $0.path, "bytes": $0.size, "hint": $0.hint as Any, "safe_to_clear": $0.cleanable] as [String: Any] }] as [String: Any]); return 0
                }
                Out.line(Term.bold("\(Fmt.size(free.used)) used") + Term.dim(" · \(Fmt.size(free.available)) free · measured \(Fmt.ago(date))"))
                Out.line()
                let total = max(1, m.groups.reduce(Int64(0)) { $0 + $1.size })
                Out.line(Out.table(["SIZE", "SHARE", "CATEGORY"], m.groups.map { [Out.Cell(Fmt.size($0.size)), Out.Cell(Fmt.pct(Double($0.size) / Double(total)), Term.dim), Out.Cell($0.name + Term.dim("  \($0.detail)"))] }, right: [0, 1]))
                Out.line()
                Out.line(Term.bold("Biggest items"))
                Out.line(Out.table(["SIZE", "", "FOLDER"], m.hotspots.map { [Out.Cell(Fmt.size($0.size)), Out.Cell($0.cleanable ? "safe" : "", Term.blue), Out.Cell(Fmt.tilde($0.path) + ($0.hint.map { "  " + Term.dim("· \($0)") } ?? ""))] }, right: [0]))
                Out.line(Term.dim("\nExplore: keeper disk explore <folder>    Clear a safe one: keeper disk clean <folder> --yes"))
                return 0
            default:
                Out.fail("unknown disk command '\(a.positional[0])'. See `keeper help disk`."); return 2
            }
        })
}

enum SystemCommands {
    static var all: [Command] { [system] }

    static let system = Command(
        name: "system", aliases: ["health", "top"], group: "Disk and system", summary: "Live health check: CPU, memory, disk, network, battery, heaviest apps",
        usage: ["keeper system [--top N] [--json]", "", "  Samples for a couple of seconds so the rates are real, like the System page."],
        valueOptions: ["top"],
        run: { a in
            let sampler = SystemSampler()
            _ = sampler.sample()
            Out.status("Sampling…")
            Thread.sleep(forTimeInterval: 2)
            let s = sampler.sample()
            let groups = Procs.scan().groups
            Out.endStatus()
            let m = MachineInfo.read()
            let health = Health.evaluate(s, topCPU: groups.max { $0.cpu < $1.cpu }.map { "\($0.name) (\(Int($0.cpu))%)" },
                                         topMemory: groups.first.map { "\($0.name) (\(Fmt.size($0.rss)))" })
            let top = Array(groups.prefix(a.int("top") ?? 8))
            if a.json {
                var o: [String: Any] = [
                    "machine": ["model": m.model, "chip": m.chip, "cores": m.cores, "memory_bytes": m.memory, "os": m.os, "uptime_seconds": Int(m.uptime)],
                    "health": ["score": health.score, "reason": health.reason, "tips": health.tips.map(\.text)],
                    "cpu": ["percent": Int(s.cpuTotal * 100), "load": [s.load.0, s.load.1, s.load.2]],
                    "memory": ["used_bytes": s.memUsed, "total_bytes": s.memTotal, "available_bytes": s.memAvailable, "swap_used_bytes": s.swapUsed, "swap_total_bytes": s.swapTotal, "pressure": s.pressure],
                    "disk": ["used_bytes": s.diskUsed, "total_bytes": s.diskTotal, "read_bytes_per_sec": Int(s.readBps), "write_bytes_per_sec": Int(s.writeBps)],
                    "network": ["down_bytes_per_sec": Int(s.netDown), "up_bytes_per_sec": Int(s.netUp)],
                    "top_apps": top.map { ["name": $0.name, "processes": $0.pids.count, "memory_bytes": $0.rss, "cpu_percent": Int($0.cpu), "developer_tool": $0.dev] as [String: Any] },
                ]
                if let b = s.battery { o["battery"] = ["percent": Int(b.level * 100), "charging": b.charging, "on_ac": b.onAC] }
                Out.json(o); return 0
            }
            let scoreStyle: (String) -> String = health.score >= 80 ? Term.blue : health.score >= 60 ? Term.yellow : Term.red
            func row(_ k: String, _ v: String) { Out.line(Term.dim(k.padding(toLength: 9, withPad: " ", startingAt: 0)) + v) }
            Out.line(Term.dim("\(m.model) · \(m.chip) · \(m.cores) cores · \(Fmt.size(m.memory)) · \(m.os) · up \(Fmt.duration(m.uptime))"))
            Out.line()
            row("Health", scoreStyle("\(health.score)") + "  " + health.reason)
            for t in health.tips { Out.line("         " + Term.yellow("· ") + t.text) }
            row("CPU", "\(Int(s.cpuTotal * 100))%" + Term.dim("   load \(String(format: "%.1f %.1f %.1f", s.load.0, s.load.1, s.load.2))"))
            row("Memory", "\(Fmt.size(s.memUsed)) of \(Fmt.size(s.memTotal))" + Term.dim("   swap \(Fmt.size(s.swapUsed)) of \(Fmt.size(s.swapTotal))") + (s.pressure >= 2 ? "  " + Term.yellow("under pressure") : ""))
            row("Disk", "\(Fmt.size(s.diskUsed)) of \(Fmt.size(s.diskTotal))" + Term.dim("   read \(Fmt.size(Int64(s.readBps)))/s · write \(Fmt.size(Int64(s.writeBps)))/s"))
            row("Network", "↓ \(Fmt.size(Int64(s.netDown)))/s  ↑ \(Fmt.size(Int64(s.netUp)))/s" + Term.dim(s.netInterface.map { "   \($0)" } ?? ""))
            if let b = s.battery { row("Battery", "\(Int(b.level * 100))%" + Term.dim(b.charging ? "   charging" : b.onAC ? "   on power" : "   on battery")) }
            Out.line()
            Out.line(Out.table(["MEMORY", "CPU", "PROCS", "APP"], top.map { [Out.Cell(Fmt.size($0.rss)), Out.Cell("\(Int($0.cpu))%", Term.dim), Out.Cell("\($0.pids.count)", Term.dim), Out.Cell($0.name + ($0.dev ? Term.dim("  dev") : ""))] }, right: [0, 1, 2]))
            return 0
        })
}
