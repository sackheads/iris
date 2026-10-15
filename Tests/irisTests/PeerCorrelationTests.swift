import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Peer correlation", .timeLimit(.minutes(1)))
struct PeerCorrelationTests {
    private func toolResultText(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.history ?? []).flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    private func call(_ args: [String: JSONValue], on app: AppState, as id: UUID) async -> String {
        let fc = FunctionCall(name: "send_to_session", args: args, id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: fc)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, id)
    }

    private func msgId(in result: String) -> String? {
        result.range(of: #"msg [0-9a-f]{8}"#, options: .regularExpression).map { String(result[$0].dropFirst(4)) }
    }

    @Test("a send returns its msg id, records it, and opens a request only with expects_reply")
    func sendRecords() async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        let out = await call(["to": .string(b.uuidString), "message": .string("please triage #12\nmore"),
                              "expects_reply": .bool(true)], on: app, as: a)
        let id = try #require(msgId(in: out))
        let rec = try #require(try app.store.peers.message(id))
        #expect(rec.fromSession == a && rec.toSession == b && rec.expectsReply && rec.depth == 1)
        #expect(rec.firstLine == "please triage #12")
        #expect(try app.store.peers.openRequests(from: a).map(\.msgId) == [id])
    }

    /// #469 review item 7: a model that writes a JSON tool call by hand may spell this as the
    /// string `"true"` rather than the boolean literal; refusing it silently (treating it as
    /// false) would leave the sender thinking it is tracked as a request when it is not.
    @Test("expects_reply accepts the string \"true\", any case, as well as the boolean",
          arguments: [JSONValue.string("true"), .string("True"), .string("TRUE"), .bool(true)])
    func expectsReplyAcceptsStringTrue(_ value: JSONValue) async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        let out = await call(["to": .string(b.uuidString), "message": .string("x"), "expects_reply": value], on: app, as: a)
        let id = try #require(msgId(in: out))
        #expect(try app.store.peers.message(id)?.expectsReply == true)
    }

    @Test("expects_reply treats any other string as false")
    func expectsReplyOtherStringIsFalse() async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        let out = await call(["to": .string(b.uuidString), "message": .string("x"), "expects_reply": .string("nah")], on: app, as: a)
        let id = try #require(msgId(in: out))
        #expect(try app.store.peers.message(id)?.expectsReply == false)
    }

    @Test("a reply inherits the thread, closes the request, and is framed as a reply to the original")
    func replyCloses() async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        let sent = await call(["to": .string(b.uuidString), "message": .string("please triage #12"),
                               "expects_reply": .bool(true)], on: app, as: a)
        let req = try #require(msgId(in: sent))
        let replied = await call(["in_reply_to": .string(req), "message": .string("done: dup of #9")], on: app, as: b)
        let rep = try #require(msgId(in: replied))
        let reqRec = try #require(try app.store.peers.message(req))
        let repRec = try #require(try app.store.peers.message(rep))
        #expect(repRec.contextId == reqRec.contextId && repRec.inReplyTo == req && repRec.toSession == a)
        #expect(!reqRec.isOpen && reqRec.closeReason?.contains(rep) == true)
    }

    @Test("in_reply_to naming a message not delivered to this session is refused")
    func replyNotYours() async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] { app.createNewConversation(id: id) }
        let sent = await call(["to": .string(b.uuidString), "message": .string("x"), "expects_reply": .bool(true)], on: app, as: a)
        let req = try #require(msgId(in: sent))
        let out = await call(["in_reply_to": .string(req), "message": .string("I'll take it")], on: app, as: c)
        #expect(out.contains("not delivered to this session"))
        #expect(try app.store.peers.message(req)?.isOpen == true)
    }

    @Test("a second reply still delivers and leaves the first reply's close in place")
    func secondReply() async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        let req = try #require(msgId(in: await call(["to": .string(b.uuidString), "message": .string("x"), "expects_reply": .bool(true)], on: app, as: a)))
        let first = try #require(msgId(in: await call(["in_reply_to": .string(req), "message": .string("one")], on: app, as: b)))
        let second = await call(["in_reply_to": .string(req), "message": .string("two")], on: app, as: b)
        #expect(msgId(in: second) != nil, "a reply to a closed request still delivers")
        #expect(try app.store.peers.message(req)?.closeReason?.contains(first) == true)
    }

    @Test("framing carries the msg id, the reply hint, and for a reply the original's first line, flattened")
    func framing() {
        let env = PeerEnvelope(msgId: "7f3a0001", contextId: "c", depth: 1, expectsReply: true, replyTo: nil)
        let req = IrisEngine.framePeerMessage("body", senderName: "w", senderId: UUID(), senderRole: nil, envelope: env)
        #expect(req.contains("msg 7f3a0001") && req.contains("in_reply_to: 7f3a0001") && req.contains("waiting for a reply"))
        let rep = PeerEnvelope(msgId: "7f3a0002", contextId: "c", depth: 2, expectsReply: false,
                               replyTo: PeerReplyRef(msgId: "7f3a0001", firstLine: IrisEngine.firstLine(of: "line \"one\"|x\nline two")))
        let text = IrisEngine.framePeerMessage("body", senderName: "w", senderId: UUID(), senderRole: nil, envelope: rep)
        #expect(text.contains("Reply from another session"))
        #expect(text.contains("to your msg 7f3a0001 (\"line 'one'/x\")"))
    }
}
