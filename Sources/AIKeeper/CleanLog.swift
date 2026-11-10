import Foundation

/// One finished cleanup: when, how much space it gave back and how many items it removed.
struct CleanRecord: Codable, Equatable {
    var date: Date
    var bytes: Int64
    var items: Int
    var kind: String        // "workspaces", "build folders", "folder", "duplicates"
}

/// The history behind the contribution chart. Stored in `cleanups.json`; shared by the app and the `keeper` command.
enum CleanLog {
    private static let file = "cleanups.json"
    private static let lock = NSLock()

    static func all() -> [CleanRecord] {
        lock.lock(); defer { lock.unlock() }
        if Demo.enabled { return demo() }
        return Persist.load([CleanRecord].self, file) ?? []
    }

    /// Cleanups that freed nothing are not worth a square.
    static func record(bytes: Int64, items: Int, kind: String, date: Date = Date()) {
        guard bytes > 0, !Demo.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        var list = Persist.load([CleanRecord].self, file) ?? []
        list.append(CleanRecord(date: date, bytes: bytes, items: items, kind: kind))
        Persist.save(list, file)
    }

    // MARK: Numbers

    struct Day: Equatable { var day: Date; var bytes: Int64; var runs: Int }

    struct Summary {
        var totalBytes: Int64
        var runs: Int
        var activeDays: Int
        var currentStreak: Int      // consecutive days up to today (or yesterday) with a cleanup
        var longestStreak: Int
        var first: Date?
        var best: Day?
        var days: [Date: Day]
    }

    static func summary(_ records: [CleanRecord], calendar: Calendar = .current, now: Date = Date()) -> Summary {
        var days: [Date: Day] = [:]
        for r in records {
            let d = calendar.startOfDay(for: r.date)
            var x = days[d] ?? Day(day: d, bytes: 0, runs: 0)
            x.bytes += r.bytes; x.runs += 1
            days[d] = x
        }
        let sorted = days.keys.sorted()
        var longest = 0, run = 0
        var prev: Date?
        for d in sorted {
            if let p = prev, calendar.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            longest = max(longest, run); prev = d
        }
        // The streak is still alive if the last cleanup was today or yesterday.
        var current = 0
        var cursor = calendar.startOfDay(for: now)
        if days[cursor] == nil, let y = calendar.date(byAdding: .day, value: -1, to: cursor) { cursor = y }
        while days[cursor] != nil {
            current += 1
            guard let p = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = p
        }
        return Summary(totalBytes: records.reduce(0) { $0 + $1.bytes }, runs: records.count, activeDays: days.count,
                       currentStreak: current, longestStreak: longest, first: records.map(\.date).min(),
                       best: days.values.max { $0.bytes < $1.bytes }, days: days)
    }

    /// 0...4, like GitHub: scaled to the biggest day in view so a single huge cleanup does not wash everything else out.
    static func level(_ bytes: Int64, peak: Int64) -> Int {
        guard bytes > 0, peak > 0 else { return 0 }
        let f = Double(bytes) / Double(peak)
        return f > 0.75 ? 4 : f > 0.5 ? 3 : f > 0.2 ? 2 : 1
    }

    /// A grid of whole weeks ending with the week that contains `now`. Columns are weeks, rows Sunday...Saturday (Monday first when the locale says so).
    static func weeks(count: Int, calendar: Calendar = .current, now: Date = Date()) -> [[Date?]] {
        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        guard let thisWeekStart = calendar.date(byAdding: .day, value: -weekday, to: today) else { return [] }
        return (0..<count).map { w in
            let start = calendar.date(byAdding: .day, value: -7 * (count - 1 - w), to: thisWeekStart)!
            return (0..<7).map { d in
                let day = calendar.date(byAdding: .day, value: d, to: start)!
                return day > today ? nil : day
            }
        }
    }

    // MARK: Demo

    /// A believable year for screenshots: bursts around busy weeks, quiet stretches, a few big days.
    private static func demo() -> [CleanRecord] {
        var rng = SeededRandom(seed: 7)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [CleanRecord] = []
        for back in 0..<300 {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = cal.component(.weekday, from: day)
            let busy = (back / 9) % 3 != 2                      // a quiet week every third
            let chance = (weekday == 1 || weekday == 7) ? 0.12 : (busy ? 0.55 : 0.18)
            if back < 4 || rng.next() < chance {
                let big = rng.next() < 0.12
                let gb = big ? 6 + rng.next() * 14 : 0.3 + rng.next() * 3.2
                out.append(CleanRecord(date: day.addingTimeInterval(9 * 3600 + rng.next() * 8 * 3600), bytes: Int64(gb * 1e9),
                                       items: big ? 4 + Int(rng.next() * 9) : 1 + Int(rng.next() * 3), kind: big ? "workspaces" : "build folders"))
            }
        }
        return out
    }

    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}
