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
        case invalidClientId
        /// A role name `SessionRoles.normalizedName` rejects (invalid or reserved).
        case invalidRole
        /// A grant needs a registered client: an id with no token must not lend its roles to the
        /// next registrant.
        case notRegistered
    }

    private let keychain: KeychainManager
    /// Guards the dictionaries only — a reader (`clientId(forToken:)`, `isRegistered`,
    /// `allClientIds`) takes this and nothing else, so it is never blocked behind a slow or
    /// prompting Keychain call.
    private let lock = NSLock()
    /// Serializes `issueToken`/`revokeToken` across their Keychain I/O: without this, two
    /// concurrent calls for the same client id could leave Keychain and the dictionaries
    /// disagreeing about which token is current (dev-2/dev-3 review). Held for the whole write,
    /// `lock` only for the brief dictionary update inside it — never the other way around, so a
    /// reader can never be stuck behind a Keychain prompt in `issueToken`/`revokeToken`.
    private let writeLock = NSLock()
    private var cache: [String: String] = [:]          // clientId -> token
    private var reverseCache: [String: String] = [:]   // token -> clientId
    /// The roles a guest client may address (#1066), normalised. Absent means none: the default is
    /// empty, never "all".
    private var roleCache: [String: Set<String>] = [:]

    /// Set when the Keychain load in `init` failed (locked item, a Deny, a damaged item). The
    /// cache then starts empty — fail-closed: nothing resolves until a client re-registers via
    /// `issueToken`. There is no automatic reload of a failed load; this property only lets a
    /// caller notice the failure happened, it does not retry it.
    private(set) var keychainLoadError: Error?

    /// A conservative allowlist, not a denylist of specific look-alikes: lowercase ASCII
    /// alphanumerics plus `.`, `_`, `-`, starting with an alphanumeric, 1-64 characters. This is
    /// what actually closes the spoofing class dev-2/dev-3 found — fullwidth "ｉｒｉｓ", Cyrillic
    /// "іris", a zero-width-joined "ir\u{200B}is", and Turkish "İris" all fail this character
    /// class, where a normalize-then-compare-to-"iris" check (this file's earlier fix) let every
    /// one of them through. The exact lowercase spelling "iris" still passes this allowlist on
    /// its own, since it is itself a valid identifier shape — `isReservedSpelling` below is the
    /// second, explicit guard that rejects that one specific case.
    private static func isValidClientIdShape(_ clientId: String) -> Bool {
        guard clientId.count <= 64, let first = clientId.unicodeScalars.first else { return false }
        guard first.isASCII, CharacterSet.lowercaseASCIILetters.contains(first) || CharacterSet.asciiDigits.contains(first) else {
            return false
        }
        return clientId.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.lowercaseASCIILetters.contains(scalar) || CharacterSet.asciiDigits.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-")
        }
    }

    private static func isReservedSpelling(_ clientId: String) -> Bool { clientId == reservedClientId }

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
        var cache: [String: String] = [:]
        var reverseCache: [String: String] = [:]
        do {
            let loaded = try keychain.secretsOrThrow(service: KeychainManager.mcpProviderService)
            for (clientId, token) in loaded
            where Self.isValidClientIdShape(clientId) && !Self.isReservedSpelling(clientId) {
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
        // Fail closed like the token load: an unreadable roles item leaves every client with no
        // roles, and an entry that is malformed, for an unusable client id, or for a role name
        // that does not normalise is dropped rather than trusted.
        var roleCache: [String: Set<String>] = [:]
        do {
            let loaded = try keychain.secretsOrThrow(service: KeychainManager.mcpProviderRolesService)
            for (clientId, json) in loaded
            where Self.isValidClientIdShape(clientId) && !Self.isReservedSpelling(clientId) && cache[clientId] != nil {
                guard let data = json.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: data)
                else { continue }
                let roles = Set(names.compactMap { SessionRoles.normalizedName($0) })
                if !roles.isEmpty { roleCache[clientId] = roles }
            }
        } catch {
            keychainLoadError = keychainLoadError ?? error
        }
        self.roleCache = roleCache
    }

    func issueToken(forClientId clientId: String) throws -> String {
        guard Self.isValidClientIdShape(clientId) else { throw RegistryError.invalidClientId }
        guard !Self.isReservedSpelling(clientId) else { throw RegistryError.reservedClientId }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        let token = Data(bytes).base64EncodedString()
        return try writeLock.withLock {
            // A first registration starts with no roles: a grant left in the Keychain by an earlier
            // registration of this id (a revoke whose roles write failed) is cleared, not inherited.
            if !isRegistered(clientId: clientId) {
                try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderRolesService) { dict in
                    dict[clientId] = nil
                }
            }
            try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
                dict[clientId] = token
            }
            lock.withLock {
                // Re-issuing for an already-registered client id must invalidate its old token,
                // or the old one keeps resolving through clientId(forToken:) after Keychain no
                // longer holds it.
                if let oldToken = cache[clientId] { reverseCache[oldToken] = nil }
                cache[clientId] = token
                reverseCache[token] = clientId
            }
            return token
        }
    }

    func revokeToken(forClientId clientId: String) throws {
        try writeLock.withLock {
            // The in-memory cache — the hot path every admission decision actually reads — is
            // cleared FIRST, before the Keychain write is even attempted. A revoke that fails to
            // persist is a recoverable problem the caller can retry (and, until it does, the
            // revoked token would resurrect on the next process launch that reloads from
            // Keychain — Task 8's revoke path must surface this throw, not swallow it); a revoke
            // that still resolves through clientId(forToken:) because the cache kept the old
            // token in THIS process is the actual security bug this fixes (dev-2 review on
            // #1069): it fails open exactly when it matters least to.
            lock.withLock {
                if let token = cache.removeValue(forKey: clientId) {
                    reverseCache[token] = nil
                }
            }
            // The grant goes first for the same reason: a revoked client must not keep reaching
            // roles in this process because a Keychain write failed.
            lock.withLock { roleCache[clientId] = nil }
            // The roles item first: a failed write after this point can leave a token that still
            // authenticates, never a grant that outlives its token.
            try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderRolesService) { dict in
                dict[clientId] = nil
            }
            try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderService) { dict in
                dict[clientId] = nil
            }
        }
    }

    /// What `clientId` may address as a guest (#1066): empty unless granted here.
    func roles(forClientId clientId: String) -> Set<String> {
        lock.withLock { cache[clientId] == nil ? [] : (roleCache[clientId] ?? []) }
    }

    /// Replaces `clientId`'s granted roles. Every name goes through `SessionRoles.normalizedName`
    /// (one rejected name fails the whole call and changes nothing), and a client id that cannot be
    /// registered cannot hold roles either. An empty set clears the grant.
    func setRoles(_ roles: Set<String>, forClientId clientId: String) throws {
        guard Self.isValidClientIdShape(clientId) else { throw RegistryError.invalidClientId }
        guard !Self.isReservedSpelling(clientId) else { throw RegistryError.reservedClientId }
        var normalised: Set<String> = []
        for role in roles {
            guard let name = SessionRoles.normalizedName(role) else { throw RegistryError.invalidRole }
            normalised.insert(name)
        }
        try writeLock.withLock {
            guard isRegistered(clientId: clientId) else { throw RegistryError.notRegistered }
            let encoded = String(data: try JSONEncoder().encode(normalised.sorted()), encoding: .utf8) ?? "[]"
            try keychain.updateSecretsOrThrow(service: KeychainManager.mcpProviderRolesService) { dict in
                dict[clientId] = normalised.isEmpty ? nil : encoded
            }
            lock.withLock { roleCache[clientId] = normalised.isEmpty ? nil : normalised }
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

private extension CharacterSet {
    static let lowercaseASCIILetters = CharacterSet(charactersIn: "a"..."z")
    static let asciiDigits = CharacterSet(charactersIn: "0"..."9")
}
