import Foundation

/// How often tier 3's canary sends a second request (#871), over its last calls, and when that is
/// too often. Measured, a hedge fires for about 2.5% of calls (#871) and 0.2% in #876's run; a rate
/// past 5% is twice the design point and well past the measurement, which means the tail the delay
/// was chosen from is gone: the provider is stalling broadly, so a second request no longer rescues
/// a slow one and only doubles the cost.
final class HedgeRateMonitor: @unchecked Sendable {
    /// The one the product's canary engine reports to, for the life of the process.
    static let canary = HedgeRateMonitor()

    /// The share of recent calls past which it warns.
    static let warnAbove = 0.05
    /// It warns again only after the share has fallen back below this, so one bad spell is one notice.
    static let rearmBelow = 0.025

    struct Rate: Equatable, Sendable {
        var hedged: Int
        var calls: Int
        var share: Double { Double(hedged) / Double(calls) }
    }

    private let lock = NSLock()
    private let window: Int
    private let minCalls: Int
    private var slots: [Bool]
    private var begun = 0
    private var armed = true

    /// `window`: how many of the latest calls count. `minCalls`: fewer calls than this never warn, so
    /// two hedges in the first five calls (40%) are not a rate.
    init(window: Int = 100, minCalls: Int = 20) {
        self.window = window
        self.minCalls = minCalls
        self.slots = Array(repeating: false, count: window)
    }

    /// A call is starting; the number to hand back to `fired`.
    func began() -> Int {
        lock.withLock {
            slots[begun % window] = false
            begun += 1
            if armed == false, rate().share < Self.rearmBelow { armed = true }
            return begun - 1
        }
    }

    /// The call numbered `call` sent its second request. Returns the rate when this is the hedge that
    /// takes the share over the line, once per spell, and nil otherwise.
    func fired(_ call: Int) -> Rate? {
        lock.withLock {
            guard begun - call <= window else { return nil }   // slid out of the window already
            slots[call % window] = true
            let now = rate()
            guard armed, now.calls >= minCalls, now.share > Self.warnAbove else { return nil }
            armed = false
            return now
        }
    }

    private func rate() -> Rate {
        let calls = min(begun, window)
        return Rate(hedged: slots.prefix(calls).filter { $0 }.count, calls: max(calls, 1))
    }

    static func warning(_ rate: Rate) -> String {
        let percent = Int((rate.share * 100).rounded())
        return "Tier 3's canary sent a second request on \(rate.hedged) of its last \(rate.calls) checks (\(percent)%). About 2.5% normally need one, so the provider looks slow right now, and each second request is a second paid call that may not be answered sooner. Settings → Security → Tier 3 can turn the second request off."
    }
}
