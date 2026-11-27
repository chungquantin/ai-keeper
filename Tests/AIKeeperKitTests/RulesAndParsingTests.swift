import Foundation
import Testing
@testable import AIKeeperKit

@MainActor @Suite struct RuleTests {
    func store(_ entries: [Entry]) -> Store {
        TestEnv.ready()
        let s = Store()
        s.entries = entries
        return s
    }

    @Test func buildFolderRuleOnlyTakesWorkspacesIdleForLongEnough() {
        let gb = TierTests.gb
        let old = workspace("old", pr: pr(1, "OPEN"), size: 4 * gb, last: daysAgo(30), artifacts: [Artifact(path: "/Users/test/work/old/target", bytes: gb)])
        let fresh = workspace("fresh", pr: pr(2, "OPEN"), size: 4 * gb, last: daysAgo(2), artifacts: [Artifact(path: "/Users/test/work/fresh/target", bytes: gb)])
        let p = RuleEngine.preview(CleanRule(kind: .buildFolders, days: 14, gb: 60), store: store([old, fresh]))
        #expect(p.plan.purge.map(\.name) == ["old"])
        #expect(p.bytes == gb)
    }

    @Test func mergedWorkspaceRuleAsksFirstAboveTheSizeLimit() {
        let gb = TierTests.gb
        let small = workspace("small", pr: pr(1, "MERGED", mergedAgo: 5), size: 2 * gb, last: daysAgo(5))
        let big = workspace("big", pr: pr(2, "MERGED", mergedAgo: 5), size: 9 * gb, last: daysAgo(5))
        let p = RuleEngine.preview(CleanRule(kind: .mergedWorkspaces, days: 3, gb: 5), store: store([small, big]))
        #expect(p.plan.removeSafe.map(\.name) == ["small"])
        #expect(p.askFirst == 9 * gb)
    }

    @Test func mergedWorkspaceRuleWaitsForItsDelay() {
        let w = workspace("w", pr: pr(1, "MERGED", mergedAgo: 1), size: TierTests.gb, last: daysAgo(1))
        #expect(RuleEngine.preview(CleanRule(kind: .mergedWorkspaces, days: 3, gb: 5), store: store([w])).plan.isEmpty)
    }

    @Test func rulesNeverTouchOnlyHere() {
        let dirty = workspace("dirty", git: GitInfo(dirtyCount: 1), size: TierTests.gb, last: daysAgo(90))
        for kind in [CleanRule.Kind.buildFolders, .mergedWorkspaces] {
            #expect(RuleEngine.preview(CleanRule(kind: kind, days: 0, gb: 100), store: store([dirty])).plan.isEmpty)
        }
    }

    @Test func everyRuleStartsOff() {
        #expect(CleanRule.defaults.allSatisfy { !$0.enabled })
    }
}

@Suite struct ParsingTests {
    @Test func dockerSizes() {
        #expect(DockerCLI.parseBytes("12.5GB (45%)") == 12_500_000_000)
        #expect(DockerCLI.parseBytes("340MB") == 340_000_000)
        #expect(DockerCLI.parseBytes("0B") == 0)
        #expect(DockerCLI.parseBytes("") == 0)
    }

    @Test func logTimestamps() {
        let d = FastDate.parse("2026-10-11T08:04:27.796Z")
        let ref = ISO8601DateFormatter(); ref.formatOptions = [.withInternetDateTime]
        #expect(d != nil)
        #expect(abs(d!.timeIntervalSince(ref.date(from: "2026-10-11T08:04:27Z")!) - 0.796) < 0.01)
        #expect(FastDate.parse("nonsense") == nil)
    }

    @Test func cleanupStreaks() {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        func rec(_ back: Int) -> CleanRecord { CleanRecord(date: cal.date(byAdding: .day, value: -back, to: today)!.addingTimeInterval(3600), bytes: 1, items: 1, kind: "x") }
        let s = CleanLog.summary([rec(0), rec(1), rec(2), rec(10), rec(11)])
        #expect(s.currentStreak == 3)
        #expect(s.longestStreak == 3)
        #expect(s.activeDays == 5)
        #expect(CleanLog.summary([rec(5)]).currentStreak == 0)
    }

    @Test func byteStringsSplitNumberAndUnit() {
        let p = Int64(96_610_000_000).byteParts
        #expect(p.unit == "GB")
        #expect(!p.number.isEmpty)
    }
}
