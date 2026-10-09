import Foundation

/// What the chat shows for a failed model call: a one-line headline and an optional capped raw
/// detail behind a disclosure.
struct LLMErrorDisplay: Equatable, Codable {
    let headline: String
    let detail: String?
}

/// LLM failures travel through the conversation as a tagged system message, the same convention
/// as `[TOOL_CALL]`, so the view can render them as a pill rather than as something Iris said.
enum LLMErrorMessage {
    static let prefix = "[LLM_ERROR]\n"
    /// What the engine used to post, as an `.agent` message, with the raw provider body appended.
    private static let legacyPrefix = "Error calling LLM: "

    static func display(for error: Error) -> LLMErrorDisplay {
        if let interrupted = error as? StreamInterruptedError {
            let inner = display(for: interrupted.underlying)
            return LLMErrorDisplay(headline: "Response interrupted: " + inner.headline, detail: inner.detail)
        }
        if let api = error as? APIError {
            return LLMErrorDisplay(headline: api.message, detail: api.detail)
        }
        return LLMErrorDisplay(headline: APIError.truncated(error.localizedDescription, to: APIError.headlineLimit), detail: nil)
    }

    static func encode(_ error: Error) -> String { encode(display(for: error)) }

    static func encode(_ display: LLMErrorDisplay) -> String {
        let data = (try? JSONEncoder().encode(display)) ?? Data()
        return prefix + (String(data: data, encoding: .utf8) ?? "{}")
    }

    static func parse(_ text: String) -> LLMErrorDisplay? {
        guard text.hasPrefix(prefix) else { return nil }
        let json = text.dropFirst(prefix.count)
        return try? JSONDecoder().decode(LLMErrorDisplay.self, from: Data(json.utf8))
    }

    /// Rewrite a persisted pre-tag error bubble into the tagged form. Anything else is returned
    /// unchanged. Applied on load so oversize bodies already on disk stop re-rendering forever.
    static func migrateLegacy(_ message: ChatMessage) -> ChatMessage {
        guard message.role == .agent, message.content.hasPrefix(legacyPrefix) else { return message }
        let rest = String(message.content.dropFirst(legacyPrefix.count))
        let display: LLMErrorDisplay
        if let match = rest.wholeMatch(of: /(?s)^(?:(Anthropic|OpenAI) )?HTTP (\d+): (.*)$/),
           let status = Int(match.2) {
            let provider = match.1.map(String.init) ?? "Gemini"
            display = self.display(for: APIError.http(provider: provider, statusCode: status, body: Data(match.3.utf8)))
        } else {
            display = LLMErrorDisplay(headline: APIError.truncated(rest, to: APIError.headlineLimit), detail: nil)
        }
        return ChatMessage(id: message.id, role: .system, content: encode(display), attachments: message.attachments)
    }
}
