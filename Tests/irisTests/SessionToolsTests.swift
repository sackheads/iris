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

    /// Same harness as `toolNames`, but reads the system-prompt TEXT actually carried on the
    /// captured request instead of the declared tool names — the count line lives in the prompt,
    /// not the tool list.
    private func systemPromptText(principal: Principal = .main, sessionPeerCount: Int? = nil,
                                  prepare: (AppState, UUID) -> Void = { _, _ in }) async -> String {
        let app = AppState()
        let id = UUID()
        app.conversations.removeAll()
        app.createNewConversation(id: id)
        prepare(app, id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], sessionPeerCount: sessionPeerCount)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
    }

    @Test("the standing count line is singular for exactly one peer")
    func standingCountSingular() async {
        let text = await systemPromptText(sessionPeerCount: 1) { app, _ in
            app.createNewConversation(id: UUID())
        }
        #expect(text.contains("1 other session is active."))
    }

    @Test("the standing count line is plural for more than one peer")
    func standingCountPlural() async {
        let text = await systemPromptText(sessionPeerCount: 2) { app, _ in
            app.createNewConversation(id: UUID())
            app.createNewConversation(id: UUID())
        }
        #expect(text.contains("2 other sessions are active."))
    }

    @Test("no standing count line when there is no peer")
    func standingCountAbsentWithoutPeers() async {
        let text = await systemPromptText(sessionPeerCount: 0)
        #expect(!text.contains("other session"))
    }

    @Test("a subagent never sees the standing count line")
    func standingCountAbsentForSubagent() async {
        let text = await systemPromptText(principal: .subagent, sessionPeerCount: 1) { app, _ in
            app.createNewConversation(id: UUID())
        }
        #expect(!text.contains("other session"), "a subagent is not a session, same as the tool gate")
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

    /// Reads the refusal the model actually received back, not a re-derived prediction of it: the
    /// tool result lands in `history` as a `functionResponse` (see `executeFunctionCall`'s
    /// `"result"` key) — the exact `Content` `request.contents` carries into the next round of the
    /// same turn (iris.swift, right after `appendContentToHistory` for the function response).
    /// `DoneGateHandlerTests.refusalCarriesEvidence` established this read pattern first.
    private func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    @Test("a send to an archived session is refused and does not resurrect it")
    func archivedSendRefused() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), other = UUID(), third = UUID()
        for id in [me, other, third] { app.createNewConversation(id: id) }
        _ = app.archiveConversation(other)

        let call = FunctionCall(name: "send_to_session",
                                args: ["session_id": .string(other.uuidString), "message": .string("hello")],
                                id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))],
                                   usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                                   usageMetadata: nil)
        let client = FakeLLMClient(responses: [first, final])
        let engine = IrisEngine(state: app, tier: .medium, client: client, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: me)

        #expect(toolResultText(app, conversationId: me).lowercased().contains("no longer active"))
        #expect(app.conversations.first { $0.id == other }?.isArchived == true,
                "a peer must not re-expand the address space on its own initiative")
    }

    @Test("a send to an unknown id is refused, not dropped")
    func unknownIdRefused() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(); app.createNewConversation(id: me)
        app.createNewConversation(id: UUID())

        let call = FunctionCall(name: "send_to_session",
                                args: ["session_id": .string(UUID().uuidString), "message": .string("hi")],
                                id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))],
                                   usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                                   usageMetadata: nil)
        let client = FakeLLMClient(responses: [first, final])
        let engine = IrisEngine(state: app, tier: .medium, client: client, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: me)

        #expect(toolResultText(app, conversationId: me).lowercased().contains("no session"))
    }
}
