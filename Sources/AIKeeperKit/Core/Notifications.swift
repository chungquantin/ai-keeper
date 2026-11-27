import AppKit
import UserNotifications

/// What a notification is about. Each kind has its own buttons, so the common fixes happen without opening the window.
enum NotificationKind: String, CaseIterable {
    case general, disk, agent, budget, rule, digest

    var categoryID: String { "keeper.\(rawValue)" }

    var actions: [NotificationAction] {
        switch self {
        case .general: []
        case .disk: [.clearBuild, .open]
        case .agent: [.openSession, .later]
        case .budget: [.raiseBudget, .seeSpend]
        case .rule: [.undoClean, .review]
        case .digest: [.undoClean, .review]
        }
    }

    /// Where a click on the notification itself goes.
    var destination: Destination {
        switch self {
        case .general, .digest: .today
        case .disk, .rule: .review
        case .agent: .live
        case .budget: .cost
        }
    }
}

enum NotificationAction: String {
    case clearBuild, open, openSession, later, raiseBudget, seeSpend, undoClean, review

    var title: String {
        switch self {
        case .clearBuild: "Clear build folders"
        case .open: "Open"
        case .openSession: "Open session"
        case .later: "Not now"
        case .raiseBudget: "Raise budget"
        case .seeSpend: "See where it went"
        case .undoClean: "Undo clean"
        case .review: "Review"
        }
    }
    var id: String { "keeper.action.\(rawValue)" }
    /// Buttons that only dismiss never need to wake the window.
    var dismisses: Bool { self == .later }
    static func from(_ identifier: String) -> NotificationAction? { Self.allCases.first { $0.id == identifier } }
    static let allCases: [NotificationAction] = [.clearBuild, .open, .openSession, .later, .raiseBudget, .seeSpend, .undoClean, .review]
}

enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Registers the buttons for each kind and makes the app the one that answers them. Call once at launch.
    static func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationHandler.shared
        center.setNotificationCategories(Set(NotificationKind.allCases.filter { !$0.actions.isEmpty }.map { kind in
            UNNotificationCategory(identifier: kind.categoryID,
                                   actions: kind.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: $0.dismisses ? [] : [.foreground]) },
                                   intentIdentifiers: [])
        }))
    }

    static func send(_ title: String, _ body: String, id: String, kind: NotificationKind = .general) {
        guard available, Prefs.notify, !Prefs.alertsPaused() else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if !kind.actions.isEmpty { c.categoryIdentifier = kind.categoryID }
        c.userInfo = ["kind": kind.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

/// Answers a click on a notification or one of its buttons.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationHandler()

    /// Show the banner even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let kind = NotificationKind(rawValue: response.notification.request.content.userInfo["kind"] as? String ?? "") ?? .general
        let action = NotificationAction.from(response.actionIdentifier)
        await MainActor.run { NotificationRouter.handle(action, kind: kind) }
    }
}

@MainActor
enum NotificationRouter {
    static func handle(_ action: NotificationAction?, kind: NotificationKind) {
        guard let store = Store.current else { return }
        switch action {
        case .later: return
        case .clearBuild: store.clearBuildFolders()
        case .raiseBudget: store.raiseDailyBudget()
        case .undoClean: store.undoRecentCleaning()
        case .openSession: store.requestedDestination = .live
        case .seeSpend: store.requestedDestination = .cost
        case .review: store.requestedDestination = .review
        case .open: store.requestedDestination = kind.destination
        case nil: store.requestedDestination = kind.destination   // the notification itself was clicked
        }
        // With the window closed (the app lives in the menu bar) opening the app again brings it back.
        if NSApp.windows.filter({ $0.isVisible && $0.canBecomeMain }).isEmpty { NSWorkspace.shared.open(Bundle.main.bundleURL) }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: What the buttons do

extension Store {
    /// "Clear build folders": every build folder in a workspace nobody is using. Deleted now, since the next build recreates them.
    func clearBuildFolders() {
        let entries = (reclaimItems.first { $0.kind == .buildFolders }?.entries ?? []).filter { runningAgents(in: $0).isEmpty }
        guard !entries.isEmpty else { return }
        var plan = Basket.Plan(); plan.purge = entries
        reclaim(plan, deleteNow: true)
    }

    func raiseDailyBudget() {
        let d = Prefs.budgetDaily
        guard d > 0 else { return }
        Prefs.defaults.set(Prefs.raised(d), forKey: Prefs.Key.budgetDaily)
    }

    /// Puts back what was removed in the last day, from the Trash or from each branch on the remote.
    func undoRecentCleaning(within hours: Double = 24) {
        let since = Date().addingTimeInterval(-hours * 3600)
        let records = RestoreLog.all().filter { $0.date >= since && $0.canRestore }
        guard !records.isEmpty else { return }
        Task {
            _ = await Task.detached(priority: .userInitiated) { records.compactMap { RestoreLog.restore($0) } }.value
            await rescan()
        }
    }
}

// MARK: Weekly digest

enum Digest {
    /// "2026-W48": one value per calendar week, so the digest goes out once a week.
    static func weekID(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }

    /// Friday from 5 pm, once per week.
    static func isDue(now: Date, lastWeek: String?, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour], from: now)
        guard c.weekday == 6, (c.hour ?? 0) >= 17 else { return false }
        return lastWeek != weekID(now, calendar: calendar)
    }

    @MainActor static func tick(_ store: Store, now: Date = Date()) {
        guard Prefs.digestEnabled, Prefs.notify else { return }
        guard isDue(now: now, lastWeek: Prefs.defaults.string(forKey: Prefs.Key.lastDigestWeek)) else { return }
        Prefs.defaults.set(weekID(now), forKey: Prefs.Key.lastDigestWeek)
        let since = now.addingTimeInterval(-7 * 86_400)
        let freed = CleanLog.all().filter { $0.date >= since }.reduce(Int64(0)) { $0 + $1.bytes }
        var line = freed > 0 ? "Reclaimed \(freed.bytesString) and spent " : "Spent "
        line += String(format: "$%.0f", store.spentWeek) + " in the last 7 days."
        if !store.advice.tips.isEmpty { line += " \(store.advice.tips.count) suggestion\(store.advice.tips.count == 1 ? "" : "s") waiting." }
        Notifier.send("Your week in AI Keeper", line, id: "digest.\(weekID(now))", kind: .digest)
    }
}
