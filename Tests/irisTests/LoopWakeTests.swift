import Testing
import Foundation
@testable import IrisKit

/// #1423: does a peer message, a topic message or an Inbox answer wake a conversation with an armed `/loop`, or wait for
/// the next tick? Measured on a real engine (FakeLLMClient), per channel, for an interval loop and a self-paced one, idle
/// and with a tick running.
///
/// What decides it: `deliverPeerMessage` (peer and topic, which is a peer delivery with `envelope.topic`) and
/// `deliverInboxAnswerFrame` start the target's turn at once when `loop.isLive` and the turn claim say it's free, and
/// queue it otherwise. A waiting `/loop` tick lives on its own slot (`IrisEngine.loopTicks`), not the goal loop's, so it
/// holds nothing an arrival queues behind. The arrival's turn ends by re-arming the tick from then (`armLoopTick`, at the
/// end of every turn), so it takes the waiting tick's place rather than adding one.
@MainActor
@Suite("A looping conversation wakes on a peer, topic or Inbox message (#1423)", .timeLimit(.minutes(1)))
struct LoopWakeTests {
    enum Channel: String, CaseIterable { case peer, topic, inbox }

    private func app(latencyMs: Int = 0) throws -> (AppState, UUID, UUID) {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-1423-\(UUID().uuidString)")))
        let replies = (1...8).map { GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "reply \($0)")]))],
                                                   usageMetadata: nil) }
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: replies, latency: .init(minMs: latencyMs, maxMs: latencyMs)),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, repromptDelay: 0.01)
        state.installEngine(engine)
        let id = state.createNewConversation(isBackground: false, select: true)
        let sender = state.createNewConversation(isBackground: false, select: false)
        return (state, id, sender)
    }

    private func sent(_ state: AppState, _ id: UUID) -> [String] {
        (state.conversations.first { $0.id == id }?.history ?? []).filter { $0.role == "user" }.flatMap(\.parts).compactMap(\.text)
    }

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = TestClock.deadline(seconds)
        while TestClock.now() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func deliver(_ channel: Channel, _ marker: String, to id: UUID, from sender: UUID, engine: IrisEngine) async -> PeerDeliveryOutcome {
        switch channel {
        case .peer, .topic:
            var envelope = PeerEnvelope(msgId: "m-\(UUID().uuidString.prefix(8))", contextId: "c-\(marker)", depth: 1, expectsReply: false, replyTo: nil)
            if channel == .topic { envelope.topic = "board" }
            return await engine.deliverPeerMessage(marker, from: sender, senderName: "peer", to: id, envelope: envelope)
        case .inbox:
            return await engine.deliverInboxAnswerFrame("Inbox answer for item i-\(marker): \(marker)", tainted: false, to: id)
        }
    }

    @Test("idle: the arrival's turn runs at once, no tick runs for it, and the next tick is re-armed from its end",
          arguments: Channel.allCases, [false, true])
    func idleWakes(_ channel: Channel, _ selfPaced: Bool) async throws {
        let (state, id, sender) = try app()
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5, selfPaced: selfPaced), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        let before = try #require(state.loopNextTick[id])
        let marker = "wake-\(channel.rawValue)-\(selfPaced)"
        let outcome = await deliver(channel, marker, to: id, from: sender, engine: engine)
        #expect(outcome == .delivered, "\(channel): delivered at once, not queued for the tick")
        #expect(await eventually { sent(state, id).contains { $0.contains(marker) } }, "\(channel): its turn ran")
        #expect(!sent(state, id).contains { $0.hasPrefix("Loop tick") }, "\(channel): no tick ran for it")
        #expect(await eventually { !state.isThinking(in: id) && (state.loopNextTick[id].map { $0 > before } ?? false) },
                "\(channel): the next tick is re-armed from the arrival's end, a full interval later")
        #expect(await engine.hasLoopTick(for: id), "\(channel): one tick waits, not two")
        state.pauseLoop(for: id)
    }

    @Test("during a running tick: the arrival queues, runs right after the tick's turn, and no second tick runs",
          arguments: Channel.allCases)
    func busyQueuesBehindTheTick(_ channel: Channel) async throws {
        let (state, id, sender) = try app(latencyMs: 800)
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, selfPaced: true), in: id)
        // A self-paced loop's first tick comes at its first interval; take it now instead, as the timer would.
        let loop = try #require(state.conversations.first { $0.id == id }?.loop)
        guard case .run(let tick) = state.takeLoopTick(for: id, loopId: loop.id) else { Issue.record("no tick"); return }
        let tickTask = Task { await engine.processInput(tick, source: IrisEngine.loopSource, conversationId: id) }
        #expect(await eventually { state.isThinking(in: id) })
        let marker = "busy-\(channel.rawValue)"
        #expect(await deliver(channel, marker, to: id, from: sender, engine: engine) == .queued, "\(channel): queued behind the tick")
        try await value(of: tickTask, within: 20)
        state.endEngineTurn(for: id)
        #expect(await eventually(20) { sent(state, id).contains { $0.contains(marker) } }, "\(channel): ran after the tick")
        let ticks = sent(state, id).filter { $0.hasPrefix("Loop tick") }.count
        #expect(ticks == 1, "\(channel): one tick, not a second for the arrival")
        state.pauseLoop(for: id)
    }
}
