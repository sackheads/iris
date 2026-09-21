import Foundation

/// One firing of a `Job` (#187 deliverable 2): the row an event card is drawn from and the record
/// `get_job_run` reads back. `jobName` and `triggerKind` are denormalized copies of the job's
/// fields so a card still reads correctly after the job is renamed, retriggered or deleted — the
/// row itself is cascaded away with the job, but a card already on screen is not.
///
/// A run starts as `running` and ends in exactly one of `completed`, `failed`, `blockedOnApproval`
/// (a tool needed an approval nobody gave) or `interrupted` (the app quit mid-run). `failed` and
/// `blockedOnApproval` runs are the ones that hold a person's attention: they stay in
/// `unacknowledgedFailures()` and are exempt from retention until `acknowledgedAt` is stamped.
struct JobRun: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable, Codable {
        case running, completed, failed, blockedOnApproval, interrupted
    }

    let id: UUID
    let jobId: UUID
    /// The job's name when the run started; not kept in sync with a later rename, on purpose.
    let jobName: String
    let triggerKind: String
    let startedAt: Date
    var finishedAt: Date?
    var status: Status
    /// One line, at most 200 characters — `JobLedger.finish` truncates.
    var outcome: String?
    var failureReason: String?
    /// The tool an approval was wanted for; set with `blockedOnApproval`.
    var blockedTool: String?
    var promptTokens: Int
    var candidateTokens: Int
    var totalTokens: Int
    /// Reserved: nothing computes a cost yet (spec §6.3).
    var costMicros: Int64?
    /// What the run's gate saw — an ETag, an mtime, a hash (#187 deliverable 3, spec §7). Compared
    /// with the previous run's to decide whether anything changed; written by
    /// `JobLedger.setGateSignal`, read back by `lastGateSignal`.
    var gateSignal: String?
    /// The background conversation this run's turn ran in. No foreign key: transcripts are pruned
    /// on their own schedule, so this can name a conversation that is already gone.
    var transcriptConversationId: UUID?
    /// When a person saw the failure. `nil` on a failed or blocked run means it is still open.
    var acknowledgedAt: Date?
    /// The exact call this run failed closed on, persisted so the card can show every argument and
    /// "Approve and run" can dispatch it (#187 deliverable 3). Set with `blockedOnApproval`.
    var blockedCall: BlockedCall?
    /// When `blockedCall` was approved and dispatched. Stamped once, atomically, so two clicks on
    /// the same card cannot run the call twice.
    var approvedAt: Date?
    /// The run this one was dispatched from — set on the row an approved `blockedCall` runs as, so
    /// the follow-up card can be traced back to the run that asked.
    var parentRunId: UUID?

    init(id: UUID = UUID(), jobId: UUID, jobName: String, triggerKind: String, startedAt: Date,
         status: Status = .running, transcriptConversationId: UUID? = nil) {
        self.id = id
        self.jobId = jobId
        self.jobName = jobName
        self.triggerKind = triggerKind
        self.startedAt = startedAt
        self.finishedAt = nil
        self.status = status
        self.outcome = nil
        self.failureReason = nil
        self.blockedTool = nil
        self.promptTokens = 0
        self.candidateTokens = 0
        self.totalTokens = 0
        self.costMicros = nil
        self.gateSignal = nil
        self.transcriptConversationId = transcriptConversationId
        self.acknowledgedAt = nil
        self.blockedCall = nil
        self.approvedAt = nil
        self.parentRunId = nil
    }
}

extension JobRun.Status {
    /// How a person is told about this status: `blocked on approval` rather than the camel-cased
    /// raw value. Shared by the event card and `/jobs`, so a run reads the same wherever it is
    /// shown.
    var text: String {
        switch self {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .blockedOnApproval: return "blocked on approval"
        case .interrupted: return "interrupted"
        }
    }
}

/// The one tool call a background run failed closed on (#187 deliverable 3, spec §6): stored on the
/// run as JSON so the event card can render the whole call — the command, the path, the body — and
/// a human can approve *that*, not just a tool name. D2 kept only the name, which is not enough to
/// approve anything safely and not enough to re-dispatch it either.
struct BlockedCall: Codable, Equatable, Sendable {
    /// Why the call did not run: nobody was there to approve it, or the job's `readOnly` profile
    /// forbids the tool outright.
    enum Reason: String, Codable, Sendable { case approval, profile }

    let toolName: String
    /// Exactly what the model sent, unaltered — this is what gets re-dispatched on approval.
    let args: [String: JSONValue]
    let cwd: String?
    let reason: Reason
    let at: Date

    init(toolName: String, args: [String: JSONValue] = [:], cwd: String? = nil,
         reason: Reason = .approval, at: Date = Date()) {
        self.toolName = toolName
        self.args = args
        self.cwd = cwd
        self.reason = reason
        self.at = at
    }

    private enum CodingKeys: String, CodingKey { case toolName, args, cwd, reason, at }

    /// Invariant 1 throughout, and an unrecognized `reason` reads as `.approval`: the conservative
    /// guess, since an approval is the case that still needs a human either way.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        reason = Reason(rawValue: try c.decodeIfPresent(String.self, forKey: .reason) ?? "") ?? .approval
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0)
    }
}
