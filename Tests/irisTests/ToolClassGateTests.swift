import Testing
import Foundation
@testable import IrisKit

/// #974 gap A (#1015): the tool class table and its one gate. Every route a tool call can take is driven
/// through its real entry, and each asserts the gate's own text (`nonOwnerToolRefusal`), not a bare
/// "refused": a not-offered refusal (#811) reads like a gate refusal.
@Suite("every declared tool has a class (#974 gap A)")
struct ToolClassTableTests {
    @Test("every declared tool has a row, and no row names a tool nothing declares")
    func tableIsComplete() {
        let universe = IrisEngine.allDeclaredToolNames.union(ToolExecutor.githubProxyTools)
        #expect(universe.subtracting(ToolClassTable.classes.keys).isEmpty,
                "classify these in ToolClassTable: \(universe.subtracting(ToolClassTable.classes.keys).sorted())")
        #expect(Set(ToolClassTable.classes.keys).subtracting(universe).isEmpty,
                "stale rows: \(Set(ToolClassTable.classes.keys).subtracting(universe).sorted())")
    }

    @Test("a name the repo does not declare (an MCP server's, a plugin's) is owner-only")
    func unknownIsOwnerOnly() {
        for name in ["github___create_issue", "plugin_x___run", "not_a_tool"] {
            #expect(ToolClassTable.toolClass(of: name) == .ownerOnly, Comment(rawValue: name))
        }
    }

    @Test("the classes the rulings name")
    func rulings() {
        for name in ["set_workspace", "gmail_send_email", "list_sessions", "schedule_job", "list_jobs", "github_approve"] {
            #expect(ToolClassTable.toolClass(of: name) == .ownerOnly, Comment(rawValue: name))
        }
        #expect(ToolClassTable.toolClass(of: "run_command") == .approvalGated, "Brian: run_command stays approval-gated")
        for name in ToolExecutor.memoryTools { #expect(ToolClassTable.toolClass(of: name) == .tierGated, Comment(rawValue: name)) }
    }

    @Test("the gate refuses owner-only on a non-owner binding and never on the owner's")
    func gate() {
        let guest = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false)
        let owner = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        #expect(ToolClassTable.refusal(tool: "srv___echo", binding: guest) == IrisEngine.nonOwnerToolRefusal)
        #expect(ToolClassTable.refusal(tool: "srv___echo", binding: owner) == nil)
        #expect(ToolClassTable.refusal(tool: "run_command", binding: guest) == nil, "left to the approval ladder")
        #expect(ToolClassTable.refusal(tool: "search_memory", binding: guest) == nil, "left to MemoryBindingGate")
    }
}

@MainActor
@Suite("the class gate on every route (#974 gap A)", .serialized, .timeLimit(.minutes(3)))
struct ToolClassGateRouteTests {
    nonisolated static let tools = ["gmail_list_unread", "set_workspace", "srv___echo", "list_jobs", "schedule_job", "register_directory_watcher"]

    private struct World {
        let app: AppState
        let id: UUID
        let root: URL
        let paths: IrisPaths
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func world(profile: String? = nil) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gapa-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try #"{"memoryWrite":1}"#.write(to: paths.profilesDir.appendingPathComponent("narrow.json"), atomically: true, encoding: .utf8)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(title: "role session", select: true)
        if let profile, let idx = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[idx].accessProfileId = profile }
        return World(app: app, id: id, root: root, paths: paths)
    }

    private func steer(_ w: World) {
        w.app.markGuestOriginTurn(w.id)
        let guest = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
        w.app.markGuestSteeredBinding(guest, for: w.id)
    }

    private func engine(_ w: World, _ client: any LLMClientProtocol) -> IrisEngine {
        let e = IrisEngine(state: w.app, tier: .medium, principal: .main, client: client, retryDelays: [], protectionEnabled: false,
                           sessionPeerCount: 1, memory: MemoryManager(paths: w.paths), accessProfileStore: AccessProfileStore(paths: w.paths))
        w.app.installEngine(e)
        return e
    }

    /// A forged call through a real `processInput` turn; returns the tool result the model got back.
    private func forged(_ name: String, _ w: World) async throws -> String {
        let part = Part(text: nil, functionCall: FunctionCall(name: name, args: ["path": .string("/tmp")], id: "c1"), functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ])
        let e = engine(w, client)
        let turn = Task { await e.processInput("go", source: "UI", conversationId: w.id) }
        let denier = Task {
            while !Task.isCancelled {
                if !w.app.pendingApprovals.isEmpty { w.app.denyPendingApprovals(for: w.id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turn)
        denier.cancel()
        return (w.app.conversations.first { $0.id == w.id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse }
            .compactMap { $0.response["result"]?.stringValue } ?? []).joined(separator: " | ")
    }

    private func offered(_ w: World) async -> Set<String> {
        let client = CapturingLLMClient(reply: "ok")
        await engine(w, client).processInput("hello", source: "UI", conversationId: w.id)
        return IrisEngine.offeredToolNames(client.requests[0])
    }

    // MARK: dispatch

    @Test("live dispatch: a guest-steered turn's call to each owner-only tool is refused by the gate", arguments: ToolClassGateRouteTests.tools)
    func steeredDispatch(_ name: String) async throws {
        let w = try world(); defer { w.tearDown() }
        steer(w)
        let r = try await forged(name, w)
        #expect(r.contains(IrisEngine.nonOwnerToolRefusal), "\(name): \(r)")
    }

    @Test("live dispatch: a session bound to a non-owner profile meets the same gate", arguments: ToolClassGateRouteTests.tools)
    func profileBoundDispatch(_ name: String) async throws {
        let w = try world(profile: "narrow"); defer { w.tearDown() }
        let r = try await forged(name, w)
        #expect(r.contains(IrisEngine.nonOwnerToolRefusal), "\(name): \(r)")
    }

    @Test("control: the owner's own turn is not refused by the gate", arguments: ToolClassGateRouteTests.tools)
    func ownerDispatch(_ name: String) async throws {
        let w = try world(); defer { w.tearDown() }
        let r = try await forged(name, w)
        #expect(!r.contains(IrisEngine.nonOwnerToolRefusal), "\(name): \(r)")
    }

    // MARK: declaration

    @Test("declaration: a guest-steered turn and a profile-bound turn are not offered set_workspace; the owner is")
    func declaration() async throws {
        let owner = try world(); defer { owner.tearDown() }
        let ownerOffered = await offered(owner)
        #expect(ownerOffered.contains("set_workspace"), "control: the owner's turn declares it")
        let steered = try world(); defer { steered.tearDown() }
        steer(steered)
        let steeredOffered = await offered(steered)
        #expect(!steeredOffered.contains("set_workspace"))
        #expect(steeredOffered.contains("run_command"), "the turn did declare tools")
        let bound = try world(profile: "narrow"); defer { bound.tearDown() }
        let boundOffered = await offered(bound)
        #expect(!boundOffered.contains("set_workspace"))
        #expect(boundOffered.contains("run_command"), "the turn did declare tools")
    }

    @Test("hardStrip: a non-owner turn drops an MCP tool the table has no row for; an owner turn keeps it")
    func stripDropsUnknown() {
        let mcp = FunctionDeclaration(name: "srv___echo", description: "x", parameters: Schema(type: "OBJECT", properties: [:], required: []))
        let run = FunctionDeclaration(name: "run_command", description: "x", parameters: Schema(type: "OBJECT", properties: [:], required: []))
        let kept = IrisEngine.hardStrip([mcp, run], isUnattended: false, principal: .main).map(\.name)
        let stripped = IrisEngine.hardStrip([mcp, run], isUnattended: false, principal: .main, nonOwner: true).map(\.name)
        #expect(kept == ["srv___echo", "run_command"])
        #expect(stripped == ["run_command"])
    }

    // MARK: approved-card replay

    private struct Replay {
        let w: World
        let store: ConversationStore
        let runner: JobRunner
        let engine: IrisEngine   // the runner holds the engine weakly
        let teardown: () -> Void
    }

    private func replay() throws -> Replay {
        let w = try world()
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []), protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: w.paths), accessProfileStore: AccessProfileStore(paths: w.paths))
        let name = "iris-gapa-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               now: { Date(timeIntervalSince1970: 1_700_000_000) }, config: ConfigManager(store: defaults),
                               sandboxAvailable: { true })
        // The runner holds the state weakly: keep it alive with the replay.
        return Replay(w: World(app: state, id: w.id, root: w.root, paths: w.paths), store: store, runner: runner, engine: engine, teardown: {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
            w.tearDown()
        })
    }

    private func blocked(_ r: Replay, tool: String, accessProfileId: String?) throws -> JobRun {
        let job = Job(name: "j-\(UUID().uuidString)", prompt: "x", trigger: .schedule(.interval(seconds: 60)), profile: .mutating, accessProfileId: accessProfileId)
        try r.store.ledger.upsert(job)
        let call = BlockedCall(toolName: tool, args: ["to": .string("a@b.c"), "subject": .string("s"), "body": .string("b")], cwd: nil)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try r.store.ledger.begin(run: run)
        try r.store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil, failureReason: "needs approval: \(tool)",
                                  blockedTool: tool, tokens: TokenUsage(), finishedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try r.store.ledger.setBlockedCall(runId: run.id, call)
        return try #require(try r.store.ledger.run(id: run.id))
    }

    private func outcome(_ r: Replay, tool: String, accessProfileId: String?) async throws -> String? {
        let run = try blocked(r, tool: tool, accessProfileId: accessProfileId)
        let result = await r.runner.runApproved(runId: run.id)
        guard case .dispatched(let approvedId) = result else { return "NOT DISPATCHED: \(result)" }
        return try r.store.ledger.run(id: approvedId)?.outcome
    }

    @Test("approved card: an owner-only card clicked under a non-owner profile is refused by the gate; the owner's is not")
    func approvedCardReplay() async throws {
        let r = try replay(); defer { r.teardown() }
        let refused = try await outcome(r, tool: "gmail_send_email", accessProfileId: "narrow")
        // The ledger keeps the first 200 characters of an outcome.
        let gateText = String(IrisEngine.nonOwnerToolRefusal.prefix(100))
        #expect(refused?.hasPrefix(gateText) == true, "\(String(describing: refused))")
        let control = try await outcome(r, tool: "gmail_send_email", accessProfileId: nil)
        #expect(control?.hasPrefix(gateText) != true, "control: the unstamped (owner) job's card is not refused by the gate")
    }

    // MARK: held write

    @Test("held write: the release of an item naming an owner-only tool is refused by the gate under a non-owner binding")
    func heldWriteRelease() async throws {
        let w = try world(); defer { w.tearDown() }
        steer(w)
        let e = engine(w, FakeLLMClient(responses: []))
        // The release dispatches with the item's tool as the one offered, so a refusal here is the gate's, not "not offered".
        let item = PendingContextWrite(id: UUID(), conversationId: w.id, toolName: "gmail_send_email", args: [:],
                                       firstLine: "", createdAt: Date(), state: .pending)
        let released = await e.applyHeldWrite(item)
        #expect(released.contains(IrisEngine.nonOwnerToolRefusal), Comment(rawValue: released))
    }
}
