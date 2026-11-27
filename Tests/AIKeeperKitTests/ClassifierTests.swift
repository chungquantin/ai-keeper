import Foundation
import Testing
@testable import AIKeeperKit

@Suite struct ClassifierTests {
    @Test func mergedCleanWorkspaceIsSafeToRemove() {
        let e = workspace("a", git: GitInfo(), pr: pr(10, "MERGED", mergedAgo: 2), last: daysAgo(1))
        #expect(e.verdict == .deprecated)
        #expect(e.safety == .safe)
    }

    @Test func closedWithoutMergingIsStillSafeWhenClean() {
        let e = workspace("a", pr: pr(11, "CLOSED"), last: daysAgo(1))
        #expect(e.verdict == .deprecated)
        #expect(e.safety == .safe)
    }

    @Test func uncommittedChangesAreDangerEvenWhenMerged() {
        let e = workspace("a", git: GitInfo(dirtyCount: 3), pr: pr(12, "MERGED", mergedAgo: 5), last: daysAgo(40))
        #expect(e.safety == .danger)
    }

    @Test func aStaleDirtyWorkspaceIsACandidateButNeverSafe() {
        let e = workspace("a", git: GitInfo(dirtyCount: 2), last: daysAgo(40))
        #expect(e.verdict == .deprecated)
        #expect(e.safety == .danger)
        #expect(workspace("b", git: GitInfo(dirtyCount: 2), last: daysAgo(2)).verdict == .active)
    }

    @Test func commitsThatExistNowhereElseAreCaution() {
        let e = workspace("a", git: GitInfo(unpushed: 2), pr: nil, last: daysAgo(40))
        #expect(e.verdict == .deprecated)
        #expect(e.safety == .caution)
    }

    @Test func commitsAfterAMergeStopItBeingSafe() {
        let e = workspace("a", git: GitInfo(unpushed: 1, unpushedAfterMerge: 1), pr: pr(13, "MERGED", mergedAgo: 5), last: daysAgo(40))
        #expect(e.safety == .caution)
    }

    @Test func anOpenPullRequestKeepsItActive() {
        let e = workspace("a", pr: pr(14, "OPEN"), last: daysAgo(60))
        #expect(e.verdict == .active)
    }

    @Test func staleCleanWorkspaceIsDeprecated() {
        #expect(workspace("a", last: daysAgo(30), staleDays: 14).verdict == .deprecated)
        #expect(workspace("a", last: daysAgo(3), staleDays: 14).verdict == .active)
    }

    @Test func aMissingFolderIsDangling() {
        var e = workspace("a")
        e.exists = false
        Classifier.classify(&e, staleDays: 14)
        #expect(e.verdict == .dangling)
    }

    @Test func caches_and_leftoversAreAlwaysDeprecated() {
        #expect(other(.cache, "c", size: 1).verdict == .deprecated)
        #expect(other(.sessionData, "s", size: 1).verdict == .deprecated)
    }
}
