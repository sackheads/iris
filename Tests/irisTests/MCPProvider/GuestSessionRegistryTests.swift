import Testing
import Foundation
@testable import IrisKit

/// #1066 Phase 2, Task 7 (and #1124): the live guest sessions, their cap and idle TTL, revoke, and
/// that one client's engine can never run a turn on another client's session.
@MainActor
@Suite("Guest session registry (#1066)", .timeLimit(.minutes(2)))
struct GuestSessionRegistryTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = SuspendingClock().now
        var now: SuspendingClock.Instant { lock.withLock { instant } }
        func advance(_ d: Duration) { lock.withLock { instant = instant.advanced(by: d) } }
    }

    private struct Rig {
        let app: AppState
        let clock: Clock
        let registry: GuestSessionRegistry
    }

    private func rig(ttl: Duration = .seconds(900), maxLive: Int = 4) -> Rig {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let clock = Clock()
        let registry = GuestSessionRegistry(state: app, ttl: ttl, maxLive: maxLive, now: { clock.now }) { state, clientId in
            IrisEngine.makeGuestEngine(state: state, clientId: clientId, client: CapturingLLMClient(reply: "ok"), protectionEnabled: false)
        }
        return Rig(app: app, clock: clock, registry: registry)
    }

    private func exists(_ r: Rig, _ id: UUID) -> Bool { r.app.conversations.contains { $0.id == id } }

    // MARK: lifecycle

    @Test("the first call creates a hidden guest conversation with its engine; the second returns the same one")
    func createsOnceThenReuses() throws {
        let r = rig()
        let id = try r.registry.session(for: "dev-1")
        let conv = try #require(r.app.conversations.first { $0.id == id })
        #expect(conv.isGuest && conv.guestClientId == "dev-1")
        #expect(r.app.guestEngines[id]?.guestClientId == "dev-1")
        #expect(try r.registry.session(for: "dev-1") == id)
        #expect(r.registry.liveCount == 1)
    }

    @Test("two clients get two sessions, each with its own engine")
    func twoClients() throws {
        let r = rig()
        let a = try r.registry.session(for: "a"), b = try r.registry.session(for: "b")
        #expect(a != b)
        #expect(r.app.guestEngines[a]?.guestClientId == "a" && r.app.guestEngines[b]?.guestClientId == "b")
    }

    @Test("the fifth live session is refused with busy and creates nothing")
    func capRefusesTheFifth() throws {
        let r = rig()
        for c in ["a", "b", "c", "d"] { _ = try r.registry.session(for: c) }
        let before = r.app.conversations.count
        #expect(throws: GuestSessionError.busy) { try r.registry.session(for: "e") }
        #expect(r.app.conversations.count == before && r.registry.liveCount == 4)
        // An existing client is still served at the cap.
        _ = try r.registry.session(for: "a")
    }

    @Test("a session idle past the TTL is deleted: engine unregistered, peer requests closed; a later call makes a fresh one")
    func idleSessionIsReaped() throws {
        let r = rig(ttl: .seconds(900))
        let id = try r.registry.session(for: "a")
        let role = r.app.createNewConversation(title: "role", select: false)
        let request = PeerMessageRecord(msgId: try r.app.store.peers.newMessageId(), fromSession: role, toSession: id, contextId: "c",
                                        inReplyTo: nil, depth: 1, firstLine: "hi", sentAt: Date(), expectsReply: true,
                                        closedAt: nil, closeReason: nil)
        try r.app.store.peers.insert(request)
        r.clock.advance(.seconds(899))
        r.registry.reapIdle()
        #expect(exists(r, id), "not yet idle past the TTL")
        r.clock.advance(.seconds(2))
        r.registry.reapIdle()
        #expect(!exists(r, id) && r.app.guestEngines[id] == nil && r.registry.liveCount == 0)
        #expect(try r.app.store.peers.openRequests(from: role).isEmpty, "the request to the reaped guest was closed")
        let fresh = try r.registry.session(for: "a")
        #expect(fresh != id && exists(r, fresh))
    }

    @Test("touch extends a session; a call to session(for:) does too")
    func touchExtends() throws {
        let r = rig(ttl: .seconds(100))
        let a = try r.registry.session(for: "a"), b = try r.registry.session(for: "b")
        r.clock.advance(.seconds(80))
        r.registry.touch("a")
        _ = try r.registry.session(for: "b")
        r.clock.advance(.seconds(30))
        r.registry.reapIdle()
        #expect(exists(r, a) && exists(r, b), "both were touched 30 s ago")
        r.clock.advance(.seconds(80))
        r.registry.reapIdle()
        #expect(!exists(r, a) && !exists(r, b))
    }

    @Test("a session with a turn in flight is not closed, and closes once the turn has ended")
    func inFlightNotClosed() throws {
        let r = rig(ttl: .seconds(10))
        let id = try r.registry.session(for: "a")
        r.app.beginEngineTurn(for: id)
        r.clock.advance(.seconds(60))
        r.registry.reapIdle()
        #expect(exists(r, id), "a turn is running")
        r.app.endEngineTurn(for: id)
        r.registry.reapIdle()
        #expect(!exists(r, id))
    }

    @Test("closeAll deletes every session, a turn in flight or not, and frees the slots")
    func closeAllDeletesEverything() throws {
        let r = rig()
        let a = try r.registry.session(for: "a"), b = try r.registry.session(for: "b")
        r.app.beginEngineTurn(for: a)
        r.registry.closeAll()
        #expect(!exists(r, a) && !exists(r, b) && r.registry.liveCount == 0)
        #expect(r.app.guestEngines[a] == nil && r.app.guestEngines[b] == nil)
        r.registry.closeAll()   // idempotent
    }

    @Test("close(clientId:) deletes at once, and an unknown client is a no-op")
    func closeNow() throws {
        let r = rig()
        let id = try r.registry.session(for: "a")
        r.registry.close(clientId: "nobody")
        #expect(exists(r, id))
        r.registry.close(clientId: "a")
        #expect(!exists(r, id) && r.app.guestEngines[id] == nil && r.registry.liveCount == 0)
        // The slot is free again.
        for c in ["a", "b", "c", "d"] { _ = try r.registry.session(for: c) }
    }

    @Test("a session the owner deleted neither counts against the cap nor comes back")
    func deletedBehindItsBack() throws {
        let r = rig(maxLive: 1)
        let id = try r.registry.session(for: "a")
        r.app.deleteConversation(id)
        let fresh = try r.registry.session(for: "a")
        #expect(fresh != id && exists(r, fresh))
        r.app.deleteConversation(fresh)
        _ = try r.registry.session(for: "b")   // would be busy if the dead entry still counted
    }

    @Test("a restart starts empty: guest conversations are not persisted")
    func restartStartsEmpty() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let registry = GuestSessionRegistry(state: app) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, client: CapturingLLMClient(reply: "ok"), protectionEnabled: false) }
        _ = try registry.session(for: "a")
        let reloaded = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        #expect(!reloaded.conversations.contains { $0.isGuest })
        let fresh = GuestSessionRegistry(state: reloaded) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, client: CapturingLLMClient(reply: "ok"), protectionEnabled: false) }
        #expect(fresh.liveCount == 0)
    }

    @Test("the reaper is a dispatch source: the registry source holds no Task.sleep")
    func reaperIsADispatchSource() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IrisKit/MCPProvider/GuestSessionRegistry.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("Task.sleep"))
        #expect(source.contains("DispatchSource.makeTimerSource"))
        #expect(GuestSessionRegistry.reaperInterval == .seconds(60))
    }

    // MARK: #1124, one client's engine never runs another client's session

    @Test("a guest engine is refused a turn on another client's conversation, and runs its own")
    func crossGuestTurnRefused() async throws {
        let r = rig()
        let a = try r.registry.session(for: "a"), b = try r.registry.session(for: "b")
        let clientA = CapturingLLMClient(reply: "from a")
        let engineA = IrisEngine.makeGuestEngine(state: r.app, clientId: "a", client: clientA, protectionEnabled: false)
        await engineA.processInput("hello", source: "UI", conversationId: b)
        #expect(clientA.requests.isEmpty, "client a's engine made no model call on client b's session")
        let refused = r.app.conversations.first { $0.id == b }?.messages.map(\.content).joined(separator: "\n") ?? ""
        #expect(refused.contains(IrisEngine.principalMismatchRefusal))
        await engineA.processInput("hello", source: "UI", conversationId: a)
        #expect(clientA.requests.count == 1, "its own session still runs")
    }

    @Test("a guest engine with no client id, or on a conversation with none, is refused")
    func missingClientIdRefused() async {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let withId = app.createNewConversation(isGuest: true, guestClientId: "a", title: "g")
        let noId = app.createNewConversation(isGuest: true, guestClientId: nil, title: "g2")
        let anon = CapturingLLMClient(reply: "x")
        let anonEngine = IrisEngine(state: app, tier: .medium, principal: .mcpGuest, client: anon, retryDelays: [], protectionEnabled: false)
        await anonEngine.processInput("hi", source: "UI", conversationId: withId)
        let named = CapturingLLMClient(reply: "x")
        let namedEngine = IrisEngine.makeGuestEngine(state: app, clientId: "a", client: named, protectionEnabled: false)
        await namedEngine.processInput("hi", source: "UI", conversationId: noId)
        // Neither side names a client: nil must not equal nil.
        await anonEngine.processInput("hi", source: "UI", conversationId: noId)
        #expect(anon.requests.isEmpty && named.requests.isEmpty)
    }

    @Test("an engine is registered only for a guest conversation of its own client")
    func registrationAgrees() {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let b = app.createNewConversation(isGuest: true, guestClientId: "b", title: "g")
        let role = app.createNewConversation(title: "role", select: false)
        let engineA = IrisEngine.makeGuestEngine(state: app, clientId: "a", client: CapturingLLMClient(reply: "x"), protectionEnabled: false)
        #expect(!app.register(guestEngine: engineA, for: b))
        #expect(!app.register(guestEngine: engineA, for: role))
        #expect(!app.register(guestEngine: engineA, for: UUID()))
        #expect(app.guestEngines.isEmpty)
        let engineB = IrisEngine.makeGuestEngine(state: app, clientId: "b", client: CapturingLLMClient(reply: "x"), protectionEnabled: false)
        #expect(app.register(guestEngine: engineB, for: b))
    }

    @Test("a guest turn carries no turn_context block at all")
    func guestTurnHasNoTurnContext() async throws {
        let r = rig()
        let id = try r.registry.session(for: "a")
        _ = r.app.createNewConversation(title: "peer", select: false)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine.makeGuestEngine(state: r.app, clientId: "a", client: client, protectionEnabled: false)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let request = try #require(client.requests.first)
        let all = (request.systemInstruction?.parts.compactMap(\.text) ?? []) + request.contents.flatMap(\.parts).compactMap(\.text)
        #expect(all.filter { $0.contains("turn_context") }.isEmpty)

        // Control: the same world, asked of a main session, does carry one, so the check can fail.
        let mainId = r.app.createNewConversation(title: "main", select: false)
        let mainClient = CapturingLLMClient(reply: "ok")
        let main = IrisEngine(state: r.app, tier: .medium, client: mainClient, retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await main.processInput("hello", source: "UI", conversationId: mainId)
        let mainRequest = try #require(mainClient.requests.first)
        let mainText = mainRequest.contents.flatMap(\.parts).compactMap(\.text) + (mainRequest.systemInstruction?.parts.compactMap(\.text) ?? [])
        #expect(mainText.contains { $0.contains("<turn_context>") }, "control: a main turn carries a turn_context block")
    }
}
