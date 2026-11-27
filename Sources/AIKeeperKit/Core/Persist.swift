import Foundation
import UserNotifications

/// Small JSON store under ~/Library/Application Support/AIKeeper.
enum Persist {
    static let dir: URL = {
        // Demo mode must never read or write the real caches.
        // AIKEEPER_DATA points everything at another folder: how the tests run without touching your real scan or vault.
        if let custom = ProcessInfo.processInfo.environment["AIKEEPER_DATA"], !custom.isEmpty {
            let u = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return u
        }
        let base = Demo.enabled ? FileManager.default.temporaryDirectory.appendingPathComponent("AIKeeperDemo", isDirectory: true)
                                : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = Demo.enabled ? base : base.appendingPathComponent("AIKeeper", isDirectory: true)
        // Paths, session titles and recovery snapshots live here: readable by this user only.
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
        return u
    }()

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let url = dir.appendingPathComponent(name)
        try? enc.encode(value).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Seconds since a stored file was last written, or nil if it doesn't exist.
    static func age(_ name: String) -> TimeInterval? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(d)
    }

    /// Reads a saved file. If it exists but cannot be decoded (an older or newer format, a half-written file), the bytes are kept as
    /// `<name>.corrupt` and a line is printed, instead of the next save quietly replacing the user's data with defaults.
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do { return try dec.decode(type, from: data) }
        catch {
            try? data.write(to: dir.appendingPathComponent(name + ".corrupt"), options: .atomic)
            FileHandle.standardError.write(Data("AI Keeper: \(name) could not be read (\(error)). Kept a copy as \(name).corrupt.\n".utf8))
            return nil
        }
    }
}

extension UserDefaults {
    func number(_ key: String, default d: Double) -> Double { object(forKey: key) as? Double ?? d }
}
