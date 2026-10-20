import Darwin
import Foundation

/// Cheap line scanning for large JSONL logs: no allocation per line, and a substring test (memmem) before any JSON work.
enum Lines {
    static func each(_ data: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var start = 0
            while start < n {
                let rest = n - start
                let len: Int
                if let nl = memchr(base + start, 0x0A, rest) { len = base.distance(to: UnsafeRawPointer(nl)) - start } else { len = rest }
                if len > 0 { body(UnsafeRawBufferPointer(start: base + start, count: len)) }
                start += len + 1
            }
        }
    }

    static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let b = line.baseAddress, line.count >= needle.count, !needle.isEmpty else { return false }
        return needle.withUnsafeBufferPointer { memmem(b, line.count, $0.baseAddress!, needle.count) != nil }
    }
}

enum FastDate {
    /// "2026-10-11T08:04:27.796Z" (always UTC in these logs). About 20x faster than ISO8601DateFormatter.
    static func parse(_ s: String) -> Date? {
        var s = s
        return s.withUTF8 { b -> Date? in
            guard b.count >= 19 else { return nil }
            func num(_ i: Int, _ len: Int) -> Int? {
                var v = 0
                for k in i..<(i + len) { let d = Int(b[k]) - 48; guard d >= 0, d <= 9 else { return nil }; v = v * 10 + d }
                return v
            }
            guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
            var t = tm()
            t.tm_year = Int32(y - 1900); t.tm_mon = Int32(mo - 1); t.tm_mday = Int32(d)
            t.tm_hour = Int32(h); t.tm_min = Int32(mi); t.tm_sec = Int32(sec)
            var secs = Double(timegm(&t))
            if b.count > 20, b[19] == 0x2E {
                var scale = 0.1, i = 20
                while i < b.count, b[i] >= 48, b[i] <= 57 { secs += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
            }
            return Date(timeIntervalSince1970: secs)
        }
    }
}
