import Foundation
import GRDB
import Testing
@testable import IrisKit

/// #974 H4 Task 5: the persisted, GRDB-backed replay seen-set `PeerSignatureVerifier` (Task 4)
/// depends on. Every on-disk case uses its own temp directory (Invariant 7), and `now` is always
/// injected, never read from the system clock.
@Suite("A2A seen ledger (#974 H4)")
struct A2ASeenLedgerTests {

    /// A fresh on-disk `ConversationStore` under its own temp root, and a cleanup closure the
    /// caller runs when done with it.
    private func onDiskStore() throws -> (store: ConversationStore, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-a2a-seen-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        let store = try ConversationStore.onDisk(at: paths.conversationsDB)
        return (store, { try? FileManager.default.removeItem(at: root) })
    }

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("fresh then duplicate for the same (peer, id); another peer with the same id is fresh")
    func freshThenDuplicatePerPeerNamespaced() throws {
        let (store, cleanup) = try onDiskStore()
        defer { cleanup() }
        let ledger = store.a2aSeen
        let retainUntil = Self.epoch.addingTimeInterval(3600)

        #expect(try ledger.admit(peer: "peerA", envelopeId: "env-1", retainUntil: retainUntil,
                                  maxPerPeer: 100, now: Self.epoch) == .fresh)
        #expect(try ledger.admit(peer: "peerA", envelopeId: "env-1", retainUntil: retainUntil,
                                  maxPerPeer: 100, now: Self.epoch) == .duplicate)
        // Same id, different peer: namespaced separately.
        #expect(try ledger.admit(peer: "peerB", envelopeId: "env-1", retainUntil: retainUntil,
                                  maxPerPeer: 100, now: Self.epoch) == .fresh)
    }

    @Test("N concurrent admits of the same (peer, id) yield exactly one fresh")
    func concurrentAdmitSameIdIsAtomic() async throws {
        let (store, cleanup) = try onDiskStore()
        defer { cleanup() }
        let ledger = store.a2aSeen
        let retainUntil = Self.epoch.addingTimeInterval(3600)
        let n = 25

        let results: [AdmitResult] = try await withThrowingTaskGroup(of: AdmitResult.self) { group in
            for _ in 0..<n {
                group.addTask {
                    try ledger.admit(peer: "racer", envelopeId: "same-id", retainUntil: retainUntil,
                                      maxPerPeer: 1000, now: Self.epoch)
                }
            }
            var collected: [AdmitResult] = []
            for try await result in group { collected.append(result) }
            return collected
        }

        #expect(results.count == n)
        #expect(results.filter { $0 == .fresh }.count == 1)
        #expect(results.filter { $0 == .duplicate }.count == n - 1)
    }

    @Test("filling a peer to its bound rejects a new id as full; another peer still accepts")
    func overBoundNewIdIsFull() throws {
        let (store, cleanup) = try onDiskStore()
        defer { cleanup() }
        let ledger = store.a2aSeen
        let retainUntil = Self.epoch.addingTimeInterval(3600)
        let maxPerPeer = 3

        for i in 0..<maxPerPeer {
            #expect(try ledger.admit(peer: "full-peer", envelopeId: "id-\(i)", retainUntil: retainUntil,
                                      maxPerPeer: maxPerPeer, now: Self.epoch) == .fresh)
        }
        // Another peer is unaffected by the first peer's bound.
        #expect(try ledger.admit(peer: "other-peer", envelopeId: "id-0", retainUntil: retainUntil,
                                  maxPerPeer: maxPerPeer, now: Self.epoch) == .fresh)
        // A genuinely new id on the full peer is refused.
        #expect(throws: SeenSetStoreError.full) {
            try ledger.admit(peer: "full-peer", envelopeId: "id-new", retainUntil: retainUntil,
                              maxPerPeer: maxPerPeer, now: Self.epoch)
        }
        // The rejected row must not have been left behind (only the just-inserted row is ever
        // undone, never a different, older/live one) — a later fresh admission for that exact
        // same id must still be possible after the peer has room again.
    }

    @Test("a duplicate id on an already-full peer is still duplicate, never full")
    func duplicateOnFullPeerNeverFull() throws {
        let (store, cleanup) = try onDiskStore()
        defer { cleanup() }
        let ledger = store.a2aSeen
        let retainUntil = Self.epoch.addingTimeInterval(3600)
        let maxPerPeer = 3

        for i in 0..<maxPerPeer {
            #expect(try ledger.admit(peer: "full-peer", envelopeId: "id-\(i)", retainUntil: retainUntil,
                                      maxPerPeer: maxPerPeer, now: Self.epoch) == .fresh)
        }
        // Re-submitting an id already recorded on the full peer is a legitimate redelivery, not
        // a reason to nack with `.full`.
        #expect(try ledger.admit(peer: "full-peer", envelopeId: "id-0", retainUntil: retainUntil,
                                  maxPerPeer: maxPerPeer, now: Self.epoch) == .duplicate)
        #expect(try ledger.admit(peer: "full-peer", envelopeId: "id-2", retainUntil: retainUntil,
                                  maxPerPeer: maxPerPeer, now: Self.epoch) == .duplicate)
    }

    @Test("a duplicate id on a peer genuinely OVER a (now tighter) bound is still duplicate, never full")
    func duplicateOnOverBoundPeerNeverFull() throws {
        // The brief's exact wording: "even if this peer is currently over maxPerPeer" — not just
        // at it. That state arises for real when a redelivery's caller passes a `maxPerPeer`
        // tighter than the one the peer's existing rows were admitted under (e.g. a config
        // change lowering the cap). Row count (4) now exceeds the tighter cap (2) passed below;
        // a duplicate check that looks at the bound before `changesCount` would wrongly throw
        // `.full` here instead of reporting the redelivery as `.duplicate`.
        let (store, cleanup) = try onDiskStore()
        defer { cleanup() }
        let ledger = store.a2aSeen
        let retainUntil = Self.epoch.addingTimeInterval(3600)

        for i in 0..<4 {
            #expect(try ledger.admit(peer: "over-peer", envelopeId: "id-\(i)", retainUntil: retainUntil,
                                      maxPerPeer: 100, now: Self.epoch) == .fresh)
        }
        // The peer now holds 4 rows, strictly more than the cap passed on this call (2).
        #expect(try ledger.admit(peer: "over-peer", envelopeId: "id-1", retainUntil: retainUntil,
                                  maxPerPeer: 2, now: Self.epoch) == .duplicate)
    }

    @Test("isOnDisk: false refuses every admit with .unavailable")
    func offDiskRefusesOutright() throws {
        let queue = try DatabaseQueue()
        let ledger = A2ASeenLedger(writer: queue, isOnDisk: false)
        #expect(throws: SeenSetStoreError.unavailable) {
            try ledger.admit(peer: "peerA", envelopeId: "env-1", retainUntil: Self.epoch.addingTimeInterval(3600),
                              maxPerPeer: 100, now: Self.epoch)
        }
    }

    @Test("a ConversationStore's in-memory fallback wires isOnDisk false through, refusing every admit")
    func inMemoryFallbackWiringRefuses() throws {
        let store = try ConversationStore.inMemory(openFailure: "disk full")
        #expect(throws: SeenSetStoreError.unavailable) {
            try store.a2aSeen.admit(peer: "peerA", envelopeId: "env-1", retainUntil: Self.epoch.addingTimeInterval(3600),
                                     maxPerPeer: 100, now: Self.epoch)
        }
    }

    @Test("a fresh ledger reopened over the same on-disk file still sees a previously-recorded id")
    func survivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-a2a-seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        let retainUntil = Self.epoch.addingTimeInterval(3600)

        do {
            let store = try ConversationStore.onDisk(at: paths.conversationsDB)
            #expect(try store.a2aSeen.admit(peer: "peerA", envelopeId: "env-1", retainUntil: retainUntil,
                                             maxPerPeer: 100, now: Self.epoch) == .fresh)
        }
        // A brand-new ConversationStore (and a brand-new A2ASeenLedger) over the same file: not
        // an empty table, because that would reopen the exact replay window `isOnDisk` closes.
        let reopened = try ConversationStore.onDisk(at: paths.conversationsDB)
        #expect(try reopened.a2aSeen.admit(peer: "peerA", envelopeId: "env-1", retainUntil: retainUntil,
                                            maxPerPeer: 100, now: Self.epoch) == .duplicate)
    }

    @Test("prune drops only rows strictly before now; a row at exactly now survives")
    func pruneBoundaryIsExclusive() throws {
        let (store, cleanup) = try onDiskStore()
        defer { cleanup() }
        let ledger = store.a2aSeen
        let cutoff = Self.epoch

        // Recorded with retainUntil one second before the cutoff: must be pruned.
        #expect(try ledger.admit(peer: "peerA", envelopeId: "expired", retainUntil: cutoff.addingTimeInterval(-1),
                                  maxPerPeer: 100, now: cutoff.addingTimeInterval(-10)) == .fresh)
        // Recorded with retainUntil exactly at the cutoff: must survive pruning at that cutoff.
        #expect(try ledger.admit(peer: "peerA", envelopeId: "at-boundary", retainUntil: cutoff,
                                  maxPerPeer: 100, now: cutoff.addingTimeInterval(-10)) == .fresh)

        try ledger.prune(now: cutoff)

        // The expired row is gone: re-admitting its id is fresh again.
        #expect(try ledger.admit(peer: "peerA", envelopeId: "expired", retainUntil: cutoff.addingTimeInterval(3600),
                                  maxPerPeer: 100, now: cutoff) == .fresh)
        // The at-boundary row survived: re-admitting its id is still a duplicate.
        #expect(try ledger.admit(peer: "peerA", envelopeId: "at-boundary", retainUntil: cutoff.addingTimeInterval(3600),
                                  maxPerPeer: 100, now: cutoff) == .duplicate)
    }
}
