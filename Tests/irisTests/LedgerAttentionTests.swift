import Testing
import Foundation
@testable import IrisKit

/// D6 decision 16: the ledger's half of the status item is a cached snapshot, refreshed after
/// every write that can move it and never polled.
@MainActor
@Suite("Ledger attention (D6)", .timeLimit(.minutes(1)))
struct LedgerAttentionTests {
    private func makeApp() throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation()
        app.selectedConversationId = id
        return (store, app, id)
    }

    private func job(_ name: String, pausedReason: String? = nil) -> Job {
        Job(name: name, prompt: "do it", trigger: .schedule(.interval(seconds: 60)), pausedReason: pausedReason)
    }

    @discardableResult
    private func row(_ job: Job, _ status: JobRun.Status, tool: String? = nil,
                     ledger: JobLedger) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date())
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: status, outcome: nil, failureReason: nil,
                          blockedTool: tool, tokens: TokenUsage(), finishedAt: Date())
        return try #require(try ledger.run(id: run.id))
    }

    /// The refresh the code under test started, awaited, so a test never asserts on a snapshot
    /// that has not landed yet.
    private func landed(_ app: AppState) async throws {
        try await value(of: try #require(app.ledgerAttentionRefresh, "no refresh was started"))
    }

    @Test("blocked and failed rows, attention pauses and owner pauses each land in their own bucket")
    func makeSortsTheRows() {
        let jobId = UUID()
        var blocked = JobRun(jobId: jobId, jobName: "pr-sweep", triggerKind: "schedule",
                             startedAt: Date(), status: .blockedOnApproval)
        blocked.blockedTool = "run_command"
        let failed = JobRun(jobId: jobId, jobName: "pr-sweep", triggerKind: "schedule",
                            startedAt: Date(), status: .failed)
        let paused = [job("budgeted", pausedReason: JobRunner.budgetReason(scope: "job", used: 10, limit: 5)),
                      job("mine", pausedReason: JobsCommand.pausedByUserReason),
                      job("copied", pausedReason: DevHomeSeeder.copiedJobPausedReason)]

        let a = LedgerAttention.make(unacknowledged: [blocked, failed], paused: paused)

        #expect(a.blocked == [LedgerAttention.Blocked(runId: blocked.id, jobId: jobId,
                                                     jobName: "pr-sweep", tool: "run_command")])
        #expect(a.failedCount == 1)
        #expect(a.attentionPaused.map(\.name) == ["budgeted"])
        #expect(a.ownerPausedCount == 2,
                "a pause the owner made, by /jobs pause or by seeding the dev home, waits on nobody")
    }

    @Test("pausedJobs lists only paused jobs, and leaves the published unreadable count alone")
    func pausedJobsQuery() throws {
        let (store, _, _) = try makeApp()
        try store.ledger.upsert(job("running"))
        try store.ledger.upsert(job("stopped", pausedReason: JobRunner.gateFailingReason))
        // Two unreadable rows, one paused: `jobs()` counts both, and `pausedJobs()` would see only
        // the paused one, so a `pausedJobs()` that published its own count would move 2 to 1.
        try store.writer.write { db in
            for (name, paused) in [("bad-running", nil), ("bad-paused", "why")] as [(String, String?)] {
                try db.execute(sql: """
                    INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt, pausedReason)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, name, "p", "schedule",
                                     "{\"kind\":\"telepathy\"}", Date(), paused])
            }
        }
        _ = try store.ledger.jobs()
        #expect(store.ledger.unreadableJobCount == 2)
        #expect(try store.ledger.pausedJobs().map(\.name) == ["stopped"])
        #expect(store.ledger.unreadableJobCount == 2)
    }

    @Test("a delivered card refreshes the snapshot")
    func deliverRefreshes() async throws {
        let (store, app, _) = try makeApp()
        let j = job("pr-sweep")
        try store.ledger.upsert(j)
        let run = try row(j, .blockedOnApproval, tool: "run_command", ledger: store.ledger)
        let card = EventCard(runId: run.id, jobId: j.id, jobName: j.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())

        await app.deliverEvent(card, to: app.activityConversationId())
        try await landed(app)

        #expect(app.ledgerAttention.blocked.map(\.runId) == [run.id])
    }

    @Test("Dismiss acknowledges the run and clears it from the snapshot")
    func dismissRefreshes() async throws {
        let (store, app, _) = try makeApp()
        let j = job("pr-sweep")
        try store.ledger.upsert(j)
        let run = try row(j, .blockedOnApproval, tool: "run_command", ledger: store.ledger)
        try await value(of: app.refreshLedgerAttention())
        #expect(app.ledgerAttention.blocked.count == 1)

        try await value(of: app.dismissEventCard(runId: run.id))

        #expect(app.ledgerAttention.blocked.isEmpty)
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt != nil)
    }

    @Test("/jobs ack refreshes the snapshot")
    func ackRefreshes() async throws {
        let (store, app, _) = try makeApp()
        let j = job("pr-sweep")
        try store.ledger.upsert(j)
        let run = try row(j, .failed, ledger: store.ledger)
        try await value(of: app.refreshLedgerAttention())
        #expect(app.ledgerAttention.failedCount == 1)

        app.sendMessage("/jobs ack \(run.id.uuidString.prefix(8))")
        try await landed(app)

        #expect(app.ledgerAttention.failedCount == 0)
    }

    @Test("/jobs pause, resume and delete refresh the snapshot")
    func jobsVerbsRefresh() async throws {
        let (store, app, _) = try makeApp()
        try store.ledger.upsert(job("nightly"))
        try store.ledger.upsert(job("thrasher", pausedReason: JobRunner.breakerReason(count: 6)))

        app.sendMessage("/jobs pause nightly")
        try await landed(app)
        #expect(app.ledgerAttention.ownerPausedCount == 1)
        #expect(app.ledgerAttention.attentionPaused.map(\.name) == ["thrasher"])

        app.sendMessage("/jobs resume nightly")
        try await landed(app)
        #expect(app.ledgerAttention.ownerPausedCount == 0)

        app.sendMessage("/jobs delete thrasher")
        try await landed(app)
        #expect(app.ledgerAttention.attentionPaused.isEmpty)
    }

    /// Holds the approved call open until released, and says when it has started.
    private actor HeldCall {
        private var held: CheckedContinuation<Void, Never>?
        private(set) var isRunning = false

        func run() async -> String {
            await withCheckedContinuation { held = $0; isRunning = true }
            return "wrote 4 bytes"
        }

        func release() { held?.resume(); held = nil }
    }

    @Test("Approve and run clears the blocked run from the snapshot when it claims it, not when the call ends")
    func approvalRefreshesOnClaim() async throws {
        let (store, app, _) = try makeApp()
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let j = Job(name: "writer", prompt: "do it", trigger: .schedule(.interval(seconds: 60)),
                    profile: .mutating)
        try store.ledger.upsert(j)
        let blocked = try row(j, .blockedOnApproval, tool: "write_file", ledger: store.ledger)
        try store.ledger.setBlockedCall(runId: blocked.id, BlockedCall(
            toolName: "write_file", args: ["path": .string("/nonexistent/a.txt"), "content": .string("once")],
            cwd: "/nonexistent"))
        let suite = "iris-attention-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        let call = HeldCall()
        defer { Task { await call.release() } }
        let runner = JobRunner(state: app, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: ConfigManager(store: defaults),
                               sandboxAvailable: { true },
                               approvedCallExecutor: { _, _ in await call.run() })
        try await value(of: app.refreshLedgerAttention())
        #expect(app.ledgerAttention.blocked.map(\.runId) == [blocked.id])

        let approval = Task { await runner.runApproved(runId: blocked.id) }
        var spins = 0
        while !(await call.isRunning), spins < 10_000 { await Task.yield(); spins += 1 }
        try #require(await call.isRunning, "the approved call never started")
        try await landed(app)
        #expect(app.ledgerAttention.blocked.isEmpty, "the claim acknowledged the run before the call began")

        await call.release()
        guard case .dispatched = try await value(of: approval) else {
            Issue.record("the approval was refused")
            return
        }
    }

    /// Holds the first read until released; every later read answers at once.
    private actor HeldRead {
        private var calls = 0
        private var held: CheckedContinuation<Void, Never>?
        private(set) var firstIsHeld = false

        func read(older: LedgerAttention, newer: LedgerAttention) async -> LedgerAttention {
            calls += 1
            guard calls == 1 else { return newer }
            await withCheckedContinuation { held = $0; firstIsHeld = true }
            return older
        }

        func release() { held?.resume(); held = nil }
    }

    @Test("an older read that finishes last never overwrites a newer one")
    func staleReadIsDropped() async throws {
        let (_, app, _) = try makeApp()
        let gate = HeldRead()
        let older = LedgerAttention(failedCount: 7), newer = LedgerAttention(failedCount: 1)
        app.ledgerAttentionReader = { _ in await gate.read(older: older, newer: newer) }

        // Released on every way out, so a failed expectation ends the test instead of leaving the
        // first read parked until the time limit.
        defer { Task { await gate.release() } }
        let first = app.refreshLedgerAttention()
        var spins = 0
        while !(await gate.firstIsHeld), spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(await gate.firstIsHeld, "the first read must be parked before the second starts")
        let second = app.refreshLedgerAttention()
        try await value(of: second)
        #expect(app.ledgerAttention.failedCount == 1)

        await gate.release()
        try await value(of: first)
        #expect(app.ledgerAttention.failedCount == 1, "the older read finished last and was dropped")
    }
}
