import Testing
import Foundation
@testable import iris

/// #185 §6. The tools cost prompt tokens on every turn they are declared, so they appear only
/// when there is somebody to talk to.
@MainActor
@Suite("Session tools")
struct SessionToolsTests {

    private let names = ["list_sessions", "send_to_session", "set_session_card"]

    @Test("no session tools when there is no peer")
    func absentWithoutPeers() async {
        let app = AppState(); app.conversations.removeAll()
        app.createNewConversation(id: UUID())
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []),
                                sessionPeerCount: 0)
        let declared = await engine.declaredToolNamesForTesting()
        for n in names { #expect(!declared.contains(n), "\(n) must not cost a single-session turn") }
    }

    @Test("session tools appear once a peer exists")
    func presentWithPeers() async {
        let app = AppState(); app.conversations.removeAll()
        app.createNewConversation(id: UUID())
        app.createNewConversation(id: UUID())
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []),
                                sessionPeerCount: 1)
        let declared = await engine.declaredToolNamesForTesting()
        for n in names { #expect(declared.contains(n)) }
    }

    @Test("a subagent never gets session tools")
    func subagentExcluded() async {
        let app = AppState(); app.conversations.removeAll()
        app.createNewConversation(id: UUID())
        app.createNewConversation(id: UUID())
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent,
                                client: FakeLLMClient(responses: []), sessionPeerCount: 1)
        let declared = await engine.declaredToolNamesForTesting()
        for n in names { #expect(!declared.contains(n), "a subagent is not a session") }
    }
}
