import Foundation
import Testing
@testable import AIKeeperKit

@Suite struct TierTests {
    static let gb: Int64 = 1_000_000_000

    /// merged 3, dirty-and-stale 2, unpushed 1, cache 1, leftovers 4, an active workspace with 2 GB of build output.
    func sample() -> [Entry] {
        [
            workspace("merged", git: GitInfo(), pr: pr(1, "MERGED", mergedAgo: 3), size: 3 * Self.gb, last: daysAgo(3)),
            workspace("dirty", git: GitInfo(dirtyCount: 2), size: 2 * Self.gb, last: daysAgo(40)),
            workspace("lonely", git: GitInfo(unpushed: 4), size: 1 * Self.gb, last: daysAgo(40)),
            other(.cache, "cache", size: 1 * Self.gb),
            other(.sessionData, "orphan", size: 4 * Self.gb),
            workspace("active", pr: pr(2, "OPEN"), size: 6 * Self.gb, last: daysAgo(1),
                      artifacts: [Artifact(path: "/Users/test/work/active/target", bytes: 2 * Self.gb)]),
        ]
    }

    @Test func statsSplitBytesByWhatLosingThemWouldCost() {
        let s = Stats(sample())
        #expect(s.remoteBytes == 3 * Self.gb)
        #expect(s.onlyHereBytes == (2 + 1 + 4) * Self.gb)
        #expect(s.rebuildBytes == (2 + 1) * Self.gb)          // active workspace's build folders + the cache
        #expect(s.safeBytes == 6 * Self.gb)
    }

    @Test func plannerGroupsEntriesIntoTiers() {
        let items = ReclaimPlanner.items(Stats(sample()))
        func item(_ k: ReclaimItem.Kind) -> ReclaimItem? { items.first { $0.kind == k } }
        #expect(item(.buildFolders)?.tier == .rebuildable)
        #expect(item(.buildFolders)?.bytes == 2 * Self.gb)
        #expect(item(.caches)?.tier == .rebuildable)
        #expect(item(.merged)?.tier == .onRemote)
        #expect(item(.merged)?.entries.map(\.name) == ["merged"])
        #expect(item(.uncommitted)?.entries.map(\.name) == ["dirty"])
        #expect(item(.unpushed)?.entries.map(\.name) == ["lonely"])
        #expect(item(.leftovers)?.tier == .onlyHere)
    }

    @Test func aWorkspaceBeingRemovedIsNotAlsoCountedAsBuildOutput() {
        let m = workspace("m", pr: pr(3, "MERGED", mergedAgo: 1), size: 5 * Self.gb, last: daysAgo(1),
                          artifacts: [Artifact(path: "/Users/test/work/m/target", bytes: 3 * Self.gb)])
        let items = ReclaimPlanner.items(Stats([m]))
        #expect(items.first { $0.kind == .buildFolders } == nil)
        #expect(items.first { $0.kind == .merged }?.bytes == 5 * Self.gb)
    }

    @Test func nothingToClearGivesNoItems() {
        #expect(ReclaimPlanner.items(Stats([])).isEmpty)
        #expect(ReclaimPlanner.items(Stats([workspace("a", pr: pr(1, "OPEN"), last: daysAgo(1))])).isEmpty)
    }
}
