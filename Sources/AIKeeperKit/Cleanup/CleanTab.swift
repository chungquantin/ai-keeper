import SwiftUI

/// Clean: one place for everything that can go, with the agent data and every workspace a tap away.
struct CleanTab: View {
    @Environment(NavState.self) private var nav

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Seg([("Review", CleanMode.review), ("Agent data", .agentData), ("All workspaces", .allWorkspaces)], selection: Bindable(nav).cleanMode)
                Spacer()
            }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 2)
            switch nav.cleanMode {
            case .review: CleanupReview()
            case .agentData: AgentDataTab()
            case .allWorkspaces: WorkspacesTab()
            }
        }
    }
}
