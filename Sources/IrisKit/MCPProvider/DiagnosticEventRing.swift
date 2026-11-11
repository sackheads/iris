import Foundation
import CoreGraphics

/// A bounded, in-order record of focus/appearance events relevant to the #1055/#1052 composer
/// debugging motivator (#1067). Deliberately not an actor: an actor's `record` would need
/// `Task { await ring.record(...) }` from a synchronous AppKit callback, and two such `Task`s have
/// no ordering guarantee relative to each other — a ring that exists to pin a physical event
/// *sequence* must not let its own recording mechanism reorder it. A single `NSLock` guarding a
/// plain array (the same shape `KeychainManager`'s lock-guarded state uses) makes `record`
/// synchronous, so two calls made in physical event order are recorded in that same order.
final class DiagnosticEventRing: @unchecked Sendable {
    static let capacity = 200

    enum Event: Sendable {
        case transcriptMouseDown(atWindowPoint: CGPoint)
        case transcriptFocusHop(tookFocus: Bool)
        case composerAcceptsFirstMouse(Bool)
        case windowAppearanceChanged(name: String)
        case composerAppearanceChanged(name: String)
    }

    struct Entry: Sendable {
        let timestamp: Date
        let event: Event
    }

    static let shared = DiagnosticEventRing()

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ event: Event) {
        lock.withLock {
            entries.append(Entry(timestamp: Date(), event: event))
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
        }
    }

    func snapshot() -> [Entry] {
        lock.withLock { entries }
    }
}
