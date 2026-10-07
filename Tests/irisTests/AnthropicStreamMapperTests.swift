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

    /// `message_start` used to require `input_tokens` to emit any usage event at all, which
    /// dropped cache fields that WERE present whenever `input_tokens` itself was missing (5a
    /// review F8). Emit whenever any of the three prompt-side fields is present.
    @Test("message_start without input_tokens still emits usage when cache fields are present")
    func messageStartCacheCountsWithoutInputTokens() throws {
        let events = try run([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":50}}}"#),
        ])
        #expect(events == [
            .usage(UsageMetadata(promptTokenCount: 950, candidatesTokenCount: nil, totalTokenCount: nil,
                                  cacheReadTokens: 900, cacheWriteTokens: 50)),
            .done(finishReason: nil),
        ])
    }

    /// All three absent (no input, no cache fields): genuinely nothing to report, so no usage
    /// event — unlike the case above, there is no cache data this would otherwise drop.
    @Test("message_start with no usage fields at all emits no usage event")
    func messageStartNoUsageFieldsEmitsNothing() throws {
        let events = try run([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","usage":{}}}"#),
        ])
        #expect(events == [.done(finishReason: nil)])
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

    @Test("thinking deltas emit no text and are kept as the reply's blocks")
    func thinkingKeptAsBlocks() throws {
        let events = try run([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":2}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        #expect(events == [.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 2, totalTokenCount: nil)),
                           .anthropicBlocks(#"[{"type":"thinking","thinking":"hmm","signature":"abc"}]"#),
                           .done(finishReason: "refusal")])
    }

    private static func thinking(_ index: Int, signature: String?) -> [(String, String)] {
        var out = [("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
                   ("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"thinking_delta","thinking":"Check \"x\"."}}"#)]
        if let signature {
            out.append(("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"signature_delta","signature":"\#(signature)"}}"#))
        }
        out.append(("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#))
        return out
    }
    private static let stop = [("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#),
                               ("message_stop", #"{"type":"message_stop"}"#)]
    private static func text(_ index: Int, _ s: String) -> [(String, String)] {
        [("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#),
         ("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(s)"}}"#),
         ("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)]
    }
    private func blocks(_ events: [LLMStreamEvent]) -> [String] {
        events.compactMap { if case .anthropicBlocks(let raw) = $0 { return raw } else { return nil } }
    }

    @Test("block order, the signature, and the tool input's own bytes are kept as received")
    func keepsBlocksAsReceived() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + Self.text(1, "Looking.") + [
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"Sea"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ttle\", \"b\": 1.0}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        ] + Self.stop)
        let expected = #"[{"type":"thinking","thinking":"Check \"x\".","signature":"sig-1"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{"query": "Seattle", "b": 1.0}}]"#
        #expect(blocks(events) == [expected])
        #expect(events.last == .done(finishReason: "end_turn"))
        // The UI and the dispatcher still get what they got before.
        #expect(events.contains(.textDelta("Looking.")))
        #expect(events.contains { event in
            if case .functionCall(let c) = event { return c.id == "toolu_1" }
            return false
        })
    }

    @Test("a redacted_thinking block is kept with its data")
    func redactedKept() throws {
        let events = try run([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"ENC=="}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ] + Self.text(1, "ok") + Self.stop)
        #expect(blocks(events) == [#"[{"type":"redacted_thinking","data":"ENC=="},{"type":"text","text":"ok"}]"#])
    }

    @Test("a reply that did not think stores nothing (Fable 5.1 on a short prompt)")
    func unthoughtStoresNothing() throws {
        #expect(blocks(try run(Self.text(0, "hi") + Self.stop)).isEmpty)
    }

    @Test("a thinking block that never got its signature stores nothing (Review Focus 1)")
    func unsignedThinkingStoresNothing() throws {
        #expect(blocks(try run(Self.thinking(0, signature: nil) + Self.text(1, "hi") + Self.stop)).isEmpty)
    }

    @Test("a block that never stopped stores nothing, even when the message stopped (Review Focus 1)")
    func unstoppedBlockStoresNothing() throws {
        let open = Array(Self.thinking(0, signature: "sig-1").dropLast())
        #expect(blocks(try run(open + Self.stop)).isEmpty)
    }

    @Test("a stream that ends without message_stop stores nothing (Review Focus 1)")
    func cutStreamStoresNothing() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + Self.text(1, "hi"))
        #expect(blocks(events).isEmpty)
        #expect(events.last == .done(finishReason: nil))
    }

    @Test("a delta Iris does not fold (citations) stores nothing for that reply")
    func citationsStoreNothing() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + [
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"citations_delta","citation":{"type":"char_location"}}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ] + Self.stop)
        #expect(blocks(events).isEmpty)
    }

    @Test("a missing block index stores nothing: the array would not be what arrived")
    func indexGapStoresNothing() throws {
        #expect(blocks(try run(Self.thinking(0, signature: "sig-1") + Self.text(2, "hi") + Self.stop)).isEmpty)
    }

    @Test("an empty text block is left out of the stored array: sent back, it is a 400")
    func emptyTextOmitted() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + [
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ] + Self.stop)
        #expect(blocks(events) == [#"[{"type":"thinking","thinking":"Check \"x\".","signature":"sig-1"}]"#])
        let whole = #"[{"type":"thinking","thinking":"t","signature":"s"}, {"type":"text","text":""} ,{"type":"tool_use","id":"t1","name":"n","input":{"q": "a,]}", "b": 1.0}}]"#
        #expect(AnthropicBlocks.storable(whole)
                == #"[{"type":"thinking","thinking":"t","signature":"s"},{"type":"tool_use","id":"t1","name":"n","input":{"q": "a,]}", "b": 1.0}}]"#)
    }

    @Test("an empty text block in first position is left out on both paths")
    func emptyTextFirstOmitted() throws {
        let events = try run(Self.text(0, "") + Self.thinking(1, signature: "sig-1") + Self.stop)
        #expect(blocks(events) == [#"[{"type":"thinking","thinking":"Check \"x\".","signature":"sig-1"}]"#])
        let whole = #"[ {"type":"text","text":""},{"type":"thinking","thinking":"t","signature":"s"},{"type":"tool_use","id":"t1","name":"n","input":{"b": 1.0}}]"#
        #expect(AnthropicBlocks.storable(whole)
                == #"[{"type":"thinking","thinking":"t","signature":"s"},{"type":"tool_use","id":"t1","name":"n","input":{"b": 1.0}}]"#)
    }

    /// Task 3's non-stream path calls `storable`; the same rules hold for an array that arrived whole.
    @Test("storable keeps a signed array verbatim and refuses unsigned, unthought, or unknown-typed ones (Review Focus 1)")
    func storableArray() {
        let signed = #"[{"type":"thinking","thinking":"t","signature":"s"},{"type":"text","text":"ok"}]"#
        #expect(AnthropicBlocks.storable(signed) == signed)
        #expect(AnthropicBlocks.storable(#"[{"type":"redacted_thinking","data":"E"}]"#) != nil)
        #expect(AnthropicBlocks.storable(#"[{"type":"thinking","thinking":"t","signature":""}]"#) == nil)
        #expect(AnthropicBlocks.storable(#"[{"type":"thinking","thinking":"t"}]"#) == nil)
        #expect(AnthropicBlocks.storable(#"[{"type":"text","text":"ok"}]"#) == nil)
        #expect(AnthropicBlocks.storable(#"[{"type":"thinking","thinking":"t","signature":"s"},{"type":"server_tool_use"}]"#) == nil)
        #expect(AnthropicBlocks.storable("[]") == nil)
        #expect(AnthropicBlocks.storable("not json") == nil)
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

    @Test("message_start carries the 1-hour split")
    func messageStartOneHourSplit() throws {
        var m = AnthropicStreamMapper()
        let data = #"{"type":"message_start","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":30}}}}"#
        let events = try m.handle(SSEEvent(event: "message_start", data: data))
        guard case .usage(let u)? = events.first else { Issue.record("no usage event"); return }
        #expect(u.cacheWriteTokens == 40 && u.cacheWrite1hTokens == 30)
    }

    /// Plan review focus 3: a field the merge leaves out prices every streamed 1-hour write at 1.25.
    @Test("the stream assembler carries the 1-hour split through the merge")
    func streamAssemblerCarriesOneHourSplit() {
        var a = StreamAssembler()
        a.apply(.usage(UsageMetadata(promptTokenCount: 45, candidatesTokenCount: nil, totalTokenCount: nil,
                                     cacheReadTokens: nil, cacheWriteTokens: 40, cacheWrite1hTokens: 30)), now: 0)
        a.apply(.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 9, totalTokenCount: nil)), now: 1)
        #expect(a.response().usageMetadata?.cacheWrite1hTokens == 30)
    }
}
