import Foundation

/// What `ProviderMailbox` needs from `ProviderTokenRegistry` — a protocol, not a direct
/// dependency, so this task's own tests can stub a registry that reports "iris" as registered
/// (proving the mailbox's own type structure resists that impersonation, independent of Task 1's
/// registration-time guard against the literal).
protocol MailboxRegistry: Sendable {
    func isRegistered(clientId: String) -> Bool
}
extension ProviderTokenRegistry: MailboxRegistry {}

/// Identifies who a message's `from`/`to` actually is. `.client` and `.iris` are different enum
/// cases, not two spellings of the same string — a client that somehow registered under the
/// literal "iris" still sends as `.client("iris")`, which can never equal `.iris` or be matched
/// by a `poll(for: "iris")` filtering on `.client("iris")`. Nothing in this type compares those
/// two cases as equivalent.
enum MailboxParty: Sendable, Hashable, Codable {
    case client(String)
    case iris
}

struct ProviderIdentity: Sendable, Codable, Equatable {
    let peerId: String
    let version: String
}

/// Client<->Iris messaging for the loopback MCP provider (#1067). Deliberately client<->Iris
/// only: `send` always addresses Iris (no recipient argument exists to get wrong), and
/// `deliverReply` — the only API that ever addresses a client — is never wired to any MCP tool
/// (Task 8), so no MCP client can write into another client's inbox, directly or by naming it.
actor ProviderMailbox {
    enum MailboxError: Error, Equatable {
        case senderNoLongerRegistered
        case textTooLarge
        case tooManyFileRefs
        case inboxFull
        case malformedFileRef
        case unknownRecipient
    }

    static let maxPendingPerClient = 500
    static let maxTextBytes = 16 * 1024
    static let maxFileRefsPerMessage = 8
    /// Matches Task 7's own object TTL, so an undelivered message and the files it references
    /// expire together.
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    struct Message: Sendable, Codable, Equatable {
        let id: UUID
        let sequence: UInt64
        let from: MailboxParty
        let to: MailboxParty
        let text: String
        let fileRefs: [String]
        let sentAt: Date
    }

    private let registry: any MailboxRegistry
    private let now: @Sendable () -> Date

    private var messages: [Message] = []
    /// Restarts at 1 every launch (messages are memory-only, like `Record` in Task 7). A poller
    /// that stored a cursor from before a restart would then see every reply as "already seen"
    /// until the new counter passes its old cursor — inert in Phase 1 (nothing ever calls
    /// `deliverReply` from a tool, so there is nothing for a cursor to miss yet), but the cursor
    /// contract this type hands Phase 2 assumes monotonicity across the process's own lifetime,
    /// not across restarts. Left as a known Phase 2 concern, not fixed here.
    private var nextSequence: UInt64 = 1

    init(registry: any MailboxRegistry, now: @escaping @Sendable () -> Date = Date.init) {
        self.registry = registry
        self.now = now
    }

    private func pendingCount(from: MailboxParty, to: MailboxParty) -> Int {
        messages.lazy.filter { $0.from == from && $0.to == to }.count
    }

    /// Always stores `from: .client(clientId), to: .iris` — there is no parameter this signature
    /// could pull an overriding `from` or any `to` other than Iris out of. Nothing drains this
    /// direction yet (no Iris-side read, ack, or consuming call) — a client that sends
    /// `maxPendingPerClient` times without ever being purged or swept will see `.inboxFull` on
    /// its next send. That is accepted for Phase 1, where this type is otherwise dormant; wiring
    /// an actual consumer of Iris's inbox is Task 8's concern (or a later follow-up), not this one.
    func send(from clientId: String, text: String, fileRefs: [String]) throws -> Message {
        guard registry.isRegistered(clientId: clientId) else { throw MailboxError.senderNoLongerRegistered }
        try Self.validate(text: text, fileRefs: fileRefs)
        let sender = MailboxParty.client(clientId)
        guard pendingCount(from: sender, to: .iris) < Self.maxPendingPerClient else { throw MailboxError.inboxFull }
        return store(from: sender, to: .iris, text: text, fileRefs: fileRefs)
    }

    /// Iris's replies to `clientId`, oldest first, filtered to `sequence > sinceSequence`. Never
    /// deletes — a dropped connection that polls again still sees them. Always empty in Phase 1:
    /// nothing calls `deliverReply` from any MCP tool yet.
    func poll(for clientId: String, sinceSequence: UInt64?) -> [Message] {
        let party = MailboxParty.client(clientId)
        return messages
            .filter { $0.to == party && (sinceSequence == nil || $0.sequence > sinceSequence!) }
            .sorted { $0.sequence < $1.sequence }
    }

    /// The Iris-side half of the mailbox: stores `from: .iris, to: .client(clientId)`. Not wired
    /// to any MCP tool in Phase 1 (an MCP client has no business writing "from Iris" messages —
    /// see Task 8's source-scan test).
    func deliverReply(to clientId: String, text: String, fileRefs: [String]) throws -> Message {
        guard registry.isRegistered(clientId: clientId) else { throw MailboxError.unknownRecipient }
        try Self.validate(text: text, fileRefs: fileRefs)
        let recipient = MailboxParty.client(clientId)
        guard pendingCount(from: .iris, to: recipient) < Self.maxPendingPerClient else { throw MailboxError.inboxFull }
        return store(from: .iris, to: recipient, text: text, fileRefs: fileRefs)
    }

    private static func validate(text: String, fileRefs: [String]) throws {
        guard text.utf8.count <= maxTextBytes else { throw MailboxError.textTooLarge }
        guard fileRefs.count <= maxFileRefsPerMessage else { throw MailboxError.tooManyFileRefs }
        // Shares ProviderArtifactStore's validation rather than keeping a second copy that can
        // drift (dev-3 review on #1077 — #1075's finding 1 was exactly this bug, in that type's
        // own copy of this check).
        guard fileRefs.allSatisfy(ProviderArtifactStore.isValidHash) else { throw MailboxError.malformedFileRef }
    }

    private func store(from: MailboxParty, to: MailboxParty, text: String, fileRefs: [String]) -> Message {
        let message = Message(id: UUID(), sequence: nextSequence, from: from, to: to, text: text, fileRefs: fileRefs, sentAt: now())
        nextSequence += 1
        messages.append(message)
        return message
    }

    /// Always Iris's own identity — never `registry.allClientIds()`. An enumerable roster of
    /// other registered clients is itself a client-to-client discovery primitive, struck along
    /// with direct `send`.
    func discover() -> ProviderIdentity {
        ProviderIdentity(peerId: ProviderTokenRegistry.reservedClientId, version: Constants.appVersion)
    }

    /// `clientId`'s own view of Iris's replies to it — equivalently, what `poll(for: clientId)`
    /// would return right now. Always `(0, nil)` in Phase 1, for the same reason `poll` is.
    func status(for clientId: String) -> (pendingCount: Int, lastMessageAt: Date?) {
        let mine = poll(for: clientId, sinceSequence: nil)
        return (mine.count, mine.last?.sentAt)
    }

    /// Deletes one pending message by id, regardless of direction. Used only by Task 8's
    /// `iris_send` wiring, to undo a `send` whose file-ref grant failed afterward.
    func retract(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    /// `now` defaults to this actor's own injected clock, not a bare `Date()` — a caller that
    /// omits it (production always will; only a test overrides it) must still see the same clock
    /// every other method in this type uses.
    func sweepExpired(now: Date? = nil) {
        let cutoff = now ?? self.now()
        messages.removeAll { cutoff.timeIntervalSince($0.sentAt) > Self.ttl }
    }

    /// Deletes every pending message to or from `clientId`, in both directions — a revoked client
    /// id, later re-issued to someone else, must not hand them the old occupant's mailbox.
    func purge(clientId: String) {
        let party = MailboxParty.client(clientId)
        messages.removeAll { $0.from == party || $0.to == party }
    }
}
