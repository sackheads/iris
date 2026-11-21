import Foundation
import CryptoKit

/// #974 Task 16 S3: what a provider guest may address lives in ONE place, `AccessProfileStore`
/// (`AccessProfile.peerRoles`, keyed by the guest's `IdentityKey.providerGuest`). The Keychain roles item
/// `ProviderTokenRegistry` has always held is now a read-only fallback, used only when the store is
/// readable and has no mapping for the guest. An unreadable store answers "no roles", never the fallback.
///
/// The registry only ever creates, replaces or deletes the profile and mapping it generated itself
/// (`generatedProfileId`). A mapping an operator wrote to some other profile is never touched here: the
/// store wins, and the registry's own grants stay out of its way.
enum ProviderGuestGrants {
    /// `guest-<clientId with '.' as '_'>-<12 hex of sha256(clientId)>`: a client id may contain '.', which a
    /// profile id may not, and the digest keeps `a.b` and `a_b` apart.
    static func generatedProfileId(forClientId clientId: String) -> String? {
        guard ProviderTokenRegistry.isValidClientIdShape(clientId), !ProviderTokenRegistry.isReservedSpelling(clientId) else { return nil }
        let digest = SHA256.hash(data: Data(clientId.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let id = "guest-" + clientId.replacingOccurrences(of: ".", with: "_") + "-" + digest
        return AccessProfileStore.isValidProfileId(id) ? id : nil
    }

    enum Outcome: Equatable {
        case written
        /// The guest is mapped to a profile this registry did not generate; left alone.
        case operatorOwned
        /// The mapping, or the profile it names, cannot be read; nothing was written.
        case unreadable
    }

    /// What `clientId` may address: its mapped profile's roles; the Keychain roles only when the store is
    /// readable and has no mapping for it; nothing when the store cannot be read. A client with no
    /// registered token has no reach whatever the store says.
    static func allowedRoles(clientId: String, registry: ProviderTokenRegistry, store: AccessProfileStore) -> Set<String> {
        guard registry.isRegistered(clientId: clientId), let identity = IdentityKey.providerGuest(clientId: clientId) else { return [] }
        switch store.lookupMappedProfile(for: identity) {
        case .found(let profile): return profile.peerRoles
        case .unreadable: return []
        case .absent: return registry.roles(forClientId: clientId)
        }
    }

    /// The roles the registry's own generated profile currently grants `clientId` (empty if it has none, or
    /// the guest is mapped elsewhere): what `grant` restores after a failed call.
    static func registryGrant(clientId: String, store: AccessProfileStore) -> Set<String> {
        guard let identity = IdentityKey.providerGuest(clientId: clientId), let ownId = generatedProfileId(forClientId: clientId),
              case .found(let mapped) = store.lookupMapping(for: identity), mapped == ownId,
              case .found(let profile) = store.lookupProfile(id: ownId) else { return [] }
        return profile.peerRoles
    }

    /// Records `roles` for `clientId` in the store. Empty roles clear the registry's own grant.
    @discardableResult
    static func grant(_ roles: Set<String>, clientId: String, store: AccessProfileStore, writer: AccessProfileWriter) throws -> Outcome {
        guard let identity = IdentityKey.providerGuest(clientId: clientId), let ownId = generatedProfileId(forClientId: clientId) else {
            return .unreadable
        }
        switch store.lookupMapping(for: identity) {
        case .unreadable: return .unreadable
        case .found(let mapped) where mapped != ownId: return .operatorOwned
        case .found:
            if roles.isEmpty { try clear(clientId: clientId, store: store, writer: writer); return .written }
            try writer.writeProfile(id: ownId, AccessProfile(peerRoles: roles), replacing: true)
            return .written
        case .absent:
            if roles.isEmpty { return .written }
            try writer.writeProfile(id: ownId, AccessProfile(peerRoles: roles), replacing: true)
            try writer.setMapping(identity, profileId: ownId, replacing: false)
            return .written
        }
    }

    /// Removes the registry's own profile and mapping for `clientId`; an operator's mapping stays.
    static func clear(clientId: String, store: AccessProfileStore, writer: AccessProfileWriter) throws {
        guard let identity = IdentityKey.providerGuest(clientId: clientId), let ownId = generatedProfileId(forClientId: clientId) else { return }
        switch store.lookupMapping(for: identity) {
        case .found(let mapped) where mapped == ownId:
            try writer.removeMapping(identity)
            try writer.removeProfile(id: ownId)
        case .absent:
            try writer.removeProfile(id: ownId)
        case .found, .unreadable:
            return
        }
    }

    /// Copies each registered guest's Keychain roles into the store, once: a guest that already has a
    /// mapping is skipped (never overwritten), and so is one whose generated profile file exists with
    /// anything but exactly those roles. The Keychain item is not changed or deleted. Returns the client
    /// ids it skipped for a reason other than "already mapped".
    @discardableResult
    static func migrate(registry: ProviderTokenRegistry, store: AccessProfileStore, writer: AccessProfileWriter) -> [String] {
        var skipped: [String] = []
        for clientId in registry.allClientIds().sorted() {
            let roles = registry.roles(forClientId: clientId)
            guard !roles.isEmpty, let identity = IdentityKey.providerGuest(clientId: clientId),
                  let ownId = generatedProfileId(forClientId: clientId) else { continue }
            guard case .absent = store.lookupMapping(for: identity) else {
                if case .unreadable = store.lookupMapping(for: identity) { skipped.append(clientId) }
                continue
            }
            let expected = AccessProfile(peerRoles: roles)
            do {
                switch store.lookupProfile(id: ownId) {
                case .found(let existing) where existing == expected: break
                case .absent: try writer.writeProfile(id: ownId, expected, replacing: false)
                case .found, .unreadable: skipped.append(clientId); continue
                }
                try writer.setMapping(identity, profileId: ownId, replacing: false)
            } catch {
                skipped.append(clientId)
            }
        }
        return skipped
    }
}
