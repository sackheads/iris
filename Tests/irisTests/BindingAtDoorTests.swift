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

    @Test("accessProfileId persists through the UPDATE path too, not only INSERT (dev-2's #1202 review finding 3)")
    func accessProfileIdPersistsThroughTheUpdatePath() throws {
        let store = try ConversationStore.inMemory()
        var c = ConversationStoreTests.sample()
        try store.apply([ConversationStoreTests.created(c)])

        // An update that SETS the id, on a row that already exists (the UPDATE branch, not INSERT).
        c.accessProfileId = "reviewer"
        var setChange = ChangeSet(); setChange.add(.metadata)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: setChange)])
        var loaded = try store.loadAll()
        #expect(try #require(loaded.conversations.first).accessProfileId == "reviewer")

        // An update that CHANGES the id.
        c.accessProfileId = "web-researcher"
        var changeChange = ChangeSet(); changeChange.add(.metadata)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: changeChange)])
        loaded = try store.loadAll()
        #expect(try #require(loaded.conversations.first).accessProfileId == "web-researcher")
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

    @Test("makeBoundEngine still refuses .broker (#1203 only wired the tool-declaration/dispatch sites; dev-2's #1300 review finding 1: principalMismatch, hooks and composedSystemPrompt still assume .broker cannot reach this function)")
    func makeBoundEngineRefusesBroker() throws {
        let (store, paths) = tempStore()
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let identity = IdentityKey(transport: "a2a", issuer: "homelab", id: "peer-1")
        try write(AccessProfile(tools: .set(["search_memory"])), id: "broker-profile", to: paths)
        try writeMappings([(identity, "broker-profile")], to: paths)

        let engine = IrisEngine.makeBoundEngine(state: state, principal: .broker, identity: identity, store: store)
        #expect(engine == nil)
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
        #expect(child?.profile == wideParent.profile)
        // .fromBinding on every axis for subagent: the parent's own grant passes through, since
        // the floor defers to the binding rather than narrowing it further.
        #expect(child?.principal == .subagent)
    }

    @Test("a subagent of an owner parent is owner in profile, but its binding's principal is the subagent's own, not the parent's (#1202 review finding 1)")
    func subagentOfOwnerParentIsOwner() {
        let ownerParent = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        let child = SubagentManager.childBinding(ofParent: ownerParent, principal: .subagent)
        #expect(child?.profile == .owner)
        #expect(child?.isOwner == true)
        // The engine running this binding is .subagent, not .main — a Group B consumer reading
        // binding.principal (rather than engine.principal) must see the real principal.
        #expect(child?.principal == .subagent)
    }

    @Test("a nil parent binding (no caller has threaded one yet) yields no child binding — the engine falls back to its own default")
    func nilParentBindingYieldsNilChildBinding() {
        #expect(SubagentManager.childBinding(ofParent: nil, principal: .subagent) == nil)
    }

    // MARK: - IrisEngine's default binding: owner for .main only (#1202 review finding 2)

    @Test("an engine built with no explicit binding defaults to deny-all for every non-main principal, never owner")
    func nonMainEngineDefaultsToDenyAll() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        for principal: Principal in [.subagent, .evaluator, .mcpGuest, .broker] {
            let engine = IrisEngine(state: state, principal: principal)
            let binding = await engine.binding
            #expect(!binding.isOwner, "\(principal) should not default to isOwner")
            #expect(binding.profile.credentials.isEmpty, "\(principal) should default to deny-all credentials")
            guard case .set(let tools) = binding.profile.tools else {
                Issue.record("\(principal) should default to a concrete, capped tool set, not .allTools")
                continue
            }
            // AccessProfile() starts deny-all (empty tools), so capping by any floor (.fixed
            // intersects, .fromBinding passes through, .unbounded is unreachable here) leaves it
            // empty — the default is minimal regardless of which Principal it is.
            #expect(tools.isEmpty, "\(principal) should default to zero tools")
        }
    }

    @Test("an engine built with no explicit binding still defaults .main to owner — unchanged")
    func mainEngineStillDefaultsToOwner() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let engine = IrisEngine(state: state, principal: .main)
        let binding = await engine.binding
        #expect(binding.isOwner)
        #expect(binding.profile == .owner)
    }

    @Test("makeGuestEngine stamps an explicit, fail-closed mcpGuest-floor binding — never the owner shape (planner's ruling)")
    func makeGuestEngineStampsFailClosedBinding() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let engine = IrisEngine.makeGuestEngine(state: state, clientId: "dev-1")
        let binding = await engine.binding
        #expect(!binding.isOwner)
        #expect(binding.profile.credentials.isEmpty)
        // Capping a deny-all profile (AccessProfile()'s default .none) by the guest floor's
        // .task ceiling cannot RAISE it -- min(.none, .task) stays .none, which is even stricter
        // than the floor allows. That is correct: capping only ever narrows.
        #expect(binding.profile.memoryRead == .none)
        guard case .set(let tools) = binding.profile.tools else {
            Issue.record("expected a concrete tool set, not .allTools")
            return
        }
        #expect(tools.isSubset(of: GuestToolset.allowedNames))
    }
}

/// #974 Task 5: `SubagentManager.childBinding` is directly testable (`BindingAtDoorTests` above),
/// but that only pins the formula — not that `runSubagent`'s real `IrisEngine(...)` construction
/// actually passes its result in as `binding:`. A source scan pins the wiring line itself (dev-3's
/// #1202 review non-blocking note), the same pattern as `ToolExecutorGitIdentityWiringSourceScanTests`.
@Suite("SubagentManager binding wiring source scan (#974 Task 5)")
struct SubagentManagerBindingWiringSourceScanTests {
    @Test("the subagent IrisEngine construction passes binding: childBinding, not a literal nil")
    func bindingParameterIsWired() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/SubagentManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("let childBinding = Self.childBinding(ofParent: parentBinding, principal: .subagent)"),
                "the child binding must come from the real formula, not a hardcoded value")
        #expect(source.contains("binding: childBinding)"),
                "the engine construction must pass the computed childBinding -- removing it would silently drop the inheritance with every other test still green")
    }
}
