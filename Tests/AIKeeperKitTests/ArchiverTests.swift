import Foundation
import Testing
@testable import AIKeeperKit

@Suite struct ArchiverTests {
    @Test func picksOnlySessionLogsOlderThanTheCutoff() {
        let h = FakeHome()
        h.file("logs/p1/old.jsonl", "old", ageDays: 100)
        h.file("logs/p1/new.jsonl", "new", ageDays: 5)
        h.file("logs/p2/old.txt", "not a log", ageDays: 100)
        let plan = Archiver.candidates(root: h.path + "/logs", days: 60)
        #expect(plan.files == ["p1/old.jsonl"])
    }

    @Test func archivesThenRemovesAndCanBeUnpacked() throws {
        let h = FakeHome()
        h.file("logs/p1/old.jsonl", "old", ageDays: 100)
        let keep = h.file("logs/p1/new.jsonl", "new", ageDays: 1)
        let plan = Archiver.candidates(root: h.path + "/logs", days: 60)
        let out = h.dir("out")
        let url = try Archiver.archive(plan, id: "claude", into: URL(fileURLWithPath: out)).get()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: h.path + "/logs/p1/old.jsonl"))
        #expect(FileManager.default.fileExists(atPath: keep))
        #expect(Archiver.restore(url, into: h.path + "/logs") == nil)
        #expect(try String(contentsOfFile: h.path + "/logs/p1/old.jsonl", encoding: .utf8) == "old")
    }

    @Test func leavesTheOriginalsAloneWhenTheArchiveCannotBeWritten() {
        let h = FakeHome()
        let f = h.file("logs/p1/old.jsonl", "old", ageDays: 100)
        let bad = Archiver.Plan(root: h.path + "/logs", files: ["p1/old.jsonl", "p1/missing.jsonl"], bytes: 1)
        let r = Archiver.archive(bad, id: "claude", into: URL(fileURLWithPath: h.dir("out")))
        if case .success = r { Issue.record("expected a failure") }
        #expect(FileManager.default.fileExists(atPath: f))
    }

    @Test func nothingOldEnoughIsAnError() {
        let plan = Archiver.Plan(root: "/tmp", files: [], bytes: 0)
        if case .success = Archiver.archive(plan, id: "claude") { Issue.record("expected a failure") }
    }
}
