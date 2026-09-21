import Testing
import Foundation
import GRDB
@testable import iris

/// The stored half of deliverable 3's data layer (#187): migration `v10_job_policy`, the policy
/// columns on `jobs`, the blocked-call/approval columns on `job_runs`, and the budget, breaker and
/// gate queries the runner's admission check reads.
@Suite("JobLedgerPolicy")
struct JobLedgerPolicyTests {
    /// Whole seconds only: GRDB stores `Date` to the millisecond, so a `Date()` taken here would
    /// not round-trip equal.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    func seedJob(_ store: ConversationStore, _ name: String) throws -> Job {
        let job = Job(name: name, prompt: "p \(name)", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        return job
    }

    /// A run that happened: it has a transcript, which is what `runsStarted` reads as "this row
    /// was work". A refusal (a skip or a pause row) has none — see `makeRefusal`.
    func makeRun(_ job: Job, at: Date, status: JobRun.Status = .completed, tokens: Int = 0) -> JobRun {
        var run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: at,
                         status: status, transcriptConversationId: UUID())
        run.totalTokens = tokens
        return run
    }

    /// A row for a fire that never became a turn: no transcript, no tokens.
    func makeRefusal(_ job: Job, at: Date) -> JobRun {
        JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: at,
               status: .interrupted)
    }

    /// A gregorian calendar pinned to one zone, so a local-day boundary is the same wherever the
    /// test runs.
    func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal
    }

    // MARK: Policy columns on `jobs`

    @Test("policy, retryAttempt and queuedFire round-trip through upsert")
    func policyRoundTrip() throws {
        let store = try ConversationStore.inMemory()
        // Whole-second `createdAt`: GRDB stores dates to the millisecond, so a default `Date()`
        // would not compare equal on the way back.
        var job = Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 60)), createdAt: t0)
        job.policy = JobPolicy(overlap: .queue, catchUp: .replay(cap: 4), runTimeoutSeconds: 120,
                               perRunTokenBudget: 10, dailyTokenBudget: 20, maxRunsPerHour: 2,
                               retry: false)
        job.retryAttempt = 3
        job.queuedFire = t0
        try store.ledger.upsert(job)
        #expect(try store.ledger.job(named: "j") == job)

        // Upsert again with the policy back to default: the UPDATE branch must write it too.
        job.policy = JobPolicy()
        job.retryAttempt = 0
        job.queuedFire = nil
        try store.ledger.upsert(job)
        #expect(try store.ledger.job(named: "j") == job)
    }

    @Test("a NULL, malformed or non-text policy column reads back as the default policy")
    func nullPolicy() throws {
        let store = try ConversationStore.inMemory()
        let encoder = JSONEncoder()
        for (name, policy) in [("null", DatabaseValue.null), ("garbage", "{not json".databaseValue),
                               ("nottext", 42.databaseValue)] {
            try store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt, policy)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, name, "p", "schedule",
                                     String(decoding: try encoder.encode(Trigger.schedule(.interval(seconds: 60))), as: UTF8.self),
                                     t0, policy])
            }
            let back = try store.ledger.job(named: name)
            #expect(back?.policy == JobPolicy())
            #expect(back?.retryAttempt == 0)
            #expect(back?.queuedFire == nil)
        }
    }

    @Test("setRetry and setQueuedFire write only their columns and reject an unknown job")
    func retryAndQueueWrites() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        try store.ledger.setRetry(jobId: job.id, attempt: 2, nextFireAt: t0)
        try store.ledger.setQueuedFire(jobId: job.id, at: t0.addingTimeInterval(30))
        let back = try store.ledger.job(named: "j")!
        #expect(back.retryAttempt == 2 && back.nextFireAt == t0)
        #expect(back.queuedFire == t0.addingTimeInterval(30) && back.prompt == "p j")

        try store.ledger.setRetry(jobId: job.id, attempt: 0, nextFireAt: nil)
        try store.ledger.setQueuedFire(jobId: job.id, at: nil)
        let cleared = try store.ledger.job(named: "j")!
        #expect(cleared.retryAttempt == 0 && cleared.nextFireAt == nil && cleared.queuedFire == nil)

        let gone = UUID()
        #expect(throws: JobLedgerError.unknownJob(gone)) {
            try store.ledger.setRetry(jobId: gone, attempt: 1, nextFireAt: nil)
        }
        #expect(throws: JobLedgerError.unknownJob(gone)) {
            try store.ledger.setQueuedFire(jobId: gone, at: nil)
        }
    }

    // MARK: Breaker and budget queries

    @Test("runsStarted counts from the boundary inclusive, per job")
    func runsStartedBoundary() throws {
        let store = try ConversationStore.inMemory()
        let a = try seedJob(store, "a")
        let b = try seedJob(store, "b")
        for offset in [-1, 0, 1, 60] {
            try store.ledger.begin(run: makeRun(a, at: t0.addingTimeInterval(TimeInterval(offset))))
        }
        try store.ledger.begin(run: makeRun(b, at: t0))
        #expect(try store.ledger.runsStarted(jobId: a.id, since: t0) == 3)
        #expect(try store.ledger.runsStarted(jobId: a.id, since: t0.addingTimeInterval(61)) == 0)
        #expect(try store.ledger.runsStarted(jobId: b.id, since: t0) == 1)

        // A skip or a pause row is a fire that never became a turn, and the breaker counts work:
        // counting them would have a `.skip` job's own overlaps, or the row recording a breaker
        // pause, trip the breaker again the moment the job was resumed.
        for offset in [0, 1, 2] {
            try store.ledger.begin(run: makeRefusal(b, at: t0.addingTimeInterval(TimeInterval(offset))))
        }
        #expect(try store.ledger.runsStarted(jobId: b.id, since: t0) == 1)
    }

    @Test("tokensToday sums the local calendar day of the given calendar's time zone")
    func tokensTodayLocalDay() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let pacific = calendar("America/Los_Angeles")
        // 2026-09-21 14:13:20 UTC — 07:13:20 in Pacific, so local midnight is seven hours back.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let dayStart = pacific.startOfDay(for: now)
        #expect(dayStart == Date(timeIntervalSince1970: 1_789_974_000))

        try store.ledger.begin(run: makeRun(job, at: dayStart.addingTimeInterval(-1), tokens: 1))
        try store.ledger.begin(run: makeRun(job, at: dayStart, tokens: 10))
        try store.ledger.begin(run: makeRun(job, at: now, tokens: 100))
        try store.ledger.begin(run: makeRun(job, at: dayStart.addingTimeInterval(86_400), tokens: 1_000))
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: pacific, now: now) == 110)

        // The same rows against UTC, whose day started seven hours *earlier*: the run a second
        // before Pacific midnight is on the same UTC day, so it counts too, and the run a Pacific
        // day later is past the UTC day's end, so it still does not.
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: calendar("UTC"), now: now) == 111)
    }

    @Test("tokensToday with a nil jobId sums every job")
    func tokensTodayGlobal() throws {
        let store = try ConversationStore.inMemory()
        let a = try seedJob(store, "a")
        let b = try seedJob(store, "b")
        let utc = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try store.ledger.begin(run: makeRun(a, at: now, tokens: 5))
        try store.ledger.begin(run: makeRun(b, at: now, tokens: 7))
        try store.ledger.begin(run: makeRun(b, at: now.addingTimeInterval(-86_400), tokens: 900))
        #expect(try store.ledger.tokensToday(jobId: nil, calendar: utc, now: now) == 12)
        #expect(try store.ledger.tokensToday(jobId: a.id, calendar: utc, now: now) == 5)
    }

    @Test("a run the app quit during keeps what it reported, and the day's budget counts it")
    func recordUsageOutlivesAnUnfinishedRun() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let utc = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let run = makeRun(job, at: now, status: .running, tokens: 0)
        try store.ledger.begin(run: run)
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: utc, now: now) == 0)

        // Two rounds' worth: the figure is the turn's running total, not this round's, so the
        // second write replaces the first rather than adding to it.
        try store.ledger.recordUsage(runId: run.id, tokens: TokenUsage(promptTokenCount: 30,
                                                                       candidatesTokenCount: 10,
                                                                       totalTokenCount: 40))
        try store.ledger.recordUsage(runId: run.id, tokens: TokenUsage(promptTokenCount: 70,
                                                                       candidatesTokenCount: 20,
                                                                       totalTokenCount: 90))
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: utc, now: now) == 90,
                "a run in flight counts what it has reported")

        // The app quits here. `finish` never runs; the next launch's sweep closes the row — and
        // must leave the spend on it, or the run was free as far as every budget is concerned.
        #expect(try store.ledger.closeRunningRuns(reason: JobRunner.releasedReason, at: now.addingTimeInterval(10)) == 1)
        let back = try #require(try store.ledger.run(id: run.id))
        #expect(back.status == .interrupted)
        #expect(back.totalTokens == 90 && back.promptTokens == 70 && back.candidateTokens == 20)
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: utc, now: now) == 90)
        #expect(try store.ledger.tokensToday(jobId: nil, calendar: utc, now: now) == 90,
                "and against the global ceiling too")
    }

    @Test("a report from a turn the deadline already gave up on cannot reopen or rewrite the row")
    func recordUsageOnlyWritesARunningRow() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let utc = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let run = makeRun(job, at: now, status: .running, tokens: 0)
        try store.ledger.begin(run: run)
        try store.ledger.recordUsage(runId: run.id, tokens: TokenUsage(totalTokenCount: 40))
        try store.ledger.finish(runId: run.id, status: .failed, outcome: nil,
                                failureReason: TurnBudget.timeExceeded, blockedTool: nil,
                                tokens: TokenUsage(totalTokenCount: 40),
                                finishedAt: now.addingTimeInterval(1))

        // The orphaned turn runs on and reports another round. It must land nowhere: the row has
        // an ending already, and it is not this turn's to change.
        try store.ledger.recordUsage(runId: run.id, tokens: TokenUsage(totalTokenCount: 4_000))
        // And a run id that is not in the table is not an error either — unlike `finish`.
        try store.ledger.recordUsage(runId: UUID(), tokens: TokenUsage(totalTokenCount: 1))

        let back = try #require(try store.ledger.run(id: run.id))
        #expect(back.status == .failed)
        #expect(back.failureReason == TurnBudget.timeExceeded)
        #expect(back.totalTokens == 40)
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: utc, now: now) == 40)
    }

    @Test("usage reports today's tokens and the last hour's runs together")
    func usageQuery() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let utc = calendar("UTC")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try store.ledger.begin(run: makeRun(job, at: now.addingTimeInterval(-30), tokens: 4))
        try store.ledger.begin(run: makeRun(job, at: now.addingTimeInterval(-3_600), tokens: 6))
        try store.ledger.begin(run: makeRun(job, at: now.addingTimeInterval(-3_601), tokens: 8))
        #expect(try store.ledger.usage(jobId: job.id, now: now, calendar: utc)
                == JobUsage(tokensToday: 18, runsLastHour: 2))
    }

    // MARK: Blocked call, approval, gate signal

    @Test("setBlockedCall round-trips the call and clears it again")
    func blockedCallRoundTrip() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0, status: .blockedOnApproval)
        try store.ledger.begin(run: run)
        let call = BlockedCall(toolName: "write_file", args: ["path": .string("/tmp/x")],
                               cwd: "/tmp", reason: .profile, at: t0)
        try store.ledger.setBlockedCall(runId: run.id, call)
        #expect(try store.ledger.run(id: run.id)?.blockedCall == call)
        try store.ledger.setBlockedCall(runId: run.id, nil)
        #expect(try store.ledger.run(id: run.id)?.blockedCall == nil)
        #expect(throws: (any Error).self) { try store.ledger.setBlockedCall(runId: UUID(), call) }
    }

    @Test("a blockedCall that will not decode reads as nil without hiding the run")
    func corruptBlockedCall() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0)
        try store.ledger.begin(run: run)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE job_runs SET blockedCall = ? WHERE id = ?",
                           arguments: ["{not json", run.id.uuidString])
        }
        let back = try store.ledger.run(id: run.id)
        #expect(back?.id == run.id)
        #expect(back?.blockedCall == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1)
    }

    @Test("markApproved stamps once and refuses a second approval")
    func markApprovedOnce() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0, status: .blockedOnApproval)
        try store.ledger.begin(run: run)
        // Nothing to approve yet: a row with no blocked call must not burn its one claim.
        #expect(try store.ledger.markApproved(runId: run.id, at: t0) == false)
        #expect(try store.ledger.run(id: run.id)?.approvedAt == nil)
        try store.ledger.setBlockedCall(runId: run.id, BlockedCall(
            toolName: "run_command", args: ["command": .string("ls")], at: t0))
        #expect(try store.ledger.markApproved(runId: run.id, at: t0) == true)
        #expect(try store.ledger.run(id: run.id)?.approvedAt == t0)
        #expect(try store.ledger.markApproved(runId: run.id, at: t0.addingTimeInterval(60)) == false)
        #expect(try store.ledger.run(id: run.id)?.approvedAt == t0)
        #expect(try store.ledger.markApproved(runId: UUID(), at: t0) == false)
    }

    @Test("markApproved refuses a call the profile denied, however the caller asks")
    func markApprovedRefusesAProfileDenial() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0, status: .blockedOnApproval)
        try store.ledger.begin(run: run)
        try store.ledger.setBlockedCall(runId: run.id, BlockedCall(
            toolName: "write_file", args: ["path": .string("/tmp/x")], reason: .profile, at: t0))

        // Nothing can approve this into running: the job is read-only, so the answer does not
        // depend on a human. The refusal lives at the data layer so a UI is not the only thing
        // standing between a `.profile` row and a re-dispatch.
        #expect(try store.ledger.markApproved(runId: run.id, at: t0) == false)
        #expect(try store.ledger.run(id: run.id)?.approvedAt == nil)

        // The same row with an approval-reason call is claimable as before.
        try store.ledger.setBlockedCall(runId: run.id, BlockedCall(
            toolName: "run_command", args: ["command": .string("ls")], reason: .approval, at: t0))
        #expect(try store.ledger.markApproved(runId: run.id, at: t0) == true)
    }

    @Test("markApproved refuses a blocked call it cannot read")
    func markApprovedRefusesAnUnreadableCall() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0, status: .blockedOnApproval)
        try store.ledger.begin(run: run)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE job_runs SET blockedCall = ? WHERE id = ?",
                           arguments: ["{not json at all", run.id.uuidString])
        }
        // There is a blocked call here and this build cannot tell what it is. The guard exists
        // because it is the last line before a re-dispatch, so it fails closed.
        #expect(try store.ledger.markApproved(runId: run.id, at: t0) == false)
        #expect(try store.ledger.run(id: run.id)?.approvedAt == nil)
    }

    @Test("parentRunId round-trips on a run")
    func parentRunId() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let parent = makeRun(job, at: t0)
        try store.ledger.begin(run: parent)
        var child = makeRun(job, at: t0.addingTimeInterval(1))
        child.parentRunId = parent.id
        try store.ledger.begin(run: child)
        #expect(try store.ledger.run(id: child.id)?.parentRunId == parent.id)
        #expect(try store.ledger.run(id: parent.id)?.parentRunId == nil)
    }

    @Test("lastGateSignal returns the newest recorded signal, ignoring rows that have none")
    func gateSignals() throws {
        let store = try ConversationStore.inMemory()
        let a = try seedJob(store, "a")
        let b = try seedJob(store, "b")
        #expect(try store.ledger.lastGateSignal(jobId: a.id) == nil)

        let older = makeRun(a, at: t0)
        let newer = makeRun(a, at: t0.addingTimeInterval(60))
        let newest = makeRun(a, at: t0.addingTimeInterval(120))
        for run in [older, newer, newest] { try store.ledger.begin(run: run) }
        try store.ledger.begin(run: makeRun(b, at: t0.addingTimeInterval(180)))

        try store.ledger.setGateSignal(runId: older.id, "etag-1")
        try store.ledger.setGateSignal(runId: newer.id, "etag-2")
        // `newest` recorded nothing — a gate that errored — so the last known signal stands.
        #expect(try store.ledger.lastGateSignal(jobId: a.id) == "etag-2")
        #expect(try store.ledger.lastGateSignal(jobId: b.id) == nil)

        try store.ledger.setGateSignal(runId: newest.id, "etag-3")
        #expect(try store.ledger.lastGateSignal(jobId: a.id) == "etag-3")
        try store.ledger.setGateSignal(runId: newest.id, nil)
        #expect(try store.ledger.lastGateSignal(jobId: a.id) == "etag-2")
        #expect(throws: (any Error).self) { try store.ledger.setGateSignal(runId: UUID(), "x") }
    }

    // MARK: Migration

    @Test("a v9 database migrates to v10 with its jobs, runs and conversations intact")
    func migratesV9ToV10() throws {
        let queue = try DatabaseQueue()
        try ConversationStore.migrator.migrate(queue, upTo: "v9_jobs")

        let jobId = UUID(), badId = UUID(), runId = UUID(), convId = UUID()
        // Exactly what deliverable 1 wrote: the gate is a bare command string inside the trigger
        // JSON, not a tagged object.
        let legacyTrigger = #"{"kind":"poll","poll":{"schedule":{"kind":"interval","seconds":300},"gate":"test -f /tmp/x"}}"#
        // And a gate kind no build knows, to prove the lenient policy read did not make gate
        // decoding lenient too.
        let futureTrigger = #"{"kind":"poll","poll":{"schedule":{"kind":"interval","seconds":300},"gate":{"kind":"quantum"}}}"#
        try queue.write { db in
            for (id, name, trigger) in [(jobId, "old", legacyTrigger), (badId, "future", futureTrigger)] {
                try db.execute(sql: """
                    INSERT INTO jobs (id, name, prompt, triggerKind, trigger, profile, createdAt, enabled)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id.uuidString, name, "p", "poll", trigger, "readOnly", t0, true])
            }
            try db.execute(sql: """
                INSERT INTO job_runs (id, jobId, jobName, triggerKind, startedAt, status,
                                      promptTokens, candidateTokens, totalTokens)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [runId.uuidString, jobId.uuidString, "old", "poll", t0, "completed", 1, 2, 3])
            try db.execute(sql: """
                INSERT INTO conversations (id, position, title, createdAt, updatedAt,
                                           messageCountSinceReflection, goalIterationCount, tokenUsage)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [convId.uuidString, 1, "kept", t0, t0, 0, 0, "{}"])
        }

        try ConversationStore.migrator.migrate(queue)

        let ledger = JobLedger(writer: queue)
        let jobs = try ledger.jobs()
        // The legacy row loads, its bare string gate read as the script gate it always meant; the
        // unknown gate kind is skipped and counted rather than guessed at.
        #expect(jobs.map(\.name) == ["old"])
        #expect(ledger.unreadableJobCount == 1)
        let job = try #require(jobs.first)
        #expect(job.id == jobId)
        #expect(job.trigger == .poll(PollSpec(schedule: .interval(seconds: 300),
                                              gate: .script(command: "test -f /tmp/x", mounts: [],
                                                            timeoutSeconds: PollSpec.legacyGateTimeoutSeconds))))
        #expect(job.policy == JobPolicy() && job.retryAttempt == 0 && job.queuedFire == nil)
        let run = try #require(try ledger.run(id: runId))
        #expect(run.totalTokens == 3 && run.blockedCall == nil && run.approvedAt == nil && run.parentRunId == nil)
        try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT title, jobProfile FROM conversations WHERE id = ?",
                                                    arguments: [convId.uuidString]))
            #expect(row["title"] as String? == "kept")
            #expect((row["jobProfile"] as DatabaseValue?)?.isNull == true)
        }
    }

    // MARK: Conversation.jobProfile

    @Test("jobProfile round-trips through the store and is nil when absent")
    func conversationJobProfile() throws {
        let store = try ConversationStore.inMemory()
        var run = Conversation(id: UUID(), title: "run"); run.jobProfile = .mutating
        let plain = Conversation(id: UUID(), title: "plain")
        for conv in [run, plain] {
            var cs = ChangeSet(); cs.created = true; cs.metadata = true
            try store.apply([ConversationWrite(id: conv.id, snapshot: conv, changes: cs)])
        }
        let back = try store.loadAll().conversations
        #expect(back.first { $0.id == run.id }?.jobProfile == .mutating)
        #expect(back.first { $0.id == plain.id }?.jobProfile == nil)

        // And the UPDATE branch clears it again.
        run.jobProfile = nil
        var cs = ChangeSet(); cs.metadata = true
        try store.apply([ConversationWrite(id: run.id, snapshot: run, changes: cs)])
        #expect(try store.loadAll().conversations.first { $0.id == run.id }?.jobProfile == nil)
    }

    @Test("a jobProfile this build does not recognize narrows to readOnly; only NULL reads as nil")
    func unrecognizedJobProfile() throws {
        let store = try ConversationStore.inMemory()
        let conv = Conversation(id: UUID(), title: "run")
        var cs = ChangeSet(); cs.created = true; cs.metadata = true
        try store.apply([ConversationWrite(id: conv.id, snapshot: conv, changes: cs)])

        // nil is "not a job run", which is the *unnarrowed* tool surface: a stamped profile this
        // build cannot read must not degrade to it.
        try store.writer.write { db in
            try db.execute(sql: "UPDATE conversations SET jobProfile = ? WHERE id = ?",
                           arguments: ["omnipotent", conv.id.uuidString])
        }
        #expect(try store.loadAll().conversations.first { $0.id == conv.id }?.jobProfile == .readOnly)

        // Not even text: same answer.
        try store.writer.write { db in
            try db.execute(sql: "UPDATE conversations SET jobProfile = ? WHERE id = ?",
                           arguments: [7, conv.id.uuidString])
        }
        #expect(try store.loadAll().conversations.first { $0.id == conv.id }?.jobProfile == .readOnly)

        try store.writer.write { db in
            try db.execute(sql: "UPDATE conversations SET jobProfile = NULL WHERE id = ?",
                           arguments: [conv.id.uuidString])
        }
        #expect(try store.loadAll().conversations.first { $0.id == conv.id }?.jobProfile == nil)
    }

    @Test("Conversation decodes with jobProfile nil when the key is absent")
    func conversationLenientDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","messages":[],"history":[],"tokenUsage":{},"messageCountSinceReflection":0,"goalIterationCount":0}"#
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(json.utf8)).jobProfile == nil)
    }
}
