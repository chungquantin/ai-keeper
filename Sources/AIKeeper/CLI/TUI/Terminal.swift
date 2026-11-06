import Darwin
import Foundation

enum Key: Equatable {
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, esc, space, tab, backspace, ctrlC
    case char(Character)
    case none
}

/// Colors. The brand cobalt is too dark for text on a dark terminal, so text uses a lighter tint and the selection bar uses the real thing.
enum A {
    static let reset = "\u{1B}[0m"
    static let trueColor = ProcessInfo.processInfo.environment["COLORTERM"].map { $0.contains("truecolor") || $0.contains("24bit") } ?? false

    static func fg(_ r: Int, _ g: Int, _ b: Int, _ ansi256: Int) -> String { trueColor ? "\u{1B}[38;2;\(r);\(g);\(b)m" : "\u{1B}[38;5;\(ansi256)m" }
    static func bg(_ r: Int, _ g: Int, _ b: Int, _ ansi256: Int) -> String { trueColor ? "\u{1B}[48;2;\(r);\(g);\(b)m" : "\u{1B}[48;5;\(ansi256)m" }

    static var bold: String { "\u{1B}[1m" }
    static var dim: String { "\u{1B}[2m" }
    static var blue: String { fg(116, 146, 255, 111) }       // links, safe, selection marks
    static var cobaltBg: String { bg(37, 69, 245, 27) + "\u{1B}[38;5;255m" }
    static var amber: String { fg(245, 166, 36, 214) }       // reclaimable space, and nothing else
    static var red: String { fg(240, 96, 96, 203) }
    static var gray: String { fg(138, 147, 161, 245) }
    static var violet: String { fg(167, 139, 250, 141) }
    static var sky: String { fg(125, 190, 250, 117) }

    static func paint(_ s: String, _ style: String) -> String { style + s + reset }
}

enum Ansi {
    /// The number of terminal cells a string takes, ignoring color codes.
    static func width(_ s: String) -> Int {
        var n = 0, inEsc = false
        for c in s.unicodeScalars {
            if inEsc { if c == "m" { inEsc = false }; continue }
            if c == "\u{1B}" { inEsc = true; continue }
            n += 1
        }
        return n
    }

    /// Cuts to `w` cells, keeping color codes intact and ending with a reset so styles never bleed into the next cell.
    static func fit(_ s: String, _ w: Int, ellipsis: Bool = true) -> String {
        guard w > 0 else { return "" }
        if width(s) <= w { return s }
        var out = "", n = 0, inEsc = false
        let limit = ellipsis ? w - 1 : w
        for c in s.unicodeScalars {
            if inEsc { out.unicodeScalars.append(c); if c == "m" { inEsc = false }; continue }
            if c == "\u{1B}" { inEsc = true; out.unicodeScalars.append(c); continue }
            if n >= limit { break }
            out.unicodeScalars.append(c); n += 1
        }
        return out + A.reset + (ellipsis ? "…" : "")
    }

    static func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
        let t = fit(s, w), gap = max(0, w - width(t))
        return right ? String(repeating: " ", count: gap) + t : t + String(repeating: " ", count: gap)
    }
}

/// Raw terminal on the alternate screen. Always restored, including on Ctrl-C and crashes of the loop.
enum TTY {
    nonisolated(unsafe) private static var saved = termios()
    nonisolated(unsafe) private static var active = false

    static var size: (cols: Int, rows: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 { return (Int(w.ws_col), Int(w.ws_row)) }
        return (100, 32)
    }

    static func enter() {
        guard !active else { return }
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        cfmakeraw(&raw)
        raw.c_oflag |= tcflag_t(OPOST)     // keep \n handling for our own output
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")   // alternate screen, hide cursor
        active = true
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { _ in SkillScanner.cancelAll(); TTY.leave(); exit(130) } }
    }

    static func leave() {
        guard active else { return }
        write("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        active = false
    }

    static func write(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = Darwin.write(STDOUT_FILENO, base + off, raw.count - off)
                if n <= 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
                off += n
            }
        }
    }

    nonisolated(unsafe) private static var pending: [Key] = []

    /// Waits up to `timeout` seconds for a key. `.none` means nothing arrived (time to refresh live data).
    /// One read can carry several keys (fast typing, paste, or a slow redraw), so all of them are parsed and queued.
    static func readKey(timeout: Double) -> Key {
        if !pending.isEmpty { return pending.removeFirst() }
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, Int32(timeout * 1000)) > 0 else { return .none }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(STDIN_FILENO, &buf, 256)
        guard n > 0 else { return .none }
        let b = Array(buf.prefix(n))
        pending = parse(b)
        return pending.isEmpty ? .none : pending.removeFirst()
    }

    static func parse(_ b: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x1B {
                if i + 2 < b.count, b[i + 1] == 0x5B || b[i + 1] == 0x4F {
                    let code = b[i + 2]
                    var len = 3
                    switch code {
                    case 0x41: keys.append(.up)
                    case 0x42: keys.append(.down)
                    case 0x43: keys.append(.right)
                    case 0x44: keys.append(.left)
                    case 0x48: keys.append(.home)
                    case 0x46: keys.append(.end)
                    case 0x35, 0x36: len = 4; keys.append(code == 0x35 ? .pageUp : .pageDown)   // ESC [ 5 ~
                    default: len = 3
                    }
                    i += len
                } else { keys.append(.esc); i += 1 }
                continue
            }
            switch c {
            case 0x03: keys.append(.ctrlC); i += 1
            case 0x0D, 0x0A: keys.append(.enter); i += 1
            case 0x20: keys.append(.space); i += 1
            case 0x09: keys.append(.tab); i += 1
            case 0x7F, 0x08: keys.append(.backspace); i += 1
            default:
                let len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1
                let end = min(b.count, i + len)
                if let ch = String(bytes: b[i..<end], encoding: .utf8)?.first { keys.append(.char(ch)) }
                i = end
            }
        }
        return keys
    }
}

