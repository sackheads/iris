import Testing
import Foundation
import GRDB
import os
@testable import IrisKit

/// D2: a link can arrive before Iris has finished starting (a cold launch delivers it between will-
/// and did-finish-launching). It waits until the job bookkeeping is done, then is handled exactly
/// as if it had just arrived. Nothing fires before the runs the last process died in are closed.
@MainActor
@Suite("Run-job URL intake (D6)", .timeLimit(.minutes(1)))
struct RunJobURLIntakeTests {
    private func makeApp() throws -> (ConversationStore, AppState, Job, URL) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        let job = Job(name: "url-digest", prompt: "", trigger: .schedule(.interval(seconds: 86_400)),
                      action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)
        let minted = try #require(URLTriggerToken.generate())
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: URLTriggerToken.digest(minted))
        return (store, app, job, URL(string: RunJobURL.url(token: minted, identity: .dev))!)
    }

    private func irisLines(_ app: AppState) -> [String] {
        let iris = app.activityConversationId()
        return app.conversations.first { $0.id == iris }?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    private let junk = URL(string: "iris-dev://run-job/junk")!
    @MainActor private final class Counter { var value = 0 }

    @Test("a link before the bookkeeping waits, silently, and is handled in order once it is done")
    func heldUntilReady() async throws {
        let (store, app, job, link) = try makeApp()
        #expect(app.urlIntake == .starting([]))
        app.receiveRunJobURL(junk)
        app.receiveRunJobURL(link)
        #expect(app.urlIntake == .starting([junk, link]))
        #expect(irisLines(app).isEmpty)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)

        app.jobsBecameReady()
        #expect(app.urlIntake == .ready)
        let lines = irisLines(app)
        #expect(lines.first == RunJobURL.refusalLine(subject: nil, reason: RunJobURL.Refusal.malformedToken.sentence, count: 1))
        #expect(lines.count == 2, "the refusal, then the fire's line")
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("held links drain oldest first: a fire held before a junk link speaks before its refusal")
    func drainsOldestFirst() async throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        app.receiveRunJobURL(junk)
        app.jobsBecameReady()
        let lines = irisLines(app)
        #expect(lines.count == 2)
        #expect(lines.last == RunJobURL.refusalLine(subject: nil, reason: RunJobURL.Refusal.malformedToken.sentence, count: 1))
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("once ready, a link is handled at once")
    func readyHandlesAtOnce() async throws {
        let (store, app, job, link) = try makeApp()
        app.jobsBecameReady()
        app.receiveRunJobURL(link)
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    // The drain re-reads the job fresh from the ledger, through the same `handleRunJobURL` a live
    // arrival uses: nothing cached at hold time is trusted at drain time. Each case below changes
    // the job between the hold and the drain and expects exactly what a fresh link opened after
    // that change would get.

    @Test("the control case: a held link whose job is unchanged fires at the drain")
    func drainFiresWhenNothingChanged() async throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        #expect(app.urlIntake == .starting([link]))
        app.jobsBecameReady()
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("a held link whose token was rotated before the drain is refused, not fired on the old digest")
    func drainRefusesARotatedToken() throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        let rotated = try #require(URLTriggerToken.generate())
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: URLTriggerToken.digest(rotated))
        app.jobsBecameReady()
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.unknownTokenReason, count: 1)])
    }

    @Test("a held link whose trigger was turned off before the drain is refused, not fired on the old digest")
    func drainRefusesATurnedOffTrigger() throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: nil)
        app.jobsBecameReady()
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.unknownTokenReason, count: 1)])
    }

    @Test("a held link whose job was paused before the drain is refused with the pause, not fired")
    func drainRefusesAPausedJob() throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        try store.ledger.setPaused(jobId: job.id, reason: JobsCommand.pausedByUserReason)
        app.jobsBecameReady()
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
        var paused = job
        paused.pausedReason = JobsCommand.pausedByUserReason
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: job.name, reason: RunJobURL.pausedReason(paused), count: 1)])
    }

    @Test("a held link whose job was deleted before the drain is refused, not fired")
    func drainRefusesADeletedJob() throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        try store.ledger.delete(jobId: job.id)
        app.jobsBecameReady()
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.unknownTokenReason, count: 1)])
    }

    @Test("a flood while starting holds only the first few and refuses the rest in one line")
    func startupFloodIsCapped() throws {
        let (_, app, _, _) = try makeApp()
        for i in 0..<(RunJobURLIntake.capacity + 5) { app.receiveRunJobURL(URL(string: "iris-dev://run-job/junk\(i)")!) }
        guard case .starting(let held) = app.urlIntake else { Issue.record("not starting"); return }
        #expect(held.count == RunJobURLIntake.capacity)
        app.flushURLRefusalLines()
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.startupFloodReason, count: 5)])
    }

    @Test("with Iris not set up, held and later links are refused in one line until setup makes it ready")
    func notSetUpRefuses() async throws {
        let (store, app, job, link) = try makeApp()
        app.receiveRunJobURL(link)
        app.refuseRunJobURLsUntilSetUp()
        app.receiveRunJobURL(link)
        #expect(app.urlIntake == .notSetUp)
        app.flushURLRefusalLines()
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.notSetUpReason, count: 2)])
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)

        app.jobsBecameReady()           // setup finished and `start()` ran
        app.receiveRunJobURL(link)
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("an event that carried no readable link is refused with a line")
    func unreadableIsRefused() throws {
        let (_, app, _, _) = try makeApp()
        app.jobsBecameReady()
        app.receiveRunJobURL(nil)
        #expect(irisLines(app) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.Refusal.unreadable.sentence, count: 1)])
    }

    @Test("the launch bookkeeping, after it closes the last session's runs, releases the held links")
    func bookkeepingMakesReady() async throws {
        let (store, app, job, link) = try makeApp()
        let orphan = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                            startedAt: Date().addingTimeInterval(-3600))
        try store.ledger.begin(run: orphan)
        app.receiveRunJobURL(link)

        await app.engine.configureJobBookkeeping(ledger: store.ledger)
        #expect(app.urlIntake == .ready)
        _ = try await value(of: try #require(app.urlFireTask))
        if let scheduler = await app.engine.jobScheduler { await scheduler.stop() }

        let runs = try store.ledger.runs(jobId: job.id, limit: 5)
        #expect(runs.first { $0.id == orphan.id }?.status == .interrupted)
        let fired = try #require(runs.first { $0.triggerKind == "url" })
        #expect(fired.status != .interrupted, "the link's own run was not closed as the last session's")
    }

    @Test("a held link is handled only after the last session's runs are closed, never before")
    func drainFollowsTheSweep() async throws {
        let (store, app, job, link) = try makeApp()
        let orphan = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                            startedAt: Date().addingTimeInterval(-3600))
        try store.ledger.begin(run: orphan)
        app.receiveRunJobURL(link)
        // The URL clock is read while the link is handled, on the main actor: the orphan's status
        // then says whether the sweep had already run.
        let seen = OSAllocatedUnfairLock(initialState: [JobRun.Status?]())
        let ledger = store.ledger, orphanId = orphan.id
        app.urlClock = {
            let status = try? ledger.run(id: orphanId)?.status
            seen.withLock { $0.append(status) }
            return Date()
        }
        await app.engine.configureJobBookkeeping(ledger: store.ledger)
        _ = try await value(of: try #require(app.urlFireTask))
        if let scheduler = await app.engine.jobScheduler { await scheduler.stop() }
        let statuses = seen.withLock { $0 }
        #expect(!statuses.isEmpty)
        #expect(statuses.allSatisfy { $0 == .interrupted })
    }

    @Test("the engine starts once, whether launch or a window asks first; the wizard's start still counts")
    func startOnce() throws {
        let (_, app, _, _) = try makeApp()
        let starts = Counter()
        app.launchEngine = { _ in starts.value += 1 }
        app.startOnce()
        app.startOnce()
        #expect(starts.value == 1)

        let (_, wizard, _, _) = try makeApp()
        let wizardStarts = Counter()
        wizard.launchEngine = { _ in wizardStarts.value += 1 }
        wizard.start()                  // the setup wizard's finish
        wizard.startOnce()              // the window's appear
        #expect(wizardStarts.value == 1)
    }

    @Test("Iris is not set up until the setup wizard has finished")
    func isSetUpNeedsTheFlag() {
        let name = "iris-intake-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        #expect(!AppState.isSetUp(defaults: defaults, config: ConfigManager(store: defaults)))
    }
}
