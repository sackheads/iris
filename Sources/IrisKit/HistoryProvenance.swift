import Foundation

/// #1452: history keeps provider-specific fields beside the text: Anthropic's echoed blocks (#314) and Gemini's thought
/// signatures, which `OpenAIClient` sends back as `reasoning_content` and reads DeepSeek's reasoning into. A request
/// to one provider must never carry another's: a Gemini signature would reach DeepSeek as its reasoning, and DeepSeek's
/// reasoning would reach Gemini as a signature. So each request drops them from every entry another provider produced.
/// Stored history is never rewritten, so a switch back still replays a provider's own entries byte for byte.
enum HistoryProvenance {
    static func filtered(_ request: GeminiRequest, for provider: String?) -> GeminiRequest {
        guard let provider else { return request }
        var filtered = request
        filtered.contents = request.contents.map { $0.forProvider(provider) }
        return filtered
    }
}

extension Content {
    /// This entry as a request to `provider` may carry it: unchanged when that provider produced it, or when nobody
    /// recorded who did (rows from before #1452 behave as they always have), and otherwise without Anthropic's blocks
    /// and without any thought signature. Text, tool calls and tool results always stay.
    func forProvider(_ provider: String) -> Content {
        guard let producer = producedBy, producer != provider else { return self }
        var stripped = self
        stripped.anthropicBlocks = nil
        stripped.parts = parts.map { part in
            var part = part
            part.thought_signature = nil
            part.thoughtSignature = nil
            if var call = part.functionCall {
                call.thought_signature = nil
                call.thoughtSignature = nil
                part.functionCall = call
            }
            return part
        }
        return stripped
    }
}
