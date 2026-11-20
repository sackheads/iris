import Testing
import Foundation
@testable import IrisKit

/// #974 Task 12 (C8), the job half: a job carries the binding of the turn that made it, the ledger
/// keeps it (column and decode both), and the run's turn is confined by it on a real engine turn.
@MainActor
@Suite("a job keeps the binding it was created under (#974 Task 12, C8)", .serialized, .timeLimit(.minutes(2)))
struct JobBindingTests {
    private struct World {
        let root: URL
        let paths: IrisPaths
        let store: ConversationStore
        let state: AppState
    }

    private func world(profiles: [String: String] = [:]) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-t12-job-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        for (id, json) in profiles {
            try json.write(to: paths.profilesDir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
        }
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        return World(root: root, paths: paths, store: store, state: state)
    }

    private func config() -> (ConfigManager, () -> Void) {
        let name = "iris-jobbinding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ConfigManager(store: defaults), {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    /// A memory READ, because a read-only job run never declares a writer (it is refused before the
    /// binding is consulted): `search_memory` of the facts store needs `memoryRead >= .shared`.
    private func saveFactResponses() -> [GeminiResponse] {
        let call = FunctionCall(name: "search_memory", args: ["query": .string("sky"), "scope": .string("facts")])
        return [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ]
    }

    /// Fires `job` through a real `JobRunner` on the one `.main` engine and returns the run's
    /// conversation and the tool results its turn produced.
    private func fire(_ job: Job, in w: World) async throws -> (conversation: Conversation, results: String) {
        try w.store.ledger.upsert(job)
        let engine = IrisEngine(state: w.state, tier: .medium, client: FakeLLMClient(responses: saveFactResponses()),
                                factStore: try FactStoreManager(inMemory: true), protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: w.paths), accessProfileStore: AccessProfileStore(paths: w.paths))
        let (cfg, teardown) = config()
        defer { teardown() }
        let runner = JobRunner(state: w.state, engine: engine, ledger: w.store.ledger, endSandboxSession: { _ in },
                               now: { Date(timeIntervalSince1970: 1_700_000_000) }, config: cfg)
        await runner.fire(job: job, origin: .schedule)
        let conversation = try #require(w.state.conversations.first { $0.isBackground })
        let responses = conversation.history.flatMap { $0.parts }.compactMap { $0.functionResponse }
        return (conversation, responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n"))
    }

    private func job(accessProfileId: String?) -> Job {
        Job(name: "sweep", prompt: "save a fact", trigger: .schedule(.interval(seconds: 60)), accessProfileId: accessProfileId)
    }

    @Test("a stamped job's run is confined on a real turn: the run conversation carries the stamp and a memory read is refused (memoryRead key omitted)")
    func stampedJobIsConfined() async throws {
        let w = try world(profiles: ["blind": #"{"memoryWrite":4}"#, "reader": #"{"memoryRead":2}"#]); defer { try? FileManager.default.removeItem(at: w.root) }
        let (conversation, results) = try await fire(job(accessProfileId: "blind"), in: w)
        #expect(conversation.accessProfileId == "blind")
        #expect(results.contains(MemoryBindingGate.refusal), Comment(rawValue: results))
    }

    @Test("control: the same job with no stamp is the owner's, and the read is not refused")
    func unstampedJobIsOwner() async throws {
        let w = try world(profiles: ["blind": #"{"memoryWrite":4}"#, "reader": #"{"memoryRead":2}"#]); defer { try? FileManager.default.removeItem(at: w.root) }
        let (conversation, results) = try await fire(job(accessProfileId: nil), in: w)
        #expect(conversation.accessProfileId == nil)
        #expect(!results.contains(MemoryBindingGate.refusal), Comment(rawValue: results))
    }

    @Test("control: a job stamped with a profile that grants the read runs it (so the refusal above is the omitted key, not a profile that failed to load)")
    func grantedStampRuns() async throws {
        let w = try world(profiles: ["blind": #"{"memoryWrite":4}"#, "reader": #"{"memoryRead":2}"#]); defer { try? FileManager.default.removeItem(at: w.root) }
        let (conversation, results) = try await fire(job(accessProfileId: "reader"), in: w)
        #expect(conversation.accessProfileId == "reader")
        #expect(!results.contains(MemoryBindingGate.refusal) && results.contains("No relevant facts"), Comment(rawValue: results))
    }

    @Test("a job stamped with a profile that no longer exists fails closed: the read is refused, never run as owner")
    func vanishedProfileFailsClosed() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let (_, results) = try await fire(job(accessProfileId: "deleted"), in: w)
        #expect(results.contains(MemoryBindingGate.refusal), Comment(rawValue: results))
    }

    @Test("schedule_job from a conversation bound to a profile stamps the job; an owner conversation stamps nothing")
    func scheduleJobStampsTheCreator() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let bound = UUID(), owner = UUID()
        w.state.createNewConversation(id: bound)
        w.state.createNewConversation(id: owner)
        let idx = try #require(w.state.conversations.firstIndex { $0.id == bound })
        w.state.conversations[idx].accessProfileId = "reader"
        let engine = IrisEngine(state: w.state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        let args = ScheduleJobArguments.parse(["prompt": .string("tidy"), "intervalSeconds": .int(600)])
        _ = await engine.scheduleJob(args, conversationId: bound, sandboxAvailable: true)
        _ = await engine.scheduleJob(ScheduleJobArguments.parse(["prompt": .string("other"), "intervalSeconds": .int(900)]),
                                     conversationId: owner, sandboxAvailable: true)
        let jobs = try w.store.ledger.jobs()
        #expect(jobs.first { $0.prompt == "tidy" }?.accessProfileId == "reader")
        #expect(jobs.first { $0.prompt == "other" }?.accessProfileId == nil)
    }

    @Test("an update (a re-schedule under the same name) never changes a stamped job's profile, even if the conversation's has since changed")
    func updateKeepsTheStamp() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let conversation = UUID()
        w.state.createNewConversation(id: conversation)
        let idx = try #require(w.state.conversations.firstIndex { $0.id == conversation })
        w.state.conversations[idx].accessProfileId = "reader"
        let engine = IrisEngine(state: w.state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        func schedule(_ prompt: String) async {
            let args = ScheduleJobArguments.parse(["prompt": .string(prompt), "name": .string("tidy"), "intervalSeconds": .int(600)])
            _ = await engine.scheduleJob(args, conversationId: conversation, sandboxAvailable: true)
        }
        await schedule("first")
        #expect(try w.store.ledger.jobs().first?.accessProfileId == "reader")
        // The conversation is now the owner's (or another profile): the replace must not adopt that.
        w.state.conversations[idx].accessProfileId = nil
        await schedule("second")
        var jobs = try w.store.ledger.jobs()
        #expect(jobs.count == 1 && jobs.first?.prompt == "second", "the second call replaced the first")
        #expect(jobs.first?.accessProfileId == "reader", "an update of a confined job must not fire as owner")
        w.state.conversations[idx].accessProfileId = "other"
        await schedule("third")
        jobs = try w.store.ledger.jobs()
        #expect(jobs.count == 1 && jobs.first?.accessProfileId == "reader", "nor switch to a different profile")
    }

    @Test("a stamp saved to the ledger reloads intact (the column persists it, not only the Codable init)")
    func stampRoundTripsThroughTheLedger() throws {
        let store = try ConversationStore.inMemory()
        let stamped = job(accessProfileId: "reader")
        try store.ledger.upsert(stamped)
        let reloaded = try #require(try store.ledger.jobs().first { $0.id == stamped.id })
        #expect(reloaded.accessProfileId == "reader")
        // And it survives a second write that changes something else.
        var changed = reloaded
        changed.name = "renamed"
        try store.ledger.upsert(changed)
        #expect(try store.ledger.jobs().first { $0.id == stamped.id }?.accessProfileId == "reader")
    }

    @Test("a job written before the field existed loads: no throw, no dropped row, owner's (nil)")
    func rowWithoutTheKeyLoads() throws {
        // The Codable half: the key is simply absent from the JSON.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job(accessProfileId: "reader"))) as? [String: Any])
        #expect(object["accessProfileId"] as? String == "reader")
        object.removeValue(forKey: "accessProfileId")
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.accessProfileId == nil, "an absent key is nil, not a decode failure")
        // The ledger half: a row whose column is NULL (every row written before the migration) is
        // still listed, and reads back as the owner's.
        let store = try ConversationStore.inMemory()
        let old = job(accessProfileId: nil)
        try store.ledger.upsert(old)
        let rows = try store.ledger.jobs()
        #expect(rows.count == 1 && rows.first?.id == old.id && rows.first?.accessProfileId == nil)
    }
}
