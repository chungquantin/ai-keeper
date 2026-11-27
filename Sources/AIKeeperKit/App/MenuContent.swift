import SwiftUI

// The menu bar item is the main way in: three facts, one action each. The window is for when you want to dig in.

/// The two menu bar settings, kept in step with UserDefaults so Settings can change them while the app runs.
/// (A binding straight to `@AppStorage` in the App struct sent the scene into an endless update loop.)
@MainActor @Observable
final class MenuBarSetting {
    var isShown = Prefs.showMenuBar { didSet { if oldValue != isShown { Prefs.defaults.set(isShown, forKey: Prefs.Key.showMenuBar) } } }
    var content = Prefs.menuBarContent.rawValue

    init() {
        // Lives as long as the app does, so the observer is never removed.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        if Prefs.showMenuBar != isShown { isShown = Prefs.showMenuBar }
        if Prefs.menuBarContent.rawValue != content { content = Prefs.menuBarContent.rawValue }
    }
}

/// The icon and the few words beside it. The icon says what needs you; the words are the one number you chose in Settings.
struct MenuBarLabel: View {
    let store: Store
    let content: String

    private var waiting: Int { store.agents.filter { $0.kind != .mcp && $0.state == .needsInput }.count }
    private var diskAlert: Bool { store.alert.map { $0.kind != .budget } ?? false }

    var body: some View {
        let (symbol, text) = parts
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
        .accessibilityLabel(waiting > 0 ? "AI Keeper, \(waiting) agent\(waiting == 1 ? "" : "s") waiting" : diskAlert ? "AI Keeper, disk filling fast" : "AI Keeper")
    }

    private var parts: (String, String?) {
        if waiting > 0 { return ("exclamationmark.bubble.fill", "\(waiting)") }
        if diskAlert { return ("externaldrive.badge.exclamationmark", "Disk low") }
        if store.isScanning { return ("arrow.triangle.2.circlepath", nil) }
        let symbol = "externaldrive.badge.checkmark"
        switch Prefs.MenuBarContent(rawValue: content) ?? .safe {
        case .safe: let b = store.stats.safeBytes; return (symbol, b > 0 ? b.bytesString.replacingOccurrences(of: ",0", with: "").replacingOccurrences(of: ".0", with: "") : nil)
        case .spend: return (symbol, String(format: "$%.0f", store.spentToday))
        case .iconOnly: return (symbol, nil)
        }
    }
}

struct MenuContent: View {
    @Environment(Store.self) private var store
    @Environment(NavState.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var pausedUntil = Prefs.alertsPausedUntil

    private func showWindow() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    private func open(_ d: Destination) { nav.go(d); showWindow() }

    var body: some View {
        let live = store.agents.filter { $0.kind != .mcp }
        let waiting = live.filter { $0.state == .needsInput }
        VStack(alignment: .leading, spacing: 12) {
            header
            if let a = waiting.first { banner(tone: .blue, title: "\(name(a)) is waiting.", text: a.title ?? "It needs an approval.", primary: "Open session") { open(.live) } }
            else if let al = store.alert, al.kind != .budget {
                banner(tone: .amber, title: al.title + ".", text: al.message, primary: store.stats.rebuildBytes > 0 ? "Clear build folders" : "Review") {
                    if store.stats.rebuildBytes > 0 { store.clearBuildFolders() } else { open(.review) }
                    store.alert = nil
                } dismiss: { store.alert = nil }
            }
            diskRow
            spendRow
            agentsRow(live)
            Divider().padding(.horizontal, -14)
            VStack(spacing: 0) {
                link("Open AI Keeper", shortcut: "⌘O") { showWindow() }.keyboardShortcut("o")
                pauseRow
                SettingsLink { HStack { Text("Settings…"); Spacer(); Text("⌘,").font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle()) }
                    .buttonStyle(HoverRowStyle()).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                link("Quit AI Keeper", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .font(.bBody)
        .padding(14).frame(width: 340, alignment: .leading)
    }

    private func name(_ a: AgentProc) -> String { store.workspace(for: a)?.name ?? a.cwd.map { ($0 as NSString).lastPathComponent } ?? a.kind.rawValue }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text("AI Keeper").font(.brand(14, .semibold))
            Spacer()
            HStack(spacing: 6) {
                if store.isScanning { ProgressView().controlSize(.mini) }
                else {
                    Circle().fill((store.lastScan.map { Date().timeIntervalSince($0) > 3600 } ?? true) ? Brand.reclaim : Brand.ok).frame(width: 6, height: 6)
                    Text(store.lastScan.map { "Scanned \($0.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))" } ?? "Not scanned yet").font(.bCaption2).foregroundStyle(.secondary)
                }
                Button { Task { await store.rescan() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(store.isScanning).help("Rescan").accessibilityLabel("Rescan")
            }
        }
    }

    private func banner(tone: Tone, title: String, text: String, primary: String, action: @escaping () -> Void, dismiss: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text(title + " ").fontWeight(.semibold) + Text(text)).font(.bCaption).foregroundStyle(tone.fg).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(primary, action: action).buttonStyle(.brandProminent).controlSize(.small)
                if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.brandOutline).controlSize(.small) }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(tone.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var diskRow: some View {
        let safe = store.stats.safeBytes, only = store.stats.onlyHereBytes
        return HStack(spacing: 12) {
            TierChip(symbol: "trash", tone: .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.hasData ? (safe > 0 ? "\(safe.bytesString) safe to reclaim" : "Nothing safe to clear") : "Measuring…").font(.bBody.weight(.semibold))
                Text(only > 0 ? "\(only.bytesString) more needs a look" : "\(store.disk.available.bytesString) free on this Mac").font(.bCaption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Reclaim") { store.basket.resetToSafe(); nav.showBasket = true; showWindow() }
                .buttonStyle(.brandProminent).controlSize(.small).disabled(safe == 0 || store.isScanning)
        }
    }

    private var spendRow: some View {
        let budget = Prefs.budgetDaily, spent = store.spentToday
        return HStack(alignment: .top, spacing: 12) {
            TierChip(symbol: "chart.bar", tone: .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "$%.2f today", spent)).font(.bBody.weight(.semibold))
                if budget > 0 {
                    GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Brand.muted); Capsule().fill(spent / budget >= 1 ? Brand.destructive : spent / budget >= 0.8 ? Brand.reclaim : Brand.accent).frame(width: max(4, g.size.width * min(spent / budget, 1))) } }.frame(height: 6)
                    Text("\(Int((spent / budget * 100).rounded()))% of your \(String(format: "$%.0f", budget)) daily budget").font(.bCaption).foregroundStyle(.secondary)
                } else {
                    Button("Set a daily budget") { open(.area(.agents, .budgets)) }.buttonStyle(.plain).font(.bCaption).foregroundStyle(Brand.primaryText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func agentsRow(_ live: [AgentProc]) -> some View {
        let waiting = live.filter { $0.state == .needsInput }.count
        return HStack(alignment: .top, spacing: 12) {
            TierChip(symbol: "bolt.horizontal", tone: .violet)
            VStack(alignment: .leading, spacing: 6) {
                Text(live.isEmpty ? "No agents running" : waiting > 0 ? "\(live.count) running · \(waiting) waiting" : "\(live.count) agent\(live.count == 1 ? "" : "s") running").font(.bBody.weight(.semibold))
                ForEach(live.sorted { ($0.state == .needsInput ? 0 : 1) < ($1.state == .needsInput ? 0 : 1) }.prefix(3)) { a in
                    HStack(spacing: 8) {
                        Circle().fill(a.state == .needsInput ? Brand.reclaim : a.state == .working ? Brand.accent : Brand.mutedForeground.opacity(0.5)).frame(width: 7, height: 7)
                        Text(name(a)).font(.bCaption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(a.state == .needsInput ? "waiting" : a.state == .working ? "working" : "idle") · \(a.elapsed >= 3600 ? "\(Int(a.elapsed / 3600)) hr" : "\(max(1, Int(a.elapsed / 60))) min")")
                            .font(.bCaption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func link(_ title: String, shortcut: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text(title); Spacer(); Text(shortcut).font(.bCaption).foregroundStyle(.secondary) }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle()) }
            .buttonStyle(HoverRowStyle()).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var pauseRow: some View {
        let paused = (pausedUntil ?? .distantPast) > Date()
        return Menu {
            Button("For 1 hour") { set(Date().addingTimeInterval(3600)) }
            Button("Until tomorrow morning") { set(Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime)) }
            if paused { Divider(); Button("Resume alerts") { set(nil) } }
        } label: {
            HStack { Text("Pause alerts"); Spacer(); Text(paused ? "until \(pausedUntil!.formatted(date: .omitted, time: .shortened))" : "›").font(.bCaption).foregroundStyle(.secondary) }
                .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(HoverRowStyle()).menuIndicator(.hidden).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func set(_ d: Date?) { Prefs.pauseAlerts(until: d); pausedUntil = d }
}
