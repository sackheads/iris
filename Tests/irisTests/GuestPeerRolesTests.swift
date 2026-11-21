import Testing
import Foundation
@testable import IrisKit

/// #974 Task 16, slice 1: the plumbing the shipped-guest retrofit stands on, with no behaviour change.
/// `peerRoles` is the message-addressing reach `ProviderTokenRegistry` roles carry (an `AccessProfile` axis,
/// not folded into `transports`, which the guest floor fixes to `[]`); `IdentityKey.providerGuest` names a
/// guest the provider's door authenticated; the store can now say "absent" apart from "unreadable".
@Suite("a guest's roles are an access axis, and a guest has an identity (#974 Task 16, slice 1)")
struct GuestPeerRolesTests {
    // MARK: every axis is handled everywhere an axis must be

    /// One entry per `AccessProfile` stored property: how to make a profile WIDER than `base` on that axis only.
    /// A property with no entry here fails `everyAxisIsListed`, so a new axis cannot be added without deciding
    /// how `capped(by:)`, `isSubGrant` and the Codable round trip treat it (the trap `peerRoles` itself nearly
    /// fell into: `capped(by:)` rebuilds the profile axis by axis, and one left out is silently zeroed).
    private static let widen: [String: @Sendable (inout AccessProfile) -> Void] = [
        "credentials": { $0.credentials = [AccountRef(type: "github", id: "x")] },
        "memoryRead": { $0.memoryRead = .full },
        "memoryWrite": { $0.memoryWrite = .full },
        "transports": { $0.transports = ["homelab"] },
        "fsRoots": { $0.fsRoots = ["/tmp/x"] },
        "skills": { $0.skills = ["s"] },
        "tools": { $0.tools = .set(["read_file"]) },
        "peerRoles": { $0.peerRoles = ["reviewer"] },
    ]

    @Test("every AccessProfile stored property is listed here")
    func everyAxisIsListed() {
        let names = Set(Mirror(reflecting: AccessProfile()).children.compactMap(\.label))
        #expect(names == Set(Self.widen.keys), "axes not covered: \(names.symmetricDifference(Set(Self.widen.keys)).sorted())")
    }

    @Test("capping by main's unbounded floor changes no axis; a wider profile is never a sub-grant of the base on any axis; the base is a sub-grant of it")
    func everyAxisSurvivesCappingAndIsSeenBySubGrant() throws {
        for (axis, makeWider) in Self.widen {
            var wide = AccessProfile()
            makeWider(&wide)
            let capped = AccessBinding(profile: wide, principal: .main, isOwner: false).capped(by: PrincipalFloor.floor(for: .main))
            #expect(capped.profile == wide, "\(axis): capped(by: .main) dropped or changed it")
            #expect(!BindingResolver.isSubGrant(wide, of: AccessProfile()), "\(axis): isSubGrant cannot see the axis, so a drop could widen it")
            #expect(BindingResolver.isSubGrant(AccessProfile(), of: wide), "\(axis)")
            let round = try JSONDecoder().decode(AccessProfile.self, from: JSONEncoder().encode(wide))
            #expect(round == wide, "\(axis): does not survive Codable")
        }
    }

    // MARK: peerRoles

    @Test("an old profile file with no peerRoles key decodes to no roles; names that do not normalise are dropped; the rest are normalised")
    func decoding() throws {
        let old = try JSONDecoder().decode(AccessProfile.self, from: Data(#"{"memoryRead":2}"#.utf8))
        #expect(old.peerRoles.isEmpty)
        let named = try JSONDecoder().decode(AccessProfile.self, from: Data(#"{"peerRoles":["Reviewer"," builder ","../x","","a b"]}"#.utf8))
        #expect(named.peerRoles == ["reviewer", "builder"], "\(named.peerRoles)")
    }

    @Test("the guest floor does not zero a guest's roles, and caps everything else as before")
    func guestFloorKeepsRoles() {
        let profile = AccessProfile(credentials: [AccountRef(type: "github", id: "x")], memoryRead: .full, memoryWrite: .full,
                                    transports: ["homelab"], tools: .set(["read_file", "list_sessions"]), peerRoles: ["reviewer"])
        let capped = AccessBinding(profile: profile, principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
        #expect(capped.profile.peerRoles == ["reviewer"])
        #expect(capped.profile.credentials.isEmpty && capped.profile.transports.isEmpty && capped.profile.memoryWrite == .none)
        #expect(capped.profile.memoryRead == .task)
    }

    @Test("two guests' bindings meet on roles: a subset wins, incomparable roles fall to no roles")
    func meetingGuestBindings() {
        func guest(_ roles: Set<String>) -> AccessBinding {
            AccessBinding(profile: AccessProfile(peerRoles: roles), principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
        }
        #expect(AccessBinding.meetGuestBindings(guest(["a"]), guest(["a", "b"])).profile.peerRoles == ["a"])
        #expect(AccessBinding.meetGuestBindings(guest(["a", "b"]), guest(["a"])).profile.peerRoles == ["a"])
        #expect(AccessBinding.meetGuestBindings(guest(["a"]), guest(["b"])).profile.peerRoles.isEmpty, "incomparable: fail closed")
    }

    @Test("a profile mapped to a guest identity resolves with its roles")
    func mappedGuestResolvesWithRoles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try #"{"peerRoles":["reviewer"]}"#.write(to: paths.profilesDir.appendingPathComponent("guest-dev-1.json"), atomically: true, encoding: .utf8)
        try #"[{"transport":"mcp","issuer":"iris-mcp-provider","id":"dev-1","profileId":"guest-dev-1"}]"#
            .write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        let identity = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        guard case .bound(let binding) = BindingResolver.resolveBinding(principal: .mcpGuest, identity: identity, requestedDrop: nil,
                                                                        store: AccessProfileStore(paths: paths)) else {
            Issue.record("a mapped guest should resolve"); return
        }
        #expect(binding.profile.peerRoles == ["reviewer"] && !binding.isOwner)
        let other = try #require(IdentityKey.providerGuest(clientId: "dev-2"))
        if case .bound = BindingResolver.resolveBinding(principal: .mcpGuest, identity: other, requestedDrop: nil, store: AccessProfileStore(paths: paths)) {
            Issue.record("an unmapped guest must not resolve through another guest's entry")
        }
    }

    // MARK: the identity

    @Test("a provider guest's identity is the constant issuer plus its client id; a client id the registry would refuse names nothing")
    func providerGuestIdentity() {
        #expect(IdentityKey.providerGuest(clientId: "dev-1") == IdentityKey(transport: "mcp", issuer: "iris-mcp-provider", id: "dev-1"))
        #expect(IdentityKey.providerGuest(clientId: "dev-1") != IdentityKey.providerGuest(clientId: "dev-2"))
        for bad in ["", "iris", "Dev-1", "a b", "../x", "dev\u{0}1", "ｉｒｉｓ", String(repeating: "a", count: 65)] {
            #expect(IdentityKey.providerGuest(clientId: bad) == nil, "\(bad.debugDescription)")
        }
    }

    // MARK: absent is not unreadable

    @Test("the store tells a missing entry from a damaged one")
    func lookups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s1-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        let store = AccessProfileStore(paths: paths)
        let id = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        func isAbsent<V>(_ l: AccessProfileStore.Lookup<V>) -> Bool { if case .absent = l { return true }; return false }
        func isUnreadable<V>(_ l: AccessProfileStore.Lookup<V>) -> Bool { if case .unreadable = l { return true }; return false }

        #expect(isAbsent(store.lookupProfile(id: "nope")) && isAbsent(store.lookupMapping(for: id)), "nothing on disk")

        try #"{"peerRoles":["a"]}"#.write(to: paths.profilesDir.appendingPathComponent("p.json"), atomically: true, encoding: .utf8)
        if case .found(let p) = store.lookupProfile(id: "p") { #expect(p.peerRoles == ["a"]) } else { Issue.record("expected found") }
        try "{not json".write(to: paths.profilesDir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        #expect(isUnreadable(store.lookupProfile(id: "broken")))

        let entry = #"{"transport":"mcp","issuer":"iris-mcp-provider","id":"dev-1","profileId":"p"}"#
        try "[\(entry)]".write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        if case .found(let pid) = store.lookupMapping(for: id) { #expect(pid == "p") } else { Issue.record("expected found") }
        let other = try #require(IdentityKey.providerGuest(clientId: "dev-2"))
        #expect(isAbsent(store.lookupMapping(for: other)), "readable file, no entry for this identity")
        try "[\(entry),\(entry.replacingOccurrences(of: "\"p\"", with: "\"q\""))]".write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        #expect(isUnreadable(store.lookupMapping(for: id)), "two conflicting entries are ambiguous, not absent")
        try "garbage".write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        #expect(isUnreadable(store.lookupMapping(for: id)))

        // An invalid id is not "no such profile": only a mapping can name it, and that is an entry with no usable profile.
        for bad in ["", "../x", "a/b", "mappings", "owner"] { #expect(isUnreadable(store.lookupProfile(id: bad)), "\(bad.debugDescription)") }
        // A profile "file" that is a directory is unreadable, not absent.
        try FileManager.default.createDirectory(at: paths.profilesDir.appendingPathComponent("dir.json"), withIntermediateDirectories: true)
        #expect(isUnreadable(store.lookupProfile(id: "dir")))
    }

    @Test("the one answer a gate acts on: absent only when the identity has no mapping; a dangling, invalid or damaged mapped profile is unreadable")
    func mappedProfileLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s1-mapped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        let store = AccessProfileStore(paths: paths)
        let id = try #require(IdentityKey.providerGuest(clientId: "dev-1"))
        func map(_ profileId: String) throws {
            try #"[{"transport":"mcp","issuer":"iris-mcp-provider","id":"dev-1","profileId":"\#(profileId)"}]"#
                .write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        }
        func kind(_ l: AccessProfileStore.Lookup<AccessProfile>) -> String {
            switch l { case .found: "found"; case .absent: "absent"; case .unreadable: "unreadable" }
        }
        #expect(kind(store.lookupMappedProfile(for: id)) == "absent", "no mappings file: the fallback is allowed")
        try map("p")
        #expect(kind(store.lookupMappedProfile(for: id)) == "unreadable", "mapped, but the profile file does not exist (dangling)")
        try "{not json".write(to: paths.profilesDir.appendingPathComponent("p.json"), atomically: true, encoding: .utf8)
        #expect(kind(store.lookupMappedProfile(for: id)) == "unreadable", "mapped to a damaged profile")
        try #"{"peerRoles":["a"]}"#.write(to: paths.profilesDir.appendingPathComponent("p.json"), atomically: true, encoding: .utf8)
        #expect(kind(store.lookupMappedProfile(for: id)) == "found")
        try map("../x")
        #expect(kind(store.lookupMappedProfile(for: id)) == "unreadable", "mapped to a path-shaped id")
        try map("")
        #expect(kind(store.lookupMappedProfile(for: id)) == "unreadable", "mapped to an empty id")
        let other = try #require(IdentityKey.providerGuest(clientId: "dev-2"))
        #expect(kind(store.lookupMappedProfile(for: other)) == "absent", "a readable file with no entry for this identity")
        try "garbage".write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        #expect(kind(store.lookupMappedProfile(for: id)) == "unreadable", "an unreadable mappings file is not an absent mapping")
    }
}
