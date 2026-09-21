import Testing
import Foundation
import GRDB
@testable import iris

@Suite("JobRunLedger")
struct JobRunLedgerTests {
    /// Whole seconds only: GRDB stores `Date` to the millisecond, so a `Date()` taken here would
    /// not round-trip equal.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    func seedJob(_ store: ConversationStore, _ name: String) throws -> Job {
        let job = Job(name: name, prompt: "p \(name)", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        return job
    }

    func makeRun(_ job: Job, at: Date, status: JobRun.Status = .running, transcript: UUID? = nil) -> JobRun {
        JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: at,
               status: status, transcriptConversationId: transcript)
    }

    // MARK: begin / run(id:)

    @Test("begin then run(id:) round-trips every field")
    func roundTrip() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let transcript = UUID()
        let run = makeRun(job, at: t0, transcript: transcript)
        try store.ledger.begin(run: run)
        #expect(try store.ledger.run(id: run.id) == run)
        #expect(try store.ledger.run(id: UUID()) == nil)
    }

    // MARK: finish

    @Test("finish sets status, outcome, tokens and finishedAt, truncating outcome to 200 characters")
    func finishWrites() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0)
        try store.ledger.begin(run: run)
        // First and last characters differ, so a suffix would fail this as loudly as no truncation.
        let long = "A" + String(repeating: "x", count: 298) + "Z"
        try store.ledger.finish(
            runId: run.id, status: .completed, outcome: long,
            failureReason: nil, blockedTool: nil,
            tokens: TokenUsage(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 7),
            finishedAt: t0.addingTimeInterval(60))
        let back = try #require(try store.ledger.run(id: run.id))
        #expect(back.status == .completed)
        #expect(back.outcome?.count == 200)
        #expect(back.outcome?.hasPrefix("A") == true)
        #expect(back.outcome?.hasSuffix("Z") == false)
        #expect(back.finishedAt == t0.addingTimeInterval(60))
        #expect(back.promptTokens == 3 && back.candidateTokens == 4 && back.totalTokens == 7)
        #expect(back.startedAt == t0 && back.jobName == "j")
    }

    @Test("finish records a blocked run's tool and reason")
    func finishBlocked() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0)
        try store.ledger.begin(run: run)
        try store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil,
                                failureReason: "needs approval", blockedTool: "run_command",
                                tokens: TokenUsage(), finishedAt: t0.addingTimeInterval(5))
        let back = try #require(try store.ledger.run(id: run.id))
        #expect(back.status == .blockedOnApproval)
        #expect(back.failureReason == "needs approval" && back.blockedTool == "run_command")
        #expect(back.outcome == nil)
    }

    @Test("finish leaves the transcript id and an acknowledgement alone")
    func finishPreservesUntouchedColumns() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let transcript = UUID()
        let run = makeRun(job, at: t0, status: .failed, transcript: transcript)
        try store.ledger.begin(run: run)
        try store.ledger.acknowledge(runId: run.id, at: t0.addingTimeInterval(30))
        try store.ledger.finish(runId: run.id, status: .failed, outcome: "tried",
                                failureReason: "boom", blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: t0.addingTimeInterval(60))
        let back = try #require(try store.ledger.run(id: run.id))
        #expect(back.transcriptConversationId == transcript)
        #expect(back.acknowledgedAt == t0.addingTimeInterval(30))
        #expect(back.failureReason == "boom")
    }

    @Test("finish on an id that is not in the table throws unknownRun")
    func finishUnknown() throws {
        let store = try ConversationStore.inMemory()
        let missing = UUID()
        #expect(throws: JobLedgerError.unknownRun(missing)) {
            try store.ledger.finish(runId: missing, status: .completed, outcome: nil,
                                    failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                    finishedAt: self.t0)
        }
    }

    // MARK: listings

    @Test("runs(jobId:limit:) is newest first, limited, and scoped to one job")
    func runsForJob() throws {
        let store = try ConversationStore.inMemory()
        let a = try seedJob(store, "a")
        let b = try seedJob(store, "b")
        for i in 0..<4 {
            try store.ledger.begin(run: makeRun(a, at: t0.addingTimeInterval(Double(i) * 60)))
        }
        try store.ledger.begin(run: makeRun(b, at: t0.addingTimeInterval(1000)))
        let newest = try store.ledger.runs(jobId: a.id, limit: 2)
        #expect(newest.map(\.startedAt) == [t0.addingTimeInterval(180), t0.addingTimeInterval(120)])
        #expect(newest.allSatisfy { $0.jobId == a.id })
        #expect(try store.ledger.runs(jobId: a.id, limit: 100).count == 4)
    }

    // MARK: runCount / runs(idPrefix:)

    @Test("runCount counts one job's runs, and one status of them, without decoding a row")
    func counts() throws {
        let store = try ConversationStore.inMemory()
        let a = try seedJob(store, "a")
        let b = try seedJob(store, "b")
        let running = makeRun(a, at: t0)
        try store.ledger.begin(run: running)
        try store.ledger.begin(run: makeRun(a, at: t0.addingTimeInterval(60)))
        try store.ledger.begin(run: makeRun(b, at: t0.addingTimeInterval(120)))
        try store.ledger.finish(runId: running.id, status: .completed, outcome: nil,
                                failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: t0.addingTimeInterval(1))

        #expect(try store.ledger.runCount(jobId: a.id) == 2)
        #expect(try store.ledger.runCount(jobId: a.id, status: .running) == 1)
        #expect(try store.ledger.runCount(jobId: a.id, status: .completed) == 1)
        #expect(try store.ledger.runCount(jobId: a.id, status: .failed) == 0)
        #expect(try store.ledger.runCount(jobId: UUID()) == 0)
    }

    /// The prefix read is what makes a run reachable by the eight characters a card prints, however
    /// old it is — `recentRuns` would have to guess a window wide enough to contain it.
    @Test("runs(idPrefix:) matches on a prefix, ignoring case and hyphens, and is capped")
    func prefixLookup() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "a")
        func seed(_ id: String, at offset: Double) throws -> UUID {
            let uuid = UUID(uuidString: id)!
            var run = makeRun(job, at: t0.addingTimeInterval(offset))
            run = JobRun(id: uuid, jobId: run.jobId, jobName: run.jobName,
                         triggerKind: run.triggerKind, startedAt: run.startedAt)
            try store.ledger.begin(run: run)
            return uuid
        }
        let target = try seed("1A2B3C4D-0000-0000-0000-000000000001", at: 0)
        _ = try seed("99999999-0000-0000-0000-000000000002", at: 60)

        #expect(try store.ledger.runs(idPrefix: "1a2b3c4d").map(\.id) == [target])
        #expect(try store.ledger.runs(idPrefix: "1A2B3C4D-0000").map(\.id) == [target])
        #expect(try store.ledger.runs(idPrefix: "1a2b3c4d0000").map(\.id) == [target],
                "a paste that lost its hyphens is the same id")
        #expect(try store.ledger.runs(idPrefix: target.uuidString).map(\.id) == [target])
        #expect(try store.ledger.runs(idPrefix: "abcdef01").isEmpty)
        #expect(try store.ledger.runs(idPrefix: "").isEmpty)
    }

    /// `%` and `_` arrive from a person's typing. Treated as LIKE wildcards they would match every
    /// run in the table, and a `/jobs ack %` would acknowledge whichever one came back first.
    @Test("a LIKE wildcard in the prefix is a literal, not a match-everything")
    func prefixWildcardsAreLiteral() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "a")
        try store.ledger.begin(run: makeRun(job, at: t0))
        #expect(try store.ledger.runs(idPrefix: "%%%%%%%%").isEmpty)
        #expect(try store.ledger.runs(idPrefix: "________").isEmpty)
    }

    @Test("recentRuns is newest first across jobs")
    func recent() throws {
        let store = try ConversationStore.inMemory()
        let a = try seedJob(store, "a")
        let b = try seedJob(store, "b")
        try store.ledger.begin(run: makeRun(a, at: t0))
        try store.ledger.begin(run: makeRun(b, at: t0.addingTimeInterval(60)))
        try store.ledger.begin(run: makeRun(a, at: t0.addingTimeInterval(120)))
        #expect(try store.ledger.recentRuns(limit: 10).map(\.jobName) == ["a", "b", "a"])
        #expect(try store.ledger.recentRuns(limit: 2).map(\.startedAt)
            == [t0.addingTimeInterval(120), t0.addingTimeInterval(60)])
    }

    @Test("unacknowledgedFailures takes failed and blocked runs oldest first, skipping acknowledged and completed")
    func failures() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let failed = makeRun(job, at: t0, status: .failed)
        let blocked = makeRun(job, at: t0.addingTimeInterval(60), status: .blockedOnApproval)
        let acked = makeRun(job, at: t0.addingTimeInterval(120), status: .failed)
        let done = makeRun(job, at: t0.addingTimeInterval(180), status: .completed)
        let running = makeRun(job, at: t0.addingTimeInterval(240))
        for run in [blocked, failed, acked, done, running] { try store.ledger.begin(run: run) }
        try store.ledger.acknowledge(runId: acked.id, at: t0.addingTimeInterval(300))
        #expect(try store.ledger.unacknowledgedFailures().map(\.id) == [failed.id, blocked.id])
    }

    @Test("acknowledge stamps the row and throws unknownRun for a missing id")
    func acknowledge() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let run = makeRun(job, at: t0, status: .failed)
        try store.ledger.begin(run: run)
        try store.ledger.acknowledge(runId: run.id, at: t0.addingTimeInterval(90))
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt == t0.addingTimeInterval(90))
        #expect(try store.ledger.unacknowledgedFailures().isEmpty)
        let missing = UUID()
        #expect(throws: JobLedgerError.unknownRun(missing)) {
            try store.ledger.acknowledge(runId: missing, at: self.t0)
        }
    }

    @Test("closeRunningRuns interrupts only the running rows and returns how many")
    func closeRunning() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let one = makeRun(job, at: t0)
        let two = makeRun(job, at: t0.addingTimeInterval(60))
        let done = makeRun(job, at: t0.addingTimeInterval(120), status: .completed)
        for run in [one, two, done] { try store.ledger.begin(run: run) }
        let closed = try store.ledger.closeRunningRuns(reason: "app quit", at: t0.addingTimeInterval(200))
        #expect(closed == 2)
        let back = try #require(try store.ledger.run(id: one.id))
        #expect(back.status == .interrupted && back.failureReason == "app quit")
        #expect(back.finishedAt == t0.addingTimeInterval(200))
        #expect(try store.ledger.run(id: done.id)?.status == .completed)
        #expect(try store.ledger.run(id: done.id)?.failureReason == nil)
        #expect(try store.ledger.closeRunningRuns(reason: "again", at: self.t0) == 0)
    }

    // MARK: pruneDecision (pure)

    let ninetyDays: TimeInterval = 90 * 24 * 3600

    func oldRun(_ jobId: UUID, ageDays: Double, status: JobRun.Status, acknowledged: Bool = false,
                transcript: UUID? = nil) -> JobRun {
        var run = JobRun(jobId: jobId, jobName: "j", triggerKind: "schedule",
                         startedAt: t0.addingTimeInterval(-ageDays * 24 * 3600), status: status,
                         transcriptConversationId: transcript)
        if acknowledged { run.acknowledgedAt = t0 }
        return run
    }

    @Test("a row past the retention window is deleted unless it is an unacknowledged failure")
    func pruneDecisionAge() throws {
        let job = UUID()
        let old = oldRun(job, ageDays: 91, status: .completed)
        let openFailure = oldRun(job, ageDays: 91, status: .failed)
        let openBlocked = oldRun(job, ageDays: 91, status: .blockedOnApproval)
        let ackedFailure = oldRun(job, ageDays: 91, status: .failed, acknowledged: true)
        let young = oldRun(job, ageDays: 1, status: .completed)
        let decision = JobLedger.pruneDecision(
            runs: [old, openFailure, openBlocked, ackedFailure, young],
            now: t0, rowRetention: ninetyDays, transcriptsPerJob: 20)
        #expect(Set(decision.deleteRunIds) == Set([old.id, ackedFailure.id]))
        #expect(decision.deleteTranscriptIds.isEmpty)
    }

    @Test("a deleted row's transcript goes with it")
    func pruneDecisionDeletedTranscript() throws {
        let job = UUID()
        let transcript = UUID()
        let old = oldRun(job, ageDays: 91, status: .completed, transcript: transcript)
        let decision = JobLedger.pruneDecision(runs: [old], now: t0, rowRetention: ninetyDays,
                                               transcriptsPerJob: 20)
        #expect(decision.deleteRunIds == [old.id])
        #expect(decision.deleteTranscriptIds == [transcript])
    }

    @Test("beyond the per-job transcript cap the oldest transcripts go, except an unacknowledged failure's")
    func pruneDecisionCap() throws {
        let job = UUID()
        // 25 recent runs, newest first by index 0. The 5 oldest are over a cap of 20; run 22 is an
        // unacknowledged failure, so its transcript stays.
        var runs: [JobRun] = []
        for i in 0..<25 {
            let failed = i == 22
            runs.append(JobRun(jobId: job, jobName: "j", triggerKind: "schedule",
                               startedAt: t0.addingTimeInterval(-Double(i) * 60),
                               status: failed ? .failed : .completed,
                               transcriptConversationId: UUID()))
        }
        let decision = JobLedger.pruneDecision(runs: runs, now: t0, rowRetention: ninetyDays,
                                               transcriptsPerJob: 20)
        #expect(decision.deleteRunIds.isEmpty)
        let expected = [20, 21, 23, 24].map { runs[$0].transcriptConversationId! }
        #expect(Set(decision.deleteTranscriptIds) == Set(expected))
        #expect(decision.deleteTranscriptIds.count == 4)
    }

    @Test("the cap counts per job and ignores runs with no transcript")
    func pruneDecisionPerJobAndNilTranscripts() throws {
        let a = UUID()
        let b = UUID()
        var runs: [JobRun] = []
        for i in 0..<3 {
            for job in [a, b] {
                runs.append(JobRun(jobId: job, jobName: "j", triggerKind: "schedule",
                                   startedAt: t0.addingTimeInterval(-Double(i) * 60),
                                   status: .completed, transcriptConversationId: UUID()))
            }
            // A transcript-less run of each job must not use up a slot under the cap.
            for job in [a, b] {
                runs.append(JobRun(jobId: job, jobName: "j", triggerKind: "schedule",
                                   startedAt: t0.addingTimeInterval(-Double(i) * 60 - 1),
                                   status: .completed))
            }
        }
        let decision = JobLedger.pruneDecision(runs: runs, now: t0, rowRetention: ninetyDays,
                                               transcriptsPerJob: 2)
        // Each job keeps its two newest transcripts and drops its third.
        let dropped = runs.filter { $0.startedAt == self.t0.addingTimeInterval(-120) }
            .compactMap(\.transcriptConversationId)
        #expect(Set(decision.deleteTranscriptIds) == Set(dropped))
        #expect(decision.deleteTranscriptIds.count == 2)
        #expect(decision.deleteRunIds.isEmpty)
    }

    @Test("a transcript another surviving run still references is not deleted")
    func pruneDecisionSharedTranscript() throws {
        let job = UUID()
        let shared = UUID()
        let old = oldRun(job, ageDays: 91, status: .completed, transcript: shared)
        let young = oldRun(job, ageDays: 1, status: .completed, transcript: shared)
        let decision = JobLedger.pruneDecision(runs: [old, young], now: t0,
                                               rowRetention: ninetyDays, transcriptsPerJob: 20)
        #expect(decision.deleteRunIds == [old.id])
        #expect(decision.deleteTranscriptIds.isEmpty)
    }

    @Test("the decision does not depend on the order the runs arrive in")
    func pruneDecisionOrderIndependent() throws {
        let a = UUID()
        let b = UUID()
        var runs: [JobRun] = []
        for i in 0..<6 {
            for job in [a, b] {
                var run = JobRun(jobId: job, jobName: "j", triggerKind: "schedule",
                                 startedAt: t0.addingTimeInterval(-Double(i) * 24 * 3600 - 91 * 24 * 3600),
                                 status: i == 1 ? .failed : .completed,
                                 transcriptConversationId: UUID())
                if i == 1 { run.acknowledgedAt = nil } else { run.acknowledgedAt = t0 }
                runs.append(run)
            }
        }
        // Two runs of the same job start in the same instant, so only the id can break the tie.
        runs.append(JobRun(jobId: a, jobName: "j", triggerKind: "schedule", startedAt: t0,
                           status: .completed, transcriptConversationId: UUID()))
        runs.append(JobRun(jobId: a, jobName: "j", triggerKind: "schedule", startedAt: t0,
                           status: .completed, transcriptConversationId: UUID()))
        func decide(_ input: [JobRun]) -> JobLedger.PruneDecision {
            JobLedger.pruneDecision(runs: input, now: t0, rowRetention: ninetyDays,
                                    transcriptsPerJob: 3)
        }
        let forward = decide(runs)
        #expect(decide(runs.reversed()) == forward)
        #expect(decide(runs.shuffled()) == forward)
        #expect(!forward.deleteRunIds.isEmpty && !forward.deleteTranscriptIds.isEmpty)
    }

    @Test("a row exactly at the cutoff is kept: retention is strictly older than")
    func pruneDecisionBoundary() throws {
        let job = UUID()
        let atCutoff = oldRun(job, ageDays: 90, status: .completed, transcript: UUID())
        let justPast = oldRun(job, ageDays: 90.001, status: .completed)
        let decision = JobLedger.pruneDecision(runs: [atCutoff, justPast], now: t0,
                                               rowRetention: ninetyDays, transcriptsPerJob: 20)
        #expect(decision.deleteRunIds == [justPast.id])
        #expect(decision.deleteTranscriptIds.isEmpty)
    }

    @Test("transcriptsPerJob of zero marks every transcript but an unacknowledged failure's")
    func pruneDecisionZeroCap() throws {
        let job = UUID()
        let done = oldRun(job, ageDays: 1, status: .completed, transcript: UUID())
        let acked = oldRun(job, ageDays: 2, status: .failed, acknowledged: true, transcript: UUID())
        let open = oldRun(job, ageDays: 3, status: .failed, transcript: UUID())
        let blocked = oldRun(job, ageDays: 4, status: .blockedOnApproval, transcript: UUID())
        let decision = JobLedger.pruneDecision(runs: [done, acked, open, blocked], now: t0,
                                               rowRetention: ninetyDays, transcriptsPerJob: 0)
        #expect(decision.deleteRunIds.isEmpty)
        #expect(Set(decision.deleteTranscriptIds)
            == Set([done, acked].compactMap(\.transcriptConversationId)))
    }

    @Test("an unacknowledged failure past retention and past the cap keeps both its row and its transcript")
    func pruneDecisionOpenFailureExemptFromBoth() throws {
        let job = UUID()
        let open = oldRun(job, ageDays: 200, status: .failed, transcript: UUID())
        var runs = [open]
        for i in 0..<5 {
            runs.append(oldRun(job, ageDays: Double(i), status: .completed, transcript: UUID()))
        }
        let decision = JobLedger.pruneDecision(runs: runs, now: t0, rowRetention: ninetyDays,
                                               transcriptsPerJob: 2)
        #expect(!decision.deleteRunIds.contains(open.id))
        #expect(!decision.deleteTranscriptIds.contains(open.transcriptConversationId!))
        // The three completed runs below the cap still lose their transcripts, rows intact.
        #expect(decision.deleteRunIds.isEmpty)
        #expect(decision.deleteTranscriptIds.count == 3)
    }

    // MARK: prune

    @Test("prune deletes exactly the rows its decision names and returns it")
    func pruneDeletes() throws {
        let store = try ConversationStore.inMemory()
        let job = try seedJob(store, "j")
        let transcript = UUID()
        let old = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                         startedAt: t0.addingTimeInterval(-91 * 24 * 3600), status: .completed,
                         transcriptConversationId: transcript)
        let openFailure = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                                 startedAt: t0.addingTimeInterval(-91 * 24 * 3600), status: .failed)
        let young = makeRun(job, at: t0.addingTimeInterval(-60))
        for run in [old, openFailure, young] { try store.ledger.begin(run: run) }
        let decision = try store.ledger.prune(now: t0, rowRetention: ninetyDays, transcriptsPerJob: 20)
        #expect(decision.deleteRunIds == [old.id])
        #expect(decision.deleteTranscriptIds == [transcript])
        #expect(try store.ledger.run(id: old.id) == nil)
        #expect(Set(try store.ledger.recentRuns(limit: 100).map(\.id)) == Set([openFailure.id, young.id]))
    }
}
