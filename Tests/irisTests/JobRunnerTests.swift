import Testing
import Foundation
@testable import iris

/// #187 §6 — what a job fire actually is now: a turn in a hidden conversation of its own, a row in
/// `job_runs`, and one event card in the Activity conversation. The pure half (`outcome`,
/// `status`) is tested on its own because the precedence between a denial, an `[LLM_ERROR]` and a
/// soft stop is the part that decides whether a person is told something went wrong.
@MainActor
@Suite("JobRunner (#187)")
struct JobRunnerTests {

    // MARK: Fixtures

    private func job(name: String = "pr-sweep",
                     prompt: String = "Reply with just the word tick.",
                     profile: JobProfile = .readOnly,
                     destination: UUID? = nil) -> Job {
        Job(name: name, prompt: prompt, trigger: .schedule(.interval(seconds: 60)),
            profile: profile, destinationConversationId: destination)
    }

    private func textResponse(_ text: String, tokens: UsageMetadata? = nil) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: tokens)
    }

    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    private func denial(_ tool: String) -> BlockedToolCall {
        BlockedToolCall(toolName: tool, details: "whatever", at: Date())
    }

    // MARK: outcome

    @Test("the outcome is the first line of the last agent message")
    func outcomeIsFirstLineOfLastAgentMessage() {
        let messages = [
            ChatMessage(role: .agent, content: "an earlier answer"),
            ChatMessage(role: .agent, content: "swept 3 PRs\nand here is the long detail"),
            ChatMessage(role: .system, content: "a system line after it"),
        ]
        #expect(JobRunner.outcome(from: messages) == "swept 3 PRs")
    }

    @Test("a long first line is truncated to 200 characters")
    func outcomeIsTruncated() {
        let long = String(repeating: "x", count: 500)
        let outcome = JobRunner.outcome(from: [ChatMessage(role: .agent, content: long)])
        #expect(outcome?.count == 200)
    }

    @Test("a run that said nothing has no outcome")
    func outcomeIsNilWithoutAnAgentMessage() {
        #expect(JobRunner.outcome(from: []) == nil)
        #expect(JobRunner.outcome(from: [ChatMessage(role: .system, content: "only a system line")]) == nil)
        #expect(JobRunner.outcome(from: [ChatMessage(role: .agent, content: "   \n  ")]) == nil)
    }

    // MARK: status precedence

    @Test("a plain turn completes")
    func statusCompleted() {
        #expect(JobRunner.status(messages: [ChatMessage(role: .agent, content: "tick")],
                                 denials: [], softStopped: false) == .completed)
    }

    @Test("an [LLM_ERROR] system message fails the run")
    func statusFailedOnLLMError() {
        let error = ChatMessage(role: .system,
                                content: LLMErrorMessage.encode(LLMErrorDisplay(headline: "HTTP 503", detail: nil)))
        #expect(JobRunner.status(messages: [error], denials: [], softStopped: false) == .failed)
        #expect(JobRunner.llmErrorHeadline(in: [error]) == "HTTP 503")
    }

    @Test("a soft stop fails the run")
    func statusFailedOnSoftStop() {
        #expect(JobRunner.status(messages: [ChatMessage(role: .agent, content: "tick")],
                                 denials: [], softStopped: true) == .failed)
    }

    @Test("a denial outranks an LLM error, which outranks a soft stop")
    func statusPrecedence() {
        let error = ChatMessage(role: .system,
                                content: LLMErrorMessage.encode(LLMErrorDisplay(headline: "HTTP 503", detail: nil)))
        // Everything wrong at once: the thing a person can act on is the approval nobody gave.
        #expect(JobRunner.status(messages: [error], denials: [denial("run_command")], softStopped: true)
                == .blockedOnApproval)
        #expect(JobRunner.status(messages: [error], denials: [], softStopped: true) == .failed)
        #expect(JobRunner.llmErrorHeadline(in: [error]) == "HTTP 503")
    }

    @Test("a turn that said nothing is a failure, not a quiet success")
    func statusFailedOnNoReply() {
        #expect(JobRunner.status(messages: [], denials: [], softStopped: false) == .failed)
        #expect(JobRunner.status(messages: [ChatMessage(role: .system, content: "a system line")],
                                 denials: [], softStopped: false) == .failed)
        #expect(JobRunner.failureReason(status: .failed, messages: [], blockedTool: nil)
                == JobRunner.noReplyReason)
        // Still outranked: a denial says more about a silent run than its silence does.
        #expect(JobRunner.status(messages: [], denials: [denial("run_command")], softStopped: false)
                == .blockedOnApproval)
    }

    @Test("a blocked run's reason names the tool, so a card with no reply still says something")
    func failureReasonNamesTheBlockedTool() {
        let reason = JobRunner.failureReason(status: .blockedOnApproval, messages: [],
                                             blockedTool: "run_command")
        #expect(reason?.contains("run_command") == true)
        #expect(JobRunner.failureReason(status: .completed, messages: [], blockedTool: nil) == nil)
    }

    @Test("the soft-stop marker is the line softStopWithSummary posts")
    func softStopMarkerMatchesTheEngineLine() {
        let line = ChatMessage(role: .system,
                               content: "[Main agent] The loop detector tripped. \(IrisEngine.softStopMarker)")
        #expect(JobRunner.softStopped(in: [line]))
        #expect(!JobRunner.softStopped(in: [ChatMessage(role: .agent, content: IrisEngine.softStopMarker)]),
                "an agent message that quotes the line is not a soft stop")
        #expect(!JobRunner.softStopped(in: [ChatMessage(role: .system, content: "something else entirely")]))
    }

    // MARK: engine-level

    private func harness(_ responses: [GeminiResponse], autoApprove: Bool = true)
        throws -> (ConversationStore, AppState, IrisEngine, FakeLLMClient, UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = autoApprove
        let userConversation = UUID()
        state.createNewConversation(id: userConversation)
        state.selectedConversationId = userConversation
        let client = FakeLLMClient(responses: responses)
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, client, userConversation)
    }

    @Test("a completed run: hidden conversation, ledger row, one card, and the user's chat untouched")
    func completedRunEndToEnd() async throws {
        let usage = UsageMetadata(promptTokenCount: 11, candidatesTokenCount: 7, totalTokenCount: 18)
        let (store, state, engine, client, userConversation) = try harness([textResponse("tick", tokens: usage)])
        let job = self.job()
        try store.ledger.upsert(job)
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, now: { firedAt })

        await runner.run(job: job, reason: "schedule")

        // A conversation of its own, hidden from the sidebar.
        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.title.hasPrefix("pr-sweep · "))
        #expect(!SidebarOrdering.visible(state.conversations).contains { $0.id == background.id })
        #expect(state.selectedConversationId == userConversation, "and it never steals the selection")
        #expect(background.mainAgentSandbox == nil, "a readOnly job does not force a sandbox")

        // The ledger row.
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 10).first)
        #expect(run.status == .completed)
        #expect(run.outcome == "tick")
        #expect(run.triggerKind == "schedule")
        #expect(run.startedAt == firedAt)
        #expect(run.finishedAt == firedAt)
        #expect(run.promptTokens == 11)
        #expect(run.candidateTokens == 7)
        #expect(run.totalTokens == 18)
        #expect(run.transcriptConversationId == background.id)
        #expect(run.failureReason == nil)
        #expect(run.blockedTool == nil)

        // Exactly one card, in the Activity conversation.
        let activityId = state.activityConversationId()
        let activity = try #require(state.conversations.first { $0.id == activityId })
        let cards = activity.messages.filter { $0.role == .event }
        #expect(cards.count == 1)
        let card = try #require(EventCard.decode(cards[0].content))
        #expect(card.runId == run.id)
        #expect(card.jobId == job.id)
        #expect(card.status == .completed)
        #expect(card.outcome == "tick")
        #expect(card.totalTokens == 18)
        #expect(card.transcriptConversationId == background.id)

        // The conversation the user was looking at heard nothing.
        #expect(state.conversations.first { $0.id == userConversation }?.messages.isEmpty == true)
        #expect(state.conversations.first { $0.id == userConversation }?.history.isEmpty == true)

        // The strip shows the run as a job, and it is no longer running.
        let session = try #require(state.sessions.first { $0.id == background.id })
        #expect(session.kind == .job)
        #expect(session.role == "job:pr-sweep")
        if case .finished(let status, _) = session.phase {
            #expect(status == "completed")
        } else {
            Issue.record("the run's session is still open: \(session.phase)")
        }

        #expect(client.callCount == 1, "one fire is one turn")

        // A second fire is a second transcript, not a second turn in the first one.
        await runner.run(job: job, reason: "schedule")
        #expect(state.conversations.filter { $0.isBackground }.count == 2)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 2)
    }

    @Test("a mutating job's run is sandboxed and its changed paths reach the prompt")
    func mutatingJobRunsSandboxedWithChangedPaths() async throws {
        let (store, state, engine, _, _) = try harness([textResponse("done")])
        let job = self.job(name: "watch-src", prompt: "Review the change.", profile: .mutating)
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger)

        await runner.run(job: job, reason: "fsEvent", changedPaths: ["/tmp/a.swift", "/tmp/b.swift"])

        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.mainAgentSandbox == .sandboxed)
        let prompt = background.history.first?.parts.compactMap(\.text).joined() ?? ""
        #expect(prompt.contains("Review the change."))
        #expect(prompt.contains("/tmp/a.swift"))
        #expect(prompt.contains("/tmp/b.swift"))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "fsEvent")
    }

    @Test("a gated tool nobody can approve blocks the run and names the tool")
    func blockedOnApproval() async throws {
        // Unique, and outside every allowlist by construction: `PermissionManager` matches a rule
        // on the exact command string, so no global/project permission file can already hold it.
        // Inert as well as unique — a regression that let the background branch through must not
        // be a regression that runs something destructive.
        let command = "true --never-run-\(UUID().uuidString)"
        let (store, state, engine, _, _) = try harness([
            callResponse("run_command", ["command": .string(command)]),
            textResponse("I could not do that."),
        ], autoApprove: false)
        let job = self.job(name: "needs-hands", prompt: "Clean up.")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger)

        await runner.run(job: job, reason: "schedule")

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(run.blockedTool == "run_command")
        #expect(state.pendingApprovals.isEmpty, "an unattended run never parks on a dialog")

        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .blockedOnApproval)
        #expect(card.headline.contains("run_command"))
        #expect(card.headline.contains("needs-hands"))
        // The model did answer here, so the card shows what it said; the reason is on the row.
        #expect(card.outcome == "I could not do that.")
        #expect(run.failureReason?.contains("run_command") == true)
    }

    @Test("a run with nothing to say fails, and its card says why instead")
    func silentRunFailsAndTheCardCarriesTheReason() async throws {
        // A reply with nothing in it: no `[LLM_ERROR]`, no denial, no soft stop, and no line for a
        // card to show — the case that used to report as a clean `completed` with a blank card.
        // (A response with no parts at all takes the `[LLM_ERROR]` path instead, tested above.)
        let (store, state, engine, _, _) = try harness([textResponse(" ")])
        let job = self.job(name: "says-nothing")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger)

        await runner.run(job: job, reason: "schedule")

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.outcome == nil)
        #expect(run.failureReason == JobRunner.noReplyReason)

        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .failed)
        #expect(card.outcome == JobRunner.noReplyReason)
    }

    @Test("a run whose app state went away closes its row rather than leaving it running")
    func releasedEngineClosesTheRow() async throws {
        let (store, state, _, _, _) = try harness([textResponse("tick")])
        let job = self.job(name: "orphaned")
        try store.ledger.upsert(job)
        // Weakly held by the runner (`AppState.engine` → runner → engine would be a cycle), so
        // dropping the only other reference is what "the app went away mid-run" looks like.
        var engine: IrisEngine? = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                             protectionEnabled: false, sessionPeerCount: 0)
        let runner = JobRunner(state: state, engine: engine!, ledger: store.ledger)
        engine = nil

        await runner.run(job: job, reason: "schedule")

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .interrupted)
        #expect(run.failureReason == JobRunner.releasedReason)
        #expect(run.finishedAt != nil)
        let activity = state.conversations.first { $0.title == AppState.activityConversationTitle }
        #expect(activity?.messages.isEmpty ?? true, "nothing to deliver a card to, so no card")
    }

    @Test("the card goes to the job's destination when it has one")
    func cardGoesToTheJobsDestination() async throws {
        let (store, state, engine, _, userConversation) = try harness([textResponse("tick")])
        let job = self.job(destination: userConversation)
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger)

        await runner.run(job: job, reason: "schedule")

        let destination = try #require(state.conversations.first { $0.id == userConversation })
        #expect(destination.messages.filter { $0.role == .event }.count == 1)
    }

    // MARK: overlap and launch bookkeeping

    @Test("a skipped overlap is recorded as an interrupted run with no transcript")
    func recordSkipWritesAnInterruptedRow() throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "slow")
        try store.ledger.upsert(job)
        let at = Date(timeIntervalSince1970: 1_700_000_500)

        try JobRunner.recordSkip(job: job, ledger: store.ledger, now: at)

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .interrupted)
        #expect(run.failureReason == JobRunner.skipReason)
        #expect(run.transcriptConversationId == nil)
        #expect(run.startedAt == at)
        #expect(run.finishedAt == at)
        #expect(run.totalTokens == 0)
    }

    @Test("the scheduler's overlap skip calls the hook the engine wires to recordSkip")
    func schedulerSkipHookFires() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = JobScheduler(ledger: store.ledger, now: { now })
        let gate = JobSchedulerTests.Gate()
        await scheduler.setFireHandler { _, _ in await gate.arriveAndWait() }
        let ledger = store.ledger
        await scheduler.setOnSkip { job in
            try? JobRunner.recordSkip(job: job, ledger: ledger, now: now)
        }
        let job = self.job(name: "slow")
        try store.ledger.upsert(Job(id: job.id, name: job.name, prompt: job.prompt, trigger: job.trigger,
                                    nextFireAt: now.addingTimeInterval(-1)))

        let first = Task { await scheduler.tick() }
        await gate.waitForEntry()
        try store.ledger.setNextFire(jobId: job.id, at: now.addingTimeInterval(-1), lastRunAt: now)
        #expect(await scheduler.tick() == 0, "the overlap does not start a second copy")
        await gate.open()
        _ = await first.value

        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 1, "the skip is the only row — the fire handler here writes none")
        #expect(runs.first?.status == .interrupted)
        #expect(runs.first?.failureReason == JobRunner.skipReason)
    }

    @Test("a job held firing across several ticks is skipped — and recorded — exactly once")
    func repeatedTicksRecordOneSkip() async throws {
        let store = try ConversationStore.inMemory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = JobFireIntegrationTests.MovableClock(start)
        let scheduler = JobScheduler(ledger: store.ledger, now: { clock.now })
        let gate = JobSchedulerTests.Gate()
        await scheduler.setFireHandler { _, _ in await gate.arriveAndWait() }
        let ledger = store.ledger
        await scheduler.setOnSkip { job in try? JobRunner.recordSkip(job: job, ledger: ledger, now: clock.now) }
        let job = Job(name: "slow", prompt: "p", trigger: .schedule(.interval(seconds: 60)),
                      nextFireAt: start.addingTimeInterval(-1))
        try store.ledger.upsert(job)

        let firing = Task { await scheduler.tick() }
        await gate.waitForEntry()
        // Three polls while the first run is still going. The skip advances `nextFireAt` the way a
        // fire does, so only the first of them finds the job due at all.
        for offset in [61.0, 71.0, 81.0] {
            clock.set(start.addingTimeInterval(offset))
            #expect(await scheduler.tick() == 0)
        }
        await gate.open()
        _ = await firing.value

        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 1, "one dropped trigger is one row, not one per poll")
        #expect(runs.first?.status == .interrupted)
        #expect(try store.ledger.job(named: "slow")?.nextFireAt == start.addingTimeInterval(121))
    }

    @Test("a skipped job whose cron can never match again is paused, exactly as a fire would pause it")
    func skipPausesAnUnmatchableCadence() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = JobScheduler(ledger: store.ledger, now: { now })
        let gate = JobSchedulerTests.Gate()
        await scheduler.setFireHandler { _, _ in await gate.arriveAndWait() }
        let ledger = store.ledger
        await scheduler.setOnSkip { job in try? JobRunner.recordSkip(job: job, ledger: ledger, now: now) }
        let job = Job(name: "goes-dead", prompt: "p", trigger: .schedule(.interval(seconds: 60)),
                      nextFireAt: now.addingTimeInterval(-1))
        try store.ledger.upsert(job)

        let firing = Task { await scheduler.tick() }
        await gate.waitForEntry()
        // Its cadence is edited to one with no future match while the run is still going, and it
        // comes due again: the skip path must pause it with the same reason a fire would, rather
        // than clearing `nextFireAt` and leaving a job that looks merely idle.
        var dead = job
        dead.trigger = .schedule(.cron(CronSchedule(expression: "0 0 30 2 *", timeZone: "UTC")))
        dead.nextFireAt = now.addingTimeInterval(-1)
        try store.ledger.upsert(dead)
        #expect(await scheduler.tick() == 0)
        await gate.open()
        _ = await firing.value

        let back = try #require(try store.ledger.job(named: "goes-dead"))
        #expect(back.pausedReason == JobScheduler.unmatchableReason)
        #expect(back.nextFireAt == nil)
        // No skip row: the dropped trigger is not the news here, the dead cadence is, and that is
        // what `pausedReason` says. A skip row is for a job that is still on a schedule.
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty)
    }

    @Test("a job paused mid-run is neither skip-logged nor bumped along its cadence")
    func pausedJobInFlightIsNotSkipLogged() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = JobScheduler(ledger: store.ledger, now: { now })
        let gate = JobSchedulerTests.Gate()
        await scheduler.setFireHandler { _, _ in await gate.arriveAndWait() }
        let ledger = store.ledger
        await scheduler.setOnSkip { job in try? JobRunner.recordSkip(job: job, ledger: ledger, now: now) }
        let job = Job(name: "paused-mid-run", prompt: "p", trigger: .schedule(.interval(seconds: 60)),
                      nextFireAt: now.addingTimeInterval(-1))
        try store.ledger.upsert(job)

        let firing = Task { await scheduler.tick() }
        await gate.waitForEntry()
        // Paused while its run is still going, and due again: it must not be treated as an
        // overlap — no skip row, and its cleared cadence stays cleared.
        try store.ledger.setPaused(jobId: job.id, reason: "out of budget")
        try store.ledger.setNextFire(jobId: job.id, at: now.addingTimeInterval(-1), lastRunAt: now)
        #expect(await scheduler.tick() == 0)
        await gate.open()
        _ = await firing.value

        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty, "a pause is not a skip")
        #expect(try store.ledger.job(named: "paused-mid-run")?.nextFireAt == now.addingTimeInterval(-1),
                "and its cadence was not bumped past the trigger it never took")
    }

    @Test("launch bookkeeping closes interrupted runs and gives the scheduler somewhere to log a skip")
    func configureJobBookkeepingWiresBothHalves() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        let job = self.job(name: "launch")
        try store.ledger.upsert(job)
        let orphan = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.ledger.begin(run: orphan)

        await engine.configureJobBookkeeping(ledger: store.ledger)

        #expect(try store.ledger.run(id: orphan.id)?.status == .interrupted)

        // And the skip hook is wired: hold a fire open, poll again, and look for the row it wrote.
        let scheduler = try #require(await engine.jobScheduler)
        let gate = JobSchedulerTests.Gate()
        await scheduler.setFireHandler { _, _ in await gate.arriveAndWait() }
        try store.ledger.setNextFire(jobId: job.id, at: Date().addingTimeInterval(-1), lastRunAt: nil)
        let firing = Task { await scheduler.tick() }
        await gate.waitForEntry()
        try store.ledger.setNextFire(jobId: job.id, at: Date().addingTimeInterval(-1), lastRunAt: nil)
        #expect(await scheduler.tick() == 0)
        await gate.open()
        _ = await firing.value
        await scheduler.stop()

        let skips = try store.ledger.runs(jobId: job.id, limit: 10).filter { $0.failureReason == JobRunner.skipReason }
        #expect(skips.count == 1)
    }

    @Test("launch closes out the runs the last process died in the middle of")
    func launchClosesRunningRows() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        let job = self.job(name: "died-mid-run")
        try store.ledger.upsert(job)
        let orphan = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.ledger.begin(run: orphan)

        let closed = await engine.closeInterruptedRuns(ledger: store.ledger, at: Date(timeIntervalSince1970: 1_700_001_000))
        #expect(closed == 1)

        let row = try #require(try store.ledger.run(id: orphan.id))
        #expect(row.status == .interrupted)
        #expect(row.failureReason == IrisEngine.interruptedByQuitReason)
        #expect(row.finishedAt == Date(timeIntervalSince1970: 1_700_001_000))

        // Idempotent: `AppState.start()` can run more than once, and a second pass must not
        // interrupt a run that is happening right now.
        let second = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date())
        try store.ledger.begin(run: second)
        #expect(await engine.closeInterruptedRuns(ledger: store.ledger, at: Date()) == 0)
        #expect(try store.ledger.run(id: second.id)?.status == .running)
    }
}
