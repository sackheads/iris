import Testing
import Foundation
@testable import IrisKit

/// #811: the dispatcher runs only a tool its round offered. Declaring a tool or not (hardStrip,
/// the grader's three tools, credential gating, workflow triggers) used to be advice the model
/// could ignore by naming a tool it had seen elsewhere.
@MainActor
@Suite("Dispatch refuses tools the round did not offer (#811)", .timeLimit(.minutes(1)))
struct DispatchOfferedToolsTests {

    /// Records every request's declared names and plays back scripted replies.
    final class Capturing: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [GeminiResponse]
        private var _declared: [[String]] = []
        var declared: [[String]] { lock.withLock { _declared } }
        init(_ replies: [GeminiResponse]) { self.replies = replies }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                _declared.append(request.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
                return replies.count > 1 ? replies.removeFirst() : replies[0]
            }
        }
        var supportsStreaming: Bool { false }
    }

    struct Outcome {
        let declared: [String]
        let results: [String]
    }

    /// One turn whose model makes `call`, then says "done".
    private func turn(_ call: FunctionCall, principal: Principal = .main, background: Bool = false,
                      input: String = "go", source: String = "UI", memory: MemoryManager? = nil,
                      prepare: (AppState, UUID) -> Void = { _, _ in }) async -> Outcome {
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: background, select: false)
        prepare(app, id)
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = Capturing([
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], protectionEnabled: false, memory: memory, stickyTools: true)
        await engine.processInput(input, source: source, conversationId: id)
        let results = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }
            .compactMap { $0.functionResponse?.response["result"]?.stringValue } ?? []
        return Outcome(declared: client.declared.first ?? [], results: results)
    }

    private func refused(_ o: Outcome, _ name: String) -> Bool {
        o.results.contains { $0.contains(IrisEngine.notOfferedRefusal(name)) }
    }

    // MARK: - Refused

    @Test("the goal grader's update_soul is refused and SOUL.md is unchanged")
    func graderCannotRewriteSoul() async throws {
        // A home of its own (Invariant 7), seeded, so "unchanged" can't be another suite's write.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-811-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try "original soul".write(to: paths.soulMd, atomically: true, encoding: .utf8)
        let o = await turn(FunctionCall(name: "update_soul", args: ["content": .string("811 grader soul")]),
                           principal: .evaluator, memory: MemoryManager(paths: paths))
        #expect(!o.declared.isEmpty && !o.declared.contains("update_soul"), "declared: \(o.declared)")
        #expect(refused(o, "update_soul"), "\(o.results)")
        #expect((try? String(contentsOf: paths.soulMd, encoding: .utf8)) == "original soul", "SOUL.md changed")
    }

    @Test("gmail_send_email, not declared without Google, is refused before its handler")
    func undeclaredWorkspaceToolRefused() async {
        let o = await turn(FunctionCall(name: "gmail_send_email", args: ["to": .string("x@example.invalid"), "subject": .string("s"), "body": .string("b")]))
        #expect(!o.declared.contains("gmail_send_email"))
        #expect(refused(o, "gmail_send_email"), "\(o.results)")
        #expect(!o.results.contains { $0.contains("refresh token") }, "the handler ran")
    }

    @Test("a subagent's main-only rename_conversation is refused")
    func subagentMainOnlyToolRefused() async {
        let o = await turn(FunctionCall(name: "rename_conversation", args: ["title": .string("811 forged")]), principal: .subagent)
        #expect(!o.declared.contains("rename_conversation"))
        #expect(refused(o, "rename_conversation"), "\(o.results)")
    }

    @Test("a workflow-trigger tool on an ordinary turn is refused")
    func triggerToolOffTriggerRefused() async {
        let o = await turn(FunctionCall(name: "rename_conversation", args: ["title": .string("811 forged")]))
        #expect(!o.declared.contains("rename_conversation"))
        #expect(refused(o, "rename_conversation"), "\(o.results)")
    }

    @Test("an unattended set_workspace is still refused")
    func unattendedSetWorkspaceRefused() async {
        let o = await turn(FunctionCall(name: "set_workspace", args: ["path": .string(NSTemporaryDirectory())]), background: true)
        #expect(!o.declared.contains("set_workspace"))
        #expect(!o.results.isEmpty)
        #expect(!o.results.contains { $0.contains("Workspace set") || $0.contains("workspace set") }, "\(o.results)")
    }

    @Test("a name no tool has is refused the same way")
    func unknownNameRefused() async {
        let o = await turn(FunctionCall(name: "definitely_not_a_tool", args: [:]))
        #expect(refused(o, "definitely_not_a_tool"), "\(o.results)")
    }

    // MARK: - Still runs

    @Test("an offered tool runs")
    func offeredToolRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-811-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        let o = await turn(FunctionCall(name: "update_memory", args: ["content": .string("811 memory")]),
                           memory: MemoryManager(paths: paths))
        #expect(o.declared.contains("update_memory"))
        #expect(o.results.contains { $0.contains("Memory updated") }, "\(o.results)")
    }

    @Test("a sticky tool runs after its gate has closed")
    func stickyToolRuns() async {
        let o = await turn(FunctionCall(name: "manage_fact", args: ["action": .string("retract"), "fact_id": .string("no-such-fact")]),
                           prepare: { app, id in app.stickyTools.record(["manage_fact"], for: id) })
        #expect(o.declared.contains("manage_fact"), "declared: \(o.declared)")
        #expect(!refused(o, "manage_fact"), "\(o.results)")
        #expect(!o.results.isEmpty)
    }

    @Test("a workflow-trigger tool runs on its trigger turn")
    func triggerToolRunsOnTrigger() async {
        let o = await turn(FunctionCall(name: "rename_conversation", args: ["title": .string("811 renamed")]),
                           input: IrisEngine.renameTriggerPrefix + ": title this chat", source: "System")
        #expect(o.declared.contains("rename_conversation"), "declared: \(o.declared)")
        #expect(o.results.contains { $0.contains("renamed") }, "\(o.results)")
    }

    @Test("the offered set is the request's declarations")
    func offeredNamesComeFromTheRequest() {
        let request = GeminiRequest(contents: [], systemInstruction: nil,
                                    tools: [Tool(functionDeclarations: [FunctionDeclaration(name: "a", description: "", parameters: nil),
                                                                        FunctionDeclaration(name: "b", description: "", parameters: nil)])])
        #expect(IrisEngine.offeredToolNames(request) == ["a", "b"])
        #expect(IrisEngine.offeredToolNames(GeminiRequest(contents: [], systemInstruction: nil, tools: nil)).isEmpty)
    }
}
