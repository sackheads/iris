import Testing
import Foundation
@testable import IrisKit

/// #599: a tool call that ran without asking says which layer let it, and why, on its pill, and
/// the record survives a relaunch. Each test builds its own `AppState`, store and
/// `PermissionManager` (Invariant 7).
@MainActor
@Suite("A tool call's pill says what approved it (#599)", .timeLimit(.minutes(1)))
struct ToolApprovalTests {

    private final class Approver: AuxiliaryInferenceEngine, @unchecked Sendable {
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            #"{"decision":"APPROVE","reason":"routine build step"}"#
        }
    }

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-599-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func app(_ home: URL) throws -> AppState {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home.appendingPathComponent("iris-home")))
        return state
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))], usageMetadata: nil)
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    /// One attended turn making `response`'s call. A prompt it raises is answered with `answer`.
    private func turn(_ state: AppState, _ response: GeminiResponse, workspace: URL,
                      answer: AppState.ApprovalResolution = .deny) async throws -> (UUID, ChatMessage?) {
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [response, text("done.")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let id = state.createNewConversation(isBackground: false, select: false)
        state.setWorkspace(for: id, path: workspace.path)
        let finished = Locked(false)
        let task = Task { @MainActor in
            await engine.processInput("go", source: "UI", conversationId: id)
            finished.mutate { $0 = true }
        }
        for _ in 0..<1000 where !finished.value {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                state.resolveApproval(id: request.id, answer)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try await value(of: task)
        let pill = state.conversations.first { $0.id == id }?.messages.first { ToolCallParser.parse($0.content) != nil }
        return (id, pill)
    }

    // MARK: the allowlist says which part matched

    @Test("match names the scope and the rule that let a call run, and isAllowed agrees")
    func matchNamesScopeAndRule() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root.appendingPathComponent("iris-home"))
        let permissions = PermissionManager(paths: paths)
        let command = "make test-\(UUID().uuidString)"
        #expect(permissions.match(toolName: "run_command", details: command, workspace: nil) == nil)
        permissions.allowGlobally(toolName: "run_command", details: command)
        #expect(permissions.match(toolName: "run_command", details: command, workspace: nil)
                == AllowMatch(scope: .global, rule: PermissionRule(toolName: "run_command", details: command)))
        #expect(permissions.isAllowed(toolName: "run_command", details: command, workspace: nil))
        let own = paths.root.appendingPathComponent("memory/notes.md").path
        #expect(permissions.match(toolName: "read_file", details: own, workspace: nil) == AllowMatch(scope: .irisHome, rule: nil))
    }

    // MARK: what the ladder returns

    @Test("each silent layer comes back with its reason: Vibecop's words, the rule, the grant's mount")
    func ladderCarriesReasons() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try app(root)
        let cid = state.createNewConversation(isBackground: false, select: false)
        let inVM = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": Approver()]) {
            await state.requestApprovalSource(toolName: "run_command", details: "make", workspace: nil,
                                              conversationId: cid, inSandbox: true, vibecopEnabled: true)
        }
        #expect(inVM == .vibecop(reason: "routine build step"))
        #expect(ToolApproval(try #require(inVM)).line == "Approved by Vibecop: routine build step")

        let command = "make ok-\(UUID().uuidString)"
        state.permissions.allowGlobally(toolName: "run_command", details: command)
        let ruled = try #require(await state.requestApprovalSource(toolName: "run_command", details: command,
                                                                   workspace: nil, conversationId: cid, vibecopEnabled: false))
        #expect(ToolApproval(ruled).line == "Allowed by a rule in your global rules: run_command \(command)")

        // A granted job run's file tool: the grant's mount is the reason.
        let rw = root.appendingPathComponent("rw")
        try FileManager.default.createDirectory(at: rw, withIntermediateDirectories: true)
        let bid = state.createNewConversation(isBackground: true, select: false)
        let index = try #require(state.conversations.firstIndex { $0.id == bid })
        state.conversations[index].sandboxGrant = JobGrant(mounts: [ContainerMount(source: rw.path)], network: false)
        let granted = await state.requestApprovalSource(toolName: "write_file", details: rw.appendingPathComponent("a").path,
                                                        workspace: rw.path, conversationId: bid,
                                                        grantedMount: ContainerMount(source: rw.path))
        #expect(granted == .grant(mount: rw.path))
    }

    @Test("a humanOnly call in a background conversation is refused and recorded, whatever rule matches")
    func humanOnlyInBackgroundIsRefused() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try app(root)
        let bid = state.createNewConversation(isBackground: true, select: false)
        let details = "schedule a job \(UUID().uuidString)"
        state.permissions.allowGlobally(toolName: "schedule_job", details: details)
        let source = await state.requestApprovalSource(toolName: "schedule_job", details: details, workspace: nil,
                                                       conversationId: bid, humanOnly: true)
        #expect(source == nil, "nobody is there to ask, and a rule does not stand in for them")
        #expect(state.takeBackgroundDenials(for: bid).count == 1, "the refusal is on the record")
    }

    // MARK: on the pill, through a real turn

    @Test("an allowlisted write's pill names the rule; a person's approval adds no line")
    func pillThroughATurn() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let target = IrisPaths.realPath(workspace.path) + "/out.txt"

        let state = try app(root)
        state.permissions.allowGlobally(toolName: "write_file", details: target)
        let (_, pill) = try await turn(state, call("write_file", ["path": .string(target), "content": .string("x")]),
                                       workspace: workspace)
        let approval = try #require(pill?.approval)
        #expect(approval.layer == .allowlist && approval.scope == "global")
        #expect(approval.line == "Allowed by a rule in your global rules: write_file \(target)")

        let asked = try app(root)
        let other = IrisPaths.realPath(workspace.path) + "/asked.txt"
        let (_, askedPill) = try await turn(asked, call("write_file", ["path": .string(other), "content": .string("x")]),
                                            workspace: workspace, answer: .approve)
        #expect(askedPill?.approval?.layer == .person)
        #expect(askedPill?.approval?.line == nil, "the dialog is a person's record")
    }

    @Test("a tool with no approval step says nobody was asked")
    func ungatedSaysSo() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try app(root)
        // An offered tool with no approval step (an unknown name is refused before the pill's
        // approval is recorded since #811).
        let (_, pill) = try await turn(state, call("delete_skill", ["name": .string("no-such-skill-599")]), workspace: root)
        #expect(pill?.approval == .ungated)
        #expect(pill?.approval?.line == "No approval needed for this tool (nobody was asked).")
    }

    @Test("a denied call's pill gets no approval")
    func deniedHasNone() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try app(root)
        let target = IrisPaths.realPath(root.path) + "/denied.txt"
        let (_, pill) = try await turn(state, call("write_file", ["path": .string(target), "content": .string("x")]),
                                       workspace: root, answer: .deny)
        #expect(pill != nil)
        #expect(pill?.approval == nil)
    }

    @Test("the first record stands: a later one does not overwrite a person's approval")
    func firstRecordStands() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try app(root)
        let cid = state.createNewConversation(isBackground: false, select: false)
        let pill = UUID()
        state.appendMessage(role: .system, content: "[TOOL_CALL]\n{\"name\":\"register_directory_watcher\"}", id: pill, to: cid)
        state.setToolApproval(messageId: pill, in: cid, ToolApproval(.person))
        #expect(state.pendingChangeSet(for: cid)?.updatedMessageIds.contains(pill) == true,
                "queued as an in-place update, so the store's UPDATE path writes it")
        state.setToolApproval(messageId: pill, in: cid, .ungated)
        #expect(state.conversations.first { $0.id == cid }?.messages.first { $0.id == pill }?.approval?.layer == .person)
    }

    // MARK: persistence

    @Test("the approval round-trips through the store, on insert and on an in-place update")
    func persists() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "t", workspacePath: nil)
        let pill = ChatMessage(role: .system, content: "[TOOL_CALL]\n{\"name\":\"run_command\"}",
                               approval: ToolApproval(layer: .vibecop, detail: "routine"))
        let later = ChatMessage(role: .system, content: "[TOOL_CALL]\n{\"name\":\"write_file\"}")
        c.messages = [pill, later]
        var created = ChangeSet(); created.add(.created); created.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: created)])

        c.messages[1].approval = ToolApproval(layer: .allowlist, detail: "write_file /x", scope: "project")
        var updated = ChangeSet(); updated.add(.messageUpdated(id: later.id))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: updated)])

        let back = try #require(try store.loadAll().conversations.first)
        #expect(back.messages.map(\.approval) == c.messages.map(\.approval))
    }

    @Test("an old message without the key, and a layer from a newer build, both still decode")
    func decodesOldAndNew() throws {
        let old = #"{"id":"\#(UUID().uuidString)","role":"system","content":"[TOOL_CALL]\n{}"}"#
        let decodedOld = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        #expect(decodedOld.approval == nil)
        let newer = #"{"id":"\#(UUID().uuidString)","role":"system","content":"x","approval":{"layer":"quorum","detail":"d"}}"#
        let decodedNewer = try JSONDecoder().decode(ChatMessage.self, from: Data(newer.utf8))
        #expect(decodedNewer.approval?.layer == .unknown)
        #expect(decodedNewer.approval?.detail == "d")
    }

    @Test("a long or multi-line Vibecop reason is shown on one line, capped; export carries the line as code")
    func reasonIsShownPlainAndCapped() {
        let long = String(repeating: "a", count: 300) + "\nsecond line"
        let line = ToolApproval(layer: .vibecop, detail: long).line ?? ""
        #expect(!line.contains("\n"))
        #expect(line.count <= "Approved by Vibecop: ".count + ToolApproval.reasonLimit + 1)
        let message = ChatMessage(role: .system, content: "[TOOL_CALL]\n{}",
                                  approval: ToolApproval(layer: .vibecop, detail: "use `rm` safely"))
        let exported = message.exportLine(format: .markdown)
        #expect(exported.hasSuffix("\n`Approved by Vibecop: use 'rm' safely`"))
        #expect(message.exportLine(format: .plainText).hasSuffix("\nApproved by Vibecop: use `rm` safely"))
    }
}
