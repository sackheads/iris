import Testing
import Foundation
@testable import iris

/// #185 §6. The tools cost prompt tokens on every turn they are declared, so they appear only
/// when there is somebody to talk to.
@MainActor
@Suite("Session tools")
struct SessionToolsTests {

    private let names = ["list_sessions", "send_to_session", "set_session_card"]

    /// Drive one real turn through the engine against a capturing client and read back the tools
    /// actually declared on the request — not a hand-written mirror of the gate. A prior version
    /// of this suite asserted against a test-only accessor that re-implemented the predicate
    /// instead of reading the assembled tool list; it drifted from the real gate (it read the
    /// override only, never `SessionDirectory`'s fallback) and stayed green after the production
    /// declaration was deleted entirely. This follows ToolSurfaceTrimTests' harness instead.
    private func toolNames(principal: Principal = .main, sessionPeerCount: Int? = nil,
                           prepare: (AppState, UUID) -> Void = { _, _ in }) async -> [String] {
        let app = AppState()
        let id = UUID()
        app.conversations.removeAll()
        app.createNewConversation(id: id)
        prepare(app, id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], sessionPeerCount: sessionPeerCount)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("no session tools when there is no peer")
    func absentWithoutPeers() async {
        let declared = await toolNames(sessionPeerCount: 0)
        for n in names { #expect(!declared.contains(n), "\(n) must not cost a single-session turn") }
    }

    @Test("session tools appear once a peer exists")
    func presentWithPeers() async {
        let declared = await toolNames(sessionPeerCount: 1) { app, _ in
            app.createNewConversation(id: UUID())
        }
        for n in names { #expect(declared.contains(n)) }
    }

    @Test("a subagent never gets session tools")
    func subagentExcluded() async {
        let declared = await toolNames(principal: .subagent, sessionPeerCount: 1) { app, _ in
            app.createNewConversation(id: UUID())
        }
        for n in names { #expect(!declared.contains(n), "a subagent is not a session") }
    }

    /// No override injected: the gate must fall back to `SessionDirectory.peers` over AppState's
    /// real conversations rather than silently reporting no peers. This is the path the old
    /// test-only accessor bypassed (it read `sessionPeerCountOverride ?? 0`, never the fallback),
    /// so a nil override with real peers declared no tools and no test caught it.
    @Test("session tools appear via the real peer count when no override is injected")
    func presentWithRealPeerNoOverride() async {
        let declared = await toolNames(sessionPeerCount: nil) { app, _ in
            app.createNewConversation(id: UUID())
        }
        for n in names { #expect(declared.contains(n)) }
    }

    /// #185 §9: "a subagent attempting a send is refused as 'not a session' ... can neither
    /// originate nor extend a cascade." Declaration gating (above) only stops a well-behaved
    /// model from being offered the tool — dispatch reads `functionCall.name` alone, so a forged
    /// call must be refused where it would otherwise act (#185 review round 2, M2). Scripts the
    /// call directly rather than relying on the model to emit an undeclared tool.
    @Test("a subagent's forged send_to_session call is refused by the handler, not just undeclared")
    func subagentSendIsRefusedByHandler() async {
        let app = AppState(); app.conversations.removeAll()
        let subagentId = UUID(), target = UUID()
        app.createNewConversation(id: subagentId, isSubagent: true)
        app.createNewConversation(id: target)

        let call = FunctionCall(name: "send_to_session",
                                args: ["session_id": .string(target.uuidString), "message": .string("do it")],
                                id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))],
                                   usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                                   usageMetadata: nil)
        let client = FakeLLMClient(responses: [first, final])
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent, client: client, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: subagentId)

        #expect(app.cascadeRemaining(for: target) == ConfigManager.shared.maxSessionCascade,
                "a refused send must never debit a cascade budget it is not allowed to extend")
        let targetHistory = app.conversations.first { $0.id == target }?.history ?? []
        #expect(targetHistory.isEmpty,
                "declaration gating is not the only enforcement — a forged call must not deliver")
    }
}
