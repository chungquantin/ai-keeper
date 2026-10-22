import Foundation

/// Command-line and MCP entry points. The same binary serves the GUI, `aikeeper <command>`, and `aikeeper mcp`.
enum Headless {
    static let commands: Set<String> = ["status", "workspaces", "clean-artifacts", "mcp", "help"]

    /// Returns true if the arguments were a headless command (already handled; caller should exit).
    static func handle(_ args: [String]) -> Bool {
        guard args.count > 1, commands.contains(args[1]) else { return false }
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "mcp": MCPServer.run()
        case "status": print(Tools.status(json: rest.contains("--json")))
        case "workspaces": print(Tools.workspaces(deprecatedOnly: rest.contains("--deprecated"), limit: 50, json: rest.contains("--json")))
        case "clean-artifacts":
            guard let path = rest.first(where: { !$0.hasPrefix("--") }) else { print("usage: aikeeper clean-artifacts <workspace-path> [--yes]"); return true }
            print(Tools.cleanArtifacts(path: path, confirm: rest.contains("--yes")).text)
        default:
            print("""
            aikeeper status [--json]                      Disk, agents and spend at a glance
            aikeeper workspaces [--deprecated] [--json]   Workspaces from the last scan, biggest first
            aikeeper clean-artifacts <path> [--yes]       Delete build folders (target, node_modules…) of one workspace. Dry run without --yes
            aikeeper mcp                                  Run as an MCP server over stdio

            Add to Claude Code:  claude mcp add aikeeper -- \(Bundle.main.executablePath ?? "aikeeper") mcp
            """)
        }
        return true
    }
}

/// The shared implementations behind the CLI and the MCP tools. Work from the saved scan so they answer instantly.
enum Tools {
    /// One-decimal numbers that serialize cleanly ("659.9", not "659.89999999999998").
    static func gb(_ b: Int64) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", Double(b) / 1e9)) }
    static func usd(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", v)) }

    static func diskInfo() -> DiskInfo {
        var d = DiskInfo()
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            let important = v.volumeAvailableCapacityForImportantUsage ?? 0
            d = DiskInfo(total: Int64(v.volumeTotalCapacity ?? 0), available: important, purgeable: max(0, important - Int64(v.volumeAvailableCapacity ?? 0)))
        }
        return d
    }

    static func entries() -> [Entry] { Persist.load([Entry].self, "scan.json") ?? [] }
    static func scanAgeMinutes() -> Int? {
        let url = Persist.dir.appendingPathComponent("scan.json")
        guard let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else { return nil }
        return Int(Date().timeIntervalSince(m) / 60)
    }

    static func diskStatus() -> [String: Any] {
        let d = diskInfo()
        let floor = UserDefaults.standard.number("guard.floorGB", default: 50)
        return ["free_gb": gb(d.available), "used_gb": gb(d.used), "total_gb": gb(d.total), "purgeable_gb": gb(d.purgeable),
                "low": Double(d.available) / 1e9 < floor, "alert_floor_gb": floor]
    }

    static func agents() -> [[String: Any]] {
        SessionPeek.assign(AgentScanner.scan()).filter { $0.kind != .mcp }.map {
            var o: [String: Any] = ["tool": $0.kind.rawValue, "pid": Int($0.pid), "state": $0.state.rawValue, "cwd": $0.cwd ?? ""]
            if let c = $0.cost { o["session_cost_usd"] = usd(c) }
            if let t = $0.title { o["task"] = t }
            return o
        }
    }

    static func workspaceList(deprecatedOnly: Bool, limit: Int) -> [[String: Any]] {
        entries().filter { $0.kind == .workspace || $0.kind == .repo }
            .filter { !deprecatedOnly || $0.verdict == .deprecated }
            .filter { ($0.size ?? 0) > 0 }
            .sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(limit).map { e in
                var o: [String: Any] = ["name": e.name, "repo": e.repoName, "path": e.path, "size_gb": gb(e.size ?? 0),
                                        "rebuildable_gb": gb(e.artifactBytes), "status": e.statusPill.0,
                                        "main_checkout": e.kind == .repo]
                if let b = e.branch { o["branch"] = b }
                if let l = e.lastActivity { o["last_active"] = ISO8601DateFormatter().string(from: l) }
                return o
            }
    }

    static func usage(days: Int) -> [String: Any] {
        let d = UsageParser.load()
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: .now))!
        var out: [String: Any] = ["days": days]
        for tool in AgentTool.allCases {
            let r = d.rows.filter { $0.agent == tool && $0.day >= cutoff }
            out[tool.rawValue.lowercased()] = ["cost_usd": usd(r.reduce(0) { $0 + $1.cost }), "tokens": r.reduce(0) { $0 + $1.tokens }]
        }
        let today = d.rows.filter { Calendar.current.isDateInToday($0.day) }
        out["today_cost_usd"] = usd(today.reduce(0) { $0 + $1.cost })
        out["note"] = "Estimated at API list prices"
        return out
    }

    /// Deletes only git-ignored build folders that the last scan attributed to this exact workspace.
    static func cleanArtifacts(path: String, confirm: Bool) -> (text: String, isError: Bool) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let e = entries().first(where: { ($0.kind == .workspace || $0.kind == .repo) && $0.path == root }) else {
            return (json(["error": "Not a known workspace. Run a scan in AI Keeper first, and pass the workspace root path.", "path": root]), true)
        }
        let targets = e.artifacts.filter { a in
            a.path.hasPrefix(root + "/") && Enricher.artifactNames.contains(a.label) && FileManager.default.fileExists(atPath: a.path)
                && ((try? FileManager.default.destinationOfSymbolicLink(atPath: a.path)) == nil)
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.bytes }
        let list = targets.map { ["path": $0.path, "size_gb": gb($0.bytes)] as [String: Any] }
        guard confirm else {
            return (json(["dry_run": true, "would_free_gb": gb(total), "folders": list, "hint": "Call again with confirm=true (or --yes) to delete."]), false)
        }
        // The scan may be hours old. Re-check what matters right before deleting: no agent is working in there, and each
        // folder is still git-ignored (so it can't be source), and still really inside the workspace.
        let busy = AgentScanner.scan().contains { $0.kind != .mcp && ($0.cwd == root || ($0.cwd?.hasPrefix(root + "/") ?? false)) }
        guard !busy else { return (json(["error": "An agent is running in this workspace. Try again when it has finished.", "path": root]), true) }
        let safe = targets.filter { t in
            URL(fileURLWithPath: t.path).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/")
                && Shell.git(root, ["check-ignore", "-q", "--", t.path]).status == 0
        }
        let progress = CleanProgress()
        for t in safe { FastDelete.remove(t.path, progress: progress) }
        log("clean-artifacts \(root) freed \(progress.freed)")
        return (json(["freed_gb": gb(progress.freed), "folders_removed": safe.count, "error": progress.firstError as Any]), progress.firstError != nil)
    }

    static func log(_ line: String) {
        let url = Persist.dir.appendingPathComponent("agent-actions.log")
        let entry = "\(ISO8601DateFormatter().string(from: .now)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func json(_ o: Any) -> String {
        let clean = (o as? [String: Any]).map { $0.filter { !($0.value is NSNull) && String(describing: $0.value) != "nil" } } ?? o
        let d = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys])
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Human-readable CLI output

    static func status(json asJSON: Bool) -> String {
        let d = diskStatus(), ag = agents()
        let reclaim = entries().filter { $0.kind == .workspace || $0.kind == .repo }.reduce(Int64(0)) { $0 + $1.artifactBytes }
        if asJSON { return json(["disk": d, "agents": ag, "rebuildable_gb": gb(reclaim), "scan_age_minutes": scanAgeMinutes() as Any]) }
        var s = "Disk       \(d["free_gb"]!) GB free of \(d["total_gb"]!) GB\(d["low"] as? Bool == true ? "  (LOW)" : "")\n"
        s += "Agents     \(ag.count) running, \(ag.filter { $0["state"] as? String == "needsInput" }.count) need you\n"
        s += "Rebuildable \(gb(reclaim)) GB in build folders"
        s += scanAgeMinutes().map { " (scan \($0) min old)" } ?? " (no scan yet: open AI Keeper once)"
        return s
    }

    static func workspaces(deprecatedOnly: Bool, limit: Int, json asJSON: Bool) -> String {
        let list = workspaceList(deprecatedOnly: deprecatedOnly, limit: limit)
        if asJSON { return (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]" }
        if list.isEmpty { return "No workspaces in the last scan. Open AI Keeper to scan." }
        return list.map { String(format: "%8.1f GB  %-14@  %@  (%@)", ($0["size_gb"] as! NSDecimalNumber).doubleValue, $0["status"] as! String, $0["path"] as! String, $0["repo"] as! String) }.joined(separator: "\n")
    }
}

/// Minimal MCP server: newline-delimited JSON-RPC 2.0 on stdin/stdout.
enum MCPServer {
    static let tools: [[String: Any]] = [
        tool("disk_status", "Free, used and purgeable disk space, and whether free space is below the user's alert floor. Check before large builds.", [:]),
        tool("list_workspaces", "Git worktrees and main checkouts from the last scan with size, rebuildable build-folder size and status (Safe to remove, Active, Uncommitted…).",
             ["deprecated_only": ["type": "boolean", "description": "Only workspaces judged deprecated"], "limit": ["type": "integer", "description": "Max results, default 20"]]),
        tool("running_agents", "Coding agents running on this machine (Claude Code, Codex…) with state: working, needsInput, idle.", [:]),
        tool("ai_usage", "Estimated AI spend and tokens per tool over the last N days, plus today's cost.", ["days": ["type": "integer", "description": "Default 7"]]),
        tool("clean_artifacts", "Delete the git-ignored build folders (target, node_modules, .venv…) of ONE workspace. Dry run unless confirm is true. Never touches source files. Use when free space is low or after finishing work in a worktree.",
             ["path": ["type": "string", "description": "Workspace root path, as returned by list_workspaces"], "confirm": ["type": "boolean", "description": "true to actually delete; default false (dry run)"]], required: ["path"]),
    ]

    static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = req["id"] else { continue }   // notifications carry no id and need no reply
            let method = req["method"] as? String ?? ""
            let params = req["params"] as? [String: Any] ?? [:]
            var msg: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                msg["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                                 "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "ai-keeper", "version": "0.2.0"]]
            case "tools/list": msg["result"] = ["tools": tools]
            case "tools/call":
                let (text, isErr) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                msg["result"] = ["content": [["type": "text", "text": text]], "isError": isErr]
            case "ping": msg["result"] = [String: Any]()
            default: msg["error"] = ["code": -32601, "message": "Method not found: \(method)"]
            }
            if let out = try? JSONSerialization.data(withJSONObject: msg) {
                FileHandle.standardOutput.write(out + Data("\n".utf8))
            }
        }
        exit(0)
    }

    static func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        switch name {
        case "disk_status": return (Tools.json(Tools.diskStatus()), false)
        case "running_agents": return (Tools.json(["agents": Tools.agents()]), false)
        case "list_workspaces":
            let list = Tools.workspaceList(deprecatedOnly: a["deprecated_only"] as? Bool ?? false, limit: a["limit"] as? Int ?? 20)
            return (Tools.json(["workspaces": list, "scan_age_minutes": Tools.scanAgeMinutes() as Any]), false)
        case "ai_usage": return (Tools.json(Tools.usage(days: max(1, a["days"] as? Int ?? 7))), false)
        case "clean_artifacts":
            guard let p = a["path"] as? String else { return ("{\"error\":\"path is required\"}", true) }
            let r = Tools.cleanArtifacts(path: p, confirm: a["confirm"] as? Bool ?? false)
            return (r.text, r.isError)
        default: return ("{\"error\":\"Unknown tool\"}", true)
        }
    }
}

enum CLIInstaller {
    static var binary: String { Bundle.main.executablePath ?? "\(home)/Applications/AIKeeper.app/Contents/MacOS/AIKeeper" }
    static var linkPath: String { "\(home)/.local/bin/aikeeper" }
    static var mcpCommand: String { "claude mcp add aikeeper -- \(linkPath) mcp" }

    /// Symlinks the app binary into ~/.local/bin (user-writable, no admin prompt).
    static func install() -> String {
        let dir = (linkPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: linkPath)
        do { try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: binary) }
        catch { return "Couldn't create the link: \(error.localizedDescription)" }
        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").contains(".local/bin")
        return onPath ? "Installed. Try: aikeeper status" : "Installed at ~/.local/bin/aikeeper. Add ~/.local/bin to your PATH to run it by name."
    }
}
