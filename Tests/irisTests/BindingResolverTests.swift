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

    @Test("isSubGrant: anything is a sub-grant of .allTools, but .allTools is never a sub-grant of a concrete set")
    func isSubGrantToolsSentinelBehavior() {
        let unbounded = AccessProfile(tools: .allTools)
        let narrow = AccessProfile(tools: .set(["search_memory"]))
        #expect(BindingResolver.isSubGrant(narrow, of: unbounded))
        #expect(!BindingResolver.isSubGrant(unbounded, of: narrow))
    }
}
