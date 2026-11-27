import SwiftUI

extension Entry {
    var statusPill: (String, Color) {
        if kind == .repo { return ("Main checkout", .gray) }
        if verdict == .dangling { return ("Stale record", .gray) }
        if safety == .danger { return ("Uncommitted", .red) }
        if verdict == .deprecated { return safety == .caution ? ("Review first", Brand.reclaim) : ("Safe to remove", Brand.accent) }
        if safety == .caution { return ("Local commits", .gray) }
        return measured ? ("Active", .gray) : ("Measuring", .gray)
    }
}
