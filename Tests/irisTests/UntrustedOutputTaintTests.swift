import Testing
import Foundation
import GRDB
@testable import IrisKit

private func eventually(_ timeoutMs: Int = 5000, _ condition: @MainActor @Sendable () -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// #813: which results taint a conversation. Default-taint: only a result that is Iris's own words
/// leaves it clean, so a tool added later taints until someone decides otherwise.
@Suite("Untrusted-output taint: what taints (#813)")
struct UntrustedOutputClassifierTests {
    @Test func ownWordsDoNotTaint() {
        for name in ["write_file", "create_skill", "update_soul", "save_fact", "reflect", "set_workspace",
                     "rename_conversation"] {
            #expect(!IrisEngine.resultCarriesOutsideContent(name, args: [:]), "\(name)")
        }
    }

    @Test func outsideContentTaints() {
        for name in ["run_command", "search_web", "gmail_list_unread", "google_docs_get", "search_memory",
                     "search_conversations", "read_conversation", "get_job_run", "list_jobs",
                     "list_sessions", "describe_session", "delegate_milestone",
                     "someserver___fetch", "a_tool_nobody_declared",
                     // #818 review: these can return text they didn't compose.
                     "goal_complete", "reach_checkpoint", "gmail_send_email", "google_calendar_create_event",
                     "google_tasks_create_task", "send_to_session", "set_session_card", "manage_fact"] {
            #expect(IrisEngine.resultCarriesOutsideContent(name, args: [:]), "\(name)")
        }
    }

    /// A plain read is decided after the hooks, on the path read; only an artifact is decided here.
    @Test func readFileIsDecidedByWhatIsRead() {
        #expect(!IrisEngine.resultCarriesOutsideContent("read_file", args: ["path": .string("/tmp/x")]))
        #expect(IrisEngine.resultCarriesOutsideContent("read_file",
                                                       args: ["path": .string("iris-artifact://" + String(repeating: "a", count: 64))]))
    }

    /// Only Iris's own standing context is first-party; the rest of ~/.iris can hold anyone's text.
    @Test func onlyStandingContextIsAFirstPartyRead() {
        let paths = IrisPaths(root: URL(fileURLWithPath: "/tmp/iris-813-\(UUID().uuidString)"))
        for url in [paths.soulMd, paths.userMd, paths.memoryMd, paths.skillsDir.appendingPathComponent("x/SKILL.md"),
                    paths.rulesDir.appendingPathComponent("a.md"), paths.configDir.appendingPathComponent("hooks.json")] {
            #expect(IrisEngine.isFirstPartyRead(url.path, paths: paths), "\(url.path)")
        }
        for url in [paths.workspacesDir.appendingPathComponent("repo/README.md"), paths.pluginsDir.appendingPathComponent("p/rules.md"),
                    paths.libraryDir.appendingPathComponent("doc.md"), paths.artifactsDir.appendingPathComponent("a.txt"),
                    paths.root.appendingPathComponent("notes.md")] {
            #expect(!IrisEngine.isFirstPartyRead(url.path, paths: paths), "\(url.path)")
        }
    }

    @Test func aBackgroundSubagentTaintsOnlyWhenItReports() {
        #expect(!IrisEngine.resultCarriesOutsideContent("invoke_subagent", args: ["background": .string("true")]))
        #expect(IrisEngine.resultCarriesOutsideContent("invoke_subagent", args: ["role": .string("r")]))
    }
}

/// #813: the flag persists, and whatever predates it or can't be read counts as tainted, the
/// opposite of `hasUnattendedInput`'s default, because set is this flag's cautious side.
@MainActor
@Suite("Untrusted-output taint: persistence (#813)")
struct UntrustedOutputPersistenceTests {
    @Test func aNewConversationStartsClean() {
        #expect(Conversation(id: UUID(), title: "t", workspacePath: nil).hasUntrustedToolOutput == false)
    }

    @Test func anAbsentKeyDecodesAsTainted() throws {
        let clean = Conversation(id: UUID(), title: "t", workspacePath: nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clean)) as? [String: Any])
        #expect(json["hasUntrustedToolOutput"] as? Bool == false)
        let kept = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(kept.hasUntrustedToolOutput == false, "a present false stays false")
        json.removeValue(forKey: "hasUntrustedToolOutput")
        let legacy = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.hasUntrustedToolOutput == true)
    }

    @Test func aNullColumnReadsAsTainted() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store)
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.hasUntrustedToolOutput == false)
        try store.rawWrite("UPDATE conversations SET hasUntrustedToolOutput = NULL WHERE id = ?", arguments: [id.uuidString])
        #expect(try store.loadAll().conversations.first { $0.id == id }?.hasUntrustedToolOutput == true)
    }

    @Test func anUnreadableValueReadsAsTainted() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store)
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.flushSave()
        try store.rawWrite("UPDATE conversations SET hasUntrustedToolOutput = 'not-a-bool' WHERE id = ?", arguments: [id.uuidString])
        #expect(try store.loadAll().conversations.first { $0.id == id }?.hasUntrustedToolOutput == true)
    }

    /// Both upsert branches: the first flush is the INSERT, the second (after marking) an UPDATE.
    @Test func theTaintSurvivesAReloadThroughInsertAndUpdate() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store)
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.hasUntrustedToolOutput == false)
        app.markConversationReadUntrusted(id)
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.hasUntrustedToolOutput == true)

        let other = UUID()
        app.createNewConversation(id: other)
        app.markConversationReadUntrusted(other)
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == other }?.hasUntrustedToolOutput == true)
    }
}

/// #813: the engine sets the flag where untrusted text reaches the model, and only there.
@MainActor
@Suite("Untrusted-output taint: the engine sets it (#813)", .timeLimit(.minutes(1)))
struct UntrustedOutputEngineTests {
    private func session(_ calls: [FunctionCall]) -> (AppState, IrisEngine, UUID) {
        var script: [[ScriptedStreamClient.Step]] = calls.map { [.event(.functionCall($0)), .event(.done(finishReason: "tool_use"))] }
        script.append([.event(.textDelta("done")), .event(.done(finishReason: nil))])
        script.append([.event(.textDelta("spare")), .event(.done(finishReason: nil))])
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        return (app, engine, id)
    }

    private func tainted(_ app: AppState, _ id: UUID) -> Bool {
        app.conversations.first { $0.id == id }?.hasUntrustedToolOutput == true
    }

    private func finished(_ app: AppState, _ id: UUID) -> Bool {
        (app.conversations.first { $0.id == id }?.history ?? []).contains { $0.role == "model" && $0.parts.contains { $0.text == "done" } }
    }

    @Test func aCommandsOutputTaints() async {
        let (app, _, id) = session([FunctionCall(name: "run_command", args: ["command": .string("echo hi")], id: "c1")])
        #expect(!tainted(app, id))
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        #expect(tainted(app, id))
    }

    @Test func ownWordsLeaveItClean() async {
        let (app, _, id) = session([FunctionCall(name: "reflect", args: ["thoughts": .string("noted")], id: "c1")])
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        #expect(!tainted(app, id))
    }

    /// Iris's own standing context is first-party; any other file is someone else's text, a cloned
    /// workspace under ~/.iris included (#818 review).
    @Test func aReadTaintsOutsideIrisStandingContext() async throws {
        let own = IrisPaths.default.rulesDir.appendingPathComponent("taint-813-\(UUID().uuidString).md")
        let cloned = IrisPaths.default.workspacesDir.appendingPathComponent("taint-813-\(UUID().uuidString).md")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("taint-813-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: IrisPaths.default.rulesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: IrisPaths.default.workspacesDir, withIntermediateDirectories: true)
        try "mine".write(to: own, atomically: true, encoding: .utf8)
        try "theirs".write(to: outside, atomically: true, encoding: .utf8)
        try "cloned".write(to: cloned, atomically: true, encoding: .utf8)
        defer { for u in [own, outside, cloned] { try? FileManager.default.removeItem(at: u) } }

        let (app, _, id) = session([FunctionCall(name: "read_file", args: ["path": .string(own.path)], id: "c1")])
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        #expect(!tainted(app, id), "a read of a rule is first-party")

        let (app2, _, id2) = session([FunctionCall(name: "read_file", args: ["path": .string(outside.path)], id: "c1")])
        app2.sendMessage("go")
        #expect(await eventually { self.finished(app2, id2) })
        #expect(tainted(app2, id2))

        let (app3, _, id3) = session([FunctionCall(name: "read_file", args: ["path": .string(cloned.path)], id: "c1")])
        app3.sendMessage("go")
        #expect(await eventually { self.finished(app3, id3) })
        #expect(tainted(app3, id3), "a workspace under ~/.iris is someone else's text")
    }

    /// #818 review: a subagent of a tainted parent starts tainted, or delegating walks around the
    /// hold. Read from inside the subagent's first model call: its own `goal_complete` taints it
    /// afterwards either way.
    @Test func aSubagentInheritsItsParentsTaint() async throws {
        let app = AppState()
        app.autoApproveTools = true
        func startedTainted(parent: UUID) async -> Bool? {
            let done = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "goal_complete", args: ["summary": .string("done")]))]))], usageMetadata: nil)
            let client = TaintProbe(response: done) {
                await MainActor.run { app.conversations.last { $0.isSubagent }?.hasUntrustedToolOutput }
            }
            _ = await SubagentManager.shared.runSubagent(role: "w", task: "t", effort: "easy", parentConversationId: parent,
                                                         client: client, appState: app)
            return client.seen
        }
        let clean = app.createNewConversation(select: false)
        #expect(await startedTainted(parent: clean) == false, "a clean parent's subagent starts clean")
        let dirty = app.createNewConversation(select: false)
        app.markConversationReadUntrusted(dirty)
        #expect(await startedTainted(parent: dirty) == true)
    }
}

/// Answers every call with one response, recording what `probe` saw at the first.
private final class TaintProbe: LLMClientProtocol, @unchecked Sendable {
    private let probe: @Sendable () async -> Bool?
    private let response: GeminiResponse
    private let lock = NSLock()
    private var first: Bool??
    init(response: GeminiResponse, probe: @escaping @Sendable () async -> Bool?) {
        self.response = response
        self.probe = probe
    }
    var seen: Bool? { lock.withLock { first ?? nil } }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        let observed = await probe()
        lock.withLock { if first == nil { first = observed } }
        return response
    }
}
