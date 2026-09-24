import Testing
import Foundation
@testable import iris

/// #282 §0.10 — a background run cannot move its own boundary. `set_workspace` is not declared to
/// an unattended turn (invariant 6) and is refused in the dispatcher if called anyway.
@MainActor
@Suite("set_workspace is refused unattended (#282)")
struct UnattendedWorkspaceTests {
    private func engine(_ app: AppState, client: any LLMClientProtocol) -> IrisEngine {
        IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                   retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
    }

    @Test("a background turn is not offered set_workspace; an ordinary turn still is")
    func notDeclaredInTheBackground() async {
        for background in [true, false] {
            let app = AppState()
            app.conversations.removeAll()
            let id = app.createNewConversation(isBackground: background, select: false)
            let client = CapturingLLMClient(reply: "ok")
            await engine(app, client: client).processInput("hello", source: "UI", conversationId: id)
            let declared = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
            #expect(declared.contains("set_workspace") == !background)
        }
    }

    @Test("a background conversation's set_workspace is refused with the sentence and its workspacePath is unchanged")
    func refusedInTheDispatcher() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-unattended-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: id, path: "/Users/me/proj")
        let call = FunctionCall(name: "set_workspace", args: ["path": .string(dir.path)])
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))], usageMetadata: nil),
        ])
        await engine(app, client: client).processInput("go", source: "UI", conversationId: id)
        let results = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }
            .compactMap { $0.functionResponse?.response["result"]?.stringValue } ?? []
        #expect(results.contains(IrisEngine.unattendedWorkspaceRefusal))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/Users/me/proj")
    }

    @Test("binding a goal workspace in a background conversation binds nothing and leaves workspacePath unchanged")
    func goalBindingLeavesABackgroundWorkspaceAlone() throws {
        let paths = IrisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-unattended-goal-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: id, path: "/Users/me/proj")
        let bound = app.bindGoalWorkspace(for: id, contract: GoalContract(objective: "Write a hangman game", criteria: []),
                                          paths: paths)
        #expect(bound == nil)
        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/Users/me/proj")
        #expect(!FileManager.default.fileExists(atPath: paths.workspacesDir.path), "no directory is created for a binding that does not happen")

        // The attended case is untouched: `GoalWorkspaceBindingTests.createsAndBinds` still holds.
        let attended = app.createNewConversation()
        #expect(app.bindGoalWorkspace(for: attended, contract: GoalContract(objective: "Write a hangman game", criteria: []),
                                      paths: paths) != nil)
    }
}
