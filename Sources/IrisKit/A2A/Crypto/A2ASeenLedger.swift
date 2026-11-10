import Foundation
import GRDB

/// The real, persisted `SeenSetStore` `PeerSignatureVerifier` (#974 H4 Task 4) depends on for
/// replay defence: the `seen_nonces` table, on the store's own writer, following the
/// `JobLedger`/`PeerLedger` idiom — a `writer.write { db in ... }` per operation, nothing cached
/// in memory. A `struct` rather than a `final class`, unlike those two, because it holds no
/// mutable state of its own beyond the immutable writer reference.
///
/// `isOnDisk` (the store's `path != nil`) is load-bearing: `ConversationStore.openOrFallBack`
/// swaps in a fresh, empty in-memory database when `conversations.sqlite` can't open, and an
/// in-memory seen-set looks empty after every restart — exactly the replay window this ledger
/// exists to close. `admit` refuses outright over such a store rather than riding it.
struct A2ASeenLedger: SeenSetStore, Sendable {
    private let writer: any DatabaseWriter
    private let isOnDisk: Bool

    init(writer: any DatabaseWriter, isOnDisk: Bool) {
        self.writer = writer
        self.isOnDisk = isOnDisk
    }

    /// One atomic check-and-record per `(peer, envelopeId)` (AGENTS.md Invariant 7: `now` is
    /// always the caller's own value, never read from the system clock here).
    ///
    /// Ordering inside the single `writer.write` transaction matters (romar replay defence):
    /// 1. Opportunistic cleanup — `DELETE ... WHERE retain_until < now` — best-effort, not
    ///    required to succeed for correctness, just keeps the table bounded over time.
    /// 2. `INSERT OR IGNORE` the `(peer, envelopeId)` pair.
    /// 3. **Zero rows changed means the pair was already present** — `.duplicate`, returned
    ///    immediately, even when this peer is already over `maxPerPeer`: a legitimate redelivery
    ///    must never be mistaken for the peer being full and nacked into an endless redeliver
    ///    loop. Only a genuinely **new** id is ever checked against the bound.
    /// 4. One row changed means it was newly inserted: now check this peer's row count. Over the
    ///    bound, delete the row just inserted — never a different, older/live row — and throw
    ///    `.full`. Otherwise, `.fresh`.
    ///
    /// Any other GRDB failure anywhere in this block maps to `.unavailable` (fail closed); a
    /// `.full` thrown from inside the block is rethrown as itself.
    func admit(peer: String, envelopeId: String, retainUntil: Date, maxPerPeer: Int, now: Date) throws -> AdmitResult {
        guard isOnDisk else { throw SeenSetStoreError.unavailable }
        do {
            return try writer.write { db in
                try db.execute(sql: "DELETE FROM seen_nonces WHERE retain_until < ?",
                               arguments: [now.timeIntervalSince1970])
                try db.execute(sql: """
                    INSERT OR IGNORE INTO seen_nonces (peer, envelope_id, retain_until) VALUES (?, ?, ?)
                    """, arguments: [peer, envelopeId, retainUntil.timeIntervalSince1970])
                guard db.changesCount > 0 else { return AdmitResult.duplicate }
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_nonces WHERE peer = ?",
                                              arguments: [peer]) ?? 0
                guard count <= maxPerPeer else {
                    try db.execute(sql: "DELETE FROM seen_nonces WHERE peer = ? AND envelope_id = ?",
                                   arguments: [peer, envelopeId])
                    throw SeenSetStoreError.full
                }
                return AdmitResult.fresh
            }
        } catch let error as SeenSetStoreError {
            throw error
        } catch {
            throw SeenSetStoreError.unavailable
        }
    }

    /// Drops rows whose retention window has closed strictly before `now` (AGENTS.md
    /// Invariant 7: `now` injected, never `Date()`) — a row at exactly `now` survives, so the
    /// boundary never reopens a replay window one tick early.
    func prune(now: Date) throws {
        do {
            try writer.write { db in
                try db.execute(sql: "DELETE FROM seen_nonces WHERE retain_until < ?",
                               arguments: [now.timeIntervalSince1970])
            }
        } catch {
            throw SeenSetStoreError.unavailable
        }
    }
}
