import Testing
import Foundation
@testable import iris

@Suite("Usage cache counts (5a)")
struct UsageCacheCountTests {
    @Test("Anthropic non-stream: prompt is input + read + write, and the cache fields are set")
    func anthropicNonStream() throws {
        let json: [String: Any] = ["content": [["type": "text", "text": "hi"]],
                                   "usage": ["input_tokens": 10, "cache_read_input_tokens": 900,
                                             "cache_creation_input_tokens": 50, "output_tokens": 7]]
        let r = try AnthropicClient.parseResponse(json)
        #expect(r.usageMetadata?.promptTokenCount == 960)
        #expect(r.usageMetadata?.cacheReadTokens == 900)
        #expect(r.usageMetadata?.cacheWriteTokens == 50)
        #expect(r.usageMetadata?.totalTokenCount == 967, "total filled from prompt + output: budgets read it")
    }

    @Test("a provider that reports no cache fields yields nil, not zero")
    func absentIsNil() throws {
        let json: [String: Any] = ["content": [["type": "text", "text": "hi"]],
                                   "usage": ["input_tokens": 10, "output_tokens": 7]]
        let r = try AnthropicClient.parseResponse(json)
        #expect(r.usageMetadata?.cacheReadTokens == nil)
        #expect(r.usageMetadata?.cacheWriteTokens == nil)
    }

    @Test("Gemini: cachedContentTokenCount decodes into cacheReadTokens; write stays nil")
    func gemini() throws {
        let data = #"{"promptTokenCount":1000,"cachedContentTokenCount":800,"candidatesTokenCount":5,"totalTokenCount":1005}"#.data(using: .utf8)!
        let u = try JSONDecoder().decode(UsageMetadata.self, from: data)
        #expect(u.cacheReadTokens == 800)
        #expect(u.cacheWriteTokens == nil)
    }

    @Test("OpenAI: prompt_tokens_details.cached_tokens is the read count")
    func openAI() throws {
        let json: [String: Any] = ["choices": [["message": ["role": "assistant", "content": "hi"]]],
                                   "usage": ["prompt_tokens": 1000, "completion_tokens": 5, "total_tokens": 1005,
                                             "prompt_tokens_details": ["cached_tokens": 768]]]
        let r = try OpenAIClient.parseResponse(json)
        #expect(r.usageMetadata?.cacheReadTokens == 768)
        #expect(r.usageMetadata?.promptTokenCount == 1000)
    }

    @Test("withTotal fills a missing total and leaves a reported one alone")
    func withTotal() {
        #expect(UsageMetadata(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: nil).withTotal().totalTokenCount == 7)
        #expect(UsageMetadata(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 9).withTotal().totalTokenCount == 9)
        #expect(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 4, totalTokenCount: nil).withTotal().totalTokenCount == nil)
    }

    @Test("a TokenUsage saved before 5a decodes, with nil cache counts (unknown is not zero)")
    func oldTokenUsageDecodes() throws {
        let old = #"{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7}"#.data(using: .utf8)!
        let u = try JSONDecoder().decode(TokenUsage.self, from: old)
        #expect(u.cacheReadTokenCount == nil && u.cacheWriteTokenCount == nil && u.promptTokenCount == 5)
    }

    @Test("a ModelCallRecord written before 5a decodes, with nil cache counts")
    func oldModelCallRecordDecodes() throws {
        let old = #"{"round":0,"model":"m","latencyMs":1,"promptTokens":5,"outputTokens":2,"returnedToolCalls":false}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ModelCallRecord.self, from: old)
        #expect(r.cacheReadTokens == nil && r.cacheWriteTokens == nil)
    }

    @MainActor @Test("updateTokenUsage sums cache counts, and a nil incoming value leaves the field untouched")
    func accumulates() {
        let app = AppState()
        let id = UUID(); app.createNewConversation(id: id)
        let fresh = app.conversations.first { $0.id == id }!.tokenUsage
        #expect(fresh.cacheReadTokenCount == nil && fresh.cacheWriteTokenCount == nil, "unreported is nil, not zero")

        app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 1, totalTokenCount: 101, cacheReadTokens: 80, cacheWriteTokens: 10))
        let afterReport = app.conversations.first { $0.id == id }!.tokenUsage
        #expect(afterReport.cacheReadTokenCount == 80 && afterReport.cacheWriteTokenCount == 10, "a reported value after nil yields that value")

        app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 1, totalTokenCount: 101, cacheReadTokens: nil, cacheWriteTokens: nil))
        let afterNil = app.conversations.first { $0.id == id }!.tokenUsage
        #expect(afterNil.cacheReadTokenCount == 80 && afterNil.cacheWriteTokenCount == 10, "a nil incoming value leaves the field untouched")
    }
}
