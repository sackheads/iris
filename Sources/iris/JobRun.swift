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
    /// Reserved for deliverable 3's gates.
    var gateSignal: String?
    /// The background conversation this run's turn ran in. No foreign key: transcripts are pruned
    /// on their own schedule, so this can name a conversation that is already gone.
    var transcriptConversationId: UUID?
    /// When a person saw the failure. `nil` on a failed or blocked run means it is still open.
    var acknowledgedAt: Date?

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
