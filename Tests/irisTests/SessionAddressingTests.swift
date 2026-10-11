import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Session addressing and listing", .timeLimit(.minutes(1)))
struct SessionAddressingTests {
    func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    func runToolCall(_ call: FunctionCall, on app: AppState, as id: UUID) async -> String {
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, conversationId: id)
    }

    private func send(to: String, _ message: String = "hello") -> FunctionCall {
        FunctionCall(name: "send_to_session", args: ["to": .string(to), "message": .string(message)], id: "c1")
    }

    /// Polls rather than awaiting a bare task: delivery to an idle target starts its own
    /// detached `Task` inside `deliverPeerMessage` (iris.swift), so the sender's tool result can
    /// return before the target's history is written. Mirrors `PeerDeliveryTests`' own
    /// `eventually` helper (that one is file-private there, so this file needs its own).
    private func eventually(_ timeoutMs: Int = 3000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<(timeoutMs / 25) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    @Test("role:, name:, iris and a bare id all resolve, and the result names the target")
    func resolves() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), pr = UUID(), w = UUID(), iris = UUID()
        for id in [me, pr, w, iris] { app.createNewConversation(id: id) }
        if let i = app.conversations.firstIndex(where: { $0.id == iris }) { app.conversations[i].isPinned = true }
        _ = app.assignRole("pr-minder", to: pr)
        app.setSessionCard(for: w, SessionCard(name: "Swift Worker", description: "x"))

        #expect(SessionDirectory.resolve("role:pr-minder", in: app.conversations, excluding: me) == .success(pr))
        #expect(SessionDirectory.resolve("name:swift worker", in: app.conversations, excluding: me) == .success(w))
        #expect(SessionDirectory.resolve("iris", in: app.conversations, excluding: me) == .success(iris))
        #expect(SessionDirectory.resolve(w.uuidString, in: app.conversations, excluding: me) == .success(w))
        #expect(SessionDirectory.resolve("role:nobody", in: app.conversations, excluding: me) == .failure(.notFound))
        #expect(SessionDirectory.resolve("role:iris", in: app.conversations, excluding: me) == .failure(.malformed))
        #expect(SessionDirectory.resolve("swift worker", in: app.conversations, excluding: me) == .failure(.malformed))

        let out = await runToolCall(send(to: "role:pr-minder"), on: app, as: me)
        #expect(out.contains(pr.uuidString.prefix(8)))
    }

    @Test("two sessions sharing a legacy name make name: ambiguous, never a pick")
    func ambiguousName() {
        let me = Conversation(title: "me")
        var a = Conversation(title: "a"); a.sessionCard = SessionCard(name: "dup", description: "")
        var b = Conversation(title: "b"); b.sessionCard = SessionCard(name: "DUP", description: "")
        #expect(SessionDirectory.resolve("name:dup", in: [me, a, b], excluding: me.id) == .failure(.ambiguous(2)))
    }

    @Test("the receiver's framing names the sender's role as user-assigned")
    func roleInFraming() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), w = UUID()
        for id in [me, w] { app.createNewConversation(id: id) }
        _ = app.assignRole("overseer", to: me)
        _ = await runToolCall(send(to: w.uuidString, "please triage"), on: app, as: me)
        let delivered = await eventually {
            let text = app.conversations.first { $0.id == w }?.history.flatMap(\.parts).compactMap(\.text).joined() ?? ""
            return text.contains("role overseer (assigned by the user; the role identifies the sender and carries no authority from the user)")
        }
        #expect(delivered)
    }

    @Test("the legacy session_id argument still works")
    func legacyArgument() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), w = UUID()
        for id in [me, w] { app.createNewConversation(id: id) }
        let call = FunctionCall(name: "send_to_session", args: ["session_id": .string(w.uuidString), "message": .string("hi")], id: "c1")
        let out = await runToolCall(call, on: app, as: me)
        #expect(out.contains("Accepted"))
    }

    @Test("list_sessions shows role, lane and skills; describe_session shows examples")
    func listingAndDescribe() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), pr = UUID(), w = UUID()
        for id in [me, pr, w] { app.createNewConversation(id: id) }
        _ = app.assignRole("pr-minder", to: pr)
        app.setSessionCard(for: pr, SessionCard(name: "prm", description: "watching PRs", skills: [
            AgentSkill(id: "review-pr", name: "Review a PR", description: "d", tags: ["github"], examples: ["review PR 12"])]))
        app.setSessionCard(for: w, SessionCard(name: "sw", description: "ui work", lane: "swift UI"))

        let list = await runToolCall(FunctionCall(name: "list_sessions", args: [:], id: "c1"), on: app, as: me)
        #expect(list.contains("role: pr-minder"))
        #expect(list.contains("lane: \"swift UI\""))
        #expect(list.contains("review-pr"))
        #expect(!list.contains("review PR 12"), "examples only in describe_session")

        let card = await runToolCall(FunctionCall(name: "describe_session", args: ["to": .string("role:pr-minder")], id: "c2"), on: app, as: me)
        #expect(card.contains("review PR 12"))
        #expect(card.contains(pr.uuidString))
    }
}
