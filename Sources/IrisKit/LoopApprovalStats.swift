import Foundation

/// #1425 step 0 (planner, 11-27): what an approval costs a loop, measured before unattended loop mode is built. One
/// line per gated call in a conversation with a loop: whether a loop tick made it, whether it was the owner's turn,
/// the call's shape (never its arguments), whether the conversation had read outside text, which layer decided it,
/// and, when the person was asked, how long the loop waited. Telemetry only: no decision reads it.
struct LoopApprovalRecord: Codable, Equatable, Sendable {
    /// Tells this line from a tick's (`LoopTickRecord`) in the shared log.
    var kind = "approval"
    var at: Date
    var conversationId: UUID
    var loopId: UUID
    /// A loop tick's turn, rather than one the owner typed or a peer's message started.
    var tick: Bool
    var ownerTurn: Bool
    var tool: String
    /// A command's Always-allow prefix (`swift test`), `exact` when it has none, or the tool name for any other tool.
    var shape: String
    var tainted: Bool
    /// What decided it: `person`, `yolo`, `allowlist-prefix`, `allowlist-exact`, `allowlist-directory`, `iris-home`, `vibecop`, `denied`, …
    var layer: String
    /// The person was shown the approval dialog for it.
    var asked: Bool
    /// Seconds the call waited on the dialog, sleep included: the loop was stuck that long either way.
    var waitSeconds: Double?
    var approved: Bool

    /// Never a path, an argument or a credential (planner, #1425): a file or MCP tool is its name alone, and a command
    /// its Always-allow prefixes, which a program spelled as a token, or a path other than a workspace script's, can't
    /// have. A prefix that still looks like a secret is logged as `exact`.
    static func shape(tool: String, details: String) -> String {
        guard tool == "run_command" else { return tool }
        guard let prefixes = CommandPattern.alwaysAllowPrefixes(details), !prefixes.isEmpty else { return "exact" }
        let shape = prefixes.map { $0.joined(separator: " ") }.joined(separator: " && ")
        return SecretLikeDetector.containsSecretLikeSubstring(shape) ? "exact" : shape
    }

    static func layer(_ source: AppState.ApprovalSource?, asked: Bool, held: Bool = false) -> String {
        switch source {
        case nil: return held ? "unattended-held" : asked ? "person-denied" : "denied"
        case .person: return "person"
        case .yolo: return "yolo"
        case .autoApprove: return "auto-approve"
        case .allowlist(let match):
            switch match.scope {
            case .irisHome: return "iris-home"
            case .global, .project:
                switch match.rule?.match {
                case .prefix?: return "allowlist-prefix"
                case .directory?: return "allowlist-directory"
                default: return "allowlist-exact"
                }
            }
        case .grant: return "grant"
        case .graderCheck: return "grader-check"
        case .vibecop, .vibecopRestricted: return "vibecop"
        }
    }
}

/// #1425 step 0 (planner, the Overseer's point): one line per loop tick with what it spent, for sizing the spend cap
/// and for #1437's cache study. The conversation's own counters' change across the tick: a subagent's spend is on its
/// own conversation and isn't counted. Counts only, no text.
struct LoopTickRecord: Codable, Equatable, Sendable {
    var kind = "tick"
    var at: Date
    var conversationId: UUID
    var loopId: UUID
    var seconds: Double
    var inputTokens: Int
    var outputTokens: Int
    /// nil while the provider has reported none in this conversation (unknown isn't zero, as in `TokenUsage`).
    var cacheReadTokens: Int?
    var cacheWrite5mTokens: Int?
    var cacheWrite1hTokens: Int?

    static func spent(from before: TokenUsage, to after: TokenUsage) -> (input: Int, output: Int, read: Int?, write5m: Int?, write1h: Int?) {
        func change(_ a: Int?, _ b: Int?) -> Int? { b.map { $0 - (a ?? 0) } }
        let write = change(before.cacheWriteTokenCount, after.cacheWriteTokenCount)
        let write1h = change(before.cacheWrite1hTokenCount, after.cacheWrite1hTokenCount)
        return (after.promptTokenCount - before.promptTokenCount, after.candidatesTokenCount - before.candidatesTokenCount,
                change(before.cacheReadTokenCount, after.cacheReadTokenCount), write.map { $0 - (write1h ?? 0) }, write1h)
    }
}

/// Carries a loop tick's mark and the dialog's wait from where they're known (`runLoopTick`, `enqueueUserApproval`)
/// to where the record is written (`requestApprovalSource`), across the awaits between, without a new parameter on
/// every caller. Task-local, so the tool calls a tick runs in parallel each see it, and nothing else does.
final class LoopApprovalProbe: @unchecked Sendable {
    @TaskLocal static var inLoopTick = false
    @TaskLocal static var current: LoopApprovalProbe?

    private let lock = NSLock()
    private var askedWait: Double?
    var asked: Bool { lock.withLock { askedWait != nil } }
    /// #1425: an unattended loop's turn held this call for the person (`AppState.recordUnattendedLoopDenial`), where an
    /// attended one would have asked: what #1425's numbers need told apart from a rule's or Vibecop's no.
    private var heldFlag = false
    var held: Bool { lock.withLock { heldFlag } }
    func noteHeld() { lock.withLock { heldFlag = true } }
    var waitSeconds: Double? { lock.withLock { askedWait } }
    func noteAsked(waited: Duration) {
        let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
        lock.withLock { askedWait = (askedWait ?? 0) + seconds }
    }

    /// The log's size past which it is moved to `loop-approvals.1.jsonl` (replacing an older one) and started afresh,
    /// so a loop that runs for weeks holds at most about twice this (planner, #1425).
    static let maxLogBytes = 5 * 1024 * 1024

    /// Appends one record (an approval's or a tick's) as a JSON line to `logs/loop-approvals.jsonl` in this build's home.
    static func appendToLog<Record: Encodable>(_ record: Record, paths: IrisPaths = .default, maxBytes: Int = maxLogBytes) {
        let dir = paths.root.appendingPathComponent("logs")
        let url = dir.appendingPathComponent("loop-approvals.jsonl")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= maxBytes {
            let old = dir.appendingPathComponent("loop-approvals.1.jsonl")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
