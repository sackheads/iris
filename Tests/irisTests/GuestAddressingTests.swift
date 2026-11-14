import Testing
import Foundation
@testable import IrisKit

/// #1066 Phase 2, Task 5: who a guest can reach. A guest addresses `role:<name>` for a role its
/// client was granted, and nothing else: not `iris`, a session id (its own or another guest's), a
/// name, a topic, an ungranted role in any case, or a vacant one. Every refusal is one text, so it
/// says nothing about whether the session exists.
@MainActor
@Suite("MCP guest addressing (#1066)", .timeLimit(.minutes(2)))
struct GuestAddressingTests {
    private struct World {
        let app: AppState
        let guest: UUID
        let otherGuest: UUID
        let reviewer: UUID
        let builder: UUID
        let iris: UUID
        let worker: UUID
    }

    private func world(granted: Set<String> = ["reviewer"], clientId: String? = "dev-1") -> World {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guest = app.createNewConversation(isGuest: true, guestClientId: clientId, title: "guest")
        let otherGuest = app.createNewConversation(isGuest: true, guestClientId: "dev-2", title: "other guest")
        let reviewer = app.createNewConversation(title: "reviewer", select: false)
        let builder = app.createNewConversation(title: "builder", select: false)
        let iris = app.createNewConversation(title: "iris", select: false)
        let worker = app.createNewConversation(title: "worker", select: false)
        for (id, role) in [(reviewer, "reviewer"), (builder, "builder")] {
            let idx = app.conversations.firstIndex { $0.id == id }!
            app.conversations[idx].role = role
        }
        app.conversations[app.conversations.firstIndex { $0.id == iris }!].isPinned = true
        app.conversations[app.conversations.firstIndex { $0.id == worker }!].sessionCard = SessionCard(name: "worker-bee", description: "works")
        app.guestRoleAllowlist = { $0 == "dev-1" ? granted : [] }
        return World(app: app, guest: guest, otherGuest: otherGuest, reviewer: reviewer, builder: builder, iris: iris, worker: worker)
    }

    private let refusal = AppState.PeerSendDecision.refused(AppState.GuestAddressRefusal.text)

    // MARK: a new send

    @Test("a guest reaches the holder of a granted role, in any case and with stray whitespace")
    func grantedRoleResolves() {
        let w = world()
        for address in ["role:reviewer", "ROLE:Reviewer", "  role:reviewer  "] {
            guard case .allowed(let target, _) = w.app.decidePeerSend(to: address, from: w.guest, replyTarget: nil) else {
                Issue.record("\(address) was refused"); continue
            }
            #expect(target == w.reviewer)
        }
    }

    @Test("every other address is refused with the one text: iris, any session id, names, topics, ungranted and vacant roles")
    func everythingElseRefused() {
        let w = world(granted: ["reviewer", "vacant-role"])
        let addresses = [
            "iris", "IRIS", w.iris.uuidString, w.reviewer.uuidString, w.builder.uuidString, w.worker.uuidString,
            w.otherGuest.uuidString, w.guest.uuidString, w.guest.uuidString.lowercased(),
            "name:worker-bee", "name:reviewer", "topic:news", "role:builder", "ROLE:BUILDER", "Role:Builder",
            "role:ghost", "role:vacant-role", "role:", "role:reviewer-extra", "role:review", "role:iris",
            "reviewer", "", "   ",
        ]
        for address in addresses {
            #expect(w.app.decidePeerSend(to: address, from: w.guest, replyTarget: nil) == refusal, "\(address) was not refused uniformly")
        }
    }

    @Test("a granted role is matched whole: a shorter grant does not reach a longer role")
    func noPrefixMatch() {
        let w = world(granted: ["review"])
        #expect(w.app.decidePeerSend(to: "role:reviewer", from: w.guest, replyTarget: nil) == refusal)
        #expect(w.app.decidePeerSend(to: "role:review", from: w.guest, replyTarget: nil) == refusal, "granted but vacant")
    }

    @Test("an empty allowlist refuses everything, and so does a guest with no client id")
    func emptyAllowlistRefusesAll() {
        for w in [world(granted: []), world(clientId: nil)] {
            for address in ["role:reviewer", "role:builder", "iris", w.reviewer.uuidString] {
                #expect(w.app.decidePeerSend(to: address, from: w.guest, replyTarget: nil) == refusal)
            }
        }
    }

    @Test("the refusal for a session that exists is the refusal for one that does not")
    func refusalRevealsNothing() {
        let w = world()
        let exists = w.app.decidePeerSend(to: "role:builder", from: w.guest, replyTarget: nil)
        let vacant = w.app.decidePeerSend(to: "role:nobody-holds-this", from: w.guest, replyTarget: nil)
        let byId = w.app.decidePeerSend(to: w.builder.uuidString, from: w.guest, replyTarget: nil)
        let unknownId = w.app.decidePeerSend(to: UUID().uuidString, from: w.guest, replyTarget: nil)
        #expect(exists == vacant && vacant == byId && byId == unknownId)
    }

    @Test("an archived holder of a granted role is not reached")
    func archivedHolderNotReached() {
        let w = world()
        w.app.conversations[w.app.conversations.firstIndex { $0.id == w.reviewer }!].isArchived = true
        #expect(w.app.decidePeerSend(to: "role:reviewer", from: w.guest, replyTarget: nil) == refusal)
    }

    // MARK: replies

    @Test("a guest's reply goes to a granted role's holder, and to nobody else")
    func guestReplies() {
        let w = world()
        guard case .allowed(let target, _) = w.app.decidePeerSend(to: "", from: w.guest, replyTarget: w.reviewer) else {
            Issue.record("a reply to a granted holder was refused"); return
        }
        #expect(target == w.reviewer)
        for replyTarget in [w.builder, w.iris, w.worker, w.otherGuest, w.guest, UUID()] {
            #expect(w.app.decidePeerSend(to: "", from: w.guest, replyTarget: replyTarget) == refusal)
        }
        #expect(w.app.decidePeerSend(to: "role:builder", from: w.guest, replyTarget: w.reviewer) == refusal,
                "a `to` that is not the reply's target is refused")
        guard case .allowed = w.app.decidePeerSend(to: "role:reviewer", from: w.guest, replyTarget: w.reviewer) else {
            Issue.record("a `to` naming the granted target was refused"); return
        }
    }

    @Test("a reply loses its target when the grant is withdrawn")
    func replyAfterRevocation() {
        let w = world()
        w.app.guestRoleAllowlist = { _ in [] }
        #expect(w.app.decidePeerSend(to: "", from: w.guest, replyTarget: w.reviewer) == refusal)
    }

    @Test("a role session replies to a guest by in_reply_to alone; a deleted guest is refused")
    func repliesToAGuest() {
        let w = world()
        guard case .allowed(let target, _) = w.app.decidePeerSend(to: "", from: w.reviewer, replyTarget: w.guest) else {
            Issue.record("a reply to a guest was refused"); return
        }
        #expect(target == w.guest)
        #expect(w.app.decidePeerSend(to: "role:reviewer", from: w.builder, replyTarget: w.guest)
                    == .refused("A reply goes to the session that sent the original message; omit `to`."))
        w.app.deleteConversation(w.guest)
        #expect(w.app.decidePeerSend(to: "", from: w.reviewer, replyTarget: w.guest)
                    == .refused("The session that sent that message is no longer active."))
    }

    @Test("the guest branch leaves a non-guest sender's addressing as it was")
    func nonGuestUnchanged() {
        let w = world()
        guard case .allowed(let byRole, _) = w.app.decidePeerSend(to: "role:builder", from: w.reviewer, replyTarget: nil),
              case .allowed(let byId, _) = w.app.decidePeerSend(to: w.worker.uuidString, from: w.reviewer, replyTarget: nil),
              case .allowed(let toIris, _) = w.app.decidePeerSend(to: "iris", from: w.reviewer, replyTarget: nil)
        else { Issue.record("a main session's sends were refused"); return }
        #expect(byRole == w.builder && byId == w.worker && toIris == w.iris)
        // A guest is not addressable by a non-guest through the generic path.
        #expect(w.app.decidePeerSend(to: w.guest.uuidString, from: w.reviewer, replyTarget: nil)
                    == .refused(SessionAddressError.inactive.message))
    }

    @Test("a reply to an archived holder or to the pinned Iris is refused even when its role is granted")
    func replyTargetMustHoldTheRole() {
        let w = world(granted: ["reviewer", "pinned-role"])
        let pinned = w.app.conversations.firstIndex { $0.id == w.iris }!
        w.app.conversations[pinned].role = "pinned-role"
        #expect(w.app.decidePeerSend(to: "", from: w.guest, replyTarget: w.iris) == refusal, "the pinned conversation may not hold a role")
        w.app.conversations[w.app.conversations.firstIndex { $0.id == w.reviewer }!].isArchived = true
        #expect(w.app.decidePeerSend(to: "", from: w.guest, replyTarget: w.reviewer) == refusal, "an archived holder")
    }

    @Test("a guest sender that is no longer in conversations is refused, never served by the generic resolve")
    func goneGuestSenderRefused() {
        let w = world()
        let gone = UUID()
        for address in ["role:reviewer", w.worker.uuidString, "iris", "name:worker-bee", "topic:x"] {
            #expect(w.app.decidePeerSend(to: address, from: gone, replyTarget: nil, senderIsGuest: true) == refusal, "\(address)")
        }
        #expect(w.app.decidePeerSend(to: "", from: gone, replyTarget: w.reviewer, senderIsGuest: true) == refusal)
        // The same unknown sender as a non-guest is the generic path, as before.
        guard case .allowed = w.app.decidePeerSend(to: w.worker.uuidString, from: gone, replyTarget: nil) else {
            Issue.record("a non-guest unknown sender changed"); return
        }
        // And a guest reaped mid-call, through the engine's flag, is refused too.
        w.app.deleteConversation(w.guest)
        #expect(w.app.decidePeerSend(to: "role:reviewer", from: w.guest, replyTarget: nil, senderIsGuest: true) == refusal)
    }

    // MARK: list_sessions

    @Test("a guest's listing is the granted, held roles with three fields each, and nothing else")
    func listingRows() {
        let w = world(granted: ["reviewer", "vacant-role"])
        let idx = w.app.conversations.firstIndex { $0.id == w.reviewer }!
        w.app.conversations[idx].sessionCard = SessionCard(name: "Rev", description: "reviews PRs")
        let rows = SessionDirectory.peersForGuest(roles: ["reviewer", "vacant-role"], in: w.app.conversations)
        #expect(rows == [GuestPeerRow(role: "reviewer", name: "Rev", description: "reviews PRs")])
        let text = IrisEngine.renderGuestPeerList(rows)
        #expect(text == "role: reviewer | name: \"Rev\" | doing: \"reviews PRs\"")
        for hidden in [w.reviewer.uuidString, w.builder.uuidString, "builder", "worker-bee", "session_id", "workspace", "status"] {
            #expect(!text.contains(hidden))
        }
    }

    @Test("a guest's list_sessions call, through the engine, lists only its granted role")
    func listingThroughTheEngine() async {
        let w = world()
        let idx = w.app.conversations.firstIndex { $0.id == w.reviewer }!
        w.app.conversations[idx].sessionCard = SessionCard(name: "Rev", description: "reviews PRs")
        let first = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: "list_sessions", args: [:], id: "c1"))]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: w.app, tier: .medium, principal: .mcpGuest,
                                client: FakeLLMClient(responses: [first, final]), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: w.guest)
        let history = w.app.conversations.first { $0.id == w.guest }?.history ?? []
        let text = history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
        #expect(text == "role: reviewer | name: \"Rev\" | doing: \"reviews PRs\"")
    }

    @Test("a guest's send_to_session to a topic or to iris is refused through the engine, and nothing is delivered")
    func engineRefusesTopicAndIris() async {
        for address in ["topic:news", "iris", "role:builder"] {
            let w = world()
            let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: FunctionCall(
                name: "send_to_session", args: ["to": .string(address), "message": .string("hello")], id: "c1"))]))], usageMetadata: nil)
            let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
            let engine = IrisEngine(state: w.app, tier: .medium, principal: .mcpGuest,
                                    client: FakeLLMClient(responses: [first, final]), retryDelays: [],
                                    protectionEnabled: false, sessionPeerCount: 0)
            await engine.processInput("go", source: "UI", conversationId: w.guest)
            let history = w.app.conversations.first { $0.id == w.guest }?.history ?? []
            let text = history.flatMap { $0.parts }.compactMap { part -> String? in
                guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
                return s
            }.last ?? ""
            #expect(text == AppState.GuestAddressRefusal.text, "\(address): \(text)")
            #expect(w.app.conversations.filter { !$0.isGuest }.allSatisfy { $0.messages.isEmpty })
        }
    }

    /// Answers with a send_to_session call, deleting the guest's conversation first: the guest is
    /// reaped between its turn starting and its tool call running.
    private final class ReapingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let call: FunctionCall
        private let reap: @Sendable () async -> Void
        init(call: FunctionCall, reap: @escaping @Sendable () async -> Void) { self.call = call; self.reap = reap }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n = lock.withLock { calls += 1; return calls }
            if n == 1 {
                await reap()
                return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
            }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        }
    }

    @Test("a guest engine whose conversation is reaped mid-turn still cannot send to a session id: the engine's principal reaches decidePeerSend")
    func reapedGuestEngineRefused() async throws {
        for address in ["role:reviewer", "iris"] {
            let w = world()
            let call = FunctionCall(name: "send_to_session", args: ["to": .string(address), "message": .string("hello"),
                                                                       "expects_reply": .bool(true)], id: "c1")
            let app = w.app, guest = w.guest
            let client = ReapingClient(call: call) { await MainActor.run { app.deleteConversation(guest) } }
            let engine = IrisEngine(state: w.app, tier: .medium, principal: .mcpGuest, client: client, retryDelays: [],
                                    protectionEnabled: false, sessionPeerCount: 0)
            await engine.processInput("go", source: "UI", conversationId: w.guest)
            #expect(!w.app.conversations.contains { $0.id == w.guest }, "the guest was reaped")
            let open = try w.app.store.peers.openRequests(from: w.guest)
            #expect(open.isEmpty, "\(address): a message was recorded from a reaped guest")
            #expect(w.app.conversations.filter { !$0.isGuest }.allSatisfy { $0.messages.isEmpty }, "nothing was delivered")
        }
    }
}
