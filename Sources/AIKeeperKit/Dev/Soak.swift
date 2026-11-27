import AppKit
import SwiftUI

/// Development aid for finding memory leaks: AIKEEPER_SOAK=<seconds> cycles through every page, opening and closing
/// inspectors and sheets, so a leak in any view's lifecycle shows up as steady growth in the process footprint.
/// Measure with `footprint <pid>` and `leaks <pid>`.
@MainActor
enum Soak {
    static var seconds: Double? { ProcessInfo.processInfo.environment["AIKEEPER_SOAK"].flatMap(Double.init) }

    static func run(store: Store, for seconds: Double) async {
        try? await Task.sleep(for: .seconds(8))   // let the first scan settle
        let pages: [Destination] = [.today, .workspaces(.all), .review, .workspaces(.tool(.claude)), .workspaces(.tool(.conductor)), .live, .cost, .folders,
                                    .savedSnapshots, .history, .duplicates, .containers, .machine, .tools]
        let end = Date().addingTimeInterval(seconds)
        var lap = 0
        while Date() < end {
            for p in pages {
                store.requestedDestination = p
                try? await Task.sleep(for: .milliseconds(900))
                if case .workspaces = p, let e = store.entries.randomElement() {
                    store.requestedSelection = e.id
                    try? await Task.sleep(for: .milliseconds(500))
                    store.plan = CleanupPlan(mode: .removeWorkspaces, entries: [e])   // open and cancel the confirmation sheet
                    try? await Task.sleep(for: .milliseconds(700))
                    store.plan = nil
                }
            }
            lap += 1
            print("SOAK lap \(lap)")
        }
        print("SOAK done")
    }
}
