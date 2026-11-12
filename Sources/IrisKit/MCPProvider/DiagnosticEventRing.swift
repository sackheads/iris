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

    /// `Encodable` by hand: `CGPoint` is not `Codable`, and the wire shape is a flat
    /// `{"kind": ..., fields}` object so a reader never has to know Swift's synthesized
    /// enum-payload layout. Only the fields an event already carries are written.
    enum Event: Sendable, Encodable {
        case transcriptMouseDown(atWindowPoint: CGPoint)
        case transcriptFocusHop(tookFocus: Bool)
        case composerAcceptsFirstMouse(Bool)
        case windowAppearanceChanged(name: String)
        case composerAppearanceChanged(name: String)
        /// The composer took first responder back (#1055): `reason` is one of `ComposerFocusPolicy.Reason`'s
        /// raw values, `tookFocus` is `makeFirstResponder`'s own answer.
        case composerFocusReclaim(reason: String, tookFocus: Bool)

        private enum CodingKeys: String, CodingKey { case kind, x, y, tookFocus, accepts, name, reason }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .transcriptMouseDown(let point):
                try c.encode("transcriptMouseDown", forKey: .kind)
                try c.encode(Double(point.x), forKey: .x)
                try c.encode(Double(point.y), forKey: .y)
            case .transcriptFocusHop(let tookFocus):
                try c.encode("transcriptFocusHop", forKey: .kind)
                try c.encode(tookFocus, forKey: .tookFocus)
            case .composerAcceptsFirstMouse(let accepts):
                try c.encode("composerAcceptsFirstMouse", forKey: .kind)
                try c.encode(accepts, forKey: .accepts)
            case .windowAppearanceChanged(let name):
                try c.encode("windowAppearanceChanged", forKey: .kind)
                try c.encode(name, forKey: .name)
            case .composerAppearanceChanged(let name):
                try c.encode("composerAppearanceChanged", forKey: .kind)
                try c.encode(name, forKey: .name)
            case .composerFocusReclaim(let reason, let tookFocus):
                try c.encode("composerFocusReclaim", forKey: .kind)
                try c.encode(reason, forKey: .reason)
                try c.encode(tookFocus, forKey: .tookFocus)
            }
        }
    }

    /// The timestamp is written as whole Unix milliseconds, not as a `Date`, so the shape does not
    /// depend on whichever date strategy the encoder in use was given.
    struct Entry: Sendable, Encodable {
        let timestamp: Date
        let event: Event

        private enum CodingKeys: String, CodingKey { case timestampUnixMs, event }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Int((timestamp.timeIntervalSince1970 * 1000).rounded()), forKey: .timestampUnixMs)
            try c.encode(event, forKey: .event)
        }
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
