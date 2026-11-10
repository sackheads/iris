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
                     "rename_conversation", "inbox_item"] {
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

/// #1026: the approved-call path (`executeApprovedCall`) used to taint unconditionally — "the
/// person approved running the call, not what came back" — which over-triggers on nearly every
/// session, since an approved call happens far more often than real untrusted ingestion. The fix
/// only removes taint where the result provably cannot carry outside content, the same bar
/// `resultCarriesOutsideContent` enforces for the main-turn path; `read_file`'s first-party
/// carve-out (`isFirstPartyRead`, applied inside `executeToolWithHooks` for a model-turn read, a
/// path `executeApprovedCall` never reaches) is reproduced here against `decidedPath`, the already-
/// resolved path `executeApprovedCall` computes when there is no sandbox grant. Ambiguous cases
/// (no plain filesystem path decided, i.e. a sandbox grant) keep tainting.
@Suite("Untrusted-output taint: approved-call classifier (#1026)")
struct ApprovedCallTaintClassifierTests {
    @Test func ownWordsDoNotTaintRegardlessOfPath() {
        #expect(!IrisEngine.approvedCallResultCarriesOutsideContent("write_file", args: [:], decidedPath: "/tmp/anything"))
        #expect(!IrisEngine.approvedCallResultCarriesOutsideContent("write_file", args: [:], decidedPath: nil))
    }

    @Test func outsideContentStillTaints() {
        for name in ["run_command", "search_web", "gmail_send_email"] {
            #expect(IrisEngine.approvedCallResultCarriesOutsideContent(name, args: [:], decidedPath: nil), "\(name)")
        }
    }

    /// `decidedPath` is checked against `IrisPaths.default` (the predicate takes no `paths:`
    /// parameter — it reproduces the main-turn path's own default), so this uses the real
    /// standing-context paths rather than a fixture root.
    @Test func readFileOfAFirstPartyPathDoesNotTaint() {
        #expect(!IrisEngine.approvedCallResultCarriesOutsideContent(
            "read_file", args: [:], decidedPath: IrisPaths.default.soulMd.path))
        #expect(!IrisEngine.approvedCallResultCarriesOutsideContent(
            "read_file", args: [:], decidedPath: IrisPaths.default.rulesDir.appendingPathComponent("a.md").path))
    }

    @Test func readFileOfANonFirstPartyPathStillTaints() {
        #expect(IrisEngine.approvedCallResultCarriesOutsideContent(
            "read_file", args: [:], decidedPath: "/tmp/iris-1026-\(UUID().uuidString)/outside.txt"))
        #expect(IrisEngine.approvedCallResultCarriesOutsideContent(
            "read_file", args: [:], decidedPath: IrisPaths.default.workspacesDir.appendingPathComponent("repo/README.md").path),
            "a cloned workspace under ~/.iris is someone else's text, same as the main-turn path")
    }

    /// No plain filesystem path was decided (a sandbox grant resolves the path a different way) —
    /// ambiguous, so this stays on the fail-safe side rather than guessing it is first-party.
    @Test func readFileWithNoDecidedPathStaysAmbiguousAndTaints() {
        #expect(IrisEngine.approvedCallResultCarriesOutsideContent("read_file", args: [:], decidedPath: nil))
    }

    /// dev-2 review (#1041): `args["path"]` must never stand in for `decidedPath`. An attacker can
    /// spell `args["path"]` as anything, including a real first-party path, while a sandbox grant
    /// resolves the actual read somewhere else entirely — so a nil `decidedPath` taints regardless
    /// of what `args` claims. This pins the function against a plausible-looking "simplification"
    /// that derives a path from `args` instead of taking the caller's own resolution.
    @Test func readFileWithNoDecidedPathTaintsEvenWithAFirstPartyLookingArgsPath() {
        #expect(IrisEngine.approvedCallResultCarriesOutsideContent(
            "read_file", args: ["path": .string(IrisPaths.default.soulMd.path)], decidedPath: nil))
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

/// #1026: `executeApprovedCall` end-to-end, through the real dispatcher — not just the classifier
/// function above — pinning both directions so a future change can't silently under-taint.
@MainActor
@Suite("Untrusted-output taint: approved-call path end-to-end (#1026)", .timeLimit(.minutes(1)))
struct ApprovedCallTaintEngineTests {
    private func harness() throws -> (AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (state, engine)
    }

    private func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-1026-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an approved call with a non-outside-content result does not taint")
    func approvedWriteFileDoesNotTaint() async throws {
        let (state, engine) = try harness()
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(dir.appendingPathComponent("a.txt").path),
                                      "content": .string("hi")], cwd: dir.path)

        _ = await engine.executeApprovedCall(call, conversationId: conversationId)

        #expect(state.conversations.first { $0.id == conversationId }?.hasUntrustedToolOutput == false)
    }

    @Test("an approved read of Iris's own standing context does not taint")
    func approvedReadOfAFirstPartyPathDoesNotTaint() async throws {
        let (state, engine) = try harness()
        let rule = IrisPaths.default.rulesDir.appendingPathComponent("taint-1026-\(UUID().uuidString).md")
        try FileManager.default.createDirectory(at: IrisPaths.default.rulesDir, withIntermediateDirectories: true)
        try "mine".write(to: rule, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rule) }
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")
        let call = BlockedCall(toolName: "read_file", args: ["path": .string(rule.path)])

        _ = await engine.executeApprovedCall(call, conversationId: conversationId)

        #expect(state.conversations.first { $0.id == conversationId }?.hasUntrustedToolOutput == false)
    }

    @Test("an approved call whose result carries outside content still taints")
    func approvedReadOfAnOutsidePathStillTaints() async throws {
        let (state, engine) = try harness()
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appendingPathComponent("theirs.txt")
        try "theirs".write(to: outside, atomically: true, encoding: .utf8)
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")
        let call = BlockedCall(toolName: "read_file", args: ["path": .string(outside.path)])

        _ = await engine.executeApprovedCall(call, conversationId: conversationId)

        #expect(state.conversations.first { $0.id == conversationId }?.hasUntrustedToolOutput == true)
    }

    /// Under a sandbox grant, `executeApprovedCall` never computes a plain `decidedPath` (it hands
    /// the executor the grant instead) — so this taints, the fail-safe side, rather than guessing.
    /// `args["path"]` is deliberately spelled as a genuine first-party path
    /// (`IrisPaths.default.soulMd.path`) while the grant mounts an unrelated directory: a correct
    /// implementation never looks at `args` for `read_file` (only `decidedPath`, which is nil here),
    /// so it must still taint. A version that "simplified" by deriving a path from `args["path"]`
    /// instead of the caller's `decidedPath` would wrongly clear this — the gap dev-2's review of
    /// #1041 found. The read itself may fail (nothing granted this mount in the real sandbox), which
    /// is fine: taint is decided independently of whether the call actually succeeded.
    @Test("an approved read under a sandbox grant taints, even when args names a real first-party path")
    func approvedReadUnderAGrantStaysAmbiguousAndTaints() async throws {
        let (state, engine) = try harness()
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")
        let grant = JobGrant(mounts: [ContainerMount(source: dir.path)])
        guard let idx = state.conversations.firstIndex(where: { $0.id == conversationId }) else {
            Issue.record("conversation not found")
            return
        }
        state.conversations[idx].sandboxGrant = grant
        let call = BlockedCall(toolName: "read_file", args: ["path": .string(IrisPaths.default.soulMd.path)])

        _ = await engine.executeApprovedCall(call, conversationId: conversationId)

        #expect(state.conversations.first { $0.id == conversationId }?.hasUntrustedToolOutput == true)
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
