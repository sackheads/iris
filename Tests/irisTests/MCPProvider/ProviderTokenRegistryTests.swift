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

    @Test("the load path applies the same allowlist as issueToken: only a shape-valid, non-reserved id survives a fresh load")
    func loadPathAppliesTheSameAllowlist() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
            dict["Iris"] = "token-1"
            dict["\u{FF49}\u{FF52}\u{FF49}\u{FF53}"] = "token-2"
            dict["ir\u{200B}is"] = "token-3"
            dict["has/slash"] = "token-4"
            dict["valid-client"] = "token-5"
        }
        let registry = ProviderTokenRegistry(keychain: keychain)
        #expect(registry.allClientIds() == ["valid-client"])
        #expect(registry.clientId(forToken: "token-5") == "valid-client")
        for badToken in ["token-1", "token-2", "token-3", "token-4"] {
            #expect(registry.clientId(forToken: badToken) == nil)
        }
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

    @Test("issueToken refuses case/whitespace variants of \"iris\" too, via the shape check, not just the exact spelling")
    func reservedSpellingVariantsRejected() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        for variant in ["Iris", "IRIS", " iris", "iris ", " Iris "] {
            #expect(throws: ProviderTokenRegistry.RegistryError.invalidClientId) {
                try registry.issueToken(forClientId: variant)
            }
        }
        #expect(registry.allClientIds().isEmpty)
    }

    @Test("look-alike spellings of \"iris\" that bypass a normalize-then-compare check are refused by the character-class allowlist")
    func unicodeLookAlikesRejected() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        // Fullwidth, Cyrillic look-alike, zero-width-joined, and Turkish dotted capital — none of
        // these are ASCII, so none can pass the lowercase-ASCII-only allowlist, regardless of
        // what a `.lowercased()` + `==` comparison does with them.
        for lookAlike in ["\u{FF49}\u{FF52}\u{FF49}\u{FF53}", "\u{0456}ris", "ir\u{200B}is", "\u{0130}ris", ""] {
            #expect(throws: ProviderTokenRegistry.RegistryError.invalidClientId) {
                try registry.issueToken(forClientId: lookAlike)
            }
        }
        #expect(registry.allClientIds().isEmpty)
    }

    /// Asserts the outcome (Keychain and the cache agree), not the mechanism: this run alone does
    /// not distinguish `writeLock` actually serializing the Keychain write and the cache update
    /// from the window between them simply being too small to lose on this machine (swapping
    /// `writeLock` for a fresh, unrelated `NSLock()` still passed here). A deterministic,
    /// semaphore-gated variant (pause the first call inside the gap via a test-only hook, then
    /// assert a second blocks) was tried and discarded: under heavy host load it produced a
    /// false failure unrelated to `writeLock` — GCD's global queue did not provision a worker
    /// thread for the second call within the bound the test needed. The serialization itself is
    /// verified by reading `issueToken`'s body instead: the Keychain write and the cache update
    /// are both inside the same `writeLock.withLock` call, so no interleaving between two
    /// concurrent calls' two phases is possible, regardless of timing.
    @Test("many concurrent issueToken calls for the same client id leave Keychain and the cache agreeing on one token")
    func concurrentIssueForSameClientStaysConsistent() async throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try registry.issueToken(forClientId: "c") }
            }
            var results: [String] = []
            for try await token in group { results.append(token) }
            return results
        }
        #expect(tokens.count == 20)
        // Whichever call ran last, exactly one token must be live: Keychain and the cache agree,
        // and every earlier call's token was invalidated.
        let liveTokens = tokens.filter { registry.clientId(forToken: $0) == "c" }
        #expect(liveTokens.count == 1)
        let stored = try keychain.secretsOrThrow(service: KeychainManager.mcpProviderService)
        #expect(stored["c"] == liveTokens.first)
        #expect(registry.allClientIds() == ["c"])
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

    // MARK: guest role grants (#1066)

    private func fresh() -> (KeychainManager, ProviderTokenRegistry) {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        return (keychain, ProviderTokenRegistry(keychain: keychain))
    }

    @Test("a client holds no roles until granted")
    func rolesDefaultEmpty() throws {
        let (_, registry) = fresh()
        _ = try registry.issueToken(forClientId: "dev-1")
        #expect(registry.roles(forClientId: "dev-1").isEmpty)
        #expect(registry.roles(forClientId: "never-seen").isEmpty)
    }

    @Test("granted roles are normalised, replace the earlier grant, and survive a reload")
    func rolesSurviveReload() throws {
        let (keychain, registry) = fresh()
        _ = try registry.issueToken(forClientId: "dev-1")
        try registry.setRoles(["Reviewer", " builder "], forClientId: "dev-1")
        #expect(registry.roles(forClientId: "dev-1") == ["reviewer", "builder"])
        try registry.setRoles(["builder"], forClientId: "dev-1")
        #expect(ProviderTokenRegistry(keychain: keychain).roles(forClientId: "dev-1") == ["builder"])
        try registry.setRoles([], forClientId: "dev-1")
        #expect(ProviderTokenRegistry(keychain: keychain).roles(forClientId: "dev-1").isEmpty, "an empty set clears the grant")
    }

    @Test("revoking the token removes the client's roles, in memory and in the Keychain")
    func revokeRemovesRoles() throws {
        let (keychain, registry) = fresh()
        _ = try registry.issueToken(forClientId: "dev-1")
        _ = try registry.issueToken(forClientId: "dev-2")
        try registry.setRoles(["reviewer"], forClientId: "dev-1")
        try registry.setRoles(["builder"], forClientId: "dev-2")
        try registry.revokeToken(forClientId: "dev-1")
        #expect(registry.roles(forClientId: "dev-1").isEmpty)
        let reloaded = ProviderTokenRegistry(keychain: keychain)
        #expect(reloaded.roles(forClientId: "dev-1").isEmpty)
        #expect(reloaded.roles(forClientId: "dev-2") == ["builder"], "another client's grant is untouched")
        // Re-registering the same id does not bring the old grant back.
        _ = try reloaded.issueToken(forClientId: "dev-1")
        #expect(reloaded.roles(forClientId: "dev-1").isEmpty)
    }

    @Test("re-issuing a token keeps the client's grant")
    func reissueKeepsRoles() throws {
        let (_, registry) = fresh()
        _ = try registry.issueToken(forClientId: "dev-1")
        try registry.setRoles(["reviewer"], forClientId: "dev-1")
        _ = try registry.issueToken(forClientId: "dev-1")
        #expect(registry.roles(forClientId: "dev-1") == ["reviewer"])
    }

    @Test("a client id that fails the shape check, or is reserved, cannot hold roles; a bad role name changes nothing")
    func badInputsHoldNothing() throws {
        let (_, registry) = fresh()
        for bad in ["Iris", "ir\u{200B}is", "has/slash", "", String(repeating: "a", count: 65)] {
            #expect(throws: ProviderTokenRegistry.RegistryError.invalidClientId) { try registry.setRoles(["reviewer"], forClientId: bad) }
            #expect(registry.roles(forClientId: bad).isEmpty)
        }
        #expect(throws: ProviderTokenRegistry.RegistryError.reservedClientId) { try registry.setRoles(["reviewer"], forClientId: "iris") }
        _ = try registry.issueToken(forClientId: "dev-1")
        try registry.setRoles(["reviewer"], forClientId: "dev-1")
        for bad in ["iris", "clear", "has space", "", "UPPER_case", String(repeating: "a", count: 33)] {
            #expect(throws: ProviderTokenRegistry.RegistryError.invalidRole) { try registry.setRoles(["builder", bad], forClientId: "dev-1") }
        }
        #expect(registry.roles(forClientId: "dev-1") == ["reviewer"], "a rejected call changed nothing")
    }

    @Test("the load path drops a stored grant that is malformed, for an unusable client id, or for a role that does not normalise")
    func loadDropsBadGrants() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderRolesService) { dict in
            dict["good"] = #"["Reviewer","iris","bad name"]"#
            dict["no-token"] = #"["reviewer"]"#
            dict["Iris"] = #"["reviewer"]"#
            dict["iris"] = #"["reviewer"]"#
            dict["has/slash"] = #"["reviewer"]"#
            dict["garbled"] = "not json"
            dict["only-bad"] = #"["iris","clear"]"#
        }
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
            for id in ["good", "garbled", "only-bad"] { dict[id] = "token-\(id)" }
        }
        let registry = ProviderTokenRegistry(keychain: keychain)
        #expect(registry.roles(forClientId: "good") == ["reviewer"])
        #expect(registry.roles(forClientId: "no-token").isEmpty, "a stored grant with no token is not served")
        for id in ["Iris", "iris", "has/slash", "garbled", "only-bad"] { #expect(registry.roles(forClientId: id).isEmpty, "\(id)") }
    }

    @Test("a grant needs a registered client, and an id with no token lends nothing to the next registrant")
    func grantNeedsARegisteredClient() throws {
        let (keychain, registry) = fresh()
        #expect(throws: ProviderTokenRegistry.RegistryError.notRegistered) { try registry.setRoles(["reviewer"], forClientId: "dev-1") }
        #expect(registry.roles(forClientId: "dev-1").isEmpty)
        // A grant left in the Keychain by an earlier registration is not inherited by a new one.
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderRolesService) { $0["dev-1"] = #"["reviewer"]"# }
        let reloaded = ProviderTokenRegistry(keychain: keychain)
        _ = try reloaded.issueToken(forClientId: "dev-1")
        #expect(reloaded.roles(forClientId: "dev-1").isEmpty)
        #expect(ProviderTokenRegistry(keychain: keychain).roles(forClientId: "dev-1").isEmpty)
    }
}
