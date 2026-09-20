import Foundation

enum SubagentTerminalStatus: String, Codable, Sendable, Equatable {
    case completed   // goal_complete was called by the subagent
    case failed      // LLM/engine error ended the run
    case timedOut    // the poll cap in SubagentManager fired
    case cancelled   // stop/cancel path ended the run
}

/// In-memory termination signal handed from a termination site to SubagentManager.
/// Not Codable — SubagentManager immediately folds it into a SubagentResult.
struct SubagentTermination: Sendable {
    var status: SubagentTerminalStatus
    var summary: String
    var calledGoalComplete: Bool
}

struct SubagentResult: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var role: String
    var status: SubagentTerminalStatus
    var calledGoalComplete: Bool
    var summary: String              // UNVERIFIED self-report — the subagent's own words
    var filesWritten: [String]       // deduped write_file paths
    var startedAt: Date
    var endedAt: Date

    /// Slice B3 — the bounded definition-of-done the parent handed this subagent. Nil for a
    /// B2-style ungraded run. Carried on the result so it is self-describing: a renderer can show
    /// criteria beside verdicts without re-deriving them.
    ///
    /// Optional, so the synthesized decoder uses `decodeIfPresent` and a SubagentResult persisted
    /// before B3 decodes to nil instead of throwing and taking every conversation with it.
    var unitContract: GoalContract?

    /// Slice B3 — the TRUSTED grade, produced by a fresh-context evaluator that never saw this
    /// subagent's transcript. Present iff the run terminated `.completed` WITH a unit contract.
    /// `summary` above remains the subagent's own unverified words; these two are never conflated.
    var verdict: GoalEvaluation?

    init(schemaVersion: Int = 1, role: String, status: SubagentTerminalStatus, calledGoalComplete: Bool,
         summary: String, filesWritten: [String], startedAt: Date, endedAt: Date,
         unitContract: GoalContract? = nil, verdict: GoalEvaluation? = nil) {
        self.schemaVersion = schemaVersion
        self.role = role
        self.status = status
        self.calledGoalComplete = calledGoalComplete
        self.summary = summary
        self.filesWritten = filesWritten
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.unitContract = unitContract
        self.verdict = verdict
    }

    /// Lenient decoder (invariant 1): this type had no hand-written `init(from:)` at all, so every
    /// non-Optional field threw `keyNotFound` on an absent key. That throw is caught at the
    /// conversation-row level in `ConversationStore.loadAll` and skips the WHOLE conversation
    /// (#204). None of these fields is an id another row references, so all get a safe default
    /// rather than staying required.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        status = try c.decodeIfPresent(SubagentTerminalStatus.self, forKey: .status) ?? .failed
        calledGoalComplete = try c.decodeIfPresent(Bool.self, forKey: .calledGoalComplete) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        filesWritten = try c.decodeIfPresent([String].self, forKey: .filesWritten) ?? []
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt) ?? Date()
        unitContract = try c.decodeIfPresent(GoalContract.self, forKey: .unitContract)
        verdict = try c.decodeIfPresent(GoalEvaluation.self, forKey: .verdict)
    }

    /// One line per criterion verdict, plus a header tallying how many were met. Only `.met`
    /// counts toward the tally — `human_pending` in particular is never rendered as a passed gate.
    private func verdictBlock(_ verdict: GoalEvaluation) -> String {
        let met = verdict.criteria.filter { $0.verdict == .met }.count
        var header = "Independent grader verdict (fresh context): \(met)/\(verdict.criteria.count) met"
        if verdict.status != .graded { header += " — grader status: \(verdict.status.rawValue)" }
        var s = header
        for c in verdict.criteria {
            let symbol: String
            switch c.verdict {
            case .met:          symbol = "✓"
            case .notMet:       symbol = "✗"
            case .cannotVerify: symbol = "?"
            case .humanPending: symbol = "—"
            }
            s += "\n  \(symbol) \(c.criterionText) — \(c.verdict.rawValue)"
            if !c.evidence.isEmpty { s += ": \(c.evidence)" }
        }
        return s
    }

    func renderedForParent() -> String {
        let statusText: String
        switch status {
        case .completed: statusText = "completed"
        case .failed:    statusText = "failed"
        case .timedOut:  statusText = "timed out"
        case .cancelled: statusText = "cancelled"
        }
        let gc = calledGoalComplete ? "goal_complete called" : "goal_complete not called"
        // Any contracted run's summary is labeled unverified — a run held to criteria invites the
        // parent to read the summary as evidence against them, whether or not a grade landed. An
        // UNcontracted run has no contract to contrast it with, so the line stays exactly as slice
        // B2 wrote it (the byte-for-byte B2 guarantee is about contract-less delegation).
        let summaryLabel = unitContract == nil ? "Summary" : "Summary (UNVERIFIED self-report)"
        var s = "Subagent '\(role)' finished — status: \(statusText) (\(gc)).\n\(summaryLabel): \(summary)"
        if !filesWritten.isEmpty {
            s += "\nFiles written (\(filesWritten.count)): \(filesWritten.joined(separator: ", "))"
        }
        if let verdict {
            s += "\n" + verdictBlock(verdict)
        } else if let unitContract {
            // Contracted but never graded (the run did not complete). Say what it was held to, so
            // the parent is not left assuming an ungraded run was an unconstrained one.
            let n = unitContract.criteria.count
            s += "\nHeld to \(n) criter\(n == 1 ? "ion" : "ia") — not graded (the run did not reach completion)."
        }
        return s
    }
}
