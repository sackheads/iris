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
    /// The run's cache components (5c §0.6), raw: `cacheWriteTokens` is every write and
    /// `cacheWrite1hTokens` the 1-hour share of it. 0 on a row written before 5c.
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheWrite1hTokens: Int = 0
    /// The share of `cacheReadTokens` its delegated subagents read (#370, v17). 0 on earlier rows.
    var delegatedCacheReadTokens: Int = 0
    /// #239 3b: what its subagents on other models spent, per model (`job_runs.delegatedCharges`).
    var delegatedCharges: [DelegatedCharge] = []
    /// Whose prices apply to this run: `LLMProvider.rawValue` and `ModelTier.rawValue`, stamped on
    /// a model-turn run at `begin`. nil on a row that spent nothing, and on every pre-5c row,
    /// which `CostWeights` then prices at its plain total.
    var provider: String?
    var tier: String?
    /// The model id `tier` resolved to when the run began (#370): cache reads price at its ratio.
    /// nil on every row written before v16, which reads at the provider's ratio.
    var model: String?
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
    /// What the burst that started this run saw and absorbed (#187 deliverable 4, spec §6). Set
    /// when the run began; `nil` on every run a watch did not start.
    var watchSummary: WatchSummary?
    /// A script job's run (#330): what the script printed, each stream capped at
    /// `ScriptJobs.outputLimit`, untrusted; and whether this run posted a card (only a change or
    /// a failure does), which `/jobs` reads as "last posted". `nil`/false on every other run.
    /// A writing script job's read-write mounts, surveyed before and after the run (#688). Nil on
    /// every other run.
    var mountFigures: [MountFigures]?
    var scriptOutput: String?
    var scriptStderr: String?
    var posted: Bool = false

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
        self.provider = nil
        self.tier = nil
        self.model = nil
        self.costMicros = nil
        self.gateSignal = nil
        self.transcriptConversationId = transcriptConversationId
        self.acknowledgedAt = nil
        self.blockedCall = nil
        self.approvedAt = nil
        self.parentRunId = nil
        self.watchSummary = nil
    }
}

extension JobRun {
    /// This row as the weight table prices it; the same split as `TokenUsage.components`.
    /// Its spend as a budget reads it: its own tokens at its provider and model, plus the other
    /// models' charges, converted when they were charged.
    var weighted: Int {
        CostWeights.weighted(components, provider: provider, model: model) + delegatedCharges.reduce(0) { $0 + $1.weighted }
    }

    var components: UsageComponents {
        UsageComponents(prompt: promptTokens, output: max(candidateTokens, totalTokens - promptTokens),
                        cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens,
                        cacheWrite1h: cacheWrite1hTokens, delegatedCacheRead: delegatedCacheReadTokens)
    }
}

extension JobRun {
    /// What a person is told about how the run ended: the outcome, or the failure reason when
    /// there is no outcome to show. Shared by `/jobs`' failure lines and the Run Log.
    var detailText: String? {
        [outcome, failureReason]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

    /// `text`, except that a run its read-only profile stopped reads `refused by profile` (#553).
    /// The ledger stores that run as `blockedOnApproval`, which keeps it in front of a person, but
    /// no approval can lift it: only recreating the job as mutating can. `reason` is the run's
    /// `blockedCall?.reason`; a run with no call on it (or one that would not decode) keeps `text`.
    func text(blockedBy reason: BlockedCall.Reason?) -> String {
        self == .blockedOnApproval && reason == .profile ? Self.refusedByProfileText : text
    }

    static let refusedByProfileText = "refused by profile"
}

extension JobRun {
    /// The status as a person reads it: `status.text`, or `refused by profile` (#553).
    var statusText: String { status.text(blockedBy: blockedCall?.reason) }
    /// Whether the read-only profile, not a missing approval, stopped this run.
    var refusedByProfile: Bool { status == .blockedOnApproval && blockedCall?.reason == .profile }
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
    /// What gets re-dispatched on approval, exactly. For a call whose BeforeTool hooks ran before
    /// it was recorded (`hooksFired`), that is the hooked arguments, the path resolved: what the
    /// card shows and the person approves is what runs (#647, #653). Otherwise what the model
    /// sent. One exception: `DevHomeSeeder` re-points absolute paths under the release home to the dev
    /// home when it copies a conversation's store, so a seeded dev copy's `args` can differ from
    /// what the model actually sent.
    let args: [String: JSONValue]
    let cwd: String?
    let reason: Reason
    let at: Date
    /// The granted directory nearest the call's path (#282 §5), so the card can say where the grant
    /// is; set only for a denial inside a granted run, nil for an ungranted one.
    let grantNearest: String?
    /// The BeforeTool hooks already ran on `args` when the call was recorded (#653), so the click
    /// runs them as they are: its hooks run again only to honour a denial, never to rewrite. False for a call recorded before its hooks
    /// (a policy denial), and for a row written before this field: those fire at the click, as
    /// they always did.
    let hooksFired: Bool

    init(toolName: String, args: [String: JSONValue] = [:], cwd: String? = nil,
         reason: Reason = .approval, at: Date = Date(), grantNearest: String? = nil, hooksFired: Bool = false) {
        self.toolName = toolName
        self.args = args
        self.cwd = cwd
        self.reason = reason
        self.at = at
        self.grantNearest = grantNearest
        self.hooksFired = hooksFired
    }

    private enum CodingKeys: String, CodingKey { case toolName, args, cwd, reason, at, grantNearest, hooksFired }

    /// Invariant 1 throughout, and an unrecognized `reason` reads as `.profile` — the fail-closed
    /// direction, because `reason` is what three layers ask "can a click run this?" and `.profile`
    /// is the answer none of them will act on (`EventCard.approvalRefusal` hides the button,
    /// `JobLedger.markApproved` refuses the claim, `JobRunner.runApproved` refuses the click). A
    /// reason a newer build wrote and this one cannot read is exactly the call not to offer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        reason = Reason(rawValue: try c.decodeIfPresent(String.self, forKey: .reason) ?? "") ?? .profile
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(timeIntervalSince1970: 0)
        grantNearest = try c.decodeIfPresent(String.self, forKey: .grantNearest)
        hooksFired = try c.decodeIfPresent(Bool.self, forKey: .hooksFired) ?? false
    }

    /// The one string that says what a call would actually do — the command, the path — and `nil`
    /// for a tool that never goes through an approval at all.
    ///
    /// Spelled once because three places have to agree on it: the dispatcher, which asks the
    /// permission layer and Vibecop about a call before it runs; the card, which asks Vibecop
    /// about the same call afterwards; and the re-dispatch. Two spellings would mean a call judged
    /// on one string when it was refused and another when it was approved.
    static func approvalDetails(toolName: String, args: [String: JSONValue]) -> String? {
        switch toolName {
        case "run_command": return args["command"]?.stringValue
        case "read_file", "write_file": return args["path"]?.stringValue
        default: return nil
        }
    }

    /// This call's own `approvalDetails`, empty for a tool that has none.
    var details: String { Self.approvalDetails(toolName: toolName, args: args) ?? "" }

    /// The file this call would write, resolved against its `cwd` — `nil` when it writes nothing.
    /// Resolved rather than taken raw: a relative path is decided against the run's directory, and
    /// the protected-directory check (R10) must see the location, not the spelling.
    var writeTarget: String? {
        guard toolName == "write_file", let path = args["path"]?.stringValue, !path.isEmpty
        else { return nil }
        return ToolExecutor.resolvePath(path, cwd: cwd)
    }
}
