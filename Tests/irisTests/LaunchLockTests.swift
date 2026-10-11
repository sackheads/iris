import Testing
import Foundation
import GRDB
@testable import IrisKit

/// D6 decision 14: the app reads the store lock before it overwrites it and remembers a live
/// foreign holder, by pid and start time, so a link waits for that process and never for a pid
/// the kernel has handed to something else. Launch is never blocked.
@MainActor
@Suite("Launch lock (D6)", .timeLimit(.minutes(1)))
struct LaunchLockTests {
    @MainActor private final class Scheduled { var bodies: [@MainActor @Sendable () -> Void] = [] }

    private let written = Date(timeIntervalSince1970: 1_700_000_000)
    private func start(_ offset: TimeInterval) -> ProcessStart {
        let t = written.timeIntervalSince1970 + offset
        return ProcessStart(seconds: UInt64(t), microseconds: UInt64((t - t.rounded(.down)) * 1_000_000))
    }

    @Test("only a live other process that started before the lock was written holds it")
    func foreignHolder() {
        let me: Int32 = 100
        let before = start(-30)
        #expect(LaunchLock.foreignHolder(.held(pid: 4242), lockWritten: written, holderStart: before, ownPid: me)
                == StoreHolder(pid: 4242, started: before))
        #expect(LaunchLock.foreignHolder(.held(pid: 4242), lockWritten: written, holderStart: start(30), ownPid: me) == nil,
                "started after the lock was written: a reused pid")
        #expect(LaunchLock.foreignHolder(.held(pid: me), lockWritten: written, holderStart: before, ownPid: me) == nil)
        #expect(LaunchLock.foreignHolder(.held(pid: 4242), lockWritten: written, holderStart: nil, ownPid: me) == nil,
                "no start time: the process has gone")
        #expect(LaunchLock.foreignHolder(.held(pid: 4242), lockWritten: nil, holderStart: before, ownPid: me) == nil,
                "no file by the time it was stamped: released")
        #expect(LaunchLock.foreignHolder(.free, lockWritten: written, holderStart: before, ownPid: me) == nil)
        #expect(LaunchLock.foreignHolder(.unreadable(path: "/x"), lockWritten: written, holderStart: before, ownPid: me) == nil)
    }

    @Test("the kernel's start time names one process, and none for a pid nothing has")
    func processStart() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let first = try #require(ProcessStart.of(me))
        #expect(ProcessStart.of(me) == first)
        #expect(first.date <= Date())
        #expect(ProcessStart.of(Int32.max) == nil)
        #expect(ProcessStart.of(0) == nil)
    }

    @Test("a lock written by a live older process reads as that process; one naming this process does not")
    func readsARealLock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-launchlock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("gui.lock")
        let parent = getppid()      // started before this test wrote anything
        GUILock.acquire(at: lock, pid: parent)
        let holder = try #require(LaunchLock.read(at: lock))
        #expect(holder.pid == parent)
        #expect(holder.started == ProcessStart.of(parent))

        GUILock.acquire(at: lock, pid: ProcessInfo.processInfo.processIdentifier)
        #expect(LaunchLock.read(at: lock) == nil)
    }

    // MARK: AppState

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

    @Test("a foreign holder is remembered and announced in Iris; none is silent")
    func noted() throws {
        let (_, app, _, _) = try makeApp()
        app.noteForeignStoreHolder(nil)
        #expect(app.foreignStoreHolder == nil)
        #expect(irisLines(app).isEmpty)

        let holder = StoreHolder(pid: 4242, started: start(-30))
        app.noteForeignStoreHolder(holder)
        #expect(app.foreignStoreHolder == 4242)
        #expect(app.foreignStoreHolderStart == holder.started)
        #expect(irisLines(app) == [RunJobURL.foreignHolderNotice(pid: 4242)])
    }

    @Test("a holder's pid now owned by a later process is not waited for: the link fires")
    func reusedPidFires() async throws {
        let (store, app, job, link) = try makeApp()
        let recorded = start(-30)
        app.noteForeignStoreHolder(StoreHolder(pid: 4242, started: recorded))
        app.isProcessAlive = { _ in true }
        app.processStart = { _ in recorded }
        #expect(app.isForeignHolderAlive(4242))

        let later = start(60)                               // the same pid, a different process
        app.processStart = { _ in later }
        #expect(app.handleRunJobURL(link, identity: .dev) == .fired(job.id))
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(app.foreignStoreHolder == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("a wait ends at the next re-check once the holder's pid belongs to another process")
    func reusedPidEndsAWait() async throws {
        let (store, app, job, link) = try makeApp()
        let recorded = start(-30), later = start(60)
        let scheduled = Scheduled()
        app.urlDeferralTimer = URLDeferralTimer { _, body in scheduled.bodies.append(body) }
        app.noteForeignStoreHolder(StoreHolder(pid: 4242, started: recorded))
        app.isProcessAlive = { _ in true }
        app.processStart = { _ in recorded }
        #expect(app.handleRunJobURL(link, identity: .dev) == .deferred(job.id))

        app.processStart = { _ in later }
        let recheck = try #require(scheduled.bodies.first)
        recheck()
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("a wait keeps the holder's start, so a reused pid ends it even after another link cleared the holder")
    func waitKeepsItsOwnStart() async throws {
        let (store, app, job, link) = try makeApp()
        let other = Job(name: "url-other", prompt: "", trigger: .schedule(.interval(seconds: 86_400)),
                        action: .builtin(DailyDigest.name))
        try store.ledger.upsert(other)
        let minted = try #require(URLTriggerToken.generate())
        try store.ledger.setURLTrigger(jobId: other.id, tokenHash: URLTriggerToken.digest(minted))
        let otherLink = URL(string: RunJobURL.url(token: minted, identity: .dev))!

        let recorded = start(-30), later = start(60)
        let scheduled = Scheduled()
        app.urlDeferralTimer = URLDeferralTimer { _, body in scheduled.bodies.append(body) }
        app.noteForeignStoreHolder(StoreHolder(pid: 4242, started: recorded))
        app.isProcessAlive = { _ in true }
        app.processStart = { _ in recorded }
        #expect(app.handleRunJobURL(link, identity: .dev) == .deferred(job.id))

        app.processStart = { _ in later }
        #expect(app.handleRunJobURL(otherLink, identity: .dev) == .fired(other.id))
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(app.foreignStoreHolder == nil && app.foreignStoreHolderStart == nil)

        let recheck = try #require(scheduled.bodies.first)
        recheck()
        #expect(app.pendingURLFires[job.id] == nil, "the wait ended at its re-check")
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }
}
