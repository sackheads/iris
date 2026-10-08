import Foundation

/// A scripted LLM client for headless runs and tests: returns queued responses in order
/// without any network call, records how many times it was asked, and optionally sleeps a
/// configurable amount before returning so a fake run models model latency instead of
/// reporting near-zero primary-LLM time.
///
/// The engine awaits each turn before the next, so calls are serialized — the index/count
/// mutations need no lock.
final class FakeLLMClient: LLMClientProtocol, @unchecked Sendable {
    /// Simulated per-call latency. `minMs == 0 && maxMs == 0` returns instantly.
    struct Latency: Codable, Sendable {
        var minMs: Int
        var maxMs: Int
        init(minMs: Int, maxMs: Int) { self.minMs = minMs; self.maxMs = maxMs }
    }

    private var index = 0
    private(set) var callCount = 0
    private let responses: [GeminiResponse]
    private let latency: Latency

    init(responses: [GeminiResponse], latency: Latency = .init(minMs: 0, maxMs: 0)) {
        self.responses = responses
        self.latency = latency
    }

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        callCount += 1
        if latency.maxMs > 0 {
            let lo = max(0, min(latency.minMs, latency.maxMs))
            let hi = max(lo, latency.maxMs)
            let ms = lo == hi ? lo : Int.random(in: lo...hi)
            if ms > 0 { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
        }
        guard !responses.isEmpty else {
            throw APIError(message: "FakeLLMClient has no responses queued")
        }
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}
