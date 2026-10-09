import Testing
import Foundation
@testable import IrisKit

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

    @Test("stripConversationBlob drops the blob keys and nothing else, with no env override")
    func stripConversationBlobDropsBlobKeysOnly() {
        let domain: [String: Any] = [
            "iris_conversations": "x",
            "iris_conversations_backup_1.5": "y",
            "iris_conversations_legacy": "z",
            "PRIMARY_PROVIDER": "Gemini",
        ]
        #expect(Set(IrisDefaults.stripConversationBlob(from: domain).keys) == Set(["PRIMARY_PROVIDER"]))
    }

    @Test("perfSeed drops conversation blobs and keeps configuration")
    func perfSeedDropsConversationBlobs() {
        let domain: [String: Any] = [
            "iris_conversations": "x",
            "iris_conversations_backup_1.5": "y",
            "iris_conversations_legacy": "z",
            "ENABLE_VIBECOP": true,
            "PRIMARY_PROVIDER": "Gemini",
        ]
        let seed = IrisDefaults.perfSeed(from: domain)
        #expect(Set(seed.keys) == Set(["ENABLE_VIBECOP", "PRIMARY_PROVIDER"]))
    }

    /// `IRIS_PERF_SEED_JSON` is how a perf/bench run overrides config for a measurement (#405's
    /// Phase 1 baseline used this, as a one-off patch, to target Anthropic on Vertex). A fake
    /// `environment` dict exercises it without ever touching the real process environment
    /// (invariant 7) — `ProcessInfo.processInfo.environment` is itself process-global.
    @Test("IRIS_PERF_SEED_JSON overrides a domain key, replayThinkingWithinTurn included, and adds a new one")
    func perfSeedAppliesEnvironmentOverride() {
        let domain: [String: Any] = ["PRIMARY_PROVIDER": "Gemini", "ENABLE_VIBECOP": true]
        let env = ["IRIS_PERF_SEED_JSON": #"{"PRIMARY_PROVIDER":"Anthropic","REPLAY_THINKING_WITHIN_TURN":true}"#]
        let seed = IrisDefaults.perfSeed(from: domain, environment: env)
        #expect(seed["PRIMARY_PROVIDER"] as? String == "Anthropic", "the override wins over the domain's own value")
        #expect(seed["REPLAY_THINKING_WITHIN_TURN"] as? Bool == true, "a key absent from the domain is still added")
        #expect(seed["ENABLE_VIBECOP"] as? Bool == true, "a key the override does not mention is untouched")

        let copyName = "iris-volatile-seedenv-\(UUID().uuidString)"
        let copy = IrisDefaults.makeVolatileCopy(of: seed, suiteName: copyName)
        defer {
            copy.removePersistentDomain(forName: copyName)
            IrisDefaults.removeSuiteFile(named: copyName, in: IrisDefaults.preferencesDirectory)
        }
        #expect(ConfigManager(store: copy).replayThinkingWithinTurn == true,
                "ConfigManager reads the override the same way it reads any other seeded key")
    }

    @Test("no IRIS_PERF_SEED_JSON, or malformed JSON, leaves the domain's own values untouched")
    func perfSeedIgnoresMissingOrMalformedOverride() {
        let domain: [String: Any] = ["PRIMARY_PROVIDER": "Gemini"]
        #expect(Set(IrisDefaults.perfSeed(from: domain, environment: [:]).keys) == Set(["PRIMARY_PROVIDER"]))
        let malformed = IrisDefaults.perfSeed(from: domain, environment: ["IRIS_PERF_SEED_JSON": "{not json"])
        #expect(malformed["PRIMARY_PROVIDER"] as? String == "Gemini")
        #expect(malformed.count == 1)
    }
}
