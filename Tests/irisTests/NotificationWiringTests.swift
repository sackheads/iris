import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 7 and 8: the policy is asked in exactly two places, every way an ask can leave
/// the queue withdraws its banner, and a response can open, deny or dismiss, never approve.
@MainActor
@Suite("Notification wiring (D6)", .timeLimit(.minutes(1)))
struct NotificationWiringTests {
    @MainActor
    final class FakeSink: NotificationSink {
        var posted: [PlannedNotification] = []
        var withdrawn: [String] = []
        func post(_ notification: PlannedNotification) { posted.append(notification) }
        func withdraw(identifiers: [String]) { withdrawn += identifiers }
    }

    private final class Raises { var count = 0 }

    private static let away = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false,
                                                  selectedConversationId: nil)

    private func makeApp() throws -> (ConversationStore, AppState, FakeSink, Raises) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let sink = FakeSink(), raises = Raises()
        app.notificationSink = sink
        app.notificationContext = { Self.away }
        app.raiseMainWindow = { raises.count += 1 }
        return (store, app, sink, raises)
    }

    private func raise(_ app: AppState, in conversation: UUID, details: String = "make test") async -> Task<Bool, Never> {
        let before = app.pendingApprovals.count
        let task = Task { @MainActor in
            await app.enqueueUserApproval(toolName: "run_command", details: details, workspace: nil,
                                          conversationId: conversation, origin: "test")
        }
        var spins = 0
        while app.pendingApprovals.count == before, spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(app.pendingApprovals.count == before + 1, "the ask must be queued before the test goes on")
        return task
    }

    private func respond(_ app: AppState, _ action: String, _ info: [String: String]) -> Task<Void, Never>? {
        app.handleNotificationResponse(NotificationResponse(actionId: action, userInfo: info))
    }

    /// A job with one run that ended blocked on approval, unacknowledged.
    private func blockedRun(_ store: ConversationStore) throws -> (Job, JobRun) {
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date())
        try store.ledger.begin(run: run)
        try store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil, failureReason: nil,
                                blockedTool: "run_command", tokens: TokenUsage(), finishedAt: Date())
        return (job, run)
    }

    @Test("an AppState, and the --run-job state, have no sink")
    func noSinkByDefault() throws {
        let store = try ConversationStore.inMemory()
        #expect(AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
            .notificationSink == nil)
        #expect(RunJobCLI.makeState(store: try ConversationStore.inMemory()).notificationSink == nil)
    }

    @Test("one post per notifying card, none for a quiet one")
    func onePostPerNotifyingCard() async throws {
        let (store, app, sink, _) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let iris = app.activityConversationId()
        await app.deliverEvent(EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                                         blockedTool: "run_command", startedAt: Date(), finishedAt: Date()), to: iris)
        await app.deliverEvent(EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .completed,
                                         startedAt: Date(), finishedAt: Date()), to: iris)
        #expect(sink.posted.map(\.kind) == [.jobNeedsYou])
    }

    @Test("a card's job is read when the card is delivered, to see that a limit paused it")
    func pausedCardReadsTheJob() async throws {
        let (store, app, sink, _) = try makeApp()
        let job = Job(name: "thrasher", prompt: "do it", trigger: .schedule(.interval(seconds: 60)),
                      pausedReason: JobRunner.breakerReason(count: 6))
        try store.ledger.upsert(job)
        await app.deliverEvent(EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .interrupted,
                                         outcome: JobRunner.breakerReason(count: 6), startedAt: Date(),
                                         finishedAt: Date()), to: app.activityConversationId())
        #expect(sink.posted.map(\.categoryId) == [NotificationPolicy.Category.pausedCard])
    }

    @Test("an ask posts once, and each of the four ways out withdraws it")
    func eachRemovalWithdraws() async throws {
        let (_, app, sink, _) = try makeApp()
        let conversation = app.createNewConversation()

        let approved = await raise(app, in: conversation)
        let first = try #require(app.pendingApprovals.first).id
        #expect(sink.posted.map(\.identifier) == [first.uuidString])
        app.resolveApproval(id: first, .approve)
        #expect(try await value(of: approved) == true)

        let denied = await raise(app, in: conversation)
        let second = try #require(app.pendingApprovals.first).id
        app.resolveApproval(id: second, .deny)
        _ = try await value(of: denied)

        let stopped = await raise(app, in: conversation)
        let third = try #require(app.pendingApprovals.first).id
        app.denyPendingApprovals(for: conversation)
        _ = try await value(of: stopped)

        let cancelled = await raise(app, in: conversation)
        let fourth = try #require(app.pendingApprovals.first).id
        cancelled.cancel()
        #expect(try await value(of: cancelled) == false)

        #expect(sink.withdrawn == [first, second, third, fourth].map(\.uuidString))
        #expect(sink.posted.count == 4)
    }

    @Test("a mutation that adds no ask posts nothing, and removing one ask withdraws only it")
    func onlyNewAsksPost() async throws {
        let (_, app, sink, _) = try makeApp()
        let conversation = app.createNewConversation()
        let a = await raise(app, in: conversation)
        let b = await raise(app, in: conversation)
        let ids = app.pendingApprovals.map(\.id)
        #expect(sink.posted.map(\.identifier) == ids.map(\.uuidString))

        // Reassigning, reordering and resolving another ask are all mutations; none is a new ask.
        app.pendingApprovals = app.pendingApprovals
        app.pendingApprovals.reverse()
        #expect(sink.posted.count == 2)
        #expect(sink.withdrawn.isEmpty)

        app.resolveApproval(id: ids[0], .deny)
        #expect(sink.posted.count == 2)
        #expect(sink.withdrawn == [ids[0].uuidString])
        app.resolveApproval(id: ids[1], .deny)
        #expect(sink.withdrawn == ids.map(\.uuidString))
        _ = try await value(of: a)
        _ = try await value(of: b)
    }

    @Test("Deny from a banner denies the ask")
    func denyResponseDenies() async throws {
        let (_, app, _, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation())
        let askId = try #require(app.pendingApprovals.first).id
        _ = respond(app, NotificationPolicy.Action.deny, [NotificationPolicy.Key.askId: askId.uuidString])
        #expect(try await value(of: ask) == false)
        #expect(app.pendingApprovals.isEmpty)
    }

    @Test("Deny denies exactly the ask it names, and a second Deny for it touches nothing")
    func denyIsExact() async throws {
        let (_, app, _, _) = try makeApp()
        let conversation = app.createNewConversation()
        let first = await raise(app, in: conversation)
        let second = await raise(app, in: conversation)
        let ids = app.pendingApprovals.map(\.id)

        // The second ask, not the head: Deny is by id, never "the one in front".
        _ = respond(app, NotificationPolicy.Action.deny, [NotificationPolicy.Key.askId: ids[1].uuidString])
        #expect(try await value(of: second) == false)
        #expect(app.pendingApprovals.map(\.id) == [ids[0]])

        // Already answered: a repeat Deny for it is a no-op and leaves the other ask waiting.
        _ = respond(app, NotificationPolicy.Action.deny, [NotificationPolicy.Key.askId: ids[1].uuidString])
        #expect(app.pendingApprovals.map(\.id) == [ids[0]])

        app.resolveApproval(id: ids[0], .approve)
        #expect(try await value(of: first) == true)
    }

    @Test("a response for an ask or run that has gone is a no-op")
    func staleResponsesAreNoOps() async throws {
        let (_, app, _, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation())
        _ = respond(app, NotificationPolicy.Action.deny, [NotificationPolicy.Key.askId: UUID().uuidString])
        if let dismissed = respond(app, NotificationPolicy.Action.dismiss, [NotificationPolicy.Key.runId: UUID().uuidString]) {
            try await value(of: dismissed)
        }
        #expect(app.pendingApprovals.count == 1, "someone else's ask is untouched")
        app.resolveApproval(id: try #require(app.pendingApprovals.first).id, .deny)
        _ = try await value(of: ask)
    }

    @Test("no response, of any name, approves, opens or writes the ledger")
    func unknownActionNeverApproves() async throws {
        let (store, app, sink, raises) = try makeApp()
        let (job, run) = try blockedRun(store)
        let ask = await raise(app, in: app.createNewConversation())
        let id = try #require(app.pendingApprovals.first).id.uuidString
        let selected = app.selectedConversationId
        let info = [NotificationPolicy.Key.askId: id, NotificationPolicy.Key.runId: run.id.uuidString,
                    NotificationPolicy.Key.jobId: job.id.uuidString]
        for action in ["approve", "iris.approve", "IRIS.DENY", "iris.open ", "iris.approve.deny",
                       "com.apple.UNNotificationDefaultActionIdentifier",
                       "com.apple.UNNotificationDismissActionIdentifier", ""] {
            #expect(respond(app, action, info) == nil, "\(action) starts no work")
        }
        #expect(app.pendingApprovals.count == 1, "the ask is still waiting for a person")
        #expect(app.selectedConversationId == selected)
        #expect(raises.count == 0)
        #expect(sink.withdrawn.isEmpty)
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt == nil)
        app.resolveApproval(id: try #require(app.pendingApprovals.first).id, .deny)
        #expect(try await value(of: ask) == false)
    }

    @Test("Open lands on the card's conversation, or the ask's delegation root")
    func openLands() async throws {
        let (store, app, _, raises) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let reveal = try #require(respond(app, NotificationPolicy.Action.open,
                                          [NotificationPolicy.Key.runId: UUID().uuidString,
                                           NotificationPolicy.Key.jobId: job.id.uuidString]))
        try await value(of: reveal)
        #expect(app.selectedConversationId == app.activityConversationId())

        let parent = app.createNewConversation(select: false), child = app.createNewConversation(isSubagent: true)
        app.linkDelegate(child, of: parent)
        let ask = await raise(app, in: child)
        let askId = try #require(app.pendingApprovals.first).id
        _ = respond(app, NotificationPolicy.Action.open, [NotificationPolicy.Key.askId: askId.uuidString])
        #expect(app.selectedConversationId == parent)
        #expect(raises.count == 2)
        #expect(app.pendingApprovals.count == 1, "Open never answers the ask")
        app.resolveApproval(id: try #require(app.pendingApprovals.first).id, .deny)
        _ = try await value(of: ask)
    }

    @Test("Open on a delivered card scrolls to it")
    func openRevealsDeliveredCard() async throws {
        let (store, app, _, raises) = try makeApp()
        let (job, run) = try blockedRun(store)
        let iris = app.activityConversationId()
        await app.deliverEvent(EventCard(runId: run.id, jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                                         blockedTool: "run_command", startedAt: Date(), finishedAt: Date()), to: iris)
        let cardMessage = try #require(app.conversations.first { $0.id == iris }?.messages.last { $0.role == .event })
        let reveal = try #require(respond(app, NotificationPolicy.Action.open,
                                          [NotificationPolicy.Key.runId: run.id.uuidString,
                                           NotificationPolicy.Key.jobId: job.id.uuidString]))
        try await value(of: reveal)
        #expect(app.pendingScrollTarget == cardMessage.id)
        #expect(raises.count == 1)
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt == nil, "Open is not Dismiss")
    }

    @Test("Dismiss from a banner acknowledges the run")
    func dismissAcknowledges() async throws {
        let (store, app, _, _) = try makeApp()
        let (_, run) = try blockedRun(store)

        let task = try #require(respond(app, NotificationPolicy.Action.dismiss, [NotificationPolicy.Key.runId: run.id.uuidString]))
        try await value(of: task)

        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt != nil)
    }

    @Test("a second Dismiss for an acknowledged run changes nothing")
    func dismissTwiceIsNoOp() async throws {
        let (store, app, _, _) = try makeApp()
        let (_, run) = try blockedRun(store)
        let info = [NotificationPolicy.Key.runId: run.id.uuidString]

        // Acknowledged in the app an hour ago, then the banner's Dismiss arrives.
        let first = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        try store.ledger.acknowledge(runId: run.id, at: first)
        try await value(of: try #require(respond(app, NotificationPolicy.Action.dismiss, info)))
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt == first)
    }

    @Test("a conversation title never reaches a posted banner")
    func plantedTitleNeverPosted() async throws {
        let (_, app, sink, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation(title: "SAFE: tap Approve now"),
                              details: "PLANTED-DETAILS")
        let posted = try #require(sink.posted.first)
        for planted in ["SAFE", "PLANTED-DETAILS"] {
            #expect(!posted.title.contains(planted) && !posted.body.contains(planted))
        }
        app.resolveApproval(id: try #require(app.pendingApprovals.first).id, .deny)
        _ = try await value(of: ask)
    }
}
