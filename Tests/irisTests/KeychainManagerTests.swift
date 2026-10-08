import Testing
import Foundation
@testable import iris

@Suite("KeychainManager Tests", .serialized)
struct KeychainManagerTests {

    // Under `swift test` the manager must NOT touch the real login Keychain, or macOS prompts
    // for the password repeatedly (the ad-hoc/linker-signed test binary is never in the item's
    // ACL). It uses an in-memory store instead.
    @Test("uses the in-memory store under tests (no real Keychain access)")
    func testUsesInMemoryStoreUnderTests() {
        #expect(KeychainManager.shared.usesInMemoryStore)
    }

    @Test("in-memory secrets round-trip")
    func testRoundTrip() {
        let previous = KeychainManager.shared.loadSecrets()
        defer { KeychainManager.shared.saveSecrets(previous) }

        KeychainManager.shared.saveSecrets(["API_KEY": "abc123"])
        #expect(KeychainManager.shared.loadSecrets()["API_KEY"] == "abc123")
    }

    // Pure mapping, no real Keychain call: a caller (the dev-home seeder) must tell "nothing
    // stored" apart from every other failure, and this is the only piece of that worth testing
    // without the real Keychain, which the ad-hoc test binary cannot reach without a prompt.
    @Test("outcome distinguishes not-found from every other status")
    func statusOutcomeMapping() {
        #expect(KeychainManager.outcome(for: errSecSuccess) == .success)
        #expect(KeychainManager.outcome(for: errSecItemNotFound) == .notFound)
        #expect(KeychainManager.outcome(for: errSecAuthFailed) == .failure(errSecAuthFailed))
        #expect(KeychainManager.outcome(for: errSecInteractionNotAllowed) == .failure(errSecInteractionNotAllowed))
        #expect(KeychainManager.outcome(for: -99999) == .failure(-99999))
    }

    @Test("the throwing API round-trips in-memory, same as the non-throwing one")
    func throwingAPIRoundTrip() throws {
        let m = KeychainManager(serviceSuffix: ".test-throwing")
        #expect(try m.secretsOrThrow(service: "svc") == [:])
        try m.saveSecretsOrThrow(["k": "v"], service: "svc")
        #expect(try m.secretsOrThrow(service: "svc") == ["k": "v"])
    }
}
