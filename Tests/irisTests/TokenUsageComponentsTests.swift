import Testing
import Foundation
@testable import iris

/// 5c §0.5-0.6: `TokenUsage` keeps the 1-hour share of the cache writes and splits itself into
/// the components a weight table prices.
@Suite struct TokenUsageComponentsTests {
    @Test func preFiveCJSONDecodesWithNoSplit() throws {
        let json = #"{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12,"cacheWriteTokenCount":4}"#
        let u = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(u.cacheWrite1hTokenCount == nil && u.cacheWriteTokenCount == 4)
    }

    @Test func splitRoundTripsThroughJSON() throws {
        let u = TokenUsage(promptTokenCount: 10, candidatesTokenCount: 2, totalTokenCount: 12,
                           cacheReadTokenCount: nil, cacheWriteTokenCount: 4, cacheWrite1hTokenCount: 3)
        let back = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(u))
        #expect(back.cacheWrite1hTokenCount == 3)
    }

    @Test func componentsChargeThinkingAsOutput() {
        // Gemini: total includes thinking tokens that candidates does not.
        let u = TokenUsage(promptTokenCount: 100, candidatesTokenCount: 10, totalTokenCount: 150,
                           cacheReadTokenCount: 60, cacheWriteTokenCount: nil)
        #expect(u.components == UsageComponents(prompt: 100, output: 50, cacheRead: 60, cacheWrite: 0, cacheWrite1h: 0))
    }

    @MainActor
    @Test func updateAndRunUsageAccumulateTheSplit() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID(); state.createNewConversation(id: id)
        for _ in 0..<2 {
            state.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 50, candidatesTokenCount: 1,
                totalTokenCount: 51, cacheReadTokens: 0, cacheWriteTokens: 40, cacheWrite1hTokens: 30))
        }
        #expect(state.runUsage(for: id).cacheWrite1hTokenCount == 60)
    }

    @MainActor
    @Test func unknownSplitStaysUnknown() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID(); state.createNewConversation(id: id)
        state.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 50, candidatesTokenCount: 1,
            totalTokenCount: 51, cacheReadTokens: 0, cacheWriteTokens: 40))
        #expect(state.runUsage(for: id).cacheWrite1hTokenCount == nil, "5a §0.4: unknown is not zero")
    }

    /// The link-then-update shape of `DelegatedSpendTests`: a linked subagent's 1-hour writes are
    /// charged to the run, so a run that delegates its cache writes still prices them at 2×.
    @MainActor
    @Test func delegatedOneHourWritesReachTheRun() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let run = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(run, budget: TurnBudget(maxTokens: 0, deadline: Date().addingTimeInterval(600)),
                          sink: NoSink())
        let child = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(child, of: run)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 50, candidatesTokenCount: 1,
            totalTokenCount: 51, cacheReadTokens: 0, cacheWriteTokens: 40, cacheWrite1hTokens: 25))
        #expect(state.runUsage(for: run).cacheWrite1hTokenCount == 25)
        #expect(state.runUsage(for: run).cacheWriteTokenCount == 40)
    }

    private struct NoSink: TurnUsageSink {
        func record(_ tokens: TokenUsage) async {}
    }
}
