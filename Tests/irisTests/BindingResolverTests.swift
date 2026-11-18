import Foundation
import Testing
@testable import IrisKit

@Suite("BindingResolver: fail-closed resolution + per-axis no-widen (#974 Task 4)")
struct BindingResolverTests {
    private func tempStore() -> (AccessProfileStore, IrisPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-974-resolver-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try? FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        return (AccessProfileStore(paths: paths), paths)
    }

    private func write(_ profile: AccessProfile, id: String, to paths: IrisPaths) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: paths.profilesDir.appendingPathComponent("\(id).json"))
    }

    private func writeMappings(_ entries: [(IdentityKey, String)], to paths: IrisPaths) throws {
        let json = entries.map { key, profileId in
            "{\"transport\":\"\(key.transport)\",\"issuer\":\"\(key.issuer)\",\"id\":\"\(key.id)\",\"profileId\":\"\(profileId)\"}"
        }.joined(separator: ",")
        try Data("[\(json)]".utf8).write(to: paths.profilesDir.appendingPathComponent("mappings.json"))
    }

    // MARK: - At-the-door route path

    @Test("an mcpGuest with no identity is refused — no anonymous route runs as owner")
    func noIdentityIsRefused() {
        let (store, _) = tempStore()
        let result = BindingResolver.resolveBinding(principal: .mcpGuest, identity: nil, requestedDrop: nil, store: store)
        guard case .refused = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
    }

    @Test("main with no identity and no requested drop binds to owner")
    func mainWithNoDropBindsOwner() {
        let (store, _) = tempStore()
        let result = BindingResolver.resolveBinding(principal: .main, identity: nil, requestedDrop: nil, store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        #expect(binding.isOwner)
        #expect(binding.profile == .owner)
    }

    @Test("main can drop from owner into a real profile with set-valued axes (#1201 review finding 2)")
    func mainCanDropFromOwnerIntoARealProfile() throws {
        let (store, paths) = tempStore()
        // Every set-valued axis non-empty — exactly the shape the review probe used, and exactly
        // the shape isSubGrant(target, of: .owner) would previously refuse, since .owner's own
        // credentials/transports/fsRoots/skills are empty by construction (Task 2), not "all".
        let reviewer = AccessProfile(credentials: [AccountRef(type: "github", id: "iris-main")],
                                     memoryRead: .shared, transports: ["homelab-peer"],
                                     fsRoots: ["/tmp/work"], skills: ["web-researcher"],
                                     tools: .set(["search_memory"]))
        try write(reviewer, id: "reviewer", to: paths)

        let result = BindingResolver.resolveBinding(principal: .main, identity: nil,
                                                     requestedDrop: "reviewer", store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        #expect(binding.profile == reviewer)
        #expect(!binding.isOwner)
    }

    @Test("a requested drop that is not a sub-grant of the resolved source is refused")
    func requestedDropNotASubGrantIsRefused() throws {
        let (store, paths) = tempStore()
        let identity = IdentityKey(transport: "a2a", issuer: "homelab", id: "peer-1")
        let source = AccessProfile(memoryRead: .shared, tools: .set(["search_memory"]))
        try write(source, id: "homelab-peer", to: paths)
        // "reviewer" is wider than source on memoryRead — not a sub-grant.
        let reviewer = AccessProfile(memoryRead: .full, tools: .set(["search_memory"]))
        try write(reviewer, id: "reviewer", to: paths)
        try writeMappings([(identity, "homelab-peer")], to: paths)

        let result = BindingResolver.resolveBinding(principal: .subagent, identity: identity,
                                                     requestedDrop: "reviewer", store: store)
        guard case .refused = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
    }

    @Test("a requested drop that genuinely narrows every axis is bound")
    func requestedDropThatNarrowsIsBound() throws {
        let (store, paths) = tempStore()
        let identity = IdentityKey(transport: "a2a", issuer: "homelab", id: "peer-1")
        let source = AccessProfile(memoryRead: .full, tools: .set(["search_memory", "run_command"]))
        try write(source, id: "homelab-peer", to: paths)
        let narrower = AccessProfile(memoryRead: .shared, tools: .set(["search_memory"]))
        try write(narrower, id: "read-only", to: paths)
        try writeMappings([(identity, "homelab-peer")], to: paths)

        let result = BindingResolver.resolveBinding(principal: .subagent, identity: identity,
                                                     requestedDrop: "read-only", store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        #expect(binding.profile == narrower)
        #expect(!binding.isOwner)
    }

    @Test("resolving the reserved 'owner' id under a non-main principal is refused")
    func ownerUnderNonMainIsRefused() throws {
        let (store, paths) = tempStore()
        let identity = IdentityKey(transport: "mcp", issuer: "guest-app", id: "g1")
        try writeMappings([(identity, "owner")], to: paths)

        let result = BindingResolver.resolveBinding(principal: .mcpGuest, identity: identity,
                                                     requestedDrop: nil, store: store)
        guard case .refused = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
    }

    @Test("an identity with no mapping at all is refused — fail closed, not owner")
    func unmappedIdentityIsRefused() {
        let (store, _) = tempStore()
        let identity = IdentityKey(transport: "mcp", issuer: "nobody", id: "x")
        let result = BindingResolver.resolveBinding(principal: .mcpGuest, identity: identity,
                                                     requestedDrop: nil, store: store)
        guard case .refused = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
    }

    @Test("the no-drop door path for mcpGuest caps the resolved profile by the guest floor (dev-2 RE-REVIEW finding 1)")
    func doorPathNoDropCapsForMcpGuest() throws {
        let (store, paths) = tempStore()
        let identity = IdentityKey(transport: "mcp", issuer: "guest-app", id: "g1")
        let wide = AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                 memoryRead: .full, memoryWrite: .full, transports: ["peer-a"],
                                 tools: .set(["run_command", "send_to_session"]))
        try write(wide, id: "guest-profile", to: paths)
        try writeMappings([(identity, "guest-profile")], to: paths)

        let result = BindingResolver.resolveBinding(principal: .mcpGuest, identity: identity,
                                                     requestedDrop: nil, store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        #expect(binding.profile.credentials.isEmpty)
        #expect(binding.profile.transports.isEmpty)
        #expect(binding.profile.memoryWrite == .none)
        #expect(binding.profile.memoryRead == .task)
        guard case .set(let allowed) = binding.profile.tools else {
            Issue.record("expected .set after capping")
            return
        }
        #expect(allowed == ["send_to_session"])
    }

    @Test("the requested-drop door path for broker caps the resolved profile by the broker floor (dev-2 RE-REVIEW finding 1)")
    func doorPathDropCapsForBroker() throws {
        let (store, paths) = tempStore()
        let identity = IdentityKey(transport: "a2a", issuer: "homelab", id: "peer-1")
        // A wide source that genuinely narrows into "drop" on the isSubGrant axes, so the drop
        // itself succeeds — the floor cap is what must additionally narrow credentials/transports.
        let source = AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                   memoryRead: .full, memoryWrite: .full, transports: ["peer-a"],
                                   tools: .set(["run_command", "search_memory"]))
        try write(source, id: "homelab-peer", to: paths)
        let drop = AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                 memoryRead: .full, memoryWrite: .full, transports: ["peer-a"],
                                 tools: .set(["search_memory"]))
        try write(drop, id: "broker-drop", to: paths)
        try writeMappings([(identity, "homelab-peer")], to: paths)

        let result = BindingResolver.resolveBinding(principal: .broker, identity: identity,
                                                     requestedDrop: "broker-drop", store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        #expect(binding.profile.credentials.isEmpty)
        #expect(binding.profile.transports.isEmpty)
        #expect(binding.profile.memoryWrite == .none)
    }

    // MARK: - On-load (persisted) path

    @Test("a nil persisted id binds main to owner, refuses every other principal")
    func nilPersistedIdOwnerOnlyForMain() {
        let (store, _) = tempStore()
        guard case .bound(let binding) = BindingResolver.resolveBinding(principal: .main, persistedProfileId: nil, store: store) else {
            Issue.record("expected main to bind to owner")
            return
        }
        #expect(binding.isOwner)

        guard case .refused = BindingResolver.resolveBinding(principal: .subagent, persistedProfileId: nil, store: store) else {
            Issue.record("expected non-main with no persisted id to be refused")
            return
        }
    }

    @Test("a persisted id naming a now-deleted profile is refused, never loaded as owner")
    func deletedPersistedProfileIsRefused() {
        let (store, _) = tempStore()
        let result = BindingResolver.resolveBinding(principal: .subagent, persistedProfileId: "gone", store: store)
        guard case .refused = result else {
            Issue.record("expected .refused, got \(result)")
            return
        }
    }

    @Test("a persisted id naming a live profile binds that profile, not owner")
    func persistedLiveProfileBinds() throws {
        let (store, paths) = tempStore()
        let profile = AccessProfile(memoryRead: .shared)
        try write(profile, id: "web-researcher", to: paths)
        let result = BindingResolver.resolveBinding(principal: .subagent, persistedProfileId: "web-researcher", store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        #expect(binding.profile == profile)
        #expect(!binding.isOwner)
    }

    @Test("a resolved binding is capped by its own floor immediately, not left to whatever reads it later (#1201 review finding 4)")
    func resolvedBindingIsCappedByItsFloorAtResolutionTime() throws {
        let (store, paths) = tempStore()
        // The exact shape dev-2's probe used: a wide profile with a credential, full memory read
        // and a tool outside the broker's fixed floor.
        let wide = AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                 memoryRead: .full, tools: .set(["run_command", "search_memory"]))
        try write(wide, id: "wide", to: paths)

        let result = BindingResolver.resolveBinding(principal: .broker, persistedProfileId: "wide", store: store)
        guard case .bound(let binding) = result else {
            Issue.record("expected .bound, got \(result)")
            return
        }
        guard case .set(let allowed) = binding.profile.tools else {
            Issue.record("expected .set after capping")
            return
        }
        // Tools narrow immediately to the broker's own floor — run_command is gone.
        #expect(allowed == ["search_memory"])
        // Per the planner's ruling (superseding this test's original comment): the floor is the
        // H2 capability backstop, not just tools — a wide, arbitrary mapped profile's credentials
        // are denied by the floor itself, regardless of what the mapped profile happens to grant.
        #expect(binding.profile.credentials.isEmpty)
        #expect(binding.profile.memoryRead == .full)
    }

    // MARK: - isSubGrant

    @Test("isSubGrant is false when the target is narrower on four axes but wider on one (no majority rule)")
    func isSubGrantRejectsWiderOnOneAxis() {
        let source = AccessProfile(memoryRead: .shared, memoryWrite: .task, fsRoots: ["/a"],
                                   skills: ["x"], tools: .set(["search_memory"]))
        // Narrower on memoryRead/memoryWrite/fsRoots/skills, but wider on tools (an extra tool).
        let target = AccessProfile(memoryRead: .task, memoryWrite: .none, fsRoots: [],
                                   skills: [], tools: .set(["search_memory", "run_command"]))
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant is true when every axis is a subset or lower tier")
    func isSubGrantAcceptsTrueNarrowing() {
        let source = AccessProfile(credentials: [AccountRef(type: "github", id: "a")],
                                   memoryRead: .full, memoryWrite: .shared,
                                   transports: ["peer-a", "peer-b"], fsRoots: ["/a", "/b"],
                                   skills: ["x", "y"], tools: .set(["search_memory", "run_command"]))
        let target = AccessProfile(credentials: [], memoryRead: .shared, memoryWrite: .none,
                                   transports: ["peer-a"], fsRoots: ["/a"], skills: ["x"],
                                   tools: .set(["search_memory"]))
        #expect(BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant resolves symlinks before the FS subset test")
    func isSubGrantResolvesSymlinksInFSRoots() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-fs-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = AccessProfile(fsRoots: [real.path])
        let target = AccessProfile(fsRoots: [link.path])
        #expect(BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant rejects a target whose FS root escapes the source's grant even after symlink resolution")
    func isSubGrantRejectsAnEscapingFSRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-fs-escape-\(UUID().uuidString)")
        let granted = base.appendingPathComponent("granted", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let escapeLink = base.appendingPathComponent("escape")
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = AccessProfile(fsRoots: [granted.path])
        // A symlink that LOOKS like it's under the grant but resolves outside it.
        let target = AccessProfile(fsRoots: [escapeLink.path])
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    // Each test below holds every axis identical between source and target except the one named,
    // which is strictly wider in target — pinning the guard mutation-check found unpinned
    // (#1201 review, dev-2 finding 1: deleting any one of these five guards left all 13 original
    // tests green).

    private static func baseline(credentials: Set<AccountRef> = [AccountRef(type: "github", id: "a")],
                                 memoryRead: MemoryTier = .shared, memoryWrite: MemoryTier = .shared,
                                 transports: TransportGrant = ["peer-a"], fsRoots: FSGrant = ["/a"],
                                 skills: SkillGrant = ["x"], tools: ToolGrant = .set(["search_memory"])) -> AccessProfile {
        AccessProfile(credentials: credentials, memoryRead: memoryRead, memoryWrite: memoryWrite,
                     transports: transports, fsRoots: fsRoots, skills: skills, tools: tools)
    }

    @Test("isSubGrant rejects a target wider only on credentials")
    func isSubGrantRejectsWiderCredentials() {
        let source = Self.baseline()
        let target = Self.baseline(credentials: [AccountRef(type: "github", id: "a"), AccountRef(type: "google", id: "b")])
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant rejects a target wider only on memoryWrite")
    func isSubGrantRejectsWiderMemoryWrite() {
        let source = Self.baseline(memoryWrite: .task)
        let target = Self.baseline(memoryWrite: .full)
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant rejects a target wider only on transports")
    func isSubGrantRejectsWiderTransports() {
        let source = Self.baseline()
        let target = Self.baseline(transports: ["peer-a", "peer-b"])
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant rejects a target wider only on fsRoots")
    func isSubGrantRejectsWiderFSRoots() {
        let source = Self.baseline()
        let target = Self.baseline(fsRoots: ["/a", "/b"])
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant rejects a target wider only on skills")
    func isSubGrantRejectsWiderSkills() {
        let source = Self.baseline()
        let target = Self.baseline(skills: ["x", "y"])
        #expect(!BindingResolver.isSubGrant(target, of: source))
    }

    @Test("isSubGrant: anything is a sub-grant of .allTools, but .allTools is never a sub-grant of a concrete set")
    func isSubGrantToolsSentinelBehavior() {
        let unbounded = AccessProfile(tools: .allTools)
        let narrow = AccessProfile(tools: .set(["search_memory"]))
        #expect(BindingResolver.isSubGrant(narrow, of: unbounded))
        #expect(!BindingResolver.isSubGrant(unbounded, of: narrow))
    }
}
