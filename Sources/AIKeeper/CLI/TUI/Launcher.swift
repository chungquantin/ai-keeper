import Foundation

enum TUILauncher {
    static var interactive: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

    static func run(start: Screen? = nil) -> Int32 {
        guard interactive else { Out.fail("the interactive mode needs a terminal. Run `keeper help` for the commands that work in scripts."); return 1 }
        let ui = TUI()
        ui.push(start ?? HomeScreen())
        ui.run()
        return 0
    }

    /// One frame of a screen as plain text with colors, for documentation and tests. Nothing is changed on disk.
    static func snapshot(_ name: String, cols: Int, rows: Int, preselect: Int) -> String? {
        let screen: Screen
        switch name {
        case "home": screen = HomeScreen()
        case "workspaces": screen = WorkspacesScreen(preselect: preselect)
        case "leftovers": screen = LeftoversScreen()
        case "confirm":
            let chosen = Library.entries().filter { $0.kind == .workspace && $0.verdict == .deprecated && $0.safety == .safe }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(max(1, preselect))
            screen = ConfirmScreen(mode: .removeWorkspaces, chosen: Array(chosen), allowDanger: false, done: {})
        case "progress":
            let p = ProgressScreen()
            p.progress = Library.Progress(index: 2, count: 5, name: "feat-search-index", freed: 6_100_000_000, total: 11_400_000_000, detail: "\(home)/Developer/api-server/.claude/worktrees/feat-search-index/target/debug/deps")
            screen = p
        case "result":
            var o = Library.Outcome(); o.freed = 11_400_000_000; o.done = Array(Library.entries().prefix(5))
            screen = ResultScreen(mode: .removeWorkspaces, outcome: o, count: 5, onClose: {})
        case "agents": screen = AgentsScreen()
        case "system": screen = SystemScreen()
        case "usage": screen = UsageScreen()
        case "disk": screen = DiskScreen()
        case "vault": screen = VaultScreen()
        default: return nil
        }
        let body = screen.render(cols, rows - 2)
        let frame = TUI.frame(body, screen: screen, toast: nil, w: cols, h: rows)
        return frame.replacingOccurrences(of: "\u{1B}[H", with: "").replacingOccurrences(of: "\u{1B}[K", with: "").replacingOccurrences(of: "\r\n", with: "\n")
    }
}

extension StatusCommands {
    static let ui = Command(
        name: "ui", aliases: ["tui", "dashboard", "interactive"], group: "Overview", summary: "Open the interactive dashboard (also what plain `keeper` does in a terminal)",
        usage: ["keeper ui", "keeper", "", "  Arrow keys or j/k to move, enter to open, space to select, esc to go back, q to quit.",
                "  Every screen shows its keys on the bottom line.", "",
                "  keeper ui --snapshot <screen> [--size 120x34] [--select N]   Print one frame and exit (for docs and tests)",
                "  screens: home workspaces leftovers confirm progress result agents system usage disk vault"],
        valueOptions: ["snapshot", "size", "select"],
        run: { a in
            if let name = a.value("snapshot") {
                let dims = (a.value("size") ?? "120x34").split(separator: "x").compactMap { Int($0) }
                guard dims.count == 2, let frame = TUILauncher.snapshot(name, cols: dims[0], rows: dims[1], preselect: a.int("select") ?? 0) else { Out.fail("unknown screen or size. See `keeper help ui`."); return 2 }
                print(frame); return 0
            }
            return TUILauncher.run()
        })
}
