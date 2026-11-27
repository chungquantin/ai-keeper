import Foundation
import Testing
@testable import AIKeeperKit

@Suite struct NotificationTests {
    @Test func everyKindWithButtonsHasItsOwnCategory() {
        let ids = NotificationKind.allCases.filter { !$0.actions.isEmpty }.map(\.categoryID)
        #expect(Set(ids).count == ids.count)
        #expect(NotificationKind.general.actions.isEmpty)
    }

    @Test func eachDiskAlertOffersTheFixAndAWayIn() {
        #expect(NotificationKind.disk.actions == [.clearBuild, .open])
        #expect(NotificationKind.agent.actions.contains(.openSession))
        #expect(NotificationKind.budget.actions.contains(.raiseBudget))
    }

    @Test func buttonIdentifiersRoundTrip() {
        for a in NotificationAction.allCases { #expect(NotificationAction.from(a.id) == a) }
        #expect(NotificationAction.from("nonsense") == nil)
    }

    @Test func aClickOnTheNotificationGoesToTheRightPlace() {
        #expect(NotificationKind.disk.destination == .review)
        #expect(NotificationKind.agent.destination == .live)
        #expect(NotificationKind.budget.destination == .cost)
    }

    @Test func raisedBudgetsRoundUpToFiveDollars() {
        #expect(Prefs.raised(40) == 50)
        #expect(Prefs.raised(7) == 10)
        #expect(Prefs.raised(0) == 5)
    }
}

@Suite struct DigestTests {
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> (Date, Calendar) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return (cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!, cal)
    }

    @Test func dueOnFridayEveningOncePerWeek() {
        let (fri, cal) = date(2026, 11, 27, 17)      // a Friday
        #expect(Digest.isDue(now: fri, lastWeek: nil, calendar: cal))
        #expect(!Digest.isDue(now: fri, lastWeek: Digest.weekID(fri, calendar: cal), calendar: cal))
        #expect(Digest.isDue(now: fri, lastWeek: "2026-W40", calendar: cal))
    }

    @Test func notDueBeforeFiveOrOnOtherDays() {
        let (early, cal) = date(2026, 11, 27, 16)
        #expect(!Digest.isDue(now: early, lastWeek: nil, calendar: cal))
        let (thu, _) = date(2026, 11, 26, 18)
        #expect(!Digest.isDue(now: thu, lastWeek: nil, calendar: cal))
    }
}

@Suite struct KeepFolderTests {
    @Test func aKeptFolderCoversItsChildrenButNotLookAlikes() {
        #expect(Prefs.isKept("/Users/t/work/app", keep: ["/Users/t/work/app"]))
        #expect(Prefs.isKept("/Users/t/work/app/target", keep: ["/Users/t/work/app"]))
        #expect(!Prefs.isKept("/Users/t/work/app-two", keep: ["/Users/t/work/app"]))
        #expect(!Prefs.isKept("/Users/t/work/app", keep: []))
    }

    @Test func keptWorkspacesAreNotOfferedForCleanup() {
        let gb = TierTests.gb
        let merged = workspace("merged", pr: pr(1, "MERGED", mergedAgo: 3), size: 3 * gb, last: daysAgo(3), artifacts: [Artifact(path: "/Users/test/work/merged/target", bytes: gb)])
        let all = Stats([merged])
        #expect(all.remoteBytes == 3 * gb)
        let kept = Stats([merged], keep: ["/Users/test/work/merged"])
        #expect(kept.remoteBytes == 0)
        #expect(kept.safeBytes == 0)
        #expect(ReclaimPlanner.items(kept).isEmpty)
    }

    @Test func theCleanerRefusesAKeptFolder() {
        let h = FakeHome()
        let kept = h.dir("Developer/precious")
        #expect(!Cleaner.isSafeToRemove(path: kept, home: h.path, keep: [kept]))
        #expect(!Cleaner.isSafeToRemove(path: kept + "/sub", home: h.path, keep: [kept]))
        #expect(Cleaner.isSafeToRemove(path: h.dir("Developer/other"), home: h.path, keep: [kept]))
    }
}
