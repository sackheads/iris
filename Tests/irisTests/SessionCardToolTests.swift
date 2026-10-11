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
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a); app.createNewConversation(id: b)
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
        let out = await run(["name": .string("n"), "description": .string("d"), "lane": .string("github"),
                             "skills": .array(six)], on: app, as: a)
        #expect(app.conversations.first { $0.id == a }?.sessionCard?.skills.count == IrisEngine.skillsMax)
        #expect(out.contains("truncated"), "more than skillsMax valid skills were supplied and some were dropped")
        _ = await run(["name": .string("n"), "description": .string("new")], on: app, as: a)
        let card = app.conversations.first { $0.id == a }?.sessionCard
        #expect(card?.description == "new")
        #expect(card?.skills.count == IrisEngine.skillsMax)
        #expect(card?.lane == "github")
    }

    @Test("hostile skill-id/lane text is flattened in the echo, an over-long lane is stored truncated, and malformed/non-array skills are handled")
    func hostileAndMalformedInput() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        _ = app.assignRole("pr-minder", to: a)

        let hostileId = "id\n1|bad\"x"
        let hostileLane = "lane\n1|bad\"x"
        let hostileSkill: JSONValue = .object(["id": .string(hostileId), "name": .string("n"), "description": .string("d")])
        let out = await run(["name": .string("n"), "description": .string("d"), "lane": .string(hostileLane),
                             "skills": .array([hostileSkill])], on: app, as: a)
        #expect(!out.contains("\n"), "no raw newline from the lane or skill id leaked into the echo")
        #expect(!out.contains("1|bad"), "the raw pipe-bearing text must not survive flattening")
        #expect(out.contains(IrisEngine.flattenCardField(hostileLane, cap: IrisEngine.cardLaneCap)))
        #expect(out.contains(IrisEngine.flattenCardField(hostileId, cap: IrisEngine.skillIdCap)))

        // A lane longer than the cap is stored truncated.
        let longLane = String(repeating: "x", count: IrisEngine.cardLaneCap + 50)
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string(longLane)], on: app, as: a)
        let lane = app.conversations.first { $0.id == a }?.sessionCard?.lane
        #expect(lane?.count == IrisEngine.cardLaneCap + 1)
        #expect(lane?.hasSuffix("\u{2026}") == true)

        // A malformed skills item (a JSON string, not an object) is dropped; a valid sibling survives.
        _ = await run(["name": .string("n"), "description": .string("d"),
                       "skills": .array([.string("bogus"), skill("good")])], on: app, as: a)
        let kept = app.conversations.first { $0.id == a }?.sessionCard?.skills
        #expect(kept?.map(\.id) == ["good"])

        // A `skills` argument that is not an array leaves the existing skills unchanged.
        _ = await run(["name": .string("n"), "description": .string("d"), "skills": .string("nope")], on: app, as: a)
        let unchanged = app.conversations.first { $0.id == a }?.sessionCard?.skills
        #expect(unchanged?.map(\.id) == ["good"])
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
