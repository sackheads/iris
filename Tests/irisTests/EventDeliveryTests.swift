import Testing
import Foundation
@testable import iris

/// Releases waiting callers on demand so a scripted round can be held open deterministically.
/// Mirrors `SteerInboxTests`' private `Gate` — file-private there, so this file needs its own.
private actor EventGate {
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

/// #187 §8.3. Delivering an event card must be inert with respect to turn scheduling: the card
/// appears in the destination's transcript the moment it is delivered, but the model-facing
/// history line either joins a turn that is already running (at the same boundary a steer joins
/// it, i.e. after the tool results of the round in flight) or is appended straight to history
/// when nothing is running. Either way no turn is started and no turn is woken.
@MainActor
@Suite("Event delivery (#187)")
struct EventDeliveryTests {

    private func card(name: String = "pr-sweep",
                      status: JobRun.Status = .completed,
                      outcome: String? = "swept 3 PRs",
                      runId: UUID = UUID()) -> EventCard {
        EventCard(runId: runId, jobId: UUID(), jobName: name, status: status, outcome: outcome,
                  startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                  finishedAt: Date(timeIntervalSince1970: 1_700_000_042),
                  totalTokens: 4200, transcriptConversationId: UUID())
    }

    private func conv(_ app: AppState, _ id: UUID) -> Conversation { app.conversations.first { $0.id == id }! }

    /// The text of every history entry, with tool calls/responses named — enough to pin the order
    /// of an event line against a function call and its response.
    private func historyShape(_ app: AppState, _ id: UUID) -> [String] {
        conv(app, id).history.map { c in
            let parts = c.parts.map { p -> String in
                if let f = p.functionCall { return "call:\(f.name)" }
                if let r = p.functionResponse { return "resp:\(r.name)" }
                if let t = p.text { return "text:\(t)" }
                return "other"
            }
            return "\(c.role ?? "?")[\(parts.joined(separator: ","))]"
        }
    }

    // MARK: - AppState

    @Test("delivery to an idle conversation writes the card and the history line, and starts no turn")
    func idleDeliveryAppendsBoth() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let c = card()

        await app.deliverEvent(c, to: id)

        let destination = conv(app, id)
        #expect(destination.messages.count == 1)
        #expect(destination.messages.first?.role == .event)
        #expect(destination.messages.first?.content == c.encodedContent(),
                "the UI message is the raw card, not the sanitised history line")
        #expect(destination.history.count == 1)
        #expect(destination.history.first?.role == "user")
        let line = destination.history.first?.parts.first?.text
        #expect(line?.contains(c.historyLine) == true)
        #expect(line?.contains("<untrusted_context source=\"event_card\">") == true,
                "a card carries a job's output; the model must see it as untrusted context")
        #expect(app.hasTurnInFlight(for: id) == false)
        #expect(app.isThinking == false)
        #expect(app.takePendingEventLines(for: id).isEmpty, "nothing was queued — it went straight to history")
        #expect(app.pendingUserMessageCount(for: id) == 0, "an event line is never a pending user message")
    }

    @Test("delivery during a turn shows the card at once and queues the line, never as a steer")
    func busyDeliveryQueuesTheLine() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.beginEngineTurn(for: id)
        let c = card()

        await app.deliverEvent(c, to: id)

        #expect(conv(app, id).messages.count == 1)
        #expect(conv(app, id).messages.first?.role == .event)
        #expect(conv(app, id).history.isEmpty, "the line must not cut into a running turn's history")
        #expect(app.takePendingSteers(for: id).isEmpty, "an event line must never enter the steer inbox")
        #expect(app.pendingUserMessageCount(for: id) == 0)

        let taken = app.takePendingEventLines(for: id)
        #expect(taken.count == 1)
        #expect(taken.first?.contains(c.historyLine) == true)
        #expect(app.takePendingEventLines(for: id).isEmpty, "takePendingEventLines clears on read")
    }

    @Test("queued lines come back in arrival order")
    func queueIsFIFO() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.enqueueEventLine("one", for: id)
        app.enqueueEventLine("two", for: id)
        #expect(app.takePendingEventLines(for: id) == ["one", "two"])
        #expect(app.takePendingEventLines(for: id).isEmpty)
    }

    @Test("a queue is per conversation")
    func queueIsPerConversation() {
        let app = AppState()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.enqueueEventLine("for a", for: a)
        #expect(app.takePendingEventLines(for: b).isEmpty)
        #expect(app.takePendingEventLines(for: a) == ["for a"])
    }

    @Test("the end of a turn flushes what is left into history without starting a new turn")
    func turnEndFlushesTheQueue() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.beginEngineTurn(for: id)
        let first = card(name: "pr-sweep", outcome: "swept 3 PRs")
        let second = card(name: "inbox", outcome: "nothing new")

        await app.deliverEvent(first, to: id)
        await app.deliverEvent(second, to: id)
        #expect(conv(app, id).history.isEmpty)

        app.endEngineTurn(for: id)

        let history = conv(app, id).history
        #expect(history.count == 2, "both queued lines land, in order")
        #expect(history.first?.role == "user")
        #expect(history.first?.parts.first?.text?.contains(first.historyLine) == true)
        #expect(history.last?.parts.first?.text?.contains(second.historyLine) == true)
        #expect(app.takePendingEventLines(for: id).isEmpty)
        #expect(app.hasTurnInFlight(for: id) == false, "the flush must not begin another turn")
        #expect(app.isThinking == false)
        #expect(app.takePendingSteers(for: id).isEmpty, "the steer inbox is untouched by the flush")
        #expect(conv(app, id).messages.count == 2, "the flush adds no new transcript message")
    }

    @Test("a turn that is still running does not flush the queue")
    func nestedTurnDoesNotFlushEarly() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.beginEngineTurn(for: id)
        app.beginEngineTurn(for: id)
        await app.deliverEvent(card(), to: id)

        app.endEngineTurn(for: id)
        #expect(conv(app, id).history.isEmpty, "one of two overlapping turns ending is not the end of the turn")

        app.endEngineTurn(for: id)
        #expect(conv(app, id).history.count == 1)
    }

    // MARK: - Engine

    /// The ordering guarantee, end to end. A card delivered while a model round is in flight must
    /// leave the round's own call/response pair intact: its line joins the history *after* the
    /// function response, where the next round reads it, and never between the call and the
    /// response (which would leave the model looking at an unanswered call). A card delivered
    /// during the final round has no later round to join and is flushed at turn end — into
    /// history only, with no third model call.
    ///
    /// The hold is a `.block` step inside the scripted stream, the same seam `SteerInboxTests`
    /// uses: there is no deterministic way to pause the engine *inside* tool execution without a
    /// new test seam (the only candidates are the process-wide approval and hook singletons,
    /// which other suites mutate). Delivering one step earlier is strictly harder on the
    /// implementation — at that moment the model's function call is not in history yet, so an
    /// implementation that appended immediately would put the event line *above* the call, which
    /// the shape assertion below also catches.
    @Test("a card delivered mid-turn joins the history after the tool result, never between the call and its response")
    func midTurnDeliveryLandsAfterTheToolResult() async {
        let roundOne = EventGate()
        let roundTwo = EventGate()
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo hi")], id: "c1")
        let client = ScriptedStreamClient([
            [.event(.functionCall(call)), .block { await roundOne.wait() }, .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("ok")), .block { await roundTwo.wait() }, .event(.done(finishReason: nil))]
        ])
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: true)
        app.installEngine(engine)

        let midTurn = card(name: "pr-sweep", outcome: "swept 3 PRs")
        let lateTurn = card(name: "inbox", outcome: "nothing new")

        let turn = Task { await engine.processInput("first", source: "UI", conversationId: id) }
        #expect(await eventually { client.calls == 1 })

        // Round one is held open: the tool call has been streamed but the turn is very much alive.
        await app.deliverEvent(midTurn, to: id)
        #expect(conv(app, id).messages.contains { $0.role == .event && $0.content == midTurn.encodedContent() },
                "the card is visible immediately, turn or no turn")
        #expect(conv(app, id).history.allSatisfy { $0.parts.allSatisfy { ($0.text ?? "").isEmpty || !($0.text ?? "").contains(midTurn.historyLine) } },
                "the line waits for the boundary")

        await roundOne.release()
        #expect(await eventually { client.calls == 2 })

        // Round two is the last one, so this card's line has no round left to join.
        await app.deliverEvent(lateTurn, to: id)
        await roundTwo.release()
        _ = await turn.value
        #expect(await eventually { !app.isThinking })

        let shape = historyShape(app, id)
        let callIndex = shape.firstIndex { $0.contains("call:run_command") }
        let responseIndex = shape.firstIndex { $0.contains("resp:run_command") }
        let midIndex = shape.firstIndex { $0.contains(midTurn.historyLine) }
        let lateIndex = shape.firstIndex { $0.contains(lateTurn.historyLine) }
        #expect(callIndex != nil && responseIndex != nil, "shape was \(shape)")
        #expect(midIndex != nil && lateIndex != nil, "shape was \(shape)")
        if let callIndex, let responseIndex, let midIndex, let lateIndex {
            #expect(callIndex < responseIndex)
            #expect(responseIndex < midIndex, "the event line must never sit between a call and its response")
            #expect(midIndex < lateIndex)
            #expect(shape[midIndex].hasPrefix("user["))
            #expect(shape[lateIndex].hasPrefix("user["))
            #expect(lateIndex == shape.count - 1, "the last card is flushed at turn end, after the reply")
        }

        #expect(client.calls == 2, "a delivered card never wakes a model turn")
        #expect(client.requests.count == 2)
        #expect(client.requests.last?.contents.contains { c in
            c.parts.contains { ($0.text ?? "").contains(midTurn.historyLine) }
        } == true, "the mid-turn line was actually sent to the model")
        #expect(client.requests.last?.contents.contains { c in
            c.parts.contains { ($0.text ?? "").contains(lateTurn.historyLine) }
        } == false, "the last card arrived too late for this turn; it waits in history for the next one")
        #expect(app.takePendingEventLines(for: id).isEmpty)
        #expect(app.pendingUserMessageCount(for: id) == 0)
        #expect(conv(app, id).messages.filter { $0.role == .event }.count == 2)
    }
}
