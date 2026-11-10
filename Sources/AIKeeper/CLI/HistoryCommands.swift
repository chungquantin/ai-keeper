import Foundation

/// The cleanup history as text: the same year-of-squares chart the app shows, drawn with block textures.
enum HistoryCommands {
    static var all: [Command] { [history] }

    /// Weeks that fit `width` columns (two characters per week, plus the day labels).
    static func weekCount(width: Int, max cap: Int = 52) -> Int { max(8, min(cap, (width - 8) / 2)) }

    /// The grid, month labels on top and Mon/Wed/Fri on the left. `paint` gets the texture and its level.
    static func grid(_ s: CleanLog.Summary, weeks count: Int, paint: (String, Int) -> String, dim: (String) -> String) -> [String] {
        let weeks = CleanLog.weeks(count: count)
        let peak = weeks.flatMap { $0 }.compactMap { $0.flatMap { s.days[$0]?.bytes } }.max() ?? 0
        let textures = ["·", "░", "▒", "▓", "█"]
        let cal = Calendar.current
        var months = Array(repeating: " ", count: count * 2)
        var lastMonth = -1, nextFree = 0
        for (i, w) in weeks.enumerated() {
            guard let first = w.compactMap({ $0 }).first else { continue }
            let m = cal.component(.month, from: first)
            defer { lastMonth = m }
            guard m != lastMonth, i * 2 >= nextFree else { continue }
            let name = Array(first.formatted(.dateTime.month(.abbreviated)).lowercased())
            guard i * 2 + name.count <= months.count else { continue }
            for (j, ch) in name.enumerated() { months[i * 2 + j] = String(ch) }
            nextFree = i * 2 + name.count + 1
        }
        var out = ["    " + dim(months.joined())]
        let labels = ["", "mon", "", "wed", "", "fri", ""]
        for d in 0..<7 {
            var row = dim(labels[d].padding(toLength: 4, withPad: " ", startingAt: 0))
            for w in weeks {
                if let day = w[d] {
                    let lv = CleanLog.level(s.days[day]?.bytes ?? 0, peak: peak)
                    row += paint(textures[lv], lv) + " "
                } else { row += "  " }
            }
            out.append(row)
        }
        return out
    }

    static func legend(paint: (String, Int) -> String, dim: (String) -> String) -> String {
        dim("less ") + (0..<5).map { paint(["·", "░", "▒", "▓", "█"][$0], $0) }.joined(separator: " ") + dim(" more")
    }

    static func days(_ n: Int) -> String { "\(n) day\(n == 1 ? "" : "s")" }

    static let history = Command(
        name: "history", aliases: ["streak"], group: "Overview", summary: "How often you cleaned up, and how much space you got back",
        usage: ["keeper history [--weeks N] [--json]", "", "  --weeks   How many weeks to draw (default: as many as fit)"],
        valueOptions: ["weeks"],
        run: { a in
            let records = CleanLog.all()
            let s = CleanLog.summary(records)
            if a.json {
                let byDay = s.days.values.sorted { $0.day < $1.day }.map { ["date": Fmt.iso($0.day) as Any, "freed_bytes": $0.bytes, "cleanups": $0.runs] as [String: Any] }
                Out.json(["total_freed_bytes": s.totalBytes, "cleanups": s.runs, "active_days": s.activeDays, "current_streak_days": s.currentStreak,
                          "longest_streak_days": s.longestStreak, "days": byDay] as [String: Any])
                return 0
            }
            guard s.runs > 0 else {
                Out.line("Nothing cleaned yet. `keeper remove --all-safe --yes` starts the chart.")
                return 0
            }
            let weeks = a.value("weeks").flatMap(Int.init).map { max(1, min(104, $0)) } ?? weekCount(width: Term.width)
            let paint: (String, Int) -> String = { t, lv in lv == 0 ? Term.dim(t) : lv == 4 ? Term.bold(Term.amber(t)) : Term.amber(t) }
            Out.line(Term.bold(Term.amber(Fmt.size(s.totalBytes))) + Term.dim("  freed" + (s.first.map { " since " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "")))
            Out.line()
            for l in grid(s, weeks: weeks, paint: paint, dim: Term.dim) { Out.line(l) }
            Out.line()
            Out.line("    " + legend(paint: paint, dim: Term.dim))
            Out.line()
            Out.line(Term.dim("cleanups      ") + "\(s.runs) on \(days(s.activeDays))")
            Out.line(Term.dim("streak        ") + "\(days(s.currentStreak)) now, \(days(s.longestStreak)) longest")
            if let b = s.best { Out.line(Term.dim("best day      ") + Fmt.size(b.bytes) + Term.dim("  " + b.day.formatted(.dateTime.month(.abbreviated).day().year()))) }
            return 0
        })
}
