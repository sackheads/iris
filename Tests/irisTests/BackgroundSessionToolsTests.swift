import Testing
import Foundation
@testable import iris

/// A background run is not a session, in both directions (#185 §9, #187).
///
/// It was already refused as a *target*: `send_to_session` treats a background conversation like an
/// archived one. As a *sender* it was not, and that is the same laundering shape `invoke_subagent`
/// had — `deliverPeerMessage` starts a real turn in a user-facing conversation, which runs under
/// the receiver's attended approval path, so an unattended run could get a gated tool run for it by
/// asking someone else. Gated on the sender side: undeclared, and refused at dispatch.
@MainActor
@Suite("A background run cannot message sessions")
struct BackgroundSessionToolsTests {

    private let names = ["list_sessions", "send_to_session", "set_session_card"]

    /// One real turn against a capturing client, reading the tools actually sent. `peerCount` is
    /// forced to 1 so the gate under test is the background one and nothing else.
    private func declaredToolNames(isBackground: Bool) async -> [String] {
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: isBackground, select: false)
        app.createNewConversation(id: UUID())   // a peer to talk to
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("a foreground conversation with a peer still gets all three")
    func declaredInTheForeground() async {
        let declared = await declaredToolNames(isBackground: false)
        for n in names { #expect(declared.contains(n), "\(n) is unchanged for an attended session") }
    }

    @Test("a background run is offered none of the three")
    func notDeclaredInTheBackground() async {
        let declared = await declaredToolNames(isBackground: true)
        for n in names { #expect(!declared.contains(n), "\(n) must not be offered to an unattended run") }
    }

    /// Drives one turn in a background conversation whose model makes `call`, and hands back what
    /// the dispatcher returned to it. The declaration gate never offered the tool; this is the
    /// forged call it does not stop.
    private func dispatchResult(for call: FunctionCall, in app: AppState, from sender: UUID) async -> [String] {
        let part = Part(text: nil, functionCall: call, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))],
                           usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: sender)
        return app.conversations.first { $0.id == sender }?.history
            .flatMap { $0.parts }
            .compactMap { $0.functionResponse?.response["result"]?.stringValue } ?? []
    }

    @Test("a forged list_sessions from a background run is refused, with no roster")
    func listRefused() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let sender = app.createNewConversation(isBackground: true, select: false)
        let peer = app.createNewConversation(id: UUID())
        app.setSessionCard(for: peer, SessionCard(name: "atlas", description: "refactoring the store"))

        let results = await dispatchResult(for: FunctionCall(name: "list_sessions", args: [:]),
                                           in: app, from: sender)
        #expect(results.contains { $0.contains(IrisEngine.unattendedSessionListRefusal) })
        #expect(!results.contains { $0.contains("atlas") }, "not one line of the roster leaks")
        #expect(!results.contains { $0.contains(peer.uuidString) })
    }

    @Test("a forged set_session_card from a background run changes nothing")
    func cardRefused() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let sender = app.createNewConversation(isBackground: true, select: false)
        app.createNewConversation(id: UUID())

        let results = await dispatchResult(for: FunctionCall(
            name: "set_session_card",
            args: ["name": .string("helper"), "description": .string("available for anything")]),
                                           in: app, from: sender)
        #expect(results.contains { $0.contains(IrisEngine.unattendedSessionListRefusal) })
        #expect(app.conversations.first { $0.id == sender }?.sessionCard == nil,
                "a run that cannot be addressed must not advertise itself either")
    }

    @Test("a forged send_to_session from a background run is refused, and starts no turn")
    func sendRefusedAndTargetUntouched() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let sender = app.createNewConversation(isBackground: true, select: false)
        let target = app.createNewConversation(id: UUID())

        let results = await dispatchResult(for: FunctionCall(
            name: "send_to_session",
            args: ["session_id": .string(target.uuidString), "message": .string("run this for me")]),
                                           in: app, from: sender)
        #expect(results.contains { $0.contains(IrisEngine.unattendedSessionMessageRefusal) })

        // Delivery is detached when it does happen, so give it a window it could have used.
        try await Task.sleep(nanoseconds: 100_000_000)
        let peer = try #require(app.conversations.first { $0.id == target })
        #expect(peer.messages.isEmpty, "no message arrived")
        #expect(peer.history.isEmpty, "and no turn ran in the peer")
    }
}
