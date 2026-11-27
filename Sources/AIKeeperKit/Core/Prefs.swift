import Foundation

/// Every preference key in one place, with its default. The window, the `keeper` command and the MCP server all read the same values,
/// so a key typed differently in two places would quietly give them different answers.
enum Prefs {
    enum Key {
        static let guardFloorGB = "guard.floorGB"
        static let guardRateGB = "guard.rateGB"
        static let notify = "notify"
        static let notifyAgents = "notify.agents"
        static let budgetDaily = "budget.daily"
        static let budgetWeekly = "budget.weekly"
        static let vaultDays = "vault.days"
        static let staleDays = "staleDays"
        static let reclaimDeleteNow = "reclaim.deleteNow"
        static let rulesNotify = "rules.notify"
        static let showMenuBar = "menubar.show"
        static let menuBarContent = "menubar.content"
        static let showDockIcon = "dock.show"
        static let scanEveryHours = "scan.everyHours"
        static let scanOnBattery = "scan.onBattery"
        static let keepFolders = "cleanup.keepFolders"
        static let alertsPausedUntil = "alerts.pausedUntil"
        static let digestEnabled = "digest.enabled"
        static let lastDigestWeek = "digest.lastWeek"
        static func agentBudget(_ id: String) -> String { "budget.agent.\(id)" }
        static func keepDays(_ id: String) -> String { "keep.\(id)" }
    }

    enum Default {
        static let guardFloorGB = 50.0
        static let guardRateGB = 10.0
        static let vaultDays = 30
        static let staleDays = 14
        static let keepDays = 60
        static let scanEveryHours = 6
    }

    /// What the menu bar item says next to its icon.
    enum MenuBarContent: String, CaseIterable, Identifiable {
        case safe, spend, iconOnly
        var id: String { rawValue }
        var title: String { switch self { case .safe: "Safe to reclaim"; case .spend: "Today's spend"; case .iconOnly: "Icon only" } }
    }

    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static func number(_ key: String, default d: Double) -> Double { defaults.object(forKey: key) as? Double ?? d }
    static func flag(_ key: String, default d: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? d }

    static var guardFloorGB: Double { number(Key.guardFloorGB, default: Default.guardFloorGB) }
    static var guardRateGB: Double { number(Key.guardRateGB, default: Default.guardRateGB) }
    static var budgetDaily: Double { number(Key.budgetDaily, default: 0) }
    static var budgetWeekly: Double { number(Key.budgetWeekly, default: 0) }
    static var vaultDays: Int { Int(number(Key.vaultDays, default: Double(Default.vaultDays))) }
    static var staleDays: Int { let v = defaults.integer(forKey: Key.staleDays); return v == 0 ? Default.staleDays : v }
    static var notify: Bool { flag(Key.notify, default: true) }
    static var notifyAgents: Bool { flag(Key.notifyAgents, default: true) }
    static var showMenuBar: Bool { flag(Key.showMenuBar, default: true) }
    static var showDockIcon: Bool { flag(Key.showDockIcon, default: true) }
    static var scanOnBattery: Bool { flag(Key.scanOnBattery, default: true) }
    static var digestEnabled: Bool { flag(Key.digestEnabled, default: true) }
    /// 0 means "only when I ask".
    static var scanEveryHours: Int { let v = defaults.object(forKey: Key.scanEveryHours) as? Int; return v ?? Default.scanEveryHours }
    static var menuBarContent: MenuBarContent { MenuBarContent(rawValue: defaults.string(forKey: Key.menuBarContent) ?? "") ?? .safe }
    /// Folders the user wants left out of every cleanup list, rule and basket.
    static var keepFolders: [String] { defaults.stringArray(forKey: Key.keepFolders) ?? [] }

    /// Notifications are held back until this moment.
    static var alertsPausedUntil: Date? {
        let t = defaults.double(forKey: Key.alertsPausedUntil)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func alertsPaused(now: Date = Date()) -> Bool { (alertsPausedUntil ?? .distantPast) > now }
    static func pauseAlerts(until d: Date?) { defaults.set(d?.timeIntervalSince1970 ?? 0, forKey: Key.alertsPausedUntil) }

    /// A bigger daily budget for the "Raise budget" notification button: 25% more, to the next $5.
    static func raised(_ budget: Double) -> Double { max(5, (budget * 1.25 / 5).rounded(.up) * 5) }

    /// True when `path` is one of the folders to keep, or sits inside one.
    static func isKept(_ path: String, keep: [String]) -> Bool {
        keep.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
    static func keepDays(_ id: String) -> Int { let v = defaults.integer(forKey: Key.keepDays(id)); return v == 0 ? Default.keepDays : v }
}
