import Testing
import Foundation
@testable import iris

/// 5c §0.8 insurance (#367 review): if the API ever rejects `ttl` with a 400, the call is retried
/// once at the 5-minute default instead of failing every Iris turn. Scoped mock sessions only,
/// never the global handler (invariant 7).
@Suite struct AnthropicTTLFallbackTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String] = []
        func append(_ s: String) { lock.withLock { bodies.append(s) } }
        var all: [String] { lock.withLock { bodies } }
    }

    private static let ttlRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"system.0.cache_control.ttl: Extra inputs are not permitted"}}"#
    private static let otherRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: must be positive"}}"#
    private static let success = #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":2}}"#

    private static func request(_ ttl: CacheTTLPolicy) -> GeminiRequest {
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])],
                              systemInstruction: Content(role: "system", parts: [Part(text: "sys")]), tools: nil)
        r.cacheHints = CacheHints(ttl: ttl)
        return r
    }

    /// Answers the listed error bodies in order with a 400, then succeeds.
    private static func session(rejections: [String], recorder: Recorder) -> (URLSession, () -> Void) {
        MockURLProtocol.scopedSession { request in
            let body = String(data: request.bodyData ?? Data(), encoding: .utf8) ?? ""
            recorder.append(body)
            let n = recorder.all.count
            let url = request.url!
            if n <= rejections.count {
                return (HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data(rejections[n - 1].utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(success.utf8))
        }
    }

    private static let iris = CacheTTLPolicy(prefix: .oneHour, history: .oneHour)

    private func generate(_ r: GeminiRequest, _ session: URLSession) async throws -> GeminiResponse {
        try await AnthropicClient.generateContent(request: r, model: "m", transport: .direct(apiKey: "k", baseURL: ""),
                                                  session: session)
    }

    private func stream(_ r: GeminiRequest, _ session: URLSession) async throws -> String {
        var text = ""
        for try await event in AnthropicClient.streamContent(request: r, model: "m", session: session,
                                                             transport: { .direct(apiKey: "k", baseURL: "") }) {
            if case .textDelta(let t) = event { text += t }
        }
        return text
    }

    @Test("non-streaming: a 400 naming ttl is retried exactly once, without ttl")
    func generateRetriesOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.ttlRejection], recorder: rec)
        defer { remove() }
        let response = try await generate(Self.request(Self.iris), session)
        #expect(response.candidates?.first?.content?.parts.first?.text == "ok")
        #expect(rec.all.count == 2)
        #expect(rec.all.first?.contains("\"ttl\"") == true)
        #expect(rec.all.last?.contains("\"ttl\"") == false)
        #expect(rec.all.last?.contains("cache_control") == true, "the markers stay, at the 5-minute default")
    }

    @Test("streaming: a 400 naming ttl is retried exactly once, without ttl")
    func streamRetriesOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.ttlRejection], recorder: rec)
        defer { remove() }
        #expect(try await stream(Self.request(Self.iris), session) == "ok")
        #expect(rec.all.count == 2)
        #expect(rec.all.first?.contains("\"ttl\"") == true)
        #expect(rec.all.last?.contains("\"ttl\"") == false)
    }

    @Test("a second ttl rejection is thrown, not retried again")
    func retriesOnlyOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.ttlRejection, Self.ttlRejection], recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) { try await generate(Self.request(Self.iris), session) }
        #expect(rec.all.count == 2)
        let rec2 = Recorder()
        let (session2, remove2) = Self.session(rejections: [Self.ttlRejection, Self.ttlRejection], recorder: rec2)
        defer { remove2() }
        await #expect(throws: APIError.self) { _ = try await stream(Self.request(Self.iris), session2) }
        #expect(rec2.all.count == 2)
    }

    @Test("a 400 about something else, or on a request with no 1h TTL, is not retried")
    func otherFailuresNotRetried() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.otherRejection], recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) { try await generate(Self.request(Self.iris), session) }
        #expect(rec.all.count == 1)

        let rec2 = Recorder()
        let (session2, remove2) = Self.session(rejections: [Self.ttlRejection], recorder: rec2)
        defer { remove2() }
        await #expect(throws: APIError.self) { try await generate(Self.request(.standard), session2) }
        #expect(rec2.all.count == 1)
    }
}
