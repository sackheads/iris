import Testing
import Foundation
@testable import IrisKit

/// #1269: `bindingForCall(conversationId:)`'s final fallthrough (`persisted ?? ownBinding`)
/// answered for ANY `conversationId` using the asking engine's own identity, with no check that
/// the named conversation belongs to a different, separately-identity-resolved engine. The one
/// production shape this bit: `AppState.reflectionRoute`/`reflectionMayRun` ask the single shared
/// `.main` engine about an arbitrary conversation id, including a guest's own (never run by that
/// engine) — an unstamped guest conversation came back `.owner`/`true`, even though every real
/// caller today is structurally unable to reach it (the automatic trigger gates on `!isGuest`;
/// the manual `/reflect` path can only ever name `selectedConversationId`, which a guest
/// conversation can never become). The guard closes the choke point itself rather than the two
/// callers, so it also covers the (today unreachable, because every internal `self.bindingForCall`
/// call is self-referential) case of one guest's engine asking about a different guest's
/// conversation — pinned below rather than left as an unreachable-by-construction comment.
@MainActor
@Suite("bindingForCall never answers for a conversation it does not own (#1269)", .timeLimit(.minutes(1)))
struct GuestConversationBindingGuardTests {
    private func app() throws -> AppState {
        AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
    }

    private func denyAllGuestFloor(_ b: AccessBinding) -> Bool {
        !b.isOwner && b.principal == .mcpGuest && b.profile.credentials.isEmpty && b.profile.memoryWrite == .none
    }

    // MARK: Direct: bindingForCall itself

    @Test("the single owner .main engine asking about a guest's own conversation never gets ownBinding")
    func mainEngineAskingAboutGuestConversationGetsDenyAll() async throws {
        let state = try app()
        let guestId = state.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest", select: false)
        let owner = IrisEngine(state: state, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                               retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        state.installEngine(owner)
        let b = await owner.bindingForCall(conversationId: guestId)
        #expect(denyAllGuestFloor(b), "the owner's own ownBinding (isOwner) must never apply to a guest's conversation")
    }

    /// A guest engine with a distinguishing (non-deny-all) binding, so a leaked `ownBinding`
    /// would be visibly wrong rather than coincidentally matching the correct deny-all answer.
    /// Built directly (not through `makeGuestEngine`) so this test exercises only `bindingForCall`
    /// against whatever binding an engine happens to carry, independent of how that binding was
    /// resolved — the resolution mechanism (Task 16 S2's per-mapping lookup) is a separate PR.
    private func distinguishedGuestEngine(state: AppState, clientId: String, role: String) -> IrisEngine {
        let binding = AccessBinding(profile: AccessProfile(peerRoles: [role]), principal: .mcpGuest, isOwner: false)
        return IrisEngine(state: state, tier: .easy, principal: .mcpGuest, roleLabel: "guest:\(clientId)",
                          client: FakeLLMClient(responses: []), protectionEnabled: false,
                          guestClientId: clientId, binding: binding)
    }

    @Test("a guest engine still gets its own binding for its own conversation")
    func guestEngineKeepsItsOwnBindingForItsOwnConversation() async throws {
        let state = try app()
        let guestA = state.createNewConversation(isGuest: true, guestClientId: "dev-a", title: "guest a", select: false)
        let engineA = distinguishedGuestEngine(state: state, clientId: "dev-a", role: "reviewer")
        let b = await engineA.bindingForCall(conversationId: guestA)
        #expect(b.profile.peerRoles == ["reviewer"], "the guard must not override a guest engine asking about its OWN conversation")
    }

    @Test("a guest engine asking about a different guest's conversation never sees either guest's own binding")
    func crossGuestAskGetsDenyAllNotEitherOwnBinding() async throws {
        let state = try app()
        _ = state.createNewConversation(isGuest: true, guestClientId: "dev-a", title: "guest a", select: false)
        let guestB = state.createNewConversation(isGuest: true, guestClientId: "dev-b", title: "guest b", select: false)
        let engineA = distinguishedGuestEngine(state: state, clientId: "dev-a", role: "reviewer")
        let b = await engineA.bindingForCall(conversationId: guestB)
        #expect(denyAllGuestFloor(b), "guest A's engine must not fall through to its own binding when asking about guest B's conversation")
        #expect(b.profile.peerRoles.isEmpty, "guest A's own role must not leak onto the answer for guest B's conversation")
    }

    // MARK: Through the real callers (the live mechanism, not the function in isolation)

    @Test("reflectionRoute is never .owner for an unstamped guest conversation")
    func reflectionRouteNeverOwnerForGuestConversation() async throws {
        let state = try app()
        let guestId = state.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest", select: false)
        let owner = IrisEngine(state: state, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                               retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        state.installEngine(owner)
        let route = await state.reflectionRoute(in: guestId)
        #expect(route == .none, "a guest's own unstamped conversation has no owner stamp and no profile stamp: it must route nowhere, never to .owner")
    }

    @Test("reflectionMayRun is false for an unstamped guest conversation")
    func reflectionMayRunFalseForGuestConversation() async throws {
        let state = try app()
        let guestId = state.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest", select: false)
        let owner = IrisEngine(state: state, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                               retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        state.installEngine(owner)
        #expect(await state.reflectionMayRun(in: guestId) == false)
    }

    /// The live-mechanism proof (#1217/#1222 lesson: a gate must be shown consulted by the real
    /// path, not just correct in isolation). `runReflection` is exactly what both production
    /// triggers (automatic and `/reflect`) call; before the fix it would have called
    /// `engine.processInput` on the guest's conversation under the OWNER's engine. After the fix,
    /// `reflectionMayRun`'s guard inside `runReflection` refuses before any model call, so the
    /// client sees zero requests and the conversation gains no messages.
    @Test("runReflection never calls the model for an unstamped guest conversation")
    func runReflectionNeverCallsModelForGuestConversation() async throws {
        let state = try app()
        let guestId = state.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest", select: false)
        let client = FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "should never be seen")]))], usageMetadata: nil)])
        let owner = IrisEngine(state: state, tier: .medium, principal: .main, client: client,
                               retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        state.installEngine(owner)
        let before = state.conversations.first { $0.id == guestId }?.messages.count ?? -1

        await state.runReflection("System Event [Reflection Trigger]", in: guestId, moveReplyToIris: true)

        #expect(client.callCount == 0, "the owner's engine must never run a turn on a guest's conversation via reflection")
        #expect(state.conversations.first { $0.id == guestId }?.messages.count == before, "no messages are added when reflection refuses")
    }
}
