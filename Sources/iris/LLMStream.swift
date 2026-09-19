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

extension StreamMapper {
    /// Provider tool-argument JSON as the engine's argument dictionary. An empty buffer is `{}`;
    /// anything that does not parse throws, so a truncated call is never dispatched.
    static func decodeArguments(_ raw: String) throws -> [String: JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode([String: JSONValue].self, from: Data((trimmed.isEmpty ? "{}" : trimmed).utf8))
    }
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
