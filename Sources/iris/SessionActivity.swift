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

    /// What the session is doing right now. `.executing`'s `detail` is derived from the tool's
    /// arguments by `SessionActivity.detail(tool:args:)` — never model-written prose — so the
    /// strip cannot be made to display arbitrary text a model chose.
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
            guard let path = stringArg(args, "path") else { return truncate(firstStringArg(args)) }
            return truncate(lastTwoComponents(of: path))
        case "search_memory":
            return truncate(stringArg(args, "query"))
        case "invoke_subagent", "delegate_milestone":
            return truncate(stringArg(args, "role"))
        default:
            return truncate(firstStringArg(args))
        }
    }

    private static func stringArg(_ args: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    /// The first string-valued argument, in a deterministic (sorted-key) order — `[String:
    /// JSONValue]` has no stable iteration order, and a flaky fallback would make this
    /// non-reproducible in tests and on screen.
    private static func firstStringArg(_ args: [String: JSONValue]) -> String? {
        for key in args.keys.sorted() {
            if case .string(let s)? = args[key] { return s }
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
        case ..<1_000_000:
            return "\(trimmed(Double(n) / 1_000))k"
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

    /// A fixed elapsed duration for a finished row (a running row uses `Text(timerInterval:)`
    /// instead, which ticks on its own).
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return minutes > 0 ? "\(minutes)m \(String(format: "%02d", secs))s" : "\(secs)s"
    }
}
