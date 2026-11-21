import Foundation

/// The one internal writer over `profiles/` (#974 Task 16 S3). `AccessProfileStore` has no write
/// method on purpose (H3: not model-writable), and this type is not a tool: no declaration, dispatcher
/// or model-reachable path names it. Its callers are the provider registry (a guest's granted roles)
/// and, later, the #961 profile pane. It never replaces what it cannot read: a mappings file that does
/// not decode, or an identity with two conflicting entries, is an error, never overwritten.
struct AccessProfileWriter {
    enum WriteError: Error, Equatable {
        case invalidProfileId
        case exists
        case unreadableMappings
    }

    /// One writer lock for the process: a mapping change is a read-modify-write of one file.
    private static let lock = NSLock()
    private let profilesDir: URL

    init(paths: IrisPaths) { profilesDir = paths.profilesDir }

    private var mappingsURL: URL { profilesDir.appendingPathComponent("mappings.json") }

    private func profileURL(_ id: String) throws -> URL {
        guard AccessProfileStore.isValidProfileId(id) else { throw WriteError.invalidProfileId }
        return profilesDir.appendingPathComponent("\(id).json")
    }

    /// Writes `profiles/<id>.json`. With `replacing: false` an existing file is left alone and `exists` thrown.
    func writeProfile(id: String, _ profile: AccessProfile, replacing: Bool) throws {
        let url = try profileURL(id)
        try Self.lock.withLock {
            try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
            if !replacing, FileManager.default.fileExists(atPath: url.path) { throw WriteError.exists }
            try JSONEncoder().encode(profile).write(to: url, options: .atomic)
        }
    }

    func removeProfile(id: String) throws {
        let url = try profileURL(id)
        Self.lock.withLock { try? FileManager.default.removeItem(at: url) }
    }

    private func readEntries() throws -> [AccessProfileStore.MappingEntry] {
        guard FileManager.default.fileExists(atPath: mappingsURL.path) else { return [] }
        guard let data = try? Data(contentsOf: mappingsURL),
              let entries = try? JSONDecoder().decode([AccessProfileStore.MappingEntry].self, from: data) else {
            throw WriteError.unreadableMappings
        }
        return entries
    }

    private func writeEntries(_ entries: [AccessProfileStore.MappingEntry]) throws {
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: mappingsURL, options: .atomic)
    }

    private func matches(_ e: AccessProfileStore.MappingEntry, _ identity: IdentityKey) -> Bool {
        IdentityKey(transport: e.transport, issuer: e.issuer, id: e.id) == identity
    }

    /// Maps `identity` to `profileId`. An existing entry for the identity is kept (`exists`) unless `replacing`.
    func setMapping(_ identity: IdentityKey, profileId: String, replacing: Bool) throws {
        guard AccessProfileStore.isValidProfileId(profileId) else { throw WriteError.invalidProfileId }
        try Self.lock.withLock {
            var entries = try readEntries()
            if entries.contains(where: { matches($0, identity) }) {
                guard replacing else { throw WriteError.exists }
                entries.removeAll { matches($0, identity) }
            }
            entries.append(.init(transport: identity.transport, issuer: identity.issuer, id: identity.id, profileId: profileId))
            try writeEntries(entries)
        }
    }

    func removeMapping(_ identity: IdentityKey) throws {
        try Self.lock.withLock {
            var entries = try readEntries()
            let before = entries.count
            entries.removeAll { matches($0, identity) }
            if entries.count != before { try writeEntries(entries) }
        }
    }
}
