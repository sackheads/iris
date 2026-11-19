import Testing
import Foundation
@testable import IrisKit

/// #974 Task 15 (F3b): the COMPLETE fix the #1119 `isGuestOriginTurn` bool only bounds. A guest's
/// `send_to_session` (or a relay through a turn that was itself guest-steered) stamps the
/// RECIPIENT turn's own `AccessBinding` on `AppState`, so `IrisEngine.bindingForCall` returns
/// something narrower than the engine's own (owner-shaped, for `.main`) binding for that specific
/// conversation. #1119's bool alone only turns YOLO off; it cannot gate memory or an
/// MCP/user-added/future tool (the F2b problem) — this is the positive-allowlist mechanism Task 7
/// consults for that.
@MainActor
@Suite("Recipient-binding of a guest-steered .main turn (#974 Task 15, F3b)", .timeLimit(.minutes(2)))
struct RecipientBindingTests {
    private struct World {
        let app: AppState
        let guest: UUID
        let reviewer: UUID
        let builder: UUID
    }

    private func world() -> World {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guest = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let reviewer = app.createNewConversation(title: "reviewer", select: false)
        let builder = app.createNewConversation(title: "builder", select: false)
        for (id, role) in [(reviewer, "reviewer"), (builder, "builder")] {
            app.conversations[app.conversations.firstIndex { $0.id == id }!].role = role
        }
        app.guestRoleAllowlist = { $0 == "dev-1" ? ["reviewer"] : [] }
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

    private func sendCall(to: String, message: String) -> FunctionCall {
        FunctionCall(name: "send_to_session", args: ["to": .string(to), "message": .string(message)], id: "c1")
    }

    /// A direct guest send: `self` (the sending engine) is the guest's own, so the recipient gets
    /// exactly the guest's binding — deny-all profile capped by the `.mcpGuest` floor, memoryRead
    /// no higher than `.task`.
    @Test("a direct guest send stamps the recipient with the guest's own capped binding")
    func directGuestSendStampsTheRecipient() async {
        let w = world()
        let call = sendCall(to: "role:reviewer", message: "please check this")
        let guestClient = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
        ])
        let guestEngine = IrisEngine(state: w.app, tier: .medium, principal: .mcpGuest, client: guestClient, retryDelays: [],
                                     protectionEnabled: false, sessionPeerCount: 0, guestClientId: "dev-1")
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "noted")]))], usageMetadata: nil)]),
                              retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        await guestEngine.processInput("go", source: "UI", conversationId: w.guest)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("please check this") })

        let stamped = w.app.guestSteeredBinding(for: w.reviewer)
        #expect(stamped != nil, "the recipient turn must carry a binding, not just the YOLO-off bool")
        #expect(stamped?.principal == .mcpGuest)
        #expect(stamped?.isOwner == false)
        #expect(stamped?.profile.memoryRead ?? .full != .full, "a guest's binding must not read as owner memory")
        let viaCall = await main.bindingForCall(conversationId: w.reviewer)
        #expect(viaCall == stamped, "bindingForCall must read the same stamp")
    }

    /// A relay: `builder`'s own turn was itself guest-steered and already carries a stamped
    /// binding; when `builder` forwards to `reviewer`, the SAME binding propagates — a guest's
    /// restriction cannot be laundered away by bouncing the message through an intermediate role.
    @Test("a relay through an already guest-steered turn propagates the same binding")
    func relayPropagatesTheInheritedBinding() async {
        let w = world()
        let stampedOnBuilder = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false)
            .capped(by: PrincipalFloor.floor(for: .mcpGuest))
        w.app.markGuestOriginTurn(w.builder)
        w.app.markGuestSteeredBinding(stampedOnBuilder, for: w.builder)

        let call = sendCall(to: "role:reviewer", message: "forwarding this along")
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: [
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "noted")]))], usageMetadata: nil),
                              ]),
                              retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        await main.processInput("go", source: "UI", conversationId: w.builder)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("forwarding this along") })

        let stamped = w.app.guestSteeredBinding(for: w.reviewer)
        #expect(stamped == stampedOnBuilder, "the relay must carry the SAME binding forward, not the engine's own owner-shaped default")
    }

    /// An ordinary, non-guest send carries no stamp: the recipient's `bindingForCall` falls back
    /// to the engine's own binding (owner, for `.main`), unchanged from before this task.
    @Test("an ordinary peer send leaves the recipient's binding untouched")
    func ordinarySendStampsNothing() async {
        let w = world()
        let call = sendCall(to: "role:reviewer", message: "ordinary peer business")
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: [
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "noted")]))], usageMetadata: nil),
                              ]),
                              retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        await main.processInput("go", source: "UI", conversationId: w.builder)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("ordinary peer business") })

        #expect(w.app.guestSteeredBinding(for: w.reviewer) == nil)
        let viaCall = await main.bindingForCall(conversationId: w.reviewer)
        #expect(viaCall == (await main.binding), "no stamp: falls back to the engine's own binding")
    }

    /// The stamp is transient, like the bool it rides alongside: once the recipient's turn ends,
    /// a later read of `bindingForCall` for that conversation must not still see a guest's cap.
    @Test("the stamp clears when the recipient's turn ends, like the #1119 bool it travels with")
    func stampClearsWithTheTurn() {
        let w = world()
        let binding = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false)
            .capped(by: PrincipalFloor.floor(for: .mcpGuest))
        w.app.markGuestOriginTurn(w.reviewer)
        w.app.markGuestSteeredBinding(binding, for: w.reviewer)
        w.app.beginEngineTurn(for: w.reviewer)
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == binding)
        w.app.endEngineTurn(for: w.reviewer)
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == nil, "cleared alongside isGuestOriginTurn")
        #expect(!w.app.isGuestOriginTurn(w.reviewer))
    }

    /// A busy target takes the queued path (`queuePeerArrival`/`drainPendingUserMessages`), not
    /// the immediate claim: the binding must survive that path too, not just the idle one above.
    @Test("a guest send queued behind a busy target still stamps the binding once drained")
    func queuedGuestSendStampsOnDrain() async {
        let w = world()
        // Occupy the reviewer's turn slot so the send takes the busy/queued branch.
        #expect(w.app.claimPeerDelivery(for: w.reviewer))

        let call = sendCall(to: "role:reviewer", message: "queued while busy")
        let guestClient = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
        ])
        let guestEngine = IrisEngine(state: w.app, tier: .medium, principal: .mcpGuest, client: guestClient, retryDelays: [],
                                     protectionEnabled: false, sessionPeerCount: 0, guestClientId: "dev-1")
        await guestEngine.processInput("go", source: "UI", conversationId: w.guest)
        #expect(await eventually { w.app.pendingUserItems(for: w.reviewer).isEmpty == false || self.text(w.app, w.reviewer).contains("queued while busy") })

        // Free the slot and drain: the queued entry's binding must land on `guestSteeredBindings`.
        w.app.releasePeerDelivery(for: w.reviewer)
        w.app.drainPendingUserMessages(for: w.reviewer)
        #expect(await eventually { w.app.guestSteeredBinding(for: w.reviewer) != nil })
        #expect(w.app.guestSteeredBinding(for: w.reviewer)?.principal == .mcpGuest)
    }
}
