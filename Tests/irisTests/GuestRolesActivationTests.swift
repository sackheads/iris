import Testing
import Foundation
@testable import IrisKit

/// #974 Task 16, slice 3: a provider guest's addressing reach (`role:<name>`) lives in the access-profile
/// store (`AccessProfile.peerRoles`); the Keychain roles item is a read-only fallback. This slice ships
/// ACTIVATED: `AppState.guestRoleAllowlist` is wired in production for the first time (Brian, 2026-11-21).
@MainActor
@Suite("a guest's roles come from the access-profile store (#974 Task 16, slice 3)", .serialized, .timeLimit(.minutes(2)))
struct GuestRolesActivationTests {
    private struct Rig {
        let root: URL
        let paths: IrisPaths
        let store: AccessProfileStore
        let writer: AccessProfileWriter
        let registry: ProviderTokenRegistry
        func tearDown() { try? FileManager.default.removeItem(at: root) }
        func keychainOnlyRegistry(_ keychain: KeychainManager) -> ProviderTokenRegistry { ProviderTokenRegistry(keychain: keychain) }
    }

    private func rig(clients: [String] = ["dev-1"]) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s3-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain, accessPaths: paths)
        for c in clients { _ = try registry.issueToken(forClientId: c) }
        return Rig(root: root, paths: paths, store: AccessProfileStore(paths: paths), writer: AccessProfileWriter(paths: paths), registry: registry)
    }

    private func roles(_ r: Rig, _ clientId: String = "dev-1") -> Set<String> {
        ProviderGuestGrants.allowedRoles(clientId: clientId, registry: r.registry, store: r.store)
    }

    private func put(_ r: Rig, profile: String, json: String, mapping clientId: String? = nil) throws {
        try FileManager.default.createDirectory(at: r.paths.profilesDir, withIntermediateDirectories: true)
        try json.write(to: r.paths.profilesDir.appendingPathComponent("\(profile).json"), atomically: true, encoding: .utf8)
        if let clientId {
            try r.writer.setMapping(try #require(IdentityKey.providerGuest(clientId: clientId)), profileId: profile, replacing: true)
        }
    }

    private func mappingsData(_ r: Rig) -> Data? { try? Data(contentsOf: r.paths.profilesDir.appendingPathComponent("mappings.json")) }

    // MARK: the generated profile id

    @Test("a generated profile id is a valid profile id, distinct per client even when '.' and '_' would collide, and nil for an unusable client")
    func generatedId() throws {
        let a = try #require(ProviderGuestGrants.generatedProfileId(forClientId: "a.b"))
        let b = try #require(ProviderGuestGrants.generatedProfileId(forClientId: "a_b"))
        #expect(a != b)
        #expect(AccessProfileStore.isValidProfileId(a) && AccessProfileStore.isValidProfileId(b))
        #expect(a == ProviderGuestGrants.generatedProfileId(forClientId: "a.b"), "stable")
        for bad in ["iris", "", "A", "../x", String(repeating: "a", count: 65)] {
            #expect(ProviderGuestGrants.generatedProfileId(forClientId: bad) == nil, Comment(rawValue: bad))
        }
    }

    // MARK: which source serves (the store wins; the Keychain is a fallback only for an unmapped guest)

    @Test("a guest with no mapping is served its Keychain roles; a mapped guest is served the store's, widened or narrowed; an unreadable store serves nothing")
    func sourceMatrix() throws {
        let r = try rig(); defer { r.tearDown() }
        #expect(roles(r).isEmpty, "registered, nothing granted anywhere")
        // Keychain only: write the roles item without touching the store.
        let keychainOnly = ProviderTokenRegistry(keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true))
        _ = try keychainOnly.issueToken(forClientId: "dev-1")
        try keychainOnly.setRoles(["reviewer", "builder"], forClientId: "dev-1")
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store) == ["reviewer", "builder"],
                "no mapping: the Keychain fallback serves")
        try put(r, profile: "ops", json: #"{"peerRoles":["reviewer"]}"#, mapping: "dev-1")
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store) == ["reviewer"],
                "mapped: the store wins and narrows the Keychain's grant")
        try put(r, profile: "ops", json: #"{"peerRoles":["reviewer","auditor"]}"#)
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store) == ["reviewer", "auditor"],
                "mapped: the store wins and widens it")
        try put(r, profile: "ops", json: #"{"memoryRead":2}"#)
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store).isEmpty,
                "mapped to a profile with no roles: no reach, the Keychain is not consulted")
        try put(r, profile: "ops", json: "{not json")
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store).isEmpty, "damaged profile: fail closed")
        try r.writer.removeProfile(id: "ops")
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store).isEmpty, "dangling mapping: fail closed")
        try "{not json".write(to: r.paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: keychainOnly, store: r.store).isEmpty, "damaged mappings file: fail closed")
    }

    @Test("a client with no registered token has no reach, whatever the store says")
    func unregisteredHasNoReach() throws {
        let r = try rig(clients: []); defer { r.tearDown() }
        try put(r, profile: "ops", json: #"{"peerRoles":["reviewer"]}"#, mapping: "ghost")
        #expect(roles(r, "ghost").isEmpty)
    }

    // MARK: migration: no silent widening or narrowing

    @Test("migration copies a Keychain grant into the store once, and the guest's reach is the same before and after")
    func migrationPreservesReach() throws {
        let r = try rig(); defer { r.tearDown() }
        // A pre-S3 install: roles in the Keychain item only.
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let legacy = ProviderTokenRegistry(keychain: keychain)
        _ = try legacy.issueToken(forClientId: "dev-1")
        try legacy.setRoles(["reviewer", "builder"], forClientId: "dev-1")
        let migrating = ProviderTokenRegistry(keychain: keychain, accessPaths: r.paths)
        let before = ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: migrating, store: r.store)
        #expect(before == ["reviewer", "builder"])
        #expect(migrating.migrateRolesToAccessStore().isEmpty)
        let after = ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: migrating, store: r.store)
        #expect(after == before, "reach is unchanged by migration")
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        guard case .found(let profile) = r.store.lookupMappedProfile(for: identity) else { Issue.record("not in the store"); return }
        #expect(profile == AccessProfile(peerRoles: ["reviewer", "builder"]), "the migrated profile grants the roles and nothing else")
        let bytes = mappingsData(r)
        #expect(migrating.migrateRolesToAccessStore().isEmpty)
        #expect(mappingsData(r) == bytes, "idempotent: a second run changes nothing")
        #expect(migrating.roles(forClientId: "dev-1") == ["reviewer", "builder"], "the Keychain item is left as it was")
    }

    @Test("migration never overwrites an existing mapping, and a skipped guest's reach is unchanged")
    func migrationSkipsMapped() throws {
        let r = try rig(); defer { r.tearDown() }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let legacy = ProviderTokenRegistry(keychain: keychain)
        _ = try legacy.issueToken(forClientId: "dev-1")
        try legacy.setRoles(["reviewer", "builder"], forClientId: "dev-1")
        try put(r, profile: "ops", json: #"{"peerRoles":["reviewer"]}"#, mapping: "dev-1")
        let migrating = ProviderTokenRegistry(keychain: keychain, accessPaths: r.paths)
        let before = ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: migrating, store: r.store)
        let bytes = mappingsData(r)
        _ = migrating.migrateRolesToAccessStore()
        #expect(mappingsData(r) == bytes, "the existing mapping is untouched")
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: migrating, store: r.store) == before, "the store entry keeps serving: reach unchanged")
        #expect(before == ["reviewer"])
    }

    @Test("migration skips, without overwriting, when the generated profile file exists with other content; the Keychain keeps serving, reach unchanged")
    func migrationSkipsDifferingGeneratedProfile() throws {
        let r = try rig(); defer { r.tearDown() }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let legacy = ProviderTokenRegistry(keychain: keychain)
        _ = try legacy.issueToken(forClientId: "dev-1")
        try legacy.setRoles(["reviewer"], forClientId: "dev-1")
        let ownId = try #require(ProviderGuestGrants.generatedProfileId(forClientId: "dev-1"))
        try put(r, profile: ownId, json: #"{"peerRoles":["auditor"]}"#)
        let migrating = ProviderTokenRegistry(keychain: keychain, accessPaths: r.paths)
        let before = ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: migrating, store: r.store)
        #expect(migrating.migrateRolesToAccessStore() == ["dev-1"])
        #expect(mappingsData(r) == nil, "no mapping was written")
        #expect(try String(contentsOf: r.paths.profilesDir.appendingPathComponent("\(ownId).json"), encoding: .utf8) == #"{"peerRoles":["auditor"]}"#)
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: migrating, store: r.store) == before)
        #expect(before == ["reviewer"], "the Keychain fallback serves: the client's current reach is preserved")
    }

    // MARK: the registry writes and clears the store

    @Test("setRoles records the grant in the store, and an empty set clears it")
    func setRolesWritesTheStore() throws {
        let r = try rig(); defer { r.tearDown() }
        try r.registry.setRoles(["reviewer"], forClientId: "dev-1")
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        guard case .found(let p) = r.store.lookupMappedProfile(for: identity) else { Issue.record("not stored"); return }
        #expect(p.peerRoles == ["reviewer"])
        #expect(r.registry.guestRoles(forClientId: "dev-1") == ["reviewer"])
        try r.registry.setRoles(["reviewer", "builder"], forClientId: "dev-1")
        #expect(r.registry.guestRoles(forClientId: "dev-1") == ["reviewer", "builder"])
        try r.registry.setRoles([], forClientId: "dev-1")
        #expect(r.registry.guestRoles(forClientId: "dev-1").isEmpty)
        if case .found = r.store.lookupMapping(for: identity) { Issue.record("mapping left behind") }
    }

    @Test("revoke clears the registry's own grant, and a client registered again does not inherit it")
    func revokeClearsAndReregisterDoesNotInherit() throws {
        let r = try rig(); defer { r.tearDown() }
        try r.registry.setRoles(["reviewer"], forClientId: "dev-1")
        try r.registry.revokeToken(forClientId: "dev-1")
        #expect(r.registry.guestRoles(forClientId: "dev-1").isEmpty)
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        if case .found = r.store.lookupMapping(for: identity) { Issue.record("revoke left the registry's mapping behind") }
        let ownId = try #require(ProviderGuestGrants.generatedProfileId(forClientId: "dev-1"))
        if case .found = r.store.lookupProfile(id: ownId) { Issue.record("revoke left the registry's profile behind") }
        _ = try r.registry.issueToken(forClientId: "dev-1")
        #expect(r.registry.guestRoles(forClientId: "dev-1").isEmpty, "a first registration starts with no roles")
    }

    @Test("a registry grant left in the store by a revoke whose store write failed is cleared by the next first registration, not inherited")
    func firstRegistrationClearsALeftoverGrant() throws {
        let r = try rig(clients: []); defer { r.tearDown() }
        let ownId = try #require(ProviderGuestGrants.generatedProfileId(forClientId: "dev-1"))
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        try r.writer.writeProfile(id: ownId, AccessProfile(peerRoles: ["reviewer"]), replacing: true)
        try r.writer.setMapping(identity, profileId: ownId, replacing: false)
        _ = try r.registry.issueToken(forClientId: "dev-1")
        #expect(r.registry.guestRoles(forClientId: "dev-1").isEmpty)
        if case .found = r.store.lookupMapping(for: identity) { Issue.record("the leftover mapping survived the first registration") }
    }

    @Test("an operator-authored mapping is never modified or deleted by setRoles or revoke; it keeps serving, and a token is still required")
    func operatorMappingIsLeftAlone() throws {
        let r = try rig(); defer { r.tearDown() }
        try put(r, profile: "ops", json: #"{"peerRoles":["auditor"]}"#, mapping: "dev-1")
        let bytes = mappingsData(r)
        #expect(throws: ProviderTokenRegistry.RegistryError.storeOwnsGrant) { try r.registry.setRoles(["reviewer"], forClientId: "dev-1") }
        #expect(mappingsData(r) == bytes)
        #expect(r.registry.guestRoles(forClientId: "dev-1") == ["auditor"], "the store wins over the registry's own grant")
        try r.registry.revokeToken(forClientId: "dev-1")
        #expect(mappingsData(r) == bytes)
        #expect(r.registry.guestRoles(forClientId: "dev-1").isEmpty, "revoked: no token, no reach, whatever the store says")
        _ = try r.registry.issueToken(forClientId: "dev-1")
        #expect(r.registry.guestRoles(forClientId: "dev-1") == ["auditor"], "documented: an operator's mapping outlives a revoke")
    }

    @Test("setRoles on an unreadable store changes nothing")
    func setRolesFailsClosedOnUnreadableStore() throws {
        let r = try rig(); defer { r.tearDown() }
        try FileManager.default.createDirectory(at: r.paths.profilesDir, withIntermediateDirectories: true)
        try "{not json".write(to: r.paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        #expect(throws: ProviderTokenRegistry.RegistryError.accessStoreUnreadable) { try r.registry.setRoles(["reviewer"], forClientId: "dev-1") }
        #expect(r.registry.roles(forClientId: "dev-1").isEmpty, "the Keychain item was not changed either")
    }

    @Test("a setRoles whose Keychain write fails leaves the store, and so the guest's reach, as it was")
    func failedSetRolesChangesNothing() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        let registry = ProviderTokenRegistry(keychain: keychain, accessPaths: paths)
        let store = AccessProfileStore(paths: paths)
        _ = try registry.issueToken(forClientId: "dev-1")
        _ = try registry.issueToken(forClientId: "dev-2")
        try registry.setRoles(["reviewer"], forClientId: "dev-1")
        keychain.simulateReadFailure(errSecIO)
        #expect(throws: (any Error).self) { try registry.setRoles(["reviewer", "builder"], forClientId: "dev-1") }
        #expect(throws: (any Error).self) { try registry.setRoles(["builder"], forClientId: "dev-2") }
        keychain.simulateReadFailure(nil)
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: registry, store: store) == ["reviewer"], "a granted guest keeps exactly its old reach")
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-2", registry: registry, store: store).isEmpty, "an ungranted guest gains nothing")
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-2"))
        if case .found = store.lookupMapping(for: identity) { Issue.record("a mapping was left behind by a failed call") }
    }

    @Test("a setRoles that clears a grant, and whose Keychain write fails, puts the grant back")
    func failedClearRestoresTheGrant() throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        let registry = ProviderTokenRegistry(keychain: keychain, accessPaths: paths)
        let store = AccessProfileStore(paths: paths)
        _ = try registry.issueToken(forClientId: "dev-1")
        try registry.setRoles(["reviewer"], forClientId: "dev-1")
        keychain.simulateReadFailure(errSecIO)
        #expect(throws: (any Error).self) { try registry.setRoles([], forClientId: "dev-1") }
        keychain.simulateReadFailure(nil)
        #expect(ProviderGuestGrants.allowedRoles(clientId: "dev-1", registry: registry, store: store) == ["reviewer"], "the failed clear did not take reach away")
        // The Keychain fallback alone would keep that answer true, so look at the store itself.
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        guard case .found(let profile) = store.lookupMappedProfile(for: identity) else { Issue.record("the grant was not put back in the store"); return }
        #expect(profile.peerRoles == ["reviewer"])
    }

    @Test("setRoles for a guest mapped to an operator's profile throws instead of reporting a success that changes nothing")
    func setRolesOnOperatorMappingThrows() throws {
        let r = try rig(); defer { r.tearDown() }
        try put(r, profile: "ops", json: #"{"peerRoles":["auditor"]}"#, mapping: "dev-1")
        #expect(throws: ProviderTokenRegistry.RegistryError.storeOwnsGrant) { try r.registry.setRoles(["reviewer"], forClientId: "dev-1") }
        #expect(r.registry.guestRoles(forClientId: "dev-1") == ["auditor"])
    }

    // MARK: the live mechanism: a guest's send through a real engine turn, both directions

    private struct World {
        let app: AppState
        let guest: UUID
        let reviewer: UUID
        let builder: UUID
    }

    private func world(_ r: Rig) -> World {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guest = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let reviewer = app.createNewConversation(title: "reviewer", select: false)
        let builder = app.createNewConversation(title: "builder", select: false)
        for (id, role) in [(reviewer, "reviewer"), (builder, "builder")] {
            app.conversations[app.conversations.firstIndex { $0.id == id }!].role = role
        }
        let registry = r.registry
        app.guestRoleAllowlist = { registry.guestRoles(forClientId: $0) }
        app.installEngine(IrisEngine(state: app, tier: .medium, principal: .main,
                                     client: FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "noted")]))], usageMetadata: nil)]),
                                     retryDelays: [], protectionEnabled: false))
        return World(app: app, guest: guest, reviewer: reviewer, builder: builder)
    }

    private func text(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.messages ?? []).map(\.content).joined(separator: "\n")
    }

    private func eventually(_ ms: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<(ms / 25) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// A guest engine whose model sends `message` to each address in turn, then ends.
    private func guestEngine(_ w: World, _ r: Rig, sends: [(to: String, message: String)]) -> IrisEngine {
        var responses = sends.enumerated().map { i, s in
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall:
                FunctionCall(name: "send_to_session", args: ["to": .string(s.to), "message": .string(s.message)], id: "c\(i)"))]))], usageMetadata: nil)
        }
        responses.append(GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil))
        return IrisEngine.makeGuestEngine(state: w.app, clientId: "dev-1", client: FakeLLMClient(responses: responses),
                                          protectionEnabled: false, store: r.store)
    }

    @Test("a guest granted a role through the registry reaches ONLY that role's session through a real turn")
    func grantedGuestReachesOnlyItsRole() async throws {
        let r = try rig(); defer { r.tearDown() }
        try r.registry.setRoles(["reviewer"], forClientId: "dev-1")
        let w = world(r)
        let engine = guestEngine(w, r, sends: [("role:reviewer", "to the reviewer"), ("role:builder", "to the builder")])
        await engine.processInput("go", source: "UI", conversationId: w.guest)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("to the reviewer") })
        let stamped = w.app.guestSteeredBinding(for: w.reviewer)
        #expect(stamped?.principal == .mcpGuest && stamped?.isOwner == false && stamped?.profile.peerRoles == ["reviewer"],
                "the recipient turn is a stamped non-owner .main turn")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!text(w.app, w.builder).contains("to the builder"), "an ungranted role stays unreachable")
    }

    @Test("a guest with no roles reaches nobody through a real turn")
    func ungrantedGuestReachesNobody() async throws {
        let r = try rig(); defer { r.tearDown() }
        let w = world(r)
        let engine = guestEngine(w, r, sends: [("role:reviewer", "to the reviewer"), ("role:builder", "to the builder")])
        await engine.processInput("go", source: "UI", conversationId: w.guest)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!text(w.app, w.reviewer).contains("to the reviewer"))
        #expect(!text(w.app, w.builder).contains("to the builder"))
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == nil)
    }

    @Test("a grant narrowed in the store reaches a live guest's NEXT send with no rebind")
    func narrowedGrantTakesEffectOnTheNextSend() async throws {
        let r = try rig(); defer { r.tearDown() }
        try r.registry.setRoles(["reviewer", "builder"], forClientId: "dev-1")
        let w = world(r)
        let first = guestEngine(w, r, sends: [("role:builder", "first to builder")])
        await first.processInput("go", source: "UI", conversationId: w.guest)
        #expect(await eventually { self.text(w.app, w.builder).contains("first to builder") })
        try r.registry.setRoles(["reviewer"], forClientId: "dev-1")
        let second = guestEngine(w, r, sends: [("role:builder", "second to builder")])
        await second.processInput("again", source: "UI", conversationId: w.guest)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!text(w.app, w.builder).contains("second to builder"))
    }

    // MARK: composition with #1289 (guest-origin turns read no profile memory) and #1285 (deny-all floor)

    @Test("a guest's granted send reaches a PROFILE-BOUND role session, and that guest-steered turn is not handed the profile's memory")
    func grantedSendToProfileBoundSessionCarriesNoProfileMemory() async throws {
        let r = try rig(); defer { r.tearDown() }
        try r.registry.setRoles(["reviewer"], forClientId: "dev-1")
        try FileManager.default.createDirectory(at: r.paths.memoryDir, withIntermediateDirectories: true)
        for f in [r.paths.userMd, r.paths.soulMd, r.paths.memoryMd] { try "owner text".write(to: f, atomically: true, encoding: .utf8) }
        try put(r, profile: "p1", json: #"{"memoryRead":1}"#)
        let notes = try #require(ProfileMemoryStore(paths: r.paths, profileId: "p1"))
        #expect(notes.replace(content: "PROFILE-NOTE-SECRET") == "Profile memory updated.")
        let w = world(r)
        w.app.conversations[w.app.conversations.firstIndex { $0.id == w.reviewer }!].accessProfileId = "p1"
        let capture = CapturingLLMClient(reply: "noted")
        w.app.installEngine(IrisEngine(state: w.app, tier: .medium, principal: .main, client: capture, retryDelays: [],
                                       streamResponses: false, protectionEnabled: false, sessionPeerCount: 0,
                                       memory: MemoryManager(paths: r.paths), accessProfileStore: r.store))
        let engine = guestEngine(w, r, sends: [("role:reviewer", "hello reviewer")])
        await engine.processInput("go", source: "UI", conversationId: w.guest)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("hello reviewer") }, "the granted send reached the profile-bound session")
        #expect(await eventually { !capture.requests.isEmpty })
        let system = capture.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(!system.contains("PROFILE-NOTE-SECRET"), "a turn a guest steered must not read the bound profile's memory back")
    }

    @Test("the owner engine asking about a provider guest's own conversation still gets the deny-all floor, with a role grant in place")
    func denyAllFloorHoldsWithAGrant() async throws {
        let r = try rig(); defer { r.tearDown() }
        try r.registry.setRoles(["reviewer"], forClientId: "dev-1")
        let w = world(r)
        let owner = IrisEngine(state: w.app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []), retryDelays: [], protectionEnabled: false)
        let b = await owner.bindingForCall(conversationId: w.guest)
        #expect(!b.isOwner && b.principal == .mcpGuest && b.profile.peerRoles.isEmpty, "a foreign engine never gets the guest's roles or the owner's binding")
    }

    // MARK: an owner-bound session never consults peerRoles

    @Test("guestRoleAllowlist is read only by the guest paths: guestTarget and the guest's list_sessions")
    func ownerPathsNeverConsultPeerRoles() throws {
        let sources = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        var uses: [String: Int] = [:]
        let walk = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        while let url = walk.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let n = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "guestRoleAllowlist").count - 1
            if n > 0 { uses[url.lastPathComponent] = n }
        }
        // AppState: the declaration, guestTarget, and the comment above the declaration; iris.swift: the guest's list_sessions;
        // MCPProviderRuntime: the one production assignment.
        #expect(Set(uses.keys) == ["AppState.swift", "iris.swift", "MCPProviderRuntime.swift"], "\(uses)")
        #expect(uses["iris.swift"] == 1 && uses["MCPProviderRuntime.swift"] == 1, "\(uses)")
        let runtime = try String(contentsOf: sources.appendingPathComponent("MCPProvider/MCPProviderRuntime.swift"), encoding: .utf8)
        #expect(runtime.contains("guests?.state.guestRoleAllowlist = { tokenRegistry.guestRoles(forClientId: $0) }"), "production is wired to the registry's one-store answer")
    }
}
