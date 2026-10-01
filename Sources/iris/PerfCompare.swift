import Foundation

struct PerfComparison {
    struct Row: Equatable {
        var scenario: String
        var rung: Int?
        var metric: String
        var before: Double
        var after: Double
        var change: Double?
        var flagged: Bool
    }
    var refusal: String?
    var rows: [Row]
    /// Advisory lines that aren't per-row regressions: today, just the cache-count straddle
    /// warning (5a review #9).
    var notes: [String] = []
    var flagged: [Row] { rows.filter(\.flagged) }
}

/// Joins two records by scenario name and rung and flags regressions past a threshold.
/// Only like-for-like is compared: a provider or model change is a refusal, not a regression.
enum PerfCompare {
    /// A median-ms change is flagged only when it is also at least this many ms in absolute
    /// terms: fake-lane smoke turns take 2-3 ms, where +50% is scheduler noise, not a regression.
    static let minFlaggedDeltaMs: Double = 50

    static func compare(baseline: PerfRunRecord, current: PerfRunRecord, threshold: Double) -> PerfComparison {
        if baseline.environment.provider != current.environment.provider {
            return PerfComparison(refusal: "provider differs: \(baseline.environment.provider) vs \(current.environment.provider)", rows: [])
        }
        if baseline.environment.toolSandbox != current.environment.toolSandbox {
            return PerfComparison(refusal: "tool sandbox mode differs: \(baseline.environment.toolSandbox ?? "unrecorded") vs \(current.environment.toolSandbox ?? "unrecorded")", rows: [])
        }
        if baseline.environment.models != current.environment.models {
            return PerfComparison(refusal: "model names differ: \(baseline.environment.models) vs \(current.environment.models)", rows: [])
        }
        var rows: [PerfComparison.Row] = []
        // Decided once, at the record level, not inferred per call: Gemini omits
        // `cachedContentTokenCount` on a cache miss, so a post-5a Gemini run with no hit would
        // read as pre-5a under per-call inference (5a review F2).
        let baselineHasCacheCounts = baseline.cacheCountsVersion != nil
        let currentHasCacheCounts = current.cacheCountsVersion != nil
        let bothHaveCacheCounts = baselineHasCacheCounts && currentHasCacheCounts
        let straddledCacheCounts = baselineHasCacheCounts != currentHasCacheCounts
        func row(_ scenario: String, _ rung: Int?, _ metric: String, _ a: Double, _ b: Double, informational: Bool = false) {
            let change = PerfStats.percentChange(from: a, to: b)
            let pastFloor = metric != "median ms" || (b - a) >= minFlaggedDeltaMs
            rows.append(.init(scenario: scenario, rung: rung, metric: metric, before: a, after: b,
                              change: change, flagged: !informational && (change ?? 0) > threshold && pastFloor))
        }
        for cur in current.scenarios {
            guard let base = baseline.scenarios.first(where: { $0.name == cur.name }) else { continue }
            for r in cur.rungs {
                guard let br = base.rungs.first(where: { $0.rung == r.rung }) else { continue }
                let okBefore = br.repetitions.filter { $0.error == nil }.count
                let okAfter = r.repetitions.filter { $0.error == nil }.count
                // A rung with zero successful repetitions has medianMs == 0, which reads as a
                // -100% change and never trips the threshold. Flag the loss of coverage directly
                // instead, and skip the median/token rows since they would be meaningless.
                if okAfter == 0 {
                    rows.append(.init(scenario: cur.name, rung: r.rung, metric: "successful repetitions",
                                      before: Double(okBefore), after: 0, change: -1.0,
                                      // A rung that was already broken in the baseline must not
                                      // fail every future gate.
                                      flagged: okBefore > 0))
                    continue
                }
                row(cur.name, r.rung, "median ms", br.medianMs, r.medianMs)
                // "prompt tokens" is always the flagging size metric the gate exists for (5a
                // review F1): a regression inside the cached prefix must still show up here even
                // when the uncached count doesn't move. When both records are marked with cache
                // counts, "uncached prompt tokens" is also emitted, informational only — it swings
                // with cache warmth (cold vs warm TTL), not with what is sent, so it must never
                // flag by itself. When the two records straddle the cache-count change (only one
                // side marked), "prompt tokens" rises by the cached portion across the boundary;
                // that row stays informational too, and a note explains why (5a review F2/F3).
                if let bt = medianPromptTokens(br), let ct = medianPromptTokens(r) {
                    row(cur.name, r.rung, "prompt tokens", bt, ct, informational: straddledCacheCounts)
                }
                if bothHaveCacheCounts, let bt = medianUncachedTokens(br), let ct = medianUncachedTokens(r) {
                    row(cur.name, r.rung, "uncached prompt tokens", bt, ct, informational: true)
                }
            }
            if let a = base.summary.overheadRatio, let b = cur.summary.overheadRatio {
                row(cur.name, nil, "overhead ratio", a, b)
            }
        }
        let notes = straddledCacheCounts
            ? ["baseline and current straddle the 5a cache-count change: one side reports cache counts and the other doesn't, so the prompt-token row is informational only."]
            : []
        return PerfComparison(refusal: nil, rows: rows, notes: notes)
    }

    static func render(_ c: PerfComparison, threshold: Double) -> String {
        if let refusal = c.refusal { return "cannot compare: \(refusal)" }
        var out = ["| scenario | rung | metric | before | after | change |", "|---|---|---|---|---|---|"]
        for r in c.rows {
            let change = r.change.map { String(format: "%+.1f%%", $0 * 100) } ?? "n/a"
            out.append("| \(r.scenario) | \(r.rung.map(String.init) ?? "-") | \(r.metric) | \(short(r.before)) | \(short(r.after)) | \(change)\(r.flagged ? " REGRESSION" : "") |")
        }
        out.append("")
        for note in c.notes { out.append("note: \(note)") }
        out.append(c.flagged.isEmpty ? "no regressions past threshold \(Int(threshold * 100))%"
                                     : "\(c.flagged.count) regression(s) past threshold \(Int(threshold * 100))%")
        return out.joined(separator: "\n")
    }

    static func exitCode(_ c: PerfComparison) -> Int32 {
        if c.refusal != nil { return 2 }
        return c.flagged.isEmpty ? 0 : 1
    }

    private static func medianPromptTokens(_ r: PerfRungResult) -> Double? {
        let tokens = PerfReport.calls(r).compactMap(\.promptTokens).map(Double.init)
        return PerfStats.median(tokens)
    }

    private static func medianUncachedTokens(_ r: PerfRungResult) -> Double? {
        let tokens = PerfReport.calls(r).compactMap(PerfReport.uncachedTokens)
        return PerfStats.median(tokens)
    }

    private static func short(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
