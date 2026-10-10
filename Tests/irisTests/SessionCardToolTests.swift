import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("set_session_card part 2", .timeLimit(.minutes(1)))
struct SessionCardToolTests {
    private func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    private func run(_ args: [String: JSONValue], on app: AppState, as id: UUID) async -> String {
        let call = FunctionCall(name: "set_session_card", args: args, id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, conversationId: id)
    }

    private func skill(_ id: String) -> JSONValue {
        .object(["id": .string(id), "name": .string(id), "description": .string("d"),
                 "tags": .array([.string("t")]), "examples": .array([.string("e")])])
    }

    @Test("a name another active session holds is refused, case-insensitively, listing taken names")
    func nameCollision() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a); app.createNewConversation(id: b)
        app.setSessionCard(for: b, SessionCard(name: "Swift-Worker", description: "x"))
        let out = await run(["name": .string("swift-worker"), "description": .string("y")], on: app, as: a)
        #expect(out.contains("taken") && out.contains("Swift-Worker"))
        #expect(app.conversations.first { $0.id == a }?.sessionCard == nil)
    }

    @Test("an archived session's name is free")
    func archivedNameFree() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] { app.createNewConversation(id: id) }
        app.setSessionCard(for: b, SessionCard(name: "w", description: "x"))
        _ = app.archiveConversation(b)
        _ = await run(["name": .string("w"), "description": .string("y")], on: app, as: a)
        #expect(app.conversations.first { $0.id == a }?.sessionCard?.name == "w")
    }

    @Test("skills are refused without a role")
    func skillsNeedRole() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        let out = await run(["name": .string("n"), "description": .string("d"), "skills": .array([skill("s")])], on: app, as: a)
        #expect(out.contains("role"))
        #expect(app.conversations.first { $0.id == a }?.sessionCard == nil)
    }

    @Test("a role-holder's skills are stored, bounded, and kept when a later call omits them")
    func skillsKept() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        _ = app.assignRole("pr-minder", to: a)
        let six = (1...6).map { skill("s\($0)") }
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string("github"),
                       "skills": .array(six)], on: app, as: a)
        #expect(app.conversations.first { $0.id == a }?.sessionCard?.skills.count == IrisEngine.skillsMax)
        _ = await run(["name": .string("n"), "description": .string("new")], on: app, as: a)
        let card = app.conversations.first { $0.id == a }?.sessionCard
        #expect(card?.description == "new")
        #expect(card?.skills.count == IrisEngine.skillsMax)
        #expect(card?.lane == "github")
    }

    @Test("an empty skills list or empty lane clears them")
    func emptyClears() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        _ = app.assignRole("pr-minder", to: a)
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string("x"), "skills": .array([skill("s")])], on: app, as: a)
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string(""), "skills": .array([])], on: app, as: a)
        let card = app.conversations.first { $0.id == a }?.sessionCard
        #expect(card?.lane == nil && card?.skills.isEmpty == true)
    }
}
