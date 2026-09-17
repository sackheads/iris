import Testing
import Foundation
@testable import iris

/// A perf run toggles guards through ConfigManager, whose setters persist. Under --bench/--perf
/// the store is a volatile copy seeded from the user's real domain, so the run sees the real
/// provider configuration but nothing it sets can escape the process.
@Suite("IrisDefaults volatile copy")
struct VolatileDefaultsTests {
    @Test("a copy sees the seed values and its writes never reach the domain it was seeded from")
    func copyIsIsolated() throws {
        let seedName = "iris-volatile-seed-\(UUID().uuidString)"
        let copyName = "iris-volatile-copy-\(UUID().uuidString)"
        let seedSuite = try #require(UserDefaults(suiteName: seedName))
        seedSuite.set(true, forKey: "ENABLE_VIBECOP")
        seedSuite.set("Gemini", forKey: "PRIMARY_PROVIDER")
        defer { seedSuite.removePersistentDomain(forName: seedName) }

        let seed = try #require(UserDefaults.standard.persistentDomain(forName: seedName))
        let copy = IrisDefaults.makeVolatileCopy(of: seed, suiteName: copyName)
        defer { copy.removePersistentDomain(forName: copyName) }
        #expect(copy.bool(forKey: "ENABLE_VIBECOP") == true)
        #expect(copy.string(forKey: "PRIMARY_PROVIDER") == "Gemini")

        copy.set(false, forKey: "ENABLE_VIBECOP")
        #expect(copy.bool(forKey: "ENABLE_VIBECOP") == false)
        #expect(UserDefaults.standard.persistentDomain(forName: seedName)?["ENABLE_VIBECOP"] as? Bool == true,
                "writing to the copy must not touch the domain it was seeded from")
    }

    @Test("the test process is never a volatile copy")
    func notVolatileUnderTest() {
        #expect(!IrisDefaults.isVolatileCopy)
    }

    @Test("the app domain is the bundle id or the process name")
    func appDomain() {
        #expect(!IrisDefaults.appDomain.isEmpty)
        #expect(IrisDefaults.appDomain == (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName))
    }
}
