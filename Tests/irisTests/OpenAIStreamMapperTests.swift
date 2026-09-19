import Testing
import Foundation
@testable import iris

@Suite("OpenAI stream mapper")
struct OpenAIStreamMapperTests {
    private func run(_ payloads: [String]) throws -> [LLMStreamEvent] {
        var m = OpenAIStreamMapper()
        var out: [LLMStreamEvent] = []
        for p in payloads { out += try m.handle(SSEEvent(event: nil, data: p)) }
        out += try m.finish()
        return out
    }

    @Test("content deltas stream; usage arrives in a choices-less chunk; [DONE] ends the turn")
    func textOnly() throws {
        let events = try run([
            #"{"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9}}"#,
            "[DONE]"
        ])
        #expect(events == [.textDelta("Hel"), .textDelta("lo"),
                           .usage(UsageMetadata(promptTokenCount: 7, candidatesTokenCount: 2, totalTokenCount: 9)),
                           .done(finishReason: "stop")])
    }

    @Test("two parallel tool calls whose argument fragments interleave by index are emitted in index order at the end")
    func parallelTools() throws {
        let events = try run([
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"run_command","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"command\":\"ls\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a.txt\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]"
        ])
        #expect(events == [
            .functionCall(FunctionCall(name: "read_file", args: ["path": .string("a.txt")], id: "call_a")),
            .functionCall(FunctionCall(name: "run_command", args: ["command": .string("ls")], id: "call_b")),
            .done(finishReason: "tool_calls")
        ])
    }

    @Test("reasoning_content is accumulated and attached as the thought signature, to calls too")
    func reasoning() throws {
        let events = try run([
            #"{"choices":[{"index":0,"delta":{"reasoning_content":"think "},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"reasoning_content":"more"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            "[DONE]"
        ])
        #expect(events == [
            .textDelta("answer"),
            .functionCall(FunctionCall(name: "t", args: [:], id: "c", thought_signature: "think more", thoughtSignature: "think more")),
            .thoughtSignature("think more"),
            .done(finishReason: "tool_calls")
        ])
    }

    @Test("a stream cut off by max tokens keeps its partial text and reports length")
    func truncated() throws {
        let events = try run([
            #"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#
        ])
        #expect(events == [.textDelta("partial"), .done(finishReason: "length")])
    }

    @Test("malformed tool arguments throw")
    func badArgumentsThrow() throws {
        var m = OpenAIStreamMapper()
        _ = try m.handle(SSEEvent(event: nil, data: #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"t","arguments":"{oops"}}]},"finish_reason":"tool_calls"}]}"#))
        #expect(throws: (any Error).self) { try m.handle(SSEEvent(event: nil, data: "[DONE]")) }
    }

    @Test("a malformed chunk throws instead of being skipped")
    func malformedChunkThrows() {
        var m = OpenAIStreamMapper()
        #expect(throws: APIError.self) { try m.handle(SSEEvent(event: nil, data: "{not json")) }
        do { _ = try m.handle(SSEEvent(event: nil, data: "{not json")) }
        catch let e as APIError { #expect(e.message == "OpenAI stream: unexpected payload") }
        catch { Issue.record("wrong error type \(error)") }
    }
}
