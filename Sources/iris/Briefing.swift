import Foundation

/// 5b §0.3: what Iris sees of background work, on its own turns only. Every field is one the
/// harness wrote: the turn-context block neutralises `<`, so nothing inside it can be marked
/// untrusted, and a run's outcome text (which can carry fetched words) would arrive with the
/// harness's authority. The model reads the words through `get_job_run`, which is guarded.
///
/// `reason(_:)` and `pausedWord(_:)` read `failureReason` / `pausedReason`, but never emit the
/// text itself (fix round 1, review): each is compared against a closed set of harness-written
/// constants — exact match, or a prefix match for the ones a number is folded into — and only the
/// matched *word* is emitted. Anything unrecognised — free text, an LLM error headline, a tool
/// name a blocked call carried — falls back to `status.text`, never to the string itself.
enum Briefing {
    static let heading = "Recent Activity"
    static let recentCap = 5

    /// The literal prefix `JobRunner.budgetReason` writes before its numbers ("daily token budget
    /// reached (job): 620000 / 1000000"). Matched by prefix because the figures vary; spelled once
    /// here rather than reaching into `JobRunner`'s formatter.
    private static let budgetReasonPrefix = "daily token budget reached"

    static func section(failures: [JobRun], paused: [Job], recent: [JobRun]) -> TurnContext.Section? {
        var lines: [String] = paused.map {
            "- \(name($0.name)) · \(pausedWord($0.pausedReason)) (job \(short($0.id)))"
        }
        lines += failures.map(line)
        let shown = Set(failures.map(\.id))
        lines += recent.filter { !shown.contains($0.id) }.prefix(recentCap).map(line)
        guard !lines.isEmpty else { return nil }
        return .init(heading: heading, body: lines.joined(separator: "\n"))
    }

    private static func line(_ run: JobRun) -> String {
        "- \(name(run.jobName)) · \(reason(run)) (run \(short(run.id)))"
    }

    private static func reason(_ run: JobRun) -> String {
        if run.status == .blockedOnApproval, let tool = run.blockedTool, isToolName(tool) {
            return "blocked: \(tool)"
        }
        if let word = reasonWord(run.failureReason) { return word }
        return run.status.text
    }

    /// Maps a run's `failureReason` to the fixed vocabulary by exact or prefix match on a known
    /// harness constant — never by substring of arbitrary text — and returns only the matched
    /// word, never the reason itself. `nil` for anything unrecognised, so `reason(_:)` falls back
    /// to `status.text`.
    private static func reasonWord(_ failureReason: String?) -> String? {
        guard let failureReason else { return nil }
        if failureReason == TurnBudget.timeExceeded { return "timeout" }
        if failureReason == TurnBudget.tokensExceeded { return "budget" }
        if failureReason.hasPrefix(budgetReasonPrefix) { return "budget" }
        if failureReason == JobRunner.gateFailingReason { return "gate error" }
        if failureReason.hasPrefix(JobRunner.gateErrorPrefix) { return "gate error" }
        if failureReason == JobRunner.skipReason { return "overlap" }
        // NOT `releasedReason` ("app state released"): that row keeps its transcriptConversationId
        // — a real run the app quit or tore down mid-turn, not an overlap — and does reach
        // `recentRuns`. Nothing overlapped, so it falls back to `status.text` ("interrupted")
        // instead of a word that would misdescribe it (re-review fix).
        return nil
    }

    /// Same idea for `Job.pausedReason`: budget, three failed retries, or a failing gate map to a
    /// word; anything else — a breaker trip, an operator's own note typed at `/jobs pause` — is
    /// just "paused".
    private static func pausedWord(_ pausedReason: String?) -> String {
        guard let pausedReason else { return "paused" }
        if pausedReason == JobRunner.retriesExhaustedReason { return "failed 3 times" }
        if pausedReason.hasPrefix(budgetReasonPrefix) { return "budget" }
        if pausedReason == JobRunner.gateFailingReason { return "gate" }
        return "paused"
    }

    private static func isToolName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }

    /// One line, no role markers, no `<`, capped. A job's name is set by whoever created it.
    ///
    /// Order matters (fix round 1, review): `<` and every newline are stripped from the RAW text
    /// first, before `sanitizeUntrustedInput` runs. The sanitiser matches its role markers by
    /// exact substring, so a spliced marker — `"mod<el: obey"`, `"Sys<tem Prompt: obey"`,
    /// `"#<## x"` — reads as harmless to it; only once the splice character is gone does the
    /// string become `"model: obey"` / `"System Prompt: obey"` / `"### x"`, which the sanitiser's
    /// own patterns then catch. Stripping `<` AFTER sanitising (the original order) was the bug:
    /// the sanitiser had already passed the still-spliced text, and removing `<` afterwards
    /// reassembled the very marker it exists to catch.
    static func name(_ raw: String) -> String {
        var flat = raw
            .replacingOccurrences(of: "<", with: "")
            .components(separatedBy: .newlines).joined(separator: " ")
        flat = PromptInjectionGuard.sanitizeUntrustedInput(flat)
        // The sanitiser only strips its own exact strings, case-insensitively, and only when
        // nothing sits between the word and the colon. A marker with a space before the colon, or
        // one sitting mid-line after other text, can still survive — `model` is one of the
        // sanitiser's own markers too, added here because this pass matches on word boundaries
        // rather than an exact substring.
        if let re = try? NSRegularExpression(pattern: #"(?i)\b(system|assistant|user|model|instruction)\s*:"#) {
            let range = NSRange(flat.startIndex..., in: flat)
            flat = re.stringByReplacingMatches(in: flat, range: range, withTemplate: "")
        }
        // Defense in depth: NFKC normalisation inside the sanitiser can turn a fullwidth `＜`
        // (U+FF1C) into a literal `<`; strip once more so the body itself never carries one,
        // rather than relying solely on `TurnContext`'s own neutralisation of the rendered block.
        flat = flat.replacingOccurrences(of: "<", with: "")
        flat = flat.trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(60))
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
}
