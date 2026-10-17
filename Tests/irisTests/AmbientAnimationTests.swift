import Testing
import AppKit
import QuartzCore
@testable import IrisKit

/// #540: the typing dots and the welcome throb run in Core Animation. Their timing must match the
/// SwiftUI animations they replace, and nothing may keep running once they leave the window.
@MainActor
@Suite("Ambient animations in Core Animation (#540)")
struct AmbientAnimationTests {
    @Test("a pulse holds at `from` before its delay, peaks after one duration, and is back after two")
    func pulseProgress() {
        let pulse = AmbientPulse(keyPath: "opacity", from: 0.3, to: 1.0, duration: 0.6, delay: 0.2)
        #expect(pulse.value(at: 0) == 0.3)
        #expect(pulse.value(at: 0.2) == 0.3)
        #expect(abs(pulse.value(at: 0.8) - 1.0) < 1e-9)
        #expect(abs(pulse.value(at: 1.4) - 0.3) < 1e-9)
        #expect(abs(pulse.value(at: 0.35) - pulse.value(at: 1.25)) < 1e-9, "the way back mirrors the way up")
        // A quarter of the way up, where CA's curve and a smoothstep differ (0.129 against 0.156).
        #expect(abs(pulse.progress(at: 0.35) - AmbientPulse.eased(0.25)) < 1e-12)
        #expect(abs(pulse.progress(at: 0.35) - 0.129) < 0.001)
    }

    /// The model's curve is CA's ease-in-ease-out, not an approximation of it (#546 review): checked
    /// off the symmetric points, against a dense sampling of the Bézier with the CSS control points.
    @Test("the pulse's easing is CA's easeInEaseOut curve", arguments: [0.1, 0.25, 0.4, 0.6, 0.75, 0.9])
    func easingIsTheTimingFunction(x: Double) {
        func bez(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t; return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        // (0.42, 0, 0.58, 1): sample the parameter finely and take the point whose x is nearest.
        let samples = (0...200_000).map { Double($0) / 200_000 }
        let t = samples.min { abs(bez($0, 0.42, 0.58) - x) < abs(bez($1, 0.42, 0.58) - x) }!
        #expect(abs(AmbientPulse.eased(x) - bez(t, 0, 1)) < 1e-4, "at x = \(x)")
    }

    @Test("the typing dots keep today's timing: 0.6 s each way, 0.0 / 0.2 / 0.4 s apart, half size and 0.3 opacity up to full")
    func dotsTiming() {
        #expect(TypingDotsNSView.delays == [0.0, 0.2, 0.4])
        for delay in TypingDotsNSView.delays {
            let pulses = TypingDotsView.pulses(delay: delay)
            #expect(pulses.map(\.keyPath) == ["transform.scale", "opacity"])
            #expect(pulses.allSatisfy { $0.duration == 0.6 && $0.delay == delay && $0.to == 1.0 })
            #expect(pulses.map(\.from) == [0.5, 0.3])
        }
    }

    @Test("the welcome throb keeps today's timing: 2.6 s each way, glow 0.9-1.06 at 0.5-0.9 opacity, icon to 1.03")
    func throbTiming() {
        #expect(WelcomeGlowView.glowPulses == [
            AmbientPulse(keyPath: "transform.scale", from: 0.9, to: 1.06, duration: 2.6),
            AmbientPulse(keyPath: "opacity", from: 0.5, to: 0.9, duration: 2.6)])
        #expect(WelcomeGlowView.iconPulses == [AmbientPulse(keyPath: "transform.scale", from: 1.0, to: 1.03, duration: 2.6)])
    }

    @Test("the built animation is the pulse: eased, autoreversing, repeating, held before it starts")
    func builtAnimation() throws {
        let pulse = AmbientPulse(keyPath: "transform.scale", from: 0.5, to: 1.0, duration: 0.6, delay: 0.4)
        let a = pulse.animation(startingAt: 10)
        #expect(a.keyPath == "transform.scale")
        #expect(a.fromValue as? Double == 0.5 && a.toValue as? Double == 1.0)
        #expect(a.duration == 0.6 && a.beginTime == 10.4)
        #expect(a.autoreverses && a.repeatCount == .infinity && a.fillMode == .backwards)
        #expect(a.timingFunction == CAMediaTimingFunction(name: .easeInEaseOut))
    }

    @Test("shown and hidden 100 times, the dots and the glow leave no animation and no extra layer")
    func lifecycleLeavesNothing() {
        let dots = TypingDotsNSView(reduceMotion: MotionSwitch(false).motion)
        let glow = WelcomeGlowNSView(reduceMotion: MotionSwitch(false).motion)
        for view in [dots, glow] as [AmbientLayerView] {
            let layers = view.layer?.sublayers?.count
            for _ in 0..<100 {
                view.startAnimating()
                #expect(view.animated.allSatisfy { !($0.layer.animationKeys() ?? []).isEmpty })
                view.stopAnimating()
            }
            #expect(view.animated.allSatisfy { ($0.layer.animationKeys() ?? []).isEmpty }, "nothing left running")
            #expect(view.layer?.sublayers?.count == layers, "no layer added by showing it")
        }
        #expect(dots.animated.count == 3 && dots.animated.allSatisfy { $0.layer.animationKeys() == nil })
    }

    @Test("leaving the window stops the animations; joining one starts them")
    func windowDrivesTheAnimations() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let dots = TypingDotsNSView(reduceMotion: MotionSwitch(false).motion)
        window.contentView?.addSubview(dots)
        #expect(dots.animated.allSatisfy { ($0.layer.animationKeys() ?? []).count == 2 })
        dots.removeFromSuperview()
        #expect(dots.animated.allSatisfy { ($0.layer.animationKeys() ?? []).isEmpty })
    }

    // MARK: Model LED (#557)

    @Test("the LED pulse keeps today's timing: 1.0 to 1.35 times its size, 0.6 s each way")
    func ledTiming() {
        #expect(LEDDotView.pulse == AmbientPulse(keyPath: "transform.scale", from: 1.0, to: 1.35, duration: 0.6))
    }

    private func pulseKeys(_ view: LEDDotNSView) -> [String] {
        (view.dot.animationKeys() ?? []).filter { $0 != "settle" }
    }

    @Test("on screen, the LED pulses exactly while it is active, however often the state flips")
    func ledPulsesWhileActive() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let led = LEDDotNSView(state: .ready)
        window.contentView?.addSubview(led)
        let layers = led.layer?.sublayers?.count
        #expect(pulseKeys(led).isEmpty, "ready does not pulse")
        for _ in 0..<100 {
            led.state = .active
            #expect(pulseKeys(led) == ["transform.scale"])
            led.state = .active
            #expect(pulseKeys(led) == ["transform.scale"], "the same state again adds nothing")
            led.state = .ready
            #expect(pulseKeys(led).isEmpty)
        }
        led.state = .downloading
        led.state = .error
        #expect(pulseKeys(led).isEmpty, "only active pulses")
        #expect(led.layer?.sublayers?.count == layers, "no layer added by pulsing")
    }

    @Test("an active LED starts pulsing when it joins a window and stops when it leaves")
    func ledFollowsTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let led = LEDDotNSView(state: .active)
        #expect(pulseKeys(led).isEmpty, "nothing runs before it is shown")
        window.contentView?.addSubview(led)
        #expect(pulseKeys(led) == ["transform.scale"])
        led.removeFromSuperview()
        #expect((led.dot.animationKeys() ?? []).isEmpty, "nothing left running, settle included")
        led.state = .ready
        led.state = .active
        #expect(pulseKeys(led).isEmpty, "a state change off screen starts nothing")
    }

    @Test("the dot keeps each state's look: its colour, a 0.3 ring, and a glow only when ready, active or downloading",
          arguments: ModelLED.LEDState.allCases)
    func ledLooks(state: ModelLED.LEDState) throws {
        let led = LEDDotNSView(state: state)
        let fill = try #require(led.dot.fillColor)
        let ring = try #require(led.dot.strokeColor)
        #expect(abs(ring.alpha - fill.alpha * 0.3) < 0.001)
        #expect(led.dot.lineWidth == 1)
        #expect(led.dot.shadowRadius == state.glowRadius)
        #expect(led.dot.shadowOpacity == (state.glowRadius > 0 ? 0.7 : 0))
        #expect(led.dot.shadowPath != nil)
    }

    @Test("leaving active settles back to full size over 0.2 s from where the pulse was, and is a no-op at full size")
    func ledSettles() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let led = LEDDotNSView(state: .active)
        window.contentView?.addSubview(led)
        led.settle(from: 1.2)
        #expect(pulseKeys(led).isEmpty, "the pulse is gone")
        let back = try #require(led.dot.animation(forKey: "settle") as? CABasicAnimation)
        #expect(back.keyPath == "transform.scale")
        #expect(back.fromValue as? Double == 1.2 && back.toValue as? Double == 1.0)
        #expect(back.duration == 0.2 && !back.autoreverses && back.repeatCount == 0)
        #expect(back.timingFunction == CAMediaTimingFunction(name: .easeInEaseOut))
        led.state = .active
        led.settle(from: 1)
        #expect((led.dot.animationKeys() ?? []).isEmpty, "already at full size: nothing to settle")
    }

    // From iris-dev-2's review of #561, probed headless.
    @Test("the LED re-resolves its colours when the appearance changes")
    func ledFollowsAppearance() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        let led = LEDDotNSView(state: .ready)
        window.contentView?.addSubview(led)
        let light = try #require(led.dot.fillColor)
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(try #require(led.dot.fillColor) != light)
    }
}
