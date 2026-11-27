import Foundation

// Helpers for lists of sessions.

extension Sequence where Element == SessionInfo {
    /// The `k` most recently active sessions in one pass: O(n), not the O(n log n) of sorting everything to read eight rows.
    func newest(_ k: Int) -> [SessionInfo] {
        var top: [SessionInfo] = []; top.reserveCapacity(k + 1)
        for s in self {
            if top.count == k, let last = top.last, s.last <= last.last { continue }
            let i = top.firstIndex { s.last > $0.last } ?? top.count
            top.insert(s, at: i)
            if top.count > k { top.removeLast() }
        }
        return top
    }
}
