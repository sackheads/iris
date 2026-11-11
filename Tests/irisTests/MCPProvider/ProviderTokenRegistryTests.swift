import Testing
import Foundation
@testable import IrisKit

@Suite("ProviderTokenRegistry")
struct ProviderTokenRegistryTests {
    @Test("issuing a token makes it resolve back to the client id, and revoking removes it")
    func issueLookupRevoke() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        let token = try registry.issueToken(forClientId: "iris-dev-1")
        #expect(registry.clientId(forToken: token) == "iris-dev-1")
        #expect(registry.allClientIds() == ["iris-dev-1"])
        try registry.revokeToken(forClientId: "iris-dev-1")
        #expect(registry.clientId(forToken: token) == nil)
    }

    @Test("issueToken refuses the reserved \"iris\" client id, before any Keychain write")
    func reservedClientIdRejected() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        #expect(throws: ProviderTokenRegistry.RegistryError.reservedClientId) {
            try registry.issueToken(forClientId: ProviderTokenRegistry.reservedClientId)
        }
        #expect(registry.allClientIds().isEmpty)
    }

    @Test("a pre-existing Keychain entry keyed \"iris\", written by any path other than issueToken, is skipped on load")
    func reservedClientIdSkippedOnLoad() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
            dict[ProviderTokenRegistry.reservedClientId] = "some-token"
        }
        let registry = ProviderTokenRegistry(keychain: keychain)
        #expect(!registry.allClientIds().contains(ProviderTokenRegistry.reservedClientId))
        #expect(!registry.isRegistered(clientId: ProviderTokenRegistry.reservedClientId))
    }

    @Test("re-issuing a token for an already-registered client invalidates its old token, and revoke after re-issue leaves nothing resolving")
    func reissueInvalidatesOldToken() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        let first = try registry.issueToken(forClientId: "a")
        let second = try registry.issueToken(forClientId: "a")
        #expect(first != second)
        #expect(registry.clientId(forToken: first) == nil)
        #expect(registry.clientId(forToken: second) == "a")

        try registry.revokeToken(forClientId: "a")
        #expect(registry.clientId(forToken: first) == nil)
        #expect(registry.clientId(forToken: second) == nil)
    }

    @Test("issueToken refuses case/whitespace variants of \"iris\", not just the exact spelling")
    func reservedSpellingVariantsRejected() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        for variant in ["Iris", "IRIS", " iris", "iris ", " Iris "] {
            #expect(throws: ProviderTokenRegistry.RegistryError.reservedClientId) {
                try registry.issueToken(forClientId: variant)
            }
        }
        #expect(registry.allClientIds().isEmpty)
    }

    @Test("revokeToken clears the in-memory cache even when persisting the revoke fails (fail-safe, not fail-open)")
    func revokeFailsSafeOnKeychainWriteFailure() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        let token = try registry.issueToken(forClientId: "a")
        #expect(registry.clientId(forToken: token) == "a")

        // updateSecretsOrThrow reads before it writes; failing the read makes the whole revoke
        // call throw before anything is persisted — but the cache must already be clear.
        keychain.simulateReadFailure(errSecIO)
        #expect(throws: (any Error).self) {
            try registry.revokeToken(forClientId: "a")
        }
        #expect(registry.clientId(forToken: token) == nil, "a revoke that fails to persist must still block the token immediately")
        #expect(!registry.isRegistered(clientId: "a"))
    }

    @Test("a Keychain read failure at init is recorded, not silently swallowed, and the registry starts empty (fail-closed)")
    func keychainLoadErrorIsRecorded() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        keychain.simulateReadFailure(errSecIO)
        let registry = ProviderTokenRegistry(keychain: keychain)
        #expect(registry.keychainLoadError != nil)
        #expect(registry.allClientIds().isEmpty)
    }

    @Test("allClientIds and isRegistered reflect multiple registered clients")
    func multipleClients() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        _ = try registry.issueToken(forClientId: "a")
        _ = try registry.issueToken(forClientId: "b")
        #expect(Set(registry.allClientIds()) == ["a", "b"])
        #expect(registry.isRegistered(clientId: "a"))
        #expect(!registry.isRegistered(clientId: "c"))
    }
}
