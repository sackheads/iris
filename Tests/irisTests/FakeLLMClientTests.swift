import Testing
import Foundation
@testable import iris

@Suite("FakeLLMClient")
struct FakeLLMClientTests {

    private func textResponse(_ s: String) -> GeminiResponse {
        let part = Part(text: s, functionCall: nil, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    @Test("returns queued responses in order and counts calls")
    func returnsInOrder() async throws {
        let client = FakeLLMClient(responses: [textResponse("one"), textResponse("two")])
        let a = try await client.generateContent(request: GeminiRequest(contents: []), tier: .medium)
        let b = try await client.generateContent(request: GeminiRequest(contents: []), tier: .medium)
        #expect(a.candidates?.first?.content?.parts.first?.text == "one")
        #expect(b.candidates?.first?.content?.parts.first?.text == "two")
        #expect(client.callCount == 2)
    }

    @Test("clamps at the last response when responses are exhausted")
    func clampsAtLast() async throws {
        let client = FakeLLMClient(responses: [textResponse("only")])
        _ = try await client.generateContent(request: GeminiRequest(contents: []), tier: .medium)
        let second = try await client.generateContent(request: GeminiRequest(contents: []), tier: .medium)
        #expect(second.candidates?.first?.content?.parts.first?.text == "only")
    }

    @Test("honors a minimum latency before returning")
    func honorsLatency() async throws {
        let client = FakeLLMClient(responses: [textResponse("slow")],
                                   latency: .init(minMs: 40, maxMs: 40))
        let start = Date()
        _ = try await client.generateContent(request: GeminiRequest(contents: []), tier: .medium)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        #expect(elapsedMs >= 30) // generous lower bound to avoid flakiness
    }
}
