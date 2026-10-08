import Testing
import Foundation
@testable import IrisKit

/// #314 decision 6: header always, field unset, and on the binding 400 one retry with drop_block.
/// Scoped mock sessions only (invariant 7); `work`'s account is unenforced, so this lane is the
/// only place the retry runs before a paid self-test.
@Suite("The drop_block retry (#314)")
struct AnthropicBindingRetryTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ r: URLRequest) { lock.withLock { requests.append(r) } }
        var all: [URLRequest] { lock.withLock { requests } }
        var bodies: [String] { all.map { String(decoding: $0.bodyData ?? Data(), as: UTF8.self) } }
    }

    static let bindingRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` to \"drop_block\"."}}"#
    static let tamperedRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block."}}"#
    static let success = #"{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}"#
    static let sse = [
        #"event: message_start"#, #"data: {"type":"message_start","message":{"id":"m","input_transformations":[{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}],"usage":{"input_tokens":5,"output_tokens":1}}}"#, "",
        #"event: content_block_start"#, #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, "",
        #"event: content_block_delta"#, #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#, "",
        #"event: content_block_stop"#, #"data: {"type":"content_block_stop","index":0}"#, "",
        #"event: message_delta"#, #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#, "",
        #"event: message_stop"#, #"data: {"type":"message_stop"}"#, "", ""].joined(separator: "\n")

    private static func session(rejections: [String], stream: Bool, recorder: Recorder) -> (URLSession, () -> Void) {
        MockURLProtocol.scopedSession { request in
            recorder.append(request)
            let n = recorder.all.count
            if n <= rejections.count {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields:
                            ["anthropic-thinking-prefix-mismatch": "pattern=first_message_rewritten"])!, Data(rejections[n - 1].utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data((stream ? sse : success).utf8))
        }
    }

    private static func request(_ behaviour: PrefixMismatchBehavior? = nil, force: Bool = false) -> GeminiRequest {
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        r.prefixMismatchBehavior = behaviour
        r.forceBindingBeta = force
        return r
    }
    private static let direct = AnthropicTransport.direct(apiKey: "k", baseURL: "")
    private static let vertex = AnthropicTransport.vertex(project: "iris-test-project", location: "global", accessToken: "t")

    private func built(_ r: GeminiRequest, _ model: String, _ t: AnthropicTransport) throws -> (body: String, beta: String?) {
        let u = try AnthropicClient.makeURLRequest(request: r, model: model, transport: t, stream: true)
        return (String(decoding: u.httpBody ?? Data(), as: UTF8.self), u.value(forHTTPHeaderField: "anthropic-beta"))
    }

    @Test("the field never travels without its header, for any model, route or setting")
    func fieldNeverWithoutHeader() throws {
        for model in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5", "claude-sonnet-5", "claude-made-up-9"] {
            for t in [Self.direct, Self.vertex] {
                for (b, f) in [(nil, false), (PrefixMismatchBehavior.dropBlock, false), (.dropBlock, true)] {
                    let (body, beta) = try built(Self.request(b, force: f), model, t)
                    if body.contains("block_binding") { #expect(beta == AnthropicCapabilities.bindingBeta, "\(model) \(t)") }
                }
            }
        }
    }

    @Test("the field is the adaptive thinking object the docs give")
    func fieldShape() throws {
        let u = try AnthropicClient.makeURLRequest(request: Self.request(.dropBlock), model: "claude-opus-5-5",
                                                   transport: Self.direct, stream: true)
        let body = try #require(try JSONSerialization.jsonObject(with: u.httpBody ?? Data()) as? [String: Any])
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect((thinking["block_binding"] as? [String: Any])?["prefix_mismatch_behavior"] as? String == "drop_block")
    }

    @Test("a persisted drop_block goes only where the beta is taken (Review Focus 4)")
    func persistedFieldOnlyWhereTheBetaIsTaken() throws {
        #expect(try built(Self.request(.dropBlock), "claude-opus-5-5", Self.direct).body.contains("block_binding"))
        #expect(try built(Self.request(.dropBlock), "claude-opus-5-5", Self.vertex).body.contains("block_binding"))
        #expect(try built(Self.request(.dropBlock), "claude-sonnet-5-5", Self.vertex).body.contains("block_binding"))
        for (model, t) in [("claude-sonnet-5", Self.direct), ("claude-haiku-4-5-20251001", Self.direct),
                           ("claude-made-up-9", Self.direct), ("claude-made-up-9", Self.vertex)] {
            let (body, beta) = try built(Self.request(.dropBlock), model, t)
            #expect(!body.contains("block_binding") && !body.contains("\"thinking\""), "\(model)")
            #expect(beta == nil, "\(model)")
        }
    }

    @Test("non-streaming: the binding 400 is retried once with drop_block and the header, and the response says so")
    func generateRetriesOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        let response = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5",
                                                                 transport: Self.direct, session: session)
        #expect(response.anthropicBindingFallback)
        #expect(rec.all.count == 2)
        #expect(!rec.bodies[0].contains("block_binding"))
        #expect(rec.all[0].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        #expect(rec.bodies[1].contains(#""prefix_mismatch_behavior":"drop_block""#))
        #expect(rec.all[1].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
    }

    @Test("streaming: the same retry, before any event, with the fallback event last")
    func streamRetriesOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection], stream: true, recorder: rec)
        defer { remove() }
        var events: [LLMStreamEvent] = []
        for try await e in AnthropicClient.streamContent(request: Self.request(), model: "claude-opus-5-5", session: session,
                                                         transport: { Self.direct }) { events.append(e) }
        #expect(events.last == .prefixMismatchFallback)
        #expect(events.contains(.textDelta("ok")))
        #expect(rec.all.count == 2)
        #expect(rec.bodies[1].contains("drop_block"))
    }

    @Test("an unknown id that answers the binding 400 gets the header and the field on the retry")
    func unknownIdRetryAddsHeader() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-made-up-9",
                                                      transport: Self.direct, session: session)
        #expect(rec.all[0].value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(rec.all[1].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        #expect(rec.bodies[1].contains("drop_block"))
    }

    @Test("a second binding 400 is thrown, not retried again")
    func retriesOnlyOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection, Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5",
                                                          transport: Self.direct, session: session)
        }
        #expect(rec.all.count == 2)
    }

    @Test("streaming: a retry that fails again yields no fallback event")
    func failedRetryYieldsNoFallback() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection, Self.bindingRejection], stream: true, recorder: rec)
        defer { remove() }
        var events: [LLMStreamEvent] = []
        await #expect(throws: APIError.self) {
            for try await e in AnthropicClient.streamContent(request: Self.request(), model: "claude-opus-5-5", session: session,
                                                             transport: { Self.direct }) { events.append(e) }
        }
        #expect(rec.all.count == 2, "precondition: the retry ran")
        #expect(!events.contains(.prefixMismatchFallback))
    }

    static let ttlRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"system.0.cache_control.ttl: Extra inputs are not permitted"}}"#

    /// A 1-hour prefix, as Iris's own conversation sends: on a route that rejects that TTL, the
    /// TTL retry goes first, and the binding retry must still follow it (review Minor 3).
    private static func oneHourRequest() -> GeminiRequest {
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])],
                              systemInstruction: Content(role: "system", parts: [Part(text: "sys")]), tools: nil)
        r.cacheHints = CacheHints(ttl: CacheTTLPolicy(prefix: .oneHour, history: .oneHour))
        return r
    }

    @Test("non-streaming: a TTL retry answered by the binding 400 still gets the binding retry, once")
    func generateBindingAfterTTL() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.ttlRejection, Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        let response = try await AnthropicClient.generateContent(request: Self.oneHourRequest(), model: "claude-opus-5-5",
                                                                 transport: Self.direct, session: session)
        #expect(response.anthropicBindingFallback)
        #expect(rec.all.count == 3)
        #expect(rec.bodies[0].contains(#""ttl":"1h""#), "precondition: the first request has the 1-hour TTL")
        #expect(!rec.bodies[1].contains(#""ttl""#) && !rec.bodies[1].contains("drop_block"))
        #expect(!rec.bodies[2].contains(#""ttl""#))
        #expect(rec.bodies[2].contains(#""prefix_mismatch_behavior":"drop_block""#))
        #expect(rec.all[2].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
    }

    @Test("streaming: a TTL retry answered by the binding 400 still gets the binding retry, fallback event last")
    func streamBindingAfterTTL() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.ttlRejection, Self.bindingRejection], stream: true, recorder: rec)
        defer { remove() }
        var events: [LLMStreamEvent] = []
        for try await e in AnthropicClient.streamContent(request: Self.oneHourRequest(), model: "claude-opus-5-5", session: session,
                                                         transport: { Self.direct }) { events.append(e) }
        #expect(rec.all.count == 3)
        #expect(!rec.bodies[2].contains(#""ttl""#))
        #expect(rec.bodies[2].contains(#""prefix_mismatch_behavior":"drop_block""#))
        #expect(events.contains(.textDelta("ok")))
        #expect(events.last == .prefixMismatchFallback)
    }

    @Test("each retry fires at most once: TTL, binding, then a second binding 400 is thrown")
    func composedRetriesStopAtThree() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.ttlRejection, Self.bindingRejection, Self.bindingRejection],
                                             stream: true, recorder: rec)
        defer { remove() }
        var events: [LLMStreamEvent] = []
        await #expect(throws: APIError.self) {
            for try await e in AnthropicClient.streamContent(request: Self.oneHourRequest(), model: "claude-opus-5-5", session: session,
                                                             transport: { Self.direct }) { events.append(e) }
        }
        #expect(rec.all.count == 3)
        #expect(!events.contains(.prefixMismatchFallback))
    }

    @Test("a tampered signature (no 'bound to a different conversation') is not retried")
    func tamperedNotRetried() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.tamperedRejection], stream: false, recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5",
                                                          transport: Self.direct, session: session)
        }
        #expect(rec.all.count == 1)
    }

    @Test("the diagnosis header rides the APIError")
    func diagnosisOnTheError() {
        let e = APIError.http(provider: "Anthropic", statusCode: 400, body: Data(Self.bindingRejection.utf8),
                              headers: ["anthropic-thinking-prefix-mismatch": "pattern=x"])
        #expect(e.prefixMismatchDiagnosis == "pattern=x")
    }

    @Test("a BeforeModel rewrite keeps the conversation's binding setting")
    func hookRewriteKeepsBinding() throws {
        let original = Self.request(.dropBlock)
        let rewritten = IrisEngine.applyHookRewrite(try JSONEncoder().encode(original), to: original)
        #expect(rewritten.prefixMismatchBehavior == .dropBlock)
    }

    @Test("a binding error after the stream has started is thrown, not retried (ruling 3)")
    func noRetryAfterStreamStarted() async throws {
        // An SSE `error` event maps to the same 400 APIError as a non-200 body, so only `!yielded`
        // stands between it and a retry that would append a second reply to the first's text.
        let midStream = [
            #"event: content_block_start"#, #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, "",
            #"event: content_block_delta"#, #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half"}}"#, "",
            #"event: error"#, "data: " + Self.bindingRejection, "", ""].joined(separator: "\n")
        let rec = Recorder()
        let (session, remove) = MockURLProtocol.scopedSession { request in
            rec.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(midStream.utf8))
        }
        defer { remove() }
        var events: [LLMStreamEvent] = []
        await #expect(throws: APIError.self) {
            for try await e in AnthropicClient.streamContent(request: Self.request(), model: "claude-opus-5-5", session: session,
                                                             transport: { Self.direct }) { events.append(e) }
        }
        #expect(events.contains(.textDelta("half")), "precondition: an event was yielded before the error")
        #expect(!events.contains(.prefixMismatchFallback))
        #expect(rec.all.count == 1)
    }

    @Test("without the binding field the body carries no thinking object, as on main (ruling 2)")
    func noThinkingWithoutTheField() throws {
        for model in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5", "claude-sonnet-5", "claude-made-up-9"] {
            for t in [Self.direct, Self.vertex] {
                #expect(!(try built(Self.request(), model, t).body.contains("\"thinking\"")), "\(model) \(t)")
            }
        }
    }

    @Test("an assembled stream carries the fallback flag, and a response replays it first")
    func assemblerCarriesTheFlag() {
        var a = StreamAssembler()
        a.apply(.prefixMismatchFallback, now: 0)
        a.apply(.textDelta("ok"), now: 0)
        let response = a.response()
        #expect(response.anthropicBindingFallback)
        #expect(LLMStreamEvent.events(from: response).last == .prefixMismatchFallback)
        #expect(!LLMStreamEvent.events(from: GeminiResponse(candidates: [], usageMetadata: nil)).contains(.prefixMismatchFallback))
    }

    @MainActor
    @Test("after a drop_block reply the floor rises to the whole history, the retry's own reply included (plan note 6)")
    func fallbackRaisesTheFloor() async throws {
        let dir = try ThinkingFixtures.tempDirectory("binding-floor")
        defer { try? FileManager.default.removeItem(at: dir) }
        var script = ThinkingFixtures.fourRounds()
        script[1].anthropicBindingFallback = true
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        try #require(h.client.requests.count == 4)
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]],
                "request three drops sig-1 and the retry's sig-2; sig-3 was bound to request three's prefix")
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: ["sig-1", "sig-2", "sig-3", "sig-4"])
    }
}
