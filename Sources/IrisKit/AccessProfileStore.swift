import Foundation

/// An authenticated identity, keyed `(transport, issuer, id)` (spec M4) — never a self-asserted
/// profile name from a task body.
struct IdentityKey: Hashable, Sendable {
    let transport: String
    let issuer: String
    let id: String
    init(transport: String, issuer: String, id: String) {
        self.transport = transport
        self.issuer = issuer
        self.id = id
    }

    /// #974 Task 16: the identity of a guest of the loopback MCP provider (#1067), which today is only
    /// the client id its bearer token resolves to. The token lookup at the provider's door IS the
    /// authentication, so this key is door-authenticated, never a name the guest supplied. The issuer is
    /// one constant: Iris's own provider. nil for an id the registry would not issue a token to (a bad
    /// shape, or the reserved `iris`), so it can never name a mapping.
    static let providerGuestTransport = "mcp"
    static let providerGuestIssuer = "iris-mcp-provider"
    static func providerGuest(clientId: String) -> IdentityKey? {
        guard ProviderTokenRegistry.isValidClientIdShape(clientId), !ProviderTokenRegistry.isReservedSpelling(clientId) else { return nil }
        return IdentityKey(transport: providerGuestTransport, issuer: providerGuestIssuer, id: clientId)
    }
}

/// The protected, read-only store over `IrisPaths.profilesDir` (spec H3): `profiles/<id>.json` per
/// named `AccessProfile`, and `profiles/mappings.json` for the identity→profile-id table. Internal
/// (not `public`) because its one `init` takes `IrisPaths`, itself internal — matches
/// `PermissionManager`'s own `init(paths:)`. This type declares **no write method** — writes come
/// only from the #961 UI's own writer type, which this store never exposes. A read of a missing or
/// unreadable file is `nil`/empty, never a default profile or mapping (C8): the caller's
/// `BindingResolver` (Task 4) is what turns that into a refusal.
final class AccessProfileStore: Sendable {
    private let profilesDir: URL

    init(paths: IrisPaths) {
        profilesDir = paths.profilesDir
    }

    /// Collides with this store's own reserved files, not a profile id a UI writer would ever
    /// pick — `BindingResolver` already bars `owner` itself (H3), but `mappings` is barred here
    /// too (dev-2's review): `profile(id: "mappings")` would otherwise try to decode the mapping
    /// array as an `AccessProfile`, which fails harmlessly today only because the shapes differ —
    /// never rely on a decode mismatch as the reason a reserved name is safe.
    private static let reservedIds: Set<String> = ["owner", "mappings"]

    /// `requestedDrop` and a persisted `accessProfileId` both reach here, and both are
    /// model-reachable strings (#1201 review finding 1 / dev-2 finding 2): without this,
    /// `"../outside"` joined straight into `profilesDir` reads any JSON file on disk the process
    /// can see, decoding as a profile with every omitted axis defaulting wide open. An id outside
    /// this allowlist (empty, containing `/`, `\`, any `.`, a NUL, or a reserved name) is simply
    /// not a profile — `nil`, same as one that does not exist. The charset excludes `.` entirely,
    /// not just a leading one, so `..` can never appear anywhere in the id.
    static func isValidProfileId(_ id: String) -> Bool {
        // Lowercased before the reserved check (dev-3's RE-REVIEW non-blocking nit): on a
        // case-insensitive volume (the default for APFS), "Mappings" reads the same file as
        // "mappings" would, so the check must not rest on exact case matching the id.
        !id.isEmpty && !reservedIds.contains(id.lowercased()) && id.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
        }
    }

    /// What a read of the store found, which `profile(id:)` and `allMappings()` cannot say: they return
    /// nil / empty for a missing file and for an unreadable one alike, and a caller that falls back to
    /// another source when the store has no answer must not fall back because the file is damaged
    /// (#974 Task 16: an owner's narrowing in a corrupt file would otherwise reopen a wider grant).
    enum Lookup<Value: Sendable>: Sendable {
        case found(Value)
        case absent
        case unreadable
    }

    /// `.absent` means exactly "no such profile file for a valid id". An id that is not a valid profile id
    /// (empty, path-shaped, reserved) is `.unreadable`: it can only reach here from a mapping that names it,
    /// an entry that exists and names no usable profile, which must not permit a fallback to a wider source.
    func lookupProfile(id: String) -> Lookup<AccessProfile> {
        guard Self.isValidProfileId(id) else { return .unreadable }
        let url = profilesDir.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let profile = try? JSONDecoder().decode(AccessProfile.self, from: data) else {
            return .unreadable
        }
        return .found(profile)
    }

    /// What the store says about `identity`'s profile, in one answer the gate can act on (#974 Task 16): `.absent`
    /// ONLY when the identity has no mapping at all (the one case a caller may fall back to another source);
    /// a mapping whose profile file is missing (dangling), invalid or damaged is `.unreadable`, because the owner
    /// did map this identity and a fallback would hand it the wider source instead.
    func lookupMappedProfile(for identity: IdentityKey) -> Lookup<AccessProfile> {
        switch lookupMapping(for: identity) {
        case .absent: return .absent
        case .unreadable: return .unreadable
        case .found(let profileId):
            switch lookupProfile(id: profileId) {
            case .found(let profile): return .found(profile)
            case .absent, .unreadable: return .unreadable
            }
        }
    }

    /// The profile id `identity` is mapped to. `.absent` only when there is no mappings file or no entry
    /// for the identity; a file that does not decode, or an identity with two conflicting entries, is
    /// `.unreadable` (the ambiguity `allMappings()` resolves to "no mapping" is not an absence).
    func lookupMapping(for identity: IdentityKey) -> Lookup<String> {
        let url = profilesDir.appendingPathComponent("mappings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([MappingEntry].self, from: data) else {
            return .unreadable
        }
        let matching = entries.filter { IdentityKey(transport: $0.transport, issuer: $0.issuer, id: $0.id) == identity }
        switch matching.count {
        case 0: return .absent
        case 1: return .found(matching[0].profileId)
        default: return .unreadable
        }
    }

    func profile(id: String) -> AccessProfile? {
        guard Self.isValidProfileId(id) else { return nil }
        let url = profilesDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AccessProfile.self, from: data)
    }

    /// A duplicate `(transport, issuer, id)` entry is ambiguous, not last-wins (#1201 review,
    /// non-blocking note taken as a fix): an identity with two conflicting mapped profiles resolves
    /// to neither, which is the fail-closed answer, consistent with everything else here.
    func allMappings() -> [IdentityKey: String] {
        let url = profilesDir.appendingPathComponent("mappings.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MappingEntry].self, from: data) else {
            return [:]
        }
        var result: [IdentityKey: String] = [:]
        var ambiguous: Set<IdentityKey> = []
        for entry in entries {
            let key = IdentityKey(transport: entry.transport, issuer: entry.issuer, id: entry.id)
            guard !ambiguous.contains(key) else { continue }
            if result[key] != nil {
                ambiguous.insert(key)
                result.removeValue(forKey: key)
                continue
            }
            result[key] = entry.profileId
        }
        return result
    }

    struct MappingEntry: Codable {
        let transport: String
        let issuer: String
        let id: String
        let profileId: String
    }
}
