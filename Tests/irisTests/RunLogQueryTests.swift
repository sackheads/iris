import Testing
import Foundation
@testable import IrisKit

/// D6 decision 15: the run log reads every row the ledger holds, newest first, in pages that
/// neither drop nor repeat a row, gate checks hidden unless asked for.
@Suite("Run log query (D6)")
struct RunLogQueryTests {
    private func makeLedger() throws -> JobLedger { try ConversationStore.inMemory().ledger }

    private func job(_ name: String = "pr-sweep", action: JobAction = .prompt) -> Job {
        Job(name: name, prompt: "do it", trigger: .schedule(.interval(seconds: 60)), action: action)
    }

    @discardableResult
    private func row(_ job: Job, at startedAt: Date, status: JobRun.Status = .completed,
                     outcome: String? = "done", transcript: UUID? = UUID(),
                     ledger: JobLedger) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: startedAt,
                         transcriptConversationId: transcript)
        try ledger.begin(run: run)
        if status != .running {
            try ledger.finish(runId: run.id, status: status, outcome: outcome, failureReason: nil,
                              blockedTool: nil, tokens: TokenUsage(), finishedAt: startedAt)
        }
        return run
    }

    @Test("running rows, built-ins and stillborn rows are all in the log")
    func includesWhatRecentRunsHides() throws {
        let ledger = try makeLedger()
        let j = job(), digest = job("Daily digest", action: .builtin(DailyDigest.name))
        try ledger.upsert(j); try ledger.upsert(digest)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let running = try row(j, at: base, status: .running, ledger: ledger)
        let builtin = try row(digest, at: base.addingTimeInterval(1), transcript: nil, ledger: ledger)
        let stillborn = try row(j, at: base.addingTimeInterval(2), status: .interrupted,
                                outcome: nil, transcript: nil, ledger: ledger)

        let ids = try ledger.runLog(limit: 10).runs.map(\.id)
        #expect(Set(ids) == [running.id, builtin.id, stillborn.id])
        #expect(try ledger.recentRuns(limit: 10).isEmpty, "recentRuns hides all three, which is why the log has its own query")
    }

    @Test("gate-unchanged rows are hidden unless asked for, the catch-up variant included")
    func gateRowsToggle() throws {
        let ledger = try makeLedger()
        let j = job(); try ledger.upsert(j)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try row(j, at: base, outcome: JobRunner.gateUnchangedOutcome, transcript: nil, ledger: ledger)
        try row(j, at: base.addingTimeInterval(1),
                outcome: JobRunner.gateUnchangedOutcome + " (27 earlier occurrences skipped)", transcript: nil, ledger: ledger)
        let real = try row(j, at: base.addingTimeInterval(2), ledger: ledger)

        #expect(try ledger.runLog(limit: 10).runs.map(\.id) == [real.id])
        #expect(try ledger.runLog(limit: 10, includeGateUnchanged: true).runs.count == 3)
    }

    @Test("paging never drops or repeats rows that share a millisecond")
    func pagingNeverDropsOrRepeatsTiedRows() throws {
        let ledger = try makeLedger()
        let j = job(); try ledger.upsert(j)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var written: [UUID] = []
        written.append(try row(j, at: base, ledger: ledger).id)
        for _ in 0..<3 { written.append(try row(j, at: base.addingTimeInterval(5), ledger: ledger).id) }
        written.append(try row(j, at: base.addingTimeInterval(9), ledger: ledger).id)

        var seen: [UUID] = []
        var cursor: JobLedger.RunLogCursor?
        var pages = 0
        // Bounded, so a cursor that repeats a row fails here rather than looping forever.
        repeat {
            let page = try ledger.runLog(limit: 2, before: cursor)
            seen += page.runs.map(\.id)
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 10

        #expect(pages == 3, "five rows at two a page")

        #expect(seen.count == 5)
        #expect(Set(seen) == Set(written), "no row dropped")
        // Newest first; within the tied millisecond, the later insert first.
        #expect(seen == [written[4], written[3], written[2], written[1], written[0]])
    }

    @Test("the job and status filters narrow the log")
    func filters() throws {
        let ledger = try makeLedger()
        let a = job("a"), b = job("b")
        try ledger.upsert(a); try ledger.upsert(b)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let failed = try row(a, at: base, status: .failed, ledger: ledger)
        try row(a, at: base.addingTimeInterval(1), ledger: ledger)
        try row(b, at: base.addingTimeInterval(2), status: .failed, ledger: ledger)

        #expect(try ledger.runLog(limit: 10, jobId: a.id).runs.count == 2)
        #expect(try ledger.runLog(limit: 10, jobId: a.id, status: .failed).runs.map(\.id) == [failed.id])
    }

    @Test("a limit below 1 reads one row rather than trapping")
    func clampsLimit() throws {
        let ledger = try makeLedger()
        let j = job()
        try ledger.upsert(j)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try row(j, at: base, ledger: ledger)
        let newest = try row(j, at: base.addingTimeInterval(1), ledger: ledger)

        for limit in [-5, 0] {
            let page = try ledger.runLog(limit: limit)
            #expect(page.runs.map(\.id) == [newest.id])
            #expect(page.next != nil)
        }
    }

    @Test("blocked on approval and refused by profile filter apart, matching the Status column's words (#567)")
    func refusalFilter() throws {
        let store = try ConversationStore.inMemory()
        let ledger = store.ledger
        let j = job()
        try ledger.upsert(j)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func blocked(_ offset: Double, _ call: BlockedCall?) throws -> JobRun {
            let run = try row(j, at: base.addingTimeInterval(offset), status: .blockedOnApproval, ledger: ledger)
            try ledger.setBlockedCall(runId: run.id, call)
            return run
        }
        let waiting = try blocked(0, BlockedCall(toolName: "run_command", args: [:], cwd: nil, reason: .approval))
        let refused = try blocked(1, BlockedCall(toolName: "write_file", args: [:], cwd: nil, reason: .profile))
        let noCall = try blocked(2, nil)
        // A call written with no reason decodes as a refusal (`BlockedCall`'s fail-closed read), and
        // one that isn't JSON doesn't decode at all, so it keeps `blocked on approval`.
        let noReason = try blocked(3, nil), garbled = try blocked(4, nil)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE job_runs SET blockedCall = ? WHERE id = ?", arguments: [#"{"toolName":"x"}"#, noReason.id.uuidString])
            try db.execute(sql: "UPDATE job_runs SET blockedCall = ? WHERE id = ?", arguments: ["not json", garbled.id.uuidString])
        }
        try row(j, at: base.addingTimeInterval(5), status: .failed, ledger: ledger)

        let runs = try ledger.runLog(limit: 20).runs
        func ids(_ status: JobLedger.RunLogStatus) throws -> Set<UUID> { Set(try ledger.runLog(limit: 20, status: status).runs.map(\.id)) }
        #expect(try ids(.refusedByProfile) == [refused.id, noReason.id])
        #expect(try ids(.awaitingApproval) == [waiting.id, noCall.id, garbled.id])
        // Each filter is exactly the rows whose Status column reads its words.
        for status in [JobLedger.RunLogStatus.refusedByProfile, .awaitingApproval] {
            #expect(try ids(status) == Set(runs.filter { $0.statusText == status.text }.map(\.id)), "\(status)")
        }
        #expect(JobLedger.RunLogStatus.refusedByProfile.text == "refused by profile")
        #expect(JobLedger.RunLogStatus.awaitingApproval.text == "blocked on approval")
    }
}
