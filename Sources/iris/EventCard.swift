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
    /// The exact call the run failed closed on (#187 §6), so the card can show what was refused —
    /// the command, the path, a preview of the body — rather than a tool name. An approval given
    /// without sight of the payload is worse than no button.
    let blockedCall: BlockedCall?
    /// What Vibecop made of `blockedCall`, taken when the card was written and shown beside the
    /// button. `APPROVE` / `ESCALATE` / `DENY`, or nil when it was not consulted (it is disabled,
    /// it failed, or the call is one no click can authorise anyway). Advisory, never a veto: a
    /// person clicking through a `DENY` is the case the verdict exists to inform, not to prevent.
    let vibecopVerdict: String?
    let vibecopReason: String?
    /// Why this build refuses to offer "Approve and run" for `blockedCall`, decided when the card
    /// was written — today, a write into a protected directory (#187 R10). `nil` means nothing
    /// stored objected; `approvalRefusal` is what the view asks, and it has the last word.
    let approvalBlockedReason: String?

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
         transcriptConversationId: UUID? = nil,
         blockedCall: BlockedCall? = nil,
         vibecopVerdict: String? = nil,
         vibecopReason: String? = nil,
         approvalBlockedReason: String? = nil) {
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
        self.blockedCall = blockedCall
        self.vibecopVerdict = vibecopVerdict
        self.vibecopReason = vibecopReason
        self.approvalBlockedReason = approvalBlockedReason
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
        // Decoded through its raw value rather than as `JobRun.Status` directly, and the two ways
        // it can be missing are NOT the same: an absent key is an older card that predates the
        // field, which was only ever written for a completed run; a present-but-unrecognised value
        // is a status a newer build invented, and the one thing a card must not do is paint an
        // unknown status green. Unknown degrades to `.interrupted` — grey, no claim of success.
        if let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) {
            status = JobRun.Status(rawValue: rawStatus) ?? .interrupted
        } else {
            status = .completed
        }
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        blockedTool = try container.decodeIfPresent(String.self, forKey: .blockedTool)
        let started = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        startedAt = started ?? Date(timeIntervalSince1970: 0)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt) ?? startedAt
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        transcriptConversationId = try container.decodeIfPresent(UUID.self, forKey: .transcriptConversationId)
        // A blocked call this build cannot read is no blocked call: "there is something here and I
        // do not know what it is" must never become a button. Same direction `JobLedger`'s
        // `markApproved` takes for an undecodable stored call.
        blockedCall = try? container.decodeIfPresent(BlockedCall.self, forKey: .blockedCall)
        vibecopVerdict = try container.decodeIfPresent(String.self, forKey: .vibecopVerdict)
        vibecopReason = try container.decodeIfPresent(String.self, forKey: .vibecopReason)
        approvalBlockedReason = try container.decodeIfPresent(String.self, forKey: .approvalBlockedReason)
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

    /// Whether `message` is an event card whose transcript conversation still exists — the
    /// enablement of a card's "View run". Resolved by whoever owns the message list and passed
    /// down to the row: read inside `MessageView.body` it would subscribe every event row to
    /// `AppState.conversations`, re-rendering the lot on any unrelated conversation mutation.
    static func transcriptAvailable(for message: ChatMessage, in conversations: [Conversation]) -> Bool {
        guard message.role == .event, let card = decode(message.content),
              let transcript = card.transcriptConversationId else { return false }
        return conversations.contains { $0.id == transcript }
    }

    /// `nil` when `messageContent` is anything other than a card — plain prose, Markdown, or JSON
    /// without a `runId`. Every render path falls back to the raw content on `nil`.
    static func decode(_ messageContent: String) -> EventCard? {
        let trimmed = messageContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? decoder().decode(EventCard.self, from: data)
    }

    /// `completed` / `blocked on approval` / … — the status as a card shows it, with
    /// `blockedOnApproval` spelled out rather than camel-cased. `/jobs` prints the same words for
    /// the same run, which is why the spelling lives on the status itself.
    var statusText: String { status.text }

    /// `statusText` plus the tool an approval was wanted for, when there is one.
    var statusDetail: String {
        guard status == .blockedOnApproval, let blockedTool, !blockedTool.isEmpty else { return statusText }
        return "\(statusText): \(blockedTool)"
    }

    /// `pr-sweep · blocked on approval: run_command` — the card's title, also its tooltip.
    var headline: String { "\(jobName) · \(statusDetail)" }

    // MARK: The blocked call (#187 §6)

    /// Why "Approve and run" is not offered for this card's blocked call — `nil` when it is, and
    /// `nil` for a card with no blocked call, which has nothing to offer either way.
    ///
    /// A read-only job's refusal is decided here rather than read out of `approvalBlockedReason`,
    /// so a card written by a build that did not store one still cannot offer a button for it
    /// (R13). `JobLedger.markApproved` refuses the same call at the data layer: three layers,
    /// because each can be reached without the others.
    var approvalRefusal: String? {
        guard let blockedCall else { return nil }
        if blockedCall.reason == .profile { return Self.profileNotApprovable }
        return approvalBlockedReason
    }

    /// Whether the card shows an "Approve and run" button at all.
    var offersApproval: Bool { blockedCall != nil && approvalRefusal == nil }

    /// Shown in place of the button for a call the read-only profile refused: no approval widens a
    /// profile, so the honest answer is what the person would have to change instead.
    static let profileNotApprovable =
        "This job is read-only, so nothing can approve this call. Recreate the job as mutating if it should be able to do this."

    /// Shown in place of the button for a write into `~/.iris/config` or `~/.iris/plugins` (R10):
    /// a write there grants further permission, so it is not a thing a click can authorise.
    static let protectedNotApprovable =
        "This writes into a protected directory (`config/` or `plugins/`), which grants permission rather than editing a file. Make the change yourself if you want it."

    /// How much of one *content-like* argument a card shows. A `write_file` body is the argument
    /// that matters most and the one that can be a megabyte; 500 characters is enough to see what
    /// is being written without pasting the file into the transcript (spec §6). Execution-bearing
    /// arguments are exempt — see `executionBearingArguments`.
    static let argumentPreviewLimit = 500

    /// How many lines of one argument a card shows, whatever kind of argument it is. The character
    /// cap says nothing about newlines, so 500 blank lines used to pass it untouched and stretch
    /// the card to 500 rows in the transcript. Runs of blank lines collapse to one and what is
    /// left is capped here, with the remainder counted rather than silently dropped.
    static let argumentPreviewLines = 12

    /// Arguments a tool *executes* rather than stores, exempt from `argumentPreviewLimit`: cutting
    /// one of these hides the thing the click authorises, and nobody can approve the 100
    /// characters they were not shown. The ledger's untruncated copy is what runs either way — the
    /// question here is only what a person can read before clicking.
    ///
    /// | argument      | tools that execute it                                   | why it is never cut                                                          |
    /// | ------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------- |
    /// | `command`     | `run_command`                                            | the string the shell runs; a trailing `&& rm -rf ~` is exactly what a cut hides |
    /// | `path`        | `read_file`, `write_file`, `edit_file`, `set_workspace`  | names the target — the body is the safe half to cut, the path is the risk      |
    /// | `cwd`         | `run_command` (also carried on `BlockedCall.cwd`)        | where the command lands; a suffix changes the directory                        |
    /// | `destination` | a move/copy-shaped tool                                  | the write target under another name                                            |
    ///
    /// Everything else is content-like — `content`, `text`, `body`, `prompt`, a query, an MCP
    /// tool's opaque payload — data the tool stores or sends, where 500 characters is enough to
    /// judge the call. Capping is the default so an unknown argument on a tool added later cannot
    /// stretch the card; adding a name here is a deliberate decision, like `readOnlyAllowed`.
    static let executionBearingArguments: Set<String> = ["command", "path", "cwd", "destination"]

    /// One rendered argument of the blocked call.
    struct BlockedArgument: Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let value: String
    }

    /// Every argument of the blocked call, sorted by key and cut to `argumentPreviewLimit`, so the
    /// person approving sees the whole call and two renders of it read the same. Empty when there
    /// is no blocked call.
    var blockedArguments: [BlockedArgument] {
        guard let blockedCall else { return [] }
        return blockedCall.args.keys.sorted().map { key in
            BlockedArgument(key: key, value: Self.preview(key: key, value: blockedCall.args[key] ?? .null))
        }
    }

    /// `Vibecop: DENY — recursive delete` — its opinion of the call, or `nil` when it was not
    /// consulted. Information for the person deciding; the button is offered regardless.
    var vibecopLine: String? {
        guard let vibecopVerdict, !vibecopVerdict.isEmpty else { return nil }
        guard let vibecopReason, !vibecopReason.isEmpty else { return "Vibecop: \(vibecopVerdict)" }
        return "Vibecop: \(vibecopVerdict) — \(vibecopReason)"
    }

    /// The call as a CARD keeps it: every argument already through `preview`. A card is a display
    /// snapshot living in a message row, and "Approve and run" re-dispatches the LEDGER's copy of
    /// the call, never this one — so storing a megabyte `write_file` body here would write the
    /// whole file into the transcript for nothing. Values that fit are untouched, and keep their
    /// type.
    ///
    /// Execution-bearing arguments are carried whole, which is the deliberate side of the trade:
    /// the argument that can be a megabyte is the content-like one and it is still capped, while a
    /// command or a path is bounded in practice by what a shell or a filesystem accepts. A card
    /// with a pathologically long single-line command is a tall card in a scrolling transcript —
    /// preferable to an approver reading 500 characters of a command and authorising 600.
    static func displayCopy(of call: BlockedCall) -> BlockedCall {
        var args: [String: JSONValue] = [:]
        for (key, value) in call.args {
            let shown = preview(key: key, value: value)
            args[key] = shown == value.stringValue ? value : .string(shown)
        }
        return BlockedCall(toolName: call.toolName, args: args,
                           cwd: call.cwd, reason: call.reason, at: call.at)
    }

    /// One argument as a card shows it. Four passes: render it (compact JSON for a structure, so a
    /// nested argument reads as itself rather than `{...}`), collapse runs of blank lines, bound
    /// its height to `argumentPreviewLines`, and cut it to `argumentPreviewLimit` characters
    /// *unless* `key` is execution-bearing.
    ///
    /// Lines are cut before characters, and both notes are collected into one `… (N characters,
    /// M more lines)` suffix at the end. Order matters: cutting characters first puts the note
    /// dozens of lines down, where the line cut then throws it away, and a truncation the reader
    /// cannot see is the one thing this must not do. The character count is of the whole
    /// (blank-collapsed) text, so it answers "how much was there", not "how much of the top
    /// twelve lines was there".
    static func preview(key: String, value: JSONValue) -> String {
        let text = collapsingBlankLines(renderedText(value))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hiddenLines = max(0, lines.count - argumentPreviewLines)
        var shown = hiddenLines == 0 ? text : lines.prefix(argumentPreviewLines).joined(separator: "\n")
        var notes: [String] = []
        if !executionBearingArguments.contains(key), shown.count > argumentPreviewLimit {
            shown = String(shown.prefix(argumentPreviewLimit))
            notes.append("\(text.count) characters")
        }
        if hiddenLines > 0 { notes.append("\(hiddenLines) more \(hiddenLines == 1 ? "line" : "lines")") }
        guard !notes.isEmpty else { return shown }
        return shown + "… (" + notes.joined(separator: ", ") + ")"
    }

    private static func renderedText(_ value: JSONValue) -> String {
        switch value {
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
                ?? value.stringValue
        default:
            return value.stringValue
        }
    }

    /// Any run of blank lines becomes one. A file with paragraph breaks still reads as one; a
    /// thousand newlines becomes a single gap.
    private static func collapsingBlankLines(_ text: String) -> String {
        var kept: [Substring] = []
        var inBlankRun = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && inBlankRun { continue }
            inBlankRun = isBlank
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

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
        let head = "[Event] job \(jobName) \(statusText)"
        guard let outcome, !outcome.isEmpty else { return "\(head) (run \(runPrefix))" }
        return "\(head): \(outcome) (run \(runPrefix))"
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

    /// The text those same paths print — what this message *reads* as outside the app, which is
    /// not always its stored content: an event card collapses to its one-line `transcriptLine`
    /// rather than dumping its JSON, and an LLM-error system row to its headline rather than the
    /// `[LLM_ERROR]`-prefixed JSON it is encoded as. Fix round 1: the Markdown export already did
    /// the latter and the other three paths did not, which is exactly the kind of drift that put
    /// four copies of the role ternary in the tree to begin with.
    var exportText: String {
        switch role {
        case .event: return EventCard.decode(content)?.transcriptLine ?? content
        case .system: return LLMErrorMessage.parse(content)?.headline ?? content
        case .user, .agent, .command: return content
        }
    }

    /// How an export renders a message block. The Markdown form is what "Copy as Markdown" and
    /// the `.md` export write; the plain form is what a plain copy and the transcript sheet write.
    enum ExportFormat: Sendable {
        case markdown
        case plainText
    }

    /// One message as an export renders it, without a trailing separator — callers join blocks
    /// with a blank line. Fix round 1: the four export paths shared only the role name, and each
    /// still interpolated `content` directly, so an `.event` row exported as raw card JSON under
    /// an "Event" heading. Whole-block, one definition, four call sites.
    func exportLine(format: ExportFormat) -> String {
        switch format {
        case .markdown:
            // `.system` and `.event` render as compact one-line cards in the transcript, so they
            // export as inline code rather than as a paragraph of prose.
            let body = (role == .system || role == .event) ? "`\(exportText)`" : exportText
            return "### \(exportRoleName)\n\(body)"
        case .plainText:
            return "\(exportRoleName):\n\(exportText)"
        }
    }
}
