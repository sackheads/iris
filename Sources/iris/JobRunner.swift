import Foundation

/// One firing of a job, start to finish (#187 §6). Replaces deliverable 1's fire handler, which
/// pushed a system event into whatever conversation the job was created in — so a five-minute
/// cadence wrote into the chat the user was reading, and a run that needed an approval parked on a
/// dialog nobody was there to answer.
///
/// A run now gets a conversation of its own: `isBackground`, so it is out of the sidebar
/// (`SidebarOrdering.visible`) and out of the selection, but a real conversation all the same, so
/// its transcript can be read back from a card afterwards. Around that turn this writes the two
/// durable records the rest of the feature reads: the `job_runs` row (begun before the turn, so a
/// crash mid-run leaves a `running` row for `closeRunningRuns` to find at the next launch) and one
/// `EventCard` delivered when it is over.
///
/// An actor because `JobScheduler` fires handlers from a task group: two jobs coming due in the
/// same tick run concurrently, and each needs its own conversation and its own row without either
/// of them serialising on the main actor for longer than the hops below.
actor JobRunner {
    /// The failure reason on the row an overlap-skip writes. Spelled once: `/jobs` reads it back.
    static let skipReason = "skipped: previous run still in progress"

    private let state: AppState
    private let engine: IrisEngine
    private let ledger: JobLedger
    private let now: @Sendable () -> Date

    init(state: AppState, engine: IrisEngine, ledger: JobLedger,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.state = state
        self.engine = engine
        self.ledger = ledger
        self.now = now
    }

    /// Creates the background conversation, records the run, runs the turn, closes the row and
    /// delivers the card. Never throws: a fire is unattended, so every failure here is logged and
    /// the run is still accounted for in the ledger rather than surfacing to a caller with no one
    /// to tell.
    func run(job: Job, reason: String, changedPaths: [String] = []) async {
        let startedAt = now()
        let title = "\(job.name) · \(ISO8601DateFormatter().string(from: startedAt))"
        let state = self.state
        let conversationId = await MainActor.run { () -> UUID in
            let id = state.createNewConversation(isBackground: true, title: title)
            // `.mutating` is the only profile that asks for a container. `.readOnly` leaves the
            // field nil deliberately: nil means "fall through to the per-workspace/global
            // default", which is not the same as pinning this run to the host (§9).
            if job.profile == .mutating, let idx = state.conversations.firstIndex(where: { $0.id == id }) {
                state.conversations[idx].mainAgentSandbox = .sandboxed
            }
            // The strip is the only place a run in flight is visible at all, since the
            // conversation itself is hidden.
            state.registerSubagent(id: id, role: "job:\(job.name)", kind: .job)
            return id
        }

        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: reason, startedAt: startedAt,
                         transcriptConversationId: conversationId)
        do {
            try ledger.begin(run: run)
        } catch {
            // The row is what makes a run visible — without it the turn would burn tokens and a
            // model call with nothing to show for it, and `finish` below would throw anyway.
            // Deleting the job out from under a due tick is the way this happens.
            print("[JobRunner] not running \(job.name): could not record the run: \(error)")
            await MainActor.run { state.finishSession(id: conversationId, status: "not recorded") }
            return
        }

        await engine.processInput(Self.prompt(job: job, changedPaths: changedPaths),
                                  source: "job:\(job.name)", conversationId: conversationId)
        let finishedAt = now()

        let (messages, denials, tokens) = await MainActor.run {
            () -> ([ChatMessage], [BlockedToolCall], TokenUsage) in
            let conversation = state.conversations.first(where: { $0.id == conversationId })
            // Taken, not read: the denials belong to this run, and leaving them behind would mark
            // the next run in the same conversation blocked too (there is no next run in the same
            // conversation today, but the drain is what guarantees that).
            return (conversation?.messages ?? [],
                    state.takeBackgroundDenials(for: conversationId),
                    conversation?.tokenUsage ?? TokenUsage())
        }

        let status = Self.status(messages: messages, denials: denials,
                                 softStopped: Self.softStopped(in: messages))
        let outcome = Self.outcome(from: messages)
        let blockedTool = denials.first?.toolName
        do {
            // The conversation is fresh, so its accumulated `tokenUsage` IS this run's cost.
            try ledger.finish(runId: run.id, status: status, outcome: outcome,
                              failureReason: Self.failureReason(status: status, messages: messages),
                              blockedTool: blockedTool, tokens: tokens, finishedAt: finishedAt)
        } catch {
            print("[JobRunner] could not close the run for \(job.name): \(error)")
        }

        let card = EventCard(runId: run.id, jobId: job.id, jobName: job.name, status: status,
                             outcome: outcome, blockedTool: blockedTool,
                             startedAt: startedAt, finishedAt: finishedAt,
                             totalTokens: tokens.totalTokenCount,
                             transcriptConversationId: conversationId)
        await MainActor.run { state.finishSession(id: conversationId, status: card.statusText) }

        let destination = await MainActor.run { () -> UUID in
            // A destination that has since been deleted falls back to Activity rather than
            // dropping the card: `deliverEvent` is a no-op for an unknown id, and a run nobody
            // hears about is the failure mode this whole deliverable exists to fix.
            if let wanted = job.destinationConversationId,
               state.conversations.contains(where: { $0.id == wanted }) {
                return wanted
            }
            return state.activityConversationId()
        }
        await state.deliverEvent(card, to: destination)
    }

    /// The job's prompt, plus the paths that woke it when a watch did. Listed rather than
    /// interpolated into a sentence so a long burst reads as data, not as instructions.
    static func prompt(job: Job, changedPaths: [String]) -> String {
        guard !changedPaths.isEmpty else { return job.prompt }
        return job.prompt + "\n\nChanged paths:\n" + changedPaths.map { "- \($0)" }.joined(separator: "\n")
    }

    /// The first line of the last thing the agent said, capped at 200 characters — the one line a
    /// card and `/jobs` show. `nil` when the run said nothing, which is a perfectly ordinary
    /// outcome for a job whose work was all tool calls.
    static func outcome(from messages: [ChatMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .agent }) else { return nil }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    /// Fail-closed precedence (§6.2). A denial outranks everything: it is the one outcome a person
    /// can do something about, and it is the reason the run stopped short even if the turn also
    /// errored on its way out. An `[LLM_ERROR]` outranks a soft stop for the same reason — it says
    /// what actually broke, where a soft stop only says the loop was cut off.
    static func status(messages: [ChatMessage], denials: [BlockedToolCall], softStopped: Bool) -> JobRun.Status {
        if !denials.isEmpty { return .blockedOnApproval }
        if llmErrorHeadline(in: messages) != nil { return .failed }
        if softStopped { return .failed }
        return .completed
    }

    /// The headline of the last failed model call in the transcript. An `[LLM_ERROR]` is a
    /// `.system` message holding encoded JSON, NOT something the agent said — scanning `.agent`
    /// text for it would find nothing.
    static func llmErrorHeadline(in messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .system && LLMErrorMessage.parse($0.content) != nil }
            .flatMap { LLMErrorMessage.parse($0.content)?.headline }
    }

    /// Whether the loop detector (or a blocked-result run) cut the turn short. The signal is the
    /// `.system` line `IrisEngine.softStopWithSummary` posts, matched on the shared marker rather
    /// than a copy of the sentence.
    static func softStopped(in messages: [ChatMessage]) -> Bool {
        softStopLine(in: messages) != nil
    }

    private static func softStopLine(in messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .system && $0.content.contains(IrisEngine.softStopMarker) }?.content
    }

    /// What the row records about why a run did not simply complete. A blocked run says it with
    /// `blockedTool` instead, so there is nothing to add here.
    static func failureReason(status: JobRun.Status, messages: [ChatMessage]) -> String? {
        guard status == .failed else { return nil }
        return llmErrorHeadline(in: messages) ?? softStopLine(in: messages)
    }

    /// The row an overlap skip writes: a run that started and ended in the same instant, with no
    /// transcript, because no turn ever happened. `interrupted` rather than `failed` — nothing
    /// went wrong, the previous copy was simply still going, and `failed` would put it in front of
    /// a person as something to fix.
    static func recordSkip(job: Job, ledger: JobLedger, now: Date) throws {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: job.trigger.kind,
                         startedAt: now, status: .interrupted)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: .interrupted, outcome: nil,
                          failureReason: skipReason, blockedTool: nil,
                          tokens: TokenUsage(), finishedAt: now)
    }
}
