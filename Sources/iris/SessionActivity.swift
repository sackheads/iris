import Foundation

/// One running or recently-finished session shown in `SessionStripView` (#217 + #19): the main
/// conversation plus any subagent/evaluator conversations currently in flight. Replaces
/// `ActiveSubagent`, which only tracked subagents and a coarse free-text status string.
struct SessionSummary: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case main
        case subagent
        case evaluator
    }
    /// `detail` is derived from the tool call's own arguments by `SessionActivity.detail(tool:args:)`.
    /// Those arguments are model-written (a `run_command` command, a `search_memory` query), so this
    /// is not a guarantee against model-chosen text; the guarantee is narrower: no body-bearing
    /// argument (file content, email body) is ever shown, the text is bounded to 60 characters, and
    /// it is prefixed by the tool name so it reads as a tool call, not as a message.
    enum Phase: Hashable, Sendable {
        case idle
        case thinking
        case executing(tool: String, detail: String?)
        case responding
        case finished(status: String, at: Date)
    }

    /// The tool name + detail last passed to `.executing`, kept even after the phase has moved on
    /// (to `.thinking`/`.responding`/`.finished`) so a test — or a future UI — can observe what a
    /// session most recently ran without racing the phase transition itself.
    struct LastActivity: Hashable, Sendable {
        let tool: String
        let detail: String?
    }

    let id: UUID              // conversation id
    let kind: Kind
    let role: String          // "main" for the main session, the subagent role otherwise
    let startTime: Date
    var phase: Phase
    var lastActivity: LastActivity?

    /// `startTime` while there is something to time, `nil` while `.idle` — an idle main session
    /// (the only kind that is ever `.idle`; subagents/evaluators start `.thinking`) has no turn in
    /// progress to show an elapsed time for. `AppState` derives `.idle` from `hasTurnInFlight`, not
    /// from whether a start is recorded (`beginEngineTurn`/`endEngineTurn` prune the per-
    /// conversation start on the way back to zero, but that pruning is a memory-hygiene cleanup,
    /// not what makes this `nil` — this checks `phase` alone). Fix round 1 (#217/#19): the row used
    /// to render a `Text(timerInterval:)` against a stale/placeholder start regardless of phase.
    var elapsedStartTime: Date? {
        if case .idle = phase { return nil }
        return startTime
    }
}

extension SessionSummary {
    /// Pure sweep: drops `.finished` entries older than `lingerWindow` relative to `now`. A pure
    /// function over the array (rather than a method that reads `Date()` itself) is what makes the
    /// 60s linger window testable without sleeping in a test.
    static func sweep(_ sessions: [SessionSummary], now: Date, lingerWindow: TimeInterval) -> [SessionSummary] {
        sessions.filter { session in
            guard case .finished(_, let at) = session.phase else { return true }
            return now.timeIntervalSince(at) < lingerWindow
        }
    }
}

/// Pure mappings the session strip renders from — no formatting logic lives in the SwiftUI layer,
/// so it is all testable without standing up a view.
enum SessionActivity {
    /// The activity text shown for an `.executing` phase, derived from the tool's own arguments —
    /// never anything the model wrote as free text. `nil` when the tool has no argument worth
    /// surfacing (e.g. a niladic tool).
    static func detail(tool: String, args: [String: JSONValue]) -> String? {
        switch tool {
        case "run_command":
            return truncate(stringArg(args, "command"))
        case "read_file", "write_file":
            // Fix round 1 (#217/#19): no fallback to the generic allowlist here. `write_file` also
            // carries a `content` argument, and — before this fix — a malformed call missing
            // `path` fell through to the sorted-key fallback, which happily surfaced up to 60
            // characters of file BODY on screen. No path, no detail.
            guard let path = stringArg(args, "path") else { return nil }
            return truncate(lastTwoComponents(of: path))
        case "search_memory":
            return truncate(stringArg(args, "query"))
        case "invoke_subagent", "delegate_milestone":
            return truncate(stringArg(args, "role"))
        default:
            return truncate(firstAllowlistedArg(args))
        }
    }

    private static func stringArg(_ args: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    /// Fix round 1 (#217/#19): the fallback used to be "the first string-valued argument in sorted
    /// key order", which put content-bearing keys like `body`/`content` in play whenever they
    /// happened to sort first (`create_skill`/`update_skill`'s `body`; `gmail_send_email`'s `body`
    /// sorting before `subject`). An explicit, ordered allowlist means an unrecognized tool can
    /// only ever surface one of these — never a free-text payload a model wrote.
    private static let fallbackKeyPriority = ["path", "query", "command", "role", "name", "title", "url", "subject", "id"]

    private static func firstAllowlistedArg(_ args: [String: JSONValue]) -> String? {
        for key in fallbackKeyPriority {
            if let value = stringArg(args, key) { return value }
        }
        return nil
    }

    private static func lastTwoComponents(of path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return components.joined(separator: "/") }
        return components.suffix(2).joined(separator: "/")
    }

    private static func truncate(_ s: String?, limit: Int = 60) -> String? {
        guard let s else { return nil }
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }

    /// `4.2k` / `210.9k` / `1.3M` — one decimal place, dropped when it would be `.0`. Below 1000
    /// the exact count is shown.
    static func formatTokenCount(_ n: Int) -> String {
        switch n {
        case ..<1_000:
            return "\(n)"
        case ..<999_500:
            return "\(trimmed(Double(n) / 1_000))k"
        case ..<1_000_000:
            // Fix round 1 (#217/#19): this range rounds up to 1.0M when expressed in k — without
            // this case it showed as the nonsensical "1000k". It's forced to keep one decimal
            // (rather than falling through to `trimmed`, which would collapse it to a bare "1M"
            // indistinguishable from an exact million) specifically because it is NOT a clean
            // million; the `default` case below still shows a bare "1M"/"2M" for one.
            return String(format: "%.1fM", Double(n) / 1_000_000)
        default:
            return "\(trimmed(Double(n) / 1_000_000))M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    /// `12s` / `1m 05s` / `1h 02m` — one format for both a running row (ticked via `TimelineView`,
    /// fix round 1) and a finished row's fixed duration, so the strip never shows two different
    /// elapsed-time styles side by side.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "\(minutes)m \(String(format: "%02d", secs))s" }
        return "\(secs)s"
    }

    /// The activity text for a phase — shared by a session's own row and the collapsed
    /// main-row summary, so both describe `.executing` etc. identically.
    static func activityText(for phase: SessionSummary.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .responding: return "responding"
        case .executing(let tool, let detail):
            guard let detail, !detail.isEmpty else { return tool }
            return "\(tool) \(detail)"
        case .finished(let status, _): return "finished · \(status)"
        }
    }

    /// Fix round 1 (#217/#19): while the strip is collapsed but subagent/evaluator sessions exist,
    /// the badge count used to be the ONLY sign of background work — exactly the visibility gap
    /// #19 asked to close. This summarizes what the expanded rows would show: `"2 subagents
    /// running"`, `"1 evaluator running"`, `"1 finished"`, or those joined, so the collapsed line
    /// still says something.
    /// `sessions` here is non-main entries only (`AppState.sessions`).
    static func collapsedSummary(for sessions: [SessionSummary]) -> String {
        let running = sessions.filter {
            if case .finished = $0.phase { return false }
            return true
        }
        // Evaluators are counted apart from subagents: `registerSubagent(kind:)` exists so the
        // strip can tell a grader run from a delegated unit of work, and the collapsed line is
        // part of the strip.
        let subagents = running.filter { $0.kind == .subagent }.count
        let evaluators = running.filter { $0.kind == .evaluator }.count
        let finished = sessions.count - running.count
        var parts: [String] = []
        if subagents > 0 { parts.append("\(subagents) subagent\(subagents == 1 ? "" : "s") running") }
        if evaluators > 0 { parts.append("\(evaluators) evaluator\(evaluators == 1 ? "" : "s") running") }
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.joined(separator: ", ")
    }
}
