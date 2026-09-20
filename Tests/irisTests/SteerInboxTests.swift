import Testing
import Foundation
@testable import iris

/// Releases waiting callers on demand so a scripted round can be held open deterministically.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let w = waiters; waiters = []
        w.forEach { $0.resume() }
    }
}

private func eventually(_ timeoutMs: Int = 3000, _ condition: @MainActor @Sendable () -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// A user message sent while a turn is already running must steer that turn, or follow it,
/// never start a second turn interleaved on the same history (#172).
@MainActor
@Suite("Mid-turn user messages (#172)")
struct SteerInboxTests {
    private var sampleAttachment: FileAttachment {
        FileAttachment(id: UUID(), filename: "a.txt", fileURL: URL(fileURLWithPath: "/tmp/a.txt"),
                       mimeType: "text/plain", fileSize: 1, category: .text)
    }
    private func session(_ client: any LLMClientProtocol) -> (AppState, UUID) {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        app.installEngine(IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [], streamResponses: true))
        return (app, id)
    }
    private func conv(_ app: AppState, _ id: UUID) -> Conversation { app.conversations.first { $0.id == id }! }
    private func texts(_ app: AppState, _ id: UUID, _ role: ChatRole) -> [String] { conv(app, id).messages.filter { $0.role == role }.map(\.content) }
    private func historyShape(_ app: AppState, _ id: UUID) -> [String] {
        conv(app, id).history.map { c in
            let parts = c.parts.map { p -> String in
                if let t = p.text { return "text:\(t.prefix(24))" }
                if let f = p.functionCall { return "call:\(f.name)" }
                if let r = p.functionResponse { return "resp:\(r.name)" }
                return "other"
            }
            return "\(c.role ?? "?")[\(parts.joined(separator: ","))]"
        }
    }

    @Test("text entries are taken in order; an attachment entry and everything behind it wait for the turn to end")
    func inboxOrdering() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.enqueuePendingUserMessage(text: "a", attachments: [], for: id)
        app.enqueuePendingUserMessage(text: "b", attachments: [], for: id)
        app.enqueuePendingUserMessage(text: "c", attachments: [sampleAttachment], for: id)
        app.enqueuePendingUserMessage(text: "d", attachments: [], for: id)
        #expect(app.takePendingSteers(for: id) == ["a", "b"])
        #expect(app.takePendingSteers(for: id) == [])
        #expect(app.pendingUserMessageCount(for: id) == 2)
    }

    @Test("a send while a turn is in flight shows the bubble at once and does not start a second turn")
    func sendQueuesWhileRunning() async {
        let gate = Gate()
        let client = ScriptedStreamClient([
            [.event(.textDelta("one")), .block { await gate.wait() }, .event(.done(finishReason: nil))],
            [.event(.textDelta("two")), .event(.done(finishReason: nil))]
        ])
        let (app, id) = session(client)
        app.sendMessage("first")
        #expect(await eventually { client.calls == 1 })
        app.sendMessage("second")
        #expect(texts(app, id, .user) == ["first", "second"])
        #expect(app.hasTurnInFlight(for: id))
        #expect(app.pendingUserMessageCount(for: id) == 1)
        #expect(client.calls == 1)
        await gate.release()
        // Round one had no tool call, so the turn ends; the queued message follows as its own turn.
        #expect(await eventually { client.calls == 2 && !app.isThinking })
        #expect(texts(app, id, .agent) == ["one", "two"])
        #expect(historyShape(app, id) == ["user[text:first]", "model[text:one]", "user[text:second]", "model[text:two]"])
        #expect(app.pendingUserMessageCount(for: id) == 0)
    }

    @Test("a message that arrives between model rounds joins the running turn after the tool result")
    func steerJoinsRunningTurn() async {
        let gate = Gate()
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo steered")], id: "c1")
        let client = ScriptedStreamClient([
            [.event(.functionCall(call)), .block { await gate.wait() }, .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("ok")), .event(.done(finishReason: nil))]
        ])
        let (app, id) = session(client)
        app.sendMessage("first")
        #expect(await eventually { client.calls == 1 })
        app.sendMessage("also check /tmp")
        await gate.release()
        #expect(await eventually { client.calls == 2 && !app.isThinking })
        #expect(client.calls == 2)
        #expect(texts(app, id, .agent) == ["ok"])
        #expect(historyShape(app, id) == [
            "user[text:first]", "model[call:run_command]", "user[resp:run_command]",
            "user[text:User (mid-task): also ch]", "model[text:ok]"
        ])
        let secondRequest = client.requests.last
        #expect(secondRequest?.contents.last?.parts.first?.text == "User (mid-task): also check /tmp")
        #expect(app.pendingUserMessageCount(for: id) == 0)
    }

    @Test("Stop drops the queued messages and says so")
    func interruptDropsQueue() async {
        let client = ScriptedStreamClient([[.event(.textDelta("part")), .hang], [.event(.textDelta("never")), .event(.done(finishReason: nil))]])
        let (app, id) = session(client)
        app.sendMessage("first")
        #expect(await eventually { self.texts(app, id, .agent) == ["part"] })
        app.sendMessage("second")
        #expect(app.pendingUserMessageCount(for: id) == 1)
        app.interruptActiveConversation()
        #expect(await eventually { !app.isThinking })
        #expect(app.pendingUserMessageCount(for: id) == 0)
        #expect(texts(app, id, .system).last == "Interrupted. 1 queued message dropped.")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.calls == 1)
    }
}
