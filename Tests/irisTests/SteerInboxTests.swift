import Testing
import Foundation
import SwiftUI
import AppKit
@testable import IrisKit

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
@Suite("Mid-turn user messages (#172)", .timeLimit(.minutes(1)))
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
        let taken = app.takePendingSteers(for: id)
        #expect(taken.map(\.text) == ["a", "b"])
        #expect(taken.allSatisfy { !$0.isPeer }, "an ordinary enqueue must never be mistaken for a peer delivery")
        #expect(app.takePendingSteers(for: id).isEmpty)
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

    /// #182 §6.1 widened `hasTurnInFlight` to see engine-started turns, so `sendMessage` now
    /// queues behind an arrival — a scheduled job, a watcher event, a subagent post-back. An
    /// arrival never runs through `runThinkingTask`, so the engine turn's own end hop is the only
    /// thing that can hand the queue on; without it the bubble appears and is silently ignored.
    @Test("a message typed during an arrival turn is drained when that turn ends")
    func arrivalTurnDrainsQueue() async throws {
        let gate = Gate()
        let client = ScriptedStreamClient([
            [.event(.textDelta("arrival")), .block { await gate.wait() }, .event(.done(finishReason: nil))],
            [.event(.textDelta("answer")), .event(.done(finishReason: nil))]
        ])
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: true)
        app.installEngine(engine)

        // The scheduler's path: straight into `processInput`, with no `activeTasks` entry.
        let arrival = Task {
            await engine.processInput("Scheduled Job Triggered: sweep", source: "Scheduler",
                                      conversationId: id)
        }
        #expect(await eventually { client.calls == 1 })

        app.sendMessage("what are you doing?")
        #expect(app.pendingUserMessageCount(for: id) == 1, "the arrival turn is in flight, so it queues")
        #expect(client.calls == 1)

        await gate.release()
        _ = try await value(of: arrival)
        #expect(await eventually { client.calls == 2 && !app.isThinking })
        #expect(app.pendingUserMessageCount(for: id) == 0, "the arrival's end hop drained it")
        #expect(texts(app, id, .agent) == ["arrival", "answer"])
    }

    @Test("a queued text message stops takePendingSteers and holds entries behind it (#1064)")
    func queuedMessageStopsTakePendingSteers() {
        let app = AppState()
        let id = UUID()
        app.enqueuePendingUserMessage(text: "steer ahead", attachments: [], for: id)
        app.enqueuePendingUserMessage(text: "queued middle", attachments: [], for: id, queued: true)
        app.enqueuePendingUserMessage(text: "steer behind", attachments: [], for: id)

        #expect(app.takePendingSteers(for: id).map(\.text) == ["steer ahead"])
        #expect(app.pendingUserMessageCount(for: id) == 2)
        #expect(app.takePendingSteers(for: id).isEmpty)
    }

    @Test("sending with queue: true waits for a multi-round turn to finish and merges queued messages (#1064)")
    func queuedMessageWaitsForMultiRoundTurnToFinish() async {
        let gate = Gate()
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo round1")], id: "c1")
        let client = ScriptedStreamClient([
            [.event(.functionCall(call)), .block { await gate.wait() }, .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("finished first turn")), .event(.done(finishReason: nil))],
            [.event(.textDelta("answered queued turn")), .event(.done(finishReason: nil))]
        ])
        let (app, id) = session(client)
        app.sendMessage("first")
        #expect(await eventually { client.calls == 1 })

        app.sendMessage("do this after", queue: true)
        app.sendMessage("and also this", queue: true)
        #expect(app.pendingUserItems(for: id).map { "\($0.summary):\($0.isQueued)" } == [
            "do this after:true",
            "and also this:true"
        ])

        await gate.release()
        #expect(await eventually { client.calls == 3 && !app.isThinking })
        #expect(texts(app, id, .agent) == ["finished first turn", "answered queued turn"])
        #expect(historyShape(app, id) == [
            "user[text:first]", "model[call:run_command]", "user[resp:run_command]",
            "model[text:finished first turn]",
            "user[text:do this after\n\nand also ]", "model[text:answered queued turn]"
        ])
        #expect(client.requests.last?.contents.last?.parts.last?.text == "do this after\n\nand also this")
        #expect(app.pendingUserItems(for: id).isEmpty)
    }

    @Test("pendingUserItems marks entries behind a queued message as Queued and flips back to Steer if the blocker is cancelled (#1064)")
    func pendingUserItemsReflectBlockingAndCancellation() {
        let client = ScriptedStreamClient([[.event(.textDelta("hold")), .hang]])
        let (app, id) = session(client)
        app.sendMessage("first")
        app.sendMessage("queued blocker", queue: true)
        app.sendMessage("steer behind blocker", queue: false)

        let itemsBefore = app.pendingUserItems(for: id)
        #expect(itemsBefore.count == 2)
        #expect(itemsBefore[0].summary == "queued blocker")
        #expect(itemsBefore[0].isQueued == true)
        #expect(itemsBefore[1].summary == "steer behind blocker")
        #expect(itemsBefore[1].isQueued == true, "behind a queued entry, so it waits for turn end too")
        #expect(texts(app, id, .user) == ["first", "queued blocker", "steer behind blocker"])

        let cancelled = app.cancelPendingUserMessage(id: itemsBefore[0].id, in: id)
        #expect(cancelled == true)
        #expect(texts(app, id, .user) == ["first", "steer behind blocker"],
                "cancelling a pending entry removes its user bubble from the transcript")

        let itemsAfter = app.pendingUserItems(for: id)
        #expect(itemsAfter.count == 1)
        #expect(itemsAfter[0].summary == "steer behind blocker")
        #expect(itemsAfter[0].isQueued == false,
                "once the queued blocker ahead of it is cancelled, the entry steers again")

        #expect(app.cancelPendingUserMessage(id: itemsBefore[0].id, in: id) == false,
                "cancelling an already-removed entry is a no-op")
        app.interruptActiveConversation()
    }

    @Test("PendingMessagesChip shrinks to one item and caps at 120 pt for many items (Invariant 8, #1064)")
    func pendingMessagesChipHeightIsCapped() {
        let app = AppState()
        let id = UUID()
        app.enqueuePendingUserMessage(text: "one pending message", attachments: [], for: id)

        func measureChip() -> CGFloat {
            let hc = NSHostingController(
                rootView: PendingMessagesChip(state: app, conversationId: id).frame(width: 500)
            )
            hc.view.layoutSubtreeIfNeeded()
            return hc.view.fittingSize.height
        }

        let oneRowHeight = measureChip()
        #expect(oneRowHeight > 16 && oneRowHeight < 60,
                "1-item chip should take its natural height, got \(oneRowHeight) pt")

        for i in 2...20 {
            app.enqueuePendingUserMessage(text: "pending message \(i)", attachments: [], for: id, queued: i.isMultiple(of: 2))
        }
        let cappedHeight = measureChip()
        #expect(cappedHeight <= 120.5,
                "20-item chip should cap at 120 pt (Invariant 8), got \(cappedHeight) pt")
    }
}
