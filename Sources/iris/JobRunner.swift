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
    /// A turn that ended without the agent saying anything: a hook that blocked it, a cancelled
    /// engine, a conversation deleted mid-run. Not `completed` — "it worked and had nothing to
    /// report" and "it never got as far as a reply" must not look the same on a card.
    static let noReplyReason = "run produced no reply"
    /// The app quit (or `AppState` was otherwise released) with the run still open.
    static let releasedReason = "app state released"

    /// Weak, both of them: `AppState` owns the engine, the engine owns this runner for the life of
    /// the process, and a strong reference back either way is a cycle that keeps a whole app state
    /// — conversations, store, sessions — alive forever. Each hop below re-reads them and bails
    /// (closing the ledger row) rather than keeping one. `state` is held only for the length of a
    /// single main-actor hop; `engine` is held across `processInput`, because that call IS the
    /// run and an engine deallocated halfway through its own turn is not a state worth surviving.
    private weak var state: AppState?
    private weak var engine: IrisEngine?
    private let ledger: JobLedger
    private let now: @Sendable () -> Date
    private let protectionEnabled: Bool?
    /// The jobs with a run in flight right now. Every fire goes through `run`, so one set here is
    /// the whole overlap story, whatever woke the job.
    private var inFlight: Set<UUID> = []

    init(state: AppState, engine: IrisEngine, ledger: JobLedger,
         now: @escaping @Sendable () -> Date = Date.init,
         protectionEnabled: Bool? = nil) {
        self.state = state
        self.engine = engine
        self.ledger = ledger
        self.now = now
        self.protectionEnabled = protectionEnabled
    }

    /// Creates the background conversation, records the run, runs the turn, closes the row and
    /// delivers the card. Never throws: a fire is unattended, so every failure here is logged and
    /// the run is still accounted for in the ledger rather than surfacing to a caller with no one
    /// to tell.
    func run(job: Job, reason: String, changedPaths: [String] = []) async {
        // One guard for every fire. A watch is the case that needs it: FSEvents delivers a burst
        // for a single save, and each event used to start its own run of the same job. A fire that
        // arrives while the job is running is dropped SILENTLY — a row per dropped event would
        // spam the ledger far worse than the overlap it recorded, and a scheduled fire still gets
        // the scheduler's one skip row per cadence. D3's policy work turns this into a real quiet
        // window; until then, dropping is the conservative half.
        guard inFlight.insert(job.id).inserted else { return }
        defer { inFlight.remove(job.id) }

        let startedAt = now()
        guard let conversationId = await openConversation(for: job, at: startedAt) else {
            print("[JobRunner] not running \(job.name): \(Self.releasedReason)")
            return
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
            await closeSession(conversationId, status: "not recorded")
            return
        }

        guard let engine else {
            await closeInterrupted(run: run, conversationId: conversationId, at: now())
            return
        }
        let prompt = await Self.prompt(job: job, changedPaths: changedPaths,
                                       protectionEnabled: protectionEnabled)
        await engine.processInput(prompt, source: "job:\(job.name)", conversationId: conversationId)
        let finishedAt = now()

        guard let turn = await readTurn(conversationId: conversationId) else {
            await closeInterrupted(run: run, conversationId: conversationId, at: finishedAt)
            return
        }

        let status = Self.status(messages: turn.messages, denials: turn.denials,
                                 softStopped: Self.softStopped(in: turn.messages))
        let outcome = Self.outcome(from: turn.messages)
        let blockedTool = turn.denials.first?.toolName
        let failureReason = Self.failureReason(status: status, messages: turn.messages,
                                               blockedTool: blockedTool)
        do {
            // The conversation is fresh, so its accumulated `tokenUsage` IS this run's cost.
            try ledger.finish(runId: run.id, status: status, outcome: outcome,
                              failureReason: failureReason, blockedTool: blockedTool,
                              tokens: turn.tokens, finishedAt: finishedAt)
        } catch {
            print("[JobRunner] could not close the run for \(job.name): \(error)")
        }

        let card = EventCard(runId: run.id, jobId: job.id, jobName: job.name, status: status,
                             // A card shows one line. With no reply to show, that line is why
                             // there is none (§6.2) — a blank failed card tells nobody anything.
                             outcome: outcome ?? failureReason, blockedTool: blockedTool,
                             startedAt: startedAt, finishedAt: finishedAt,
                             totalTokens: turn.tokens.totalTokenCount,
                             transcriptConversationId: conversationId)
        await closeSession(conversationId, status: card.statusText)
        await deliver(card, for: job)
    }

    /// The run's own hidden conversation, registered in the session strip. `nil` when the app
    /// state has been released — there is nothing to run a turn against, and no row has been
    /// written yet, so the fire is simply dropped.
    private func openConversation(for job: Job, at startedAt: Date) async -> UUID? {
        guard let state else { return nil }
        let title = "\(job.name) · \(ISO8601DateFormatter().string(from: startedAt))"
        return await MainActor.run { () -> UUID in
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
    }

    /// What the finished turn left behind. `nil` when the app state went away while it ran.
    private struct TurnResult {
        let messages: [ChatMessage]
        let denials: [BlockedToolCall]
        let tokens: TokenUsage
    }

    private func readTurn(conversationId: UUID) async -> TurnResult? {
        guard let state else { return nil }
        return await MainActor.run { () -> TurnResult in
            let conversation = state.conversations.first(where: { $0.id == conversationId })
            // Taken, not read: the denials belong to this run, and leaving them behind would mark
            // the next run in the same conversation blocked too (there is no next run in the same
            // conversation today, but the drain is what guarantees that).
            return TurnResult(messages: conversation?.messages ?? [],
                              denials: state.takeBackgroundDenials(for: conversationId),
                              tokens: conversation?.tokenUsage ?? TokenUsage())
        }
    }

    /// Closes a run whose app state disappeared under it: the same shape as the sweep at the next
    /// launch, because it is the same situation — nothing will ever finish this turn. No card:
    /// there is nowhere to deliver one to.
    private func closeInterrupted(run: JobRun, conversationId: UUID, at: Date) async {
        // The normal path drains through `readTurn`; this one has to drain too, or a denial (and
        // the descendant links behind it) outlives the run that caused it in `AppState`.
        if let state {
            await MainActor.run { _ = state.takeBackgroundDenials(for: conversationId) }
        }
        do {
            try ledger.finish(runId: run.id, status: .interrupted, outcome: nil,
                              failureReason: Self.releasedReason, blockedTool: nil,
                              tokens: TokenUsage(), finishedAt: at)
        } catch {
            print("[JobRunner] could not close the released run for \(run.jobName): \(error)")
        }
        await closeSession(conversationId, status: "interrupted")
    }

    private func closeSession(_ conversationId: UUID, status: String) async {
        guard let state else { return }
        await MainActor.run { state.finishSession(id: conversationId, status: status) }
    }

    private func deliver(_ card: EventCard, for job: Job) async {
        guard let state else { return }
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

    /// The job's prompt, plus the paths that woke it when a watch did.
    ///
    /// The job's own prompt is trusted — the user (or the agent on their behalf) wrote it. The
    /// paths are not: a filename is chosen by whoever can write into the watched directory, and
    /// D1 put every fire through `handleSystemEvent`, which sanitized it. So each path goes
    /// through the structural pass and the whole block through the tiered guard, arriving wrapped
    /// in `<untrusted_context>` after the instructions rather than concatenated into them.
    static func prompt(job: Job, changedPaths: [String], protectionEnabled: Bool? = nil) async -> String {
        guard !changedPaths.isEmpty else { return job.prompt }
        let listed = changedPaths
            .map { "- " + PromptInjectionGuard.sanitizeUntrustedInput($0) }
            .joined(separator: "\n")
        let block = await InjectionGuard.sanitize("Changed paths:\n" + listed,
                                                  contextTag: "fs_event_paths",
                                                  maxTier: .tier3_canary,
                                                  protectionEnabled: protectionEnabled)
        return job.prompt + "\n\n" + block
    }

    /// The first line of the last thing the agent said, capped at 200 characters — the one line a
    /// card and `/jobs` show. `nil` when the run said nothing at all, which `status` treats as a
    /// failure: an empty bubble is no more of a reply than no bubble, so both land here.
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
    /// what actually broke, where a soft stop only says the loop was cut off. Last, a turn that
    /// reached the end with nothing said is a failure too: a hook that blocked the turn, a
    /// cancelled engine or a conversation deleted mid-run all land here, and reporting any of them
    /// as `completed` would put a green card on a run that did nothing.
    static func status(messages: [ChatMessage], denials: [BlockedToolCall], softStopped: Bool) -> JobRun.Status {
        if !denials.isEmpty { return .blockedOnApproval }
        if llmErrorHeadline(in: messages) != nil { return .failed }
        if softStopped { return .failed }
        if outcome(from: messages) == nil { return .failed }
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

    /// What the row records about why a run did not simply complete — and, when the run left no
    /// reply to show, what the card prints in its place.
    static func failureReason(status: JobRun.Status, messages: [ChatMessage],
                              blockedTool: String?) -> String? {
        switch status {
        case .blockedOnApproval:
            return "needs approval: \(blockedTool ?? "a gated tool")"
        case .failed:
            return llmErrorHeadline(in: messages) ?? softStopLine(in: messages) ?? noReplyReason
        case .running, .completed, .interrupted:
            return nil
        }
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
