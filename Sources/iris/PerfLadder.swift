import Foundation

/// What a real turn sends besides the prompt, captured once per scenario.
struct LadderCapture: Sendable {
    let systemInstruction: Content?
    let tools: [Tool]?
    var toolCount: Int
}

/// One timed ladder call.
struct LadderSample: Sendable {
    let wallClockMs: Double
    let modelCall: ModelCallRecord?
    let error: String?
}

/// Rungs 1 to 3 of the overhead ladder: direct provider calls with progressively more of what
/// Iris adds. Rungs 4 and 5 are ordinary `ScenarioRunner` turns and live in `PerfRunner`.
enum PerfLadder {
    /// Run one engine turn against a capturing client with guards off, and keep the request it
    /// built. This is exactly the system prompt and tool list a real turn sends.
    @MainActor
    static func capture(for scenario: Scenario) async -> LadderCapture {
        let client = CapturingLLMClient(reply: "ok")
        var one = scenario
        one.turns = Array(scenario.turns.prefix(1))
        _ = await ScenarioRunner.run(one, guards: .off, clientOverride: client)
        let request = client.requests.first
        let count = request?.tools?.reduce(0) { $0 + $1.functionDeclarations.count } ?? 0
        return LadderCapture(systemInstruction: request?.systemInstruction, tools: request?.tools, toolCount: count)
    }

    static func request(rung: Int, prompt: String, capture: LadderCapture) -> GeminiRequest {
        let user = Content(role: "user", parts: [Part(text: prompt, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
        switch rung {
        case 1: return GeminiRequest(contents: [user], systemInstruction: nil, tools: nil)
        case 2: return GeminiRequest(contents: [user], systemInstruction: capture.systemInstruction, tools: nil)
        default: return GeminiRequest(contents: [user], systemInstruction: capture.systemInstruction, tools: capture.tools)
        }
    }

    static func sample(rung: Int, prompt: String, tier: ModelTier, capture: LadderCapture,
                       client: any LLMClientProtocol) async -> LadderSample {
        let req = request(rung: rung, prompt: prompt, capture: capture)
        let model = await MainActor.run { ConfigManager.shared.getModel(for: tier) }
        let start = MonotonicClock.nowMs()
        do {
            let response = try await client.generateContent(request: req, tier: tier)
            let ms = (MonotonicClock.nowMs() - start)
            let call = ModelCallRecord(round: 0, model: model, latencyMs: ms,
                                       promptTokens: response.usageMetadata?.promptTokenCount,
                                       outputTokens: response.usageMetadata?.candidatesTokenCount,
                                       returnedToolCalls: response.candidates?.first?.content?.parts.contains { $0.functionCall != nil } ?? false)
            return LadderSample(wallClockMs: ms, modelCall: call, error: nil)
        } catch {
            let ms = (MonotonicClock.nowMs() - start)
            return LadderSample(wallClockMs: ms, modelCall: nil, error: LLMErrorMessage.display(for: error).headline)
        }
    }
}
