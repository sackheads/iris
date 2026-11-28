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
/// holds nothing an arrival queues behind. The arrival's turn ends by arming the tick again (`armLoopTick`, at the end of
/// every turn), which keeps the waiting tick and its due time (`AppState.loopDue`): an arrival never moves the next tick.
@MainActor
@Suite("A looping conversation wakes on a peer, topic or Inbox message (#1423)", .timeLimit(.minutes(1)))
struct LoopWakeTests {
    enum Channel: String, CaseIterable { case peer, topic, inbox }

    private func app(latencyMs: Int = 0) throws -> (AppState, UUID, UUID) {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-1423-\(UUID().uuidString)")))
        state.loopRestSeconds = 0   // the rows that pin the rest set their own
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

    @Test("idle: the arrival's turn runs at once, no tick runs for it, and the waiting tick keeps its due time",
          arguments: Channel.allCases, [false, true])
    func idleWakes(_ channel: Channel, _ selfPaced: Bool) async throws {
        let (state, id, sender) = try app(latencyMs: 200)
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5, selfPaced: selfPaced), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        let before = try #require(state.loopNextTick[id])
        let marker = "wake-\(channel.rawValue)-\(selfPaced)"
        let outcome = await deliver(channel, marker, to: id, from: sender, engine: engine)
        #expect(outcome == .delivered, "\(channel): delivered at once, not queued for the tick")
        #expect(await eventually { sent(state, id).contains { $0.contains(marker) } }, "\(channel): its turn ran")
        #expect(!sent(state, id).contains { $0.hasPrefix("Loop tick") }, "\(channel): no tick ran for it")
        // The arrival's turn cancels the waiting tick as it starts (#190); its end arms it again, at the same due time.
        #expect(await eventually { !state.isThinking(in: id) && state.loopNextTick[id] != nil })
        #expect(state.loopNextTick[id].map { abs($0.timeIntervalSince(before)) < 0.05 } ?? false, "\(channel): the arrival didn't move the next tick")
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

    /// #1423 (planner's ruling): a turn between ticks never moves the next one, so a chatty conversation still loops.
    @Test("an arrival keeps an interval loop's due time: three arrivals, and the next tick hasn't moved")
    // Each turn takes 200 ms, so re-arming from a turn's end would move the tick by more than the 50 ms the chip's
    // recomputed date is compared within.
    func arrivalsKeepTheDueTime() async throws {
        let (state, id, sender) = try app(latencyMs: 200)
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        let due = try #require(state.loopNextTick[id])
        for n in 1...3 {
            let marker = "chatty-\(n)"
            #expect(await deliver(.peer, marker, to: id, from: sender, engine: engine) == .delivered)
            #expect(await eventually { sent(state, id).contains { $0.contains(marker) } && !state.isThinking(in: id) && state.loopNextTick[id] != nil })
            #expect(state.loopNextTick[id].map { abs($0.timeIntervalSince(due)) < 0.05 } ?? false, "arrival \(n) left the tick where it was")
        }
        #expect(await engine.hasLoopTick(for: id))
        state.pauseLoop(for: id)
    }

    @Test("a chatty peer, an arrival every quarter interval, still gets a tick every interval")
    func chattyPeerStillTicks() async throws {
        let (state, id, sender) = try app()
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 1, cap: 20), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        let start = TestClock.now()
        var n = 0
        while TestClock.seconds(since: start) < 4.2 {
            n += 1
            _ = await deliver(.peer, "chatty-\(n)", to: id, from: sender, engine: engine)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let ticks = sent(state, id).filter { $0.hasPrefix("Loop tick") }.count
        #expect(ticks >= 3, "\(ticks) ticks in ~4 s at a 1 s interval with \(n) arrivals; before #1423 an arrival every 0.25 s left none")
        #expect(ticks <= 5, "no more than one tick per interval")
        state.pauseLoop(for: id)
    }

    /// Tick start times in `id` over `seconds`, sampled every 50 ms.
    private func tickStarts(_ state: AppState, _ id: UUID, over seconds: Double) async -> [Double] {
        var starts: [Double] = []
        let start = TestClock.now()
        var seen = 0
        while TestClock.seconds(since: start) < seconds {
            let count = sent(state, id).filter { $0.hasPrefix("Loop tick") }.count
            if count > seen { starts.append(TestClock.seconds(since: start)); seen = count }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return starts
    }

    @Test("at the production rest, a short interval's next tick is due a minute after the tick ENDS; a long one's an interval after it began")
    func productionRestIsAMinute() async throws {
        // A fresh state, its rest untouched: the helpers above zero it for their fast loops (dev-3's #1458 review).
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        #expect(state.loopRestSeconds == 60)
        // 1 s is below `/loop`'s shortest interval (60 s) on purpose, built directly rather than parsed: at 60 the start
        // and end anchors coincide, and this row exists to tell them apart.
        for (interval, restWins) in [(1.0, true), (3600.0, false)] {
            let id = state.createNewConversation(isBackground: false, select: false)
            let loop = ConversationLoop(prompt: "p", intervalSeconds: interval, cap: 5)
            state.startLoop(loop, in: id)
            // The start's own arm runs on a task; let it land first, or it takes the tick-start record mid-turn.
            #expect(await eventually { state.loopNextTick[id] != nil })
            let started = SuspendingClock().now
            guard case .run = state.takeLoopTick(for: id, loopId: loop.id) else { Issue.record("no tick"); return }
            // The tick's turn lasts a measurable while, so a rest anchored at its start would show.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let ended = SuspendingClock().now
            state.endEngineTurn(for: id)
            let fire = state.loopFireTime(for: id, loop: loop, delay: interval)
            // One-sided where a late reading could only help (dev-3's review): nothing suspends between `ended` and the
            // code's own clock reading today, but a later edit might.
            if restWins {
                #expect(fire >= ended + .seconds(60), "due at least 60 s after the tick ended")
                #expect(fire > started + .seconds(60.3), "not 60 s after it began")
                #expect(fire <= ended + .seconds(70))
            } else {
                #expect(fire <= started + .seconds(3600.5), "due an interval after the tick began")
                #expect(fire < ended + .seconds(3600), "the rest doesn't add to it")
            }
            state.pauseLoop(for: id)
        }
    }

    @Test("a tick that outlasts its interval rests the minimum after it ends: never back to back")
    func slowTicksRest() async throws {
        // `/loop 1m` with 90 s ticks and a 60 s rest, scaled: a 1 s interval, 1.5 s ticks, a 1 s rest. Ticks ~2.5 s apart.
        let (state, id, _) = try app(latencyMs: 1500)
        state.loopRestSeconds = 1
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 1, cap: 20), in: id)
        let starts = await tickStarts(state, id, over: 9)
        #expect(starts.count >= 2, "ticks ran: \(starts)")
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 2.2 }, "each tick began at least the rest after the last one ended: gaps \(gaps)")
        state.pauseLoop(for: id)
    }

    @Test("a tick shorter than its interval keeps the cadence start to start, the rest not adding to it")
    func shortTicksKeepCadence() async throws {
        // `/loop 20m` with 2-minute ticks, scaled: a 2 s interval, 0.5 s ticks, a 0.5 s rest. Starts 2 s apart, not 2.5.
        let (state, id, _) = try app(latencyMs: 500)
        state.loopRestSeconds = 0.5
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 2, cap: 20), in: id)
        let starts = await tickStarts(state, id, over: 7.5)
        #expect(starts.count >= 3, "ticks ran: \(starts)")
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 1.8 && $0 < 2.3 }, "start to start is the interval: gaps \(gaps)")
        state.pauseLoop(for: id)
    }

    @Test("a busy turn spanning the due time gives exactly one tick, right after it")
    func busyTurnGivesOneTick() async throws {
        let (state, id, sender) = try app(latencyMs: 2500)
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 0.5, cap: 20), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        // One long turn: the due time (0.5 s) and several more intervals pass while it runs.
        #expect(await deliver(.peer, "long-turn", to: id, from: sender, engine: engine) == .delivered)
        #expect(await eventually { state.isThinking(in: id) })
        #expect(await eventually(10) { !state.isThinking(in: id) || sent(state, id).contains { $0.hasPrefix("Loop tick") } })
        let ended = TestClock.now()
        #expect(await eventually(5) { sent(state, id).contains { $0.hasPrefix("Loop tick") } }, "the missed tick runs after the turn")
        #expect(TestClock.seconds(since: ended) < 2, "right after it, not at the 30 s busy retry")
        // The tick's own turn takes 2.5 s; nothing else may start beside or before it.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(sent(state, id).filter { $0.hasPrefix("Loop tick") }.count == 1, "one tick, no catch-up burst for the missed ones")
        let texts = sent(state, id)
        let turn = try #require(texts.firstIndex { $0.contains("long-turn") })
        let tick = try #require(texts.firstIndex { $0.hasPrefix("Loop tick") })
        #expect(turn < tick, "no tick ran during the busy turn")
        state.pauseLoop(for: id)
    }

    @Test("a self-paced loop's wake survives an arrival, and a turn that reschedules moves it")
    func selfPacedWakeSurvives() async throws {
        let (state, id, sender) = try app(latencyMs: 200)
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5, selfPaced: true), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        let wake = try #require(state.loopNextTick[id])
        #expect(await deliver(.inbox, "arrival", to: id, from: sender, engine: engine) == .delivered)
        #expect(await eventually { sent(state, id).contains { $0.contains("arrival") } && !state.isThinking(in: id) && state.loopNextTick[id] != nil })
        #expect(state.loopNextTick[id].map { abs($0.timeIntervalSince(wake)) < 0.05 } ?? false, "the arrival kept the wake")
        _ = state.scheduleNextLoopTick(for: id, requested: 120)
        #expect(await deliver(.peer, "rescheduled", to: id, from: sender, engine: engine) == .delivered)
        #expect(await eventually { state.loopNextTick[id].map { $0 < wake.addingTimeInterval(-3000) } ?? false },
                "a reschedule moves it to what was asked for")
        state.pauseLoop(for: id)
    }
}
