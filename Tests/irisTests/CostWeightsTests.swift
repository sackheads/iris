import Testing
import Foundation
@testable import iris

/// 5c §0.5: the weighted-token table. Budgets compare these figures, so a wrong weight here moves
/// every stop and every pause.
@Suite struct CostWeightsTests {
    @Test func anthropicWeights() {
        let u = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400, cacheWrite: 400, cacheWrite1h: 100)
        // uncached 200×1 + read 19_400×0.1 + 5m 300×1.25 + 1h 100×2 + output 500×5
        #expect(CostWeights.weighted(u, provider: "Anthropic", model: nil) == 200 + 1_940 + 375 + 200 + 2_500)
    }

    @Test func specExampleIsAboutFiveThousand() {
        // §0.5: a 20k prompt, 97% cache reads, 500 output tokens ≈ 5k weighted.
        let u = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400, cacheWrite: 0, cacheWrite1h: 0)
        #expect((4_500...5_500).contains(CostWeights.weighted(u, provider: "Anthropic", model: nil)))
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
        #expect(CostWeights.weighted(u, provider: "Mistral", model: nil) == 1_000 + 50)
    }

    /// Plan rulings 7 and 10: no provider means a row written before 5c, priced at its plain
    /// `totalTokens` — every component at 1×, output included — which is what it was charged then.
    @Test func noProviderIsPlainTotal() {
        let u = UsageComponents(prompt: 1_000, output: 10, cacheRead: 600, cacheWrite: 100, cacheWrite1h: 0)
        #expect(CostWeights.weighted(u, provider: nil, model: nil) == 1_010)
    }

    @Test func inconsistentInputsNeverGoNegative() {
        let u = UsageComponents(prompt: 10, output: -3, cacheRead: 50, cacheWrite: 5, cacheWrite1h: 9)
        #expect(CostWeights.weighted(u, provider: "Anthropic", model: nil) >= 0)
        #expect(CostWeights.weighted(UsageComponents(prompt: -5, output: -3), provider: nil, model: nil) == 0)
    }

    @Test func roundsUp() {
        #expect(CostWeights.weighted(UsageComponents(prompt: 1, cacheRead: 1), provider: "Anthropic", model: nil) == 1)
    }

    // MARK: Per-model read ratio (#370)

    /// Pinned on 2026-10-06 from Anthropic's published pricing (platform.claude.com pricing and
    /// prompt-caching pages): cache reads cost 0.1× base input on every Claude model except
    /// claude-opus-5-5 ($0.20 against $4 per MTok, 0.05×) and claude-fable-5-1 / claude-mythos-5-1
    /// ($0.25 against $10, 0.025×). claude-opus-5 ($0.50 against $5) and claude-fable-5 ($1 against
    /// $10) are 0.1×. Revisit when a model ships or a price changes.
    @Test func modelReadRatiosArePinned() {
        #expect(CostWeights.modelReadRatios == [
            "claude-opus-5-5": 0.05,
            "claude-opus-5": 0.1,
            "claude-fable-5-1": 0.025,
            "claude-mythos-5-1": 0.025,
            "claude-fable-5": 0.1,
            "claude-sonnet": 0.1,
            "claude-haiku": 0.1,
        ])
    }

    /// A 20k prompt that is 97% cache reads: the read is the only figure that differs by model.
    private let readHeavy = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400,
                                            cacheWrite: 400, cacheWrite1h: 100)

    @Test func opusReadsAtHalfHaikusRate() {
        // uncached 200 + 5m 300×1.25 + 1h 100×2 + output 500×5, then reads at each model's ratio.
        let rest = 200 + 375 + 200 + 2_500
        #expect(CostWeights.weighted(readHeavy, provider: "Anthropic", model: "claude-opus-5-5") == rest + 970)
        #expect(CostWeights.weighted(readHeavy, provider: "Anthropic", model: "claude-haiku-4-5-20251001") == rest + 1_940)
        #expect(CostWeights.weighted(readHeavy, provider: "Anthropic", model: "claude-sonnet-5") == rest + 1_940)
    }

    @Test func longestKeyWinsAndDatedOrPlatformIdsMatch() {
        #expect(CostWeights.modelReadRatio(for: "claude-opus-5-5") == 0.05)
        #expect(CostWeights.modelReadRatio(for: "claude-opus-5") == 0.1, "Opus 5 is not Opus 5.5")
        #expect(CostWeights.modelReadRatio(for: "claude-opus-5-5-20261001") == 0.05)
        #expect(CostWeights.modelReadRatio(for: "claude-haiku-4-5@20251001") == 0.1, "Vertex spelling")
        #expect(CostWeights.modelReadRatio(for: "us.anthropic.claude-opus-5-5") == 0.05, "Bedrock spelling")
        #expect(CostWeights.modelReadRatio(for: "CLAUDE-OPUS-5-5") == 0.05)
        #expect(CostWeights.modelReadRatio(for: "claude-fable-5-1") == 0.025)
        #expect(CostWeights.modelReadRatio(for: "claude-fable-5") == 0.1)
        // A key is a whole id segment, never a bare prefix of one.
        #expect(CostWeights.modelReadRatio(for: "claude-opus-55") == nil)
        #expect(CostWeights.modelReadRatio(for: "claude-sonnetx") == nil)
    }

    /// A model the table does not list reads at the provider's ratio, and so does a row with no model.
    @Test func unknownOrMissingModelFallsBackToTheProvider() {
        let provider = CostWeights.weighted(readHeavy, provider: "Anthropic", model: nil)
        #expect(CostWeights.weighted(readHeavy, provider: "Anthropic", model: "claude-opus-4-8") == provider)
        #expect(CostWeights.weighted(readHeavy, provider: "Anthropic", model: "") == provider)
        #expect(CostWeights.weighted(readHeavy, provider: "Gemini", model: "gemini-3.5-flash")
                == CostWeights.weighted(readHeavy, provider: "Gemini", model: nil))
        #expect(CostWeights.modelReadRatio(for: "gpt-5.6-terra") == nil)
    }

    /// The model changes the read ratio only: write weights stay the provider's.
    @Test func modelKeepsTheProvidersWriteWeights() {
        let r = CostWeights.rates(provider: "Anthropic", model: "claude-opus-5-5")
        #expect(r == .init(read: 0.05, write5m: 1.25, write1h: 2.0))
        #expect(CostWeights.rates(provider: "Mistral", model: "claude-opus-5-5")
                == .init(read: 0.05, write5m: 1, write1h: 1))
    }

    /// A legacy row (no provider) is a plain total whatever its model says.
    @Test func noProviderIsPlainTotalEvenWithAModel() {
        #expect(CostWeights.weighted(readHeavy, provider: nil, model: "claude-opus-5-5") == 20_500)
    }
}
