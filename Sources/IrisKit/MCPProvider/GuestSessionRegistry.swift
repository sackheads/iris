import Foundation

/// #1066 Phase 2, Task 7: the live guest sessions, at most one per client, bounded in number and
/// in idle time. A guest session is a hidden conversation plus its own engine; this type is the
/// only place that creates or closes one. In memory on purpose: a restart starts empty, and a
/// guest conversation is never persisted.
enum GuestSessionError: Error, Equatable {
    /// `maxLive` sessions already exist for other clients; nothing was created.
    case busy
    /// The conversation or its engine could not be set up; nothing is left behind.
    case unavailable
}

@MainActor
final class GuestSessionRegistry {
    /// How often the reaper looks for idle sessions.
    static let reaperInterval: DispatchTimeInterval = .seconds(60)

    private struct Entry {
        var conversationId: UUID
        var lastTouched: SuspendingClock.Instant
    }

    private let state: AppState
    private let ttl: Duration
    private let maxLive: Int
    private let now: @Sendable () -> SuspendingClock.Instant
    private let makeEngine: @MainActor (AppState, String) -> IrisEngine
    private var entries: [String: Entry] = [:]
    private var reaper: DispatchSourceTimer?

    init(state: AppState, ttl: Duration = .seconds(900), maxLive: Int = 4,
         now: @escaping @Sendable () -> SuspendingClock.Instant = { SuspendingClock().now },
         makeEngine: @escaping @MainActor (AppState, String) -> IrisEngine) {
        self.state = state
        self.ttl = ttl
        self.maxLive = maxLive
        self.now = now
        self.makeEngine = makeEngine
    }

    var liveCount: Int { entries.count }

    /// The conversation for `clientId`, created on first use and reused after. An entry whose
    /// conversation is gone (the owner deleted it) is dropped first, so it neither counts against
    /// the cap nor comes back as a dead id.
    func session(for clientId: String) throws -> UUID {
        pruneGone()
        if var entry = entries[clientId] {
            entry.lastTouched = now()
            entries[clientId] = entry
            return entry.conversationId
        }
        guard entries.count < maxLive else { throw GuestSessionError.busy }
        let id = state.createNewConversation(isGuest: true, guestClientId: clientId, title: "guest:\(clientId)", select: false)
        guard state.register(guestEngine: makeEngine(state, clientId), for: id) else {
            state.deleteConversation(id)
            throw GuestSessionError.unavailable
        }
        entries[clientId] = Entry(conversationId: id, lastTouched: now())
        return id
    }

    func touch(_ clientId: String) {
        guard var entry = entries[clientId] else { return }
        entry.lastTouched = now()
        entries[clientId] = entry
    }

    /// Deletes the session now, a turn in flight or not: its peer requests are closed, its engine
    /// is unregistered and the conversation goes (`AppState.deleteConversation`). A revoked client
    /// must not keep a session.
    func close(clientId: String) {
        guard let entry = entries.removeValue(forKey: clientId) else { return }
        state.deleteConversation(entry.conversationId)
    }

    /// Closes every session now, for the provider stopping: a guest session does not outlive the
    /// runtime that served it.
    func closeAll() {
        for clientId in Array(entries.keys) { close(clientId: clientId) }
    }

    /// Closes every session idle past the TTL, except one with a turn in flight: that one is left
    /// for the next pass, which closes it once the turn has ended.
    func reapIdle() {
        pruneGone()
        let cutoff = now()
        for (clientId, entry) in entries
        where entry.lastTouched.duration(to: cutoff) > ttl && !state.hasTurnInFlight(for: entry.conversationId) {
            close(clientId: clientId)
        }
    }

    private func pruneGone() {
        let live = Set(state.conversations.map(\.id))
        for (clientId, entry) in entries where !live.contains(entry.conversationId) {
            entries[clientId] = nil
            state.unregisterGuestEngine(for: entry.conversationId)
        }
    }

    /// A dispatch timer, not a task that sleeps: a held cooperative pool must not hold the reaper
    /// (Invariant 4). Idempotent.
    func startReaper() {
        guard reaper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.reaperInterval, repeating: Self.reaperInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reapIdle() }
        }
        reaper = timer
        timer.resume()
    }

    func stopReaper() {
        reaper?.cancel()
        reaper = nil
    }
}
