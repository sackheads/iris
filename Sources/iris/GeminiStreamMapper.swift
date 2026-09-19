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
