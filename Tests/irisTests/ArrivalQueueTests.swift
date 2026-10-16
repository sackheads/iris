import Testing
import Foundation
@testable import IrisKit

/// Set once from the test, polled by a scripted round.
private final class OpenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isOpen: Bool { lock.withLock { flag } }
    func open() { lock.withLock { flag = true } }
}

private func eventually(_ timeoutMs: Int = 5000, _ condition: @MainActor @Sendable () -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// #478: an arrival that starts a turn without the owner (a background subagent's post-back, a
/// peer message) waits for the turn in flight AND for a goal follow-up waiting out its delay.
/// Started beside either, it put a user entry between a model's `functionCall` and its
/// `functionResponse`, which Anthropic rejects with a 400, or ran two turns on one history.
@MainActor
@Suite("Arrivals queue behind a turn and a waiting follow-up (#478)", .timeLimit(.minutes(1)))
struct ArrivalQueueTests {
    private func session(_ client: any LLMClientProtocol, repromptDelay: TimeInterval = 1.5) -> (AppState, IrisEngine, UUID) {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                repromptDelay: repromptDelay)
        app.installEngine(engine)
        return (app, engine, id)
    }

    private func history(_ app: AppState, _ id: UUID) -> [Content] {
        app.conversations.first { $0.id == id }?.history ?? []
    }

    private func texts(_ app: AppState, _ id: UUID) -> [String] {
        history(app, id).flatMap { $0.parts.compactMap(\.text) }
    }

    /// Every model entry with calls is followed at once by the entry answering all of them.
    private func expectCallsAnswered(_ history: [Content], sourceLocation: SourceLocation = #_sourceLocation) {
        for (i, entry) in history.enumerated() {
            let callIds = Set(entry.parts.compactMap { $0.functionCall?.id })
            guard !callIds.isEmpty else { continue }
            let next = i + 1 < history.count ? history[i + 1] : nil
            let answered = Set(next?.parts.compactMap { $0.functionResponse?.id } ?? [])
            #expect(answered == callIds, "entry \(i + 1) does not answer the calls in entry \(i)",
                    sourceLocation: sourceLocation)
        }
    }

    /// A command that runs until `marker` exists, so the test decides when the tool batch ends.
    private func waitingCall(_ marker: URL) -> FunctionCall {
        FunctionCall(name: "run_command",
                     args: ["command": .string("while [ ! -e '\(marker.path)' ]; do sleep 0.02; done; echo released")],
                     id: "c1")
    }

    private func marker() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-478-\(UUID().uuidString)")
    }

    @Test("a post-back that lands while tools run waits for their results")
    func postBackMidToolBatch() async throws {
        let release = marker()
        defer { try? FileManager.default.removeItem(at: release) }
        let client = ScriptedStreamClient([
            [.event(.functionCall(waitingCall(release))), .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("ok")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
        ])
        let (app, engine, id) = session(client)
        app.sendMessage("go")
        #expect(await eventually { self.history(app, id).contains { $0.parts.contains { $0.functionCall != nil } } })

        Task { await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id) }
        // Queued, or (the bug) a second turn already called the model.
        #expect(await eventually { app.pendingUserMessageCount(for: id) == 1 || client.calls >= 2 })
        FileManager.default.createFile(atPath: release.path, contents: nil)
        #expect(await eventually { !app.isThinking && !app.hasTurnInFlight(for: id) && client.calls >= 2 })

        let h = history(app, id)
        expectCallsAnswered(h)
        let response = try #require(h.firstIndex { $0.parts.contains { $0.functionResponse != nil } })
        let arrivals = h.indices.filter { h[$0].parts.contains { $0.text?.contains("Background subagent result: built") == true } }
        #expect(arrivals.count == 1, "the post-back reaches history once")
        #expect(arrivals.allSatisfy { $0 > response }, "after the tool result, never before it")
        #expect(client.calls == 2, "read inside the running turn, not in a second one")
        #expect(app.pendingUserMessageCount(for: id) == 0)
    }

    @Test("a post-back and a peer message that arrive while a goal follow-up waits are read by that follow-up")
    func arrivalsWaitForAPendingFollowUp() async throws {
        let client = ScriptedStreamClient([
            [.event(.textDelta("working")), .event(.done(finishReason: nil))],
            [.event(.textDelta("read them")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
        ])
        let (app, engine, id) = session(client, repromptDelay: 1.0)
        app.setGoal(for: id, goal: "do the thing")
        let peer = UUID()
        app.createNewConversation(id: peer, select: false)
        app.selectedConversationId = id

        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(engine.goalLoopIsLive(for: id), "the reprompt is waiting out its delay")
        #expect(!app.hasTurnInFlight(for: id))

        await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id)
        let envelope = PeerEnvelope(msgId: "dddd0478", contextId: "ctx-dddd0478", depth: 1, expectsReply: false, replyTo: nil)
        let outcome = await engine.deliverPeerMessage("also this", from: peer, senderName: "peer", to: id, envelope: envelope)
        #expect(outcome == .queued)
        #expect(app.pendingUserMessageCount(for: id) == 2)
        #expect(client.calls == 1, "neither started a turn beside the waiting follow-up")

        // The reprompt turn takes both as steers before its first model call.
        #expect(await eventually { client.calls >= 2 })
        let second = try #require(client.requests.dropFirst().first)
        let sent = second.contents.flatMap { $0.parts.compactMap(\.text) }
        #expect(sent.contains { $0.contains("Background subagent result: built") })
        #expect(sent.contains { $0.contains("also this") })
        await engine.cancelReprompt(for: id)
        app.clearGoal(for: id)
    }

    @Test("an arrival queued for a follow-up that never runs gets a turn of its own")
    func arrivalOutlivesACancelledFollowUp() async throws {
        let client = ScriptedStreamClient([
            [.event(.textDelta("working")), .event(.done(finishReason: nil))],
            [.event(.textDelta("acknowledged")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
        ])
        let (app, engine, id) = session(client, repromptDelay: 0.5)
        app.setGoal(for: id, goal: "do the thing")

        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(engine.goalLoopIsLive(for: id))
        await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id)
        #expect(app.pendingUserMessageCount(for: id) == 1)
        // The goal ends during the delay, so the reprompt wakes, finds nothing to continue, and exits.
        app.clearGoal(for: id)

        #expect(await eventually { client.calls == 2 && !app.hasTurnInFlight(for: id) && !engine.goalLoopIsLive(for: id) })
        #expect(app.pendingUserMessageCount(for: id) == 0)
        #expect(texts(app, id).contains { $0.contains("Background subagent result: built") })
        expectCallsAnswered(history(app, id))
    }

    /// From the #527 review: the end-of-turn drain runs while `processInput` still counts the turn
    /// in its goal loop, so holding arrivals on `isLive` there stranded one that landed during the
    /// turn's last model call.
    @Test("an arrival queued during an engine turn's last model call gets a turn when it ends",
          arguments: [false, true])
    func arrivalDuringLastRoundOfAnEngineTurn(peer: Bool) async throws {
        let open = OpenFlag()
        let client = ScriptedStreamClient([
            [.block({ while !open.isOpen { try? await Task.sleep(nanoseconds: 10_000_000) } }),
             .event(.textDelta("done")), .event(.done(finishReason: nil))],
            [.event(.textDelta("acknowledged")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
        ])
        let (app, engine, id) = session(client)
        let sender = UUID()
        app.createNewConversation(id: sender, select: false)
        app.selectedConversationId = id

        let turn = Task { await engine.processInput("System Event [Scheduler]: tick", source: "System", conversationId: id) }
        #expect(await eventually { client.calls == 1 })
        if peer {
            let envelope = PeerEnvelope(msgId: "eeee0478", contextId: "ctx-eeee0478", depth: 1, expectsReply: false, replyTo: nil)
            #expect(await engine.deliverPeerMessage("also this", from: sender, senderName: "peer", to: id, envelope: envelope) == .queued)
        } else {
            await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id)
        }
        #expect(app.pendingUserMessageCount(for: id) == 1, "queued behind the engine turn")
        open.open()
        _ = try await value(of: turn)

        #expect(await eventually { client.calls == 2 && !app.hasTurnInFlight(for: id) }, "the queued entry got a turn of its own")
        #expect(app.pendingUserMessageCount(for: id) == 0, "nothing left in the inbox")
    }

    /// Planner condition 2: a goal paused at a checkpoint schedules no follow-up, so a post-back
    /// is delivered at once instead of waiting for a person to act on the checkpoint.
    @Test("a post-back to a goal paused at a checkpoint is delivered, not held")
    func postBackToAPausedGoalIsDelivered() async throws {
        let client = ScriptedStreamClient([
            [.event(.textDelta("paused")), .event(.done(finishReason: nil))],
            [.event(.textDelta("acknowledged")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
        ])
        // A long delay: were a reprompt scheduled, it would still be pending when the post-back lands.
        let (app, engine, id) = session(client, repromptDelay: 30)
        let a = Criterion(text: "build", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "Ship", criteria: [a]))
        let idx = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[idx].goalContract?.checkpointStatus = .pausedForReview

        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(!engine.goalLoopIsLive(for: id), "a paused goal schedules no follow-up")
        await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id)
        #expect(app.pendingUserMessageCount(for: id) == 0, "delivered, not queued")
        #expect(client.calls == 2, "its own turn ran")
        await engine.cancelReprompt(for: id)
    }

    /// The taint is read at each tool call (`executeFunctionCall`), so a post-back read mid-turn
    /// gates job creation in the rest of that same turn, as it would in a turn of its own.
    @Test("a post-back read mid-turn gates job creation for the rest of that turn")
    func postBackSteerGatesJobCreation() async throws {
        let release = marker()
        defer { try? FileManager.default.removeItem(at: release) }
        let scheduleCall = FunctionCall(name: "schedule_job", args: ["prompt": .string("sweep"), "intervalSeconds": .int(60)], id: "c2")
        let client = ScriptedStreamClient([
            [.event(.functionCall(waitingCall(release))), .event(.done(finishReason: "tool_use"))],
            [.event(.functionCall(scheduleCall)), .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("ok")), .event(.done(finishReason: nil))],
            [.event(.textDelta("spare")), .event(.done(finishReason: nil))],
        ])
        let (app, engine, id) = session(client)
        // Not auto-approved, so `schedule_job`'s human-only gate is the thing under test.
        app.autoApproveTools = false
        app.sendMessage("start a turn")
        #expect(await eventually { app.pendingApprovals.contains { $0.toolName == "run_command" } || self.history(app, id).contains { $0.parts.contains { $0.functionCall != nil } } })
        #expect(app.conversations.first { $0.id == id }?.hasUnattendedInput == false)

        await engine.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: id)
        #expect(app.conversations.first { $0.id == id }?.hasUnattendedInput == true, "tainted on arrival, before the steer is read")
        FileManager.default.createFile(atPath: release.path, contents: nil)

        var sawSchedule = false
        for _ in 0..<200 {
            if let pending = app.pendingApprovals.first {
                if pending.toolName == "schedule_job" { sawSchedule = true }
                app.resolveApproval(id: pending.id, .approve)
            }
            if (try? app.store.ledger.jobs().count) == 1 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(sawSchedule, "job creation after a post-back steer must ask a human")
        #expect(await eventually { !app.hasTurnInFlight(for: id) && !app.isThinking })
        #expect(client.calls == 3, "one turn: the post-back was read inside it")
        expectCallsAnswered(history(app, id))
    }
}
