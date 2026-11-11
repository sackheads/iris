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

    /// Set when the Keychain load in `init` failed (locked item, a Deny, a damaged item). The
    /// cache then starts empty — fail-closed: nothing resolves until the next successful
    /// `issueToken`/Keychain read — rather than silently pretending the store is simply new.
    private(set) var keychainLoadError: Error?

    /// Rejects every spelling of `reservedClientId` a UI would still render as "iris" — not just
    /// the exact string. `issueToken`'s own check used only `==`, so "Iris", " iris " or "IRIS"
    /// registered successfully and would be indistinguishable from Iris itself wherever a client
    /// id reaches a UI.
    private static func isReservedSpelling(_ clientId: String) -> Bool {
        clientId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == reservedClientId
    }

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
        var cache: [String: String] = [:]
        var reverseCache: [String: String] = [:]
        do {
            let loaded = try keychain.secretsOrThrow(service: KeychainManager.mcpProviderService)
            for (clientId, token) in loaded where !Self.isReservedSpelling(clientId) {
                // Two client ids sharing one stored token (only reachable through a write outside
                // issueToken) would otherwise make reverseCache resolve to whichever wins the
                // loop; skip every duplicate so a token resolves to at most one client id.
                guard reverseCache[token] == nil else { continue }
                cache[clientId] = token
                reverseCache[token] = clientId
            }
        } catch {
            keychainLoadError = error
        }
        self.cache = cache
        self.reverseCache = reverseCache
    }

    func issueToken(forClientId clientId: String) throws -> String {
        guard !Self.isReservedSpelling(clientId) else { throw RegistryError.reservedClientId }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        let token = Data(bytes).base64EncodedString()
        // The Keychain write and the cache update happen under the same lock as one unit: two
        // concurrent issueToken calls for the same clientId, each writing Keychain outside any
        // lock and updating the cache separately, could leave Keychain holding one call's token
        // while the cache holds the other's — a real race, not a hypothetical one, since
        // KeychainManager's own write lock only serializes the Keychain write itself, not this
        // class's cache mutation relative to it.
        return try lock.withLock {
            try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
                dict[clientId] = token
            }
            // Re-issuing for an already-registered client id must invalidate its old token, or
            // the old one keeps resolving through clientId(forToken:) after Keychain no longer
            // holds it.
            if let oldToken = cache[clientId] { reverseCache[oldToken] = nil }
            cache[clientId] = token
            reverseCache[token] = clientId
            return token
        }
    }

    func revokeToken(forClientId clientId: String) throws {
        try lock.withLock {
            // The in-memory cache — the hot path every admission decision actually reads — is
            // cleared FIRST, before the Keychain write is even attempted. A revoke that fails to
            // persist is a recoverable problem the caller can retry; a revoke that still resolves
            // through clientId(forToken:) because the cache kept the old token is the actual
            // security bug this fixes (dev-2 review on #1069): it fails open exactly when it
            // matters least to.
            if let token = cache.removeValue(forKey: clientId) {
                reverseCache[token] = nil
            }
            try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
                dict[clientId] = nil
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
