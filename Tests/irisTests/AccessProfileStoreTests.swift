import Foundation
import Testing
@testable import IrisKit

@Suite("AccessProfileStore: the protected, read-only profile/mapping store (#974 Task 3, H3)")
struct AccessProfileStoreTests {
    private func tempPaths() -> IrisPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-974-profilestore-\(UUID().uuidString)", isDirectory: true)
        return IrisPaths(root: root)
    }

    @Test("reads a profile the UI writer wrote, as JSON under profiles/<id>.json")
    func readsAWrittenProfile() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        let profile = AccessProfile(memoryRead: .shared, tools: .set(["search_memory"]))
        let data = try JSONEncoder().encode(profile)
        try data.write(to: paths.profilesDir.appendingPathComponent("reviewer.json"))

        let store = AccessProfileStore(paths: paths)
        #expect(store.profile(id: "reviewer") == profile)
    }

    @Test("an unknown id reads nil — fail-closed, never a default profile")
    func unknownIdReadsNil() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = AccessProfileStore(paths: paths)
        #expect(store.profile(id: "no-such-profile") == nil)
    }

    @Test("an unreadable/corrupt profile file reads nil, not a default")
    func corruptProfileReadsNil() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.profilesDir.appendingPathComponent("broken.json"))
        let store = AccessProfileStore(paths: paths)
        #expect(store.profile(id: "broken") == nil)
    }

    @Test("allMappings reads the identity-key to profile-id mapping file")
    func readsMappings() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        let json = """
        [{"transport":"a2a","issuer":"homelab","id":"peer-1","profileId":"homelab-peer"}]
        """
        try Data(json.utf8).write(to: paths.profilesDir.appendingPathComponent("mappings.json"))

        let store = AccessProfileStore(paths: paths)
        let mappings = store.allMappings()
        #expect(mappings[IdentityKey(transport: "a2a", issuer: "homelab", id: "peer-1")] == "homelab-peer")
    }

    @Test("a missing mapping file yields an empty mapping, not a crash or a default identity")
    func missingMappingFileYieldsEmpty() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = AccessProfileStore(paths: paths)
        #expect(store.allMappings().isEmpty)
    }

    // `AccessProfileStore` declares no write method at all (H3) — verified by code review of its
    // public surface, not a runtime test (Swift has no clean negative-existence assertion for "no
    // method of this shape"). The #961 pane's writer is a separate type this store never exposes.

    // MARK: - Path traversal (#1201 review finding 1)

    @Test("a traversal id never escapes profilesDir — the probed case a wide profile sits outside it")
    func traversalIdCannotEscapeProfilesDir() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        // The exact probe dev-3 ran: a wide profile one level above profilesDir.
        let wide = AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                 memoryRead: .full, tools: .set(["run_command"]))
        try JSONEncoder().encode(wide).write(to: paths.root.appendingPathComponent("outside.json"))

        let store = AccessProfileStore(paths: paths)
        #expect(store.profile(id: "../outside") == nil)
    }

    @Test("an id containing a path separator, any dot, a NUL, empty, or a reserved name is rejected")
    func malformedIdsAreRejected() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = AccessProfileStore(paths: paths)
        for bad in ["a/b", "a\\b", "", ".hidden", "..", "/etc/passwd", "a.b", "a\0b", "owner", "mappings"] {
            #expect(store.profile(id: bad) == nil, "expected '\(bad)' to be rejected")
        }
    }

    @Test("a well-formed id with letters, numbers, underscore and hyphen still reads")
    func wellFormedIdsStillRead() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        let profile = AccessProfile(memoryRead: .task)
        try JSONEncoder().encode(profile).write(to: paths.profilesDir.appendingPathComponent("web-researcher_v2.json"))
        let store = AccessProfileStore(paths: paths)
        #expect(store.profile(id: "web-researcher_v2") == profile)
    }

    // MARK: - Ambiguous duplicate mappings (#1201 review, non-blocking note taken as a fix)

    @Test("a duplicate identity entry resolves to neither profile, not the last one written")
    func duplicateIdentityIsAmbiguousNotLastWins() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        let json = """
        [{"transport":"a2a","issuer":"homelab","id":"peer-1","profileId":"profile-a"},
         {"transport":"a2a","issuer":"homelab","id":"peer-1","profileId":"profile-b"}]
        """
        try Data(json.utf8).write(to: paths.profilesDir.appendingPathComponent("mappings.json"))
        let store = AccessProfileStore(paths: paths)
        #expect(store.allMappings()[IdentityKey(transport: "a2a", issuer: "homelab", id: "peer-1")] == nil)
    }
}
