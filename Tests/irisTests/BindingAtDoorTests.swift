import Foundation
import Testing
@testable import IrisKit

@MainActor
@Suite("Binding built at the door + R2 persistence (#974 Task 5)", .timeLimit(.minutes(1)))
struct BindingAtDoorTests {
    // MARK: - R2 persistence: accessProfileId round-trips through the REAL store

    @Test("accessProfileId round-trips through ConversationStore, not just a Codable round-trip")
    func accessProfileIdRoundTripsThroughTheRealStore() throws {
        let store = try ConversationStore.inMemory()
        var c = ConversationStoreTests.sample()
        c.accessProfileId = "reviewer"
        try store.apply([ConversationStoreTests.created(c)])
        let loaded = try store.loadAll()
        #expect(loaded.skipped.isEmpty)
        let back = try #require(loaded.conversations.first)
        #expect(back.accessProfileId == "reviewer")
    }

    @Test("a conversation with no accessProfileId round-trips to nil, not owner")
    func absentAccessProfileIdRoundTripsToNil() throws {
        let store = try ConversationStore.inMemory()
        let c = ConversationStoreTests.sample()
        try store.apply([ConversationStoreTests.created(c)])
        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first)
        #expect(back.accessProfileId == nil)
    }

    @Test("Conversation decodes accessProfileId absent, per Invariant 1")
    func decodeAbsentAccessProfileId() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"legacy"}
        """
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(decoded.accessProfileId == nil)
    }

    // MARK: - makeBoundEngine: the at-the-door chokepoint

    private func tempStore() -> (AccessProfileStore, IrisPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-974-door-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try? FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        return (AccessProfileStore(paths: paths), paths)
    }

    private func write(_ profile: AccessProfile, id: String, to paths: IrisPaths) throws {
        try JSONEncoder().encode(profile).write(to: paths.profilesDir.appendingPathComponent("\(id).json"))
    }

    private func writeMappings(_ entries: [(IdentityKey, String)], to paths: IrisPaths) throws {
        let json = entries.map { key, profileId in
            "{\"transport\":\"\(key.transport)\",\"issuer\":\"\(key.issuer)\",\"id\":\"\(key.id)\",\"profileId\":\"\(profileId)\"}"
        }.joined(separator: ",")
        try Data("[\(json)]".utf8).write(to: paths.profilesDir.appendingPathComponent("mappings.json"))
    }

    @Test("an engine built for an mcpGuest with no mapped identity refuses to run — no owner fallback")
    func unmappedGuestRefusesToBuild() throws {
        let (store, _) = tempStore()
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let identity = IdentityKey(transport: "mcp", issuer: "nobody", id: "g1")
        let engine = IrisEngine.makeBoundEngine(state: state, principal: .mcpGuest, identity: identity, store: store)
        #expect(engine == nil)
    }

    @Test("an engine built for a mapped identity binds, and the engine's binding reflects the resolved profile")
    func mappedIdentityBuildsWithTheResolvedBinding() async throws {
        let (store, paths) = tempStore()
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let identity = IdentityKey(transport: "mcp", issuer: "guest-app", id: "g1")
        let profile = AccessProfile(memoryRead: .task, tools: .set(["send_to_session"]))
        try write(profile, id: "guest-profile", to: paths)
        try writeMappings([(identity, "guest-profile")], to: paths)

        let engine = try #require(IrisEngine.makeBoundEngine(state: state, principal: .mcpGuest, identity: identity, store: store))
        let binding = await engine.binding
        #expect(!binding.isOwner)
        #expect(binding.profile.memoryRead == .task)
    }

    // MARK: - SubagentManager: parent ∩ floor, never widened (Review Focus 2)

    @Test("a subagent's binding is the parent's binding capped by the subagent floor")
    func subagentBindingIsParentCappedByFloor() {
        let wideParent = AccessBinding(
            profile: AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                   memoryRead: .full, memoryWrite: .full,
                                   tools: .set(["run_command", "search_memory"])),
            principal: .subagent, isOwner: false)
        let child = SubagentManager.childBinding(ofParent: wideParent, principal: .subagent)
        let expected = wideParent.capped(by: PrincipalFloor.floor(for: .subagent))
        #expect(child == expected)
        // .fromBinding on every axis for subagent: the parent's own grant passes through, since
        // the floor defers to the binding rather than narrowing it further.
        #expect(child?.profile == wideParent.profile)
    }

    @Test("a subagent of an owner parent is owner (Invariant 1) — never widened, never narrowed by this step")
    func subagentOfOwnerParentIsOwner() {
        let ownerParent = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        let child = SubagentManager.childBinding(ofParent: ownerParent, principal: .subagent)
        #expect(child?.profile == .owner)
        #expect(child?.isOwner == true)
    }

    @Test("a nil parent binding (no caller has threaded one yet) yields no child binding — the engine falls back to its own default")
    func nilParentBindingYieldsNilChildBinding() {
        #expect(SubagentManager.childBinding(ofParent: nil, principal: .subagent) == nil)
    }
}
