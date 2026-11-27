import ServiceManagement
import SwiftUI

/// Settings, laid out the way System Settings is: a list of topics on the left, grouped rows on the right.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", agents = "Agents", cleanup = "Cleanup", budgets = "Budgets", notifications = "Notifications", privacy = "Privacy and data"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .general: "gearshape"; case .agents: "bolt.horizontal"; case .cleanup: "trash"; case .budgets: "chart.bar"; case .notifications: "bell"; case .privacy: "lock.shield" }
        }
        var color: Color {
            switch self {
            case .general: Color(white: 0.55); case .agents: Brand.accent; case .cleanup: Brand.ok
            case .budgets: Brand.reclaim; case .notifications: Brand.merged; case .privacy: Color(white: 0.2)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Pane.allCases) { p in
                    let on = p == pane
                    Button { pane = p } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).frame(width: 22, height: 22).background(p.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(p.rawValue).font(.brand(13, .medium))
                            Spacer()
                        }
                        .foregroundStyle(on ? Color.white : Color.primary).padding(.horizontal, 8).frame(height: 32)
                        .background(on ? Brand.accent : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12).frame(width: 220).background(Brand.sidebar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(pane.rawValue).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    switch pane {
                    case .general: GeneralPane()
                    case .agents: AgentsPane(open: open)
                    case .cleanup: CleanupPane(open: open)
                    case .budgets: BudgetsPane()
                    case .notifications: NotificationsPane()
                    case .privacy: PrivacyPane()
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Brand.background)
        }
        .frame(width: 820, height: 600).font(.bBody).tint(Brand.accent)
    }

    private func open(_ d: Destination) { nav.go(d); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}

// MARK: Building blocks

private struct SGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) { content }.panel(12)
            if let footer { Text(footer).font(.bCaption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct SRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.bBody)
                if let subtitle { Text(subtitle).font(.bCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 10)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44).overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

private struct SMenu<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    var body: some View { PillMenu(options, selection: $selection) }
}

// MARK: General

private struct GeneralPane: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.Key.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.Key.menuBarContent) private var content = Prefs.MenuBarContent.safe.rawValue
    @AppStorage(Prefs.Key.showDockIcon) private var showDock = true
    @AppStorage(Prefs.Key.scanEveryHours) private var scanHours = Prefs.Default.scanEveryHours
    @AppStorage(Prefs.Key.scanOnBattery) private var onBattery = true
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        SGroup {
            SRow(title: "Show in the menu bar", subtitle: "If it is missing, your menu bar is full: macOS hides items that do not fit beside the notch.") { Toggle("", isOn: $showMenuBar).toggleStyle(.switch).labelsHidden() }
            SRow(title: "What it says", subtitle: "Next to the icon.") {
                SMenu(options: Prefs.MenuBarContent.allCases.map { ($0.title, $0.rawValue) }, selection: $content)
            }.disabled(!showMenuBar)
            SRow(title: "Open at login") {
                Toggle("", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = on; loginError = nil }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled; loginError = error.localizedDescription }
                })).toggleStyle(.switch).labelsHidden()
            }
            SRow(title: "Keep the Dock icon", subtitle: showMenuBar ? "Off keeps AI Keeper in the menu bar only." : "Needs the menu bar item, or there would be no way to open the app.") {
                Toggle("", isOn: $showDock).toggleStyle(.switch).labelsHidden().disabled(!showMenuBar)
            }
        }
        .onChange(of: showDock) { _, _ in NSApp.setActivationPolicy(showDock || !showMenuBar ? .regular : .accessory) }
        .onChange(of: showMenuBar) { _, on in if !on { showDock = true; NSApp.setActivationPolicy(.regular) } }
        if let e = loginError { Text(e).font(.bCaption).foregroundStyle(.red) }
        SGroup(footer: "Reads agent logs and project folders on this Mac.") {
            SRow(title: "Scan") {
                SMenu(options: [("Every hour", 1), ("Every 3 hours", 3), ("Every 6 hours", 6), ("Every 12 hours", 12), ("Every day", 24), ("Only when I ask", 0)], selection: $scanHours)
            }
            SRow(title: "Scan while on battery") { Toggle("", isOn: $onBattery).toggleStyle(.switch).labelsHidden() }.disabled(scanHours == 0)
        }
        SGroup(footer: "A workspace with uncommitted changes is never marked safe to remove, however long it sits.") {
            SRow(title: "Mark a workspace idle after") {
                Stepper(value: Bindable(store).staleDays, in: 3...180) { Text("\(store.staleDays) days").monospacedDigit() }.fixedSize()
            }
        }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

// MARK: Agents

private struct AgentsPane: View {
    @Environment(Store.self) private var store
    let open: (Destination) -> Void
    @State private var cliMessage: String?

    var body: some View {
        SGroup {
            SRow(title: "Tools tracked", subtitle: "\(store.enabledTools.count) of \(ToolCatalog.all.count) tools, and \(store.repoRoots.count) project folder\(store.repoRoots.count == 1 ? "" : "s").") {
                Button("Choose…") { open(.tools) }
            }
            SRow(title: "Run setup again", subtitle: "Look for agents and project folders from the start.") { Button("Run setup") { store.needsOnboarding = true; open(.today) } }
        }
        SGroup(footer: "Let your coding agents check disk space and clean their own build folders. Everything is a dry run unless the agent passes confirm.") {
            SRow(title: "Command-line tool", subtitle: cliMessage) { Button("Install") { cliMessage = CLIInstaller.install() } }
            SRow(title: "Agent access (MCP)", subtitle: CLIInstaller.mcpCommand) {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(CLIInstaller.mcpCommand, forType: .string) }
            }
        }
    }
}

// MARK: Cleanup

private struct CleanupPane: View {
    @Environment(Store.self) private var store
    let open: (Destination) -> Void
    @AppStorage(Prefs.Key.reclaimDeleteNow) private var deleteNow = true
    @AppStorage(Prefs.Key.vaultDays) private var vaultDays = Prefs.Default.vaultDays
    @State private var keep = Prefs.keepFolders

    var body: some View {
        SGroup {
            SRow(title: "Reclaim", subtitle: "Rebuildable and On a remote items can be recreated, so deleting them frees the space at once.") {
                SMenu(options: [("Delete now", true), ("Move to Trash", false)], selection: $deleteNow)
            }
            SRow(title: "Skip folders an agent has open", subtitle: "Not a setting.") { Tag(text: "Always", tone: .gray) }
            SRow(title: "Keep snapshots of unsaved work for") {
                Stepper(value: $vaultDays, in: 1...365) { Text("\(vaultDays) days").monospacedDigit() }.fixedSize()
            }
        }
        SGroup(footer: "These folders and everything inside them are never listed as cleanable and never removed, by you, a rule or an agent.") {
            SRow(title: "Folders to keep") { Button("Choose…") { choose() } }
            ForEach(keep, id: \.self) { f in
                SRow(title: f.replacingOccurrences(of: home, with: "~")) {
                    Button { keep.removeAll { $0 == f }; save() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Stop keeping \(f)")
                }
            }
        }
        SGroup { SRow(title: "Cleanup rules", subtitle: "Run by themselves, only on things you could get back.") { Button("Open…") { open(.area(.cleanup, .automate)) } } }
    }

    private func choose() {
        if let p = FolderPicker.choose(message: "Choose a folder AI Keeper must never clean up"), !keep.contains(p) { keep.append(p); save() }
    }
    private func save() { Prefs.defaults.set(keep, forKey: Prefs.Key.keepFolders); store.refreshStats() }
}

// MARK: Budgets

private struct BudgetsPane: View {
    @AppStorage(Prefs.Key.budgetDaily) private var daily = 0.0
    @AppStorage(Prefs.Key.budgetWeekly) private var weekly = 0.0
    @AppStorage(Prefs.Key.agentBudget("claude")) private var claude = 0.0
    @AppStorage(Prefs.Key.agentBudget("codex")) private var codex = 0.0
    @AppStorage(Prefs.Key.agentBudget("pi")) private var pi = 0.0

    private func money(_ v: Double) -> String { v == 0 ? "Off" : String(format: "$%.0f", v) }

    var body: some View {
        SGroup(footer: "0 turns a limit off. Estimated at public API list prices, from your session logs.") {
            SRow(title: "Daily") { Stepper(value: $daily, in: 0...1000, step: 5) { Text(money(daily)).monospacedDigit() }.fixedSize() }
            SRow(title: "Weekly") { Stepper(value: $weekly, in: 0...5000, step: 25) { Text(money(weekly)).monospacedDigit() }.fixedSize() }
        }
        SGroup {
            SRow(title: "Claude Code, daily") { Stepper(value: $claude, in: 0...1000, step: 5) { Text(money(claude)).monospacedDigit() }.fixedSize() }
            SRow(title: "Codex, daily") { Stepper(value: $codex, in: 0...1000, step: 5) { Text(money(codex)).monospacedDigit() }.fixedSize() }
            SRow(title: "Pi, daily") { Stepper(value: $pi, in: 0...1000, step: 5) { Text(money(pi)).monospacedDigit() }.fixedSize() }
        }
    }
}

// MARK: Notifications

private struct NotificationsPane: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.Key.notify) private var notify = true
    @AppStorage(Prefs.Key.notifyAgents) private var notifyAgents = true
    @AppStorage(Prefs.Key.guardFloorGB) private var floorGB = Prefs.Default.guardFloorGB
    @AppStorage(Prefs.Key.guardRateGB) private var rateGB = Prefs.Default.guardRateGB
    @AppStorage(Prefs.Key.digestEnabled) private var digest = true
    @State private var pausedUntil = Prefs.alertsPausedUntil

    var body: some View {
        SGroup(footer: "We send at most one disk alert a day unless free space drops fast. Finished sessions, scans and successful cleans stay silent.") {
            SRow(title: "Disk and budget alerts", subtitle: "With a button to fix it where we can.") { Toggle("", isOn: $notify).toggleStyle(.switch).labelsHidden() }
            SRow(title: "Agent alerts", subtitle: "When an agent is waiting for you.") { Toggle("", isOn: $notifyAgents).toggleStyle(.switch).labelsHidden() }
            SRow(title: "Weekly digest", subtitle: "Friday at 5 pm, with Undo for anything rules cleaned.") { Toggle("", isOn: $digest).toggleStyle(.switch).labelsHidden() }
            SRow(title: "When a rule runs") { Toggle("", isOn: Bindable(store.rules).notify).toggleStyle(.switch).labelsHidden() }
        }
        SGroup {
            SRow(title: "Alert when free space is below") { Stepper(value: $floorGB, in: 5...500, step: 5) { Text("\(Int(floorGB)) GB").monospacedDigit() }.fixedSize() }
            SRow(title: "Alert when this much disappears in 10 minutes") { Stepper(value: $rateGB, in: 1...100) { Text("\(Int(rateGB)) GB").monospacedDigit() }.fixedSize() }
        }
        SGroup {
            SRow(title: "Pause alerts", subtitle: (pausedUntil ?? .distantPast) > Date() ? "Paused until \(pausedUntil!.formatted(date: .omitted, time: .shortened))." : nil) {
                Menu("Pause") {
                    Button("For 1 hour") { set(Date().addingTimeInterval(3600)) }
                    Button("Until tomorrow morning") { set(Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime)) }
                    Button("Resume alerts") { set(nil) }
                }.fixedSize()
            }
        }
    }
    private func set(_ d: Date?) { Prefs.pauseAlerts(until: d); pausedUntil = d }
}

// MARK: Privacy

private struct PrivacyPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        SGroup(footer: "AI Keeper reads logs on this Mac and never sends them anywhere.") {
            SRow(title: "What it reads", subtitle: "Session logs in ~/.claude/projects and ~/.codex/sessions, git state in your project folders, and sizes of the folders agents and dev tools make.") { EmptyView() }
            SRow(title: "What it never touches", subtitle: "Your Documents, Photos, iCloud Drive and Mail; uncommitted changes; unpushed commits; or a folder an agent has open.") { EmptyView() }
            SRow(title: "Project folders", subtitle: store.repoRoots.isEmpty ? "None yet." : store.repoRoots.map { $0.replacingOccurrences(of: home, with: "~") }.joined(separator: "\n")) { EmptyView() }
        }
        SGroup {
            SRow(title: "AI Keeper's own data", subtitle: Persist.dir.path.replacingOccurrences(of: home, with: "~")) {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Persist.dir]) }
            }
        }
    }
}
