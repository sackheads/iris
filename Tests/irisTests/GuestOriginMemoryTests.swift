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
    nonisolated static let all = reads + writes

    // MARK: the one list

    @Test("the set is exactly these eleven names: a tool added or dropped fails here and is decided on purpose")
    func setIsComplete() {
        #expect(ToolExecutor.memoryReadTools == Set(Self.reads))
        #expect(ToolExecutor.memoryWriteTools == Set(Self.writes))
        #expect(ToolExecutor.memoryTools == Set(Self.all))
        #expect(!ToolExecutor.memoryTools.isEmpty)
        #expect(ToolExecutor.memoryReadTools.isDisjoint(with: ToolExecutor.memoryWriteTools))
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
        #expect(ToolExecutor.memoryTools.isSubset(of: declared), "\(ToolExecutor.memoryTools.subtracting(declared).sorted())")
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

    @Test("hardStrip drops each memory tool on a guest-origin turn, and keeps it on any other", arguments: GuestOriginMemoryTests.all)
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
        let stripped = Set(IrisEngine.hardStrip(declarations(Array(ToolExecutor.memoryTools)), isUnattended: false,
                                                principal: .main, guestOrigin: true).map(\.name))
        #expect(stripped.isDisjoint(with: ToolExecutor.memoryTools))
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

    @Test("a real attended turn offers the memory tools; the same turn a guest started offers none of them",
          arguments: [false, true])
    func realTurnDeclaration(_ pinned: Bool) async {
        let control = await declared(guestOrigin: false, pinned: pinned)
        let guest = await declared(guestOrigin: true, pinned: pinned)
        let offered = control.intersection(ToolExecutor.memoryTools)
        // The control must actually offer them, or "none offered" proves nothing.
        // `manage_fact` is declared only once the fact store has something to manage, so a fresh turn does
        // not offer it; it is covered by the pure strip and dispatch tests above and below.
        #expect(offered.isSuperset(of: Set(Self.writes).subtracting(["manage_fact"]).union(["search_memory"])), "\(offered.sorted())")
        if pinned { #expect(offered.isSuperset(of: ["search_conversations", "read_conversation"]), "\(offered.sorted())") }
        #expect(guest.intersection(ToolExecutor.memoryTools).isEmpty, "\(guest.intersection(ToolExecutor.memoryTools).sorted())")
        #expect(guest.contains("run_command"), "the guest-origin turn did declare tools")
    }

    // MARK: dispatch

    @Test("the dispatcher refuses each memory tool on a guest-origin turn, and no other tool", arguments: GuestOriginMemoryTests.all)
    func dispatchRefusalByTool(_ name: String) {
        #expect(IrisEngine.memoryDispatchRefusal(name, guestOrigin: true) == IrisEngine.memoryGuestOriginRefusal)
        #expect(IrisEngine.memoryDispatchRefusal(name, guestOrigin: false) == nil)
        #expect(IrisEngine.memoryDispatchRefusal("run_command", guestOrigin: true) == nil)
        #expect(IrisEngine.memoryDispatchRefusal("reflect", guestOrigin: true) == nil)
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
        #expect(result.contains(IrisEngine.memoryGuestOriginRefusal), "\(name): \(result)")
    }

    @Test("control: the same call from an unmarked attended turn is not refused as guest-origin", arguments: GuestOriginMemoryTests.all)
    func unmarkedTurnIsNotRefused(_ name: String) async throws {
        let result = try await dispatchResult(for: name, origin: .none)
        #expect(!result.contains(IrisEngine.memoryGuestOriginRefusal), "\(name): \(result)")
    }
}
