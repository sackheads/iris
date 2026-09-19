import Testing
import Foundation
@testable import iris

@Suite("LLM stream primitives")
struct LLMStreamTests {
    // MARK: SSEParser

    @Test("event/data pairs dispatch on the blank line; multi-line data joins with newline")
    func parserBasics() {
        var p = SSEParser()
        #expect(p.feed("event: message_start") == nil)
        #expect(p.feed("data: {\"a\":1}") == nil)
        #expect(p.feed("") == SSEEvent(event: "message_start", data: "{\"a\":1}"))
        #expect(p.feed("data: line one") == nil)
        #expect(p.feed("data: line two") == nil)
        #expect(p.feed("") == SSEEvent(event: nil, data: "line one\nline two"))
    }

    @Test("comments, id/retry fields and repeated blank lines are ignored; a final event without a trailing blank line still dispatches")
    func parserEdges() {
        var p = SSEParser()
        #expect(p.feed(": keep-alive") == nil)
        #expect(p.feed("") == nil)
        #expect(p.feed("id: 7") == nil)
        #expect(p.feed("retry: 100") == nil)
        #expect(p.feed("data:[DONE]") == nil)          // no space after the colon is legal
        #expect(p.finish() == SSEEvent(event: nil, data: "[DONE]"))
        #expect(p.finish() == nil)
    }

    // MARK: StreamAssembler

    private func call(_ name: String) -> FunctionCall {
        FunctionCall(name: name, args: ["x": .int(1)], id: "id-\(name)")
    }

    @Test("text deltas concatenate into one part, calls follow in order, usage merges field-wise")
    func assemblerBuildsResponse() throws {
        var a = StreamAssembler()
        a.apply(.usage(UsageMetadata(promptTokenCount: 10, candidatesTokenCount: nil, totalTokenCount: nil)), now: 1)
        #expect(a.firstTokenAt == nil)
        a.apply(.textDelta("Hel"), now: 5)
        a.apply(.textDelta("lo"), now: 6)
        a.apply(.functionCall(call("run_command")), now: 7)
        a.apply(.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 4, totalTokenCount: nil)), now: 8)
        a.apply(.done(finishReason: "tool_use"), now: 9)
        #expect(a.firstTokenAt == 5)
        let r = a.response()
        let parts = try #require(r.candidates?.first?.content?.parts)
        #expect(parts.count == 2)
        #expect(parts[0].text == "Hello")
        #expect(parts[1].functionCall?.name == "run_command")
        #expect(parts[1].functionCall?.id == "id-run_command")
        #expect(r.candidates?.first?.finishReason == "tool_use")
        #expect(r.usageMetadata?.promptTokenCount == 10)
        #expect(r.usageMetadata?.candidatesTokenCount == 4)
        #expect(r.emptyReason == nil)
    }

    @Test("a thought signature attaches to the text part; a call keeps its own")
    func assemblerSignatures() {
        var a = StreamAssembler()
        a.apply(.textDelta("thinking done"), now: 1)
        a.apply(.thoughtSignature("sig-text"), now: 2)
        var fc = call("t"); fc.thoughtSignature = "sig-call"
        a.apply(.functionCall(fc), now: 3)
        let parts = a.response().candidates!.first!.content!.parts
        #expect(parts[0].thoughtSignature == "sig-text" && parts[0].thought_signature == "sig-text")
        #expect(parts[1].thoughtSignature == "sig-call" && parts[1].thought_signature == nil)
    }

    @Test("no text and no call reproduces the #136 empty reasons exactly")
    func assemblerEmptyReasons() {
        var safety = StreamAssembler()
        safety.apply(.done(finishReason: "SAFETY"), now: 1)
        #expect(safety.response().emptyReason == "finishReason: SAFETY")
        #expect(safety.firstTokenAt == nil)

        var blocked = StreamAssembler()
        blocked.apply(.done(finishReason: nil, blockReason: "PROHIBITED_CONTENT"), now: 1)
        #expect(blocked.response().emptyReason == "blockReason: PROHIBITED_CONTENT")

        var nothing = StreamAssembler()
        nothing.apply(.done(finishReason: nil), now: 1)
        #expect(nothing.response().emptyReason == "empty candidate")
    }

    // MARK: replay / default protocol conformance

    @Test("events(from:) replays a response as text, signature, call, usage, done")
    func replayEvents() {
        let text = Part(text: "hi", thoughtSignature: "s")
        let callPart = Part(functionCall: call("f"), thoughtSignature: "cs")
        let r = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [text, callPart]), finishReason: "STOP")],
                               usageMetadata: UsageMetadata(promptTokenCount: 1, candidatesTokenCount: 2, totalTokenCount: 3))
        let events = LLMStreamEvent.events(from: r)
        var expectedCall = call("f"); expectedCall.thoughtSignature = "cs"
        #expect(events == [.textDelta("hi"), .thoughtSignature("s"), .functionCall(expectedCall),
                           .usage(UsageMetadata(promptTokenCount: 1, candidatesTokenCount: 2, totalTokenCount: 3)),
                           .done(finishReason: "STOP")])
    }

    @Test("a blocked prompt replays its block reason on done")
    func replayBlockReason() {
        var r = GeminiResponse(candidates: nil, usageMetadata: nil)
        r.promptFeedback = PromptFeedback(blockReason: "PROHIBITED_CONTENT")
        #expect(LLMStreamEvent.events(from: r) == [.done(finishReason: nil, blockReason: "PROHIBITED_CONTENT")])
    }

    @Test("a client that only implements generateContent streams by replay and reports no native support")
    func defaultStreamContent() async throws {
        let part = Part(text: "ok")
        let client = FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)])
        #expect(client.supportsStreaming == false)
        var got: [LLMStreamEvent] = []
        let request = GeminiRequest(contents: [], systemInstruction: nil, tools: nil)
        for try await e in client.streamContent(request: request, tier: .medium) { got.append(e) }
        #expect(got == [.textDelta("ok"), .done(finishReason: nil)])
        #expect(client.callCount == 1)
    }

    @Test("a failing generateContent surfaces as a thrown error from the replayed stream")
    func replayPropagatesErrors() async {
        struct Boom: LLMClientProtocol {
            func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
                throw APIError(message: "boom", statusCode: 503)
            }
        }
        let request = GeminiRequest(contents: [], systemInstruction: nil, tools: nil)
        var thrown: Error?
        do { for try await _ in Boom().streamContent(request: request, tier: .medium) {} } catch { thrown = error }
        #expect((thrown as? APIError)?.statusCode == 503)
    }
}
