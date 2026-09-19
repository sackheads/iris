import Testing
import Foundation
@testable import iris

/// Every `data:` payload from `streamGenerateContent?alt=sse` is a whole GenerateContentResponse.
@Suite("Gemini stream mapper")
struct GeminiStreamMapperTests {
    private func run(_ payloads: [String]) throws -> [LLMStreamEvent] {
        var m = GeminiStreamMapper()
        var out: [LLMStreamEvent] = []
        for p in payloads { out += try m.handle(SSEEvent(event: nil, data: p)) }
        out += try m.finish()
        return out
    }

    @Test("text arrives as fragments, a call arrives whole, usage and finish reason on the last chunk")
    func textThenCall() throws {
        let events = try run([
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]}}]}"#,
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"lo"}]}}],"usageMetadata":{"promptTokenCount":9}}"#,
            #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"run_command","args":{"command":"uname"}},"thoughtSignature":"sig1"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":12,"totalTokenCount":21}}"#
        ])
        var expectedCall = FunctionCall(name: "run_command", args: ["command": .string("uname")])
        expectedCall.thoughtSignature = "sig1"
        #expect(events == [
            .textDelta("Hel"),
            .textDelta("lo"),
            .usage(UsageMetadata(promptTokenCount: 9, candidatesTokenCount: nil, totalTokenCount: nil)),
            .functionCall(expectedCall),
            .usage(UsageMetadata(promptTokenCount: 9, candidatesTokenCount: 12, totalTokenCount: 21)),
            .done(finishReason: "STOP")
        ])
    }

    @Test("a text part's thought signature follows its delta")
    func textSignature() throws {
        let events = try run([#"{"candidates":[{"content":{"parts":[{"text":"x","thoughtSignature":"s"}]}}]}"#])
        #expect(events == [.textDelta("x"), .thoughtSignature("s"), .done(finishReason: nil)])
    }

    @Test("a parts-less safety stop yields only done with the finish reason")
    func safetyStop() throws {
        let events = try run([#"{"candidates":[{"finishReason":"SAFETY"}]}"#])
        #expect(events == [.done(finishReason: "SAFETY")])
    }

    @Test("a blocked prompt yields done with the block reason")
    func blockedPrompt() throws {
        let events = try run([#"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}"#])
        #expect(events == [.done(finishReason: nil, blockReason: "PROHIBITED_CONTENT")])
    }

    @Test("a malformed chunk throws instead of being skipped")
    func malformedChunkThrows() {
        var m = GeminiStreamMapper()
        #expect(throws: APIError.self) { try m.handle(SSEEvent(event: nil, data: "{not json")) }
        do { _ = try m.handle(SSEEvent(event: nil, data: "{not json")) }
        catch let e as APIError { #expect(e.message == "Gemini stream: unexpected payload") }
        catch { Issue.record("wrong error type \(error)") }
    }
}
