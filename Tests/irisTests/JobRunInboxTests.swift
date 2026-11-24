import Testing
import Foundation
@testable import IrisKit

/// #920 slice 1b: a scheduled or polled job's run may raise an inbox item, owned by the job
/// (`job:<id>`) rather than the run, which has ended by the time Brian answers. The answer is handed
/// to the job's next run as his decision, without widening that run's tools, or goes to the pinned
/// Iris when the job is deleted, paused, or not due within 24 hours.
@MainActor
@Suite("Inbox items from job runs (#920 slice 1b)", .timeLimit(.minutes(1)))
struct JobRunInboxTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(UUID, String)] = []
        var calls: [(UUID, String)] { lock.withLock { stored } }
        var deliver: IrisEngine.InboxDeliver { { [self] id, text, _ in lock.withLock { stored.append((id, text)) }; return .delivered } }
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-jobinbox-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func state() throws -> (ConversationStore, AppState) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.autoApproveTools = true
        return (store, app)
    }

    private func job(_ trigger: Trigger = .schedule(.interval(seconds: 3_600)), nextFire: Date? = Date().addingTimeInterval(3_600)) -> Job {
        var j = Job(name: "nightly-check", prompt: "Check the build.", trigger: trigger, profile: .readOnly)
        j.nextFireAt = nextFire
        return j
    }

    /// A job run's background conversation, stamped the way `JobRunner.openConversation` stamps one.
    private func runConversation(_ app: AppState, for job: Job) -> UUID {
        let id = app.createNewConversation(isBackground: true, title: "run")
        app.setJobProfile(for: id, job.profile)
        app.setJobRunStamp(for: id, .init(jobId: job.id, isWatch: job.trigger.kind == Trigger.fsEventKind))
        return id
    }

    private func offered(_ app: AppState, _ id: UUID) async -> Set<String> {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("tick", source: "job:test", conversationId: id)
        return Set(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    }

    private func raise(_ app: AppState, from run: UUID, for job: Job) throws -> InboxItem {
        let chain = app.inboxOwnerChain(for: run)
        let now = Date()
        let item = InboxItem(id: try app.store.inbox.newItemId(), threadId: try app.store.inbox.newThreadId(ownerChain: chain),
                             ownerChain: chain, emitter: run, emitterLabel: "nightly-check", title: "Flaky test?",
                             situation: "BuildTests failed twice.", options: [InboxOption(id: "a", label: "Quarantine", pros: [], cons: [])],
                             responseMode: .optionsAndFreeform, routeBack: [], notify: [], deadline: nil, vetoDefaultOptionId: nil,
                             emitterTainted: false, state: .open, createdAt: now, lastActivityAt: now, answer: nil)
        guard case .success(let created) = try app.store.inbox.createItem(item, question: item.situation) else {
            Issue.record("createItem failed"); return item
        }
        return created
    }

    private func engine(_ app: AppState) -> IrisEngine {
        IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []), retryDelays: [],
                   protectionEnabled: false, sessionPeerCount: 0)
    }

    @Test("a scheduled or polled job's run is offered inbox_item; a watch's run and an unstamped background turn are not")
    func gateByTrigger() async throws {
        let (store, app) = try state()
        var watch = job(.fsEvent(FSWatch(path: "/tmp/w"))); watch.name = "save-watch"
        let scheduled = job()
        try store.ledger.upsert(scheduled); try store.ledger.upsert(watch)
        #expect(await offered(app, runConversation(app, for: scheduled)).contains("inbox_item"))
        #expect(!(await offered(app, runConversation(app, for: watch))).contains("inbox_item"))
        let plain = app.createNewConversation(isBackground: true, title: "bg")
        #expect(!(await offered(app, plain)).contains("inbox_item"))
    }

    @Test("an item from a job run is owned by the job, and the job's next run may resolve it")
    func ownedByTheJob() async throws {
        let (store, app) = try state()
        let j = job(); try store.ledger.upsert(j)
        let first = runConversation(app, for: j)
        let item = try raise(app, from: first, for: j)
        #expect(item.ownerChain == "job:" + j.id.uuidString)
        _ = app.takeBackgroundDenials(for: first)   // the run's drain, which drops its stamp
        #expect(app.jobRunStamps[first] == nil)
        let next = runConversation(app, for: j)
        #expect(app.inboxOwnerChain(for: next) == item.ownerChain)
        #expect(await offered(app, next).contains(IrisEngine.resolveInboxItemTool))
    }

    @Test("a job's runs share one emit budget, keyed by the job")
    func rateLimitKeyedByJob() throws {
        let (store, app) = try state()
        let j = job(); try store.ledger.upsert(j)
        var allowed = 0
        for _ in 0..<(PeerRateLimiter.capacity + 5) {
            let run = runConversation(app, for: j)
            if case .allowed = app.decideInboxEmit(from: run) { allowed += 1 }
        }
        #expect(allowed == PeerRateLimiter.capacity)
    }

    @Test("the fallback rule: deleted, paused, disabled, not due within 24 hours; else wait")
    func fallbackReasons() {
        let at = Date()
        var j = job(nextFire: at.addingTimeInterval(3_600))
        #expect(IrisEngine.jobInboxFallbackReason(job: nil, answeredAt: at) == "the job has been deleted")
        #expect(IrisEngine.jobInboxFallbackReason(job: j, answeredAt: at) == nil)
        j.pausedReason = "failed 4 times"
        #expect(IrisEngine.jobInboxFallbackReason(job: j, answeredAt: at) == "the job is paused")
        j.pausedReason = nil; j.enabled = false
        #expect(IrisEngine.jobInboxFallbackReason(job: j, answeredAt: at) == "the job is paused")
        j.enabled = true; j.nextFireAt = at.addingTimeInterval(25 * 3_600)
        #expect(IrisEngine.jobInboxFallbackReason(job: j, answeredAt: at) == "the job does not run again within 24 hours")
        j.nextFireAt = nil
        #expect(IrisEngine.jobInboxFallbackReason(job: j, answeredAt: at) == "the job does not run again within 24 hours")
    }

    @Test("an answer for a job due soon waits for its next run, which takes it once as Brian's decision")
    func answerWaitsForNextRun() async throws {
        let (store, app) = try state()
        let j = job(); try store.ledger.upsert(j)
        let run = runConversation(app, for: j)
        let item = try raise(app, from: run, for: j)
        let e = engine(app), sink = Sink()
        _ = await e.submitInboxAnswer(itemId: item.id, choice: "a", freeText: "quarantine it", deliver: sink.deliver)
        #expect(sink.calls.isEmpty, "nothing is delivered to the run that ended")
        var stored = try #require(try store.inbox.item(id: item.id))
        #expect(stored.state == .awaitingDelivery && stored.pendingTargets == ["job:" + j.id.uuidString])

        let next = runConversation(app, for: j)
        let handed = try #require(await e.takeJobInboxAnswers(jobId: j.id, for: next))
        #expect(handed.contains("Brian's decision") && handed.contains("quarantine it"))
        stored = try #require(try store.inbox.item(id: item.id))
        #expect(stored.state == .answered && stored.pendingTargets.isEmpty)
        #expect(await e.takeJobInboxAnswers(jobId: j.id, for: next) == nil, "taken once")
    }

    @Test("an answer for a deleted, paused, or far-off job goes to the pinned Iris, with the job named", arguments: [0, 1, 2])
    func fallsBackToIris(_ which: Int) async throws {
        let (store, app) = try state()
        let iris = app.createNewConversation(select: false)
        app.conversations[app.conversations.firstIndex { $0.id == iris }!].isPinned = true
        var j = job(); try store.ledger.upsert(j)
        let item = try raise(app, from: runConversation(app, for: j), for: j)
        switch which {
        case 0: try store.ledger.delete(jobId: j.id)
        case 1: j.pausedReason = "paused by you"; try store.ledger.upsert(j)
        default: j.nextFireAt = Date().addingTimeInterval(3 * 86_400); try store.ledger.upsert(j)
        }
        let sink = Sink()
        _ = await engine(app).submitInboxAnswer(itemId: item.id, choice: "a", freeText: nil, deliver: sink.deliver)
        #expect(sink.calls.map(\.0) == [iris])
        let text = try #require(sink.calls.first?.1)
        #expect(text.contains("cannot go to that job") && text.contains("Brian's decision"))
        #expect(which == 0 || text.contains("nightly-check"))
        let stored = try #require(try store.inbox.item(id: item.id))
        #expect(stored.state == .answered)
    }

    @Test("a job paused after the answer is re-checked on the watcher's tick and reaches the pinned Iris then")
    func tickFallback() async throws {
        let (store, app) = try state()
        let iris = app.createNewConversation(select: false)
        app.conversations[app.conversations.firstIndex { $0.id == iris }!].isPinned = true
        var j = job(); try store.ledger.upsert(j)
        let item = try raise(app, from: runConversation(app, for: j), for: j)
        let e = engine(app), sink = Sink()
        _ = await e.submitInboxAnswer(itemId: item.id, choice: "a", freeText: nil, deliver: sink.deliver)
        #expect(sink.calls.isEmpty)
        j.pausedReason = "paused by you"; try store.ledger.upsert(j)
        await e.evaluateJobInboxFallbacks(deliver: sink.deliver)
        #expect(sink.calls.map(\.0) == [iris])
        #expect(try #require(try store.inbox.item(id: item.id)).state == .answered)
    }

    @Test("the next real run gets the answer in its prompt, framed as Brian's decision, and is still read-only")
    func nextRunPromptAndSurface() async throws {
        let (store, app) = try state()
        let j = job(); try store.ledger.upsert(j)
        let item = try raise(app, from: runConversation(app, for: j), for: j)
        let client = CapturingLLMClient(reply: "done")
        let e = IrisEngine(state: app, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        _ = await e.submitInboxAnswer(itemId: item.id, choice: "a", freeText: "quarantine it", deliver: Sink().deliver)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: app, engine: e, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })
        await runner.fire(job: j, origin: .schedule)

        let request = try #require(client.requests.first)
        // The answer arrives as the turn's own input, never as a tool result.
        let userText = request.contents.filter { $0.role == "user" }.flatMap(\.parts).compactMap(\.text).joined()
        #expect(userText.contains(JobRunner.jobInboxAnswersPreamble))
        #expect(userText.contains("Brian's decision") && userText.contains("quarantine it") && userText.contains("Check the build."))
        #expect(request.contents.flatMap(\.parts).allSatisfy { $0.functionResponse == nil })
        // And it does not widen the run: everything offered is still on the read-only ceiling.
        let names = Set(request.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        #expect(!names.isEmpty && names.allSatisfy { !JobProfile.readOnlyDenies($0, sandboxedRunCommand: true, readOnlyMCPTools: []) })
        #expect(!names.contains("write_file"))
        #expect(try #require(try store.inbox.item(id: item.id)).state == .answered)
    }

    @Test("a tainted item's answer taints the run it is handed to; a clean one does not (dev-2's #1377 review)")
    func answerTaintCarries() async throws {
        let (store, app) = try state()
        let j = job(); try store.ledger.upsert(j)
        let e = engine(app)
        for tainted in [false, true] {
            let run = runConversation(app, for: j)
            var item = try raise(app, from: run, for: j)
            if tainted {
                // Raised clean, then marked as an emitter that had read outside content.
                item = InboxItem(id: try store.inbox.newItemId(), threadId: try store.inbox.newThreadId(ownerChain: item.ownerChain),
                                 ownerChain: item.ownerChain, emitter: run, emitterLabel: "nightly-check", title: "Tainted?",
                                 situation: "Read from the web.", options: item.options, responseMode: .optionsAndFreeform,
                                 routeBack: [], notify: [], deadline: nil, vetoDefaultOptionId: nil, emitterTainted: true,
                                 state: .open, createdAt: Date(), lastActivityAt: Date(), answer: nil)
                guard case .success(let created) = try store.inbox.createItem(item, question: item.situation) else {
                    Issue.record("createItem failed"); return
                }
                item = created
            }
            _ = await e.submitInboxAnswer(itemId: item.id, choice: "a", freeText: nil, deliver: Sink().deliver)
            let next = runConversation(app, for: j)
            app.conversations[app.conversations.firstIndex { $0.id == next }!].hasUntrustedToolOutput = false
            #expect(await e.takeJobInboxAnswers(jobId: j.id, for: next) != nil)
            #expect(app.conversations.first { $0.id == next }?.hasUntrustedToolOutput == tainted, Comment(rawValue: "tainted: \(tainted)"))
        }
    }

    @Test("a sweep whose snapshot predates the next run's take does not deliver that answer again (dev-2's #1377 review)")
    func staleSnapshotDoesNotDoubleDeliver() async throws {
        let (store, app) = try state()
        let iris = app.createNewConversation(select: false)
        app.conversations[app.conversations.firstIndex { $0.id == iris }!].isPinned = true
        var j = job(); try store.ledger.upsert(j)
        let e = engine(app)
        // An earlier item whose target is refused, so it is still awaiting delivery, ahead of the job's.
        let other = app.createNewConversation(select: false)
        let first = try raise(app, from: other, for: j)   // owner chain is `other`'s own id: no stamp
        _ = await e.submitInboxAnswer(itemId: first.id, choice: "a", freeText: nil, deliver: { _, _, _ in .refused })
        let jobItem = try raise(app, from: runConversation(app, for: j), for: j)
        _ = await e.submitInboxAnswer(itemId: jobItem.id, choice: "a", freeText: nil, deliver: Sink().deliver)
        // Now the job is paused, so a sweep that still thinks the answer is pending would send it to Iris.
        j.pausedReason = "paused by you"; try store.ledger.upsert(j)
        let next = runConversation(app, for: j)
        let jobId = j.id
        let sink = Sink()
        let tookDuringSweep = Sink()
        await e.redeliverAwaitingInbox(deliver: { [sink, tookDuringSweep] id, text, t in
            // While the sweep delivers the first item, the job's next run takes its answer.
            if id == other, tookDuringSweep.calls.isEmpty, let taken = await e.takeJobInboxAnswers(jobId: jobId, for: next) {
                await tookDuringSweep.deliver(next, taken, false)
            }
            return await sink.deliver(id, text, t)
        })
        #expect(tookDuringSweep.calls.count == 1, "precondition: the next run took the answer mid-sweep")
        #expect(!sink.calls.contains { $0.0 == iris }, "the answer the run took is not also sent to Iris")
        #expect(try #require(try store.inbox.item(id: jobItem.id)).state == .answered)
    }

    @Test("hardStrip's keep list lifts only the job-run inbox tools, whatever it is handed (dev-3's #1377 review)")
    func keepUnattendedLiftsOnlyInboxTools() {
        let tools = ["schedule_job", "set_workspace", "list_sessions", "inbox_item", IrisEngine.resolveInboxItemTool, "read_file"]
            .map { FunctionDeclaration(name: $0, description: "", parameters: Schema(type: "OBJECT", properties: [:])) }
        let kept = IrisEngine.hardStrip(tools, isUnattended: true, principal: .main,
                                        keepUnattended: ["schedule_job", "set_workspace", "list_sessions", "inbox_item"]).map(\.name)
        #expect(kept == ["inbox_item", "read_file"])
        #expect(IrisEngine.hardStrip(tools, isUnattended: true, principal: .main).map(\.name) == ["read_file"])
    }
}
