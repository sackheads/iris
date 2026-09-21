import Testing
import Foundation
@testable import iris

/// #187 §9, invariant 6 — `list_jobs` and `get_job_run` cost prompt tokens on every turn they are
/// declared, and only a pinned conversation (the Activity conversation) is about jobs at all. The
/// gate is a pure function so both answers can be pinned without driving a turn; one turn through
/// a capturing client then proves the real tool list is actually assembled from it.
@MainActor
@Suite("job tools (#187)")
struct JobToolsTests {

    private let names = ["list_jobs", "get_job_run"]

    // MARK: The declaration gate (D2-R3)

    @Test("an unpinned conversation declares neither job tool")
    func noDeclarationsWhenUnpinned() {
        #expect(IrisEngine.jobToolDeclarations(isPinned: false).isEmpty)
    }

    @Test("a pinned conversation declares exactly the two job tools")
    func declarationsWhenPinned() {
        let declared = IrisEngine.jobToolDeclarations(isPinned: true)
        #expect(declared.map(\.name) == names)
        #expect(declared.allSatisfy { !$0.description.isEmpty })
    }

    @Test("list_jobs takes no arguments and get_job_run requires a run_id")
    func declarationParameters() {
        let declared = IrisEngine.jobToolDeclarations(isPinned: true)
        let list = declared.first { $0.name == "list_jobs" }
        #expect(list?.parameters?.type == "OBJECT")
        #expect(list?.parameters?.properties?.isEmpty == true)
        #expect(list?.parameters?.required?.isEmpty == true)

        let get = declared.first { $0.name == "get_job_run" }
        #expect(get?.parameters?.required == ["run_id"])
        #expect(get?.parameters?.properties?["run_id"]?.type == "STRING")
    }

    /// The gate helper on its own cannot tell whether anything appends it — a previous suite in
    /// this tree went green against a test-only mirror of a declaration production had already
    /// deleted (see `SessionToolsTests`). One real turn against a capturing client reads the tools
    /// actually sent, for both values of the gate.
    private func declaredToolNames(pinned: Bool) async -> [String] {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if pinned, let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].isPinned = true
        }
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("the job tools reach a pinned turn's real tool list")
    func declaredOnPinnedTurn() async {
        let declared = await declaredToolNames(pinned: true)
        for n in names { #expect(declared.contains(n), Comment(rawValue: n)) }
    }

    @Test("no other conversation sees them (invariant 6)")
    func absentOnOrdinaryTurn() async {
        let declared = await declaredToolNames(pinned: false)
        for n in names { #expect(!declared.contains(n), Comment(rawValue: n)) }
    }

    // MARK: Handlers

    private func job(_ name: String = "pr-sweep") -> Job {
        Job(name: name, prompt: "do the thing", trigger: .schedule(.interval(seconds: 60)))
    }

    /// Scripts one tool call in a pinned conversation and hands back the result the model saw —
    /// the `functionResponse` the engine wrote into `history`, the same read `SessionToolsTests`
    /// uses. `protectionEnabled: false` keeps the guard tiers (process-wide singletons other
    /// suites mock) out of it; the structural wrapper still applies.
    private func runToolCall(_ call: FunctionCall, on app: AppState, as conversationId: UUID) async -> String {
        let first = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let client = FakeLLMClient(responses: [first, final])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: conversationId)
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    private func pinnedApp() -> (AppState, UUID) {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].isPinned = true
        }
        return (app, id)
    }

    @Test("list_jobs answers with one JSON object per job")
    func listJobsShape() async throws {
        let (app, id) = pinnedApp()
        var j = job()
        j.nextFireAt = Date(timeIntervalSince1970: 1_700_000_000)
        try app.store.ledger.upsert(j)
        let r = JobRun(jobId: j.id, jobName: j.name, triggerKind: j.trigger.kind, startedAt: Date())
        try app.store.ledger.begin(run: r)
        try app.store.ledger.finish(runId: r.id, status: .completed, outcome: "swept 3",
                                    failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                    finishedAt: Date())

        let result = await runToolCall(FunctionCall(name: "list_jobs", args: [:], id: "c1"),
                                       on: app, as: id)

        let data = Data(result.utf8)
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["name"] as? String == "pr-sweep")
        #expect(rows[0]["trigger"] as? String == "every 60 s")
        #expect(rows[0]["enabled"] as? Bool == true)
        #expect((rows[0]["nextFireAt"] as? String)?.hasPrefix("2023-11-14") == true)
        #expect(rows[0]["lastStatus"] as? String == "completed")
    }

    @Test("list_jobs with no jobs is an empty array, not prose")
    func listJobsEmpty() async throws {
        let (app, id) = pinnedApp()
        let result = await runToolCall(FunctionCall(name: "list_jobs", args: [:], id: "c1"),
                                       on: app, as: id)
        let rows = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]]
        #expect(rows?.isEmpty == true)
    }

    @Test("get_job_run returns the ledger row plus the transcript's last agent message")
    func getJobRunShape() async throws {
        let (app, id) = pinnedApp()
        let j = job()
        try app.store.ledger.upsert(j)
        let transcript = UUID()
        app.createNewConversation(id: transcript, select: false)
        app.appendMessage(role: .agent, content: "an earlier answer", to: transcript)
        app.appendMessage(role: .agent, content: "swept 3 PRs, all green", to: transcript)
        app.appendMessage(role: .system, content: "a system line after it", to: transcript)
        let r = JobRun(jobId: j.id, jobName: j.name, triggerKind: j.trigger.kind,
                       startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                       transcriptConversationId: transcript)
        try app.store.ledger.begin(run: r)
        try app.store.ledger.finish(runId: r.id, status: .failed, outcome: "swept 3 PRs",
                                    failureReason: "HTTP 503", blockedTool: nil,
                                    tokens: TokenUsage(promptTokenCount: 10, candidatesTokenCount: 4,
                                                       totalTokenCount: 14),
                                    finishedAt: Date(timeIntervalSince1970: 1_700_000_060))

        let result = await runToolCall(
            FunctionCall(name: "get_job_run", args: ["run_id": .string(r.id.uuidString)], id: "c1"),
            on: app, as: id)

        let row = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(row["id"] as? String == r.id.uuidString)
        #expect(row["jobName"] as? String == "pr-sweep")
        #expect(row["status"] as? String == "failed")
        #expect(row["outcome"] as? String == "swept 3 PRs")
        #expect(row["failureReason"] as? String == "HTTP 503")
        #expect(row["totalTokens"] as? Int == 14)
        #expect((row["startedAt"] as? String)?.hasPrefix("2023-11-14") == true)
        let message = try #require(row["lastAgentMessage"] as? String)
        #expect(message.contains("swept 3 PRs, all green"))
        #expect(!message.contains("an earlier answer"), "the LAST agent message, not the first")
        #expect(!message.contains("a system line after it"))
    }

    @Test("a long transcript message is cut at 2,000 characters")
    func getJobRunTruncatesTranscript() async throws {
        let (app, id) = pinnedApp()
        let j = job()
        try app.store.ledger.upsert(j)
        let transcript = UUID()
        app.createNewConversation(id: transcript, select: false)
        app.appendMessage(role: .agent, content: String(repeating: "y", count: 5_000), to: transcript)
        let r = JobRun(jobId: j.id, jobName: j.name, triggerKind: j.trigger.kind, startedAt: Date(),
                       transcriptConversationId: transcript)
        try app.store.ledger.begin(run: r)

        let result = await runToolCall(
            FunctionCall(name: "get_job_run", args: ["run_id": .string(r.id.uuidString)], id: "c1"),
            on: app, as: id)

        let row = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let message = try #require(row["lastAgentMessage"] as? String)
        // Counted on a character the `<untrusted_context>` wrapper does not itself contain.
        #expect(message.filter { $0 == "y" }.count == IrisEngine.jobRunTranscriptExcerpt)
    }

    @Test("a run whose transcript is gone still returns its row")
    func getJobRunWithoutTranscript() async throws {
        let (app, id) = pinnedApp()
        let j = job()
        try app.store.ledger.upsert(j)
        let r = JobRun(jobId: j.id, jobName: j.name, triggerKind: j.trigger.kind, startedAt: Date(),
                       transcriptConversationId: UUID())
        try app.store.ledger.begin(run: r)

        let result = await runToolCall(
            FunctionCall(name: "get_job_run", args: ["run_id": .string(r.id.uuidString)], id: "c1"),
            on: app, as: id)

        let row = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(row["status"] as? String == "running")
        #expect(row["lastAgentMessage"] == nil || row["lastAgentMessage"] is NSNull)
    }

    @Test("an unknown run id says so rather than returning an empty row")
    func getJobRunUnknown() async {
        let (app, id) = pinnedApp()
        let result = await runToolCall(
            FunctionCall(name: "get_job_run", args: ["run_id": .string(UUID().uuidString)], id: "c1"),
            on: app, as: id)
        #expect(result.contains("No run with that id."))
    }

    /// An event card's history line names its run by the first eight characters of the id
    /// (`EventCard.historyLine`), so that is the id the model has to hand — the tool has to accept
    /// it, or the only pointer it is ever given is unusable.
    @Test("the eight-character id an event card shows is enough to fetch the run")
    func getJobRunByCardPrefix() async throws {
        let (app, id) = pinnedApp()
        let j = job()
        try app.store.ledger.upsert(j)
        let r = JobRun(jobId: j.id, jobName: j.name, triggerKind: j.trigger.kind, startedAt: Date())
        try app.store.ledger.begin(run: r)

        let prefix = String(r.id.uuidString.lowercased().prefix(8))
        let result = await runToolCall(
            FunctionCall(name: "get_job_run", args: ["run_id": .string(prefix)], id: "c1"),
            on: app, as: id)

        let row = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(row["id"] as? String == r.id.uuidString)
    }

    /// Invariant 6 is a property of the conversation, not of what the model was offered: dispatch
    /// reads `functionCall.name` alone, so an unpinned conversation that calls the tool anyway
    /// must be refused where it would otherwise read the ledger.
    @Test("a forged call from an unpinned conversation is refused by the handler")
    func forgedCallRefused() async throws {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        try app.store.ledger.upsert(job())

        let result = await runToolCall(FunctionCall(name: "list_jobs", args: [:], id: "c1"),
                                       on: app, as: id)

        #expect(result.contains("Refused"))
        #expect(!result.contains("pr-sweep"))
    }

    @Test("a malformed run id says so rather than crashing")
    func getJobRunMalformed() async {
        let (app, id) = pinnedApp()
        let result = await runToolCall(
            FunctionCall(name: "get_job_run", args: ["run_id": .string("not-a-uuid")], id: "c1"),
            on: app, as: id)
        #expect(result.contains("No run with that id."))
    }
}
