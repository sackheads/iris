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
