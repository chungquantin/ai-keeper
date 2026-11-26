import SwiftUI

// The five places in the app. Each is one question; tabs hold the variations.
// Today: what needs me?  Sessions: what are my agents doing?  Insights: how do I work?
// Cleanup: what can I remove?  Agents: how is it set up?

enum Area: String, CaseIterable, Identifiable {
    case today = "Today", sessions = "Sessions", insights = "Insights", cleanup = "Cleanup", agents = "Agents"
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
        case .today: [.briefing, .reclaim, .optimize, .activity]
        case .sessions: [.history, .live, .logs, .prompts]
        case .insights: [.cost, .speed, .reliability, .context, .advisor, .machine]
        case .cleanup: [.workspaces, .leftovers, .disk, .containers, .removed]
        case .agents: [.tools, .skills, .mcp, .hooks, .budgets]
        }
    }
    var firstTab: Tab { tabs[0] }
}

enum Tab: String, Hashable, Identifiable {
    case briefing = "Briefing", reclaim = "Reclaim", optimize = "Optimize", activity = "Activity"
    case history = "History", live = "Live", logs = "Logs", prompts = "Prompts"
    case cost = "Cost", speed = "Speed", reliability = "Reliability", context = "Context", advisor = "Advisor", machine = "Machine"
    case workspaces = "Workspaces", leftovers = "Leftovers", disk = "Disk", containers = "Containers", removed = "Removed"
    case tools = "Tools", skills = "Skills", mcp = "MCP servers", hooks = "Hooks", budgets = "Budgets"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .briefing: "sun.max"
        case .reclaim: "trash"
        case .optimize: "chart.bar.xaxis"
        case .activity: "bolt.horizontal"
        default: ""
        }
    }
}

/// Where the user is, and the state of the filters that used to be separate pages.
@MainActor
final class NavState: ObservableObject {
    @Published var area: Area = .today
    @Published var tab: [Area: Tab] = Dictionary(uniqueKeysWithValues: Area.allCases.map { ($0, $0.firstTab) })
    @Published var workspaceFilter: Section = .all      // all, deprecated, or one tool
    @Published var diskDuplicates = false               // Disk tab: analyzer or duplicates
    @Published var showPalette = false
    /// The agent filter at the top of the sidebar. nil means all agents.
    @Published var scope: String?

    var currentTab: Tab { tab[area] ?? area.firstTab }

    func open(_ a: Area, _ t: Tab? = nil) {
        area = a
        if let t { tab[a] = t }
    }

    /// Old page names still work: menu commands, alerts and the screenshot tool all speak `Section`.
    func go(_ s: Section) {
        switch s {
        case .overview: open(.today, .briefing)
        case .all: workspaceFilter = .all; open(.cleanup, .workspaces)
        case .deprecated: workspaceFilter = .deprecated; open(.cleanup, .workspaces)
        case .tool: workspaceFilter = s; open(.cleanup, .workspaces)
        case .leftovers: open(.cleanup, .leftovers)
        case .disk: diskDuplicates = false; open(.cleanup, .disk)
        case .dedupe: diskDuplicates = true; open(.cleanup, .disk)
        case .containers: open(.cleanup, .containers)
        case .vault: open(.cleanup, .removed)
        case .agents: open(.sessions, .live)
        case .sessions: open(.sessions, .history)
        case .usage: open(.insights, .cost)
        case .memory: open(.insights, .machine)
        case .skills: open(.agents, .skills)
        case .integrations: open(.agents, .tools)
        }
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

/// The tab strip. Today uses raised pills with a live count on each tab; every other area uses a quiet underline.
struct TabStrip: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var pills = false
    var badge: (Tab) -> String? = { _ in nil }
    var hot: (Tab) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: pills ? 6 : 22) {
            ForEach(tabs) { t in
                let on = t == selection
                Button { selection = t } label: {
                    if pills { pill(t, on) } else { underline(t, on) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, pills ? 4 : 0)
        .padding(.bottom, pills ? 12 : 0)
        .overlay(alignment: .bottom) { if !pills { Divider() } }
    }

    private func pill(_ t: Tab, _ on: Bool) -> some View {
        HStack(spacing: 8) {
            if !t.symbol.isEmpty { Image(systemName: t.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Brand.primaryText : Brand.mutedForeground) }
            Text(t.rawValue).font(.brand(13, on ? .semibold : .medium))
            if let b = badge(t) {
                Text(b).font(.brand(12, .semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(hot(t) ? Brand.reclaimTint : (on ? Brand.primaryTint : Brand.muted), in: Capsule())
                    .foregroundStyle(hot(t) ? Brand.reclaimText : (on ? Brand.primaryText : Brand.mutedForeground))
            }
        }
        .foregroundStyle(on ? Color.primary : Brand.mutedForeground)
        .padding(.leading, 12).padding(.trailing, 14).frame(height: 38)
        .background {
            if on { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.edge))
                .shadow(color: Brand.liftNear, radius: 1, y: 1).shadow(color: Brand.liftFar, radius: 8, y: 5) }
        }
        .contentShape(Rectangle())
    }

    private func underline(_ t: Tab, _ on: Bool) -> some View {
        Text(t.rawValue)
            .font(.brand(13, .medium))
            .foregroundStyle(on ? Brand.primaryText : Brand.mutedForeground)
            .padding(.top, 10).padding(.bottom, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(on ? Brand.accent : .clear).frame(height: 2) }
            .contentShape(Rectangle())
    }
}

/// One area: the title is set by the window, the tab strip sits under the toolbar, and the page fills the rest.
struct AreaView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    let area: Area

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 8)
            TabStrip(tabs: area.tabs,
                     selection: Binding(get: { nav.currentTab }, set: { nav.tab[area] = $0 }),
                     pills: area == .today, badge: badge, hot: { area == .today && $0 == .briefing })
            GeometryReader { g in
                HStack(spacing: 0) {
                    page(nav.currentTab)
                        .environment(\.embeddedInArea, true)
                        .id(nav.currentTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if area == .insights, nav.currentTab == .speed, g.size.width >= 1120 {
                        Divider()
                        WorthChanging().frame(width: 300)
                    }
                }
            }
        }
        .navigationTitle(area.rawValue)
        .toolbar {
            if area == .today {
                ToolbarItem(placement: .automatic) { Text(Date().formatted(.dateTime.weekday(.wide).month().day())).font(.bCaption).foregroundStyle(.secondary) }
            }
        }
        .background(Brand.background)
    }

    private func badge(_ t: Tab) -> String? {
        guard area == .today else { return nil }
        switch t {
        case .briefing: return "\(TodayData.attention(store).count)"
        case .reclaim: return store.hasData ? store.reclaimable.bytesString : nil
        case .optimize: return "$\(MockData.monthlySavings)"
        case .activity:
            let n = store.agents.filter { $0.kind != .mcp }.count
            return n > 0 ? "\(n) live" : nil
        default: return nil
        }
    }

    @ViewBuilder private func page(_ t: Tab) -> some View {
        switch t {
        case .briefing: TodayBriefing()
        case .reclaim: TodayReclaim()
        case .optimize: TodayOptimize()
        case .activity: TodayActivity()
        case .history: SessionHistoryView()
        case .live: AgentsView()
        case .logs: LogsView()
        case .prompts: PromptsView()
        case .cost: UsageView()
        case .speed: SpeedView()
        case .reliability: ReliabilityView()
        case .context: ContextView()
        case .advisor: AdvisorView()
        case .machine: SystemView()
        case .workspaces: WorkspacesTab()
        case .leftovers: EntryListView(section: .leftovers).id(Section.leftovers)
        case .disk: DiskTab()
        case .containers: DockerView()
        case .removed: VaultView()
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
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState

    private var tools: [Source] { ToolCatalog.all.filter { store.enabledTools.contains($0.id) && $0.workspaces }.compactMap(\.source) + [.git] }

    var body: some View {
        VStack(spacing: 0) {
            ReclaimStrip().padding(.horizontal, 28).padding(.top, 6)
            HStack(spacing: 10) {
                Picker("Show", selection: Binding(
                    get: { nav.workspaceFilter == .deprecated ? 1 : (nav.workspaceFilter == .all ? 0 : 2) },
                    set: { nav.workspaceFilter = $0 == 1 ? .deprecated : ($0 == 0 ? .all : (tools.first.map { Section.tool($0) } ?? Section.all)) })) {
                    Text("All").tag(0); Text("Safe to remove").tag(1); Text("By tool").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                if case .tool(let cur) = nav.workspaceFilter {
                    Menu {
                        ForEach(tools, id: \.self) { s in Button(s.rawValue) { nav.workspaceFilter = .tool(s) } }
                    } label: { Label(cur.rawValue, systemImage: "line.3.horizontal.decrease") }.fixedSize()
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            EntryListView(section: nav.workspaceFilter).id(nav.workspaceFilter)
        }
    }
}

/// Disk: the analyzer and duplicate merging share one tab.
struct DiskTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: NavState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $nav.diskDuplicates) { Text("Analyzer").tag(false); Text("Duplicates").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
            }.padding(.horizontal, 28).padding(.vertical, 10)
            if nav.diskDuplicates { DedupView(model: store.dedup) } else { DiskView(model: store.analyzer) }
        }
    }
}

/// The one-line answer above the Cleanup lists: how much is there and what kind it is.
struct ReclaimStrip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let ws = store.total(store.removableWorkspaces), build = store.keptArtifactBytes, left = store.total(store.orphanSessions) + store.total(store.caches)
        let total = max(ws + build + left, 1)
        Card(padding: 14) {
            HStack(spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(store.hasData ? store.reclaimable.byteParts.number : "—").font(.figure(40)).monospacedDigit()
                    Text(store.reclaimable.byteParts.unit).font(.figure(16)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            Rectangle().fill(Brand.reclaim).frame(width: max(0, (g.size.width - 4) * Double(build) / Double(total)))
                            Rectangle().fill(Brand.accent).frame(width: max(0, (g.size.width - 4) * Double(ws) / Double(total)))
                            Rectangle().fill(Brand.merged).frame(width: max(0, (g.size.width - 4) * Double(left) / Double(total)))
                        }.clipShape(RoundedRectangle(cornerRadius: 5)).background(RoundedRectangle(cornerRadius: 5).fill(Brand.muted))
                    }.frame(height: 10)
                    Legend(items: [("Build folders \(build.bytesString)", Brand.reclaim), ("Merged workspaces \(ws.bytesString)", Brand.accent), ("Leftovers \(left.bytesString)", Brand.merged)])
                }
            }
        }
    }
}

/// The right-hand panel on Speed, Reliability and Context: the few changes worth making. Sample data until the advisor is measured.
struct WorthChanging: View {
    @EnvironmentObject var nav: NavState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Worth changing").font(.bHeadline)
                    Text("From your last 30 days. Open Advisor for the full picture.").font(.bCaption).foregroundStyle(.secondary)
                }
                SampleChip()
                ForEach([("Send docs to Pi", "Same merged rate as Claude Code at a fifth of the cost.", "$18 a month", Tone.blue),
                         ("Remove the linear MCP server", "Adds 3.8K tokens to every session and was never called.", "$9 a month", .blue),
                         ("Start fresh at 70% context", "Long sessions cost 2.3× as much and finish less often.", "$18 a month", .amber)], id: \.0) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) { Text(t.0).font(.bBody.weight(.semibold)); Spacer(minLength: 4); Tag(text: t.2, tone: t.3) }
                        Text(t.1).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Brand.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button { nav.open(.insights, .advisor) } label: { Text("Open Advisor").frame(maxWidth: .infinity) }.buttonStyle(.brandProminent).controlSize(.large)
                Button { nav.open(.agents, .budgets) } label: { Text("Set a budget").frame(maxWidth: .infinity) }
            }.padding(20)
        }.background(Brand.card)
    }
}
