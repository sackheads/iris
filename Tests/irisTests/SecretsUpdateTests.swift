import Testing
import Foundation
@testable import IrisKit

/// #750: every writer of a secrets item loads the whole dictionary, changes some keys and saves it
/// back, so two writes close together used to lose one's keys. `updateSecrets` holds one lock
/// across the three.
@Suite("Secrets are updated atomically (#750)", .timeLimit(.minutes(1)))
struct SecretsUpdateTests {
    private func keychain() -> KeychainManager {
        KeychainManager(serviceSuffix: ".750-\(UUID().uuidString)", inMemory: true)
    }

    @Test("concurrent writers of different keys: every key is there afterwards")
    func concurrentWritersKeepEveryKey() {
        let keychain = keychain()
        keychain.replaceSecrets(["GEMINI_API_KEY": "kept"])
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            // A pause inside the change, so without the lock another write lands in between.
            keychain.updateSecrets { usleep(200); $0["k\(i)"] = "\(i)" }
        }
        let after = keychain.loadSecrets()
        #expect(after["GEMINI_API_KEY"] == "kept")
        #expect((0..<64).allSatisfy { after["k\($0)"] == "\($0)" }, "lost: \((0..<64).filter { after["k\($0)"] == nil })")
    }

    @Test("the throwing form keeps every key too, and the two forms share the lock")
    func throwingWritersKeepEveryKey() {
        let keychain = keychain()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if i.isMultiple(of: 2) {
                try? keychain.updateSecretsOrThrow { usleep(200); $0["k\(i)"] = "\(i)" }
            } else {
                keychain.updateSecrets { usleep(200); $0["k\(i)"] = "\(i)" }
            }
        }
        let after = keychain.loadSecrets()
        #expect((0..<64).allSatisfy { after["k\($0)"] == "\($0)" })
    }

    @Test("a read that fails saves nothing over the item, and a change that throws saves nothing")
    func failuresSaveNothing() throws {
        let keychain = keychain()
        keychain.replaceSecrets(["a": "1"])
        keychain.simulateReadFailure(errSecInteractionNotAllowed)
        #expect(throws: (any Error).self) { try keychain.updateSecretsOrThrow { $0 = ["b": "2"] } }
        keychain.simulateReadFailure(nil)
        #expect(keychain.loadSecrets() == ["a": "1"])
        struct Stop: Error {}
        #expect(throws: Stop.self) { try keychain.updateSecretsOrThrow { $0["c"] = "3"; throw Stop() } }
        #expect(keychain.loadSecrets() == ["a": "1"])
    }

    @Test("guarded settings, fingerprints and the writable-roots record written together keep every key (the shape #749's review found)")
    func guardedSettingAndAnotherKey() throws {
        let name = "iris-750-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory) }
        let keychain = keychain()
        let config = ConfigManager(store: defaults, guardedSecrets: keychain)
        // The settings writer on one queue (ConfigManager isn't meant for concurrent callers), the
        // fingerprint writer on another, interleaved.
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for _ in 0..<16 { config.setGuardedBlob(.subagentRates, ""); usleep(100) }
        }
        DispatchQueue.global().async(group: group) {
            // Fingerprint writers race each other as well as the settings writer.
            DispatchQueue.concurrentPerform(iterations: 16) { i in
                _ = ScriptFingerprints.record(jobId: UUID(), spec: ScriptSpec(command: "true \(i)", mounts: [], timeoutSeconds: 10, network: false),
                                              keychain: keychain)
            }
        }
        DispatchQueue.global().async(group: group) {
            // And the writable-roots record (#749), another writer of the same item.
            DispatchQueue.concurrentPerform(iterations: 16) { i in
                _ = GuardedRoots(keychain: keychain).add(["/iris750/\(i)"], migrating: { [] })
            }
        }
        group.wait()
        let after = keychain.loadSecrets()
        #expect(after[GuardedSettings.markerKey] == "1")
        #expect(after.keys.filter { $0.hasPrefix("SCRIPT_FP_") }.count == 16)
        let roots = try JSONDecoder().decode([String].self, from: Data((after[GuardedRoots.key] ?? "[]").utf8))
        #expect(roots.count == 16, "every root, from copies of the store each with its own cache")
    }
}
