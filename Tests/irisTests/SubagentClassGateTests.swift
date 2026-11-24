import Testing
import Foundation
@testable import IrisKit

/// #1306: a subagent carries its parent turn's binding, capped, so a profile-bound session's subagent is not the owner
/// either. It used to be offered and to run owner-only tools (`set_workspace`, and MCP and plugin tools with the owner's
/// credentials and no approval step), because the class gate and the declaration strip asked only of `.main`. Driven
/// through the real `invoke_subagent` route from a conversation whose persisted `accessProfileId` names a real profile.
@MainActor
@Suite("a profile-bound session's subagent meets the class gate (#1306)", .serialized, .timeLimit(.minutes(2)))
struct SubagentClassGateTests {
    /// Answers each request by who asks (a subagent's system prompt names its role, as in `DelegatedSpendTests`), and
    /// records the tools each side was offered. The parent delegates once; the subagent forges `set_workspace` whether
    /// or not it was offered, then finishes.
    final class Client: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String: Int] = [:]
        private var offers: [String: [Set<String>]] = [:]
        let workspace: String
        let forged: String

        init(workspace: String, forged: String = "set_workspace") { self.workspace = workspace; self.forged = forged }

        func offered(_ who: String) -> [Set<String>] { lock.withLock { offers[who] ?? [] } }

        private static func reply(_ parts: [Part]) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: parts))], usageMetadata: nil)
        }

        private static func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
            reply([Part(functionCall: FunctionCall(name: name, args: args))])
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            let who = prompt.contains("subagent role: **") ? "subagent" : "parent"
            let n = lock.withLock { () -> Int in
                calls[who, default: 0] += 1
                offers[who, default: []].append(IrisEngine.offeredToolNames(request))
                return calls[who]!
            }
            switch (who, n) {
            case ("parent", 1):
                return Self.call("invoke_subagent", ["role": .string("worker"), "task": .string("Point the workspace."),
                                                     "effort": .string("easy")])
            case ("subagent", 1): return Self.call(forged, ["path": .string(workspace)])
            case ("subagent", 2): return Self.call("goal_complete", ["summary": .string("done")])
            default: return Self.reply([Part(text: "done")])
            }
        }
    }

    private struct World {
        let app: AppState
        let parent: UUID
        let root: URL
        let paths: IrisPaths
        let target: URL
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func world(profile: String?) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1306-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try #"{"memoryWrite":1}"#.write(to: paths.profilesDir.appendingPathComponent("narrow.json"), atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.autoApproveTools = true
        let parent = app.createNewConversation(title: "role session", select: true)
        if let profile, let i = app.conversations.firstIndex(where: { $0.id == parent }) { app.conversations[i].accessProfileId = profile }
        return World(app: app, parent: parent, root: root, paths: paths, target: target)
    }

    private func run(_ w: World, forging forged: String = "set_workspace") async throws
        -> (client: Client, child: Conversation?, results: [String]) {
        let client = Client(workspace: w.target.path, forged: forged)
        let engine = IrisEngine(state: w.app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0, memory: MemoryManager(paths: w.paths),
                                accessProfileStore: AccessProfileStore(paths: w.paths))
        w.app.installEngine(engine)
        try await value(of: Task { await engine.processInput("go", source: "UI", conversationId: w.parent) }, within: 60)
        let child = w.app.conversations.first { $0.isSubagent }
        let results = child?.history.flatMap(\.parts).compactMap(\.functionResponse)
            .filter { $0.name == forged }.compactMap { $0.response["result"]?.stringValue } ?? []
        return (client, child, results)
    }

    @Test("a profile-bound parent's subagent is not offered set_workspace, and its forged call is refused by the gate")
    func profileBoundSubagentIsGated() async throws {
        let w = try world(profile: "narrow"); defer { w.tearDown() }
        let (client, child, results) = try await run(w)
        let offered = try #require(client.offered("subagent").first, "the subagent ran")
        #expect(offered.contains("run_command"), "the subagent's turn did declare tools")
        #expect(!offered.contains("set_workspace"), "declaration: not offered on a non-owner binding")
        let result = try #require(results.first, "the subagent's set_workspace call got a result")
        #expect(result.contains(ToolClassTable.refusalLead(tool: "set_workspace")), "\(result)")
        #expect(result.contains("this turn is bound to profile `narrow`"), "names the parent session's profile: \(result)")
        #expect(child?.workspacePath != w.target.path, "nothing was re-pointed")
    }

    @Test("control: an owner parent's subagent is still offered set_workspace, and runs it")
    func ownerSubagentStillRuns() async throws {
        let w = try world(profile: nil); defer { w.tearDown() }
        let (client, child, results) = try await run(w)
        #expect(client.offered("subagent").first?.contains("set_workspace") == true)
        let result = try #require(results.first)
        #expect(!result.contains(ToolClassTable.refusalLead(tool: "set_workspace")), "\(result)")
        #expect(child?.workspacePath == w.target.path, "the owner's subagent set it: \(result)")
    }

    @Test("a subagent's call to a main-only tool keeps #811's not-offered wording, not the class gate's")
    func mainOnlyToolKeepsItsWording() async throws {
        let w = try world(profile: "narrow"); defer { w.tearDown() }
        // `list_sessions` is owner-only and main-only: never declared to a subagent, so #811 answers it as before.
        let (_, _, results) = try await run(w, forging: "list_sessions")
        let result = try #require(results.first)
        #expect(result == IrisEngine.notOfferedRefusal("list_sessions"), "\(result)")
    }

    // MARK: the gate's other two callers (intended side effects of widening it)

    private static func childOfProfile(_ w: World) -> AccessBinding {
        guard case .bound(let parent) = BindingResolver.resolveBinding(principal: .main, persistedProfileId: "narrow",
                                                                         store: AccessProfileStore(paths: w.paths)) else {
            preconditionFailure("the narrow profile resolves")
        }
        return SubagentManager.childBinding(ofParent: parent, principal: .subagent)!
    }

    private static let ownerChild = SubagentManager.childBinding(
        ofParent: AccessBinding(profile: .owner, principal: .main, isOwner: true), principal: .subagent)!

    private func subagentEngine(_ w: World, binding: AccessBinding) -> IrisEngine {
        IrisEngine(state: w.app, tier: .medium, principal: .subagent, client: FakeLLMClient(responses: []), protectionEnabled: false,
                   sessionPeerCount: 0, memory: MemoryManager(paths: w.paths), binding: binding,
                   accessProfileStore: AccessProfileStore(paths: w.paths))
    }

    /// A subagent delegated from the bound session, so the refusal can name the root's profile.
    private func boundChild(_ w: World) -> UUID {
        let child = UUID()
        w.app.createNewConversation(id: child, isSubagent: true)
        w.app.registerSubagent(id: child, role: "worker", owner: w.parent)
        return child
    }

    @Test("approved-card replay: a non-owner subagent's owner-only card is refused by the gate; an owner subagent's is not")
    func approvedCardReplay() async throws {
        let w = try world(profile: "narrow"); defer { w.tearDown() }
        let child = boundChild(w)
        let call = BlockedCall(toolName: "srv___echo", args: [:], cwd: nil)
        let refused = await subagentEngine(w, binding: Self.childOfProfile(w)).executeApprovedCall(call, conversationId: child)
        #expect(refused.contains(ToolClassTable.refusalLead(tool: "srv___echo")), "\(refused)")
        #expect(refused.contains("this turn is bound to profile `narrow`"), "\(refused)")
        let owner = try world(profile: nil); defer { owner.tearDown() }
        let ownerChild = UUID()
        owner.app.createNewConversation(id: ownerChild, isSubagent: true)
        let allowed = await subagentEngine(owner, binding: Self.ownerChild).executeApprovedCall(call, conversationId: ownerChild)
        #expect(!allowed.contains(ToolClassTable.refusalLead(tool: "srv___echo")), "\(allowed)")
    }

    @Test("held-write release: a non-owner subagent's owner-only release is refused by the gate; an owner subagent's is not")
    func heldWriteRelease() async throws {
        let w = try world(profile: "narrow"); defer { w.tearDown() }
        let child = boundChild(w)
        func item(_ id: UUID) -> PendingContextWrite {
            PendingContextWrite(id: UUID(), conversationId: id, toolName: "set_workspace", args: [:], firstLine: "",
                                createdAt: Date(), state: .pending)
        }
        let refused = await subagentEngine(w, binding: Self.childOfProfile(w)).applyHeldWrite(item(child))
        #expect(refused.contains(ToolClassTable.refusalLead(tool: "set_workspace")), "\(refused)")
        let owner = try world(profile: nil); defer { owner.tearDown() }
        let ownerChild = UUID()
        owner.app.createNewConversation(id: ownerChild, isSubagent: true)
        let allowed = await subagentEngine(owner, binding: Self.ownerChild).applyHeldWrite(item(ownerChild))
        #expect(!allowed.contains(ToolClassTable.refusalLead(tool: "set_workspace")), "\(allowed)")
    }

    @Test("hardStrip: a guest is never stripped by binding, so its own list_sessions stays (#1015's regression)")
    func guestFloorUnchanged() {
        let list = GuestToolset.listSessions, send = GuestToolset.sendToSession
        #expect(IrisEngine.hardStrip([list, send], isUnattended: false, principal: .mcpGuest).map(\.name) == [list.name, send.name])
    }
}
