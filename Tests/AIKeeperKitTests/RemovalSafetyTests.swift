import Foundation
import Testing
@testable import AIKeeperKit

@Suite struct RemovalSafetyTests {
    @Test func refusesHomeAndFoldersDirectlyUnderIt() {
        let h = FakeHome()
        #expect(!Cleaner.isSafeToRemove(path: h.path, home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: h.dir("Documents"), home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: h.dir("Desktop"), home: h.path))
        #expect(Cleaner.isSafeToRemove(path: h.dir("Developer/project"), home: h.path))
    }

    @Test func refusesPathsOutsideHome() {
        let h = FakeHome()
        #expect(!Cleaner.isSafeToRemove(path: "/etc/hosts", home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: "/", home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: h.path + "/../elsewhere/x", home: h.path))
    }

    @Test func doesNotFollowASymlinkOutOfHome() throws {
        let h = FakeHome(), outside = FakeHome()
        let target = outside.dir("secret/data")
        let link = h.path + "/Developer/link"
        try FileManager.default.createDirectory(atPath: h.path + "/Developer", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(!Cleaner.isSafeToRemove(path: link, home: h.path))
    }

    @Test func everyKindOfEntryIsChecked() {
        let h = FakeHome()
        for kind in [Kind.workspace, .cache, .sessionData] {
            var e = other(kind, "x", size: 1)
            e.path = h.path + "/Documents"
            #expect(throws: Cleaner.Failure.self) { try Cleaner.checkRemovable(e, home: h.path) }
            e.path = h.dir("Library/Caches/thing")
            #expect(throws: Never.self) { try Cleaner.checkRemovable(e, home: h.path) }
        }
    }

    @Test func aMainCheckoutIsNotRemovedAsAWorktree() throws {
        let h = FakeHome()
        let checkout = h.dir("Developer/repo")
        try FileManager.default.createDirectory(atPath: checkout + "/.git", withIntermediateDirectories: true)
        var e = workspace("repo", path: checkout)
        e.path = checkout
        #expect(throws: Cleaner.Failure.self) { try Cleaner.checkRemovable(e, home: h.path) }
        // A linked worktree has a .git file, not a folder.
        let wt = h.dir("Developer/wt")
        FileManager.default.createFile(atPath: wt + "/.git", contents: Data("gitdir: /x".utf8))
        e.path = wt
        #expect(throws: Never.self) { try Cleaner.checkRemovable(e, home: h.path) }
    }
}

@Suite struct RestoreTests {
    @Test func putsBackWhatTheTrashTook() {
        let h = FakeHome()
        let trashed = h.file("Trash/proj/file.txt", "hello")
        let r = RestoreRecord(id: UUID().uuidString, date: .now, name: "proj", bytes: 5, path: h.path + "/Developer/proj", trash: (trashed as NSString).deletingLastPathComponent)
        #expect(RestoreLog.restore(r, home: h.path) == nil)
        #expect(FileManager.default.fileExists(atPath: h.path + "/Developer/proj/file.txt"))
    }

    @Test func refusesToOverwriteWhatIsAlreadyThere() {
        let h = FakeHome()
        let trashed = h.dir("Trash/proj"), there = h.dir("Developer/proj")
        let r = RestoreRecord(id: "1", date: .now, name: "proj", bytes: 1, path: there, trash: trashed)
        #expect(RestoreLog.restore(r, home: h.path) != nil)
    }

    @Test func refusesARecordPointingOutsideHome() {
        let h = FakeHome()
        let r = RestoreRecord(id: "2", date: .now, name: "evil", bytes: 1, path: "/etc/evil", trash: h.dir("Trash/evil"))
        #expect(RestoreLog.restore(r, home: h.path) != nil)
        #expect(!FileManager.default.fileExists(atPath: "/etc/evil"))
    }

    @Test func recreatesAWorktreeFromItsBranch() {
        let h = FakeHome()
        let repo = h.dir("Developer/repo")
        func git(_ args: [String]) -> Int32 { Shell.run("/usr/bin/git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com"] + args).status }
        #expect(git(["init", "-q", "-b", "main"]) == 0)
        h.file("Developer/repo/a.txt")
        #expect(git(["add", "."]) == 0)
        #expect(git(["commit", "-q", "-m", "init"]) == 0)
        let wt = h.path + "/Developer/repo-wt"
        #expect(git(["worktree", "add", "-q", "-b", "feature", wt]) == 0)
        #expect(git(["worktree", "remove", "--force", wt]) == 0)
        let r = RestoreRecord(id: "3", date: .now, name: "repo-wt", bytes: 1, path: wt, trash: nil, repo: repo, branch: "feature")
        #expect(r.canRestore)
        #expect(RestoreLog.restore(r, home: h.path) == nil)
        #expect(FileManager.default.fileExists(atPath: wt + "/a.txt"))
    }

    @Test func aRecordWithNeitherTrashNorBranchCannotBeRestored() {
        #expect(!RestoreRecord(id: "4", date: .now, name: "x", bytes: 1, path: "/x").canRestore)
    }
}

@Suite struct AppAndFileTests {
    @Test func allowsAnAppBundleDirectlyInApplicationsOnly() {
        let h = FakeHome()
        #expect(Cleaner.isSafeToRemove(path: "/Applications/Example.app", home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: "/Applications", home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: "/Applications/Utilities/Terminal.app", home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: "/Applications/Example.app/Contents", home: h.path))
        #expect(!Cleaner.isSafeToRemove(path: "/Applications/readme.txt", home: h.path))
    }

    @Test func installersInDownloadsAreRebuildableAndOtherFilesAreOnlyHere() {
        let dmg = BigFile(path: home + "/Downloads/Xcode.dmg", bytes: 1, opened: nil, inCloud: false)
        let mov = BigFile(path: home + "/Movies/a.mov", bytes: 1, opened: nil, inCloud: false)
        let cloud = BigFile(path: home + "/Documents/a.zip", bytes: 1, opened: nil, inCloud: true)
        #expect(dmg.tier == .rebuildable && mov.tier == .onlyHere && cloud.tier == .onRemote)
        #expect(mov.kind == .movie && dmg.kind == .image)
    }

    @Test func unusedAppsNeedAnOldLastOpenedDate() {
        let old = app(Date().addingTimeInterval(-200 * 86_400)), fresh = app(Date())
        #expect(old.notOpened(forDays: 90) && !fresh.notOpened(forDays: 90))
    }
}

private func app(_ opened: Date) -> InstalledApp {
    var a = InstalledApp(name: "Example", path: "/Applications/Example.app", bundleID: "com.example.app", version: "1", source: .download)
    a.lastOpened = opened
    return a
}
