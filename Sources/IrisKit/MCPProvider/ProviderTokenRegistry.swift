import Foundation
import Security

/// Bearer tokens for clients of the loopback MCP provider (#1067). One token per registered
/// client id, Keychain-bound under `KeychainManager.mcpProviderService`. The in-memory cache is
/// the hot-path read: a Keychain lookup on every HTTP request is unacceptable (a locked or
/// denied item can raise a user-facing prompt), so every mutation re-reads the whole map once and
/// keeps it resident.
final class ProviderTokenRegistry: @unchecked Sendable {
    /// `ProviderMailbox.MailboxParty.iris` (Task 6) is distinct from this string by construction
    /// at the mailbox layer, but `ProviderArtifactStore`'s authorized-reader sets (Task 7) are
    /// plain `Set<String>` with no equivalent type separation — a client registered under this
    /// literal could still gain a read via `authorizeAll(adding: Self.reservedClientId)`'s string
    /// match alone. Reserving it here closes that second surface.
    static let reservedClientId = "iris"

    enum RegistryError: Error, Equatable {
        case reservedClientId
    }

    private let keychain: KeychainManager
    private let lock = NSLock()
    private var cache: [String: String] = [:]          // clientId -> token
    private var reverseCache: [String: String] = [:]   // token -> clientId

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
        let loaded = (try? keychain.secretsOrThrow(service: KeychainManager.mcpProviderService)) ?? [:]
        var cache: [String: String] = [:]
        var reverseCache: [String: String] = [:]
        for (clientId, token) in loaded where clientId != Self.reservedClientId {
            cache[clientId] = token
            reverseCache[token] = clientId
        }
        self.cache = cache
        self.reverseCache = reverseCache
    }

    func issueToken(forClientId clientId: String) throws -> String {
        guard clientId != Self.reservedClientId else { throw RegistryError.reservedClientId }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        let token = Data(bytes).base64EncodedString()
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
            dict[clientId] = token
        }
        lock.withLock {
            cache[clientId] = token
            reverseCache[token] = clientId
        }
        return token
    }

    func revokeToken(forClientId clientId: String) throws {
        try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
            dict[clientId] = nil
        }
        lock.withLock {
            if let token = cache.removeValue(forKey: clientId) {
                reverseCache[token] = nil
            }
        }
    }

    func clientId(forToken token: String) -> String? {
        lock.withLock { reverseCache[token] }
    }

    func allClientIds() -> [String] {
        lock.withLock { Array(cache.keys) }
    }

    func isRegistered(clientId: String) -> Bool {
        lock.withLock { cache[clientId] != nil }
    }
}
