import Testing
import Foundation
@testable import IrisKit

/// #974 Task 16, slice 2: the shipped guest door resolves its binding from the guest's
/// `(mcp, iris-mcp-provider, clientId)` identity. An unmapped guest, and one whose mapping cannot be read,
/// keep today's deny-all `.mcpGuest` floor binding; a mapped guest gets its profile, capped by the floor.
/// Nothing here activates roles: `guestRoleAllowlist` is still unwired (slice 3).
@MainActor
@Suite("the guest door binds a guest from its identity (#974 Task 16, slice 2)", .timeLimit(.minutes(1)))
struct GuestDoorBindingTests {
    private func home() throws -> (IrisPaths, AccessProfileStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-t16s2-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        return (paths, AccessProfileStore(paths: paths), root)
    }

    private func map(_ clientId: String, to profileId: String, json: String?, in paths: IrisPaths) throws {
        if let json { try json.write(to: paths.profilesDir.appendingPathComponent("\(profileId).json"), atomically: true, encoding: .utf8) }
        let file = paths.profilesDir.appendingPathComponent("mappings.json")
        var entries: [String] = []
        if let old = try? String(contentsOf: file, encoding: .utf8), old.count > 2 {
            entries.append(String(old.dropFirst().dropLast()))
        }
        entries.append(#"{"transport":"mcp","issuer":"iris-mcp-provider","id":"\#(clientId)","profileId":"\#(profileId)"}"#)
        try "[\(entries.joined(separator: ","))]".write(to: file, atomically: true, encoding: .utf8)
    }

    private func state() throws -> AppState {
        AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
    }

    private let wide = #"{"credentials":[{"type":"github","id":"x"}],"memoryRead":3,"memoryWrite":3,"transports":["homelab"],"fsRoots":["/tmp/x"],"skills":["s"],"peerRoles":["reviewer"]}"#

    private func denyAll(_ b: AccessBinding) -> Bool {
        guard case .set(let tools) = b.profile.tools else { return false }
        return !b.isOwner && b.principal == .mcpGuest && b.profile.credentials.isEmpty && b.profile.memoryRead == .none
            && b.profile.peerRoles.isEmpty && tools.isSubset(of: GuestToolset.allowedNames)
    }

    @Test("an unmapped guest keeps the deny-all floor binding, as before")
    func unmappedIsDenyAll() throws {
        let (_, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(denyAll(IrisEngine.providerGuestBinding(clientId: "dev-1", store: store)))
    }

    @Test("a mapped guest gets its profile's roles, and everything else the floor caps stays capped")
    func mappedIsCapped() throws {
        let (paths, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try map("dev-1", to: "guest-dev-1", json: wide, in: paths)
        let b = IrisEngine.providerGuestBinding(clientId: "dev-1", store: store)
        #expect(b.profile.peerRoles == ["reviewer"] && !b.isOwner && b.principal == .mcpGuest)
        #expect(b.profile.credentials.isEmpty && b.profile.memoryWrite == .none && b.profile.transports.isEmpty)
        #expect(b.profile.memoryRead <= .task)
        guard case .set(let tools) = b.profile.tools else { Issue.record("expected a fixed tool set"); return }
        #expect(tools.isSubset(of: GuestToolset.allowedNames))
    }

    @Test("a mapping that cannot be read, or names no usable profile, fails closed to deny-all")
    func unreadableIsDenyAll() throws {
        let (paths, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try map("dangling", to: "gone", json: nil, in: paths)
        try map("broken", to: "broken-p", json: "{not json", in: paths)
        try map("owner-ish", to: "owner", json: wide, in: paths)
        for id in ["dangling", "broken", "owner-ish"] {
            #expect(denyAll(IrisEngine.providerGuestBinding(clientId: id, store: store)), Comment(rawValue: id))
        }
        try "{not json".write(to: paths.profilesDir.appendingPathComponent("mappings.json"), atomically: true, encoding: .utf8)
        #expect(denyAll(IrisEngine.providerGuestBinding(clientId: "dev-1", store: store)), "damaged mappings file")
    }

    @Test("a client id the provider would refuse binds to deny-all, never to a mapping")
    func badClientIdIsDenyAll() throws {
        let (_, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(denyAll(IrisEngine.providerGuestBinding(clientId: "iris", store: store)))
        #expect(denyAll(IrisEngine.providerGuestBinding(clientId: "../x", store: store)))
    }

    @Test("two guests carry two bindings: one's roles are not the other's")
    func twoGuestsTwoBindings() async throws {
        let (paths, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try map("dev-1", to: "p1", json: #"{"peerRoles":["reviewer"]}"#, in: paths)
        try map("dev-2", to: "p2", json: #"{"peerRoles":["builder"]}"#, in: paths)
        let s = try state()
        let e1 = IrisEngine.makeGuestEngine(state: s, clientId: "dev-1", protectionEnabled: false, store: store)
        let e2 = IrisEngine.makeGuestEngine(state: s, clientId: "dev-2", protectionEnabled: false, store: store)
        let e3 = IrisEngine.makeGuestEngine(state: s, clientId: "dev-3", protectionEnabled: false, store: store)
        #expect(await e1.binding.profile.peerRoles == ["reviewer"])
        #expect(await e2.binding.profile.peerRoles == ["builder"])
        #expect(await e3.binding.profile.peerRoles.isEmpty)
    }

    @Test("a turn through processInput on a mapped guest's engine runs under the mapped binding, and still offers only the guest floor's tools")
    func liveTurn() async throws {
        let (paths, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try map("dev-1", to: "guest-dev-1", json: wide.replacingOccurrences(of: #""peerRoles""#, with: #""tools":["run_command","read_file","write_file","send_to_session"],"peerRoles""#), in: paths)
        let s = try state()
        let id = s.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine.makeGuestEngine(state: s, clientId: "dev-1", client: client, protectionEnabled: false, store: store)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let request = try #require(client.requests.first)
        #expect(IrisEngine.offeredToolNames(request).isSubset(of: GuestToolset.allowedNames), "\(IrisEngine.offeredToolNames(request))")
        let seen = await engine.bindingForCall(conversationId: id)
        #expect(seen.profile.peerRoles == ["reviewer"] && !seen.isOwner)
    }

    @Test("a guest engine does not run a turn on another client's conversation")
    func otherClientsConversationIsRefused() async throws {
        let (paths, store, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try map("dev-1", to: "p1", json: #"{"peerRoles":["reviewer"]}"#, in: paths)
        let s = try state()
        let theirs = s.createNewConversation(isGuest: true, guestClientId: "dev-2", title: "guest")
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine.makeGuestEngine(state: s, clientId: "dev-1", client: client, protectionEnabled: false, store: store)
        await engine.processInput("hello", source: "UI", conversationId: theirs)
        #expect(client.requests.isEmpty)
    }

    @Test("makeGuestEngine hands the store it resolved from to the engine, so a later read sees the same one")
    func storeIsThreaded() throws {
        let source = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift"), encoding: .utf8)
        // #1417 put guestSessionsEnabled between the two, on the line above.
        #expect(source.contains("guestClientId: clientId, guestSessionsEnabled: guestSessionsEnabled,"))
        #expect(source.contains("binding: binding, accessProfileStore: store)"))
    }
}
