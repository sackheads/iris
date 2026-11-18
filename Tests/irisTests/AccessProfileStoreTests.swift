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
}
