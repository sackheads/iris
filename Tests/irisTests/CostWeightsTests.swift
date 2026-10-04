import Testing
import Foundation
@testable import iris

/// 5c §0.5: the weighted-token table. Budgets compare these figures, so a wrong weight here moves
/// every stop and every pause.
@Suite struct CostWeightsTests {
    @Test func anthropicWeights() {
        let u = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400, cacheWrite: 400, cacheWrite1h: 100)
        // uncached 200×1 + read 19_400×0.1 + 5m 300×1.25 + 1h 100×2 + output 500×5
        #expect(CostWeights.weighted(u, provider: "Anthropic") == 200 + 1_940 + 375 + 200 + 2_500)
    }

    @Test func specExampleIsAboutFiveThousand() {
        // §0.5: a 20k prompt, 97% cache reads, 500 output tokens ≈ 5k weighted.
        let u = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400, cacheWrite: 0, cacheWrite1h: 0)
        #expect((4_500...5_500).contains(CostWeights.weighted(u, provider: "Anthropic")))
    }

    /// Pinned on 2026-10-04 from https://ai.google.dev/gemini-api/docs/pricing (gemini-3.5-flash:
    /// input $1.50, context caching $0.15 per 1M, ratio 0.1) and
    /// https://developers.openai.com/api/docs/pricing (gpt-5.6-terra: input $2.00, cached input
    /// $0.20 per 1M, ratio 0.1) — each provider's default medium model (plan note 12).
    @Test func geminiAndOpenAIHaveNoWriteCharge() {
        #expect(CostWeights.rates(for: "Gemini") == .init(read: 0.1, write5m: 0, write1h: 0))
        #expect(CostWeights.rates(for: "OpenAI") == .init(read: 0.1, write5m: 0, write1h: 0))
    }

    /// A provider string this build does not know: reads and writes at 1×, output still 5×.
    @Test func unknownProviderIsOneToOne() {
        let u = UsageComponents(prompt: 1_000, output: 10, cacheRead: 600, cacheWrite: 100, cacheWrite1h: 0)
        #expect(CostWeights.weighted(u, provider: "Mistral") == 1_000 + 50)
    }

    /// Plan rulings 7 and 10: no provider means a row written before 5c, priced at its plain
    /// `totalTokens` — every component at 1×, output included — which is what it was charged then.
    @Test func noProviderIsPlainTotal() {
        let u = UsageComponents(prompt: 1_000, output: 10, cacheRead: 600, cacheWrite: 100, cacheWrite1h: 0)
        #expect(CostWeights.weighted(u, provider: nil) == 1_010)
    }

    @Test func inconsistentInputsNeverGoNegative() {
        let u = UsageComponents(prompt: 10, output: -3, cacheRead: 50, cacheWrite: 5, cacheWrite1h: 9)
        #expect(CostWeights.weighted(u, provider: "Anthropic") >= 0)
        #expect(CostWeights.weighted(UsageComponents(prompt: -5, output: -3), provider: nil) == 0)
    }

    @Test func roundsUp() {
        #expect(CostWeights.weighted(UsageComponents(prompt: 1, cacheRead: 1), provider: "Anthropic") == 1)
    }
}
