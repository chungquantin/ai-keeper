import Darwin
import Foundation

/// `keeper update`: finds the latest release and installs it. This is the only thing in AI Keeper that touches the network
/// by itself, and it runs only when you type it.
///
/// Homebrew installs are upgraded with `brew`. Anything else (the zip, the install script) is replaced in place: the zip is
/// downloaded from this repository's GitHub release, checked against the SHA-256 published with it, checked again with
/// `codesign`, and only then swapped in, keeping the old app until the new one is in place.
enum UpdateCommands {
    static var all: [Command] { [update] }

    // MARK: Versions

    /// "v0.2.2" or "0.2.2" as numbers, or nil when it is not a plain release version.
    static func components(_ v: String) -> [Int]? {
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...4).contains(parts.count), !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// True when `latest` is a higher release than `current`. nil when either is not a release version.
    static func isNewer(_ latest: String, than current: String) -> Bool? {
        guard var a = components(latest), var b = components(current) else { return nil }
        while a.count < 4 { a.append(0) }
        while b.count < 4 { b.append(0) }
        return a.lexicographicallyPrecedes(b) ? false : a != b
    }

    // MARK: Where things are

    private static let repo = "chungquantin/ai-keeper"
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// The three overrides below exist so the tests can run against local files. They are not documented settings.
    private static var latestPage: String { env["AIKEEPER_UPDATE_PAGE"] ?? "https://github.com/\(repo)/releases/latest" }
    private static var downloadBase: String { env["AIKEEPER_UPDATE_BASE"] ?? "https://github.com/\(repo)/releases/download" }

    /// The app that would be replaced: the one this binary lives in. nil for a development build.
    static func installedApp() -> String? {
        if let forced = env["AIKEEPER_UPDATE_APP"], !forced.isEmpty { return forced }
        guard !Runtime.executable.isEmpty else { return nil }
        let app = URL(fileURLWithPath: Runtime.executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app.path : nil
    }

    static func version(ofApp path: String) -> String? {
        (NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    private static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private static func managedByHomebrew() -> Bool {
        guard let brew = brewPath() else { return false }
        return Shell.run(brew, ["list", "--cask", "ai-keeper"]).status == 0
    }

    /// The newest published release (never a draft or pre-release): GitHub's "latest" page redirects to its tag.
    static func latestRelease() -> String? {
        if let forced = env["AIKEEPER_UPDATE_LATEST"] { return components(forced) == nil ? nil : forced }
        let r = Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "20", "-o", "/dev/null", "-w", "%{url_effective}", latestPage])
        guard r.status == 0, let tag = r.out.split(separator: "/").last.map(String.init), components(tag) != nil else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // MARK: Doing it

    /// Runs a program with this terminal's input and output, so progress bars and `brew`'s own messages show.
    private static func runVisible(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// True when the app at `app` is running. Only that copy matters: another AI Keeper elsewhere is not in the way.
    private static func appIsOpen(_ app: String) -> Bool {
        let pattern = NSRegularExpression.escapedPattern(for: app + "/Contents/MacOS/") + "AIKeeper"
        return Shell.run("/usr/bin/pgrep", ["-f", "--", pattern]).out.split(separator: "\n").compactMap { Int32($0) }.contains { $0 != getpid() }
    }

    /// Downloads, verifies and swaps the app. Returns nil on success, or what went wrong. Nothing changes until every check has passed.
    private static func installDirect(version v: String, app: String) -> String? {
        guard components(v) != nil else { return "'\(v)' is not a release version." }
        let fm = FileManager.default
        if appIsOpen(app) { return "AI Keeper is open. Quit it first, then run this again." }
        let parent = (app as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else { return "I can't write to \(parent). Run it with sudo, or install the app somewhere you own." }

        let tmp = NSTemporaryDirectory() + "keeper-update-\(getpid())"
        try? fm.removeItem(atPath: tmp)
        do { try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true) } catch { return "Couldn't create a temporary folder: \(error.localizedDescription)" }
        defer { try? fm.removeItem(atPath: tmp) }

        let name = "AI-Keeper-\(v).zip", url = "\(downloadBase)/v\(v)/\(name)", zip = "\(tmp)/\(name)"
        Out.note("Downloading \(name)…")
        let progress = Term.errTTY ? "--progress-bar" : "-sS"
        guard runVisible("/usr/bin/curl", ["-fL", progress, "--max-time", "600", "-o", zip, url]) == 0 else { return "Couldn't download \(url)." }
        guard Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "30", "-o", zip + ".sha256", url + ".sha256"]).status == 0,
              let published = try? String(contentsOfFile: zip + ".sha256", encoding: .utf8) else { return "Couldn't download the checksum for \(name), so I won't install it." }

        // The release publishes just the hash, or "hash  filename".
        let want = String(published.split(whereSeparator: { $0.isWhitespace }).first ?? "").lowercased()
        let got = Shell.run("/usr/bin/shasum", ["-a", "256", zip]).out.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        guard want.count == 64, want == got else { return "The download does not match its published checksum. Nothing was installed." }

        let unpacked = tmp + "/unpacked"
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip, unpacked]).status == 0 else { return "Couldn't unpack the download." }
        let fresh = unpacked + "/AI Keeper.app"
        guard fm.fileExists(atPath: fresh) else { return "The download did not contain AI Keeper.app." }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh]).status == 0 else { return "The new app's signature does not verify. Nothing was installed." }
        guard version(ofApp: fresh) == v else { return "The download says it is version \(version(ofApp: fresh) ?? "unknown"), not \(v). Nothing was installed." }

        // Swap, keeping the old app until the new one is in place.
        let backup = app + ".update-old"
        try? fm.removeItem(atPath: backup)
        do { try fm.moveItem(atPath: app, toPath: backup) } catch { return "Couldn't move the old app aside: \(error.localizedDescription)" }
        if Shell.run("/usr/bin/ditto", [fresh, app]).status != 0 {
            try? fm.removeItem(atPath: app)
            try? fm.moveItem(atPath: backup, toPath: app)
            return "Couldn't copy the new app into place. Your old version is back where it was."
        }
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app])
        try? fm.removeItem(atPath: backup)
        return nil
    }

    private static func finish(_ a: Args, current: String, latest: String, updated: Bool, method: String, app: String?, error: String? = nil) -> Int32 {
        if a.json {
            var o: [String: Any] = ["current_version": current, "latest_version": latest, "update_available": isNewer(latest, than: current) == true,
                                    "updated": updated, "method": method]
            if let app { o["app"] = app }
            if let error { o["error"] = error }
            Out.json(o)
        }
        return error == nil ? 0 : 1
    }

    static let update = Command(
        name: "update", aliases: ["upgrade"], group: "Setup", summary: "Check for a newer release and install it",
        usage: ["keeper update [--check] [--yes] [--direct] [--json]", "",
                "  Looks for the latest release on GitHub. This is the only command that uses the network, and only when you run it.",
                "  Without --yes it shows what it found and asks before installing. In a script, add --yes.",
                "  --check    Only report whether a newer version exists. Installs nothing.",
                "  --direct   Download the release yourself instead of using Homebrew, even if Homebrew installed the app.",
                "",
                "  Homebrew installs are upgraded with `brew`. Others are downloaded from the release, checked against its",
                "  published SHA-256 and its signature, then swapped in; the old app is kept until the new one is in place."],
        flags: ["check", "direct"],
        run: { a in
            guard let app = installedApp() else {
                Out.fail("this is not an installed copy of the app (a development build?), so there is nothing to update. Build it again, or install a release.")
                return 1
            }
            guard let current = version(ofApp: app), components(current) != nil else {
                Out.fail("I couldn't read the installed version from \(Fmt.tilde(app)).")
                return 1
            }
            Out.note("Checking for updates…")
            guard let latest = latestRelease() else {
                Out.fail("couldn't find the latest release. Check your connection, and that https://github.com/\(repo)/releases has a release.")
                return finish(a, current: current, latest: "", updated: false, method: "none", app: app, error: "latest release not found")
            }
            guard isNewer(latest, than: current) == true else {
                if a.json { _ = finish(a, current: current, latest: latest, updated: false, method: "none", app: app) }
                else { Out.line("AI Keeper \(Term.bold(current)) is up to date.") }
                return 0
            }
            let brew = !a.flag("direct") && env["AIKEEPER_UPDATE_APP"] == nil && managedByHomebrew()
            let method = brew ? "homebrew" : "direct"
            if !a.json {
                Out.line("A new version is available: \(Term.dim(current)) → \(Term.bold(latest))")
                Out.line(Term.dim("Release notes: https://github.com/\(repo)/releases/tag/v\(latest)"))
            }
            if a.flag("check") { return finish(a, current: current, latest: latest, updated: false, method: method, app: app) }

            if !a.yes {
                guard isatty(STDIN_FILENO) != 0, Term.errTTY else {
                    if a.json { _ = finish(a, current: current, latest: latest, updated: false, method: method, app: app) }
                    else { Out.line(Term.dim("\nNothing was changed. Add --yes to install it.")) }
                    return 0
                }
                FileHandle.standardError.write(Data("Install it now (\(brew ? "with Homebrew" : "downloaded from GitHub"))? [y/N] ".utf8))
                guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else { Out.line(Term.dim("Nothing was changed.")); return 0 }
            }

            if brew, let b = brewPath() {
                if appIsOpen(app) { Out.fail("AI Keeper is open. Quit it first, then run this again."); return 1 }
                Out.note("Updating Homebrew…")
                _ = runVisible(b, ["update", "--quiet"])
                guard runVisible(b, ["upgrade", "--cask", "chungquantin/ai-keeper/ai-keeper"]) == 0 else {
                    Out.fail("Homebrew could not upgrade it. Try `brew upgrade --cask ai-keeper`, or run `keeper update --direct`.")
                    return finish(a, current: current, latest: latest, updated: false, method: method, app: app, error: "brew upgrade failed")
                }
                let now = version(ofApp: app) ?? current
                guard isNewer(now, than: current) == true else {
                    Out.fail("Homebrew has not picked up \(latest) yet. Wait a minute and try again, or run `keeper update --direct`.")
                    return finish(a, current: current, latest: latest, updated: false, method: method, app: app, error: "cask not updated yet")
                }
                if !a.json { Out.line("Updated AI Keeper \(Term.dim(current)) → \(Term.bold(now)). Open the app again to use it.") }
                return finish(a, current: current, latest: latest, updated: true, method: method, app: app)
            }

            if let problem = installDirect(version: latest, app: app) {
                Out.fail(problem)
                return finish(a, current: current, latest: latest, updated: false, method: method, app: app, error: problem)
            }
            if !a.json { Out.line("Updated AI Keeper \(Term.dim(current)) → \(Term.bold(latest)). Open the app again to use it.") }
            return finish(a, current: current, latest: latest, updated: true, method: method, app: app)
        })
}
