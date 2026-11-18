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

    func profile(id: String) -> AccessProfile? {
        let url = profilesDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AccessProfile.self, from: data)
    }

    func allMappings() -> [IdentityKey: String] {
        let url = profilesDir.appendingPathComponent("mappings.json")
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MappingEntry].self, from: data) else {
            return [:]
        }
        var result: [IdentityKey: String] = [:]
        for entry in entries {
            result[IdentityKey(transport: entry.transport, issuer: entry.issuer, id: entry.id)] = entry.profileId
        }
        return result
    }

    private struct MappingEntry: Codable {
        let transport: String
        let issuer: String
        let id: String
        let profileId: String
    }
}
