# Streaming Responses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Text the model produces appears in the chat as it is produced, for Gemini (including Vertex), Anthropic and OpenAI, with everything downstream of the model call unchanged and time-to-first-token recorded in the perf record.

**Architecture:** A provider-neutral `LLMStreamEvent` stream is added to `LLMClientProtocol` with a default implementation that replays a plain call, so every fake client keeps working. Each real client maps its provider's Server-Sent Events through a small synchronous mapper; the engine folds events with a `StreamAssembler` into the same `GeminiResponse` the rest of the turn already consumes, while a `MessageStreamer` actor grows one agent message in place at most every 50 ms.

**Tech Stack:** Swift 6 / SwiftPM, strict concurrency, Swift Testing, `URLSession.bytes(for:)` + `AsyncBytes.lines`, MarkdownUI (unchanged).

**Spec:** `docs/specs/2026-09-18-streaming-responses-design.md`

## Global Constraints

- Swift 6 language mode with strict concurrency; every new type crossing a `Task` or actor boundary is `Sendable`.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`). Never XCTest for new tests.
- Tests never mutate `ConfigManager.shared` (AGENTS.md). The "streaming off" path is exercised through a client whose `supportsStreaming` is `false`, which is the same engine branch.
- New persisted or recorded fields are Optional and decode when absent: `ModelCallRecord.firstTokenMs`, `PerfEnvironment.streaming`, `PerfScenarioSummary.medianFirstTokenMs`, settings key `STREAM_RESPONSES` (default `true`).
- Tool calls are never emitted partially: a client accumulates argument JSON and emits one `functionCall` per call once it parses.
- A failure before the first `textDelta`/`functionCall` retries exactly as today; a failure after it is never retried (wrapped in `StreamInterruptedError`).
- `firstTokenMs` is recorded only when the engine used a native stream (`streamed == true`); replayed calls leave it nil.
- The flush interval is the single constant `MessageStreamer.flushIntervalMs = 50`.
- Existing test files are extended with the Edit tool, never overwritten with Write.
- Commits are conventional (`feat:`, `test:`, `docs:`, `refactor:`) and end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Deviations from the spec made by this plan, all recorded in the spec by Task 1: the event enum gains `thoughtSignature(String)` (Gemini requires thought signatures echoed back, and the non-streaming decoders keep them); `done` gains a `blockReason` so the #136 pill text is byte-identical; the SSE parser is a synchronous `SSEParser` fed from `bytes.lines` inside the client's task rather than a separate `SSEReader` stream (no non-Sendable `AsyncLineSequence` crosses a task boundary).

---

## File Structure

| file | responsibility |
|---|---|
| `Sources/iris/LLMStream.swift` (new) | `LLMStreamEvent`, `SSEEvent`/`SSEParser`, `StreamMapper` protocol, `StreamAssembler`, `LLMStreamEvent.replay`/`events(from:)`, `LLMClientProtocol` default `streamContent`/`supportsStreaming`, `LLMStreaming.stream` (the shared URLSession → SSE → mapper pump) |
| `Sources/iris/GeminiStreamMapper.swift`, `AnthropicStreamMapper.swift`, `OpenAIStreamMapper.swift` (new) | one provider's SSE → events, pure and synchronous |
| `Sources/iris/LLMClient.swift`, `AnthropicClient.swift`, `OpenAIClient.swift` | request builders extracted from `generateContent`; native `streamContent`; `supportsStreaming` |
| `Sources/iris/LLMError.swift`, `LLMErrorMessage.swift` | `StreamInterruptedError` and its display |
| `Sources/iris/MessageStreamer.swift` (new) | coalescing in-place message updates |
| `Sources/iris/AppState.swift` | `updateMessageContent(id:content:in:persist:)`; `ChatMessage.content` becomes `var` |
| `Sources/iris/ConfigManager.swift`, `SettingsView.swift` | `streamResponses` setting |
| `Sources/iris/PerformanceProfiler.swift`, `PerfRecord.swift`, `PerfRunner.swift` (`PerfSummarizer`), `PerfReport.swift`, `PerfEnvironment+Capture.swift` | `firstTokenMs`, `streaming`, `medianFirstTokenMs`, report column |
| `Sources/iris/iris.swift` | the model-call seam consumes a stream |
| `Tests/irisTests/LLMStreamTests.swift`, `GeminiStreamMapperTests.swift`, `AnthropicStreamMapperTests.swift`, `OpenAIStreamMapperTests.swift`, `StreamingClientTests.swift`, `MessageStreamerTests.swift`, `StreamingEngineTests.swift` (new); `LLMRetryTests.swift`, `LLMErrorMessageTests.swift`, `PerfRecordTests.swift`, `PerfReportTests.swift`, `PerfCompareTests.swift` (extended) | |
| `perf/README.md`, `docs/tool_hooks.md`, the spec | docs |

Conventions used throughout: `Part(text:functionCall:functionResponse:inlineData:thought_signature:thoughtSignature:)` has defaults for every parameter; `FunctionCall(name:args:id:thought_signature:thoughtSignature:)` likewise; `GeminiResponse(candidates:usageMetadata:)`; `Candidate(content:finishReason:)`; `UsageMetadata(promptTokenCount:candidatesTokenCount:totalTokenCount:)`; `APIError.http(provider:statusCode:body:headers:)`.

---

### Task 1: Event model, SSE parser, assembler, protocol default

**Files:**
- Create: `Sources/iris/LLMStream.swift`
- Modify: `Sources/iris/LLMClient.swift:5-7` (protocol), `docs/specs/2026-09-18-streaming-responses-design.md` (record the deviations)
- Test: `Tests/irisTests/LLMStreamTests.swift`

**Interfaces:**
- Produces:
  - `enum LLMStreamEvent: Sendable, Equatable { case textDelta(String); case thoughtSignature(String); case functionCall(FunctionCall); case usage(UsageMetadata); case done(finishReason: String?, blockReason: String? = nil) }`
  - `struct SSEEvent: Equatable, Sendable { var event: String?; var data: String }`
  - `struct SSEParser { mutating func feed(_ line: String) -> SSEEvent?; mutating func finish() -> SSEEvent? }`
  - `protocol StreamMapper: Sendable { mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent]; mutating func finish() throws -> [LLMStreamEvent] }`
  - `struct StreamAssembler: Sendable { text, calls, usage, finishReason, blockReason, firstTokenAt: Double?; mutating func apply(_ event: LLMStreamEvent, now: Double); func response() -> GeminiResponse }`
  - `LLMStreamEvent.events(from response: GeminiResponse) -> [LLMStreamEvent]` and `LLMStreamEvent.replay(_ call: @escaping @Sendable () async throws -> GeminiResponse) -> AsyncThrowingStream<LLMStreamEvent, Error>`
  - `LLMClientProtocol` gains `func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error>` and `var supportsStreaming: Bool { get }`, both defaulted in an extension (replay; `false`).
  - `extension FunctionCall: Equatable {}` and `extension UsageMetadata: Equatable {}` (synthesized; `JSONValue` is already `Equatable`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/LLMStreamTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head`
Expected: errors such as `cannot find 'SSEParser' in scope`, `cannot find 'StreamAssembler' in scope`, `value of type 'FakeLLMClient' has no member 'supportsStreaming'`.

- [ ] **Step 3: Implement `LLMStream.swift`**

Create `Sources/iris/LLMStream.swift`:

```swift
import Foundation

/// One provider-neutral event from a streaming model call
/// (docs/specs/2026-09-18-streaming-responses-design.md §1).
enum LLMStreamEvent: Sendable, Equatable {
    /// A fragment of visible assistant text. Fragments concatenate in order.
    case textDelta(String)
    /// A provider thought signature that belongs to the text part (Gemini requires it echoed back).
    case thoughtSignature(String)
    /// A complete function call. Providers that stream arguments accumulate inside the client
    /// and emit one event per call once its JSON is whole.
    case functionCall(FunctionCall)
    /// Token counts, possibly emitted more than once; fields merge, max wins.
    case usage(UsageMetadata)
    /// The provider ended the turn. `finishReason` is the provider's own string; `blockReason`
    /// is Gemini's prompt-level block, kept separate so the #136 pill reads exactly as before.
    case done(finishReason: String?, blockReason: String? = nil)
}

extension FunctionCall: Equatable {}
extension UsageMetadata: Equatable {}

/// One Server-Sent Event: the optional `event:` name and the joined `data:` payload.
struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Incremental SSE parser. Feed it one line at a time (without the line terminator); it hands
/// back an event on the blank line that ends one. `finish()` flushes an event the stream ended
/// without terminating. Comments (`:` prefix) and unknown fields (`id`, `retry`) are ignored.
struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let (field, value) = Self.split(line)
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    mutating func finish() -> SSEEvent? { flush() }

    private mutating func flush() -> SSEEvent? {
        defer { event = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.hasPrefix(" ") { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

/// Maps one provider's SSE payloads to stream events. Pure and synchronous so a transcript
/// fixture can be asserted as an event list.
protocol StreamMapper: Sendable {
    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent]
    /// Called once after the last SSE event. Emits `done` if the provider never did.
    mutating func finish() throws -> [LLMStreamEvent]
}

/// Folds stream events into the `GeminiResponse` the rest of a turn consumes (spec §4.1).
struct StreamAssembler: Sendable {
    private(set) var text = ""
    private(set) var textSignature: String?
    private(set) var calls: [FunctionCall] = []
    private(set) var usage: UsageMetadata?
    private(set) var finishReason: String?
    private(set) var blockReason: String?
    /// `now` of the first text delta or function call; nil until then.
    private(set) var firstTokenAt: Double?

    mutating func apply(_ event: LLMStreamEvent, now: Double) {
        switch event {
        case .textDelta(let delta):
            text += delta
            if firstTokenAt == nil { firstTokenAt = now }
        case .thoughtSignature(let signature):
            textSignature = signature
        case .functionCall(let call):
            calls.append(call)
            if firstTokenAt == nil { firstTokenAt = now }
        case .usage(let incoming):
            var merged = usage ?? UsageMetadata()
            merged.promptTokenCount = Self.maxOf(merged.promptTokenCount, incoming.promptTokenCount)
            merged.candidatesTokenCount = Self.maxOf(merged.candidatesTokenCount, incoming.candidatesTokenCount)
            merged.totalTokenCount = Self.maxOf(merged.totalTokenCount, incoming.totalTokenCount)
            usage = merged
        case .done(let finish, let block):
            finishReason = finish
            blockReason = block
        }
    }

    /// One candidate: the text (if any) as one part, then one part per call, in the shape the
    /// non-streaming decoders produce. With nothing assembled, `emptyReason` reports the finish
    /// or block reason exactly as #136 does.
    func response() -> GeminiResponse {
        var parts: [Part] = []
        if !text.isEmpty {
            parts.append(Part(text: text, thought_signature: textSignature, thoughtSignature: textSignature))
        }
        for call in calls {
            parts.append(Part(functionCall: call, thought_signature: call.thought_signature, thoughtSignature: call.thoughtSignature))
        }
        let content = parts.isEmpty ? nil : Content(role: "model", parts: parts)
        var response = GeminiResponse(candidates: [Candidate(content: content, finishReason: finishReason)], usageMetadata: usage)
        if let blockReason { response.promptFeedback = PromptFeedback(blockReason: blockReason) }
        return response
    }

    private static func maxOf(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }
}

extension LLMStreamEvent {
    /// A finished response as the events a stream would have produced.
    static func events(from response: GeminiResponse) -> [LLMStreamEvent] {
        var out: [LLMStreamEvent] = []
        let candidate = response.candidates?.first
        for part in candidate?.content?.parts ?? [] {
            if let text = part.text {
                out.append(.textDelta(text))
                if let signature = part.thoughtSignature ?? part.thought_signature { out.append(.thoughtSignature(signature)) }
            }
            if var call = part.functionCall {
                call.thoughtSignature = call.thoughtSignature ?? part.thoughtSignature
                call.thought_signature = call.thought_signature ?? part.thought_signature
                out.append(.functionCall(call))
            }
        }
        if let usage = response.usageMetadata { out.append(.usage(usage)) }
        out.append(.done(finishReason: candidate?.finishReason, blockReason: response.promptFeedback?.blockReason))
        return out
    }

    /// One plain call, replayed as events once it returns. The engine's single code path for
    /// clients without native streaming and for the streaming-off setting.
    static func replay(_ call: @escaping @Sendable () async throws -> GeminiResponse) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await call()
                    for event in events(from: response) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension LLMClientProtocol {
    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        LLMStreamEvent.replay { try await generateContent(request: request, tier: tier) }
    }

    var supportsStreaming: Bool { false }
}
```

Then in `Sources/iris/LLMClient.swift` replace the protocol declaration (lines 5-7) with:

```swift
protocol LLMClientProtocol: Sendable {
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse
    /// Streams the same call. Default (LLMStream.swift): one `generateContent` replayed as events.
    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// True only when `streamContent` reads the provider's stream natively. Default false.
    var supportsStreaming: Bool { get }
}
```

If the compiler rejects capturing the non-`Sendable` `GeminiRequest` in the `replay` closure, mark `GeminiRequest`, `Tool`, `FunctionDeclaration`, `Schema`, `GeminiResponse`, `Candidate` as `Sendable` (they are value types of `Codable` values; `Content`, `Part`, `FunctionCall`, `UsageMetadata`, `PromptFeedback` already are).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LLMStreamTests 2>&1 | tail -15`
Expected: all 10 tests pass. Then `swift build 2>&1 | grep -c "error:"` prints `0` (every existing `LLMClientProtocol` conformer compiles through the defaults).

- [ ] **Step 5: Record the deviations in the spec**

In `docs/specs/2026-09-18-streaming-responses-design.md` §1, add the `thoughtSignature(String)` case and the `blockReason` parameter of `done` to the enum listing with the two design-point sentences from the Global Constraints above; in §2.1 rename `SSEReader` to `SSEParser` and state that it is synchronous and fed from `bytes.lines` inside the client's task. Keep the edit to those two sections.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/LLMStream.swift Sources/iris/LLMClient.swift Tests/irisTests/LLMStreamTests.swift docs/specs/2026-09-18-streaming-responses-design.md
git commit -m "feat(stream): event model, SSE parser, assembler and replay default for LLM clients

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Gemini stream mapper

**Files:**
- Create: `Sources/iris/GeminiStreamMapper.swift`
- Test: `Tests/irisTests/GeminiStreamMapperTests.swift`

**Interfaces:**
- Consumes: `StreamMapper`, `SSEEvent`, `LLMStreamEvent` (Task 1); `GeminiResponse` decoding.
- Produces: `struct GeminiStreamMapper: StreamMapper` (init with no arguments).

- [ ] **Step 1: Write the failing tests**

```swift
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
        #expect(throws: (any Error).self) { try m.handle(SSEEvent(event: nil, data: "{not json")) }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -3`
Expected: `cannot find 'GeminiStreamMapper' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Gemini `streamGenerateContent?alt=sse`: each `data:` payload is a complete
/// `GenerateContentResponse`; text parts are fragments, function calls arrive whole, and
/// `usageMetadata` carries running counts. `done` is emitted at end of stream.
struct GeminiStreamMapper: StreamMapper {
    private var finishReason: String?
    private var blockReason: String?

    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent] {
        let chunk = try JSONDecoder().decode(GeminiResponse.self, from: Data(sse.data.utf8))
        var out: [LLMStreamEvent] = []
        if let candidate = chunk.candidates?.first {
            for part in candidate.content?.parts ?? [] {
                if let text = part.text {
                    out.append(.textDelta(text))
                    if let signature = part.thoughtSignature ?? part.thought_signature { out.append(.thoughtSignature(signature)) }
                }
                if var call = part.functionCall {
                    call.thoughtSignature = call.thoughtSignature ?? part.thoughtSignature
                    call.thought_signature = call.thought_signature ?? part.thought_signature
                    out.append(.functionCall(call))
                }
            }
            if let reason = candidate.finishReason { finishReason = reason }
        }
        if let block = chunk.promptFeedback?.blockReason { blockReason = block }
        if let usage = chunk.usageMetadata { out.append(.usage(usage)) }
        return out
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        [.done(finishReason: finishReason, blockReason: blockReason)]
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter GeminiStreamMapperTests 2>&1 | tail -8`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/GeminiStreamMapper.swift Tests/irisTests/GeminiStreamMapperTests.swift
git commit -m "feat(stream): Gemini SSE mapper

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Anthropic stream mapper

**Files:**
- Create: `Sources/iris/AnthropicStreamMapper.swift`
- Test: `Tests/irisTests/AnthropicStreamMapperTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `APIError.http`.
- Produces: `struct AnthropicStreamMapper: StreamMapper`.

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -3`
Expected: `cannot find 'AnthropicStreamMapper' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Anthropic Messages streaming (`"stream": true`). Text deltas pass through; a `tool_use`
/// block's `input_json_delta` fragments are buffered per block index and emitted as one
/// `functionCall` on `content_block_stop`; `message_start`/`message_delta` carry the two
/// halves of usage; `thinking`/`signature` deltas and `ping` are dropped.
struct AnthropicStreamMapper: StreamMapper {
    private struct ToolBlock { var id: String; var name: String; var json = "" }
    private var tools: [Int: ToolBlock] = [:]
    private var stopReason: String?
    private var stopped = false

    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(sse.data.utf8)) as? [String: Any] else { return [] }
        let type = (json["type"] as? String) ?? sse.event ?? ""
        switch type {
        case "message_start":
            if let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any],
               let input = usage["input_tokens"] as? Int {
                return [.usage(UsageMetadata(promptTokenCount: input, candidatesTokenCount: nil, totalTokenCount: nil))]
            }
        case "content_block_start":
            if let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String, let name = block["name"] as? String {
                tools[index] = ToolBlock(id: id, name: name)
            }
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { return [.textDelta(text)] }
            case "input_json_delta":
                if let index = json["index"] as? Int, let partial = delta["partial_json"] as? String {
                    tools[index]?.json += partial
                }
            default:
                break
            }
        case "content_block_stop":
            if let index = json["index"] as? Int, let block = tools.removeValue(forKey: index) {
                let raw = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
                let args = try JSONDecoder().decode([String: JSONValue].self, from: Data((raw.isEmpty ? "{}" : raw).utf8))
                return [.functionCall(FunctionCall(name: block.name, args: args, id: block.id))]
            }
        case "message_delta":
            var out: [LLMStreamEvent] = []
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String { stopReason = reason }
            if let usage = json["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int {
                out.append(.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: output, totalTokenCount: nil)))
            }
            return out
        case "message_stop":
            stopped = true
            return [.done(finishReason: stopReason)]
        case "error":
            // Same shape and builder as a non-2xx body, so the pill and retry classification match.
            let errorType = (json["error"] as? [String: Any])?["type"] as? String
            let status = errorType == "overloaded_error" ? 529 : 500
            throw APIError.http(provider: "Anthropic", statusCode: status, body: Data(sse.data.utf8))
        default:
            break
        }
        return []
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        stopped ? [] : [.done(finishReason: stopReason)]
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter AnthropicStreamMapperTests 2>&1 | tail -8`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/AnthropicStreamMapper.swift Tests/irisTests/AnthropicStreamMapperTests.swift
git commit -m "feat(stream): Anthropic SSE mapper with buffered tool_use input

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: OpenAI stream mapper

**Files:**
- Create: `Sources/iris/OpenAIStreamMapper.swift`
- Test: `Tests/irisTests/OpenAIStreamMapperTests.swift`

**Interfaces:**
- Produces: `struct OpenAIStreamMapper: StreamMapper`.

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -3`
Expected: `cannot find 'OpenAIStreamMapper' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// OpenAI Chat Completions streaming (`"stream": true` + `stream_options.include_usage`).
/// `delta.content` streams; `delta.tool_calls[]` fragments accumulate per `index` and are
/// emitted in index order when the stream ends (`[DONE]` or end of input); the choices-less
/// usage chunk maps to `usage`; `reasoning_content` is kept as the thought signature so the
/// streamed turn round-trips like the non-streaming decoder's.
struct OpenAIStreamMapper: StreamMapper {
    private struct Call { var id: String?; var name: String?; var arguments = "" }
    private var calls: [Int: Call] = [:]
    private var finishReason: String?
    private var reasoning = ""
    private var ended = false

    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent] {
        let payload = sse.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            ended = true
            return try endEvents()
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return [] }
        var out: [LLMStreamEvent] = []
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty { out.append(.textDelta(text)) }
                if let r = delta["reasoning_content"] as? String { reasoning += r }
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = fragment["index"] as? Int ?? 0
                    var call = calls[index] ?? Call()
                    if let id = fragment["id"] as? String { call.id = id }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String { call.name = name }
                        if let arguments = function["arguments"] as? String { call.arguments += arguments }
                    }
                    calls[index] = call
                }
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        if let usage = json["usage"] as? [String: Any] {
            out.append(.usage(UsageMetadata(promptTokenCount: usage["prompt_tokens"] as? Int,
                                            candidatesTokenCount: usage["completion_tokens"] as? Int,
                                            totalTokenCount: usage["total_tokens"] as? Int)))
        }
        return out
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        ended ? [] : try endEvents()
    }

    private mutating func endEvents() throws -> [LLMStreamEvent] {
        var out: [LLMStreamEvent] = []
        let signature = reasoning.isEmpty ? nil : reasoning
        for index in calls.keys.sorted() {
            guard let call = calls[index], let name = call.name else { continue }
            let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let args = try JSONDecoder().decode([String: JSONValue].self, from: Data((raw.isEmpty ? "{}" : raw).utf8))
            out.append(.functionCall(FunctionCall(name: name, args: args, id: call.id ?? "call_\(name)_\(index)",
                                                  thought_signature: signature, thoughtSignature: signature)))
        }
        calls = [:]
        if let signature { out.append(.thoughtSignature(signature)) }
        out.append(.done(finishReason: finishReason))
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OpenAIStreamMapperTests 2>&1 | tail -8`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/OpenAIStreamMapper.swift Tests/irisTests/OpenAIStreamMapperTests.swift
git commit -m "feat(stream): OpenAI chunk mapper with per-index tool-call accumulation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Native streaming in the three clients

**Files:**
- Modify: `Sources/iris/LLMStream.swift` (add `LLMStreaming.stream`), `Sources/iris/LLMClient.swift`, `Sources/iris/AnthropicClient.swift`, `Sources/iris/OpenAIClient.swift`
- Test: `Tests/irisTests/StreamingClientTests.swift`

**Interfaces:**
- Consumes: mappers (Tasks 2-4), `SSEParser`, `StreamMapper`.
- Produces:
  - `enum LLMStreaming { static func stream<M: StreamMapper>(provider: String, mapper: M, makeRequest: @escaping @Sendable () async throws -> URLRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> }`
  - `LLMClient.resolveGeminiRequestURL(modelName:isADC:customBaseURL:quotaProject:streaming:)` with `streaming: Bool = false`
  - `LLMClient.makeGeminiURLRequest(request:modelName:streaming:) async throws -> URLRequest`
  - `AnthropicClient.makeURLRequest(request:model:apiKey:baseURL:stream:) throws -> URLRequest`, `AnthropicClient.streamContent(request:model:apiKey:baseURL:)`
  - `OpenAIClient.makeURLRequest(request:model:apiKey:baseURL:stream:) throws -> URLRequest`, `OpenAIClient.streamContent(request:model:apiKey:baseURL:)`
  - `LLMClient.streamContent(request:tier:)` (dispatches by provider) and `LLMClient.supportsStreaming == true`.

- [ ] **Step 1: Write the failing tests**

`MockURLProtocol` (in `Tests/irisTests/MockURLProtocol.swift`) is a process-global handler; the suite is `.serialized` and registers/unregisters per test. `URLSession.shared.bytes(for:)` goes through registered `URLProtocol` classes just like `data(for:)`.

```swift
import Testing
import Foundation
@testable import iris

/// The streaming request shapes and the URLSession → SSE → mapper pump, against a mocked transport.
@Suite("Streaming clients", .serialized)
struct StreamingClientTests {
    private func withMock<T>(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data), _ body: () async throws -> T) async rethrows -> T {
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = handler
        defer { MockURLProtocol.handler = nil; URLProtocol.unregisterClass(MockURLProtocol.self) }
        return try await body()
    }

    private func ok(_ url: URL, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(body.utf8))
    }

    private var request: GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
    }

    @Test("the Gemini streaming URL swaps the method and asks for SSE, on both endpoint forms")
    func geminiStreamingURL() throws {
        let direct = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: false, customBaseURL: "", quotaProject: nil, streaming: true)
        #expect(direct.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:streamGenerateContent?alt=sse")
        let vertex = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: true, customBaseURL: "", quotaProject: "proj", streaming: true)
        #expect(vertex.absoluteString == "https://aiplatform.googleapis.com/v1/projects/proj/locations/global/publishers/google/models/gemini-x:streamGenerateContent?alt=sse")
        let plain = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: false, customBaseURL: "", quotaProject: nil)
        #expect(plain.absoluteString.hasSuffix(":generateContent"))
    }

    @Test("Anthropic: stream flag in the body, events mapped end to end, non-streaming body unchanged")
    func anthropicStream() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let events: [LLMStreamEvent] = try await withMock({ req in
            let body = try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["stream"] as? Bool == true)
            #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
            return self.ok(req.url!, body: sse)
        }) {
            var got: [LLMStreamEvent] = []
            for try await e in AnthropicClient.streamContent(request: request, model: "claude-x", apiKey: "k") { got.append(e) }
            return got
        }
        #expect(events == [
            .usage(UsageMetadata(promptTokenCount: 12, candidatesTokenCount: nil, totalTokenCount: nil)),
            .textDelta("Hel"), .textDelta("lo"),
            .usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 5, totalTokenCount: nil)),
            .done(finishReason: "end_turn")
        ])
        let plain = try AnthropicClient.makeURLRequest(request: request, model: "claude-x", apiKey: "k", baseURL: "", stream: false)
        let plainBody = try JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any]
        #expect(plainBody?["stream"] == nil)
    }

    @Test("OpenAI: stream and stream_options in the body, chunks mapped end to end")
    func openAIStream() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}

        data: [DONE]

        """
        let events: [LLMStreamEvent] = try await withMock({ req in
            let body = try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["stream"] as? Bool == true)
            #expect((body?["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
            return self.ok(req.url!, body: sse)
        }) {
            var got: [LLMStreamEvent] = []
            for try await e in OpenAIClient.streamContent(request: request, model: "gpt-x", apiKey: "k") { got.append(e) }
            return got
        }
        #expect(events == [.textDelta("Hi"),
                           .usage(UsageMetadata(promptTokenCount: 3, candidatesTokenCount: 1, totalTokenCount: 4)),
                           .done(finishReason: "stop")])
    }

    @Test("a non-2xx response is read to the end and thrown as the same APIError as a plain call")
    func httpErrorThrows() async throws {
        let body = #"{"error":{"type":"rate_limit_error","message":"Too many"}}"#
        let thrown: Error? = await withMock({ req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7"])!, Data(body.utf8))
        }) {
            do {
                for try await _ in AnthropicClient.streamContent(request: request, model: "claude-x", apiKey: "k") {}
                return nil
            } catch { return error }
        }
        let api = try #require(thrown as? APIError)
        #expect(api.statusCode == 429)
        #expect(api.retryAfter == 7)
        #expect(api.message == "Anthropic HTTP 429 rate_limit_error: Too many")
    }

    @Test("an empty API key fails before any request, as the plain call does")
    func emptyKey() async {
        var thrown: Error?
        do { for try await _ in OpenAIClient.streamContent(request: request, model: "m", apiKey: "") {} } catch { thrown = error }
        #expect((thrown as? URLError)?.code == .userAuthenticationRequired)
    }

    @Test("the production client advertises native streaming")
    func nativeFlag() {
        #expect(LLMClient().supportsStreaming == true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -5`
Expected: errors naming `streamContent`, `makeURLRequest`, `streaming:` argument.

- [ ] **Step 3: Add the shared pump to `LLMStream.swift`**

Append:

```swift
/// The URLSession → SSE → mapper pump every provider client shares (spec §2.1). Non-2xx is
/// read to completion and thrown through `APIError.http`, so a 429 mid-handshake is the same
/// error, with the same `Retry-After`, as on a plain call. Cancelling the consumer cancels the
/// task and with it the URLSession transfer.
enum LLMStreaming {
    static func stream<M: StreamMapper>(provider: String, mapper: M,
                                        makeRequest: @escaping @Sendable () async throws -> URLRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try await makeRequest()
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        print("API Error (\(http.statusCode)): \(String(data: body, encoding: .utf8) ?? "<non-utf8 body>")")
                        throw APIError.http(provider: provider, statusCode: http.statusCode, body: body, headers: http.allHeaderFields)
                    }
                    var mapper = mapper
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        guard let sse = parser.feed(line) else { continue }
                        for event in try mapper.handle(sse) { continuation.yield(event) }
                    }
                    if let sse = parser.finish() {
                        for event in try mapper.handle(sse) { continuation.yield(event) }
                    }
                    for event in try mapper.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Anthropic: extract the request builder, add `streamContent`**

In `AnthropicClient.swift`, move everything in `generateContent` from the `guard !apiKey.isEmpty` through `LLMRequestPolicy.apply(to: &urlRequest)` into:

```swift
    /// The full request for one call. `stream` adds the provider's streaming switch and nothing else.
    static func makeURLRequest(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "", stream: Bool) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw URLError(.userAuthenticationRequired) }
        // ... the existing message/tool translation and body construction, verbatim ...
        if stream { body["stream"] = true }
        // ... the existing endpoint resolution and header setup, verbatim ...
        LLMRequestPolicy.apply(to: &urlRequest)
        return urlRequest
    }
```

`generateContent` becomes: `var urlRequest = try makeURLRequest(request: request, model: model, apiKey: apiKey, baseURL: baseURL, stream: false)` followed by the unchanged `URLSession.shared.data(for:)`, status check and decode. Then add:

```swift
    static func streamContent(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "") -> AsyncThrowingStream<LLMStreamEvent, Error> {
        LLMStreaming.stream(provider: "Anthropic", mapper: AnthropicStreamMapper()) {
            try makeURLRequest(request: request, model: model, apiKey: apiKey, baseURL: baseURL, stream: true)
        }
    }
```

- [ ] **Step 5: OpenAI: the same extraction**

Same shape in `OpenAIClient.swift`; the streaming additions inside `makeURLRequest` are:

```swift
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
```

and `streamContent` uses `provider: "OpenAI", mapper: OpenAIStreamMapper()`.

- [ ] **Step 6: Gemini: URL form, request builder, dispatch, native flag**

In `LLMClient.swift`:

1. `resolveGeminiRequestURL` gains `streaming: Bool = false`. Let `let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"` and use `:\(method)` in both built URL strings. For a non-empty `customBaseURL`, when `streaming` and the string has suffix `:generateContent`, replace that suffix with `:streamGenerateContent?alt=sse`; otherwise use it as given.
2. Extract from `generateContent`'s Gemini branch (from `let isADC` through `urlRequest.httpBody = requestData` and `LLMRequestPolicy.apply`) into `func makeGeminiURLRequest(request: GeminiRequest, modelName: String, streaming: Bool) async throws -> URLRequest`, passing `streaming:` to `resolveGeminiRequestURL`. The API-key query item is appended with `URLComponents` as today, so `alt=sse` and `key=` coexist. `generateContent` calls it with `streaming: false`.
3. Add:

```swift
    var supportsStreaming: Bool { true }

    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let config = ConfigManager.shared
        let provider = config.primaryProvider
        let modelName = config.getModel(for: tier)
        let metricOp: MetricOperationType
        switch tier {
        case .easy: metricOp = .easy
        case .medium: metricOp = .medium
        case .hard: metricOp = .hard
        }
        let inner: AsyncThrowingStream<LLMStreamEvent, Error>
        if provider == LLMProvider.anthropic.rawValue {
            inner = AnthropicClient.streamContent(request: request, model: modelName, apiKey: config.anthropicAPIKey, baseURL: config.anthropicBaseURL)
        } else if provider == LLMProvider.openai.rawValue {
            inner = OpenAIClient.streamContent(request: request, model: modelName, apiKey: config.openAIAPIKey, baseURL: config.openAIBaseURL)
        } else {
            let isADC = config.geminiAuthMode == GeminiAuthMode.adc.rawValue
            if !isADC && config.geminiAPIKey.isEmpty {
                return AsyncThrowingStream { $0.finish(throwing: APIError(message: "GEMINI_FALLBACK_AUTH_ERROR_1013")) }
            }
            inner = LLMStreaming.stream(provider: "Gemini", mapper: GeminiStreamMapper()) {
                try await self.makeGeminiURLRequest(request: request, modelName: modelName, streaming: true)
            }
        }
        // Provider latency metrics, as the plain call records them.
        let start = CFAbsoluteTimeGetCurrent()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var succeeded = true
                do {
                    for try await event in inner { continuation.yield(event) }
                } catch {
                    succeeded = false
                    continuation.finish(throwing: error)
                }
                await MetricsManager.shared.trackLatency(operation: metricOp, modelName: modelName,
                                                         durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0, success: succeeded)
                if succeeded { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

- [ ] **Step 7: Run to verify pass, and that the non-streaming client tests still pass**

Run: `swift test --filter "StreamingClientTests|AnthropicClientTests|OpenAIClientTests|LLMClientTests" 2>&1 | tail -12`
Expected: all pass; the XCTest client suites are unaffected by the extraction.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/LLMStream.swift Sources/iris/LLMClient.swift Sources/iris/AnthropicClient.swift Sources/iris/OpenAIClient.swift Tests/irisTests/StreamingClientTests.swift
git commit -m "feat(stream): native SSE streaming for Gemini, Anthropic and OpenAI clients

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `StreamInterruptedError` and its display

**Files:**
- Modify: `Sources/iris/LLMError.swift`, `Sources/iris/LLMErrorMessage.swift:17-22`
- Test: extend `Tests/irisTests/LLMRetryTests.swift` and `Tests/irisTests/LLMErrorMessageTests.swift` (Edit tool, append tests inside the existing suites)

**Interfaces:**
- Produces: `struct StreamInterruptedError: Error, Sendable { let underlying: any Error }`; `LLMErrorMessage.display(for:)` unwraps it with the headline prefixed `Response interrupted: `.

- [ ] **Step 1: Write the failing tests**

Append to the suite in `LLMRetryTests.swift`:

```swift
    @Test("an interruption after partial output is never retried, even when it wraps a retryable status")
    func interruptedIsNotRetried() async {
        let counter = Counter()
        let wrapped = StreamInterruptedError(underlying: APIError(message: "overloaded", statusCode: 529))
        var thrown: Error?
        do {
            _ = try await LLMRetry.run(delays: [0, 0]) { () -> Int in
                await counter.increment()
                throw wrapped
            }
        } catch { thrown = error }
        #expect(thrown is StreamInterruptedError)
        #expect(await counter.value == 1)
    }
```

Use whatever attempt-counting helper the file already has; if it has none, add a small `actor Counter { var value = 0; func increment() { value += 1 } }` at file scope.

Append to `LLMErrorMessageTests.swift`:

```swift
    @Test("an interrupted stream shows the underlying provider error under an interruption headline")
    func interruptedDisplay() {
        let inner = APIError.http(provider: "Anthropic", statusCode: 529,
                                  body: Data(#"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        let display = LLMErrorMessage.display(for: StreamInterruptedError(underlying: inner))
        #expect(display.headline == "Response interrupted: Anthropic HTTP 529 overloaded_error: Overloaded")
        #expect(display.detail == inner.detail)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -3`
Expected: `cannot find 'StreamInterruptedError' in scope`.

- [ ] **Step 3: Implement**

Append to `LLMError.swift`:

```swift
/// A model stream that failed after the user had already seen part of the reply. `LLMRetry`
/// retries only `APIError`/transport errors, so wrapping is what stops a retry that would
/// duplicate or delete text already on screen (spec §4.4). The engine keeps the partial message
/// and shows the underlying error after it.
struct StreamInterruptedError: Error, Sendable {
    let underlying: any Error
}
```

In `LLMErrorMessage.display(for:)`, before the `APIError` check:

```swift
        if let interrupted = error as? StreamInterruptedError {
            let inner = display(for: interrupted.underlying)
            return LLMErrorDisplay(headline: "Response interrupted: " + inner.headline, detail: inner.detail)
        }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "LLMRetryTests|LLMErrorMessageTests" 2>&1 | tail -6`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/LLMError.swift Sources/iris/LLMErrorMessage.swift Tests/irisTests/LLMRetryTests.swift Tests/irisTests/LLMErrorMessageTests.swift
git commit -m "feat(stream): StreamInterruptedError is shown, never retried

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: In-place message updates and the coalescing streamer

**Files:**
- Modify: `Sources/iris/AppState.swift:12-35` (`ChatMessage.content` to `var`), add `updateMessageContent` next to `appendMessage`
- Create: `Sources/iris/MessageStreamer.swift`
- Test: `Tests/irisTests/MessageStreamerTests.swift`

**Interfaces:**
- Produces:
  - `AppState.updateMessageContent(id: UUID, content: String, in conversationId: UUID, persist: Bool = false)`
  - `actor MessageStreamer` with `typealias Open = @Sendable (UUID, String) async -> Void`, `typealias Update = @Sendable (UUID, String, Bool) async -> Void`, `typealias Sleep = @Sendable (UInt64) async -> Void`; `static let flushIntervalMs: UInt64 = 50`; `let messageId: UUID`; `init(open:update:sleep:)`; `func append(_ delta: String) async`; `func finish(_ finalText: String) async`; `func settle() async -> String`; `var text: String`; `var opened: Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import iris

/// Releases `sleep` callers on demand so a flush window is deterministic.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
    var waiting: Int { waiters.count }
}

private actor Recorder {
    var opens: [(UUID, String)] = []
    var updates: [(UUID, String, Bool)] = []
    func open(_ id: UUID, _ text: String) { opens.append((id, text)) }
    func update(_ id: UUID, _ text: String, _ final: Bool) { updates.append((id, text, final)) }
}

private func eventually(_ timeoutMs: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@Suite("Message streamer")
struct MessageStreamerTests {
    private func make(_ recorder: Recorder, gate: Gate) -> MessageStreamer {
        MessageStreamer(open: { await recorder.open($0, $1) },
                        update: { await recorder.update($0, $1, $2) },
                        sleep: { _ in await gate.wait() })
    }

    @Test("the row opens with the first delta; later deltas coalesce into one update per window; finish writes once and persists")
    func coalescing() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.append("Hel")
        #expect(await recorder.opens.map(\.1) == ["Hel"])
        await s.append("lo")
        await s.append(" wor")
        #expect(await eventually { await gate.waiting == 1 })
        #expect(await recorder.updates.isEmpty)
        await gate.release()
        #expect(await eventually { await recorder.updates.count == 1 })
        #expect(await recorder.updates.first?.1 == "Hello wor")
        #expect(await recorder.updates.first?.2 == false)
        await s.finish("Hello world!")
        let updates = await recorder.updates
        #expect(updates.count == 2)
        #expect(updates.last?.1 == "Hello world!" && updates.last?.2 == true)
        #expect(await recorder.opens.count == 1)
        #expect(await recorder.opens.first?.0 == s.messageId)
    }

    @Test("a replayed call opens and finalizes in one go")
    func replayPath() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.finish("whole reply")
        #expect(await recorder.opens.map(\.1) == ["whole reply"])
        #expect(await recorder.updates.map(\.1) == ["whole reply"])
        #expect(await recorder.updates.map(\.2) == [true])
    }

    @Test("finishing with nothing to show opens no row")
    func emptyFinish() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.finish("")
        #expect(await recorder.opens.isEmpty && recorder.updates.isEmpty)
    }

    @Test("settle returns what was shown and finalizes it; a pending flush no longer fires")
    func settle() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.append("par")
        await s.append("tial")
        let shown = await s.settle()
        #expect(shown == "partial")
        #expect(await recorder.updates.last?.1 == "partial" && recorder.updates.last?.2 == true)
        let before = await recorder.updates.count
        await gate.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.updates.count == before)
    }

    @Test("the flush interval is 50 ms")
    func interval() {
        #expect(MessageStreamer.flushIntervalMs == 50)
    }
}

@MainActor
@Suite("AppState in-place message update")
struct UpdateMessageContentTests {
    @Test("content is replaced without adding a message; persist is opt-in")
    func updateInPlace() {
        let app = AppState()
        let conv = UUID()
        app.createNewConversation(id: conv)
        let id = UUID()
        app.appendMessage(role: .agent, content: "a", id: id, to: conv)
        let count = app.conversations.first { $0.id == conv }!.messages.count
        app.updateMessageContent(id: id, content: "ab", in: conv)
        let messages = app.conversations.first { $0.id == conv }!.messages
        #expect(messages.count == count)
        #expect(messages.first { $0.id == id }?.content == "ab")
        #expect(messages.first { $0.id == id }?.role == .agent)
    }

    @Test("an unknown message id is a no-op")
    func unknownId() {
        let app = AppState()
        let conv = UUID()
        app.createNewConversation(id: conv)
        let before = app.conversations.first { $0.id == conv }!.messages
        app.updateMessageContent(id: UUID(), content: "x", in: conv)
        #expect(app.conversations.first { $0.id == conv }!.messages.map(\.content) == before.map(\.content))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -3`
Expected: `cannot find 'MessageStreamer' in scope`, `value of type 'AppState' has no member 'updateMessageContent'`.

- [ ] **Step 3: Implement**

In `AppState.swift` change `let content: String` in `ChatMessage` to `var content: String` (the custom `init(from:)` and memberwise init are unchanged). After `appendMessage(role:content:attachments:id:to:)` add:

```swift
    /// Replaces one message's content in place (a streamed reply growing). No title generation;
    /// the caller asks for a save only when the message is final.
    func updateMessageContent(id: UUID, content: String, in conversationId: UUID, persist: Bool = false) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationId }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[c].messages[m].content = content
        if persist { saveConversations() }
    }
```

Create `Sources/iris/MessageStreamer.swift`:

```swift
import Foundation

/// Grows one agent message in place as text deltas arrive, coalescing UI writes to at most one
/// per `flushIntervalMs` (spec §5.2). One instance per model round; it mints the message id,
/// opens the row on the first delta, and writes the final text exactly once.
actor MessageStreamer {
    typealias Open = @Sendable (UUID, String) async -> Void
    /// (message id, whole text so far, isFinal). `isFinal` is the caller's cue to persist.
    typealias Update = @Sendable (UUID, String, Bool) async -> Void
    typealias Sleep = @Sendable (UInt64) async -> Void

    /// 20 writes per second: well under what MarkdownUI re-parses comfortably for a few-KB
    /// message, above the rate at which any provider produces visually distinct chunks.
    static let flushIntervalMs: UInt64 = 50

    let messageId = UUID()
    private(set) var text = ""
    private(set) var opened = false
    private var lastSent = ""
    private var flushTask: Task<Void, Never>?
    private let open: Open
    private let update: Update
    private let sleep: Sleep

    init(open: @escaping Open, update: @escaping Update,
         sleep: @escaping Sleep = { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) }) {
        self.open = open
        self.update = update
        self.sleep = sleep
    }

    func append(_ delta: String) async {
        guard !delta.isEmpty else { return }
        text += delta
        if !opened {
            opened = true
            lastSent = text
            await open(messageId, text)
            return
        }
        if flushTask == nil {
            flushTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(Self.flushIntervalMs)
                await self.flush()
            }
        }
    }

    private func flush() async {
        flushTask = nil
        guard text != lastSent else { return }
        lastSent = text
        await update(messageId, text, false)
    }

    /// Writes the final content once and asks for it to be persisted. Opens the row first when
    /// nothing streamed (a replayed call delivers its whole text here).
    func finish(_ finalText: String) async {
        flushTask?.cancel()
        flushTask = nil
        text = finalText
        if !opened {
            guard !finalText.isEmpty else { return }
            opened = true
            await open(messageId, finalText)
        }
        lastSent = finalText
        await update(messageId, finalText, true)
    }

    /// Ends the stream with whatever has been shown (error, hook block, Stop) and returns it.
    func settle() async -> String {
        let shown = text
        if opened { await finish(shown) }
        return shown
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "MessageStreamerTests|UpdateMessageContentTests|MessageGroupingTests" 2>&1 | tail -10`
Expected: pass (the grouping tests confirm the `var` change broke nothing).

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/MessageStreamer.swift Tests/irisTests/MessageStreamerTests.swift
git commit -m "feat(stream): in-place message updates with a 50 ms coalescing streamer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Setting and perf record fields

**Files:**
- Modify: `Sources/iris/ConfigManager.swift` (property near line 32, init near line 217), `Sources/iris/SettingsView.swift:45-47`, `Sources/iris/PerformanceProfiler.swift:44-58`, `Sources/iris/PerfRecord.swift:77-98,147-161`, `Sources/iris/PerfEnvironment+Capture.swift`, `Sources/iris/PerfRunner.swift` (`PerfSummarizer.summarize`), `Sources/iris/PerfReport.swift`, `perf/README.md`
- Test: extend `Tests/irisTests/PerfRecordTests.swift`, `PerfReportTests.swift`, `PerfCompareTests.swift` (Edit tool)

**Interfaces:**
- Produces: `ConfigManager.streamResponses: Bool` (key `STREAM_RESPONSES`, default `true`); `ModelCallRecord.firstTokenMs: Double?` (init parameter `firstTokenMs: Double? = nil`); `PerfEnvironment.streaming: Bool?`; `PerfEnvironment.capture(headless:toolDeclarationCount:repoRoot:toolSandbox:)` records `streaming: ConfigManager.shared.streamResponses`; `PerfScenarioSummary.medianFirstTokenMs: Double?`; report column `first token ms` and header line `- streaming: on|off`.

- [ ] **Step 1: Write the failing tests**

In `PerfRecordTests.swift`, inside the existing suite:

```swift
    @Test("a model call record without firstTokenMs decodes with nil; one with it round-trips")
    func firstTokenMsOptional() throws {
        let legacy = Data(#"{"round":0,"model":"m","latencyMs":10,"returnedToolCalls":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ModelCallRecord.self, from: legacy)
        #expect(decoded.firstTokenMs == nil)
        let rec = ModelCallRecord(round: 1, model: "m", latencyMs: 20, promptTokens: nil, outputTokens: nil, returnedToolCalls: false, firstTokenMs: 3.5)
        let round = try JSONDecoder().decode(ModelCallRecord.self, from: JSONEncoder().encode(rec))
        #expect(round.firstTokenMs == 3.5)
    }
```

In `PerfReportTests.swift`: update the existing header expectation to `| rung | n | median ms | p90 ms | first token ms | prompt tokens | failed |` and add:

```swift
    @Test("the first-token column is the median over the rung's successful turns, or a dash")
    func firstTokenColumn() throws {
        // Build the smallest record the file's existing helpers allow, with one rung whose two
        // repetitions carry modelCalls with firstTokenMs 100 and 300, and one rung with none.
        // Assert the rendered rows contain "| 200 |" for the first and "| - |" for the second,
        // and that the header block contains "- streaming: on" when environment.streaming == true.
    }
```

Fill the body with the record-building helper already used in that file (it constructs `PerfRunRecord` values; reuse it rather than adding a second builder). The expectations are exactly the three `#expect` lines described in the comment.

In `PerfCompareTests.swift`:

```swift
    @Test("a streaming flag mismatch is not a refusal")
    func streamingMismatchCompares() {
        // Take the file's baseline/current pair helper, set baseline.environment.streaming = nil
        // and current.environment.streaming = true, and assert PerfCompare.compare(...).refusal == nil.
    }
```

Again fill the body with the file's existing pair helper; the assertion is `#expect(comparison.refusal == nil)`.

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep "error:" | head -3`
Expected: `extra argument 'firstTokenMs' in call`, `value of type 'PerfEnvironment' has no member 'streaming'`.

- [ ] **Step 3: Implement**

`ConfigManager.swift`, next to `copyChatsAsMarkdown`:

```swift
    /// Show the reply while the model is still writing it (spec §7). Off means whole replies,
    /// the pre-streaming behaviour.
    var streamResponses: Bool {
        didSet { ConfigManager.store.set(streamResponses, forKey: "STREAM_RESPONSES") }
    }
```

and in `init`, next to the `COPY_CHATS_AS_MARKDOWN` block:

```swift
        if ConfigManager.store.object(forKey: "STREAM_RESPONSES") != nil {
            self.streamResponses = ConfigManager.store.bool(forKey: "STREAM_RESPONSES")
        } else {
            self.streamResponses = true
        }
```

`SettingsView.swift`, in the Preferences section after the copy-as-Markdown toggle:

```swift
                    Toggle("Stream responses as they are generated", isOn: $config.streamResponses)
                        .help("Show Iris's reply while the model is still writing it. Turn off to receive whole replies.")
```

`PerformanceProfiler.swift`, `ModelCallRecord`:

```swift
    /// ms from request start to the first text delta or function call. Set only for native
    /// streams; nil for replayed calls, calls that produced nothing, and records older than #131.
    public var firstTokenMs: Double? = nil

    public init(round: Int, model: String, latencyMs: Double, promptTokens: Int?, outputTokens: Int?, returnedToolCalls: Bool, firstTokenMs: Double? = nil) {
        self.round = round; self.model = model; self.latencyMs = latencyMs
        self.promptTokens = promptTokens; self.outputTokens = outputTokens; self.returnedToolCalls = returnedToolCalls
        self.firstTokenMs = firstTokenMs
    }
```

`PerfRecord.swift`: `PerfEnvironment` gains `var streaming: Bool? = nil` after `toolSandbox` with the comment `/// Whether rungs 4-5 streamed. Informational: compare does not refuse on a mismatch.`; `PerfScenarioSummary` gains `var medianFirstTokenMs: Double? = nil` with `/// Median firstTokenMs over the top rung's successful turns; nil when nothing streamed.`

`PerfEnvironment+Capture.swift`: pass `streaming: config.streamResponses` in the initializer call.

`PerfSummarizer.summarize` (in `PerfRunner.swift`): after `fullTurns` is computed add

```swift
        let firstTokens = fullTurns.flatMap(\.modelCalls).compactMap(\.firstTokenMs)
```

and pass `medianFirstTokenMs: PerfStats.median(firstTokens)` in the returned summary.

`PerfReport.swift`: header line `if let streaming = env.streaming { out.append("- streaming: \(streaming ? "on" : "off")") }` after the guards line; table header and separator gain the `first token ms` column between `p90 ms` and `prompt tokens` (seven columns); each row computes

```swift
                let firstToken = PerfStats.median(ok.flatMap { rep in (rep.modelCalls + rep.turns.flatMap(\.modelCalls)).compactMap(\.firstTokenMs) })
```

and renders `\(firstToken.map { String(Int($0)) } ?? "-")` in that position.

`perf/README.md`: under the section that explains the ladder columns, add two sentences: `first token ms` is the median time from request start to the first streamed token for rungs that streamed (4 and 5 when the streaming setting is on); it is `-` for the bare-call rungs and for fake-lane runs, whose clients replay whole responses. The header line `streaming:` records the setting; compare does not refuse across it because total wall time is comparable either way.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "PerfRecordTests|PerfReportTests|PerfCompareTests|PerfRunnerTests" 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/ConfigManager.swift Sources/iris/SettingsView.swift Sources/iris/PerformanceProfiler.swift Sources/iris/PerfRecord.swift Sources/iris/PerfEnvironment+Capture.swift Sources/iris/PerfRunner.swift Sources/iris/PerfReport.swift perf/README.md Tests/irisTests/PerfRecordTests.swift Tests/irisTests/PerfReportTests.swift Tests/irisTests/PerfCompareTests.swift
git commit -m "feat(perf): streamResponses setting, firstTokenMs on model calls, first-token column

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Engine integration

**Files:**
- Modify: `Sources/iris/iris.swift` (the model-call seam near lines 686-716, the text-part loop near 757-767, the block/empty `break`s near 722-740, the `catch` near 890-912; new helper methods next to `pushToUI`), `docs/tool_hooks.md`
- Test: `Tests/irisTests/StreamingEngineTests.swift`

**Interfaces:**
- Consumes: `LLMStreamEvent`, `StreamAssembler`, `LLMStreamEvent.replay`, `MessageStreamer`, `StreamInterruptedError`, `ConfigManager.streamResponses`, `ModelCallRecord(firstTokenMs:)`, `AppState.updateMessageContent`.
- Produces (engine-internal): `struct StreamOutcome { let response: GeminiResponse; let firstTokenMs: Double? }`; `func consumeModelStream(request:streamed:streamer:) async throws -> StreamOutcome`; `func makeStreamer(conversationId:) -> MessageStreamer`; `func updateStreamedMessage(id:content:isFinal:conversationId:) async`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import iris

/// A client that plays scripted stream events, one script per call.
final class ScriptedStreamClient: LLMClientProtocol, @unchecked Sendable {
    enum Step: Sendable {
        case event(LLMStreamEvent)
        case fail(any Error)
        /// Never ends on its own; the consumer's cancellation ends it.
        case hang
    }
    private let lock = NSLock()
    private var scripts: [[Step]]
    private(set) var calls = 0
    init(_ scripts: [[Step]]) { self.scripts = scripts }
    var supportsStreaming: Bool { true }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        throw APIError(message: "ScriptedStreamClient only streams")
    }
    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let script: [Step] = lock.withLock {
            calls += 1
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in script {
                        switch step {
                        case .event(let e): continuation.yield(e)
                        case .fail(let error): throw error
                        case .hang: try await Task.sleep(nanoseconds: 60_000_000_000)
                        }
                        await Task.yield()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
@Suite("IrisEngine streaming")
struct StreamingEngineTests {
    private func session(_ client: any LLMClientProtocol, retryDelays: [TimeInterval] = []) -> (AppState, IrisEngine, UUID) {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: retryDelays)
        return (app, engine, id)
    }
    private func conv(_ app: AppState, _ id: UUID) -> Conversation { app.conversations.first { $0.id == id }! }
    private func agentTexts(_ app: AppState, _ id: UUID) -> [String] { conv(app, id).messages.filter { $0.role == .agent }.map(\.content) }
    private func errorPills(_ app: AppState, _ id: UUID) -> [LLMErrorDisplay] { conv(app, id).messages.compactMap { LLMErrorMessage.parse($0.content) } }
    private var overloaded: APIError { APIError.http(provider: "Gemini", statusCode: 503, body: Data(#"{"error":{"message":"busy","status":"UNAVAILABLE"}}"#.utf8)) }

    @Test("a streamed text turn ends as one agent message, one model history turn, usage counted")
    func streamedText() async {
        let client = ScriptedStreamClient([[.event(.textDelta("Hel")), .event(.textDelta("lo")),
                                            .event(.usage(UsageMetadata(promptTokenCount: 5, candidatesTokenCount: 2, totalTokenCount: 7))),
                                            .event(.done(finishReason: "STOP"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(agentTexts(app, id) == ["Hello"])
        let history = conv(app, id).history
        #expect(history.last?.role == "model")
        #expect(history.last?.parts.first?.text == "Hello")
        #expect(conv(app, id).tokenUsage.candidatesTokenCount == 2)
        #expect(errorPills(app, id).isEmpty)
    }

    @Test("firstTokenMs is recorded for a native stream and nil for a replayed client")
    func firstTokenRecorded() async throws {
        let scenario = Scenario(name: "s", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")],
                                scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "Hello", calls: nil)])
        let native = ScriptedStreamClient([[.event(.textDelta("Hello")), .event(.done(finishReason: nil))]])
        let streamed = await ScenarioRunner.run(scenario, clientOverride: native)
        let call = try #require(streamed.turnProfiles.first?.modelCalls.first)
        #expect(call.firstTokenMs != nil)
        #expect(call.firstTokenMs! >= 0 && call.firstTokenMs! <= call.latencyMs + 1)

        let replayed = await ScenarioRunner.run(scenario)   // FakeLLMClient: supportsStreaming == false
        #expect(replayed.turnProfiles.first?.modelCalls.first?.firstTokenMs == nil)
        #expect(replayed.finalTexts == streamed.finalTexts)
    }

    @Test("a streamed tool call dispatches once with its parsed arguments and the loop continues")
    func streamedToolCall() async {
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo streamed")], id: "c1")
        let client = ScriptedStreamClient([[.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))],
                                           [.event(.textDelta("done")), .event(.done(finishReason: "STOP"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("run it", source: "User", conversationId: id)
        #expect(client.calls == 2)
        #expect(agentTexts(app, id) == ["done"])
        let toolCalls = conv(app, id).messages.filter { $0.content.hasPrefix("[TOOL_CALL]") }
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.content.contains("echo streamed") == true)
    }

    @Test("a failure after the first delta keeps the partial text, shows the error after it, is not retried, and reaches history")
    func midStreamFailure() async throws {
        let client = ScriptedStreamClient([[.event(.textDelta("partial ")), .fail(overloaded)],
                                           [.event(.textDelta("never")), .event(.done(finishReason: nil))]])
        let (app, engine, id) = session(client, retryDelays: [0.01, 0.01])
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(client.calls == 1)
        #expect(agentTexts(app, id) == ["partial "])
        let pill = try #require(errorPills(app, id).first)
        #expect(pill.headline.hasPrefix("Response interrupted: Gemini HTTP 503"))
        let messages = conv(app, id).messages
        let agentIndex = messages.firstIndex { $0.role == .agent }!
        let pillIndex = messages.firstIndex { LLMErrorMessage.parse($0.content) != nil }!
        #expect(agentIndex < pillIndex)
        #expect(conv(app, id).history.last?.parts.first?.text == "partial ")
        #expect(!conv(app, id).messages.contains { $0.content.hasPrefix("[retry]") })
    }

    @Test("a failure before the first delta retries as before and leaves no partial row")
    func preDeltaRetry() async {
        let client = ScriptedStreamClient([[.fail(overloaded)],
                                           [.event(.textDelta("ok")), .event(.done(finishReason: nil))]])
        let (app, engine, id) = session(client, retryDelays: [0.01])
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(client.calls == 2)
        #expect(agentTexts(app, id) == ["ok"])
        #expect(conv(app, id).messages.contains { $0.content.hasPrefix("[retry]") })
        #expect(errorPills(app, id).isEmpty)
    }

    @Test("Stop mid-stream keeps the partial text, posts no error pill, and commits the partial text to history")
    func cancellation() async {
        let client = ScriptedStreamClient([[.event(.textDelta("part")), .hang]])
        let (app, engine, id) = session(client)
        let turn = Task { await engine.processInput("hi", source: "User", conversationId: id) }
        for _ in 0..<200 where agentTexts(app, id).isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(agentTexts(app, id) == ["part"])
        turn.cancel()
        await turn.value
        #expect(agentTexts(app, id) == ["part"])
        #expect(errorPills(app, id).isEmpty)
        #expect(conv(app, id).history.last?.role == "model")
        #expect(conv(app, id).history.last?.parts.first?.text == "part")
    }

    @Test("an empty stream produces the #136 pill and no agent row")
    func emptyStream() async {
        let client = ScriptedStreamClient([[.event(.done(finishReason: "SAFETY"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(agentTexts(app, id).isEmpty)
        #expect(errorPills(app, id).first?.headline.contains("finishReason: SAFETY") == true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter StreamingEngineTests 2>&1 | grep -E "✘|error:" | head`
Expected: `streamedText` fails (the engine ignores `streamContent` and calls `generateContent`, which throws), `firstTokenRecorded` fails on `firstTokenMs != nil`, `midStreamFailure` fails on `calls == 1`.

- [ ] **Step 3: Add the engine helpers**

In `iris.swift`, next to `pushToUI`:

```swift
    /// One model round's assembled result plus when its first token arrived (spec §4).
    struct StreamOutcome {
        let response: GeminiResponse
        let firstTokenMs: Double?
    }

    /// One attempt at the model call: opens the native stream or a replayed plain call, feeds
    /// text to the streamer as it arrives, and returns the assembled response. A failure after
    /// the first token is wrapped in `StreamInterruptedError` so `LLMRetry` lets it through.
    func consumeModelStream(request: GeminiRequest, streamed: Bool, streamer: MessageStreamer) async throws -> StreamOutcome {
        let start = MonotonicClock.nowMs()
        var assembler = StreamAssembler()
        let client = self.client, tier = self.modelTier
        let stream = streamed
            ? client.streamContent(request: request, tier: tier)
            : LLMStreamEvent.replay { try await client.generateContent(request: request, tier: tier) }
        do {
            for try await event in stream {
                assembler.apply(event, now: MonotonicClock.nowMs())
                if case .textDelta(let delta) = event { await streamer.append(delta) }
            }
            // A cancelled consumer sees the stream end early instead of throwing; make it a Stop.
            try Task.checkCancellation()
        } catch {
            if assembler.firstTokenAt != nil, !(error is CancellationError), !Task.isCancelled {
                throw StreamInterruptedError(underlying: error)
            }
            throw error
        }
        return StreamOutcome(response: assembler.response(), firstTokenMs: assembler.firstTokenAt.map { $0 - start })
    }

    func makeStreamer(conversationId: UUID) -> MessageStreamer {
        MessageStreamer(
            open: { [weak self] id, text in
                guard let self else { return }
                await self.pushToUI(role: .agent, text: text, conversationId: conversationId, id: id)
                let localState = await self.state
                await MainActor.run { localState?.updateSubagentStatus(id: conversationId, status: "Responding...") }
            },
            update: { [weak self] id, text, isFinal in
                await self?.updateStreamedMessage(id: id, content: text, isFinal: isFinal, conversationId: conversationId)
            })
    }

    func updateStreamedMessage(id: UUID, content: String, isFinal: Bool, conversationId: UUID) async {
        let localState = state
        await MainActor.run {
            localState?.updateMessageContent(id: id, content: content, in: conversationId, persist: isFinal)
        }
    }
```

(`state` is `private weak var`; reading it from the closure needs the actor hop shown, or expose a tiny `func currentState() -> AppState?`. Either is fine.)

- [ ] **Step 4: Rewrite the seam**

Inside the `while !turnFinished` loop, immediately before `do {`, add `let streamer = makeStreamer(conversationId: conversationId)`.

Replace the block from `let requestToSend = activeRequest` through the `PerformanceProfiler.shared.recordModelCall(...)` call with:

```swift
                let requestToSend = activeRequest
                let modelCallStart = CFAbsoluteTimeGetCurrent()
                let streamed = ConfigManager.shared.streamResponses && client.supportsStreaming
                let outcome = try await LLMRetry.run(delays: retryDelays, onRetry: { error, attempt, delay in
                    await self.pushToUI(role: .system,
                                        text: "[retry] \(error.message); retrying in \(Self.formatDelay(delay)) (attempt \(attempt) of \(self.retryDelays.count))",
                                        conversationId: conversationId)
                }) {
                    try await measure(.primaryLLM) {
                        try await self.consumeModelStream(request: requestToSend, streamed: streamed, streamer: streamer)
                    }
                }
                let response = outcome.response
                PerformanceProfiler.shared.recordModelCall(
                    turnID: PerformanceProfiler.currentTurnID,
                    ModelCallRecord(
                        round: modelRound,
                        model: ConfigManager.shared.getModel(for: modelTier),
                        latencyMs: (CFAbsoluteTimeGetCurrent() - modelCallStart) * 1000.0,
                        promptTokens: response.usageMetadata?.promptTokenCount,
                        outputTokens: response.usageMetadata?.candidatesTokenCount,
                        returnedToolCalls: response.candidates?.first?.content?.parts.contains { $0.functionCall != nil } ?? false,
                        firstTokenMs: streamed ? outcome.firstTokenMs : nil))
```

In the three early exits that follow (`fireAfterModel` block, `emptyReason` pill, `guard let responseContent ... else { break }`), call `_ = await streamer.settle()` before each `break` (for the `guard`, write it as an `if` so the settle can run).

In the text-part loop replace `await pushToUI(role: .agent, text: responseText, conversationId: conversationId)` with `await streamer.finish(responseText)`. The assembler yields one text part, so this runs once; the hook-modified `activeResponse` text is what gets written, so a rewriting hook still has the last word.

In the `catch`, after `let cancelled = ...` add:

```swift
                // Whatever streamed stays on screen and goes into history: the user saw it, so
                // the model should know it said it (spec §6).
                let partial = await streamer.settle()
                if !partial.isEmpty {
                    let content = Content(role: "model", parts: [Part(text: partial)])
                    await MainActor.run { localState?.appendContentToHistory(for: conversationId, content: content) }
                }
```

- [ ] **Step 5: Run the streaming tests, then the engine suites that share this seam**

Run: `swift test --filter "StreamingEngineTests|LLMErrorEngineTests|EmptyCandidateEngineTests|EngineInstrumentationTests|ScenarioRunnerOptionsTests|LLMRetryTests" 2>&1 | tail -20`
Expected: all pass. If `EmptyCandidateEngineTests` differ only in pill wording, the assembler (Task 1) is wrong, not the test.

- [ ] **Step 6: Document the hook and history semantics**

In `docs/tool_hooks.md`, in the section describing the AfterModel/AfterAgent hooks, add a short paragraph: with streaming on, the reply is shown as it arrives and the AfterModel hook runs once the whole reply has arrived; a hook that rewrites the text replaces what the user has been reading, and a hook that blocks leaves the streamed text in place with the block notice after it. Also note that on Stop or a mid-reply provider failure the partial text is kept and recorded in history as the model's turn.

- [ ] **Step 7: Full suite**

Run: `swift test 2>&1 | tail -5`
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/iris.swift Tests/irisTests/StreamingEngineTests.swift docs/tool_hooks.md
git commit -m "feat(stream): the engine consumes model output as a stream and grows the reply in place

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Verification

**Files:** none new; this task runs the suite, a fake-lane perf smoke, and hands a manual checklist to the user (agent-launched debug binaries block on the Keychain prompt; the user runs the app via `scripts/run-dev.sh`).

- [ ] **Step 1: Full test suite and a clean build**

Run: `swift build 2>&1 | grep -c "warning:.*LLMStream\|warning:.*Streamer"` → expected `0`; `swift test 2>&1 | tail -3` → green.

- [ ] **Step 2: Fake-lane perf smoke renders the new column**

Run: `swift run -c release iris --perf run --suite smoke 2>&1 | grep -E "streaming:|first token ms" | head -3`
Expected: the header shows `- streaming: on` (or `off`, matching the setting) and the table header carries `first token ms`; fake-lane rows show `-` in that column.

- [ ] **Step 3: Manual checklist for the user (report, do not run)**

With `scripts/run-dev.sh`:
1. Gemini: ask for a 300-word explanation; text appears progressively; the final message renders as Markdown; `/tokens` shows the turn counted.
2. Anthropic and OpenAI keys, same prompt, same result; a prompt that triggers `run_command` executes once and the follow-up text streams.
3. Press Stop mid-answer: the partial text stays, no error pill, the next message gets a coherent continuation.
4. A deliberately wrong API key: the #124 pill, no agent row.
5. Settings → Preferences → turn streaming off: whole replies again.
6. `perf/run.sh` real lane: the ladder report shows `first token ms` for rungs 4-5.

- [ ] **Step 4: Open the PR**

Branch `feat/131-streaming`, PR body: link the spec and this plan, list the two behaviour changes (partial text kept on Stop/failure; hooks see the whole reply after it streamed), and paste the smoke header lines from Step 2.

---

## Self-review

- **Spec coverage.** §1 event model → Task 1 (with the recorded additions). §2 protocol + default → Task 1; §2.1 SSE → Task 1 parser, Task 5 pump. §3.1–3.4 → Tasks 2, 3, 4, 5. §4.1 assembler → Task 1; §4.2–4.4 turn, source choice, retries → Task 9 (with Task 6's error). §5.1 AppState → Task 7; §5.2 streamer → Task 7; §5.3 status clearing → Task 9's `open` closure, scroll → no change (documented in spec). §6 table → Task 9 tests (`midStreamFailure`, `preDeltaRetry`, `cancellation`, `emptyStream`) and Task 5 (`httpErrorThrows`). §7 → Task 8. §8 test plan → every listed test exists above except the manual list, which is Task 10. §9 file map → matches the File Structure table. §10 MarkdownUI risk → not built, per spec.
- **Placeholders.** Two test bodies in Task 8 are described rather than written because they must reuse the record-building helpers already in `PerfReportTests.swift`/`PerfCompareTests.swift`; the assertions are stated exactly. No other prose-only steps.
- **Type consistency.** `LLMStreamEvent.done(finishReason:blockReason:)` is used with the default in every mapper except Gemini (Tasks 1–5, 9). `MessageStreamer.append/finish/settle` names match between Task 7 and Task 9. `StreamOutcome`, `consumeModelStream(request:streamed:streamer:)`, `makeStreamer(conversationId:)`, `updateStreamedMessage(id:content:isFinal:conversationId:)` are defined and used only in Task 9. `ModelCallRecord(... firstTokenMs:)` defined in Task 8, used in Task 9. `ScriptedStreamClient.calls` is read in Task 9 tests as defined there. `AppState.updateMessageContent(id:content:in:persist:)` defined in Task 7, called in Task 9.
