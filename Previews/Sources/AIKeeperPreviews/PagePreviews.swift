import SwiftUI
@testable import AIKeeperKit

// Every page of the app, on demo data. Sizes match the content column of the window at its usual 1360 points
// (the window is 1360, the sidebar takes 232). Narrow variants use the minimum window width, 1060.

// MARK: Today

#Preview("Today · Briefing") { TodayHome().previewEnv().previewPage() }
#Preview("Today · Briefing · dark") { TodayHome().previewEnv().previewPage().preferredColorScheme(.dark) }

// MARK: Sessions

#Preview("Sessions · History") { SessionHistoryView().previewEnv(.sessions, .history).previewPage(height: 820) }
#Preview("Sessions · History · narrow") { SessionHistoryView().previewEnv(.sessions, .history).previewPage(width: 828, height: 820) }
#Preview("Sessions · Logs") { LogsView().previewEnv().previewPage() }
#Preview("Sessions · Prompts") { PromptsView().previewEnv().previewPage() }

// MARK: Insights

#Preview("Insights · Findings") { InsightsHome().previewEnv(.insights, .findings).previewPage(height: 820) }
#Preview("Insights · Speed") { SpeedView().previewEnv().previewPage(height: 1400) }
#Preview("Insights · Reliability") { ReliabilityView().previewEnv().previewPage() }
#Preview("Insights · Reliability · narrow") { ReliabilityView().previewEnv().previewPage(width: 828) }
#Preview("Insights · Reliability · dark") { ReliabilityView().previewEnv().previewPage().preferredColorScheme(.dark) }
#Preview("Insights · Context") { ContextView().previewEnv().previewPage() }
#Preview("Insights · Advisor") { AdvisorView().previewEnv().previewPage(height: 1000) }
#Preview("Insights · Customize metrics") { MetricsCatalogSheet() }

// MARK: Cleanup

#Preview("Cleanup · Review") { CleanupReview().previewEnv(.cleanup, .review).previewPage(height: 820) }
#Preview("Cleanup · Review · dark") { CleanupReview().previewEnv(.cleanup, .review).previewPage(height: 820).preferredColorScheme(.dark) }
#Preview("Cleanup · Review · narrow") { CleanupReview().previewEnv(.cleanup, .review).previewPage(width: 828, height: 820) }
#Preview("Cleanup · Item detail") {
    ReclaimDetail(item: PreviewKit.store.reclaimItems.first { $0.kind == .merged } ?? PreviewKit.store.reclaimItems[0]) {}.previewEnv(.cleanup, .review).previewPage(height: 820)
}
#Preview("Cleanup · Map") { CleanupMap().previewEnv(.cleanup, .map).previewPage(height: 820) }
#Preview("Cleanup · Agent data") { AgentDataTab().previewEnv(.cleanup, .agentData).previewPage(height: 820) }
#Preview("Cleanup · Automate") { AutomateTab().previewEnv(.cleanup, .automate).previewPage(height: 820) }
#Preview("Cleanup · History") { CleanupHistory().previewEnv(.cleanup, .cleaned).previewPage(height: 820) }
#Preview("Cleanup · Basket") { BasketSheet().previewEnv(.cleanup, .review) }

// MARK: Agents

#Preview("Agents · Tools") { FleetView().previewEnv(.agents, .tools).previewPage(height: 820) }
#Preview("Agents · MCP servers") { MCPView().previewEnv().previewPage() }
#Preview("Agents · Hooks") { HooksView().previewEnv().previewPage() }
#Preview("Agents · Budgets") { BudgetsView().previewEnv().previewPage(height: 820) }

// MARK: Dialogs and windows

#Preview("Confirm cleanup") {
    CleanupSheet(plan: CleanupPlan(mode: .removeWorkspaces, entries: Array(PreviewKit.store.removableWorkspaces.prefix(3)))).previewEnv()
}
#Preview("Share a session") {
    ShareSheet(session: PreviewKit.store.sessions[0]).previewEnv()
}
#Preview("Compare two runs") {
    CompareSheet(session: PreviewKit.store.sessions[0]).previewEnv()
}
#Preview("Search and commands") { PaletteView().previewEnv() }
#Preview("Settings") { SettingsView().previewEnv() }
#Preview("First run") { OnboardingView().previewEnv() }
#Preview("Menu bar") { MenuContent().previewEnv() }

// MARK: The whole window

#Preview("App · Today") { RootView().previewEnv(.today).frame(width: 1360, height: 900) }
#Preview("App · Insights") { RootView().previewEnv(.insights, .reliability).frame(width: 1360, height: 900) }
#Preview("App · Cleanup · dark") { RootView().previewEnv(.cleanup, .review).frame(width: 1360, height: 900).preferredColorScheme(.dark) }
