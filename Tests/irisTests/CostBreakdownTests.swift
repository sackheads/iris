import Foundation
import Testing
@testable import IrisKit

/// #1011: the toolbar cost figure taken apart by token type.
@MainActor
@Suite("Cost breakdown (#1011)", .timeLimit(.minutes(1)))
struct CostBreakdownTests {
    // $3 / $15 per MTok input / output, $0.30 cache read, $3.75 cache write: round numbers a
    // reader can check by hand.
    private let rates = TokenRates(input: 3e-6, output: 15e-6, cacheRead: 0.3e-6, cacheWrite: 3.75e-6)

    private func cost(_ rates: TokenRates, source: RateSource = .snapshot, estimated: Bool = false, note: String? = nil) -> ConversationCost {
        ConversationCost(dollars: 0, model: "claude-test-1",
                         rate: ResolvedRate(rates: rates, source: source, asOf: "2026-11-01", estimated: estimated, note: note))
    }

    private var usage: TokenUsage {
        // prompt 1,000,000 of which 600,000 are cache reads and 100,000 cache writes: 300,000 plain.
        var u = TokenUsage(promptTokenCount: 1_000_000, candidatesTokenCount: 50_000, totalTokenCount: 1_050_000)
        u.cacheReadTokenCount = 600_000
        u.cacheWriteTokenCount = 100_000
        return u
    }

    @Test("each line is tokens times rate, and the lines are the four terms of the estimate")
    func lines() throws {
        let b = CostBreakdown.make(usage: usage, cost: cost(rates))
        #expect(b.lines.map(\.kind) == [.input, .cacheRead, .cacheWrite, .output])
        #expect(b.lines.map(\.tokens) == [300_000, 600_000, 100_000, 50_000])
        let d = b.lines.map(\.dollars)
        #expect(abs(d[0] - 0.9) < 1e-9)      // 300k x $3
        #expect(abs(d[1] - 0.18) < 1e-9)     // 600k x $0.30
        #expect(abs(d[2] - 0.375) < 1e-9)    // 100k x $3.75
        #expect(abs(d[3] - 0.75) < 1e-9)     // 50k x $15
        #expect(b.lines.map(\.ratePerMTok).map { ($0 * 100).rounded() / 100 } == [3, 0.3, 3.75, 15])
    }

    @Test("the lines sum to exactly the toolbar figure, for several shapes of usage")
    func sumsToTheEstimate() {
        var shapes: [TokenUsage] = [usage]
        shapes.append(TokenUsage(promptTokenCount: 1_000, candidatesTokenCount: 10, totalTokenCount: 1_010))   // no cache reported
        var gemini = TokenUsage(promptTokenCount: 5_000, candidatesTokenCount: 100, totalTokenCount: 5_900)    // thinking tokens: output is total - prompt
        gemini.cacheReadTokenCount = 2_000
        shapes.append(gemini)
        for u in shapes {
            let c = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: .snapshotOnly)
            let b = CostBreakdown.make(usage: u, cost: c)
            #expect(abs(b.total - c.dollars) < 1e-12, "breakdown \(b.total) vs toolbar \(c.dollars) for \(u)")
        }
    }

    @Test("a cache figure the provider never reported is shown as not reported, not as zero")
    func unreportedCache() {
        let u = TokenUsage(promptTokenCount: 1_000, candidatesTokenCount: 10, totalTokenCount: 1_010)
        let b = CostBreakdown.make(usage: u, cost: cost(rates))
        #expect(b.lines[1].tokens == nil && b.lines[2].tokens == nil)
        #expect(CostBreakdown.tokens(nil) == "not reported")
        #expect(b.lines[1].dollars == 0)
    }

    @Test("a model with no cache-write rate prices writes as input and says so")
    func noCacheWriteRate() {
        let b = CostBreakdown.make(usage: usage, cost: cost(TokenRates(input: 3e-6, output: 15e-6, cacheRead: 0.3e-6, cacheWrite: nil)))
        let write = b.lines[2]
        #expect(abs(write.dollars - 0.3) < 1e-9)          // 100k x $3, the input rate
        #expect(write.note?.contains("priced as input") == true)
        #expect(b.lines[0].note == nil)
    }

    @Test("the caveats say the figure is an estimate, at the current model, and leaves subagents out")
    func caveats() {
        let b = CostBreakdown.make(usage: usage, cost: cost(rates))
        #expect(b.caveats.contains { $0.contains("An estimate, not a bill") && $0.contains("claude-test-1") && $0.contains("current model") })
        #expect(b.caveats.contains { $0.contains("Subagents") && $0.contains("not included") })
        #expect(b.rateSourceNote == "price list of 2026-11-01")
    }

    @Test("1-hour cache writes and a fallback rate each add their own caveat, and only then")
    func conditionalCaveats() {
        #expect(!CostBreakdown.make(usage: usage, cost: cost(rates)).caveats.contains { $0.contains("1-hour") || $0.contains("No exact rate") })
        var u = usage; u.cacheWrite1hTokenCount = 40_000
        let b = CostBreakdown.make(usage: u, cost: cost(rates, source: .fallback, estimated: true, note: "set a rate in Settings"))
        #expect(b.caveats.contains { $0.contains("40,000") && $0.contains("1-hour") && $0.contains("bill above the rate") })
        #expect(b.caveats.contains { $0.contains("No exact rate is known") && $0.contains("set a rate in Settings") })
        #expect(b.rateSourceNote == "fallback")
    }

    @Test("a server on this Mac says it is free, and every line is zero")
    func loopback() {
        let zero = TokenRates(input: 0, output: 0, cacheRead: 0, cacheWrite: nil)
        let b = CostBreakdown.make(usage: usage, cost: cost(zero, source: .loopback))
        #expect(b.rateSourceNote == "a server on this Mac: no charge")
        #expect(b.total == 0 && b.lines.allSatisfy { $0.dollars == 0 })
        #expect(CostBreakdown.money(0) == "$0.00")
    }

    @Test("figures are formatted the same on every Mac")
    func formatting() {
        #expect(CostBreakdown.tokens(1_234_567) == "1,234,567")
        #expect(CostBreakdown.rate(3) == "$3.00/MTok")
        #expect(CostBreakdown.rate(0.3) == "$0.30/MTok")
        #expect(CostBreakdown.rate(1.25) == "$1.25/MTok")
        #expect(CostBreakdown.rate(0.075) == "$0.075/MTok")
        #expect(CostBreakdown.money(0.18) == "$0.1800")
        #expect(CostBreakdown.money(0.00005) == "<$0.0001")
        #expect(CostBreakdown.money(12.3456) == "$12.35")
        #expect(CostBreakdown.money(1234.5) == "$1,234.50")
    }

    @Test("thinking tokens folded into Output are labelled, and only when there are any")
    func thinkingTokensLabelled() {
        // Gemini: the total (5,900) minus the prompt (5,000) is 900, the candidates 100: 800 are thinking.
        var g = TokenUsage(promptTokenCount: 5_000, candidatesTokenCount: 100, totalTokenCount: 5_900)
        g.cacheReadTokenCount = 2_000
        let out = CostBreakdown.make(usage: g, cost: cost(rates)).lines[3]
        #expect(out.tokens == 900)
        #expect(out.note == "Includes 800 thinking tokens (the provider's total minus the prompt), billed as output.")
        #expect(CostBreakdown.make(usage: usage, cost: cost(rates)).lines[3].note == nil)
    }

    @Test("a line the provider never reported shows a dash, a reported zero shows $0.00")
    func dashForUnreported() {
        let none = TokenUsage(promptTokenCount: 1_000, candidatesTokenCount: 10, totalTokenCount: 1_010)
        let a = CostBreakdown.make(usage: none, cost: cost(rates))
        #expect(CostBreakdown.cost(of: a.lines[1]) == "\u{2014}" && CostBreakdown.cost(of: a.lines[2]) == "\u{2014}")
        var zero = none; zero.cacheReadTokenCount = 0
        let b = CostBreakdown.make(usage: zero, cost: cost(rates))
        #expect(CostBreakdown.cost(of: b.lines[1]) == "$0.00")
        #expect(CostBreakdown.cost(of: b.lines[0]) != "\u{2014}")
    }

    @Test("the toolbar figure is a button that opens the breakdown popover")
    func toolbarOpensThePopover() throws {
        let chat = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/ChatView.swift"), encoding: .utf8)
        #expect(chat.contains("Button { showCostBreakdown.toggle() }"), "the cost figure must be a click target")
        #expect(chat.contains("CostBreakdownView(breakdown: CostBreakdown.make(usage: conv.tokenUsage, cost: cost))"),
                "the popover is built from the figure it opened from, with no optional that can render it empty")
        #expect(chat.contains(".popover(isPresented: $showCostBreakdown"))
    }
}
