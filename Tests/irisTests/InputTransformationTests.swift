import Testing
import Foundation
@testable import iris

@Suite("input_transformations and the diagnosis header (#314 decision 7)")
struct InputTransformationTests {
    static let entries = #"[{"type":"thinking_dropped","path":"messages.7.content.0","reason":"prefix_binding_mismatch"},{"type":"later_kind","reason":"later_reason"}]"#

    @Test("message_start carries the array on the message object")
    func fromMessageStart() throws {
        var m = AnthropicStreamMapper()
        let events = try m.handle(SSEEvent(event: "message_start", data:
            #"{"type":"message_start","message":{"id":"m","input_transformations":\#(Self.entries),"usage":{"input_tokens":1}}}"#))
        #expect(events.contains(.inputTransformations([
            InputTransformation(type: "thinking_dropped", path: "messages.7.content.0", reason: "prefix_binding_mismatch"),
            InputTransformation(type: "later_kind", path: nil, reason: "later_reason")])))
    }

    @Test("an empty array is kept as empty, distinct from absent")
    func emptyIsNotAbsent() throws {
        var m = AnthropicStreamMapper()
        let with = try m.handle(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"input_transformations":[]}}"#))
        #expect(with == [.inputTransformations([])])
        var n = AnthropicStreamMapper()
        #expect(try n.handle(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{}}"#)).isEmpty)
    }

    @Test("a final message_delta's array (after a server-side fallback) replaces the first")
    func fromMessageDelta() {
        var a = StreamAssembler()
        a.apply(.inputTransformations([]), now: 0)
        a.apply(.inputTransformations([InputTransformation(type: "thinking_dropped", path: "messages.1.content.0",
                                                           reason: "model_binding_mismatch")]), now: 1)
        #expect(a.response().anthropicInputTransformations?.first?.reason == "model_binding_mismatch")
    }

    @Test("message_delta is parsed too")
    func messageDeltaParsed() throws {
        var m = AnthropicStreamMapper()
        let events = try m.handle(SSEEvent(event: "message_delta", data:
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"input_transformations":[],"usage":{"output_tokens":1}}"#))
        #expect(events.contains(.inputTransformations([])))
    }

    @Test("the non-stream body carries it at the top level")
    func fromNonStream() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(
            #"{"content":[{"type":"text","text":"ok"}],"input_transformations":\#(Self.entries),"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)) as? [String: Any])
        #expect(try AnthropicClient.parseResponse(json).anthropicInputTransformations?.count == 2)
    }

    @Test("the diagnosis header is read case-insensitively, and the Anthropic mapper turns it into an event")
    func diagnosisHeader() {
        #expect(InputTransformation.diagnosis(in: ["Anthropic-Thinking-Prefix-Mismatch": "pattern=x"]) == "pattern=x")
        #expect(InputTransformation.diagnosis(in: ["other": "y"]) == nil)
        var m = AnthropicStreamMapper()
        #expect(m.headers(["anthropic-thinking-prefix-mismatch": "pattern=x"]) == [.prefixMismatchDiagnosis("pattern=x")])
    }

    @Test("the console line names known entries and the header, ignores unknown ones, and is nil when empty")
    func logLine() {
        let known = InputTransformation(type: "thinking_dropped", path: "messages.7.content.0", reason: "prefix_binding_mismatch")
        let unknown = InputTransformation(type: "later_kind", path: nil, reason: "later_reason")
        #expect(InputTransformation.logLine(round: 2, model: "claude-opus-5-5", entries: [known, unknown], diagnosis: "pattern=x")
                == "Anthropic thinking (claude-opus-5-5, round 2): thinking_dropped/prefix_binding_mismatch at messages.7.content.0; anthropic-thinking-prefix-mismatch: pattern=x")
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: [], diagnosis: nil) == nil)
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: [unknown], diagnosis: nil) == nil)
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: nil, diagnosis: nil) == nil)
    }

    /// Ruling R7: `thinking_mismatch_allowed` is what an unenforced account produces, so a known
    /// type is logged whatever its reason. Only `thinking_dropped` with an unknown reason is ignored.
    @Test("a known type is logged with a nil or unknown reason, except thinking_dropped with an unknown one")
    func logLineReasons() {
        let allowedNil = InputTransformation(type: "thinking_mismatch_allowed", path: "messages.3.content.0", reason: nil)
        #expect(InputTransformation.logLine(round: 1, model: "m", entries: [allowedNil], diagnosis: nil)
                == "Anthropic thinking (m, round 1): thinking_mismatch_allowed at messages.3.content.0")
        let allowedOdd = InputTransformation(type: "thinking_mismatch_allowed", path: nil, reason: "later_reason")
        #expect(InputTransformation.logLine(round: 1, model: "m", entries: [allowedOdd], diagnosis: nil)
                == "Anthropic thinking (m, round 1): thinking_mismatch_allowed/later_reason at ?")
        let droppedNil = InputTransformation(type: "thinking_dropped", path: "messages.1.content.0", reason: nil)
        #expect(InputTransformation.logLine(round: 1, model: "m", entries: [droppedNil], diagnosis: nil)
                == "Anthropic thinking (m, round 1): thinking_dropped at messages.1.content.0")
        let droppedOdd = InputTransformation(type: "thinking_dropped", path: nil, reason: "later_reason")
        #expect(InputTransformation.logLine(round: 1, model: "m", entries: [droppedOdd], diagnosis: nil) == nil)
        #expect(InputTransformation.logLine(round: 1, model: "m", entries: [droppedOdd], diagnosis: "p=1")
                == "Anthropic thinking (m, round 1): no transformations; anthropic-thinking-prefix-mismatch: p=1")
    }

    @Test("a malformed element is skipped, not the whole array")
    func mixedArray() throws {
        let value = try JSONSerialization.jsonObject(with: Data(
            #"[{"type":"thinking_dropped","reason":"prefix_binding_mismatch"},"junk",3,{"no_type":1},{"type":"thinking_mismatch_allowed"}]"#.utf8))
        #expect(InputTransformation.list(value) == [
            InputTransformation(type: "thinking_dropped", reason: "prefix_binding_mismatch"),
            InputTransformation(type: "thinking_mismatch_allowed")])
        #expect(InputTransformation.list(["not": "an array"]) == nil)
    }

    @Test("the header is capped at 512 UTF-8 bytes in the console line, on a character boundary")
    func diagnosisCapped() throws {
        let prefix = "Anthropic thinking (m, round 0): no transformations; anthropic-thinking-prefix-mismatch: "
        let exact = String(repeating: "a", count: 512)
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: nil, diagnosis: exact) == prefix + exact)
        // 511 ASCII bytes, then a 2-byte character that would cross the limit.
        let crossing = String(repeating: "a", count: 511) + "é" + "tail"
        let line = try #require(InputTransformation.logLine(round: 0, model: "m", entries: nil, diagnosis: crossing))
        #expect(line == prefix + String(repeating: "a", count: 511) + "…")
        let long = String(repeating: "b", count: 10_000)
        let printed = try #require(InputTransformation.logLine(round: 0, model: "m", entries: nil, diagnosis: long))
        #expect(printed.dropFirst(prefix.count).utf8.count == 512 + "…".utf8.count)
    }

    @Test("a perf record written before #314 decodes, with no transformations")
    func oldRecordDecodes() throws {
        let json = #"{"round":0,"model":"m","latencyMs":1,"returnedToolCalls":false}"#
        let r = try JSONDecoder().decode(ModelCallRecord.self, from: Data(json.utf8))
        #expect(r.inputTransformations == nil)
    }

    @Test("the fields are never encoded into the AfterModel payload, and replay as events")
    func notEncodedButReplayed() throws {
        var response = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        response.anthropicInputTransformations = []
        response.anthropicPrefixDiagnosis = "pattern=x"
        #expect(!String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains("pattern=x"))
        var a = StreamAssembler()
        for e in LLMStreamEvent.events(from: response) { a.apply(e, now: 0) }
        #expect(a.response().anthropicInputTransformations == [])
        #expect(a.response().anthropicPrefixDiagnosis == "pattern=x")
    }

    // MARK: end to end, over a scoped mock session (invariant 7)

    private static let header = ["Content-Type": "text/event-stream",
                                 "anthropic-thinking-prefix-mismatch": "pattern=x"]

    /// The live probe (#314, Vertex): the stream carries the array in `message_start` only; the
    /// final `message_delta` has none, and must not clear what `message_start` gave.
    @Test("a stream carrying the array only in message_start records it, with the 200's header")
    func streamMessageStartOnly() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","input_transformations":[{"type":"thinking_mismatch_allowed","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}],"usage":{"input_tokens":3}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let (session, remove) = MockURLProtocol.scopedSession { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: Self.header)!, Data(sse.utf8))
        }
        defer { remove() }
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        var a = StreamAssembler()
        for try await event in AnthropicClient.streamContent(request: request, model: "m", session: session,
                                                             transport: { .direct(apiKey: "k", baseURL: "") }) {
            a.apply(event, now: 0)
        }
        let response = a.response()
        #expect(response.anthropicInputTransformations == [
            InputTransformation(type: "thinking_mismatch_allowed", path: "messages.1.content.0", reason: "prefix_binding_mismatch")])
        #expect(response.anthropicPrefixDiagnosis == "pattern=x")
        #expect(response.candidates?.first?.finishReason == "end_turn")
    }

    @Test("a non-stream call records the top-level array and the header")
    func nonStreamEndToEnd() async throws {
        let body = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","input_transformations":[],"usage":{"input_tokens":1,"output_tokens":1}}"#
        let (session, remove) = MockURLProtocol.scopedSession { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["anthropic-thinking-prefix-mismatch": "pattern=y"])!, Data(body.utf8))
        }
        defer { remove() }
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let response = try await AnthropicClient.generateContent(request: request, model: "m",
                                                                 transport: .direct(apiKey: "k", baseURL: ""), session: session)
        #expect(response.anthropicInputTransformations == [])
        #expect(response.anthropicPrefixDiagnosis == "pattern=y")
        #expect(response.candidates?.first?.finishReason == "end_turn")
    }
}
