import SwiftUI

/// Which workspaces the "All workspaces" table shows.
enum WorkspaceFilter: Hashable {
    case all, deprecated, tool(Source), leftovers
}

/// Where a link, an alert, a menu command or the search palette can send you. One type for the whole app:
/// an area and tab, plus the few places that also need a mode set on the page they open.
enum Destination: Hashable {
    case today
    case area(Area, Tab)
    case review                          // Cleanup › Review
    case workspaces(WorkspaceFilter)     // Cleanup › Review › All workspaces
    case folders, duplicates             // Cleanup › Map
    case containers                      // Cleanup › Agent data › Containers
    case savedSnapshots                  // Cleanup › History › Saved snapshots

    static let live = Destination.area(.sessions, .live)
    static let history = Destination.area(.sessions, .history)
    static let cost = Destination.area(.insights, .cost)
    static let machine = Destination.area(.insights, .machine)
    static let skills = Destination.area(.agents, .skills)
    static let tools = Destination.area(.agents, .tools)
}

extension NavState {
    func go(_ d: Destination) {
        switch d {
        case .today: open(.today, .briefing)
        case .area(let a, let t): open(a, t)
        case .review: reviewAll = false; open(.cleanup, .review)
        case .workspaces(let f): workspaceFilter = f; reviewAll = true; open(.cleanup, .review)
        case .folders: mapMode = .folders; open(.cleanup, .map)
        case .duplicates: mapMode = .duplicates; open(.cleanup, .map)
        case .containers: dataMode = .containers; open(.cleanup, .agentData)
        case .savedSnapshots: historyMode = .removed; open(.cleanup, .cleaned)
        }
    }
}
