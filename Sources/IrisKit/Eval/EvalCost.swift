import Foundation

/// What a paid eval run costs, from #239's price list (`PriceTable.snapshot`), and what it is
/// expected to cost before any call (docs/specs/2026-10-28-model-eval-framework.md, sections 5, 6 and 9).
/// A price the list lacks is nil, shown as "n/a": never a fallback rate, never zero.
enum EvalCost {
    /// Tokens as a provider reports them. Thought tokens are billed as output.
    struct Tokens: Codable, Equatable, Sendable {
        var input: Int
        /// Candidate (visible answer) tokens.
        var output: Int
        var thought: Int
        var calls: Int

        static let zero = Tokens(input: 0, output: 0, thought: 0, calls: 0)

        static func + (a: Tokens, b: Tokens) -> Tokens {
            Tokens(input: a.input + b.input, output: a.output + b.output, thought: a.thought + b.thought, calls: a.calls + b.calls)
        }

        /// One call's usage. Gemini's `thoughtsTokenCount` is not decoded into `UsageMetadata`, but the
        /// total is prompt + candidates + thoughts, so the thought share is what the total leaves.
        init(_ usage: UsageMetadata) {
            input = usage.promptTokenCount ?? 0
            output = usage.candidatesTokenCount ?? 0
            thought = max(0, (usage.totalTokenCount ?? 0) - input - output)
            calls = 1
        }

        init(input: Int, output: Int, thought: Int, calls: Int) {
            self.input = input; self.output = output; self.thought = thought; self.calls = calls
        }
    }

    /// The listed rate for a provider's model, or nil when #239's list has none.
    static func rates(provider: LLMProvider, model: String, table: PriceTable = .snapshot) -> TokenRates? {
        table.rate(family: provider.rawValue.lowercased(), model: model)
    }

    /// Dollars for `tokens` at `rates`; nil when there is no rate.
    static func dollars(_ tokens: Tokens, rates: TokenRates?) -> Double? {
        guard let rates else { return nil }
        return Double(tokens.input) * rates.input + Double(tokens.output + tokens.thought) * rates.output
    }

    /// Dollars per 1,000 judgements; nil without a rate or without any judgement.
    static func perThousand(_ dollars: Double?, judgements: Int) -> Double? {
        guard let dollars, judgements > 0 else { return nil }
        return dollars / Double(judgements) * 1_000
    }

    /// Measured on gemini-3.8-flash in #783's bake-off (eval/bakeoff-783: 401 judgements per arm):
    /// about 845 input tokens, 1.5 output and these thought tokens a judgement. Used only to
    /// estimate; a result records what the provider reported.
    static let templateTokens = 90
    static let outputTokens = 2
    static let thoughtTokens: [String: Int] = ["low": 62, "medium": 145]
    /// No level sent is unmeasured (#800): the larger measured figure stands in, said in the estimate.
    static let unmeasuredThoughtTokens = 145

    struct Estimate: Equatable, Sendable {
        var calls: Int
        var tokens: Tokens
        var dollars: Double?
        var assumptions: [String]
    }

    /// The expected calls and cost of judging `texts` `repeats` times each, with no call made. Input
    /// tokens are the text (as capped for the canary) at 4 bytes a token plus the template.
    static func estimate(textBytes: [Int], repeats: Int, thinkingLevel: String?, rates: TokenRates?) -> Estimate {
        let thought = thinkingLevel.flatMap { thoughtTokens[$0] } ?? unmeasuredThoughtTokens
        let input = textBytes.reduce(0) { $0 + min($1, OutputCap.limitBytes) / 4 + templateTokens } * repeats
        let calls = textBytes.count * repeats
        let tokens = Tokens(input: input, output: outputTokens * calls, thought: thought * calls, calls: calls)
        var notes = ["input tokens: each text (capped at \(OutputCap.limitBytes) bytes) at 4 bytes a token, plus about \(templateTokens) for the prompt",
                     "answer tokens: about \(outputTokens) a call",
                     thinkingLevel.flatMap { thoughtTokens[$0] } != nil
                        ? "thought tokens: \(thought) a call, the mean measured at level \(thinkingLevel ?? "") in #783's bake-off"
                        : "thought tokens: \(thought) a call; no level sent is unmeasured, so the larger measured mean (level medium) stands in"]
        if rates == nil { notes.append("no listed price for this model: the cost is not estimated") }
        return Estimate(calls: calls, tokens: tokens, dollars: dollars(tokens, rates: rates), assumptions: notes)
    }

    static func money(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "$%.4f", value)
    }
}
