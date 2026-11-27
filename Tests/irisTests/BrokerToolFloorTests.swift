import Testing
import Foundation
@testable import IrisKit

/// #1203: `.broker`'s floor (search_memory, search_conversations, read_conversation) now holds at
/// both tool-declaration sites and at dispatch, mirroring `GuestToolsetTests`' own structure --
/// these drive the real engine, not `PrincipalFloor.floor(for:.broker)` alone, since asserting
/// against the floor would pass whatever `buildRequest` appended after it.
@MainActor
@Suite("Disclosure broker tool floor (#974 H2, #1203)", .timeLimit(.minutes(2)))
struct BrokerToolFloorTests {
    private let floor: Set<String> = ["search_memory", "search_conversations", "read_conversation"]

    /// Pinned: `search_conversations`/`read_conversation` are declared only when `isPinned`
    /// (invariant 6, iris.swift's `jobToolDeclarations(isPinned:)`) -- unrelated to the broker
    /// floor itself, but required for all three of its tools to appear in `executor.getTools()`
    /// at all, which is what the broker-floor filter then narrows.
    private func brokerApp() -> (AppState, UUID) {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(title: "broker")
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[idx].isPinned = true }
        return (app, id)
    }

    @Test("the request a broker engine is sent declares exactly its three-tool floor, with every gate on")
    func requestDeclaresOnlyTheFloor() async {
        let (app, id) = brokerApp()
        app.stickyTools.record(["run_command", "send_to_session", "inbox_item"], for: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .broker, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 3, declareStateGatedTools: true,
                                stickyTools: true)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let names = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        #expect(Set(names) == floor)
        #expect(names.count == 3, "each tool once")
    }

    private func result(of name: String, args: [String: JSONValue] = [:]) async -> (String, AppState) {
        let (app, id) = brokerApp()
        let first = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args, id: "c1"))]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .broker,
                                client: FakeLLMClient(responses: [first, final]), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        let history = app.conversations.first { $0.id == id }?.history ?? []
        let text = history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
        return (text, app)
    }

    @Test("a broker's call to any tool outside its floor is refused before a handler runs",
          arguments: ["run_command", "write_file", "vcs", "save_fact", "manage_fact",
                      "update_memory", "update_soul", "send_to_session", "schedule_job", "list_sessions"])
    func outsideTheFloorRefused(name: String) async {
        let (text, _) = await result(of: name, args: ["command": .string("touch /tmp/iris-1203-should-not-exist"),
                                                      "path": .string("/tmp/iris-1203-nope")])
        #expect(text == PrincipalFloor.brokerRefusal(for: name), "\(name): \(text)")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/iris-1203-should-not-exist"))
    }

    @Test("a broker's call to a floor tool is not refused at the floor gate")
    func floorToolNotRefused() async {
        let (text, _) = await result(of: "search_memory", args: ["query": .string("x")])
        #expect(!text.contains("this session can only use"), "a floor tool must not be refused by the broker gate: \(text)")
    }
}
