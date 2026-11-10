import Testing
import Foundation
@testable import IrisKit

/// #1020: OpenAI's per-tier `reasoning_effort`, the live reasoning display for servers that stream
/// it, and the 400 fallback for a model or route that takes no effort.
@Suite("OpenAI reasoning effort and reasoning display (#1020)", .timeLimit(.minutes(1)))
struct OpenAIReasoningEffortTests {
    private func isolated() -> (ConfigManager, UserDefaults, () -> Void) {
        let name = "iris-openaieffort-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), store, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private let empty = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
    private func key() -> String { "https://x|\(UUID().uuidString)|high" }

    private func wire(_ request: GeminiRequest) throws -> [String: Any] {
        let url = try OpenAIClient.makeURLRequest(request: request, model: "m", apiKey: "k", stream: false)
        let data = try #require(url.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("each tier reads its own effort; empty and unknown words read as none; it persists")
    func perTier() {
        let (config, store, cleanup) = isolated(); defer { cleanup() }
        for tier in [ModelTier.easy, .medium, .hard] { #expect(config.openaiReasoningEffort(for: tier) == nil) }
        config.openaiEffortEasy = "low"; config.openaiEffortMedium = "none"; config.openaiEffortHard = "ludicrous"
        #expect(config.openaiReasoningEffort(for: .easy) == "low")
        #expect(config.openaiReasoningEffort(for: .medium) == "none")
        #expect(config.openaiReasoningEffort(for: .hard) == nil)
        #expect(ConfigManager(store: store).openaiReasoningEffort(for: .easy) == "low")
    }

    @Test("the wire body carries reasoning_effort only when one is set")
    func wireShape() throws {
        #expect(try wire(empty)["reasoning_effort"] == nil)
        var r = empty; r.reasoningEffort = "high"
        #expect(try wire(r)["reasoning_effort"] as? String == "high")
    }

    @Test("a chat call takes the tier's effort; a guard call or a named model never does")
    func resolution() {
        let (config, _, cleanup) = isolated(); defer { cleanup() }
        config.openaiEffortEasy = "minimal"
        #expect(LLMClient.resolvedReasoningEffort(request: empty, tier: .easy, config: config, modelOverride: false) == "minimal")
        #expect(LLMClient.resolvedReasoningEffort(request: empty, tier: .medium, config: config, modelOverride: false) == nil)
        #expect(LLMClient.resolvedReasoningEffort(request: empty, tier: .easy, config: config, modelOverride: true) == nil)
        var guardCall = empty; guardCall.ignoresTierThinkingLevel = true
        #expect(LLMClient.resolvedReasoningEffort(request: guardCall, tier: .easy, config: config, modelOverride: false) == nil)
    }

    @Test("reasoning_content and reasoning stream to the status line; only reasoning_content is kept as the signature")
    func streamDisplay() throws {
        var mapper = OpenAIStreamMapper()
        let a = try mapper.handle(SSEEvent(event: nil, data: #"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#))
        let b = try mapper.handle(SSEEvent(event: nil, data: #"{"choices":[{"delta":{"reasoning":"more"}}]}"#))
        let c = try mapper.handle(SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"Hi"}}]}"#))
        #expect(a == [.thinkingText("think ")] && b == [.thinkingText("more")] && c == [.textDelta("Hi")])
        let end = try mapper.finish()
        #expect(end.contains(.thoughtSignature("think ")), "round trip unchanged")
    }

    @Test("a server that sends both reasoning_content and reasoning in one delta shows it once")
    func bothFieldsShownOnce() throws {
        var mapper = OpenAIStreamMapper()
        let events = try mapper.handle(SSEEvent(event: nil, data: #"{"choices":[{"delta":{"reasoning_content":"same","reasoning":"same"}}]}"#))
        #expect(events == [.thinkingText("same")])
    }

    @Test("a transient error before the first event (503, 429) is not a refusal: no reopen, nothing remembered")
    func streamTransientErrorsPassThrough() async {
        for status in [503, 429, 500] {
            let k = key()
            let opens = Sent()
            let stream = OpenAIEffortFallback.stream(key: k, effort: "high") { e in
                AsyncThrowingStream { c in
                    Task { await opens.add(e) }
                    c.finish(throwing: APIError(message: "busy", statusCode: status))
                }
            }
            do { for try await _ in stream {}; Issue.record("should throw") }
            catch { #expect((error as? APIError)?.statusCode == status) }
            let seen = await opens.all
            #expect(seen == ["high"], "status \(status) reopened without the effort")
            #expect(!OpenAIEffortFallback.isRefused(k))
        }
    }

    @Test("a 400 for the effort alone is answered once without it, and remembered")
    func refusedOnce() async throws {
        let k = key(); let sent = Sent()
        let r: String = try await OpenAIEffortFallback.run(key: k, effort: "high") { e in
            await sent.add(e)
            if e != nil { throw APIError(message: "unsupported", statusCode: 400) }
            return "ok"
        }
        #expect(r == "ok" && OpenAIEffortFallback.isRefused(k))
        let again = Sent()
        _ = try await OpenAIEffortFallback.run(key: k, effort: "high") { e in await again.add(e); return "ok" }
        let first = await sent.all, second = await again.all
        #expect(first == ["high", nil] && second == [nil], "one failed round trip per process")
    }

    @Test("a 400 the prompt causes fails both and remembers nothing; a non-400 does not retry")
    func promptFourHundred() async {
        let k = key()
        do {
            _ = try await OpenAIEffortFallback.run(key: k, effort: "high") { _ in throw APIError(message: "too big", statusCode: 400) } as String
            Issue.record("should throw")
        } catch { #expect((error as? APIError)?.message == "too big") }
        #expect(!OpenAIEffortFallback.isRefused(k))
        let sent = Sent()
        _ = try? await OpenAIEffortFallback.run(key: k, effort: "high") { e in await sent.add(e); throw APIError(message: "busy", statusCode: 503) } as String
        let calls = await sent.all
        #expect(calls == ["high"])
    }

    @Test("a stream rejected before its first event is reopened without the effort; later errors pass through")
    func streamFallback() async throws {
        let k = key()
        let stream = OpenAIEffortFallback.stream(key: k, effort: "high") { e in
            AsyncThrowingStream { c in
                if e != nil { c.finish(throwing: APIError(message: "bad", statusCode: 400)); return }
                c.yield(.textDelta("hi")); c.finish()
            }
        }
        var got: [LLMStreamEvent] = []
        for try await e in stream { got.append(e) }
        #expect(got == [.textDelta("hi")] && OpenAIEffortFallback.isRefused(k))

        let k2 = key()
        let late = OpenAIEffortFallback.stream(key: k2, effort: "high") { _ in
            AsyncThrowingStream { c in c.yield(.textDelta("a")); c.finish(throwing: APIError(message: "late", statusCode: 400)) }
        }
        var n = 0
        do { for try await _ in late { n += 1 } } catch { #expect((error as? APIError)?.message == "late") }
        #expect(n == 1 && !OpenAIEffortFallback.isRefused(k2))
    }
}

private actor Sent {
    var all: [String?] = []
    func add(_ e: String?) { all.append(e) }
}
