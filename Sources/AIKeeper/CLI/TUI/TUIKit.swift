import Foundation

protocol Screen: AnyObject {
    var title: String { get }
    /// Seconds between live refreshes; 0 for a screen that only changes on a key.
    var tickInterval: Double { get }
    func render(_ w: Int, _ h: Int) -> [String]
    func handle(_ key: Key, _ ui: TUI)
    func tick(_ ui: TUI)
    var keys: [(String, String)] { get }
}

extension Screen {
    var tickInterval: Double { 0 }
    func tick(_ ui: TUI) {}
}

/// The full-screen app: a stack of screens, redrawn after every key and on a timer for live ones.
final class TUI {
    var stack: [Screen] = []
    private var toast: (text: String, until: Date)?
    var quit = false

    func push(_ s: Screen) { stack.append(s) }
    func pop() { if stack.count > 1 { stack.removeLast() } else { quit = true } }
    func flash(_ text: String, seconds: Double = 3) { toast = (text, Date().addingTimeInterval(seconds)) }

    /// Draws one frame now (used while a long action runs and the key loop is busy).
    func draw() {
        guard let screen = stack.last else { return }
        let (w, h) = TTY.size
        TTY.write(Self.frame(screen.render(w, h - 2), screen: screen, toast: toast.flatMap { $0.until > Date() ? $0.text : nil }, w: w, h: h))
    }

    static func frame(_ body: [String], screen: Screen, toast: String?, w: Int, h: Int) -> String {
        var lines = [Chrome.header(screen.title, w)] + body.prefix(max(0, h - 2))
        while lines.count < h - 1 { lines.append("") }
        lines.append(toast.map { " " + A.paint($0, A.amber) } ?? Chrome.footer(screen.keys, w))
        return "\u{1B}[H" + lines.prefix(h).map { Ansi.fit($0, w, ellipsis: false) + A.reset + "\u{1B}[K" }.joined(separator: "\r\n")
    }

    func run() {
        TTY.enter()
        defer { SkillScanner.cancelAll(); TTY.leave() }
        draw()
        var lastTick = Date(), lastSize = TTY.size
        while !quit, let screen = stack.last {
            let wait = screen.tickInterval > 0 ? min(0.25, screen.tickInterval) : 0.5
            let key = TTY.readKey(timeout: wait)
            if key == .ctrlC { break }
            var dirty = false
            if key != .none { screen.handle(key, self); dirty = true }
            if let s = stack.last, s.tickInterval > 0, Date().timeIntervalSince(lastTick) >= s.tickInterval { s.tick(self); lastTick = Date(); dirty = true }
            let size = TTY.size
            if size != lastSize { lastSize = size; dirty = true; TTY.write("\u{1B}[2J") }
            if toast != nil, toast!.until <= Date() { toast = nil; dirty = true }
            if dirty { draw() }
        }
    }
}

enum Chrome {
    nonisolated(unsafe) private static var cachedDisk: (at: Date, info: DiskInfo)?

    private static func disk() -> DiskInfo {
        if let c = cachedDisk, Date().timeIntervalSince(c.at) < 5 { return c.info }
        let d = Tools.diskInfo(); cachedDisk = (Date(), d); return d
    }

    /// `keeper / workspaces` on the left, and on every screen the number that matters most: how much disk is free.
    static func header(_ title: String, _ w: Int) -> String {
        let path = title.lowercased().replacingOccurrences(of: "  ›  ", with: " / ")
        let left = " " + A.paint(" keeper ", A.cobaltBg + A.bold) + A.paint("  " + (path == "overview" ? "" : path), A.gray)
        let d = disk()
        let used = d.total > 0 ? Double(d.total - d.available) / Double(d.total) : 0
        let low = d.total > 0 && Double(d.available) / Double(d.total) < 0.1
        let right = A.paint(Fmt.size(d.available), low ? A.red + A.bold : A.bold) + A.paint(" free ", A.gray) + Widget.bar(used, width: 10, color: low ? A.red : A.blue) + " "
        return left + String(repeating: " ", count: max(1, w - Ansi.width(left) - Ansi.width(right))) + right
    }

    static func footer(_ keys: [(String, String)], _ w: Int) -> String {
        " " + keys.map { A.paint($0.0, A.blue) + A.paint(" " + $0.1, A.gray) }.joined(separator: "   ")
    }

    static func rule(_ w: Int) -> String { A.paint(String(repeating: "─", count: max(0, w)), A.gray + A.dim) }

    /// `── Biggest folders ─────────`: a rule that names the section it opens.
    static func titled(_ title: String, _ w: Int) -> String {
        let label = " " + title + " "
        return A.paint("──", A.gray + A.dim) + A.paint(label, A.bold) + A.paint(String(repeating: "─", count: max(0, w - Ansi.width(label) - 2)), A.gray + A.dim)
    }
}

enum Widget {
    /// A gauge drawn as line weight: `━━━━────`. The heavy part is the amount, the light part is what is left.
    static func bar(_ fraction: Double, width: Int, color: String = A.blue) -> String {
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        let full = f > 0 ? max(1, Int((Double(width) * f).rounded())) : 0
        return A.paint(String(repeating: "━", count: min(full, width)), color) + A.paint(String(repeating: "─", count: max(0, width - full)), A.gray + A.dim)
    }

    /// Halftone density, so categories differ by texture rather than by hue.
    static let textures = ["█", "▓", "▒", "░", "·"]
    static func texture(_ i: Int) -> String { textures[min(i, textures.count - 1)] }

    static func segments(_ parts: [(Double, String)], width: Int) -> String {
        let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
        var out = "", used = 0
        for (i, p) in parts.enumerated() {
            var n = Int((p.0 / total * Double(width)).rounded())
            if i == parts.count - 1 { n = width - used }
            n = max(0, min(n, width - used))
            out += String(repeating: texture(i), count: n); used += n
        }
        return out
    }

    static func spark(_ values: [Double], height: Int = 1) -> String {
        let bars = Array("▁▂▃▄▅▆▇█"), top = max(values.max() ?? 1, 0.0001)
        return values.map { String(bars[min(7, Int($0 / top * 7.999))]) }.joined()
    }

    /// Filters as plain words: the active one is underlined, the rest recede.
    static func chips(_ labels: [String], selected: Int) -> String {
        labels.enumerated().map { i, l in i == selected ? A.paint(l, A.bold + A.underline) : A.paint(l, A.gray) }.joined(separator: "    ")
    }

    /// A row under the cursor: the faint band holds its colors, because every reset re-applies it.
    static func band(_ line: String, _ width: Int) -> String {
        let fitted = Ansi.pad(line, width)
        return A.band + fitted.replacingOccurrences(of: A.reset, with: A.reset + A.band) + A.reset
    }

    // A compact 3-row numeral from half blocks: each glyph is 3 wide by 6 pixels tall.
    private static let glyphs: [Character: [String]] = [
        "0": ["###", "#.#", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "#..", "###"], "3": ["###", "..#", ".##", "..#", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#", "..#"], "5": ["###", "#..", "###", "..#", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "#.#", "###"], "7": ["###", "..#", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "..#", "###"],
        ".": ["...", "...", "...", "...", "...", ".#."], " ": ["...", "...", "...", "...", "...", "..."],
    ]

    static func bigNumber(_ text: String) -> [String] {
        var rows = ["", "", ""]
        for ch in text {
            let g = glyphs[ch] ?? glyphs[" "]!
            for r in 0..<3 {
                var cells = ""
                for x in 0..<3 {
                    let top = Array(g[r * 2])[x] == "#", bottom = Array(g[r * 2 + 1])[x] == "#"
                    cells += top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " "
                }
                rows[r] += cells + " "
            }
        }
        return rows
    }
}

/// Cursor and scroll position for a list.
struct ListState {
    var cursor = 0
    var offset = 0

    mutating func move(_ delta: Int, count: Int) { cursor = count == 0 ? 0 : min(max(0, cursor + delta), count - 1) }
    mutating func clamp(count: Int, visible: Int) {
        cursor = count == 0 ? 0 : min(max(0, cursor), count - 1)
        if cursor < offset { offset = cursor }
        if cursor >= offset + visible { offset = cursor - visible + 1 }
        offset = max(0, min(offset, max(0, count - visible)))
    }
}
