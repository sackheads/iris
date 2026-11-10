import Testing
import Foundation
@testable import IrisKit

/// #1018: `thinking.display` now goes to every default user on every route, including ones that
/// were never probed (a direct key, a custom base URL). A 400 that names it is retried once without
/// it, and the endpoint is remembered so only its first request ever pays. Each test uses an
/// endpoint of its own (a unique base URL), so the process-wide memory is never shared (invariant 7).
@Suite("The thinking.display fallback (#1018)", .timeLimit(.minutes(1)))
struct AnthropicDisplayFallbackTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ r: URLRequest) { lock.withLock { requests.append(r) } }
        var all: [URLRequest] { lock.withLock { requests } }
        var bodies: [String] { all.map { String(decoding: $0.bodyData ?? Data(), as: UTF8.self) } }
    }

    static let displayRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"thinking.display: Extra inputs are not permitted"}}"#
    static let otherRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"x-api-key: invalid"}}"#

    private static func endpoint() -> AnthropicTransport {
        .direct(apiKey: "k", baseURL: "https://proxy-\(UUID().uuidString.lowercased()).example/v1")
    }

    private static func request() -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
    }

    private static func session(rejections: [String], stream: Bool, recorder: Recorder) -> (URLSession, () -> Void) {
        MockURLProtocol.scopedSession { request in
            recorder.append(request)
            let n = recorder.all.count
            if n <= rejections.count {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data(rejections[n - 1].utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data((stream ? AnthropicBindingRetryTests.sse : AnthropicBindingRetryTests.success).utf8))
        }
    }

    @Test("only a 400 that names display is a display rejection, and never one already retried")
    func predicate() {
        func error(_ status: Int, _ body: String) -> APIError {
            APIError.http(provider: "Anthropic", statusCode: status, body: Data(body.utf8), headers: [:])
        }
        let plain = Self.request()
        var omitted = Self.request()
        omitted.omitThinkingDisplay = true
        #expect(AnthropicClient.isDisplayRejection(error(400, Self.displayRejection), request: plain))
        #expect(!AnthropicClient.isDisplayRejection(error(400, Self.otherRejection), request: plain))
        #expect(!AnthropicClient.isDisplayRejection(error(400, #"{"error":{"message":"tools.4.custom.name: got display_image"}}"#), request: plain))
        #expect(!AnthropicClient.isDisplayRejection(error(400, #"{"error":{"message":"messages.2.content.0.text: contains the display name Jo"}}"#), request: plain))
        #expect(!AnthropicClient.isDisplayRejection(error(500, Self.displayRejection), request: plain))
        #expect(!AnthropicClient.isDisplayRejection(error(400, AnthropicBindingRetryTests.bindingRejection), request: plain),
                "the binding 400 mentions thinking blocks, not display")
        #expect(!AnthropicClient.isDisplayRejection(error(400, Self.displayRejection), request: omitted), "once, never twice")
    }

    @Test("non-streaming: the display 400 is retried once without display, and the next call to that endpoint omits it from the start")
    func generateRetriesAndRemembers() async throws {
        let transport = Self.endpoint()
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.displayRejection], stream: false, recorder: rec)
        defer { remove() }
        _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-sonnet-5-5", transport: transport, session: session)
        #expect(rec.all.count == 2)
        #expect(rec.bodies[0].contains("\"display\""))
        #expect(!rec.bodies[1].contains("\"display\"") && !rec.bodies[1].contains("\"thinking\""))

        let again = Recorder()
        let (session2, remove2) = Self.session(rejections: [], stream: false, recorder: again)
        defer { remove2() }
        _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-sonnet-5-5", transport: transport, session: session2)
        #expect(again.all.count == 1, "remembered: no failed first request")
        #expect(!again.bodies[0].contains("\"display\""))
    }

    @Test("another endpoint is not affected by the first one's rejection")
    func otherEndpointKeepsDisplay() async throws {
        let first = Self.endpoint()
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.displayRejection], stream: false, recorder: rec)
        defer { remove() }
        _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5", transport: first, session: session)

        let other = Recorder()
        let (session2, remove2) = Self.session(rejections: [], stream: false, recorder: other)
        defer { remove2() }
        _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5", transport: Self.endpoint(), session: session2)
        #expect(other.bodies[0].contains("\"display\":\"summarized\""))
    }

    @Test("streaming: the same retry, before any event")
    func streamRetriesAndRemembers() async throws {
        let transport = Self.endpoint()
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.displayRejection], stream: true, recorder: rec)
        defer { remove() }
        var events: [LLMStreamEvent] = []
        for try await e in AnthropicClient.streamContent(request: Self.request(), model: "claude-sonnet-5-5", session: session,
                                                         transport: { transport }) { events.append(e) }
        #expect(events.contains(.textDelta("ok")))
        #expect(rec.all.count == 2)
        #expect(rec.bodies[0].contains("\"display\"") && !rec.bodies[1].contains("\"display\""))
        #expect(!events.contains(.prefixMismatchFallback), "a display fallback is not a binding fallback")
    }

    @Test("a different 400 is not retried, and a second display 400 is thrown, not looped")
    func noLoop() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.otherRejection], stream: false, recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5", transport: Self.endpoint(), session: session)
        }
        #expect(rec.all.count == 1)

        let twice = Recorder()
        let (session2, remove2) = Self.session(rejections: [Self.displayRejection, Self.displayRejection], stream: false, recorder: twice)
        defer { remove2() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5", transport: Self.endpoint(), session: session2)
        }
        #expect(twice.all.count == 2)
    }

    @Test("a retry that fails again does not teach the endpoint anything: display is still sent there next time")
    func failedRetryIsNotRemembered() async throws {
        let transport = Self.endpoint()
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.displayRejection, Self.displayRejection], stream: false, recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5", transport: transport, session: session)
        }
        #expect(!AnthropicCapabilities.rejectsDisplay(transport))

        let streamed = Recorder()
        let (session2, remove2) = Self.session(rejections: [Self.displayRejection, Self.displayRejection], stream: true, recorder: streamed)
        defer { remove2() }
        await #expect(throws: APIError.self) {
            for try await _ in AnthropicClient.streamContent(request: Self.request(), model: "claude-opus-5-5", session: session2,
                                                             transport: { transport }) {}
        }
        #expect(!AnthropicCapabilities.rejectsDisplay(transport))
    }

    @Test("a successful retry teaches the endpoint, streamed or not")
    func successfulRetryIsRemembered() async throws {
        let transport = Self.endpoint()
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.displayRejection], stream: true, recorder: rec)
        defer { remove() }
        for try await _ in AnthropicClient.streamContent(request: Self.request(), model: "claude-opus-5-5", session: session,
                                                         transport: { transport }) {}
        #expect(AnthropicCapabilities.rejectsDisplay(transport))
    }

    @Test("a non-streamed reply that now carries a thinking block parses to its text, and the block is stored for replay (#1018)")
    func nonStreamedThinkingBlockParses() throws {
        let raw = #"{"id":"m","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"weighing it","signature":"sig-1"},{"type":"text","text":"answer"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":9}}"#
        let json = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let parsed = try AnthropicClient.parseResponse(json, raw: Data(raw.utf8))
        let content = try #require(parsed.candidates?.first?.content)
        #expect(content.parts.compactMap(\.text) == ["answer"], "the thinking text is not part of the reply")
        #expect(content.anthropicBlocks != nil, "the block is kept as it arrived")
    }
}
