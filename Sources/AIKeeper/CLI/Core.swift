import Darwin
import Foundation

// MARK: - Arguments

/// Parsed command line: positional words, boolean flags and `--name value` / `--name=value` options.
/// Short flags: -y (--yes), -h (--help), -j (--json).
struct Args {
    var positional: [String] = []
    private var flags: Set<String> = []
    private var options: [String: String] = [:]
    private(set) var unknown: [String] = []

    /// `valueOptions` are the option names that take a value; every other `--name` is a flag.
    init(_ raw: [String], valueOptions: Set<String> = []) {
        let short = ["y": "yes", "h": "help", "j": "json"]
        var i = 0
        var onlyPositional = false
        while i < raw.count {
            let a = raw[i]
            i += 1
            if onlyPositional || !a.hasPrefix("-") || a == "-" { positional.append(a); continue }
            if a == "--" { onlyPositional = true; continue }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") { options[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
                else if valueOptions.contains(body), i < raw.count { options[body] = raw[i]; i += 1 }
                else { flags.insert(body) }
            } else {
                for c in a.dropFirst() {
                    if let long = short[String(c)] { flags.insert(long) } else { unknown.append("-\(c)") }
                }
            }
        }
    }

    var flagNames: Set<String> { flags }
    var optionNames: Set<String> { Set(options.keys) }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { options[name] }
    func int(_ name: String) -> Int? { options[name].flatMap(Int.init) }
    var json: Bool { flag("json") }
    var yes: Bool { flag("yes") }
}

// MARK: - Terminal output

enum Term {
    static let outTTY = isatty(STDOUT_FILENO) != 0
    static let errTTY = isatty(STDERR_FILENO) != 0
    nonisolated(unsafe) static var colorOverride: Bool?
    static var color: Bool { colorOverride ?? (outTTY && ProcessInfo.processInfo.environment["NO_COLOR"] == nil) }

    static var width: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return Int(w.ws_col) }
        return 100
    }

    private static func sgr(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { sgr("1", s) }
    static func dim(_ s: String) -> String { sgr("2", s) }
    static func red(_ s: String) -> String { sgr("31", s) }
    static func yellow(_ s: String) -> String { sgr("33", s) }
    static func blue(_ s: String) -> String { sgr("34", s) }
}

enum Out {
    static func line(_ s: String = "") { print(s) }
    /// Progress, hints and warnings go to stderr so `--json` and pipes stay clean.
    static func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    static func fail(_ s: String) { note(Term.red("keeper: ") + s) }

    static func json(_ o: Any) {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        print(String(decoding: d, as: UTF8.self))
    }

    /// Overwrites the current stderr line (when it is a terminal), otherwise stays quiet.
    /// The interactive mode sets this to show progress on its own bottom line instead of writing to stderr.
    nonisolated(unsafe) static var statusHook: ((String) -> Void)?

    static func status(_ s: String) {
        if let hook = statusHook { hook(s); return }
        guard Term.errTTY else { return }
        let clipped = s.count > Term.width - 1 ? String(s.prefix(Term.width - 2)) + "…" : s
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(clipped)".utf8))
    }
    static func endStatus() { if statusHook == nil, Term.errTTY { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) } }

    struct Cell {
        var text: String
        var style: (String) -> String = { $0 }
        init(_ text: String, _ style: @escaping (String) -> String = { $0 }) { self.text = text; self.style = style }
    }

    /// Aligned columns. The last column takes the remaining width and is truncated.
    static func table(_ headers: [String], _ rows: [[Cell]], right: Set<Int> = []) -> String {
        guard !rows.isEmpty else { return "" }
        var widths = headers.map { $0.count }
        for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.text.count) } }
        let last = widths.count - 1
        let gap = 2
        let fixed = widths.dropLast().reduce(0, +) + gap * last
        let room = max(10, Term.width - fixed)
        widths[last] = min(widths[last], room)
        func pad(_ s: String, _ w: Int, rightAlign: Bool) -> String {
            let t = s.count > w ? String(s.prefix(max(0, w - 1))) + "…" : s
            let fill = String(repeating: " ", count: max(0, w - t.count))
            return rightAlign ? fill + t : t + fill
        }
        var lines = [Term.dim(headers.enumerated().map { pad($1, widths[$0], rightAlign: right.contains($0)) }.joined(separator: String(repeating: " ", count: gap)))]
        for r in rows {
            let cells = r.enumerated().map { i, c -> String in
                let padded = pad(c.text, widths[min(i, last)], rightAlign: right.contains(i))
                return i == last ? c.style(padded.trimmingCharacters(in: .whitespaces)) : c.style(padded)
            }
            lines.append(cells.joined(separator: String(repeating: " ", count: gap)))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Formatting

enum Fmt {
    /// Decimal units, one decimal for GB and up, like the app.
    static func size(_ b: Int64) -> String {
        let v = Double(b)
        if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
        return "\(b) B"
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "-" }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        switch s {
        case ..<90: return "just now"
        case ..<3600: return "\(s / 60) min ago"
        case ..<86_400: return "\(s / 3600) hr ago"
        case ..<(86_400 * 2): return "1 day ago"
        case ..<(86_400 * 60): return "\(s / 86_400) days ago"
        default: return "\(s / (86_400 * 30)) mo ago"
        }
    }

    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func iso(_ d: Date?) -> String? { d.map { ISO8601DateFormatter().string(from: $0) } }
    static func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 86_400 { return "\(s / 86_400)d \(s % 86_400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(max(1, s / 60))m"
    }
}

// MARK: - Commands

struct Command {
    let name: String
    var aliases: [String] = []
    let group: String
    let summary: String
    let usage: [String]
    var valueOptions: Set<String> = []
    /// Every flag the command understands (besides --json, --yes, --help). Anything else is a usage error.
    var flags: Set<String> = []
    /// Returns the process exit code: 0 ok, 1 failed, 2 wrong usage.
    let run: (Args) -> Int32
}

/// Where the running binary really is. `Bundle.main` is blind when the command is a symlink (`keeper` on your PATH),
/// so the version and the app's own files are found from the resolved path instead.
enum Runtime {
    static let executable: String = {
        var size = UInt32(MAXPATHLEN)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return Bundle.main.executablePath ?? "" }
        guard let real = realpath(buf, nil) else { return String(cString: buf) }
        defer { free(real) }
        return String(cString: real)
    }()

    /// `AI Keeper.app/Contents/Info.plist` next to the real binary, when it lives in an app bundle.
    static var infoPlist: [String: Any]? {
        let url = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: url) as? [String: Any]
    }
}

enum CLI {
    static let version: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        ?? (Runtime.infoPlist?["CFBundleShortVersionString"] as? String) ?? "dev"

    static var all: [Command] {
        StatusCommands.all + WorkspaceCommands.all + CleanCommands.all + AgentCommands.all + UsageCommands.all
            + DiskCommands.all + SystemCommands.all + SafetyCommands.all + SetupCommands.all
    }

    /// The same binary is the app, `keeper` and `aikeeper`. Run by the command names it is linked as, it never opens the window.
    static var invokedAsCLI: Bool {
        let n = ((CommandLine.arguments.first ?? "") as NSString).lastPathComponent.lowercased()
        return n == "keeper" || n == "aikeeper"
    }

    /// True when the arguments were a CLI invocation (already handled; the caller should exit with `exitCode`).
    static func handle(_ argv: [String], exitCode: inout Int32) -> Bool {
        let args = Array(argv.dropFirst())
        if args.isEmpty, invokedAsCLI, TUILauncher.interactive { exitCode = TUILauncher.run(); return true }
        let wantsHelp = args.isEmpty ? invokedAsCLI : ["help", "--help", "-h"].contains(args[0])
        if wantsHelp {
            if args.count > 1, let c = find(args[1]) { printHelp(c); exitCode = 0 } else { printOverview(); exitCode = 0 }
            return true
        }
        if args.isEmpty { return false }
        if args[0] == "--version" || args[0] == "-V" || args[0] == "version" { print("keeper \(version)"); exitCode = 0; return true }
        guard let cmd = find(args[0]) else {
            guard invokedAsCLI else { return false }   // the app binary also gets macOS launch arguments
            Out.fail("unknown command '\(args[0])'. Run `keeper help` to see what is available.")
            exitCode = 2; return true
        }
        var rest = Array(args.dropFirst())
        if rest.contains("--no-color") { Term.colorOverride = false; rest.removeAll { $0 == "--no-color" } }
        let parsed = Args(rest, valueOptions: cmd.valueOptions)
        if parsed.flag("help") { printHelp(cmd); exitCode = 0; return true }
        if let bad = parsed.unknown.first { Out.fail("unknown option \(bad). See `keeper help \(cmd.name)`."); exitCode = 2; return true }
        let allowedFlags = cmd.flags.union(["json", "yes", "help"]), allowedOptions = cmd.valueOptions
        if let bad = parsed.flagNames.first(where: { !allowedFlags.contains($0) && !allowedOptions.contains($0) }) ?? parsed.optionNames.first(where: { !allowedOptions.contains($0) }) {
            Out.fail("unknown option --\(bad). See `keeper help \(cmd.name)`."); exitCode = 2; return true
        }
        if let missing = parsed.flagNames.first(where: { allowedOptions.contains($0) }) { Out.fail("--\(missing) needs a value. See `keeper help \(cmd.name)`."); exitCode = 2; return true }
        exitCode = cmd.run(parsed)
        return true
    }

    static func find(_ name: String) -> Command? { all.first { $0.name == name || $0.aliases.contains(name) } }

    static func printOverview() {
        var s = Term.bold("keeper") + "  Clean up after your coding agents. Everything the AI Keeper app does, from the terminal.\n"
        let groups = ["Overview", "Workspaces", "Clean up", "Agents and usage", "Disk and system", "Safety nets", "Setup"]
        for g in groups {
            let cmds = all.filter { $0.group == g }
            guard !cmds.isEmpty else { continue }
            s += "\n" + Term.bold(g) + "\n"
            for c in cmds { s += "  " + c.name.padding(toLength: 12, withPad: " ", startingAt: 0) + c.summary + "\n" }
        }
        s += """

        Every command takes --json. Anything that deletes is a dry run until you add --yes.
        Run `keeper help <command>` for details.
        """
        print(s)
    }

    static func printHelp(_ c: Command) {
        var s = Term.bold("keeper \(c.name)") + "  " + c.summary + "\n\n"
        s += c.usage.map { "  " + $0 }.joined(separator: "\n")
        s += "\n\n  --json        Machine-readable output\n  --no-color    No colors\n  -h, --help    This help"
        if !c.aliases.isEmpty { s += "\n\n  Also: " + c.aliases.joined(separator: ", ") }
        print(s)
    }
}
