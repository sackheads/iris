import Testing
import Foundation
@testable import IrisKit

/// D6 decision 11: both model rewrite paths turn the URL trigger off when they change what the
/// job does, and say so to the model and to the owner. `/jobs reschedule` keeps it.
@MainActor
@Suite("URL trigger cleared on change (D6)", .timeLimit(.minutes(1)))
struct URLTriggerClearTests {
    /// A stand-in digest long enough that finding it in an answer would mean something.
    private static let digest = "digest-7f3a9c1e5b"

    private func makeEngine() throws -> (ConversationStore, AppState, IrisEngine, UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let conversation = state.createNewConversation()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, conversation)
    }

    private func schedule(_ prompt: String, interval: Int = 600) -> Result<ScheduleJobArguments, ToolMessage> {
        ScheduleJobArguments.parse(["prompt": .string(prompt), "intervalSeconds": .int(interval),
                                    "name": .string("pr-sweep")])
    }

    private func irisLines(_ state: AppState) -> [String] {
        state.conversations.first { $0.id == state.activityConversationId() }?
            .messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    private func tempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("schedule_job's re-schedule with a new prompt turns it off, and says so twice")
    func rescheduleClears() async throws {
        let (store, state, engine, conversation) = try makeEngine()
        _ = await engine.scheduleJob(schedule("sweep the PRs"), conversationId: conversation, sandboxAvailable: false)
        let job = try #require(try store.ledger.job(named: "pr-sweep"))
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)

        let answer = await engine.scheduleJob(schedule("sweep the PRs and merge them"),
                                              conversationId: conversation, sandboxAvailable: false)

        #expect(answer.contains(ScheduleJobArguments.urlTriggerClearedNote("pr-sweep")))
        #expect(!answer.contains(Self.digest))
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
        #expect(irisLines(state).contains(AppState.urlTriggerClearedLine("pr-sweep")))
    }

    @Test("a re-schedule that changes only the cadence keeps it, and says nothing")
    func cadenceOnlyKeeps() async throws {
        let (store, state, engine, conversation) = try makeEngine()
        _ = await engine.scheduleJob(schedule("sweep the PRs"), conversationId: conversation, sandboxAvailable: false)
        let job = try #require(try store.ledger.job(named: "pr-sweep"))
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)

        let answer = await engine.scheduleJob(schedule("sweep the PRs", interval: 1_200),
                                              conversationId: conversation, sandboxAvailable: false)

        #expect(!answer.contains("URL trigger"))
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == true)
        #expect(!irisLines(state).contains(AppState.urlTriggerClearedLine("pr-sweep")))
    }

    @Test("a new prompt on a job that never had the trigger on says nothing")
    func neverOnSaysNothing() async throws {
        let (store, state, engine, conversation) = try makeEngine()
        _ = await engine.scheduleJob(schedule("sweep the PRs"), conversationId: conversation, sandboxAvailable: false)

        let answer = await engine.scheduleJob(schedule("sweep the PRs and merge them"),
                                              conversationId: conversation, sandboxAvailable: false)

        #expect(!answer.contains("URL trigger"))
        #expect(try store.ledger.job(named: "pr-sweep")?.prompt == "sweep the PRs and merge them")
        #expect(!irisLines(state).contains(AppState.urlTriggerClearedLine("pr-sweep")))
    }

    @Test("a re-schedule that turns it off closes that job's open link sheet, and only that job's")
    func rescheduleWithdrawsSheet() async throws {
        let (store, state, engine, conversation) = try makeEngine()
        _ = await engine.scheduleJob(schedule("sweep the PRs"), conversationId: conversation, sandboxAvailable: false)
        let job = try #require(try store.ledger.job(named: "pr-sweep"))
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)

        // Another job's sheet survives a change to this one.
        let other = RevealedURLTrigger(jobId: UUID(), jobName: "other", url: "iris-dev://run-job/x")
        state.revealedURLTrigger = other
        _ = await engine.scheduleJob(schedule("sweep the PRs, then merge"),
                                     conversationId: conversation, sandboxAvailable: false)
        #expect(state.revealedURLTrigger == other)

        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)
        state.revealedURLTrigger = RevealedURLTrigger(jobId: job.id, jobName: job.name, url: "iris-dev://run-job/y")
        _ = await engine.scheduleJob(schedule("sweep the PRs and merge them"),
                                     conversationId: conversation, sandboxAvailable: false)
        #expect(state.revealedURLTrigger == nil)
    }

    @Test("the engine's watch update turns it off, tells Iris and closes the sheet")
    func engineWatcherUpdateClears() async throws {
        let base = try tempDirectory(prefix: "iris-urlclear-engine")
        defer { try? FileManager.default.removeItem(at: base) }
        let notes = base.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let (store, state, engine, conversation) = try makeEngine()
        let executor = await engine.executor
        func register(_ instructions: String) async -> String {
            await executor.execute(name: "register_directory_watcher",
                                   args: ["path": .string(notes.path), "instructions": .string(instructions)],
                                   conversationId: conversation)
        }

        _ = await register("summarise")
        let job = try #require(try store.ledger.jobs().first)
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)
        state.revealedURLTrigger = RevealedURLTrigger(jobId: job.id, jobName: job.name, url: "iris-dev://run-job/z")

        let changed = await register("summarise and file")

        #expect(changed.contains(ScheduleJobArguments.urlTriggerClearedNote(job.name)))
        #expect(!changed.contains(Self.digest))
        #expect(irisLines(state).contains(AppState.urlTriggerClearedLine(job.name)))
        #expect(state.revealedURLTrigger == nil)
    }

    private actor Announced {
        var names: [String] = []
        var ids: [UUID] = []
        func add(_ id: UUID, _ name: String) { ids.append(id); names.append(name) }
    }

    @Test("register_directory_watcher's update with new instructions turns it off, and says so")
    func watcherUpdateClears() async throws {
        let base = try tempDirectory(prefix: "iris-urlclear")
        defer { try? FileManager.default.removeItem(at: base) }
        let notes = base.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let irisRoot = base.appendingPathComponent("dot-iris")
        try FileManager.default.createDirectory(at: irisRoot.appendingPathComponent("config"),
                                                withIntermediateDirectories: true)
        let store = try ConversationStore.inMemory()
        let announced = Announced()
        var configured = ToolExecutor()
        configured.jobToolsProvider = {
            JobTools(ledger: store.ledger, announceURLTriggerCleared: { await announced.add($0, $1) })
        }
        configured.irisPaths = IrisPaths(root: irisRoot)
        configured.homeDirectory = base.appendingPathComponent("home").path
        configured.watchBreakerProvider = { 30 }
        let executor = configured
        let conversation = UUID()
        func register(_ instructions: String) async -> String {
            await executor.execute(name: "register_directory_watcher",
                                   args: ["path": .string(notes.path), "instructions": .string(instructions)],
                                   conversationId: conversation)
        }

        _ = await register("summarise")
        let job = try #require(try store.ledger.jobs().first)
        // Never on: a changed watch says nothing about a trigger it never had.
        let unarmed = await register("summarise, briefly")
        #expect(!unarmed.contains("URL trigger"))
        #expect(await announced.names.isEmpty)

        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)

        let same = await register("summarise, briefly")
        #expect(!same.contains("URL trigger"), "re-stating the same watch changes nothing")
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == true)
        #expect(await announced.names.isEmpty)

        let changed = await register("summarise and file")
        #expect(changed.contains(ScheduleJobArguments.urlTriggerClearedNote(job.name)))
        #expect(!changed.contains(Self.digest))
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
        #expect(await announced.names == [job.name])
        #expect(await announced.ids == [job.id])
    }

    @Test("/jobs reschedule keeps it")
    func jobsRescheduleKeeps() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        let job = Job(name: "pr-sweep", prompt: "sweep", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: Self.digest)

        app.sendMessage("/jobs reschedule pr-sweep 0 9 * * *")

        #expect(try store.ledger.job(id: job.id)?.urlTrigger == true)
    }
}
