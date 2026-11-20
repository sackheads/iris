import Testing
import Foundation
@testable import IrisKit

/// #1246 (C7): the automatic reflection consolidates the conversation's whole history into the
/// owner's memory, so it does not run once a guest's text has entered that history
/// (`Conversation.hasGuestInput`). The per-turn binding gate (#1244) cannot see this: the guest-steered
/// stamp is gone by the time the owner's own turn ends and the reflection fires. `/reflect` is the
/// owner's own ask and still runs, including under YOLO ("yolo is yolo", #1230): intentional.
@MainActor
@Suite("the automatic reflection skips a history a guest wrote into (#1246)", .serialized, .timeLimit(.minutes(2)))
struct GuestInputReflectionTests {
    private struct Harness {
        let state: AppState
        let client: FakeLLMClient
        let iris: UUID
        let source: UUID
    }

    private static let report = "Updated USER.md: prefers short answers."

    private static func reply(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    private func harness(guestInput: Bool, replies: [String]) throws -> Harness {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let iris = state.activityConversationId()
        let source = state.createNewConversation(title: "Launch plan", select: true)
        state.appendMessage(role: .user, content: "plan the launch", to: source)
        state.appendMessage(role: .agent, content: "Launch is Friday.", to: source)
        if let idx = state.conversations.firstIndex(where: { $0.id == source }) {
            state.conversations[idx].title = "Launch plan"
            state.conversations[idx].hasGuestInput = guestInput
            state.conversations[idx].messageCountSinceReflection = 29
        }
        let client = FakeLLMClient(responses: replies.map(Self.reply))
        state.installEngine(IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                       streamResponses: false, protectionEnabled: false, sessionPeerCount: 0))
        return Harness(state: state, client: client, iris: iris, source: source)
    }

    private func cards(_ h: Harness) -> [EventCard] {
        (h.state.conversations.first { $0.id == h.iris }?.messages ?? []).filter { $0.role == .event }.compactMap { EventCard.decode($0.content) }
    }

    private func messages(_ h: Harness) -> [ChatMessage] {
        h.state.conversations.first { $0.id == h.source }?.messages ?? []
    }

    private func waitForTurn(_ h: Harness) async throws {
        for _ in 0..<400 where h.state.hasTurnInFlight(for: h.source) { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(!h.state.hasTurnInFlight(for: h.source), "turn did not finish within the bounded wait")
    }

    @Test("control: an owner session with no guest input reflects after its 30th message and reports to Iris")
    func ownerReflects() async throws {
        let h = try harness(guestInput: false, replies: ["Noted.", Self.report])
        h.state.sendMessage("and one more thing")
        try await waitForTurn(h)
        #expect(h.client.callCount == 2, "the user's turn, then the reflection turn")
        #expect(cards(h).count == 1)
    }

    @Test("a session a guest has written into answers its own message and then does not reflect")
    func guestTouchedSessionDoesNotReflectAutomatically() async throws {
        let h = try harness(guestInput: true, replies: ["Noted.", Self.report])
        h.state.sendMessage("and one more thing")
        try await waitForTurn(h)
        #expect(h.client.callCount == 1, "only the user's own turn ran")
        #expect(!messages(h).contains { $0.content == "Triggering automatic memory reflection..." })
        #expect(cards(h).isEmpty, "nothing reaches Iris")
    }

    @Test("/reflect still runs in a guest-touched session: the owner asked for it")
    func manualReflectStillRuns() async throws {
        let h = try harness(guestInput: true, replies: [Self.report])
        h.state.sendMessage("/reflect")
        try await waitForTurn(h)
        #expect(h.client.callCount == 1)
        #expect(messages(h).contains { $0.content == "Triggering manual memory reflection..." })
        #expect(cards(h).count == 1)
    }

    // MARK: the flag is set where guest text really arrives, and it persists

    private func envelope() -> PeerEnvelope {
        PeerEnvelope(msgId: "aaaa0001", contextId: "ctx", depth: 1, expectsReply: false, replyTo: nil)
    }

    @Test("a guest's message delivered to a role session sets the flag; a peer's message does not")
    func guestDeliverySetsTheFlag() async throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guest = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let guestTarget = app.createNewConversation(title: "reviewer", select: false)
        let peerTarget = app.createNewConversation(title: "builder", select: false)
        let peer = app.createNewConversation(title: "peer", select: false)
        for (id, role) in [(guestTarget, "reviewer"), (peerTarget, "builder")] {
            app.conversations[app.conversations.firstIndex { $0.id == id }!].role = role
        }
        app.guestRoleAllowlist = { $0 == "dev-1" ? ["reviewer"] : [] }
        let client = FakeLLMClient(responses: [Self.reply("ok"), Self.reply("ok")])
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)

        _ = await engine.deliverPeerMessage("hello", from: peer, senderName: nil, to: peerTarget, envelope: envelope())
        #expect(app.conversations.first { $0.id == peerTarget }?.hasGuestInput == false, "a peer's message is not guest input")

        _ = await engine.deliverPeerMessage("run a sweep", from: guest, senderName: nil, to: guestTarget, envelope: envelope(),
                                            guestClientId: "dev-1")
        #expect(app.conversations.first { $0.id == guestTarget }?.hasGuestInput == true, "the guest's text reached this history")
    }

    @Test("hasGuestInput round-trips through the real store on INSERT and UPDATE, and an absent key reads false")
    func flagPersists() throws {
        let store = try ConversationStore.inMemory()
        var c = ConversationStoreTests.sample()
        c.hasGuestInput = true
        try store.apply([ConversationStoreTests.created(c)])
        #expect(try #require(try store.loadAll().conversations.first).hasGuestInput == true, "INSERT path")

        var other = ConversationStoreTests.sample()
        try store.apply([ConversationStoreTests.created(other)])
        #expect(try store.loadAll().conversations.first { $0.id == other.id }?.hasGuestInput == false, "default is false")
        other.hasGuestInput = true
        var change = ChangeSet(); change.add(.metadata)
        try store.apply([ConversationWrite(id: other.id, snapshot: other, changes: change)])
        #expect(try store.loadAll().conversations.first { $0.id == other.id }?.hasGuestInput == true, "UPDATE path")

        let coded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c))
        #expect(coded.hasGuestInput == true, "the Codable route keeps it too (decodeIfPresent, not a silent default)")
        let json = "{\"id\":\"\(UUID().uuidString)\",\"title\":\"legacy\"}"
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(decoded.hasGuestInput == false, "Invariant 1: absent key decodes false")
    }
}
