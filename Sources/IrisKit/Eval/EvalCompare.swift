import Foundation

/// `iris --eval compare`: two results, metric by metric, refusing any pair whose version keys
/// differ in a part it wasn't told is meant to differ (spec, section 9).
enum EvalCompare {
    /// The version-key parts that differ, by the names `--vary` takes.
    static func differences(_ a: EvalResult.VersionKey, _ b: EvalResult.VersionKey) -> Set<String> {
        var d: Set<String> = []
        if a.task != b.task { d.insert("task") }
        if a.configuration != b.configuration { d.insert("configuration") }
        if a.scoringVersion != b.scoringVersion { d.insert("scoring") }
        if a.model != b.model || a.modelFingerprint != b.modelFingerprint { d.insert("model") }
        if a.runtime != b.runtime || a.runtimeVersion != b.runtimeVersion { d.insert("runtime") }
        if a.datasetFamily != b.datasetFamily || a.datasetVersion != b.datasetVersion || a.datasetSha256 != b.datasetSha256 { d.insert("dataset") }
        if a.split != b.split { d.insert("split") }
        if a.sample != b.sample { d.insert("sample") }
        if a.think != b.think { d.insert("think") }
        if (a.repeats ?? 1) != (b.repeats ?? 1) { d.insert("repeats") }
        return d
    }

    /// Task, configuration and scoring version never vary: across them, a number means something else.
    static func check(_ a: EvalResult, _ b: EvalResult, vary: Set<String>) throws {
        let d = differences(a.key, b.key)
        let never = d.intersection(["task", "configuration", "scoring"])
        guard never.isEmpty else { throw EvalError.incomparable("\(never.sorted().joined(separator: ", ")) differ; those never compare") }
        let unexpected = d.subtracting(vary)
        guard unexpected.isEmpty else {
            throw EvalError.incomparable("\(unexpected.sorted().joined(separator: ", ")) differ; pass --vary \(unexpected.sorted().joined(separator: ",")) if that's the point")
        }
    }

    static func render(_ a: EvalResult, _ b: EvalResult, vary: Set<String>) throws -> String {
        try check(a, b, vary: vary)
        var out = ["\(a.key.task) [\(a.key.configuration)]: \(label(a)) → \(label(b))", ""]
        func pct(_ r: EvalResult.Rate?) -> String { r?.rate.map { String(format: "%.1f%%", $0 * 100) + " (\(r!.hits)/\(r!.n))" } ?? "n/a" }
        func line(_ name: String, _ x: EvalResult.Rate?, _ y: EvalResult.Rate?) {
            var delta = ""
            if let p = x?.rate, let q = y?.rate { delta = String(format: "  %+.1f pts", (q - p) * 100) }
            out.append("\(name): \(pct(x)) → \(pct(y))\(delta)")
        }
        line("false positives", a.metrics.falsePositives, b.metrics.falsePositives)
        line("recall", a.metrics.recall, b.metrics.recall)
        if a.metrics.clean != nil || b.metrics.clean != nil {
            line("clean texts' false positives", a.metrics.clean?.falsePositives, b.metrics.clean?.falsePositives)
            line("clean texts' recall", a.metrics.clean?.recall, b.metrics.clean?.recall)
        }
        if a.metrics.freshRecall != nil || b.metrics.freshRecall != nil {
            line("fresh attacks' recall", a.metrics.freshRecall, b.metrics.freshRecall)
        }
        out.append("ROC-AUC: \(num(a.metrics.rocAuc)) → \(num(b.metrics.rocAuc))")
        out.append("fail-closed: \(a.metrics.failClosed) → \(b.metrics.failClosed); infra: \(a.metrics.infra) → \(b.metrics.infra)")
        if let x = a.metrics.passes, let y = b.metrics.passes { out.append("bar: \(x ? "pass" : "fail") → \(y ? "pass" : "fail")") }
        if a.metrics.agreement != nil || b.metrics.agreement != nil {
            line("agreement across repeats", a.metrics.agreement, b.metrics.agreement)
        }
        if a.metrics.parseFailures != nil || b.metrics.parseFailures != nil {
            out.append("parse failures: \(a.metrics.parseFailures.map(String.init) ?? "n/a") → \(b.metrics.parseFailures.map(String.init) ?? "n/a")")
        }
        out += ["", "by category:"]
        for c in Set(a.metrics.falsePositivesByCategory.keys).union(b.metrics.falsePositivesByCategory.keys).sorted() {
            line("  benign \(c)", a.metrics.falsePositivesByCategory[c], b.metrics.falsePositivesByCategory[c])
        }
        for c in Set(a.metrics.recallByCategory.keys).union(b.metrics.recallByCategory.keys).sorted() {
            line("  attack \(c)", a.metrics.recallByCategory[c], b.metrics.recallByCategory[c])
        }
        out += ["", "by size:"]
        for upper in EvalMetrics.sizeBands {
            let x = a.metrics.bySize.first { $0.maxBytes == upper }, y = b.metrics.bySize.first { $0.maxBytes == upper }
            guard x != nil || y != nil else { continue }
            line("  ≤\(bytes(upper)) FP", x?.falsePositives, y?.falsePositives)
            line("  ≤\(bytes(upper)) recall", x?.recall, y?.recall)
        }
        let flips = flipped(a, b)
        out += ["", "attacks caught → missed: " + (flips.lost.isEmpty ? "none" : flips.lost.joined(separator: ", ")),
                "attacks missed → caught: " + (flips.gained.isEmpty ? "none" : flips.gained.joined(separator: ", "))]
        if !flips.unstable.isEmpty {
            out.append("left out of the flips, judged differently across a result's own repeats: " + flips.unstable.joined(separator: ", "))
        }
        if (a.key.repeats ?? 1) > 1 || (b.key.repeats ?? 1) > 1 {
            out += ["", "margin rule (spec §9): a difference is real only if it moves by at least \(minStableTexts) stable texts "
                    + "and by more than twice the larger of the two results' repeat spreads."]
            out += margin(a, b).map { "  " + $0 }
        }
        return out.joined(separator: "\n")
    }

    /// The stable-text movement the margin rule asks for (spec, section 9).
    static let minStableTexts = 2

    /// The range of the per-repeat rates; nil when none were recorded or none had a rate.
    static func spread(_ perRepeat: [EvalResult.Rate]?) -> Double? {
        guard let rates = perRepeat?.compactMap(\.rate), !rates.isEmpty else { return nil }
        return rates.max()! - rates.min()!
    }

    /// Texts judged and stable (the same flagged state in every judgement) in both results whose
    /// state changed: how many became flagged, and how many stopped being flagged. `attacks`
    /// picks which side of the dataset.
    static func stableMovement(_ a: EvalResult, _ b: EvalResult, attacks: Bool) -> (up: Int, down: Int) {
        func stable(_ r: EvalResult) -> [String: Bool] {
            var seen: [String: Set<Bool>] = [:]
            for v in r.verdicts where v.outcome != EvalMetrics.Outcome.infra.rawValue && v.outcome != EvalMetrics.Outcome.failClosed.rawValue {
                // An attack is flagged when caught; a benign text when anything but passed.
                if attacks, let c = v.caught { seen[v.id, default: []].insert(c) }
                else if !attacks, v.caught == nil { seen[v.id, default: []].insert(v.outcome != EvalMetrics.Outcome.passed.rawValue) }
            }
            return seen.filter { $0.value.count == 1 }.mapValues { $0.first! }
        }
        let before = stable(a), after = stable(b)
        var up = 0, down = 0
        for (id, now) in after {
            guard let then = before[id], then != now else { continue }
            if now { up += 1 } else { down += 1 }
        }
        return (up, down)
    }

    /// One line per aggregate: whether its difference clears the margin rule, and why or why not.
    static func margin(_ a: EvalResult, _ b: EvalResult) -> [String] {
        func pts(_ x: Double) -> String { String(format: "%.1f pts", x * 100) }
        func verdict(_ name: String, _ x: EvalResult.Rate, _ y: EvalResult.Rate, _ ax: [EvalResult.Rate]?, _ bx: [EvalResult.Rate]?,
                     attacks: Bool) -> String {
            guard let p = x.rate, let q = y.rate else { return "\(name): n/a, nothing judged on one side" }
            let delta = q - p
            let moved = stableMovement(a, b, attacks: attacks)
            // Recall moves up when attacks are caught; a false-positive rate moves up when more texts are flagged.
            let net = moved.up - moved.down
            let texts = "\(abs(net)) stable text\(abs(net) == 1 ? "" : "s") net (\(moved.up) up, \(moved.down) down)"
            guard let sa = spread(ax), let sb = spread(bx) else {
                let missing = [spread(ax) == nil ? "first" : nil, spread(bx) == nil ? "second" : nil].compactMap { $0 }.joined(separator: " and ")
                return "\(name): moved \(pts(delta)), \(texts); no spread recorded in the \(missing) result, so no verdict"
            }
            let limit = 2 * max(sa, sb)
            // The stable texts must move the way the aggregate does: unstable texts can carry an
            // aggregate one way while the stable ones go the other (#842 review).
            let enough = abs(net) >= minStableTexts, clear = abs(delta) > limit
            let sameWay = (net > 0) == (delta > 0)
            let why = "moved \(pts(delta)) and \(texts) (needs \(minStableTexts)); spreads \(pts(sa)) and \(pts(sb)), so it must move by more than \(pts(limit))"
            let opposite = enough && clear && !sameWay ? "; the stable texts moved the other way from the aggregate" : ""
            return "\(name): " + (enough && clear && sameWay ? "REAL, " : "not shown, ") + why + opposite
        }
        return [verdict("false positives", a.metrics.falsePositives, b.metrics.falsePositives,
                        a.metrics.falsePositivesByRepeat, b.metrics.falsePositivesByRepeat, attacks: false),
                verdict("recall", a.metrics.recall, b.metrics.recall, a.metrics.recallByRepeat, b.metrics.recallByRepeat, attacks: true)]
    }

    /// Each attack's caught flag where every judgement of it agreed, and the ids where they didn't.
    static func stableCaught(_ r: EvalResult) -> (stable: [String: Bool], unstable: Set<String>) {
        var seen: [String: Set<Bool>] = [:]
        for v in r.verdicts where v.outcome != EvalMetrics.Outcome.infra.rawValue {
            if let c = v.caught { seen[v.id, default: []].insert(c) }
        }
        var stable: [String: Bool] = [:], unstable: Set<String> = []
        for (id, values) in seen {
            if values.count == 1 { stable[id] = values.first! } else { unstable.insert(id) }
        }
        return (stable, unstable)
    }

    /// Attacks scored in both whose caught flag changed, by id, among those stable in both: an
    /// attack judged differently across either result's repeats is listed apart (spec, section 9).
    static func flipped(_ a: EvalResult, _ b: EvalResult) -> (lost: [String], gained: [String], unstable: [String]) {
        let before = stableCaught(a), after = stableCaught(b)
        var lost: [String] = [], gained: [String] = []
        for (id, now) in after.stable {
            guard let then = before.stable[id], now != then else { continue }
            if then { lost.append(id) } else { gained.append(id) }
        }
        let both = Set(before.stable.keys).union(before.unstable).intersection(Set(after.stable.keys).union(after.unstable))
        return (lost.sorted(), gained.sorted(), before.unstable.union(after.unstable).intersection(both).sorted())
    }

    static func summary(_ r: EvalResult) -> String {
        func pct(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
        var s = "\(r.key.task) \(label(r)): FP \(pct(r.metrics.falsePositives.rate)) of \(r.metrics.falsePositives.n), "
            + "recall \(pct(r.metrics.recall.rate)) of \(r.metrics.recall.n), ROC-AUC \(num(r.metrics.rocAuc))"
        if let f = r.metrics.freshRecall { s += ", fresh recall \(pct(f.rate)) of \(f.n)" }
        if let a = r.metrics.agreement { s += ", agreement \(pct(a.rate)) of \(a.n) texts" }
        if let p = r.metrics.passes { s += ", bar \(p ? "PASS" : "FAIL")" }
        if r.metrics.failClosed + r.metrics.infra > 0 { s += ", fail-closed \(r.metrics.failClosed), infra \(r.metrics.infra)" }
        return s
    }

    static func label(_ r: EvalResult) -> String {
        "\(r.key.runtime):\(r.key.model) (\(String(r.key.modelFingerprint.suffix(8))))" + (r.key.think.map { " think \($0)" } ?? "")
            + " on \(r.key.datasetFamily) v\(r.key.datasetVersion) \(r.key.split)"
            + (r.key.sample.map { " s\($0)" } ?? " full") + (r.key.repeats.map { $0 > 1 ? " ×\($0)" : "" } ?? "") + ", \(r.date)"
    }

    static func num(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "n/a" }

    static func bytes(_ n: Int) -> String { n == Int.max ? "any size" : n >= 1024 ? "\(n / 1024) KB" : "\(n) B" }
}

/// `iris --eval table`: `docs/evals.md`, generated from every committed result, never hand-edited.
enum EvalTable {
    struct Loaded: Sendable {
        var file: String
        var result: EvalResult
    }

    static func load(_ resultsRoot: URL) throws -> [Loaded] {
        guard let walker = FileManager.default.enumerator(at: resultsRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [Loaded] = []
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            out.append(.init(file: url.lastPathComponent, result: try EvalResult.decode(Data(contentsOf: url))))
        }
        return out.sorted { ($0.result.key.task, $0.result.date, $0.file) < ($1.result.key.task, $1.result.date, $1.file) }
    }

    static func render(_ results: [Loaded]) -> String {
        func pct(_ r: EvalResult.Rate) -> String { r.rate.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
        var out = ["# Model evals",
                   "",
                   "<!-- Generated by `iris --eval table` from eval/results/. Don't edit by hand: rerun it. -->",
                   "",
                   "How these are made, and the rules for comparing them: [the spec](specs/2026-10-28-model-eval-framework.md). "
                   + "Run one with `iris --eval run` ([building.md](building.md#model-evals---eval)). "
                   + "Bars: false positives ≤ 2% and recall ≥ 80% on a full `test` split; a sample or `dev` run isn't graded. "
                   + "\"n/a\" means not measured, never zero."]
        for (task, rows) in Dictionary(grouping: results, by: \.result.key.task).sorted(by: { $0.key < $1.key }) {
            out += ["", "## \(task)", "",
                    "| Date | Model | Fingerprint | Config | Dataset | Texts | FP | Recall | ROC-AUC | Benign max / attack min | Bar | Notes | File |",
                    "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
            for row in rows {
                let r = row.result, m = r.metrics
                var notes: [String] = []
                if let c = r.contaminated { notes.append("contaminated: \(c)") }
                if let c = m.clean {
                    notes.append("clean texts: FP \(c.falsePositives.map(pct) ?? "n/a"), recall \(c.recall.map(pct) ?? "n/a")")
                }
                if let f = m.freshRecall { notes.append("fresh attacks' recall \(pct(f)) of \(f.n)") }
                if r.modelChanged == true { notes.append("model changed") }
                if m.failClosed > 0 { notes.append("fail-closed \(m.failClosed)") }
                if m.infra > 0 { notes.append("infra \(m.infra)") }
                if let t = r.key.think { notes.append("think \(t)") }
                if let a = m.agreement { notes.append("agreement \(pct(a)) of \(a.n), \(m.unstable?.count ?? 0) unstable") }
                if let p = m.parseFailures, p > 0 { notes.append("parse failures \(p)") }
                if r.environment.onBattery == true { notes.append("on battery") }
                let texts = "\(r.key.split) " + (r.key.sample.map { "s\($0)" } ?? "full") + (r.key.repeats.map { $0 > 1 ? " ×\($0)" : "" } ?? "")
                let sep = "\(EvalCompare.num(m.highestBenignScore)) / \(EvalCompare.num(m.lowestAttackScore))"
                let bar = m.passes.map { $0 ? "pass" : "**fail**" } ?? "n/a"
                out.append("| \(r.date) | \(r.key.runtime):\(r.key.model) | `\(r.key.modelFingerprint.suffix(12))` | \(r.key.configuration) | "
                           + "\(r.key.datasetFamily) v\(r.key.datasetVersion) | \(texts) | \(pct(m.falsePositives)) | \(pct(m.recall)) | "
                           + "\(EvalCompare.num(m.rocAuc)) | \(sep) | \(bar) | \(notes.joined(separator: "; ")) | `\(row.file)` |")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
