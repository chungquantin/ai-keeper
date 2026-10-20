import Foundation
import UserNotifications

/// Small JSON store under ~/Library/Application Support/AIKeeper.
enum Persist {
    static let dir: URL = {
        // Demo mode must never read or write the real caches.
        let base = Demo.enabled ? FileManager.default.temporaryDirectory.appendingPathComponent("AIKeeperDemo", isDirectory: true)
                                : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = Demo.enabled ? base : base.appendingPathComponent("AIKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// Seconds since a stored file was last written, or nil if it doesn't exist.
    static func age(_ name: String) -> TimeInterval? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(d)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: data)
    }
}

enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String, id: String) {
        guard available, UserDefaults.standard.object(forKey: "notify") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

extension UserDefaults {
    func number(_ key: String, default d: Double) -> Double { object(forKey: key) as? Double ?? d }
}
