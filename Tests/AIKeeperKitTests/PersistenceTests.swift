import Foundation
import Testing
@testable import AIKeeperKit

@Suite struct PersistenceTests {
    init() { TestEnv.ready() }

    @Test func roundTripsAFile() {
        let name = "numbers-\(UUID().uuidString).json"
        Persist.save([1, 2, 3], name)
        #expect(Persist.load([Int].self, name) == [1, 2, 3])
    }

    @Test func anUnreadableFileIsKeptAsideInsteadOfLost() throws {
        let name = "broken-\(UUID().uuidString).json"
        let url = Persist.dir.appendingPathComponent(name)
        try Data("{ not json".utf8).write(to: url)
        #expect(Persist.load([CleanRule].self, name) == nil)
        let kept = Persist.dir.appendingPathComponent(name + ".corrupt")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ not json")
    }

    @Test func rulesWrittenByAnOlderVersionStillLoad() throws {
        let json = #"[{"kind":"buildFolders","enabled":true,"days":7}]"#
        let rules = try JSONDecoder().decode([CleanRule].self, from: Data(json.utf8))
        #expect(rules.count == 1)
        #expect(rules[0].enabled)
        #expect(rules[0].days == 7)
        #expect(rules[0].gb == 20)
    }

    @Test func restoreRecordsWithoutNewerFieldsStillLoad() throws {
        let json = #"[{"id":"a","date":"2026-11-01T10:00:00Z","name":"x","path":"/Users/t/x"}]"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let l = try dec.decode([RestoreRecord].self, from: Data(json.utf8))
        #expect(l[0].restored == false)
        #expect(l[0].trash == nil)
    }

    @Test func settingKeysAreStable() {
        // These strings are stored on people's Macs and read by the keeper command: changing one would silently reset the setting.
        #expect(Prefs.Key.budgetDaily == "budget.daily")
        #expect(Prefs.Key.vaultDays == "vault.days")
        #expect(Prefs.Key.agentBudget("claude") == "budget.agent.claude")
        #expect(Prefs.Key.keepDays("codex") == "keep.codex")
    }
}
