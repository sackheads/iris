import Foundation
import Testing
@testable import IrisKit

/// #465 part 2: a profile's `tools:` list narrows what a conversation is offered and what it may
/// call. Files go in a temp home of the test's own (Invariant 7).
@MainActor
@Suite("Agent profile tools (#465)", .timeLimit(.minutes(1)))
struct AgentProfileToolsTests {
    private final class ScriptedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [GeminiRequest] = []
        private let responses: [GeminiResponse]
        init(_ responses: [GeminiResponse]) { self.responses = responses }
        var requests: [GeminiRequest] { lock.withLock { sent } }
        var declared: [Set<String>] { requests.map { Set($0.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []) } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                sent.append(request)
                return responses[min(sent.count - 1, responses.count - 1)]
            }
        }
    }

    nonisolated private static func reply(_ part: Part) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    nonisolated private static let narrowFile = """
    ---
    role: reviewer
    tools: [read_file, mcp:github]
    ---
    You review.
    """

    private func setUp(_ text: String = Self.narrowFile) throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-465b-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        let store = AgentProfileStore(paths: paths)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.directory.appendingPathComponent("reviewer.md"))
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = store
        return (app, root)
    }

    /// Denies every approval as it is asked, so a call the profile failed to refuse ends at once
    /// with the human-denial result instead of waiting out the time limit.
    private func denyApprovals(_ app: AppState) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for pending in app.pendingApprovals { app.resolveApproval(id: pending.id, .deny) }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    /// Holds the reflection's model call until released, so a turn can run beside it.
    private final class HeldReflectionClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(text: String, names: Set<String>)] = []
        private var released = false
        var requests: [(text: String, names: Set<String>)] { lock.withLock { sent } }
        func release() { lock.withLock { released = true } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let text = request.contents.last?.parts.compactMap(\.text).joined() ?? ""
            let names = Set(request.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
            lock.withLock { sent.append((text, names)) }
            let isReflection = text.contains("Reflection Trigger")
            while isReflection, !lock.withLock({ released }) { try await Task.sleep(nanoseconds: 5_000_000) }
            // AppState.noConsolidationReply's text: that constant is main-actor isolated.
            return AgentProfileToolsTests.reply(Part(text: isReflection ? "No memory consolidation needed at this time." : "ok"))
        }
    }

    private func profile(_ tools: [String]?) -> AgentProfile {
        AgentProfile(name: "p", role: nil, tier: nil, skills: nil, tools: tools, prompt: "x", contentHash: "h")
    }

    private func lastToolResult(_ app: AppState, _ id: UUID) -> String {
        let history = app.conversations.first { $0.id == id }?.history ?? []
        return history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
    }

    // MARK: The rule

    @Test("a list offers its names, a named MCP server's tools, and the flow tools; no list offers all")
    func allowsTool() {
        let narrow = profile(["read_file", "mcp:github"])
        #expect(narrow.allowsTool("read_file"))
        #expect(!narrow.allowsTool("write_file"))
        #expect(narrow.allowsTool("github" + JobProfile.mcpNameSeparator + "list_prs"))
        #expect(!narrow.allowsTool("slack" + JobProfile.mcpNameSeparator + "post"))
        #expect(narrow.allowsTool("goal_complete"))
        #expect(!narrow.allowsTool("send_to_session"), "not a flow tool: a profile without it can't message peers")
        #expect(profile(nil).allowsTool("write_file"))
        #expect(!profile([]).allowsTool("read_file"), "an empty list is a list")
    }

    /// The planner's ruling: every state-gated tool is classified on purpose, so a new one fails
    /// here until someone decides whether a profile narrows it.
    @Test("every sticky (state-gated) tool is classified as exempt or narrowed")
    func stickyClassified() {
        let exempt: Set<String> = ["goal_complete", "amend_goal_contract", "reach_checkpoint", "delegate_milestone", "waive_criterion",
                                   IrisEngine.scheduleNextTickTool]
        let narrowed: Set<String> = ["manage_fact", "list_sessions", "describe_session", "send_to_session", "set_session_card", "close_request"]
        #expect(exempt.union(narrowed) == StickyTools.eligible, "classify the new state-gated tool")
        for name in StickyTools.eligible {
            #expect(AgentProfile.flowTools.contains(name) == exempt.contains(name), "\(name)")
        }
        #expect(AgentProfile.flowTools == exempt.union(["propose_goal_contract", "rename_conversation"]))
    }

    @Test("the reflection exemption is exactly the tools the reflection prompts name")
    func reflectionToolsMatchPrompts() {
        func named(_ prompt: String) -> Set<String> {
            let pattern = /`([a-z]+(?:_[a-z]+)+)`/
            return Set(prompt.matches(of: pattern).map { String($0.output.1) })
        }
        #expect(named(AppState.reflectionPrompt) == AppState.reflectionTools)
        // `/reflect` names `write_file` only to say not to use it.
        #expect(named(AppState.manualReflectionPrompt).subtracting(["write_file"]) == AppState.reflectionTools)
    }

    @Test("narrowing only removes: a reflection turn never gets back what a strip took out")
    func narrowOnlyRemoves() {
        let tools = ["read_file", "write_file", "update_memory"].map {
            FunctionDeclaration(name: $0, description: "", parameters: Schema(type: "OBJECT", properties: [:]))
        }
        let reflecting = AgentToolScope(profile: profile(["read_file"]), reflecting: true)
        #expect(reflecting.narrow(tools).map(\.name) == ["read_file", "update_memory"])
        let stripped = tools.filter { $0.name != "update_memory" }
        #expect(reflecting.narrow(stripped).map(\.name) == ["read_file"])
        #expect(AgentToolScope(profile: profile(["read_file"]), reflecting: false).narrow(tools).map(\.name) == ["read_file"])
    }

    // MARK: A turn

    @Test("a profiled conversation is offered only its list and the flow tools; a plain one is unchanged")
    func declaredNarrowed() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let profiled = app.createNewConversation(select: false, agentProfile: "reviewer")
        let plain = app.createNewConversation(select: false)
        let client = ScriptedClient([Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hi", source: "UI", conversationId: profiled)
        await engine.processInput("hi", source: "UI", conversationId: plain)
        let (narrow, wide) = (client.declared[0], client.declared[1])
        #expect(narrow.contains("read_file"))
        #expect(!narrow.contains("write_file") && !narrow.contains("run_command") && !narrow.contains("update_memory"))
        #expect(narrow.allSatisfy { AgentProfile.flowTools.contains($0) || $0 == "read_file" }, "\(narrow)")
        #expect(wide.contains("write_file") && wide.contains("run_command") && wide.contains("update_memory"))
    }

    @Test("a call outside the list is refused at dispatch, and the refusal names the profile")
    func dispatchRefused() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let call = FunctionCall(name: "write_file", args: ["path": .string(root.appendingPathComponent("x").path), "content": .string("x")])
        let client = ScriptedClient([Self.reply(Part(functionCall: call)), Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let denier = denyApprovals(app); defer { denier.cancel() }
        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(lastToolResult(app, id) == IrisEngine.agentProfileDeniedToolResult(tool: "write_file", profile: "reviewer"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
    }

    @Test("a memory reflection in a narrowed conversation is still offered the tools its prompt names")
    func reflectionKeepsMemoryTools() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let client = ScriptedClient([Self.reply(Part(text: AppState.noConsolidationReply))])
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        await app.runReflection(AppState.reflectionPrompt, in: id, moveReplyToIris: false)
        await engine.processInput("and now", source: "UI", conversationId: id)
        let (reflection, next) = (client.declared[0], client.declared[1])
        #expect(AppState.reflectionTools.isSubset(of: reflection), "\(reflection)")
        #expect(!reflection.contains("write_file"), "only the prompt's tools come back")
        #expect(AppState.reflectionTools.isDisjoint(with: next), "the next turn is narrowed again")
    }

    @Test("a turn running beside a reflection is narrowed as usual; only the reflection's own turn is exempt")
    func besideReflection() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let client = HeldReflectionClient()
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        let reflection = Task { await app.runReflection(AppState.reflectionPrompt, in: id, moveReplyToIris: false) }
        for _ in 0..<1000 where client.requests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try #require(client.requests.count == 1, "the reflection's call is held")
        await engine.processInput("beside", source: "UI", conversationId: id)
        client.release()
        _ = try await value(of: reflection)
        let held = try #require(client.requests.first { $0.text.contains("Reflection Trigger") })
        let beside = try #require(client.requests.first { $0.text.contains("beside") })
        #expect(AppState.reflectionTools.isSubset(of: held.names))
        #expect(AppState.reflectionTools.isDisjoint(with: beside.names), "\(beside.names)")
    }

    @Test("the reflection text alone, typed as a message, is no reflection turn")
    func reflectionTextIsNotTheSignal() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let client = ScriptedClient([Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput(AppState.reflectionPrompt, source: "System", conversationId: id)
        #expect(AppState.reflectionTools.isDisjoint(with: client.declared[0]))
    }

    @Test("a subagent working for a profiled conversation is narrowed too, at any depth; its call is refused")
    func subagentInherits() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = app.createNewConversation(select: false, agentProfile: "reviewer")
        let child = app.createNewConversation(isSubagent: true, select: false)
        let grandchild = app.createNewConversation(isSubagent: true, select: false)
        app.linkDelegate(child, of: parent)
        app.linkDelegate(grandchild, of: child)
        let call = FunctionCall(name: "run_command", args: ["command": .string("true")])
        let client = ScriptedClient([Self.reply(Part(functionCall: call)), Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, principal: .subagent, roleLabel: "helper", client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let denier = denyApprovals(app); defer { denier.cancel() }
        await engine.processInput("go", source: "System", conversationId: grandchild)
        #expect(!client.declared[0].contains("run_command") && client.declared[0].contains("read_file"))
        #expect(lastToolResult(app, grandchild) == IrisEngine.agentProfileDeniedToolResult(tool: "run_command", profile: "reviewer"))
    }

    @Test("a subagent of a plain conversation, and the evaluator, are not narrowed")
    func othersUnchanged() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = app.createNewConversation(select: false)
        let child = app.createNewConversation(isSubagent: true, select: false)
        app.linkDelegate(child, of: parent)
        let client = ScriptedClient([Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, principal: .subagent, roleLabel: "helper", client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "System", conversationId: child)
        #expect(client.declared[0].contains("run_command"))
        let profiled = app.createNewConversation(select: false, agentProfile: "reviewer")
        let grader = app.createNewConversation(isSubagent: true, select: false)
        app.linkDelegate(grader, of: profiled, kind: .evaluator)
        let evalClient = ScriptedClient([Self.reply(Part(text: "ok"))])
        let evaluator = IrisEngine(state: app, principal: .evaluator, client: evalClient,
                                   retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await evaluator.processInput("grade", source: "System", conversationId: grader)
        #expect(evalClient.declared[0].contains("run_command"), "the grader keeps its own toolset")
    }

    /// A reprompt's task is created inside the turn before it, so it starts with that turn's scope
    /// bound; it is right only because every `processInput` binds its own. This pins that, and
    /// would catch a later dispatch path outside `processInput` that inherits a stale scope.
    @Test("a goal reprompt scheduled by a narrowed turn, after Clear, is offered the full set")
    func repromptRebinds() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        app.setGoal(for: id, goal: "keep going")
        let client = ScriptedClient([Self.reply(Part(text: "working on it"))])
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, repromptDelay: 0.3)
        await engine.processInput("go", source: "UI", conversationId: id)
        app.clearAgentProfile(for: id)
        for _ in 0..<1000 where client.requests.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        app.clearGoal(for: id)
        await engine.cancelReprompt(for: id)
        try #require(client.requests.count >= 2, "the reprompt ran")
        #expect(!client.declared[0].contains("write_file"))
        #expect(client.declared[1].contains("write_file"), "the reprompt bound its own, cleared, scope")
    }

    @Test("Clear Agent Profile widens the next turn back")
    func clearWidens() async throws {
        let (app, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let client = ScriptedClient([Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hi", source: "UI", conversationId: id)
        app.clearAgentProfile(for: id)
        await engine.processInput("hi", source: "UI", conversationId: id)
        #expect(!client.declared[0].contains("write_file") && client.declared[1].contains("write_file"))
    }
}
