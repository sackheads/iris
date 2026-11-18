import Testing
import Foundation
@testable import IrisKit

/// #1195: a turn a guest's message started or steered is attended `.main`, but its words are a guest's.
/// The memory tools read the owner's facts and every other conversation with no approval step, and
/// write standing context, so that turn is not offered them (`hardStrip`), a call that arrives anyway
/// is refused at the dispatcher. One list drives the code and these tests: `ToolExecutor.memoryTools`.
@MainActor
@Suite("A turn a guest's message started has no memory tools (#1195)", .timeLimit(.minutes(1)))
struct GuestOriginMemoryTests {
    nonisolated static let reads = ["search_memory", "search_conversations", "read_conversation"]
    nonisolated static let writes = ["save_fact", "manage_fact", "update_memory", "update_user_profile", "update_soul",
                         "create_skill", "update_skill", "delete_skill"]
    nonisolated static let google = ["gmail_list_unread", "gmail_send_email", "google_calendar_list_events",
                                     "google_calendar_create_event", "google_docs_get", "google_drive_search",
                                     "google_sheets_get", "google_tasks_list_tasklists", "google_tasks_list_tasks",
                                     "google_tasks_create_task"]
    nonisolated static let jobReads = ["list_jobs", "get_job_run"]
    nonisolated static let memory = reads + writes
    /// Everything a guest-origin turn is neither offered nor allowed to run.
    nonisolated static let all = memory + google + jobReads

    // MARK: the one list

    @Test("the sets are exactly these names: a tool added or dropped fails here and is decided on purpose")
    func setIsComplete() {
        #expect(ToolExecutor.memoryReadTools == Set(Self.reads))
        #expect(ToolExecutor.memoryWriteTools == Set(Self.writes))
        #expect(ToolExecutor.memoryTools == Set(Self.memory))
        #expect(ToolExecutor.googleWorkspaceTools == Set(Self.google))
        #expect(ToolExecutor.ownerJobReadTools == Set(Self.jobReads))
        #expect(ToolExecutor.guestOriginDeniedTools == Set(Self.all))
        #expect(!ToolExecutor.guestOriginDeniedTools.isEmpty)
        #expect(ToolExecutor.memoryReadTools.isDisjoint(with: ToolExecutor.memoryWriteTools))
    }

    @Test("every Google tool the managers declare is in the set, so a new Google tool cannot be forgotten")
    func googleToolsAreAllCovered() async {
        let declared = Set((await GoogleTasksManager.shared.getTools() + GoogleWorkspaceManager.shared.getTools()).map(\.name))
        #expect(!declared.isEmpty)
        #expect(declared.isSubset(of: ToolExecutor.googleWorkspaceTools),
                "\(declared.subtracting(ToolExecutor.googleWorkspaceTools).sorted())")
        #expect(ToolExecutor.googleWorkspaceTools.isSubset(of: declared),
                "\(ToolExecutor.googleWorkspaceTools.subtracting(declared).sorted())")
    }

    @Test("every job read the pinned conversation is offered is in the set")
    func jobReadsAreAllCovered() {
        let declared = Set(IrisEngine.jobToolDeclarations(isPinned: true).map(\.name))
        for name in ["list_jobs", "get_job_run", "search_conversations", "read_conversation"] { #expect(declared.contains(name), Comment(rawValue: name)) }
        #expect(ToolExecutor.ownerJobReadTools.isSubset(of: declared))
    }

    @Test("every standing-context write the hold covers (#813) is in the set, so a new held tool cannot be forgotten")
    func heldWritesAreStripped() {
        #expect(ContextHolds.heldTools.isSubset(of: ToolExecutor.memoryWriteTools),
                "\(ContextHolds.heldTools.subtracting(ToolExecutor.memoryWriteTools).sorted())")
    }

    @Test("every name in the set is a tool the app really declares: a typo would strip nothing")
    func namesAreRealTools() {
        let declared = IrisEngine.allDeclaredToolNames
            .union(IrisEngine.jobToolDeclarations(isPinned: true).map(\.name))
            .union(["create_skill", "update_skill", "delete_skill"])
            .union(ToolExecutor.googleWorkspaceTools)
        #expect(ToolExecutor.guestOriginDeniedTools.isSubset(of: declared), "\(ToolExecutor.guestOriginDeniedTools.subtracting(declared).sorted())")
    }

    @Test("reflect stays out: its handler returns a fixed line and stores nothing")
    func reflectIsInert() {
        #expect(!ToolExecutor.memoryTools.contains("reflect"))
    }

    // MARK: declaration

    private func declarations(_ names: [String]) -> [FunctionDeclaration] {
        (names + ["run_command", "read_file"]).map {
            FunctionDeclaration(name: $0, description: "", parameters: Schema(type: "OBJECT", properties: [:], required: []))
        }
    }

    @Test("hardStrip drops each owner-data tool on a guest-origin turn, and keeps it on any other", arguments: GuestOriginMemoryTests.all)
    func hardStripByTool(_ name: String) {
        let tools = declarations([name])
        let stripped = Set(IrisEngine.hardStrip(tools, isUnattended: false, principal: .main, guestOrigin: true).map(\.name))
        #expect(!stripped.contains(name))
        #expect(stripped.isSuperset(of: ["run_command", "read_file"]), "only the memory tools go")
        let kept = Set(IrisEngine.hardStrip(tools, isUnattended: false, principal: .main).map(\.name))
        #expect(kept.contains(name))
    }

    @Test("hardStrip strips the whole set at once")
    func hardStripWholeSet() {
        let stripped = Set(IrisEngine.hardStrip(declarations(Array(ToolExecutor.guestOriginDeniedTools)), isUnattended: false,
                                                principal: .main, guestOrigin: true).map(\.name))
        #expect(stripped.isDisjoint(with: ToolExecutor.guestOriginDeniedTools))
    }

    /// The tool names a real turn declares to the model.
    private func declared(guestOrigin: Bool, pinned: Bool) async -> Set<String> {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        if pinned, let idx = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[idx].isPinned = true }
        if guestOrigin { app.markGuestOriginTurn(id) }
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return Set(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    }

    @Test("a real attended turn offers the owner-data tools; the same turn a guest started offers none of them",
          arguments: [false, true])
    func realTurnDeclaration(_ pinned: Bool) async {
        let control = await declared(guestOrigin: false, pinned: pinned)
        let guest = await declared(guestOrigin: true, pinned: pinned)
        let offered = control.intersection(ToolExecutor.guestOriginDeniedTools)
        // The control must actually offer them, or "none offered" proves nothing.
        // `manage_fact` is declared only once the fact store has something to manage, so a fresh turn does
        // not offer it; it is covered by the pure strip and dispatch tests above and below.
        #expect(offered.isSuperset(of: Set(Self.writes).subtracting(["manage_fact"]).union(["search_memory"])), "\(offered.sorted())")
        if pinned {
            #expect(offered.isSuperset(of: ["search_conversations", "read_conversation", "list_jobs", "get_job_run"]), "\(offered.sorted())")
        }
        #expect(guest.intersection(ToolExecutor.guestOriginDeniedTools).isEmpty,
                "\(guest.intersection(ToolExecutor.guestOriginDeniedTools).sorted())")
        #expect(guest.contains("run_command"), "the guest-origin turn did declare tools")
    }

    @Test("the Google tools, which a real turn offers only with an account connected, are stripped from a guest-origin turn")
    func googleToolsAreStripped() async {
        let all = await ToolExecutor().getTools(workspaceToolsEnabled: true, githubToolsEnabled: false)
        let kept = Set(IrisEngine.hardStrip(all, isUnattended: false, principal: .main).map(\.name))
        let stripped = Set(IrisEngine.hardStrip(all, isUnattended: false, principal: .main, guestOrigin: true).map(\.name))
        #expect(kept.isSuperset(of: ToolExecutor.googleWorkspaceTools), "control: an ordinary turn offers them")
        #expect(stripped.isDisjoint(with: ToolExecutor.googleWorkspaceTools))
        #expect(stripped.contains("run_command"))
    }

    // MARK: dispatch

    @Test("the dispatcher refuses each memory tool on a guest-origin turn, and no other tool", arguments: GuestOriginMemoryTests.all)
    func dispatchRefusalByTool(_ name: String) {
        #expect(IrisEngine.guestOriginDispatchRefusal(name, guestOrigin: true) == IrisEngine.guestOriginDataRefusal)
        #expect(IrisEngine.guestOriginDispatchRefusal(name, guestOrigin: false) == nil)
        #expect(IrisEngine.guestOriginDispatchRefusal("run_command", guestOrigin: true) == nil)
        #expect(IrisEngine.guestOriginDispatchRefusal("reflect", guestOrigin: true) == nil)
    }

    enum Origin { case none, conversation, delegationRoot }

    /// One turn where the model calls `name`, returning what the dispatcher gave it.
    private func dispatchResult(for name: String, origin: Origin) async throws -> String {
        let app = AppState()
        app.conversations.removeAll()
        var id = UUID()
        app.createNewConversation(id: id)
        switch origin {
        case .none: break
        case .conversation: app.markGuestOriginTurn(id)
        case .delegationRoot:
            let root = id
            id = UUID()
            app.createNewConversation(id: id)
            app.linkDelegate(id, of: root)
            app.markGuestOriginTurn(root)
        }
        let call = FunctionCall(name: name, args: ["query": .string("anything"), "content": .string("x"), "id": .string("1"),
                                                   "action": .string("list"), "name": .string("s")])
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))], usageMetadata: nil),
        ])
        // Its own stores, so a control call that really writes touches nothing shared.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1195-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], factStore: try FactStoreManager(inMemory: true), protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: IrisPaths(root: root)))
        let turnTask = Task { await engine.processInput("go", source: "UI", conversationId: id) }
        let denyTask = Task {
            while !Task.isCancelled {
                if !app.pendingApprovals.isEmpty { app.denyPendingApprovals(for: id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turnTask)
        denyTask.cancel()
        let responses = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse } ?? []
        return responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n")
    }

    @Test("a forged call to each memory tool from a guest-origin turn is refused, itself or through its delegation root",
          arguments: GuestOriginMemoryTests.all, [Origin.conversation, .delegationRoot])
    func forgedCallRefused(_ name: String, _ origin: Origin) async throws {
        let result = try await dispatchResult(for: name, origin: origin)
        #expect(result.contains(IrisEngine.guestOriginDataRefusal), "\(name): \(result)")
    }

    @Test("control: the same call from an unmarked attended turn is not refused as guest-origin", arguments: GuestOriginMemoryTests.all)
    func unmarkedTurnIsNotRefused(_ name: String) async throws {
        let result = try await dispatchResult(for: name, origin: .none)
        #expect(!result.contains(IrisEngine.guestOriginDataRefusal), "\(name): \(result)")
    }
}
