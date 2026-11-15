import Foundation

/// What `GuestSessionDriver.submit` decided about one `iris_send`.
enum GuestSubmitResult: Equatable, Sendable {
    /// A turn was started; its reply arrives later through the mailbox, by `iris_poll`.
    case accepted(messageId: UUID)
    /// No turn: every guest slot is taken, or this client's previous turn is still running.
    /// Refused to the client as a tool error, never queued.
    case busy
    /// No turn: this client has used its turns for the hour.
    case rateLimited
    /// No turn: this client has spent its token budget for the UTC day (#1135).
    case overDailyBudget
    /// No turn: guest sessions are off (or the client is no longer registered). The caller keeps
    /// the Phase 1 behaviour: the message sits in the mailbox.
    case disabled
}

/// What guest turns have spent, per client, in tokens. The guest conversation is deleted when its
/// session is reaped and is never persisted, so a figure kept on it would go with it; this tally
/// is the one place a reaped guest's spend survives (memory only: a restart starts it empty).
///
/// Besides the running total it keeps today's total, by UTC day, which the driver reads to refuse a
/// client that has used its daily budget (#1135). A day is `floor(unix time / 86400)`, so the
/// count restarts at 00:00 UTC without a timer.
actor GuestSpendLedger {
    private var totals: [String: Int] = [:]
    private var daily: [String: (day: Int, tokens: Int)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    private func today() -> Int { Int((now().timeIntervalSince1970 / 86_400).rounded(.down)) }

    func add(_ tokens: Int, for clientId: String) {
        guard tokens > 0 else { return }
        totals[clientId, default: 0] += tokens
        let day = today()
        // Entries from an earlier day are dead weight: drop them as the day turns.
        daily = daily.filter { $0.value.day == day }
        daily[clientId] = (day, (daily[clientId]?.tokens ?? 0) + tokens)
    }

    func total(for clientId: String) -> Int { totals[clientId] ?? 0 }

    /// What `clientId` has spent so far this UTC day.
    func todayTotal(for clientId: String) -> Int {
        guard let entry = daily[clientId], entry.day == today() else { return 0 }
        return entry.tokens
    }
}

/// Feeds one turn's running usage into the ledger. `record` is absolute (the turn's total so far),
/// so only the growth since the last report is added.
final class GuestSpendSink: TurnUsageSink, @unchecked Sendable {
    private let clientId: String
    private let ledger: GuestSpendLedger
    private let lock = NSLock()
    private var reported = 0

    init(clientId: String, ledger: GuestSpendLedger) {
        self.clientId = clientId
        self.ledger = ledger
    }

    func record(_ tokens: TokenUsage) async {
        let delta: Int = lock.withLock {
            let growth = tokens.totalTokenCount - reported
            if growth > 0 { reported = tokens.totalTokenCount }
            return max(0, growth)
        }
        await ledger.add(delta, for: clientId)
    }
}

/// #1066 Phase 2, Task 8: runs an external MCP client's `iris_send` as one model turn in its guest
/// session and files the final reply in the mailbox. The only caller of
/// `ProviderMailbox.deliverReply` besides the mailbox itself.
@MainActor
final class GuestSessionDriver {
    /// Turns one client may start per hour: a bucket of this size that refills one per
    /// `turnRefillInterval`. D4, in one place for the owner to tune.
    static let turnsPerHour = 12
    static let turnRefillInterval: Duration = .seconds(300)
    /// The weighted-token ceiling and the wall-clock bound of one guest turn. D5.
    static let turnMaxTokens = 30_000
    static let turnTimeoutSeconds: Double = 180
    /// The most one client may spend in a UTC day, in the tokens a turn's ceiling counts (the plain
    /// prompt plus output total: a guest turn has no provider stamp, so no price weighting).
    /// Checked before a turn starts, so a client can overshoot it by at most one turn, and one turn
    /// at a time per client keeps it at one. That turn ends at `turnMaxTokens` plus the model round
    /// that crossed it (the ceiling is read between rounds), and a turn cut off by its timeout loses
    /// the round in flight, which the ledger never saw. D6, #1135, for the owner to tune. At 12 turns an hour the per-turn ceiling alone would allow 8,640,000 a day.
    static let dailyTokenCap = 500_000
    /// The `source` a guest turn runs under.
    static let turnSource = "mcp-guest"
    /// Filed when a turn ends with nothing to say: an error, a timeout, a refusal. Short and free
    /// of internals; silence would read to the client as a hang.
    static let failureReply = "Iris could not finish answering that message (the turn failed or ran out of time). Try again later."

    /// Runs one turn on the guest conversation. A seam so a test needs no model.
    typealias TurnRunner = @Sendable (_ conversationId: UUID, _ text: String, _ budget: TurnBudget,
                                      _ sink: any TurnUsageSink) async -> Void

    private let state: AppState
    private let registry: GuestSessionRegistry
    private let mailbox: ProviderMailbox
    let turnGate: ProviderRequestGate
    private let isEnabled: @MainActor () -> Bool
    private let turnTimeout: Double
    private let dailyCap: Int
    private let runTurn: TurnRunner
    let spend: GuestSpendLedger

    /// Clients with a turn running, claimed before the first suspension so two sends racing from
    /// one client cannot both start a turn on one conversation.
    private var running: Set<String> = []
    private var turnTasks: [String: Task<Void, Never>] = [:]

    init(state: AppState, registry: GuestSessionRegistry, mailbox: ProviderMailbox, turnGate: ProviderRequestGate,
         isEnabled: @escaping @MainActor () -> Bool = { ConfigManager.shared.mcpGuestSessionsEnabled },
         turnTimeout: Double = GuestSessionDriver.turnTimeoutSeconds,
         dailyCap: Int = GuestSessionDriver.dailyTokenCap,
         spend: GuestSpendLedger = GuestSpendLedger(),
         runTurn: TurnRunner? = nil) {
        self.state = state
        self.registry = registry
        self.mailbox = mailbox
        self.turnGate = turnGate
        self.isEnabled = isEnabled
        self.turnTimeout = turnTimeout
        self.dailyCap = dailyCap
        self.spend = spend
        self.runTurn = runTurn ?? { [weak state] conversationId, text, budget, sink in
            let engine = await MainActor.run { state?.guestEngines[conversationId] }
            await engine?.processInput(text, source: GuestSessionDriver.turnSource, conversationId: conversationId,
                                       turnBudget: budget, usageSink: sink)
        }
    }

    var isActive: Bool { isEnabled() }

    /// A revoked client: its session closes and its turns bucket goes, so a later re-issue of the
    /// same id starts clean and the gate holds no state for ids that no longer exist. Revoke only:
    /// an idle reap must keep the bucket, or a client could reset its hourly limit by waiting out
    /// the TTL.
    func forget(clientId: String) async {
        registry.close(clientId: clientId)
        await turnGate.purge(clientId: clientId)
    }

    /// The turn in flight for `clientId`, if any; a test awaits it.
    func turnTask(for clientId: String) -> Task<Void, Never>? { turnTasks[clientId] }

    /// Starts one guest turn for `clientId`, or says why not. The refusals are decided before any
    /// turn exists: a turn that was refused spent nothing. A client that has already used its
    /// `dailyTokenCap` for the UTC day is refused (#1135).
    ///
    /// `storedMessageId` is the mailbox copy of `text` that `iris_send` stored: the turn has the
    /// text, and nothing else ever drains that direction, so it is retracted when the turn ends or
    /// a client's pending allowance would fill up and lock it out after 500 sends.
    func submit(text: String, from clientId: String, storedMessageId: UUID? = nil) async -> GuestSubmitResult {
        guard isEnabled() else { return .disabled }
        guard running.insert(clientId).inserted else { return .busy }
        var started = false
        defer { if !started { running.remove(clientId) } }

        // Before the turns gate, so a refusal here does not also spend one of the client's hourly turns.
        if await spend.todayTotal(for: clientId) >= dailyCap { return .overDailyBudget }
        switch await turnGate.admit(clientId: clientId) {
        case .admitted: break
        case .budgetExceeded: return .rateLimited
        case .unauthorized: return .disabled
        }
        let conversationId: UUID
        do { conversationId = try registry.session(for: clientId) } catch { return .busy }

        started = true
        let messageId = UUID()
        turnTasks[clientId] = Task { await self.complete(clientId: clientId, conversationId: conversationId, text: text, storedMessageId: storedMessageId) }
        return .accepted(messageId: messageId)
    }

    private func complete(clientId: String, conversationId: UUID, text: String, storedMessageId: UUID?) async {
        let before = messageCount(conversationId)
        let sink = GuestSpendSink(clientId: clientId, ledger: spend)
        let budget = TurnBudget(maxTokens: Self.turnMaxTokens, seconds: Self.turnTimeoutSeconds)
        let runTurn = self.runTurn
        var finished = true
        do {
            try await withTimeout(seconds: turnTimeout) { await runTurn(conversationId, text, budget, sink) }
        } catch {
            finished = false
            // `withTimeout` cancelled the turn's task, which a cooperative engine call answers at its
            // next boundary; closing the session also deletes the conversation, so nothing the
            // abandoned turn still writes outlives it.
            registry.close(clientId: clientId)
        }
        // The turn is over: the session's idle clock starts now, not when the message arrived, or a
        // turn longer than the TTL would leave it reapable the moment it ended.
        registry.touch(clientId)
        let reply = finished ? finalReply(conversationId, after: before) : nil
        // `deliverReply` re-checks that the client is still registered: a client revoked while its
        // turn ran gets nothing, and the refusal is dropped here on purpose.
        _ = try? await mailbox.deliverReply(to: clientId, text: Self.clamp(reply ?? Self.failureReply), fileRefs: [])
        if let storedMessageId { await mailbox.retract(id: storedMessageId) }
        running.remove(clientId)
        turnTasks[clientId] = nil
    }

    private func messageCount(_ conversationId: UUID) -> Int {
        state.conversations.first { $0.id == conversationId }?.messages.count ?? 0
    }

    /// The last agent message the turn added, or nil if it added none (or the session is gone).
    private func finalReply(_ conversationId: UUID, after count: Int) -> String? {
        guard let conversation = state.conversations.first(where: { $0.id == conversationId }),
              conversation.messages.count > count else { return nil }
        let added = state.liveMessages(Array(conversation.messages[count...]))
        let text = added.last { $0.role == .agent }?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// `text` cut to what the mailbox accepts, on a character boundary.
    static func clamp(_ text: String) -> String {
        guard text.utf8.count > ProviderMailbox.maxTextBytes else { return text }
        var out = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            let n = String(scalar).utf8.count
            if bytes + n > ProviderMailbox.maxTextBytes { break }
            out.append(scalar)
            bytes += n
        }
        return String(out)
    }
}
