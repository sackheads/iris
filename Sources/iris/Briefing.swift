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

    /// `knownTools` defaults to the live declared surface so production call sites get it for
    /// free; tests pass their own set to keep this function pure and dependency-free.
    static func section(failures: [JobRun], paused: [Job], recent: [JobRun],
                        knownTools: Set<String> = IrisEngine.allDeclaredToolNames) -> TurnContext.Section? {
        var lines: [String] = paused.map {
            "- \(quoted($0.name)) · \(pausedWord($0.pausedReason)) (job \(short($0.id)))"
        }
        lines += failures.map { line($0, knownTools: knownTools) }
        let shown = Set(failures.map(\.id))
        lines += recent.filter { !shown.contains($0.id) }.prefix(recentCap).map { line($0, knownTools: knownTools) }
        guard !lines.isEmpty else { return nil }
        return .init(heading: heading, body: lines.joined(separator: "\n"))
    }

    private static func line(_ run: JobRun, knownTools: Set<String>) -> String {
        "- \(quoted(run.jobName)) · \(reason(run, knownTools: knownTools)) (run \(short(run.id)))"
    }

    /// A blocked run's `blockedTool` is a tool name the MODEL chose, not one the harness wrote —
    /// a well-formed but nonexistent name (hallucinated, or injected) must not reach the
    /// harness-authority turn context as `blocked: <name>` (#187 review). Checked against the real
    /// declared surface rather than a character-shape check: a plausible-looking fake tool name
    /// passes any character check that a real one would.
    private static func reason(_ run: JobRun, knownTools: Set<String>) -> String {
        if run.status == .blockedOnApproval, let tool = run.blockedTool, knownTools.contains(tool) {
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

    /// One line, no role markers, no `<`, capped in UTF-8 bytes. A job's name is set by whoever created it.
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
        var flat = IrisEngine.flattenHitLineField(raw.replacingOccurrences(of: "<", with: ""))
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
        // The line's own field separator and the quotes `quoted(_:)` wraps the name in: a name
        // like `c · failed 3 times (run deadbeef) · blocked: run_command` otherwise forges a
        // whole line's worth of harness fields (#187 review). Filtered by scalar, after the
        // sanitiser's NFKC pass, so neither a combining mark fused onto a `·` nor a compatibility
        // form that folds into one gets through.
        flat = String(String.UnicodeScalarView(flat.unicodeScalars.filter { !fieldDelimiters.contains($0) }))
        flat = flat.trimmingCharacters(in: .whitespaces)
        // Bytes, not `Character`s: one letter plus 50,000 combining marks is one Character of
        // ~100 KB, and this lands in the harness-authority turn context (#187 review).
        return ConversationReader.utf8Prefix(flat, maxBytes: nameMaxBytes)
    }

    /// 90 bytes: 90 ASCII characters, or 30 CJK ones — the old 60-Character cap would otherwise
    /// cut a short CJK name to 20.
    static let nameMaxBytes = 90

    /// `·` (U+00B7) and the dots that read as one: Greek ano teleia (folds to U+00B7), hyphenation
    /// point, bullet and dot operators, word-separator middle dot, katakana middle dot (and its
    /// halfwidth form), bullet. Then the curly double quotes the name is wrapped in, and the
    /// double-quote shapes that read as them.
    private static let fieldDelimiters: Set<Unicode.Scalar> = [
        "\u{00B7}", "\u{0387}", "\u{2027}", "\u{2219}", "\u{22C5}", "\u{2E31}", "\u{30FB}", "\u{FF65}", "\u{2022}",
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{2036}", "\u{301D}", "\u{301E}", "\u{301F}",
        "\u{FF02}",
    ]

    /// The name as one field: `name(_:)` strips `“` and `”`, so the closing quote here is always
    /// the real end of the name.
    static func quoted(_ raw: String) -> String { "\u{201C}\(name(raw))\u{201D}" }

    private static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
}
