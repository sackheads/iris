import Foundation

/// The payload of a `ChatRole.event` message (#187 deliverable 2): what a background job run did,
/// delivered into the pinned "Iris Activity" conversation and drawn as a one-line card by
/// `EventCardView`.
///
/// It is stored as JSON inside `ChatMessage.content` rather than as new columns on the message
/// row: an event card is a *snapshot* of the run at the moment it was delivered, not a live view
/// of the `job_runs` row. Runs are pruned on a retention schedule and jobs can be renamed or
/// deleted; a card already in the transcript keeps reading correctly regardless (the same reason
/// `JobRun` denormalizes `jobName`).
///
/// An `.event` message never wakes a model turn and is never indexed for search
/// (`ConversationStore.indexedRoles`) — it is a UI artifact, so nothing here needs to be
/// model-legible beyond `historyLine`.
struct EventCard: Codable, Equatable, Sendable {
    /// Discriminator for a future second kind of card. Only `"job_run"` exists today.
    let kind: String
    let runId: UUID
    let jobId: UUID
    /// The job's name at delivery time, copied from `JobRun.jobName`; a later rename does not
    /// rewrite cards already on screen.
    let jobName: String
    let status: JobRun.Status
    /// The run's one-line outcome, already truncated to 200 characters by `JobLedger.finish`.
    let outcome: String?
    /// The tool an approval was wanted for, set alongside `.blockedOnApproval`.
    let blockedTool: String?
    let startedAt: Date
    let finishedAt: Date
    let totalTokens: Int
    /// The background conversation the run's turn happened in, if it still had one when the card
    /// was written. There is no foreign key — transcripts are pruned on their own schedule, so
    /// this can name a conversation that is already gone (the card then says "transcript pruned"
    /// rather than offering a dead button).
    let transcriptConversationId: UUID?

    init(kind: String = "job_run",
         runId: UUID,
         jobId: UUID,
         jobName: String,
         status: JobRun.Status,
         outcome: String? = nil,
         blockedTool: String? = nil,
         startedAt: Date,
         finishedAt: Date,
         totalTokens: Int = 0,
         transcriptConversationId: UUID? = nil) {
        self.kind = kind
        self.runId = runId
        self.jobId = jobId
        self.jobName = jobName
        self.status = status
        self.outcome = outcome
        self.blockedTool = blockedTool
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.totalTokens = totalTokens
        self.transcriptConversationId = transcriptConversationId
    }

    /// A card that fails to decode renders as raw JSON in the transcript, so every field a future
    /// version might drop is read with `decodeIfPresent` and defaulted. `runId` is the exception:
    /// it is the card's identity, and requiring it is what lets `decode` tell a card apart from
    /// any other JSON that happens to be sitting in a message's content.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let runId = try container.decodeIfPresent(UUID.self, forKey: .runId) else {
            throw DecodingError.keyNotFound(CodingKeys.runId, DecodingError.Context(
                codingPath: container.codingPath, debugDescription: "not an event card"))
        }
        self.runId = runId
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "job_run"
        jobId = try container.decodeIfPresent(UUID.self, forKey: .jobId) ?? Self.unknownId
        jobName = try container.decodeIfPresent(String.self, forKey: .jobName) ?? "unknown"
        // Decoded through its raw value rather than as `JobRun.Status` directly: a status this
        // build does not know about degrades to `.completed` instead of throwing away the card.
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap(JobRun.Status.init(rawValue:)) ?? .completed
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        blockedTool = try container.decodeIfPresent(String.self, forKey: .blockedTool)
        let started = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        startedAt = started ?? Date(timeIntervalSince1970: 0)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt) ?? startedAt
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        transcriptConversationId = try container.decodeIfPresent(UUID.self, forKey: .transcriptConversationId)
    }

    private static let unknownId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys so an unchanged card encodes to the same bytes every time — the message row
        // is diffed by content, and an unstable key order would look like an edit on every write.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The JSON written into `ChatMessage.content`. ISO-8601 carries no sub-second component, so
    /// a re-decoded card's dates are truncated to the second — fine for the elapsed time and the
    /// timestamps a card displays, and nothing compares them for equality outside tests.
    func encodedContent() -> String {
        guard let data = try? Self.encoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            // Unreachable: every stored property is trivially encodable. Emitting an empty object
            // (rather than crashing) keeps a delivery failure to one unreadable card.
            return "{}"
        }
        return json
    }

    /// `nil` when `messageContent` is anything other than a card — plain prose, Markdown, or JSON
    /// without a `runId`. Every render path falls back to the raw content on `nil`.
    static func decode(_ messageContent: String) -> EventCard? {
        let trimmed = messageContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? decoder().decode(EventCard.self, from: data)
    }

    /// `completed` / `blocked on approval` / … — the status as a card shows it, with
    /// `blockedOnApproval` spelled out rather than camel-cased.
    var statusText: String {
        switch status {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .blockedOnApproval: return "blocked on approval"
        case .interrupted: return "interrupted"
        }
    }

    /// `statusText` plus the tool an approval was wanted for, when there is one.
    var statusDetail: String {
        guard status == .blockedOnApproval, let blockedTool, !blockedTool.isEmpty else { return statusText }
        return "\(statusText): \(blockedTool)"
    }

    /// `pr-sweep · blocked on approval: run_command` — the card's title, also its tooltip.
    var headline: String { "\(jobName) · \(statusDetail)" }

    /// The run's wall time, in the same format the session strip uses so the two never show two
    /// styles of elapsed time side by side.
    var elapsedText: String { SessionActivity.formatElapsed(finishedAt.timeIntervalSince(startedAt)) }

    /// `[job pr-sweep · completed · 4.2k tokens] swept 3 PRs` — what Copy Transcript and the
    /// Markdown export print in place of the card's JSON (spec §8.2).
    var transcriptLine: String {
        let head = "[job \(jobName) · \(statusText) · \(SessionActivity.formatTokenCount(totalTokens)) tokens]"
        guard let outcome, !outcome.isEmpty else { return head }
        return "\(head) \(outcome)"
    }

    /// `[Event] job pr-sweep completed: swept 3 PRs (run 1a2b3c4d)` — the model-legible form, for
    /// the line drained into a turn's history. The run is named by the first eight characters of
    /// its id, which is enough for `/jobs ack <run id>` to match on.
    var historyLine: String {
        let runPrefix = runId.uuidString.lowercased().prefix(8)
        let body = (outcome?.isEmpty == false) ? " \(jobName) \(statusText): \(outcome!)"
                                               : " \(jobName) \(statusText)"
        return "[Event] job\(body) (run \(runPrefix))"
    }
}

extension ChatMessage {
    /// The role caption every copy/export path prints. Four sites used to spell this out as their
    /// own `role == .user ? "You" : (role == .system ? "System" : "Iris")` ternary — three in
    /// `ChatView`, one in `TranscriptSheet` — none of which the compiler would have flagged when
    /// `.event` was added. An exhaustive `switch` in one place makes the next new role a build
    /// error instead of a silently mislabelled message.
    var exportRoleName: String {
        switch role {
        case .user: return "You"
        case .system: return "System"
        case .event: return "Event"
        case .agent, .command: return "Iris"
        }
    }

    /// The text those same paths print: an event card collapses to its one-line `transcriptLine`
    /// rather than dumping its JSON, everything else is its content verbatim.
    var exportText: String {
        guard role == .event else { return content }
        return EventCard.decode(content)?.transcriptLine ?? content
    }
}
