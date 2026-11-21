import Foundation

/// #1245 (#974 C7, the narrowed local reflection): the one memory file a session bound to an access
/// profile may write, `profiles/<id>/memory.md`. A bound session's reflection used to be skipped
/// outright because the only stores it could write were the owner's; this is the store it writes
/// instead. It sits inside `IrisPaths.profilesDir`, so it is a protected write for every model tool
/// (`PermissionManager.isProtectedWrite`) and this type is the only writer. #1263 reads it back into
/// that same profile's own later turns, through the injection guard under its own `profile_memory`
/// tag, never into the owner's context or another profile's (`IrisEngine.guardedProfileMemoryText`).
struct ProfileMemoryStore {
    /// The one flippable threshold: the `memoryWrite` tier a profile needs for its session to reflect
    /// into this store. Below it the session writes nothing anywhere.
    static let minimumWriteTier: MemoryTier = .task

    /// Bytes. A reflection rewrites the whole file, so a runaway one cannot grow it past this.
    static let maxBytes = 16 * 1024

    static let fileName = "memory.md"

    static func refusalTooLarge() -> String {
        "Profile memory not updated: the content is over \(maxBytes / 1024) KB. Condense it and try again."
    }

    let profileId: String
    private let directory: URL

    /// nil for an id `AccessProfileStore` would not accept as a profile id (empty, a `.`, a `/`, a NUL, a
    /// reserved name): the id comes off a conversation's persisted profile, which is model-reachable, so
    /// it is never joined into a path unvalidated.
    init?(paths: IrisPaths, profileId: String) {
        guard AccessProfileStore.isValidProfileId(profileId) else { return nil }
        self.profileId = profileId
        directory = paths.profilesDir.appendingPathComponent(profileId, isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// At most `maxBytes`: `replace` already refuses to write more, but a file that got there some
    /// other way (hand-edited, a future writer) must not be fed to the prompt partially or in full
    /// past the cap either — this enforces the same bound independently on the read path, rather
    /// than trusting that the file on disk was always made through `replace`.
    func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL), data.count <= Self.maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the file. Refuses over the size cap, and refuses to write through a link at the profile's
    /// directory or at the file itself (the directory is made here, never followed from elsewhere).
    func replace(content: String) -> String {
        guard content.utf8.count <= Self.maxBytes else { return Self.refusalTooLarge() }
        let fm = FileManager.default
        for url in [directory, fileURL] {
            if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
                return "Profile memory not updated: its location is a link."
            }
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return "Profile memory updated."
        } catch {
            return "Profile memory not updated: \(error.localizedDescription)"
        }
    }
}
