import Foundation

/// Records every request the engine sends and answers each with a fixed text. The perf ladder
/// uses it to obtain the exact system prompt and tool list a real turn would send, without
/// calling a provider.
final class CapturingLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    let reply: String

    init(reply: String = "ok") { self.reply = reply }

    var requests: [GeminiRequest] { lock.withLock { recorded } }

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        lock.withLock { recorded.append(request) }
        let part = Part(text: reply, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }
}
