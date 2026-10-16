import Testing
import Foundation
import QuartzCore
@testable import IrisKit

/// #476: the spectrum line's drift runs in Core Animation; its timing maths is `SpectrumClock`.
@Suite("Spectrum line clock (#476)")
struct SpectrumClockTests {
    @Test("the phase advances at the rate, one width per 1/rate seconds")
    func advancesAtTheRate() {
        let clock = SpectrumClock.starting(at: 100, speed: SpectrumClock.idleRate)
        #expect(clock.phase(at: 100) == 0)
        #expect(abs(clock.phase(at: 102) - 0.25) < 1e-9)
        #expect(abs(clock.phase(at: 110) - 0.25) < 1e-9, "wraps after one width")
    }

    @Test("a rate switch carries the phase on without a jump", arguments: [
        (SpectrumClock.idleRate, SpectrumClock.activeRate),
        (SpectrumClock.activeRate, SpectrumClock.idleRate),
    ])
    func switchIsContinuous(from: Double, to: Double) {
        let before = SpectrumClock.starting(at: 50, speed: from)
        let now: CFTimeInterval = 53.7
        let after = before.switching(to: to, at: now)
        #expect(abs(after.localTime(at: now) - before.localTime(at: now)) < 1e-9)
        // And from then on it moves at the new rate.
        #expect(abs((after.localTime(at: now + 1) - after.localTime(at: now)) - to) < 1e-9)
    }

    @Test("the layer gets the clock and the animation, and a rate change keeps the animation")
    @MainActor
    func viewKeepsItsAnimationAcrossRateAndSize() throws {
        let view = SpectrumNSView(rate: SpectrumClock.idleRate)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 2)
        view.layout()
        let animation = try #require(view.drift.animation(forKey: SpectrumNSView.animationKey))
        #expect(view.drift.speed == Float(SpectrumClock.idleRate))
        #expect(view.drift.frame == view.bounds)
        #expect(view.drift.contents != nil, "the doubled bar was drawn")

        view.setRate(SpectrumClock.activeRate)
        #expect(view.drift.speed == Float(SpectrumClock.activeRate))
        #expect(view.drift.timeOffset == view.clock.timeOffset)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 2)
        view.layout()
        #expect(view.drift.frame == view.bounds, "a resize re-frames the layer")
        #expect(view.drift.animation(forKey: SpectrumNSView.animationKey) === animation,
                "neither a rate change nor a resize restarts the animation")
    }
}
