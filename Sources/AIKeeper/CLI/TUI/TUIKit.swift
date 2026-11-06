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
    static func header(_ title: String, _ w: Int) -> String {
        let left = " " + A.paint("AI Keeper", A.bold) + A.paint("  ›  ", A.gray) + title
        let right = A.paint("keeper \(CLI.version) ", A.gray)
        return left + String(repeating: " ", count: max(1, w - Ansi.width(left) - Ansi.width(right))) + right
    }

    static func footer(_ keys: [(String, String)], _ w: Int) -> String {
        " " + keys.map { A.paint($0.0, A.bold) + A.paint(" " + $0.1, A.gray) }.joined(separator: A.paint("   ", A.gray))
    }

    static func rule(_ w: Int) -> String { A.paint(String(repeating: "─", count: max(0, w)), A.gray + A.dim) }
}

enum Widget {
    /// A horizontal gauge. The filled part carries the color, the rest is a quiet track.
    static func bar(_ fraction: Double, width: Int, color: String = A.blue) -> String {
        let f = min(1, max(0, fraction.isFinite ? fraction : 0))
        let full = Int((Double(width) * f).rounded(.down))
        let partial = Int(((Double(width) * f) - Double(full)) * 8)
        let eighths = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var s = String(repeating: "█", count: full)
        if full < width, partial > 0 { s += eighths[partial] }
        let used = Ansi.width(s)
        return A.paint(s, color) + A.paint(String(repeating: "░", count: max(0, width - used)), A.gray + A.dim)
    }

    /// Stacked segments for a whole-disk map.
    static func segments(_ parts: [(Double, String)], width: Int) -> String {
        let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
        var out = "", used = 0
        for (i, p) in parts.enumerated() {
            var n = Int((p.0 / total * Double(width)).rounded())
            if i == parts.count - 1 { n = width - used }
            n = max(0, min(n, width - used))
            out += A.paint(String(repeating: "█", count: n), p.1); used += n
        }
        return out
    }

    static func spark(_ values: [Double], height: Int = 1) -> String {
        let bars = Array("▁▂▃▄▅▆▇█"), top = max(values.max() ?? 1, 0.0001)
        return values.map { String(bars[min(7, Int($0 / top * 7.999))]) }.joined()
    }

    static func chips(_ labels: [String], selected: Int) -> String {
        labels.enumerated().map { i, l in i == selected ? A.paint(" \(l) ", A.cobaltBg) : A.paint(" \(l) ", A.gray) }.joined(separator: " ")
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
