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
        out.append("ROC-AUC: \(num(a.metrics.rocAuc)) → \(num(b.metrics.rocAuc))")
        out.append("fail-closed: \(a.metrics.failClosed) → \(b.metrics.failClosed); infra: \(a.metrics.infra) → \(b.metrics.infra)")
        if let x = a.metrics.passes, let y = b.metrics.passes { out.append("bar: \(x ? "pass" : "fail") → \(y ? "pass" : "fail")") }
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
        return out.joined(separator: "\n")
    }

    /// Attacks scored in both whose caught flag changed, by id.
    static func flipped(_ a: EvalResult, _ b: EvalResult) -> (lost: [String], gained: [String]) {
        let before = Dictionary(uniqueKeysWithValues: a.verdicts.compactMap { v in v.caught.map { (v.id, $0) } })
        var lost: [String] = [], gained: [String] = []
        for v in b.verdicts {
            guard let now = v.caught, let then = before[v.id], now != then else { continue }
            if then { lost.append(v.id) } else { gained.append(v.id) }
        }
        return (lost.sorted(), gained.sorted())
    }

    static func summary(_ r: EvalResult) -> String {
        func pct(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
        var s = "\(r.key.task) \(label(r)): FP \(pct(r.metrics.falsePositives.rate)) of \(r.metrics.falsePositives.n), "
            + "recall \(pct(r.metrics.recall.rate)) of \(r.metrics.recall.n), ROC-AUC \(num(r.metrics.rocAuc))"
        if let p = r.metrics.passes { s += ", bar \(p ? "PASS" : "FAIL")" }
        if r.metrics.failClosed + r.metrics.infra > 0 { s += ", fail-closed \(r.metrics.failClosed), infra \(r.metrics.infra)" }
        return s
    }

    static func label(_ r: EvalResult) -> String {
        "\(r.key.runtime):\(r.key.model) (\(String(r.key.modelFingerprint.suffix(8)))) on \(r.key.datasetFamily) v\(r.key.datasetVersion) \(r.key.split)"
            + (r.key.sample.map { " s\($0)" } ?? " full") + ", \(r.date)"
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
                if r.modelChanged == true { notes.append("model changed") }
                if m.failClosed > 0 { notes.append("fail-closed \(m.failClosed)") }
                if m.infra > 0 { notes.append("infra \(m.infra)") }
                if r.environment.onBattery == true { notes.append("on battery") }
                let texts = "\(r.key.split) " + (r.key.sample.map { "s\($0)" } ?? "full")
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
