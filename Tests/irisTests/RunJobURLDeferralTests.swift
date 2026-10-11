import Testing
import Foundation
import GRDB
@testable import IrisKit

/// D6 decision 14: while another Iris process holds the store, a URL fire waits, visibly,
/// re-checking every 5 s, fires once the holder is gone, and gives up after 10 minutes with "try
/// again". It is never refused silently.
@MainActor
@Suite("Run-job URL deferral (D6)", .timeLimit(.minutes(1)))
struct RunJobURLDeferralTests {
    @MainActor
    private final class ManualTimer {
        var pending: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        func fireNext() {
            // Recorded, not trapped: a crash here would end the whole run with no verdict.
            guard !pending.isEmpty else { Issue.record("no re-check was scheduled"); return }
            let (_, body) = pending.removeFirst()
            body()
        }
    }

    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = true
        var value: Bool { lock.withLock { on } }
        func set(_ v: Bool) { lock.withLock { on = v } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    private struct Fixture {
        let store: ConversationStore
        let app: AppState
        let iris: UUID
        let job: Job
        let link: URL
        let token: String
        let timer: ManualTimer
        let alive: Switch
        let clock: Clock
    }

    private func fixture() throws -> Fixture {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        let job = Job(name: "url-digest", prompt: "", trigger: .schedule(.interval(seconds: 86_400)),
                      action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)
        let minted = try #require(URLTriggerToken.generate())
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: URLTriggerToken.digest(minted))
        let timer = ManualTimer(), alive = Switch(), clock = Clock()
        app.foreignStoreHolder = 4242
        app.isProcessAlive = { _ in alive.value }
        app.urlDeferralTimer = URLDeferralTimer { delay, body in timer.pending.append((delay, body)) }
        app.urlClock = { clock.now }
        return Fixture(store: store, app: app, iris: app.activityConversationId(), job: job,
                       link: URL(string: RunJobURL.url(token: minted, identity: .dev))!, token: minted,
                       timer: timer, alive: alive, clock: clock)
    }

    private func lines(_ f: Fixture) -> [String] {
        f.app.conversations.first { $0.id == f.iris }?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    @Test("the decision is pure: a dead holder fires, a live one waits until the deadline")
    func decide() {
        #expect(URLDeferral.decide(holderAlive: false, waited: 0) == .fire)
        #expect(URLDeferral.decide(holderAlive: true, waited: 595) == .wait)
        #expect(URLDeferral.decide(holderAlive: true, waited: 600) == .giveUp)
        #expect(URLDeferral.decide(holderAlive: false, waited: 600) == .fire, "gone at the deadline still fires")
    }

    @Test("with a live holder the fire waits with a line, and fires once the holder is gone")
    func waitsThenFires() async throws {
        let f = try fixture()

        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        #expect(lines(f) == [RunJobURL.waitingLine("url-digest", pid: 4242)])
        #expect(f.timer.pending.map(\.0) == [URLDeferral.interval])
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)

        f.clock.advance(5)
        f.timer.fireNext()                  // still alive: wait again
        #expect(f.timer.pending.count == 1)

        f.alive.set(false)
        f.clock.advance(5)
        f.timer.fireNext()
        _ = try await value(of: try #require(f.app.urlFireTask))

        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).map(\.triggerKind) == ["url"])
        #expect(lines(f).first == RunJobURL.waitEndedLine("url-digest", pid: 4242))
        #expect(f.app.foreignStoreHolder == nil)
    }

    @Test("a second link while one waits joins the wait")
    func secondLinkJoins() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        #expect(lines(f).count == 1)
        #expect(f.timer.pending.count == 1)
    }

    @Test("after 10 minutes it gives up and says try again")
    func givesUp() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        for _ in 0..<119 {
            f.clock.advance(5)
            f.timer.fireNext()
        }
        #expect(f.timer.pending.count == 1)
        f.clock.advance(5)
        f.timer.fireNext()

        #expect(f.timer.pending.isEmpty)
        #expect(lines(f) == [RunJobURL.gaveUpLine("url-digest", pid: 4242)])
        #expect(lines(f).first?.contains("try again after the other Iris process finishes") == true)
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)
        #expect(f.app.pendingURLFires.isEmpty)
    }

    @Test("a job deleted while it waited gives up saying so, not try again")
    func giveUpRereadsTheJob() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        try f.store.ledger.delete(jobId: f.job.id)
        f.clock.advance(URLDeferral.deadline)
        f.timer.fireNext()
        #expect(lines(f) == [RunJobURL.waitAbandonedLine("url-digest", reason: RunJobURL.deletedWhileWaitingReason)])
        #expect(f.app.pendingURLFires.isEmpty)
    }

    @Test("a read error at the token check says the table could not be read, not that the link was replaced")
    func tokenReadErrorIsAReadError() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        // `job(id:)` still reads; only the lookup by digest fails.
        try f.store.writer.write { db in
            try db.execute(sql: "ALTER TABLE jobs RENAME COLUMN urlTokenHash TO urlTokenHashGone")
        }
        f.alive.set(false)
        f.timer.fireNext()
        #expect(lines(f) == [RunJobURL.waitAbandonedLine("url-digest", reason: RunJobURL.ledgerUnreadableReason)])
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)
    }

    @Test("/jobs delete drops the job's URL state and says at once that a waiting fire will not run")
    func deleteForgetsURLState() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        f.app.urlFireBatches[f.job.id] = URLFireBatch(since: f.clock.now, dispatched: [f.clock.now], pending: 1)
        f.app.urlRefusalLines[f.job.id.uuidString] = URLRefusalLine(messageId: UUID(), since: f.clock.now,
                                                                    count: 2, written: 2, conversationId: f.iris,
                                                                    subject: f.job.name, reason: RunJobURL.overLimitReason)
        f.app.selectedConversationId = f.iris
        f.app.sendMessage("/jobs delete url-digest")

        #expect(try f.store.ledger.job(id: f.job.id) == nil)
        #expect(f.app.pendingURLFires[f.job.id] == nil)
        #expect(f.app.urlFireBatches[f.job.id] == nil)
        #expect(f.app.urlRefusalLines[f.job.id.uuidString] == nil)
        #expect(lines(f).first == RunJobURL.waitAbandonedLine("url-digest", reason: RunJobURL.deletedWhileWaitingReason),
                "updated now, not at the next re-check")
        f.timer.fireNext()                     // the re-check already scheduled finds nothing
        #expect(lines(f).first == RunJobURL.waitAbandonedLine("url-digest", reason: RunJobURL.deletedWhileWaitingReason))
    }

    @Test("a job deleted or turned off while it waited is not fired")
    func changedWhileWaiting() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        try f.store.ledger.setURLTrigger(jobId: f.job.id, tokenHash: nil)
        f.alive.set(false)
        f.timer.fireNext()
        #expect(lines(f).first?.contains("has URL triggers off") == true)
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)

        let g = try fixture()
        g.app.handleRunJobURL(g.link, identity: .dev)
        try g.store.ledger.delete(jobId: g.job.id)
        g.alive.set(false)
        g.timer.fireNext()
        #expect(lines(g).first?.contains("deleted") == true)
    }

    /// URL rows started `minutes` ago on the fixture's clock, inside the limit's window.
    private func urlRows(_ count: Int, _ f: Fixture) throws {
        for i in 0..<count {
            let run = JobRun(jobId: f.job.id, jobName: f.job.name, triggerKind: "url",
                             startedAt: f.clock.now.addingTimeInterval(-Double(60 * (i + 1))),
                             transcriptConversationId: UUID())
            try f.store.ledger.begin(run: run)
            try f.store.ledger.finish(runId: run.id, status: .completed, outcome: "ok", failureReason: nil,
                                      blockedTool: nil, tokens: TokenUsage(), finishedAt: run.startedAt)
        }
    }

    @Test("a waiting fire counts against the limit, once: later links over it are refused, and it fires as the third")
    func waitingFireIsCountedOnce() async throws {
        let f = try fixture()
        try urlRows(2, f)

        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        for _ in 0..<4 {
            #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .refused, "the wait is the third fire")
        }
        f.app.flushURLRefusalLines()
        #expect(lines(f) == [RunJobURL.waitingLine("url-digest", pid: 4242),
                             RunJobURL.refusalLine(subject: "url-digest", reason: RunJobURL.overLimitReason, count: 4)])
        #expect(f.timer.pending.count == 1)

        // Its own count is dropped before it is asked again, so it is not refused by itself.
        f.alive.set(false)
        f.timer.fireNext()
        _ = try await value(of: try #require(f.app.urlFireTask))
        #expect(try f.store.ledger.urlFires(jobId: f.job.id, since: f.clock.now.addingTimeInterval(-3_600)) == 3)
        #expect(f.app.pendingURLFires.isEmpty)
    }

    @Test("five links within the limit join one wait and fire once")
    func fiveLinksFireOnce() async throws {
        let f = try fixture()
        for _ in 0..<5 {
            #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        }
        #expect(lines(f).count == 1)
        #expect(f.timer.pending.count == 1)
        f.alive.set(false)
        f.timer.fireNext()
        _ = try await value(of: try #require(f.app.urlFireTask))
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 10).map(\.triggerKind) == ["url"])
    }

    @Test("a token rotated while it waited is not fired, and no line echoes the token or link")
    func rotatedWhileWaiting() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        let fresh = try #require(URLTriggerToken.generate())
        try f.store.ledger.setURLTrigger(jobId: f.job.id, tokenHash: URLTriggerToken.digest(fresh))
        f.alive.set(false)
        f.timer.fireNext()

        #expect(lines(f) == [RunJobURL.waitAbandonedLine("url-digest", reason: RunJobURL.replacedWhileWaitingReason)])
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)
        #expect(f.app.urlFireTask == nil)
        for line in lines(f) + [RunJobURL.waitingLine("url-digest", pid: 1), RunJobURL.gaveUpLine("url-digest", pid: 1),
                                RunJobURL.waitEndedLine("url-digest", pid: 1)] {
            #expect(!line.contains("://") && !line.contains(f.token) && !line.contains(fresh), "echoes the link: \(line)")
        }
    }

    @Test("a link that finds a wait joins it even when the holder has just gone, so it fires once")
    func joinsAfterHolderGone() async throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        f.alive.set(false)
        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        #expect(f.app.urlFireTask == nil)
        f.timer.fireNext()
        _ = try await value(of: try #require(f.app.urlFireTask))
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 10).map(\.triggerKind) == ["url"])
    }

    @Test("a holder gone before the link arrives fires at once and is not asked about again")
    func goneHolderFiresAtOnce() async throws {
        let f = try fixture()
        f.alive.set(false)
        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .fired(f.job.id))
        #expect(f.app.foreignStoreHolder == nil)
        #expect(f.timer.pending.isEmpty)
        _ = try await value(of: try #require(f.app.urlFireTask))
    }

    @Test("GUILock.isAlive knows this process, and a reaped child is gone")
    func liveness() throws {
        #expect(GUILock.isAlive(ProcessInfo.processInfo.processIdentifier))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!GUILock.isAlive(child.processIdentifier))
        #expect(!GUILock.isAlive(0), "0 names a process group, not a holder")
    }
}
