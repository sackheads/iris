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

    // MARK: dev-2 review of #1212 round 1

    private func wideAndNarrow() -> (wide: AccessBinding, narrow: AccessBinding) {
        (AccessBinding(profile: AccessProfile(memoryRead: .conversations), principal: .mcpGuest, isOwner: false),
         AccessBinding(profile: AccessProfile(memoryRead: .task), principal: .mcpGuest, isOwner: false))
    }

    private func incomparablePair() -> (AccessBinding, AccessBinding) {
        (AccessBinding(profile: AccessProfile(memoryRead: .shared, transports: []), principal: .mcpGuest, isOwner: false),
         AccessBinding(profile: AccessProfile(memoryRead: .none, transports: ["slack"]), principal: .mcpGuest, isOwner: false))
    }

    private func incomparableFloor() -> AccessBinding {
        AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
    }

    /// dev-2 review of #1212, round 1: the fold inside `takePendingSteers` was untested -- reverting
    /// it to first-wins left every prior test green. Pins wide-then-narrow, narrow-then-wide, and an
    /// incomparable pair failing closed, all through the real queue, not the pure helper directly.
    @Test("takePendingSteers folds every queued guest binding through the meet, in both orders")
    func takePendingSteersFoldsTheMeet() {
        let w = world()
        let (wide, narrow) = wideAndNarrow()

        w.app.enqueuePendingUserMessage(text: "a", attachments: [], for: w.reviewer, isPeer: true, isGuestOrigin: true, guestBinding: wide)
        w.app.enqueuePendingUserMessage(text: "b", attachments: [], for: w.reviewer, isPeer: true, isGuestOrigin: true, guestBinding: narrow)
        _ = w.app.takePendingSteers(for: w.reviewer)
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == narrow, "wide-then-narrow must end up narrow")

        w.app.enqueuePendingUserMessage(text: "c", attachments: [], for: w.builder, isPeer: true, isGuestOrigin: true, guestBinding: narrow)
        w.app.enqueuePendingUserMessage(text: "d", attachments: [], for: w.builder, isPeer: true, isGuestOrigin: true, guestBinding: wide)
        _ = w.app.takePendingSteers(for: w.builder)
        #expect(w.app.guestSteeredBinding(for: w.builder) == narrow, "narrow-then-wide must still end up narrow")

        let (a, b) = incomparablePair()
        let third = w.app.createNewConversation(isBackground: false, select: false)
        w.app.enqueuePendingUserMessage(text: "e", attachments: [], for: third, isPeer: true, isGuestOrigin: true, guestBinding: a)
        w.app.enqueuePendingUserMessage(text: "f", attachments: [], for: third, isPeer: true, isGuestOrigin: true, guestBinding: b)
        _ = w.app.takePendingSteers(for: third)
        #expect(w.app.guestSteeredBinding(for: third) == incomparableFloor(), "an incomparable pair must fail closed, not pick a side")
    }

    /// Same risk, the drain path (`drainPendingUserMessages`, which starts a NEW turn rather than
    /// steering a running one).
    @Test("drainPendingUserMessages folds every merged guest binding through the meet, in both orders")
    func drainPendingUserMessagesFoldsTheMeet() {
        let w = world()
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)]),
                              retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        let (wide, narrow) = wideAndNarrow()

        w.app.enqueuePendingUserMessage(text: "a", attachments: [], for: w.reviewer, isPeer: true, isGuestOrigin: true, guestBinding: wide)
        w.app.enqueuePendingUserMessage(text: "b", attachments: [], for: w.reviewer, isPeer: true, isGuestOrigin: true, guestBinding: narrow)
        w.app.drainPendingUserMessages(for: w.reviewer)
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == narrow, "wide-then-narrow must end up narrow")

        let (a, b) = incomparablePair()
        let third = w.app.createNewConversation(isBackground: false, select: false)
        w.app.enqueuePendingUserMessage(text: "e", attachments: [], for: third, isPeer: true, isGuestOrigin: true, guestBinding: a)
        w.app.enqueuePendingUserMessage(text: "f", attachments: [], for: third, isPeer: true, isGuestOrigin: true, guestBinding: b)
        w.app.drainPendingUserMessages(for: third)
        #expect(w.app.guestSteeredBinding(for: third) == incomparableFloor(), "an incomparable pair must fail closed, not pick a side")
    }

    // MARK: dev-3 review of #1212

    /// Finding 1: the meet never widens. A narrower binding already on the conversation must
    /// survive a wider one arriving, in every order, and an incomparable pair fails closed.
    @Test("markGuestSteeredBinding meets with any existing stamp -- it never widens")
    func markGuestSteeredBindingNeverWidens() {
        let w = world()
        let narrow = AccessBinding(profile: AccessProfile(memoryRead: .task), principal: .mcpGuest, isOwner: false)
        let wide = AccessBinding(profile: AccessProfile(memoryRead: .conversations), principal: .mcpGuest, isOwner: false)

        w.app.markGuestSteeredBinding(narrow, for: w.reviewer)
        w.app.markGuestSteeredBinding(wide, for: w.reviewer)
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == narrow, "a wider stamp arriving after must not widen the conversation")

        w.app.markGuestSteeredBinding(wide, for: w.builder)
        w.app.markGuestSteeredBinding(narrow, for: w.builder)
        #expect(w.app.guestSteeredBinding(for: w.builder) == narrow, "order must not matter -- the meet is commutative")

        // Incomparable on two different axes: neither is a subgrant of the other, so the meet
        // fails closed to the `.mcpGuest` floor rather than guessing which axis wins.
        let readsMore = AccessBinding(profile: AccessProfile(memoryRead: .shared, transports: []), principal: .mcpGuest, isOwner: false)
        let transportsMore = AccessBinding(profile: AccessProfile(memoryRead: .none, transports: ["slack"]), principal: .mcpGuest, isOwner: false)
        let floor = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false)
            .capped(by: PrincipalFloor.floor(for: .mcpGuest))
        let meet = AccessBinding.meetGuestBindings(readsMore, transportsMore)
        #expect(meet == floor, "incomparable pair must fail closed, not pick a side")
    }

    /// Finding 2: `bindingForCall` must not fall through to the engine's own (owner-shaped, for
    /// `.main`) binding when `isGuestOriginTurn` is true but no stamp was ever written -- a path
    /// that marks only the bool (directly, or a pre-Task-16 guest turn) must still fail closed.
    @Test("bindingForCall fails closed when guestOrigin is true with no stamp yet")
    func bindingForCallFailsClosedWithNoStamp() async {
        let w = world()
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: []), retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        w.app.markGuestOriginTurn(w.reviewer)
        #expect(w.app.guestSteeredBinding(for: w.reviewer) == nil, "sanity: no stamp written")

        let effective = await main.bindingForCall(conversationId: w.reviewer)
        #expect(effective.principal == .mcpGuest, "must fail closed to the guest floor, never the engine's own owner binding")
        #expect(effective.isOwner == false)
    }

    /// dev-3 review of #1212, round 2: when a delegate was itself a `send_to_session` target and
    /// also carries a root stamp, `bindingForCall` must meet the two, not pick either by
    /// first-non-nil -- which could pick the wider one.
    @Test("bindingForCall meets the delegate's own stamp with the root's when both exist")
    func bindingForCallMeetsDelegateAndRootStamps() async {
        let w = world()
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: []), retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        let (wide, narrow) = wideAndNarrow()
        let delegate = w.app.createNewConversation(isBackground: true, select: false)
        w.app.linkDelegate(delegate, of: w.builder)

        w.app.markGuestSteeredBinding(wide, for: w.builder)
        w.app.markGuestSteeredBinding(narrow, for: delegate)
        let effective = await main.bindingForCall(conversationId: delegate)
        #expect(effective == narrow, "root wide, delegate narrow -- must end up narrow")

        // dev-3 review round 3: the opposite order, so a mutant that always returns the
        // delegate's own stamp (ignoring the root) cannot hide behind this test alone.
        let delegate2 = w.app.createNewConversation(isBackground: true, select: false)
        let root2 = w.app.createNewConversation(isBackground: false, select: false)
        w.app.linkDelegate(delegate2, of: root2)
        w.app.markGuestSteeredBinding(narrow, for: root2)
        w.app.markGuestSteeredBinding(wide, for: delegate2)
        let effective2 = await main.bindingForCall(conversationId: delegate2)
        #expect(effective2 == narrow, "delegate wide, root narrow -- must still end up narrow")
    }

    /// dev-3 review of #1212, round 2: the relay computation in `deliverPeerMessage` has the same
    /// shape (`stamp(sender) ?? stamp(root)`) and needs the same fix.
    @Test("a relay meets the sender's own stamp with its root's when both exist")
    func relayMeetsSenderAndRootStamps() async {
        let w = world()
        let (wide, narrow) = wideAndNarrow()
        let delegateSender = w.app.createNewConversation(isBackground: false, select: false)
        w.app.linkDelegate(delegateSender, of: w.builder)
        w.app.markGuestSteeredBinding(wide, for: w.builder)
        w.app.markGuestSteeredBinding(narrow, for: delegateSender)
        w.app.markGuestOriginTurn(delegateSender)

        let call = sendCall(to: "role:reviewer", message: "relay from a doubly-stamped delegate")
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: [
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "noted")]))], usageMetadata: nil),
                              ]),
                              retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        await main.processInput("go", source: "UI", conversationId: delegateSender)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("relay from a doubly-stamped delegate") })

        #expect(w.app.guestSteeredBinding(for: w.reviewer) == narrow, "root wide, sender narrow -- the relay must end up narrow")
    }

    /// dev-3 review round 3: the opposite order of the test above, in a fresh world (reusing the
    /// same target would meet the new stamp with the one already left there, masking a mutant
    /// that always takes the sender's own stamp while ignoring the root).
    @Test("a relay meets the sender's own stamp with its root's, opposite order")
    func relayMeetsSenderAndRootStampsOppositeOrder() async {
        let w = world()
        let (wide, narrow) = wideAndNarrow()
        let delegateSender = w.app.createNewConversation(isBackground: false, select: false)
        w.app.linkDelegate(delegateSender, of: w.builder)
        w.app.markGuestSteeredBinding(narrow, for: w.builder)
        w.app.markGuestSteeredBinding(wide, for: delegateSender)
        w.app.markGuestOriginTurn(delegateSender)

        let call = sendCall(to: "role:reviewer", message: "relay from the opposite order")
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: [
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
                                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "noted")]))], usageMetadata: nil),
                              ]),
                              retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        await main.processInput("go", source: "UI", conversationId: delegateSender)
        #expect(await eventually { self.text(w.app, w.reviewer).contains("relay from the opposite order") })

        #expect(w.app.guestSteeredBinding(for: w.reviewer) == narrow, "sender wide, root narrow -- must still end up narrow")
    }

    /// dev-2 review of #1212: `bindingForCall` must check the delegation root too, mirroring
    /// `deliverPeerMessage`'s own `isGuestOriginTurn(senderId) || isGuestOriginTurn(root)` check.
    /// A delegate conversation under a guest-steered root was never itself the target
    /// `deliverPeerMessage` stamped -- only the root was.
    @Test("bindingForCall reads the delegation root's stamp when the delegate itself has none")
    func bindingForCallChecksDelegationRoot() async {
        let w = world()
        let main = IrisEngine(state: w.app, tier: .medium, principal: .main,
                              client: FakeLLMClient(responses: []), retryDelays: [], protectionEnabled: false)
        w.app.installEngine(main)
        // dev-3 review round 3: NOT the deny-all floor shape -- that is exactly what the
        // fail-closed branch below would also return for a guest-origin root with no stamp, so a
        // mutant that skips the root-stamp read entirely and falls through to fail-closed could
        // hide behind this assertion. A distinguishable (wide) binding exposes that mutant.
        let (wide, _) = wideAndNarrow()
        w.app.markGuestOriginTurn(w.builder)
        w.app.markGuestSteeredBinding(wide, for: w.builder)
        let delegate = w.app.createNewConversation(isBackground: true, select: false)
        w.app.linkDelegate(delegate, of: w.builder)

        let effective = await main.bindingForCall(conversationId: delegate)
        #expect(effective == wide, "the delegate inherits the root's stamp, not the engine's own binding")
    }

    /// Finding 3: a subagent spawned from a guest-steered `.main` turn must not inherit the
    /// engine's own owner binding -- all three `runSubagent` call sites must read the per-turn
    /// `bindingForCall`, not `self.binding`. A source scan (not an end-to-end spawn, which would
    /// need a real provider round trip for each site): pins that none of the three regressed to
    /// the old, turn-blind form this task replaced.
    @Test("every runSubagent call site reads bindingForCall, not the engine's own binding")
    func subagentSpawnSitesReadPerTurnBinding() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let occurrences = source.components(separatedBy: "parentBinding:").count - 1
        // 3 runSubagent sites + the 2 `GoalEvaluator.evaluate` sites that #974 Task 6 routes by the
        // turn's binding (#1216): every one of the 5 must read `bindingForCall`.
        #expect(occurrences == 5, "expected exactly the 5 known parentBinding: call sites")
        #expect(!source.contains("parentBinding: self.binding"),
                "a call site reading the engine's own binding directly would ignore a guest-steered turn's stamp")
        #expect(source.contains("parentBinding: await self.bindingForCall(conversationId: conversationId))"),
                "every site must resolve the per-turn binding before spawning")
        let perTurn = source.components(separatedBy: "parentBinding: await self.bindingForCall(conversationId: conversationId)").count - 1
        #expect(perTurn == occurrences, "all \(occurrences) sites must read the per-turn binding, found \(perTurn)")
    }
}
