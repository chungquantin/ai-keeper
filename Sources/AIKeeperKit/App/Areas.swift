import SwiftUI

// The five places in the app. Each is one question; tabs hold the variations.
// Today: what needs me?  Sessions: what are my agents doing?  Insights: how do I work?
// Cleanup: what can I remove?  Agents: how is it set up?

enum Area: String, CaseIterable, Identifiable {
    case today = "Today", sessions = "Traces", insights = "Insights", cleanup = "Cleanup", agents = "Agents"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .sessions: "text.justify.left"
        case .insights: "chart.bar.xaxis"
        case .cleanup: "trash"
        case .agents: "bolt.horizontal"
        }
    }

    var tabs: [Tab] {
        switch self {
        case .today: [.briefing]
        case .sessions: [.history, .live, .logs, .prompts]
        case .insights: [.findings]                                    // one page; the rest open from its "Look deeper" list
        case .cleanup: [.overview, .clean, .apps, .files, .optimize, .automate]
        case .agents: [.tools, .skills, .mcp, .hooks, .budgets]
        }
    }
    var firstTab: Tab { tabs[0] }

    /// Every page in the area, including the ones reached from inside another page and not from a tab.
    var pages: [Tab] {
        switch self {
        case .insights: [.findings, .cost, .speed, .reliability, .context, .advisor, .machine]
        default: tabs
        }
    }
}

enum Tab: String, Hashable, Identifiable {
    case briefing = "Briefing"
    case history = "Sessions", live = "Live", logs = "Logs", prompts = "Prompts"
    case findings = "Findings", cost = "Cost", speed = "Speed", reliability = "Reliability", context = "Context", advisor = "Advisor", machine = "Machine"
    case overview = "Overview", clean = "Clean", apps = "Apps", files = "Files", optimize = "Optimize", automate = "Automate"
    case tools = "Tools", skills = "Skills", mcp = "MCP servers", hooks = "Hooks", budgets = "Budgets"
    var id: String { rawValue }

    /// One line under the title saying what the page is for.
    var subtitle: String {
        switch self {
        case .briefing: "What needs you, and what you can get back or save"
        case .history: "Every agent session on this Mac, searchable"
        case .live: "Agents running right now"
        case .logs: "What failed, what you declined and what was compacted, across recent sessions"
        case .prompts: "Every prompt you sent, and how long the agent worked on it"
        case .findings: "What to change, from your last 30 days of sessions"
        case .cost: "Estimated at public API list prices, from your local session logs"
        case .speed: "How long agents take, and where the time goes"
        case .reliability: "What fails, what loops, and what costs you retries"
        case .context: "How full the window gets, and what the cache saves"
        case .advisor: "What your own history says about which agent and tools to use"
        case .machine: "What agents cost this Mac"
        case .overview: "Your disk, and what you can clear"
        case .clean: "Junk, developer clutter and agent data, sorted by what losing it would cost"
        case .apps: "Uninstall apps, and everything they left behind"
        case .files: "Large and old files, duplicates and the folder map"
        case .optimize: "What starts with your Mac, and routine maintenance"
        case .automate: "Rules that run by themselves, and what they did"
        case .tools: "Every agent on this Mac"
        case .skills: "What your agents can load, checked for risky scripts"
        case .mcp: "What each server adds to every session, and whether it is used"
        case .hooks: "Commands that run around an agent's tool use"
        case .budgets: "Spend limits for you, then for each agent"
        }
    }
    var action: String? {
        switch self { case .cost: "Export CSV"; default: nil }
    }

    var symbol: String {
        switch self {
        case .briefing: "sun.max"
        default: ""
        }
    }
}

/// Where the user is, and the state of the filters that used to be separate pages.
@MainActor @Observable
final class NavState {
    var area: Area = .today { didSet { remember() } }
    var tab: [Area: Tab] = Dictionary(uniqueKeysWithValues: Area.allCases.map { ($0, $0.firstTab) }) { didSet { remember() } }

    // scripts/dev.sh relaunches the app after every rebuild. With AIKEEPER_DEV set, it comes back on the page you were on.
    private static let devFile: URL? = ProcessInfo.processInfo.environment["AIKEEPER_DEV"] != nil ? Persist.dir.appendingPathComponent("dev-nav.txt") : nil
    private func remember() { if let f = Self.devFile { try? "\(area.rawValue)|\(currentTab.rawValue)".write(to: f, atomically: true, encoding: .utf8) } }
    init() {
        guard let f = Self.devFile, let s = try? String(contentsOf: f, encoding: .utf8) else { return }
        let p = s.split(separator: "|").map(String.init)
        if p.count == 2, let a = Area(rawValue: p[0]), let t = Tab(rawValue: p[1]), a.pages.contains(t) { area = a; tab[a] = t }
    }
    var workspaceFilter: WorkspaceFilter = .all   // all, deprecated, or one tool
    var cleanMode: CleanMode = .review
    var filesMode: FilesMode = .large
    var autoMode: AutoMode = .rules
    var dataMode: DataMode = .sources
    var showBasket = false                   // the confirm sheet behind the sidebar's Reclaim button
    var showPalette = false
    /// The session whose full trace is open, in place of the Traces lists.
    var openTrace: SessionInfo?
    /// The agent filter at the top of the sidebar. nil means all agents.
    var scope: String?

    var currentTab: Tab { tab[area] ?? area.firstTab }

    func open(_ a: Area, _ t: Tab? = nil) {
        openTrace = nil
        area = a
        if let t { tab[a] = t }
    }
}

// MARK: Layout helpers shared by the area pages

private struct EmbeddedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when a page sits under an area's tab strip, which already clears the toolbar.
    var embeddedInArea: Bool { get { self[EmbeddedKey.self] } set { self[EmbeddedKey.self] = newValue } }
}

private struct ToolbarClearance: ViewModifier {
    @Environment(\.embeddedInArea) private var embedded
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: embedded ? 0 : 62) }   // keep the first row clear of the glass toolbar
    }
}
extension View { func toolbarClearance() -> some View { modifier(ToolbarClearance()) } }

/// The tab strip: a quiet underline under the open tab. Areas with a single page do not show one.
struct TabStrip: View {
    let tabs: [Tab]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs) { t in
                let on = t == selection
                Button { selection = t } label: {
                    Text(t.rawValue)
                        .font(.brand(13, .medium))
                        .foregroundStyle(on ? Brand.primaryText : Brand.mutedForeground)
                        .padding(.top, 10).padding(.bottom, 11)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? Brand.accent : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One area: the title is set by the window, the tab strip sits under the toolbar, and the page fills the rest.
struct AreaView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    let area: Area

    var body: some View {
        if area == .sessions, let s = nav.openTrace { TraceDetailView(session: s).id(s.id) } else { lists }
    }

    private var lists: some View {
        VStack(spacing: 0) {
            // One bar: where you are, what it is for, and its one action. The window has no separate title.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if area == .insights && nav.currentTab != .findings {
                    Button { nav.tab[.insights] = .findings } label: { Label("Insights", systemImage: "chevron.left").font(.brand(13, .medium)) }
                        .buttonStyle(.plain).foregroundStyle(Brand.primaryText)
                    Text("›").foregroundStyle(.tertiary)
                    Text(nav.currentTab.rawValue).font(.brand(15, .semibold))
                } else {
                    Text(area.rawValue).font(.brand(15, .semibold))
                }
                Text(nav.currentTab.subtitle).font(.bCaption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if area == .today { Text(Date().formatted(.dateTime.weekday(.wide).month().day())).font(.bCaption).foregroundStyle(.secondary) }
                if let a = nav.currentTab.action { Button(a) { UsageExport.save(store.usage) }.buttonStyle(.brandOutline).controlSize(.small) }
            }
            .padding(.horizontal, 28).frame(height: 52)
            if area.tabs.count > 1 {
                TabStrip(tabs: area.tabs, selection: Binding(get: { nav.currentTab }, set: { nav.tab[area] = $0 }))
            }
            GeometryReader { g in
                HStack(spacing: 0) {
                    page(nav.currentTab)
                        .environment(\.embeddedInArea, true)
                        .buttonStyle(.brandOutline)   // the quiet secondary button, unless a view asks for another
                        .id(nav.currentTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Brand.background)
    }

    @ViewBuilder private func page(_ t: Tab) -> some View {
        switch t {
        case .briefing: TodayHome()
        case .findings: InsightsHome()
        case .history: SessionHistoryView()
        case .live: AgentsView()
        case .logs: LogsView()
        case .prompts: PromptsView()
        case .cost: CostView()
        case .speed: SpeedView()
        case .reliability: ReliabilityView()
        case .context: ContextView()
        case .advisor: AdvisorView()
        case .machine: SystemView()
        case .overview: StorageOverview()
        case .clean: CleanTab()
        case .apps: AppsTab()
        case .files: FilesTab()
        case .optimize: OptimizeTab()
        case .automate: AutomateHub()
        case .tools: FleetView()
        case .skills: SkillsView()
        case .mcp: MCPView()
        case .hooks: HooksView()
        case .budgets: BudgetsView()
        }
    }
}

/// Workspaces: the old All, Deprecated and By tool pages are one list with a filter.
struct WorkspacesTab: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav

    private var tools: [Source] { ToolCatalog.all.filter { store.enabledTools.contains($0.id) && $0.workspaces }.compactMap(\.source) + [.git] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Seg([("All", 0), ("Safe to remove", 1), ("By tool", 2)], selection: Binding(
                    get: { nav.workspaceFilter == .deprecated ? 1 : (nav.workspaceFilter == .all ? 0 : 2) },
                    set: { nav.workspaceFilter = $0 == 1 ? .deprecated : ($0 == 0 ? .all : (tools.first.map { WorkspaceFilter.tool($0) } ?? WorkspaceFilter.all)) }))
                if case .tool(let cur) = nav.workspaceFilter {
                    Menu {
                        ForEach(tools, id: \.self) { s in Button(s.rawValue) { nav.workspaceFilter = .tool(s) } }
                    } label: { Label(cur.rawValue, systemImage: "line.3.horizontal.decrease") }.fixedSize()
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            EntryListView(filter: nav.workspaceFilter).id(nav.workspaceFilter)
        }
    }
}

/// Export CSV on Cost: one row per day, agent and model.
enum UsageExport {
    @MainActor static func save(_ rows: [UsageRow]) {
        let p = NSSavePanel(); p.nameFieldStringValue = "ai-keeper-usage.csv"; p.allowedContentTypes = [.commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        var acc: [String: (Int, Int, Int, Int, Double)] = [:]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for r in rows { let k = "\(f.string(from: r.day)),\(r.agent.rawValue),\(r.model)"; var x = acc[k] ?? (0, 0, 0, 0, 0); x.0 += r.input; x.1 += r.output; x.2 += r.cacheRead; x.3 += r.cacheWrite; x.4 += r.cost; acc[k] = x }
        var out = "day,agent,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,estimated_cost_usd\n"
        for k in acc.keys.sorted() { let x = acc[k]!; out += "\(k),\(x.0),\(x.1),\(x.2),\(x.3),\(String(format: "%.4f", x.4))\n" }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum CleanMode: Hashable { case review, agentData, allWorkspaces }
enum FilesMode: Hashable { case large, duplicates, folders, trustMap }
enum AutoMode: Hashable { case rules, history, snapshots }
enum DataMode: Hashable { case sources, containers }
