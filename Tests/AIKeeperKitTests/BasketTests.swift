import Foundation
import Testing
@testable import AIKeeperKit

@MainActor @Suite struct BasketTests {
    func items() -> [ReclaimItem] {
        let gb = TierTests.gb
        return ReclaimPlanner.items(Stats([
            workspace("merged1", pr: pr(1, "MERGED", mergedAgo: 3), size: 3 * gb, last: daysAgo(3), artifacts: [Artifact(path: "/Users/test/work/merged1/target", bytes: gb)]),
            workspace("merged2", pr: pr(2, "MERGED", mergedAgo: 3), size: 2 * gb, last: daysAgo(3)),
            workspace("dirty", git: GitInfo(dirtyCount: 1), size: 4 * gb, last: daysAgo(40)),
            workspace("active", pr: pr(3, "OPEN"), size: 5 * gb, last: daysAgo(1), artifacts: [Artifact(path: "/Users/test/work/active/target", bytes: 2 * gb)]),
        ]))
    }

    @Test func safeTiersStartTickedAndOnlyHereDoesNot() {
        let b = Basket()
        for i in items() { #expect(b.contains(i) == i.tier.isSafe) }
    }

    @Test func totalCountsOnlyTickedItems() {
        let b = Basket(), gb = TierTests.gb
        #expect(b.total(items()) == (5 + 2) * gb)     // merged 3+2, active's build folders 2
    }

    @Test func tickingOnlyHereAddsItAndUntickingASafeItemRemovesIt() {
        let b = Basket(), all = items()
        let risky = all.first { $0.kind == .uncommitted }!, merged = all.first { $0.kind == .merged }!
        b.toggle(risky); b.toggle(merged)
        #expect(b.contains(risky))
        #expect(!b.contains(merged))
        #expect(b.total(all) == (4 + 2) * TierTests.gb)
    }

    @Test func planSeparatesBuildFoldersSafeRemovalsAndRiskyRemovals() {
        let b = Basket(), all = items()
        var p = b.plan(all)
        #expect(p.purge.map(\.name) == ["active"])
        #expect(Set(p.removeSafe.map(\.name)) == ["merged1", "merged2"])
        #expect(p.removeRisky.isEmpty)
        b.toggle(all.first { $0.kind == .uncommitted }!)
        p = b.plan(all)
        #expect(p.removeRisky.map(\.name) == ["dirty"])
    }

    @Test func excludedEntriesStayOut() {
        let b = Basket(), all = items()
        let merged = all.first { $0.kind == .merged }!
        b.toggleEntry(merged.entries.first { $0.name == "merged2" }!)
        #expect(b.plan(all).removeSafe.map(\.name) == ["merged1"])
    }

    @Test func buildOnlyTurnsARemovalIntoACleanOfBuildFolders() {
        let b = Basket(), all = items()
        let m1 = all.first { $0.kind == .merged }!.entries.first { $0.name == "merged1" }!
        b.toggleBuildOnly(m1)
        let p = b.plan(all)
        #expect(Set(p.purge.map(\.name)) == ["active", "merged1"])
        #expect(p.removeSafe.map(\.name) == ["merged2"])
        #expect(b.bytes(all.first { $0.kind == .merged }!) == (1 + 2) * TierTests.gb)
    }

    @Test func tickingOneEntryInsideAnUntickedItemTicksOnlyThatEntry() {
        let b = Basket(), all = items()
        let risky = all.first { $0.kind == .uncommitted }!
        b.tick(risky.entries[0], in: risky)
        #expect(b.contains(risky))
        #expect(b.isOn(risky.entries[0], in: risky))
    }

    @Test func resetReturnsToTheSafeDefault() {
        let b = Basket(), all = items()
        b.toggle(all.first { $0.kind == .uncommitted }!); b.toggle(all.first { $0.kind == .merged }!)
        b.resetToSafe()
        for i in all { #expect(b.contains(i) == i.tier.isSafe) }
    }
}
