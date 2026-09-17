import Testing
import Foundation
@testable import iris

@Suite("PerfLadder rungs 1-3")
struct PerfLadderTests {
    private let sys = Content(role: "system", parts: [Part(text: "You are Iris.", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
    private var capture: LadderCapture {
        LadderCapture(systemInstruction: sys,
                      tools: [Tool(functionDeclarations: [FunctionDeclaration(name: "read_file", description: "d", parameters: Schema(type: "OBJECT", properties: [:], required: []))])],
                      toolCount: 1)
    }

    @Test("rung 1 sends the prompt alone")
    func rung1() {
        let r = PerfLadder.request(rung: 1, prompt: "hi", capture: capture)
        #expect(r.systemInstruction == nil)
        #expect(r.tools == nil)
        #expect(r.contents.first?.parts.first?.text == "hi")
    }

    @Test("rung 2 adds the system prompt, rung 3 adds the tools")
    func rung2and3() {
        #expect(PerfLadder.request(rung: 2, prompt: "hi", capture: capture).systemInstruction?.parts.first?.text == "You are Iris.")
        #expect(PerfLadder.request(rung: 2, prompt: "hi", capture: capture).tools == nil)
        #expect(PerfLadder.request(rung: 3, prompt: "hi", capture: capture).tools?.first?.functionDeclarations.count == 1)
    }

    @Test("a sample records latency and tokens from the reply")
    func sampleRecordsCall() async {
        let usage = UsageMetadata(promptTokenCount: 12, candidatesTokenCount: 3, totalTokenCount: 15)
        let reply = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: usage)
        let client = FakeLLMClient(responses: [reply])
        let s = await PerfLadder.sample(rung: 1, prompt: "hi", tier: .medium, capture: capture, client: client)
        #expect(s.error == nil)
        #expect(s.modelCall?.promptTokens == 12)
        #expect(s.modelCall?.outputTokens == 3)
        #expect(s.wallClockMs >= 0)
    }

    @Test("a failing call is a recorded error, not a crash")
    func sampleRecordsError() async {
        struct Failing: LLMClientProtocol {
            func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
                throw APIError(message: "boom")
            }
        }
        let s = await PerfLadder.sample(rung: 2, prompt: "hi", tier: .medium, capture: capture, client: Failing())
        #expect(s.error == "boom")
        #expect(s.modelCall == nil)
    }

    @MainActor
    @Test("capture assembles what a real turn would send, without a provider")
    func captureFromEngine() async {
        let scenario = Scenario(name: "cap", clientMode: .real, turns: [Scenario.Turn(prompt: "hello")])
        let c = await PerfLadder.capture(for: scenario)
        #expect(c.systemInstruction?.parts.first?.text?.isEmpty == false)
        #expect(c.toolCount > 10)
    }
}
