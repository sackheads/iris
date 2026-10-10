import Testing
import Foundation
@testable import IrisKit

/// 5c §0.4. Several turns of one conversation, states toggling, through one engine. Each turn's
/// declared tools are a superset of the previous turn's, every shared entry encodes byte for byte
/// the same, and shared entries keep their relative order (review focus 2).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ToolPrefixGrowthTests {
    private func encoded(_ d: FunctionDeclaration) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(d)
    }

    @Test func prefixOnlyGrows() async throws {
        let app = AppState(store: try ConversationStore.inMemory())
        let id = UUID(); app.createNewConversation(id: id)
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                factStore: facts, protectionEnabled: false, sessionPeerCount: 0)

        await engine.processInput("hello", source: "UI", conversationId: id)                    // plain
        await engine.processInput("Where does Brian live?", source: "UI", conversationId: id)   // facts on
        await engine.processInput("What is two plus two?", source: "UI", conversationId: id)    // facts off
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship", criteria: [a, b])
        c.milestones = [Milestone(title: "One", criterionIds: [a.id]), Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)
        await engine.processInput("carry on", source: "UI", conversationId: id)                 // ladder on
        app.clearGoal(for: id)
        await engine.processInput("and now?", source: "UI", conversationId: id)                 // ladder off
        await engine.processInput("Stop and summarize.", source: "System", conversationId: id,
                                  restrictToGoalComplete: true)                                   // soft stop

        let turns = client.requests.map { $0.tools?.first?.functionDeclarations ?? [] }
        #expect(turns.count == 6)
        for n in 1..<turns.count {
            let prev = turns[n - 1], next = turns[n]
            let nextByName = Dictionary(next.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for d in prev {
                let match = try #require(nextByName[d.name], "turn \(n + 1) dropped \(d.name)")
                #expect(try encoded(match) == encoded(d), "turn \(n + 1) changed \(d.name)")
            }
            let shared = Set(prev.map(\.name))
            #expect(next.map(\.name).filter(shared.contains) == prev.map(\.name),
                    "turn \(n + 1) reordered the shared prefix")
        }
    }
}
