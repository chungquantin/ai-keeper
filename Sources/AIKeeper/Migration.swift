import Foundation

/// The bundle ID changed from co.architect.ai-keeper to chungquantin.ai-keeper. macOS stores settings per bundle ID,
/// so without this everyone would see onboarding again and lose their thresholds and budgets.
/// Runs once, only copies keys that are not already set, and never touches the old settings.
enum Migration {
    static let newID = "chungquantin.ai-keeper"
    static let oldID = "co.architect.ai-keeper"
    static let marker = "migratedFromOldBundleID"

    static let keys = [
        "onboarded", "tools.enabled", "repo.roots", "staleDays", "guard.floorGB", "guard.rateGB",
        "notify", "notify.agents", "budget.daily", "budget.weekly", "vault.days",
    ]

    static func run(defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard bundleID == newID, !defaults.bool(forKey: marker) else { return }
        defer { defaults.set(true, forKey: marker) }
        guard let old = UserDefaults(suiteName: oldID) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
}
