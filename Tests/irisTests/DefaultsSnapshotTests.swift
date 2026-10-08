import Testing
import Foundation
@testable import IrisKit

/// #401: `ConfigManager.init` reads its settings from one `DefaultsSnapshot` rather than key by key,
/// because each read on a store can be a synchronous cfprefsd round trip, and hundreds of
/// main-actor tests building a manager held the main actor for seconds.
@Suite("DefaultsSnapshot (#401)")
struct DefaultsSnapshotTests {

    /// Counts the per-key reads `ConfigManager.init` used to make.
    final class CountingDefaults: UserDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var reads: Int { lock.withLock { count } }
        private func note() { lock.withLock { count += 1 } }

        override func object(forKey defaultName: String) -> Any? { note(); return super.object(forKey: defaultName) }
        override func string(forKey defaultName: String) -> String? { note(); return super.string(forKey: defaultName) }
        override func bool(forKey defaultName: String) -> Bool { note(); return super.bool(forKey: defaultName) }
        override func integer(forKey defaultName: String) -> Int { note(); return super.integer(forKey: defaultName) }
        override func double(forKey defaultName: String) -> Double { note(); return super.double(forKey: defaultName) }
    }

    private func withSuite<T>(_ body: (String) throws -> T) rethrows -> T {
        let name = "iris-snapshot-\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        return try body(name)
    }

    @Test("reads what UserDefaults reads, coercions included")
    func matchesUserDefaults() throws {
        let values: [String: Any] = [
            "s": "abc", "sNum": "12", "sFrac": "3.7", "sNeg": "-4", "sYES": "YES", "sTrue": "true",
            "sNo": "no", "sZero": "0", "sEmpty": "", "sLead": "12abc", "sOne": "1", "sTwo": "2",
            "sCaps": "TRUE", "sYes": "Yes", "sY": "y", "sSpaceBefore": " 7", "sSpaceAfter": "7 ", "sPlus": "+5",
            "sExp": "1e3", "sHex": "0x10", "sSpaceTrue": " true", "sOn": "on",
            "i0": 0, "i5": 5, "iNeg": -1, "bT": true, "bF": false, "d": 2.5, "dNeg": -0.5, "dWhole": 3.0, "dZero": 0.0, "dFrac": 0.4, "dBig": 1e10, "dNegFrac": -2.7,
            "data": Data([1, 2]), "array": ["x"], "dict": ["k": "v"],
        ]
        try withSuite { name in
            let store = try #require(UserDefaults(suiteName: name))
            for (key, value) in values { store.set(value, forKey: key) }
            let saved = DefaultsSnapshot(store)
            for key in Array(values.keys) + ["missing"] {
                #expect((saved.object(forKey: key) == nil) == (store.object(forKey: key) == nil), "object \(key)")
                #expect(saved.string(forKey: key) == store.string(forKey: key), "string \(key)")
                #expect(saved.integer(forKey: key) == store.integer(forKey: key), "integer \(key)")
                #expect(saved.double(forKey: key) == store.double(forKey: key), "double \(key)")
                #expect(saved.bool(forKey: key) == store.bool(forKey: key), "bool \(key)")
            }
        }
    }

    @Test("ConfigManager.init makes no per-key reads of its store, and still reads what was saved")
    func configInitReadsTheSnapshot() throws {
        try withSuite { name in
            let store = try #require(CountingDefaults(suiteName: name))
            store.set("Anthropic", forKey: "PRIMARY_PROVIDER")
            store.set(7, forKey: "MAX_SUBAGENT_ITERATIONS")
            store.set(45, forKey: "SUBAGENT_TURN_TIMEOUT_SECONDS")
            store.set(false, forKey: "STREAM_RESPONSES")
            let before = store.reads

            let config = ConfigManager(store: store)

            #expect(store.reads == before, "every setting came from the one snapshot")
            #expect(config.primaryProvider == "Anthropic")
            #expect(config.maxSubagentIterations == 7)
            #expect(config.subagentTurnTimeoutSeconds == 45)
            #expect(config.streamResponses == false)
        }
    }
}
