import Testing
import Foundation
@testable import IrisKit

/// The per-tool refusals #811 keeps as defence in depth. On a real turn #811's dispatch check
/// refuses these calls first (the tool is never offered in that mode), so each backstop is
/// reached here with the tool offered, and the assertion is on the backstop's own words: a test
/// that only said "refused" would pass on whichever layer fired first.
@MainActor
@Suite("Per-tool dispatch backstops behind #811", .timeLimit(.minutes(1)))
struct DispatchBackstopTests {

    private func engine(_ app: AppState, principal: Principal = .main) -> IrisEngine {
        IrisEngine(state: app, tier: .medium, principal: principal, client: FakeLLMClient(responses: []),
                   retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
    }

    private func openRequest(_ msgId: String, from: UUID, to: UUID) -> PeerMessageRecord {
        PeerMessageRecord(msgId: msgId, fromSession: from, toSession: to, contextId: "c", inReplyTo: nil, depth: 1,
                          firstLine: "x", sentAt: Date(), expectsReply: true, closedAt: nil, closeReason: nil)
    }

    // MARK: - A background run is not a session

    @Test("background list_sessions and set_session_card meet the unattended list refusal",
          arguments: ["list_sessions", "set_session_card"])
    func backgroundListAndCard(_ name: String) async {
        let app = AppState(); app.conversations.removeAll()
        let sender = app.createNewConversation(isBackground: true, select: false)
        app.createNewConversation(id: UUID())
        let args: [String: JSONValue] = name == "set_session_card" ? ["name": .string("run"), "description": .string("d")] : [:]
        let result = await engine(app).dispatchForTesting(FunctionCall(name: name, args: args),
                                                          conversationId: sender, offered: [name])
        #expect(result == IrisEngine.unattendedSessionListRefusal, Comment(rawValue: result))
        #expect(app.conversations.first { $0.id == sender }?.sessionCard == nil)
    }

    @Test("background send_to_session meets the unattended message refusal, and delivers nothing")
    func backgroundSend() async throws {
        let app = AppState(); app.conversations.removeAll()
        let sender = app.createNewConversation(isBackground: true, select: false)
        let target = app.createNewConversation(id: UUID())
        let result = await engine(app).dispatchForTesting(
            FunctionCall(name: "send_to_session", args: ["session_id": .string(target.uuidString), "message": .string("m")]),
            conversationId: sender, offered: ["send_to_session"])
        #expect(result == IrisEngine.unattendedSessionMessageRefusal, Comment(rawValue: result))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(app.conversations.first { $0.id == target }?.messages.isEmpty == true)
    }

    @Test("background close_request meets the unattended message refusal, and closes nothing")
    func backgroundClose() async throws {
        let app = AppState(); app.conversations.removeAll()
        let sender = app.createNewConversation(isBackground: true, select: false)
        try app.store.peers.insert(openRequest("bbbb0001", from: sender, to: UUID()))
        let result = await engine(app).dispatchForTesting(FunctionCall(name: "close_request", args: ["msg": .string("bbbb0001")]),
                                                          conversationId: sender, offered: ["close_request"])
        #expect(result == IrisEngine.unattendedSessionMessageRefusal, Comment(rawValue: result))
        #expect(try app.store.peers.message("bbbb0001")?.isOpen == true)
    }

    // MARK: - A subagent is not a session

    @Test("a subagent's session tools meet the subagent refusal",
          arguments: ["list_sessions", "describe_session", "send_to_session", "set_session_card", "close_request"])
    func subagentSessionTools(_ name: String) async throws {
        let app = AppState(); app.conversations.removeAll()
        let sub = UUID(), peer = UUID()
        app.createNewConversation(id: sub, isSubagent: true)
        app.createNewConversation(id: peer)
        try app.store.peers.insert(openRequest("bbbb0002", from: sub, to: peer))
        let args: [String: JSONValue] = [
            "session_id": .string(peer.uuidString), "to": .string(peer.uuidString), "message": .string("m"),
            "name": .string("impostor"), "description": .string("d"), "msg": .string("bbbb0002"),
        ]
        let result = await engine(app, principal: .subagent).dispatchForTesting(FunctionCall(name: name, args: args),
                                                                                conversationId: sub, offered: [name])
        #expect(result == "Refused — a subagent is not a session.", Comment(rawValue: result))
        #expect(app.conversations.first { $0.id == sub }?.sessionCard == nil)
        #expect(try app.store.peers.message("bbbb0002")?.isOpen == true)
    }

    // MARK: - The pinned conversation's tools

    @Test("an unpinned conversation meets each pinned-only tool's own refusal", arguments: [
        ("list_jobs", "Refused — the job tools are only available in a pinned conversation."),
        ("search_conversations", "Refused — search_conversations is only available in a pinned conversation."),
        ("read_conversation", "Refused — read_conversation is only available in a pinned conversation."),
    ])
    func unpinnedTools(_ name: String, _ refusal: String) async {
        let app = AppState(); app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let args: [String: JSONValue] = ["query": .string("anything"), "id": .string(UUID().uuidString)]
        let result = await engine(app).dispatchForTesting(FunctionCall(name: name, args: args),
                                                          conversationId: id, offered: [name])
        #expect(result == refusal, Comment(rawValue: result))
    }

    // MARK: - The seam itself

    @Test("the test entry still refuses a name outside its offered set")
    func seamKeepsTheCheck() async {
        let app = AppState(); app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        let result = await engine(app).dispatchForTesting(FunctionCall(name: "update_soul", args: ["content": .string("x")]),
                                                          conversationId: id, offered: ["reflect"])
        #expect(result == IrisEngine.notOfferedRefusal("update_soul"))
    }
}
