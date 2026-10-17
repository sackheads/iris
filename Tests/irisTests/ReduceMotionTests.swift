import Testing
import AppKit
@testable import IrisKit

/// A Reduce Motion setting of the test's own: never the Mac's, so a test means the same thing on
/// every machine. Flipping it posts on a private centre, as the system's change notification does.
@MainActor
final class MotionSwitch {
    let center = NotificationCenter()
    let name = Notification.Name("iris.test.reduceMotion")
    var on: Bool
    private(set) lazy var motion = ReduceMotion(read: { self.on }, center: center, name: name)

    init(_ on: Bool) { self.on = on }

    func set(_ on: Bool) {
        self.on = on
        center.post(name: name, object: nil)
    }
}

/// #538: the ambient animations honour Reduce Motion, read live through `ReduceMotion`.
@MainActor
@Suite("Ambient animations under Reduce Motion (#538)", .timeLimit(.minutes(1)))
struct ReduceMotionTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    /// The observer delivers on the main queue, so give it a turn of the run loop.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    private func keys(_ view: AmbientLayerView) -> [[String]] {
        view.animated.map { $0.layer.animationKeys() ?? [] }
    }

    @Test("with Reduce Motion on, the dots stand still at full size and the glow at its fullest")
    func standStill() {
        let motion = MotionSwitch(true)
        let window = window()
        let dots = TypingDotsNSView(reduceMotion: motion.motion)
        let glow = WelcomeGlowNSView(reduceMotion: motion.motion)
        window.contentView?.addSubview(dots)
        window.contentView?.addSubview(glow)
        #expect(keys(dots).allSatisfy { $0.isEmpty } && keys(glow).allSatisfy { $0.isEmpty }, "nothing runs")
        for (layer, _) in dots.animated {
            #expect(abs((layer.value(forKeyPath: "transform.scale") as? Double ?? 0) - 1.0) < 0.0001)
            #expect(layer.opacity == 1)
        }
        func scale(_ layer: CALayer) -> Double { layer.value(forKeyPath: "transform.scale") as? Double ?? 0 }
        #expect(abs(scale(glow.glow) - 1.06) < 0.0001)
        #expect(abs(glow.glow.opacity - 0.9) < 0.0001)
        #expect(abs(scale(glow.icon) - 1.03) < 0.0001)
    }

    @Test("a pulse can stand still somewhere other than its peak")
    func stillOverridesThePeak() {
        final class One: AmbientLayerView {
            let dot = CALayer()
            init(reduceMotion: ReduceMotion) {
                super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10), reduceMotion: reduceMotion)
                layer?.addSublayer(dot)
                animated = [(dot, [AmbientPulse(keyPath: "transform.scale", from: 1.0, to: 1.35, duration: 0.6, still: 1.0)])]
            }
            required init?(coder: NSCoder) { fatalError() }
        }
        let view = One(reduceMotion: MotionSwitch(true).motion)
        window().contentView?.addSubview(view)
        #expect(abs((view.dot.value(forKeyPath: "transform.scale") as? Double ?? 0) - 1.0) < 0.0001)
        #expect(view.dot.animationKeys() == nil)
    }

    @Test("turning Reduce Motion on mid-animation takes the animations off at once, and off puts them back")
    func flipWhileShown() async {
        let motion = MotionSwitch(false)
        let window = window()
        let dots = TypingDotsNSView(reduceMotion: motion.motion)
        window.contentView?.addSubview(dots)
        #expect(keys(dots).allSatisfy { $0.count == 2 })
        motion.set(true)
        #expect(await eventually { keys(dots).allSatisfy { $0.isEmpty } }, "off with the setting, not at the next turn")
        motion.set(false)
        #expect(await eventually { keys(dots).allSatisfy { $0.count == 2 } }, "and back with it")
    }

    @Test("off screen, a change of the setting starts nothing")
    func offScreenIgnoresTheSetting() async throws {
        let motion = MotionSwitch(false)
        let window = window()
        let dots = TypingDotsNSView(reduceMotion: motion.motion)
        window.contentView?.addSubview(dots)
        dots.removeFromSuperview()
        motion.set(true)
        motion.set(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(keys(dots).allSatisfy { $0.isEmpty })
    }

    @Test("with Reduce Motion on, the spectrum line stands still, dimmer at rest, and fades once to full while working")
    func spectrumStandsStill() throws {
        let motion = MotionSwitch(true)
        let view = SpectrumNSView(rate: SpectrumClock.idleRate, reduceMotion: motion.motion)
        #expect(view.drift.animation(forKey: SpectrumNSView.animationKey) == nil, "no drift")
        #expect(view.drift.contents != nil, "the gradient is still shown")
        #expect(view.fader.opacity == SpectrumNSView.stillIdleOpacity)

        view.setRate(SpectrumClock.activeRate)
        #expect(view.fader.opacity == SpectrumNSView.stillActiveOpacity)
        let up = try #require(view.fader.animation(forKey: SpectrumNSView.fadeKey) as? CABasicAnimation)
        #expect(up.keyPath == "opacity" && up.duration == 0.3)
        #expect(up.repeatCount == 0 && !up.autoreverses, "one-shot")
        #expect(up.toValue as? Float == SpectrumNSView.stillActiveOpacity)
        #expect(view.drift.animation(forKey: SpectrumNSView.animationKey) == nil, "still no drift while working")

        view.setRate(SpectrumClock.idleRate)
        #expect(view.fader.opacity == SpectrumNSView.stillIdleOpacity)
        let down = try #require(view.fader.animation(forKey: SpectrumNSView.fadeKey) as? CABasicAnimation)
        #expect(down.toValue as? Float == SpectrumNSView.stillIdleOpacity)
    }

    @Test("the spectrum line follows the setting both ways while shown")
    func spectrumFlipsBothWays() async {
        let motion = MotionSwitch(false)
        let window = window()
        let view = SpectrumNSView(rate: SpectrumClock.activeRate, reduceMotion: motion.motion)
        window.contentView?.addSubview(view)
        #expect(view.drift.animation(forKey: SpectrumNSView.animationKey) != nil)
        #expect(view.fader.opacity == 1)

        motion.set(true)
        #expect(await eventually { view.drift.animation(forKey: SpectrumNSView.animationKey) == nil },
                "the drift comes off at once")
        #expect(view.fader.opacity == SpectrumNSView.stillActiveOpacity, "working, so full")

        motion.set(false)
        #expect(await eventually { view.drift.animation(forKey: SpectrumNSView.animationKey) != nil },
                "and drifts again")
        #expect(view.fader.opacity == 1)
        #expect(view.fader.animation(forKey: SpectrumNSView.fadeKey) == nil)
    }
}
