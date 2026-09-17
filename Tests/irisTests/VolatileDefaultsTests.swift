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
        defer {
            seedSuite.removePersistentDomain(forName: seedName)
            // removePersistentDomain does not delete the backing plist on current macOS.
            IrisDefaults.removeSuiteFile(named: seedName, in: IrisDefaults.preferencesDirectory)
        }

        let seed = try #require(UserDefaults.standard.persistentDomain(forName: seedName))
        let copy = IrisDefaults.makeVolatileCopy(of: seed, suiteName: copyName)
        defer {
            copy.removePersistentDomain(forName: copyName)
            IrisDefaults.removeSuiteFile(named: copyName, in: IrisDefaults.preferencesDirectory)
        }
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

    // `removePersistentDomain(forName:)` clears the in-memory domain but does not delete the
    // backing plist on current macOS, so the volatile bench/perf suite's atexit cleanup left a
    // `iris-bench-<pid>.plist` behind on every run. `removeSuiteFile` is the explicit filesystem
    // delete that actually gets rid of it.
    private func makeDir(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-volatile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names { try Data().write(to: dir.appendingPathComponent(n)) }
        return dir
    }

    @Test("removeSuiteFile deletes exactly the named plist")
    func removeSuiteFileDeletesExactlyTheNamedPlist() throws {
        let dir = try makeDir(["iris-bench-4242.plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        IrisDefaults.removeSuiteFile(named: "iris-bench-4242", in: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["iris.plist"])
        // A missing name must not throw or crash.
        IrisDefaults.removeSuiteFile(named: "iris-bench-not-there", in: dir)
    }

    @Test("the preferences directory is the user's Library/Preferences")
    func preferencesDirectoryIsLibraryPreferences() {
        #expect(IrisDefaults.preferencesDirectory.path.hasSuffix("/Library/Preferences"))
    }

    @Test("perfSeed drops conversation blobs and keeps configuration")
    func perfSeedDropsConversationBlobs() {
        let domain: [String: Any] = [
            "iris_conversations": "x",
            "iris_conversations_backup_1.5": "y",
            "ENABLE_VIBECOP": true,
            "PRIMARY_PROVIDER": "Gemini",
        ]
        let seed = IrisDefaults.perfSeed(from: domain)
        #expect(Set(seed.keys) == Set(["ENABLE_VIBECOP", "PRIMARY_PROVIDER"]))
    }
}
