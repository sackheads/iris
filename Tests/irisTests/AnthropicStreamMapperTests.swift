import Testing
import Foundation
@testable import iris

@Suite("Anthropic stream mapper")
struct AnthropicStreamMapperTests {
    private func run(_ pairs: [(String, String)]) throws -> [LLMStreamEvent] {
        var m = AnthropicStreamMapper()
        var out: [LLMStreamEvent] = []
        for (event, data) in pairs { out += try m.handle(SSEEvent(event: event, data: data)) }
        out += try m.finish()
        return out
    }

    @Test("text block then a tool_use block whose input arrives in four fragments, one of them empty")
    func textThenTool() throws {
        let events = try run([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"check."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_command","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"and\": \"un"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ame\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":31}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        #expect(events == [
            .usage(UsageMetadata(promptTokenCount: 12, candidatesTokenCount: nil, totalTokenCount: nil)),
            .textDelta("Let me "),
            .textDelta("check."),
            .functionCall(FunctionCall(name: "run_command", args: ["command": .string("uname")], id: "toolu_1")),
            .usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 31, totalTokenCount: nil)),
            .done(finishReason: "tool_use")
        ])
    }

    @Test("message_start carries cache read/write counts, and prompt is their sum with input")
    func messageStartCacheCounts() throws {
        let events = try run([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":50}}}"#),
        ])
        #expect(events == [
            .usage(UsageMetadata(promptTokenCount: 960, candidatesTokenCount: nil, totalTokenCount: nil,
                                  cacheReadTokens: 900, cacheWriteTokens: 50)),
            .done(finishReason: nil),
        ])
    }

    @Test("two tool blocks interleaved with text keep their own buffers; an empty input parses as {}")
    func twoTools() throws {
        let events = try run([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"first","input":{}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"and"}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"b","name":"second","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"n\":2}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        #expect(events == [
            .textDelta("and"),
            .functionCall(FunctionCall(name: "first", args: [:], id: "a")),
            .functionCall(FunctionCall(name: "second", args: ["n": .int(2)], id: "b")),
            .done(finishReason: nil)
        ])
    }

    @Test("thinking and signature deltas are dropped")
    func thinkingIgnored() throws {
        let events = try run([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":2}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        #expect(events == [.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 2, totalTokenCount: nil)),
                           .done(finishReason: "refusal")])
    }

    @Test("an error event throws an APIError carrying the provider's type and message")
    func errorEventThrows() {
        var m = AnthropicStreamMapper()
        let data = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(throws: APIError.self) { try m.handle(SSEEvent(event: "error", data: data)) }
        do { _ = try m.handle(SSEEvent(event: "error", data: data)) } catch let e as APIError {
            #expect(e.statusCode == 529)
            #expect(e.message == "Anthropic HTTP 529 overloaded_error: Overloaded")
        } catch { Issue.record("wrong error type \(error)") }
    }

    @Test("a stream that ends without message_stop still emits done once")
    func finishWithoutStop() throws {
        var m = AnthropicStreamMapper()
        _ = try m.handle(SSEEvent(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#))
        #expect(try m.finish() == [.done(finishReason: "end_turn")])
    }

    @Test("a rate_limit_error event throws a retryable APIError with the matching status code")
    func rateLimitErrorThrows() {
        var m = AnthropicStreamMapper()
        let data = #"{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}"#
        do {
            _ = try m.handle(SSEEvent(event: "error", data: data))
            Issue.record("expected a throw")
        } catch let e as APIError {
            #expect(e.statusCode == 429)
            #expect(e.isRetryable == true)
        } catch { Issue.record("wrong error type \(error)") }
    }

    /// Anthropic splits usage across two events: `message_start` carries input + cache tokens,
    /// `message_delta` carries only `output_tokens`. `StreamAssembler.usage` merges field-wise
    /// (max wins per field, not overwrite), and `response()` fills a still-missing total as
    /// prompt + output — so the assembled response's total must be exactly prompt (input + read +
    /// write) + output, not just one event's contribution (5a review #12).
    @Test("StreamAssembler fills the total from Anthropic's split streaming usage: prompt (input+read+write) + output")
    func assemblerFillsTotalFromSplitAnthropicUsage() throws {
        var mapper = AnthropicStreamMapper()
        var assembler = StreamAssembler()
        let events = try mapper.handle(SSEEvent(event: "message_start",
            data: #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":50}}}"#))
            + mapper.handle(SSEEvent(event: "message_delta",
            data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":31}}"#))
            + mapper.finish()
        for event in events { assembler.apply(event, now: 1) }
        let usage = try #require(assembler.response().usageMetadata)
        #expect(usage.promptTokenCount == 960, "input 10 + read 900 + write 50")
        #expect(usage.candidatesTokenCount == 31)
        #expect(usage.totalTokenCount == 991, "prompt (input+read+write) + output")
        #expect(usage.cacheReadTokens == 900)
        #expect(usage.cacheWriteTokens == 50)
    }

    @Test("a malformed chunk throws instead of being skipped")
    func malformedChunkThrows() {
        var m = AnthropicStreamMapper()
        #expect(throws: APIError.self) { try m.handle(SSEEvent(event: nil, data: "{not json")) }
        do { _ = try m.handle(SSEEvent(event: nil, data: "{not json")) }
        catch let e as APIError { #expect(e.message == "Anthropic stream: unexpected payload") }
        catch { Issue.record("wrong error type \(error)") }
    }

    @Test("a valid-JSON-but-non-object payload throws the same unexpected-payload error")
    func nonObjectPayloadThrows() {
        var m = AnthropicStreamMapper()
        #expect(throws: APIError.self) { try m.handle(SSEEvent(event: nil, data: "[1,2]")) }
        do { _ = try m.handle(SSEEvent(event: nil, data: "[1,2]")) }
        catch let e as APIError { #expect(e.message == "Anthropic stream: unexpected payload") }
        catch { Issue.record("wrong error type \(error)") }
    }
}
