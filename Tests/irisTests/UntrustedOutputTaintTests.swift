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
                     "gmail_send_email", "goal_complete", "send_to_session"] {
            #expect(!IrisEngine.resultCarriesOutsideContent(name, args: [:]), "\(name)")
        }
    }

    @Test func outsideContentTaints() {
        for name in ["run_command", "search_web", "gmail_list_unread", "google_docs_get", "search_memory",
                     "search_conversations", "read_conversation", "get_job_run", "list_jobs",
                     "list_sessions", "describe_session", "delegate_milestone",
                     "someserver___fetch", "a_tool_nobody_declared"] {
            #expect(IrisEngine.resultCarriesOutsideContent(name, args: [:]), "\(name)")
        }
    }

    /// A plain read is decided after the hooks, on the path read; only an artifact is decided here.
    @Test func readFileIsDecidedByWhatIsRead() {
        #expect(!IrisEngine.resultCarriesOutsideContent("read_file", args: ["path": .string("/tmp/x")]))
        #expect(IrisEngine.resultCarriesOutsideContent("read_file",
                                                       args: ["path": .string("iris-artifact://" + String(repeating: "a", count: 64))]))
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

    /// Iris's own file is first-party; any other file is someone else's text.
    @Test func aReadTaintsOnlyOutsideIrisOwnFolder() async throws {
        let own = IrisPaths.default.root.appendingPathComponent("taint-813-\(UUID().uuidString).md")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("taint-813-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: IrisPaths.default.root, withIntermediateDirectories: true)
        try "mine".write(to: own, atomically: true, encoding: .utf8)
        try "theirs".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: own); try? FileManager.default.removeItem(at: outside) }

        let (app, _, id) = session([FunctionCall(name: "read_file", args: ["path": .string(own.path)], id: "c1")])
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        #expect(!tainted(app, id), "a read under ~/.iris is first-party")

        let (app2, _, id2) = session([FunctionCall(name: "read_file", args: ["path": .string(outside.path)], id: "c1")])
        app2.sendMessage("go")
        #expect(await eventually { self.finished(app2, id2) })
        #expect(tainted(app2, id2))
    }

    @Test func anArrivalTaints() async {
        let (app, engine, id) = session([])
        #expect(!tainted(app, id))
        await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id)
        #expect(await eventually { self.tainted(app, id) })
        await engine.cancelReprompt(for: id)
    }
}
