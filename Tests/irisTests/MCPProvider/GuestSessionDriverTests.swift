import Testing
import Foundation
@testable import IrisKit

/// #1066 Phase 2, Task 8: the guest driver. A fake turn runner stands in for the model; what is
/// under test is who is admitted, which turn runs, and where the reply goes.
@MainActor
@Suite("Guest session driver (#1066)", .timeLimit(.minutes(2)))
struct GuestSessionDriverTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = SuspendingClock().now
        var now: SuspendingClock.Instant { lock.withLock { instant } }
        func advance(_ d: Duration) { lock.withLock { instant = instant.advanced(by: d) } }
    }

    /// Wall time for the ledger's UTC day, moved by hand.
    private final class WallClock: @unchecked Sendable {
        private let lock = NSLock()
        // 2026-11-14 23:00:00 UTC
        private var date = Date(timeIntervalSince1970: 1_794_870_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private actor Latch {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            for w in waiters { w.resume() }
            waiters = []
        }
    }

    /// What the fake runner does, and what it saw.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [String] = []
        private var _reply: String? = "an answer"
        var latch: Latch?
        var reply: String? {
            get { lock.withLock { _reply } }
            set { lock.withLock { _reply = newValue } }
        }
        var texts: [String] { lock.withLock { _texts } }
        func saw(_ text: String) { lock.withLock { _texts.append(text) } }
    }

    private struct Rig {
        let app: AppState
        let clock: Clock
        let gateClock: Clock
        let wall: WallClock
        let tokens: ProviderTokenRegistry
        let mailbox: ProviderMailbox
        let sessions: GuestSessionRegistry
        let gate: ProviderRequestGate
        let script: Script
        let driver: GuestSessionDriver
        let enabled: Flag
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _on = true
        var on: Bool { get { lock.withLock { _on } } set { lock.withLock { _on = newValue } } }
    }

    private func rig(enabled: Bool = true, ttl: Duration = .seconds(900), maxLive: Int = 4,
                     turnTimeout: Double = 30, clients: [String] = ["dev-1"], dailyCap: Int? = nil) throws -> Rig {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let clock = Clock(), gateClock = Clock(), wall = WallClock()
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let tokens = ProviderTokenRegistry(keychain: keychain)
        for c in clients { _ = try tokens.issueToken(forClientId: c) }
        let mailbox = ProviderMailbox(registry: tokens)
        let sessions = GuestSessionRegistry(state: app, ttl: ttl, maxLive: maxLive, now: { clock.now }) { s, c in
            IrisEngine.makeGuestEngine(state: s, clientId: c, client: CapturingLLMClient(reply: "unused"), protectionEnabled: false)
        }
        let gate = ProviderRequestGate(registry: tokens, capacity: GuestSessionDriver.turnsPerHour,
                                       refillInterval: GuestSessionDriver.turnRefillInterval, now: { gateClock.now })
        let script = Script()
        let flag = Flag()
        flag.on = enabled
        let spend = GuestSpendLedger(now: { wall.now })
        // A nil `dailyCap` leaves the driver's own default, so a test can pin the named constant.
        let driver = dailyCap.map {
            GuestSessionDriver(
                state: app, registry: sessions, mailbox: mailbox, turnGate: gate, isEnabled: { flag.on }, turnTimeout: turnTimeout,
                dailyCap: $0, spend: spend, runTurn: Self.fakeTurn(app, script))
        } ?? GuestSessionDriver(
            state: app, registry: sessions, mailbox: mailbox, turnGate: gate, isEnabled: { flag.on }, turnTimeout: turnTimeout,
            spend: spend, runTurn: Self.fakeTurn(app, script))
        return Rig(app: app, clock: clock, gateClock: gateClock, wall: wall, tokens: tokens, mailbox: mailbox, sessions: sessions,
                   gate: gate, script: script, driver: driver, enabled: flag)
    }

    private static func fakeTurn(_ app: AppState, _ script: Script) -> GuestSessionDriver.TurnRunner {
        { [script] conversationId, text, _, sink in
            script.saw(text)
            await MainActor.run { app.beginEngineTurn(for: conversationId) }
            await script.latch?.wait()
            if let reply = script.reply {
                await MainActor.run { app.appendMessage(role: .agent, content: reply, to: conversationId) }
            }
            await sink.record(TokenUsage(promptTokenCount: 60, candidatesTokenCount: 40, totalTokenCount: 100))
            await MainActor.run { app.endEngineTurn(for: conversationId) }
        }
    }

    private func finish(_ r: Rig, _ client: String) async throws {
        if let task = r.driver.turnTask(for: client) { try await value(of: task, within: 20) }
    }

    private func replies(_ r: Rig, _ client: String) async -> [ProviderMailbox.Message] {
        await r.mailbox.poll(for: client, sinceSequence: nil)
    }

    // MARK: the gate overload

    @Test("admit(clientId:) charges a registered client and refuses one that is not registered, without charging")
    func admitByClientId() async throws {
        let r = try rig()
        #expect(await r.gate.admit(clientId: "dev-1") == .admitted(clientId: "dev-1"))
        // Revoked between the request gate resolving its token and this gate.
        try r.tokens.revokeToken(forClientId: "dev-1")
        #expect(await r.gate.admit(clientId: "dev-1") == .unauthorized)
        #expect(await r.gate.admit(clientId: "never-issued") == .unauthorized)
    }

    @Test("forget(clientId:) closes the session and clears the turns bucket: a re-issued id starts with a full one")
    func forgetClearsTheBucketAndSession() async throws {
        let r = try rig()
        for _ in 0..<GuestSessionDriver.turnsPerHour { _ = await r.gate.admit(clientId: "dev-1") }
        #expect(await r.gate.admit(clientId: "dev-1") == .budgetExceeded)
        _ = try r.sessions.session(for: "dev-1")
        try r.tokens.revokeToken(forClientId: "dev-1")
        await r.driver.forget(clientId: "dev-1")
        #expect(r.sessions.liveCount == 0)
        _ = try r.tokens.issueToken(forClientId: "dev-1")
        for i in 0..<GuestSessionDriver.turnsPerHour {
            #expect(await r.gate.admit(clientId: "dev-1") == .admitted(clientId: "dev-1"), "turn \(i) of the new bucket")
        }
    }

    @Test("an idle reap keeps the turns bucket, so waiting out the TTL does not reset the hourly limit")
    func reapKeepsTheBucket() async throws {
        let r = try rig(ttl: .seconds(10))
        for _ in 0..<GuestSessionDriver.turnsPerHour { _ = await r.gate.admit(clientId: "dev-1") }
        _ = try r.sessions.session(for: "dev-1")
        r.clock.advance(.seconds(60))
        r.sessions.reapIdle()
        #expect(r.sessions.liveCount == 0)
        #expect(await r.driver.submit(text: "again", from: "dev-1") == .rateLimited)
    }

    // MARK: flag off, flag on

    @Test("with the flag off, submit starts nothing and creates no session")
    func flagOff() async throws {
        let r = try rig(enabled: false)
        #expect(await r.driver.submit(text: "hello", from: "dev-1") == .disabled)
        #expect(r.sessions.liveCount == 0 && r.script.texts.isEmpty)
        #expect(await replies(r, "dev-1").isEmpty)
    }

    @Test("with the flag on, submit creates the session, runs one turn, and files the final reply for that client")
    func flagOnRunsOneTurn() async throws {
        let r = try rig()
        let result = await r.driver.submit(text: "hello", from: "dev-1")
        guard case .accepted = result else { Issue.record("not accepted: \(result)"); return }
        try await finish(r, "dev-1")
        #expect(r.script.texts == ["hello"])
        #expect(r.sessions.liveCount == 1)
        let mine = await replies(r, "dev-1")
        #expect(mine.count == 1)
        #expect(mine.first?.text == "an answer" && mine.first?.from == .iris && mine.first?.sequence == 1)
    }

    @Test("a reply goes to the client that sent, never to another registered client")
    func replyGoesToTheSender() async throws {
        let r = try rig(clients: ["dev-1", "dev-2"])
        _ = await r.driver.submit(text: "hello", from: "dev-1")
        try await finish(r, "dev-1")
        #expect(await replies(r, "dev-1").count == 1)
        #expect(await replies(r, "dev-2").isEmpty)
    }

    @Test("the reserved client id is never admitted and never gets a session")
    func reservedIdIsNeverAGuest() async throws {
        let r = try rig()
        let result = await r.driver.submit(text: "hi", from: ProviderTokenRegistry.reservedClientId)
        #expect(result == .disabled)
        #expect(r.sessions.liveCount == 0 && r.script.texts.isEmpty)
    }

    // MARK: the turns-per-hour gate

    @Test("the 13th turn in an hour is rateLimited and starts no turn; five minutes later one more is allowed")
    func thirteenthIsRateLimited() async throws {
        let r = try rig()
        for i in 1...GuestSessionDriver.turnsPerHour {
            guard case .accepted = await r.driver.submit(text: "m\(i)", from: "dev-1") else { Issue.record("turn \(i) refused"); return }
            try await finish(r, "dev-1")
        }
        #expect(await r.driver.submit(text: "one too many", from: "dev-1") == .rateLimited)
        #expect(r.script.texts.count == GuestSessionDriver.turnsPerHour && !r.script.texts.contains("one too many"))
        r.gateClock.advance(GuestSessionDriver.turnRefillInterval)
        guard case .accepted = await r.driver.submit(text: "after the refill", from: "dev-1") else { Issue.record("refill did not admit"); return }
        try await finish(r, "dev-1")
    }

    // MARK: the daily token cap (#1135)

    @Test("the daily cap is the named constant: one token under is admitted, at the cap is refused")
    func dailyCapIsTheConstant() async throws {
        let r = try rig()
        await r.driver.spend.add(GuestSessionDriver.dailyTokenCap - 1, for: "dev-1")
        guard case .accepted = await r.driver.submit(text: "under", from: "dev-1") else { Issue.record("under the cap was refused"); return }
        try await finish(r, "dev-1")           // the turn adds 100 more, past the cap
        #expect(await r.driver.submit(text: "over", from: "dev-1") == .overDailyBudget)
        #expect(r.script.texts == ["under"])
    }

    @Test("an over-cap client gets no session and no turn, and the refusal does not spend an hourly turn")
    func overCapStartsNothing() async throws {
        let r = try rig()
        await r.driver.spend.add(GuestSessionDriver.dailyTokenCap, for: "dev-1")
        #expect(await r.driver.submit(text: "no", from: "dev-1") == .overDailyBudget)
        #expect(r.sessions.liveCount == 0 && r.script.texts.isEmpty)
        #expect(await replies(r, "dev-1").isEmpty)
        // All twelve of this hour's turns are still there: the refusal came before the turns gate.
        for i in 0..<GuestSessionDriver.turnsPerHour {
            #expect(await r.gate.admit(clientId: "dev-1") == .admitted(clientId: "dev-1"), "turn \(i)")
        }
    }

    @Test("turns add up toward the cap: three 100-token turns pass a 250 cap, the fourth is refused")
    func turnsAccumulate() async throws {
        let r = try rig(dailyCap: 250)
        for i in 1...3 {
            guard case .accepted = await r.driver.submit(text: "m\(i)", from: "dev-1") else { Issue.record("turn \(i) refused"); return }
            try await finish(r, "dev-1")
        }
        #expect(await r.driver.spend.todayTotal(for: "dev-1") == 300)
        #expect(await r.driver.submit(text: "m4", from: "dev-1") == .overDailyBudget)
        #expect(r.script.texts == ["m1", "m2", "m3"])
    }

    @Test("one client's cap does not refuse another client")
    func capIsPerClient() async throws {
        let r = try rig(clients: ["dev-1", "dev-2"])
        await r.driver.spend.add(GuestSessionDriver.dailyTokenCap, for: "dev-1")
        #expect(await r.driver.submit(text: "no", from: "dev-1") == .overDailyBudget)
        guard case .accepted = await r.driver.submit(text: "yes", from: "dev-2") else { Issue.record("dev-2 refused"); return }
        try await finish(r, "dev-2")
    }

    @Test("the count restarts at 00:00 UTC, not 24 hours after the first spend")
    func dayRollover() async throws {
        let r = try rig()          // the wall clock starts at 23:00 UTC
        await r.driver.spend.add(GuestSessionDriver.dailyTokenCap, for: "dev-1")
        r.wall.advance(59 * 60)    // 23:59
        #expect(await r.driver.submit(text: "still today", from: "dev-1") == .overDailyBudget)
        r.wall.advance(2 * 60)     // 00:01 the next day, only 61 minutes after the spend
        guard case .accepted = await r.driver.submit(text: "new day", from: "dev-1") else { Issue.record("not admitted after midnight"); return }
        try await finish(r, "dev-1")
        #expect(await r.driver.spend.todayTotal(for: "dev-1") == 100 && r.script.texts == ["new day"])
        #expect(await r.driver.spend.total(for: "dev-1") == GuestSessionDriver.dailyTokenCap + 100, "the lifetime tally is not reset")
    }

    @Test("revoking and re-issuing a client does not reset its day's count")
    func revokeKeepsTheDayCount() async throws {
        let r = try rig()
        await r.driver.spend.add(GuestSessionDriver.dailyTokenCap, for: "dev-1")
        try r.tokens.revokeToken(forClientId: "dev-1")
        await r.driver.forget(clientId: "dev-1")
        _ = try r.tokens.issueToken(forClientId: "dev-1")
        #expect(await r.driver.submit(text: "again", from: "dev-1") == .overDailyBudget)
    }

    // MARK: busy

    @Test("a full registry is busy for a new client, creates no session and starts no turn; an existing client is still served")
    func fullRegistryIsBusy() async throws {
        let r = try rig(maxLive: 2, clients: ["a", "b", "c"])
        _ = try r.sessions.session(for: "a")
        _ = try r.sessions.session(for: "b")
        #expect(await r.driver.submit(text: "hi", from: "c") == .busy)
        #expect(r.sessions.liveCount == 2 && r.script.texts.isEmpty)
        guard case .accepted = await r.driver.submit(text: "hi", from: "a") else { Issue.record("existing client refused"); return }
        try await finish(r, "a")
    }

    @Test("a second message from a client whose turn is still running is busy, not a second turn")
    func secondWhileRunningIsBusy() async throws {
        let r = try rig()
        let latch = Latch()
        r.script.latch = latch
        guard case .accepted = await r.driver.submit(text: "first", from: "dev-1") else { Issue.record("first refused"); return }
        #expect(await r.driver.submit(text: "second", from: "dev-1") == .busy)
        await latch.open()
        try await finish(r, "dev-1")
        #expect(r.script.texts == ["first"])
        // The refused attempt spent no turn: the answer to the first is the only reply.
        #expect(await replies(r, "dev-1").count == 1)
        guard case .accepted = await r.driver.submit(text: "third", from: "dev-1") else { Issue.record("not free after the turn"); return }
        try await finish(r, "dev-1")
    }

    // MARK: failure is a reply, not silence

    @Test("a turn that adds no agent message files a short failure reply")
    func noAnswerIsAFailureReply() async throws {
        let r = try rig()
        r.script.reply = nil
        _ = await r.driver.submit(text: "hello", from: "dev-1")
        try await finish(r, "dev-1")
        #expect(await replies(r, "dev-1").map(\.text) == [GuestSessionDriver.failureReply])
    }

    @Test("a turn past its bound files the failure reply and closes the session")
    func timeoutIsAFailureReply() async throws {
        let r = try rig(turnTimeout: 0.2)
        r.script.latch = Latch()   // never opened: the turn hangs
        _ = await r.driver.submit(text: "hello", from: "dev-1")
        try await finish(r, "dev-1")
        #expect(await replies(r, "dev-1").map(\.text) == [GuestSessionDriver.failureReply])
        #expect(r.sessions.liveCount == 0, "the abandoned turn's conversation is deleted, ending its spend")
    }

    @Test("a reply longer than the mailbox accepts is cut to fit, not dropped")
    func longReplyIsClamped() async throws {
        let r = try rig()
        r.script.reply = String(repeating: "é", count: ProviderMailbox.maxTextBytes)   // 2 bytes each
        _ = await r.driver.submit(text: "hello", from: "dev-1")
        try await finish(r, "dev-1")
        let text = try #require(await replies(r, "dev-1").first?.text)
        #expect(text.utf8.count <= ProviderMailbox.maxTextBytes && text.utf8.count > ProviderMailbox.maxTextBytes - 2)
        #expect(!text.contains("\u{FFFD}"))
    }

    // MARK: revoke mid-turn

    @Test("a client revoked while its turn runs is never sent the reply; a client that is not revoked is")
    func revokedMidTurnGetsNothing() async throws {
        let r = try rig(clients: ["dev-1", "dev-2"])
        let latch = Latch()
        r.script.latch = latch
        _ = await r.driver.submit(text: "one", from: "dev-1")
        _ = await r.driver.submit(text: "two", from: "dev-2")
        try r.tokens.revokeToken(forClientId: "dev-1")
        r.sessions.close(clientId: "dev-1")
        await latch.open()
        try await finish(r, "dev-1")
        try await finish(r, "dev-2")
        #expect(await replies(r, "dev-1").isEmpty, "a revoked id gets no reply, not even a failure one")
        #expect(await replies(r, "dev-2").map(\.text) == ["an answer"], "control: the same flow delivers to a live client")
    }

    // MARK: the session clock

    @Test("a session is not reaped mid-turn however long the turn runs, and its TTL restarts when the turn ends")
    func touchAtTurnEnd() async throws {
        let r = try rig(ttl: .seconds(900))
        let latch = Latch()
        r.script.latch = latch
        _ = await r.driver.submit(text: "long", from: "dev-1")
        let script = r.script
        #expect(await polled(within: 10) { script.texts.count == 1 })
        r.clock.advance(.seconds(1000))
        r.sessions.reapIdle()
        #expect(r.sessions.liveCount == 1, "a turn is running")
        await latch.open()
        try await finish(r, "dev-1")
        r.sessions.reapIdle()
        #expect(r.sessions.liveCount == 1, "the turn just ended: its idle time starts now, not when it began")
        r.clock.advance(.seconds(800))
        r.sessions.reapIdle()
        #expect(r.sessions.liveCount == 1, "800 s after the turn is inside the 900 s TTL")
        r.clock.advance(.seconds(200))
        r.sessions.reapIdle()
        #expect(r.sessions.liveCount == 0)
    }

    // MARK: spend

    @Test("a turn's tokens are tallied against its client and the tally outlives the session")
    func spendSurvivesTheSession() async throws {
        let r = try rig()
        _ = await r.driver.submit(text: "hello", from: "dev-1")
        try await finish(r, "dev-1")
        #expect(await r.driver.spend.total(for: "dev-1") == 100)
        r.sessions.close(clientId: "dev-1")
        #expect(await r.driver.spend.total(for: "dev-1") == 100)
        #expect(await r.driver.spend.total(for: "dev-2") == 0)
    }

    // MARK: production wiring (nothing injected)

    @Test("a driver with the default flag reader is inactive in a process that never turned the setting on")
    func defaultFlagIsOff() async throws {
        let r = try rig()
        let driver = GuestSessionDriver(state: r.app, registry: r.sessions, mailbox: r.mailbox, turnGate: r.gate)
        #expect(!driver.isActive)
        #expect(await driver.submit(text: "hello", from: "dev-1") == .disabled)
        #expect(r.sessions.liveCount == 0)
    }

    @Test("the default turn runner reaches the guest's own engine: a real turn's final message is the reply")
    func defaultRunnerRunsARealTurn() async throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let tokens = ProviderTokenRegistry(keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true))
        _ = try tokens.issueToken(forClientId: "dev-1")
        let mailbox = ProviderMailbox(registry: tokens)
        let sessions = GuestSessionRegistry(state: app) { s, c in
            IrisEngine.makeGuestEngine(state: s, clientId: c, client: CapturingLLMClient(reply: "hi from the engine"), protectionEnabled: false)
        }
        let gate = ProviderRequestGate(registry: tokens, capacity: GuestSessionDriver.turnsPerHour, refillInterval: GuestSessionDriver.turnRefillInterval)
        let driver = GuestSessionDriver(state: app, registry: sessions, mailbox: mailbox, turnGate: gate, isEnabled: { true })
        guard case .accepted = await driver.submit(text: "hello", from: "dev-1") else { Issue.record("not accepted"); return }
        try await value(of: try #require(driver.turnTask(for: "dev-1")), within: 30)
        #expect(await mailbox.poll(for: "dev-1", sinceSequence: nil).map(\.text) == ["hi from the engine"])
    }

    // MARK: the stored message

    @Test("the stored client message is retracted when its turn ends, so sends never fill the client's allowance")
    func storedMessageIsRetracted() async throws {
        let r = try rig()
        let stored = try await r.mailbox.send(from: "dev-1", text: "hello", fileRefs: [])
        _ = await r.driver.submit(text: "hello", from: "dev-1", storedMessageId: stored.id)
        try await finish(r, "dev-1")
        // The whole allowance is still free: a left-behind message would make the last one inboxFull.
        for i in 0..<ProviderMailbox.maxPendingPerClient { _ = try await r.mailbox.send(from: "dev-1", text: "m\(i)", fileRefs: []) }
    }

    // MARK: sources

    @Test("deliverReply( is called only from GuestSessionDriver.swift and ProviderMailbox.swift, and the driver never names the reserved id")
    func deliverReplyCallSites() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var callers: Set<String> = []
        for sub in ["IrisKit", "iris"] {
            guard let walk = FileManager.default.enumerator(at: sources.appendingPathComponent(sub), includingPropertiesForKeys: nil) else { continue }
            while let url = walk.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("deliverReply(") { callers.insert(url.lastPathComponent) }
            }
        }
        #expect(callers == ["GuestSessionDriver.swift", "ProviderMailbox.swift"])
        for file in ["GuestSessionDriver.swift", "GuestSessionRegistry.swift"] {
            let url = sources.appendingPathComponent("IrisKit/MCPProvider/\(file)")
            #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("reservedClientId"), "\(file)")
        }
    }
}
