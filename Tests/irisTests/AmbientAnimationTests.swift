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
        #expect(abs(pulse.value(at: 0.5) - pulse.value(at: 1.1)) < 1e-9, "the way back mirrors the way up")
        #expect(abs(pulse.value(at: 0.5) - 0.65) < 1e-9, "halfway up is halfway in value")
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
        let dots = TypingDotsNSView()
        let glow = WelcomeGlowNSView()
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
        let dots = TypingDotsNSView()
        window.contentView?.addSubview(dots)
        #expect(dots.animated.allSatisfy { ($0.layer.animationKeys() ?? []).count == 2 })
        dots.removeFromSuperview()
        #expect(dots.animated.allSatisfy { ($0.layer.animationKeys() ?? []).isEmpty })
    }
}
