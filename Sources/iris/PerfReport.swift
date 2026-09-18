import Foundation

/// Renders a run record as Markdown for the terminal and for pasting into a review.
enum PerfReport {
    static func render(_ r: PerfRunRecord) -> String {
        var out: [String] = []
        let env = r.environment
        out.append("# perf: \(r.suite)")
        out.append("")
        out.append("- when: \(iso(r.startedAt)) (\(fmt((r.finishedAt.timeIntervalSince(r.startedAt)) * 1000)) ms total)")
        out.append("- commit: \(env.gitSha)\(env.gitDirty ? " (dirty)" : "")  build: \(env.buildConfiguration)")
        out.append("- machine: \(env.machineModel), macOS \(env.osVersion), \(env.cpuCount) cores")
        out.append("- provider: \(env.provider)  models: " + env.models.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        out.append("- guards: vibecop \(env.vibecopEnabled ? "on (\(env.vibecopEngine))" : "off"), injection guard \(env.injectionGuardEnabled ? "on (\(env.promptGuardEngine))" : "off"), sandbox \(env.sandboxEnabled ? "on" : "off"), headless \(env.headless)")
        if let n = env.toolDeclarationCount { out.append("- tool declarations sent per call: \(n)") }
        if env.buildConfiguration == "debug" { out.append("- WARNING: debug build; timings are not comparable to release runs") }
        if env.gitDirty { out.append("- WARNING: dirty tree; the sha does not describe this code") }
        out.append("")

        for s in r.scenarios {
            out.append("## \(s.name)  (\(s.category), \(s.lane))")
            out.append("")
            out.append("| rung | n | median ms | p90 ms | prompt tokens | failed |")
            out.append("|---|---|---|---|---|---|")
            for rung in s.rungs {
                let ok = rung.repetitions.filter { $0.error == nil }
                let failed = rung.repetitions.count - ok.count
                let tokens = PerfStats.median(ok.flatMap { rep in (rep.modelCalls + rep.turns.flatMap(\.modelCalls)).compactMap { $0.promptTokens }.map(Double.init) })
                out.append("| \(rung.rung) | \(ok.count) | \(fmt(rung.medianMs)) | \(fmt(rung.p90Ms)) | \(tokens.map { String(Int($0)) } ?? "-") | \(failed > 0 ? "\(failed) failed" : "-") |")
            }
            out.append("")
            var ratios: [String] = []
            if let o = s.summary.overheadRatio { ratios.append("overhead \(String(format: "%.2f", o))x") }
            if let h = s.summary.harnessRatio { ratios.append("harness \(String(format: "%.2f", h))x") }
            if !ratios.isEmpty { out.append("- ratios vs bare call: " + ratios.joined(separator: ", ")) }
            let spans = topSpans(s)
            if !spans.isEmpty { out.append("- top spans (rung \(s.rungs.map { $0.rung }.max() ?? 0), summed): " + spans.map { "\($0.0) \(fmt($0.1)) ms" }.joined(separator: ", ")) }
            if !s.summary.toolCallsByName.isEmpty || s.summary.toolCallRate > 0 {
                out.append("- tool-call rate \(Int((s.summary.toolCallRate * 100).rounded()))%: " + s.summary.toolCallsByName.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
            }
            if let rate = s.summary.unexpectedToolCallRate {
                let names = (s.summary.unexpectedToolCallsByName ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                out.append("- unexpected tool-call rate \(Int((rate * 100).rounded()))%: \(names.isEmpty ? "none" : names)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func topSpans(_ s: PerfScenarioResult) -> [(String, Double)] {
        guard let top = s.rungs.max(by: { $0.rung < $1.rung }) else { return [] }
        var sum: [String: Double] = [:]
        for span in top.repetitions.flatMap(\.turns).flatMap({ $0.spans }) { sum[span.key, default: 0] += span.value.ms }
        return sum.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    private static func fmt(_ ms: Double) -> String { String(format: "%.1f", ms) }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); return f.string(from: d)
    }
}
