import Testing
import Foundation
@testable import iris

/// How the engine surfaces a failed model call: a tagged system pill, not an agent bubble, and
/// transient provider errors (429/503/529) are retried with backoff before anything is shown.
@MainActor
@Suite("IrisEngine LLM error handling")
struct LLMErrorEngineTests {
    /// Throws the scripted errors in order, then returns `finalResponse` for every later call.
    private final class FlakyClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        private let errors: [Error]
        private let finalResponse: GeminiResponse

        init(errors: [Error], then finalResponse: GeminiResponse) {
            self.errors = errors
            self.finalResponse = finalResponse
        }
        var callCount: Int { lock.withLock { index } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let (i, err): (Int, Error?) = lock.withLock {
                defer { index += 1 }
                return (index, index < errors.count ? errors[index] : nil)
            }
            _ = i
            if let err { throw err }
            return finalResponse
        }
    }

    private var ok: GeminiResponse {
        let part = Part(text: "Recovered.", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    private var rateLimited: APIError {
        APIError.http(provider: "Gemini", statusCode: 429,
                      body: Data(#"{"error":{"code":429,"message":"Resource exhausted.","status":"RESOURCE_EXHAUSTED"}}"#.utf8))
    }
    private var unauthenticated: APIError {
        APIError.http(provider: "Gemini", statusCode: 401,
                      body: Data(#"{"error":{"code":401,"message":"Bad credentials.","status":"UNAUTHENTICATED"}}"#.utf8))
    }

    private func run(_ client: FlakyClient, retryDelays: [TimeInterval]) async -> Conversation? {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: retryDelays)
        await engine.processInput("hello", source: "User", conversationId: id)
        return app.conversations.first { $0.id == id }
    }

    @Test("a failed call is shown as an LLM_ERROR system pill, not an agent bubble")
    func failureIsASystemPill() async throws {
        let client = FlakyClient(errors: [unauthenticated], then: ok)
        let conv = try #require(await run(client, retryDelays: []))
        let errors = conv.messages.compactMap { m in LLMErrorMessage.parse(m.content).map { (m.role, $0) } }
        #expect(errors.count == 1)
        #expect(errors.first?.0 == .system)
        #expect(errors.first?.1.headline == "Gemini HTTP 401 UNAUTHENTICATED: Bad credentials.")
        #expect(!conv.messages.contains { $0.role == .agent && $0.content.hasPrefix("Error calling LLM") })
    }

    @Test("a 401 is not retried")
    func nonRetryableIsNotRetried() async {
        let client = FlakyClient(errors: [unauthenticated], then: ok)
        _ = await run(client, retryDelays: [0, 0, 0])
        #expect(client.callCount == 1)
    }

    @Test("a 429 is retried and the eventual reply reaches the user")
    func rateLimitIsRetried() async throws {
        let client = FlakyClient(errors: [rateLimited, rateLimited], then: ok)
        let conv = try #require(await run(client, retryDelays: [0, 0, 0]))
        #expect(client.callCount == 3)
        #expect(conv.messages.contains { $0.role == .agent && $0.content == "Recovered." })
        #expect(!conv.messages.contains { LLMErrorMessage.parse($0.content) != nil })
    }

    @Test("each retry is announced with the headline and the wait")
    func retriesAreAnnounced() async throws {
        let client = FlakyClient(errors: [rateLimited], then: ok)
        let conv = try #require(await run(client, retryDelays: [0, 0]))
        let notices = conv.messages.filter { $0.role == .system && $0.content.hasPrefix("[retry]") }
        #expect(notices.count == 1)
        #expect(notices.first?.content.contains("Gemini HTTP 429 RESOURCE_EXHAUSTED") == true)
        #expect(notices.first?.content.contains("1 of 2") == true)
    }

    @Test("when retries are exhausted the last error is shown once")
    func exhaustedRetriesShowError() async throws {
        let client = FlakyClient(errors: [rateLimited, rateLimited, rateLimited, rateLimited], then: ok)
        let conv = try #require(await run(client, retryDelays: [0, 0]))
        #expect(client.callCount == 3)
        #expect(conv.messages.filter { LLMErrorMessage.parse($0.content) != nil }.count == 1)
    }

    @Test("stopping during a retry wait shows no error pill")
    func cancellationDuringBackoffIsSilent() async throws {
        let client = FlakyClient(errors: [rateLimited, rateLimited, rateLimited], then: ok)
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [30, 30])
        let turn = Task { await engine.processInput("hello", source: "User", conversationId: id) }
        // Give the first attempt time to fail and enter the 30 s wait, then press Stop.
        while client.callCount < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        turn.cancel()
        await turn.value
        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(client.callCount == 1)
        #expect(!conv.messages.contains { LLMErrorMessage.parse($0.content) != nil },
                "a user-initiated stop is not an LLM error")
    }

    @Test("no retries are configured means a 429 is shown immediately")
    func zeroRetries() async throws {
        let client = FlakyClient(errors: [rateLimited], then: ok)
        let conv = try #require(await run(client, retryDelays: []))
        #expect(client.callCount == 1)
        #expect(conv.messages.contains { LLMErrorMessage.parse($0.content) != nil })
    }
}
