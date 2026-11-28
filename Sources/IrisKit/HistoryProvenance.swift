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
    /// This entry as a request to `provider` may carry it: unchanged when that provider produced it, and otherwise
    /// without Anthropic's blocks and without any thought signature. Text, tool calls and tool results always stay.
    func forProvider(_ provider: String) -> Content {
        guard let producer = producedBy else { return untaggedForProvider(provider) }
        guard producer != provider else { return self }
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

    /// A row from before #1452 records no producer, and its signature fields hold either kind, since `OpenAIClient`
    /// reads DeepSeek's reasoning into them too (dev-2's #1455 review). The values tell themselves apart: a Gemini
    /// signature is a long run of base64 (`isGeminiSignature`), and reasoning is anything else, a one-word answer
    /// included. So a request to Gemini drops each value that is reasoning, and one to an OpenAI-compatible provider
    /// each value that is a signature. Anthropic's client sends neither, so its requests are unchanged, as are the
    /// blocks only it reads.
    func untaggedForProvider(_ provider: String) -> Content {
        guard provider != ProviderSlug.id(of: .anthropic) else { return self }
        let toGemini = provider == ProviderSlug.id(of: .gemini)
        func kept(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return value }
            return Self.isGeminiSignature(value) == toGemini ? value : nil
        }
        var filtered = self
        filtered.parts = parts.map { part in
            var part = part
            part.thought_signature = kept(part.thought_signature)
            part.thoughtSignature = kept(part.thoughtSignature)
            if var call = part.functionCall {
                call.thought_signature = kept(call.thought_signature)
                call.thoughtSignature = kept(call.thoughtSignature)
                part.functionCall = call
            }
            return part
        }
        return filtered
    }

    /// Base64 (standard or URL-safe), at least 40 characters: real signatures run to hundreds, and reasoning, even a
    /// single word, is shorter or has a character base64 doesn't use.
    static func isGeminiSignature(_ value: String) -> Bool {
        value.count >= 40 && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+/=-_".unicodeScalars.contains($0)
        }
    }
}
