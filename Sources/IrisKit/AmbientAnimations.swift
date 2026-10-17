import AppKit
import QuartzCore
import SwiftUI

/// One repeating property animation, as Core Animation runs it (#540). A SwiftUI
/// `.repeatForever` animation inside the chat window re-lays out the whole window on every frame
/// (8.6% CPU for the typing dots, 10-12% for the welcome throb); the render server runs these
/// with no work on the main thread. Pure, so its timing can be tested without a layer.
struct AmbientPulse: Equatable {
    var keyPath: String
    var from: Double
    var to: Double
    var duration: CFTimeInterval
    var delay: CFTimeInterval = 0
    /// Where the layer stands under Reduce Motion (#538): `to`, the peak, unless a pulse whose
    /// peak is the moving state (the LED's 1.35) says otherwise.
    var still: Double? = nil

    /// The curve the animation is eased with. `progress(at:)` evaluates the same one, from its
    /// own control points, so the pure model and the shipped animation cannot drift apart.
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }

    /// 0 at `from`, 1 at `to`: up over `duration`, back over the next, from `delay` on, on
    /// `timing`'s curve. Before `delay` it holds at `from`, as the animation's backwards fill does.
    func progress(at elapsed: CFTimeInterval) -> Double {
        let t = elapsed - delay
        guard t > 0 else { return 0 }
        let cycle = t.truncatingRemainder(dividingBy: 2 * duration)
        let linear = cycle <= duration ? cycle / duration : 2 - cycle / duration
        return Self.eased(linear)
    }

    /// `timing` at `x` (0...1): the cubic Bézier through (0,0), c1, c2, (1,1), solved for the
    /// parameter whose x is `x` (Newton, then bisection if it stalls), then its y.
    static func eased(_ x: Double) -> Double {
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &c1)
        timing.getControlPoint(at: 2, values: &c2)
        let (x1, y1, x2, y2) = (Double(c1[0]), Double(c1[1]), Double(c2[0]), Double(c2[1]))
        func bez(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        func dbez(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
        }
        let x = min(max(x, 0), 1)
        var t = x
        for _ in 0..<8 {
            let err = bez(t, x1, x2) - x
            if abs(err) < 1e-12 { break }
            let slope = dbez(t, x1, x2)
            if abs(slope) < 1e-9 { break }
            t -= err / slope
        }
        if abs(bez(t, x1, x2) - x) > 1e-9 || t < 0 || t > 1 {
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 {
                t = (lo + hi) / 2
                if bez(t, x1, x2) < x { lo = t } else { hi = t }
            }
        }
        return bez(t, y1, y2)
    }

    func value(at elapsed: CFTimeInterval) -> Double { from + (to - from) * progress(at: elapsed) }

    /// The animation, starting `delay` after `start` in the layer's own time.
    func animation(startingAt start: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = start + delay
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.fillMode = .backwards
        animation.timingFunction = Self.timing
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// An NSView whose layers animate only while it is in a window: shown, they start; removed with
/// the view (the turn ended, the conversation got a message), nothing is left running. With
/// Reduce Motion on they stand still at each pulse's peak instead (#538), and a change of the
/// setting while shown takes effect at once.
class AmbientLayerView: NSView {
    /// Each animated layer with its pulses.
    var animated: [(layer: CALayer, pulses: [AmbientPulse])] = []
    let reduceMotion: ReduceMotion
    private var motionObserver: NSObjectProtocol?

    init(frame: NSRect, reduceMotion: ReduceMotion = .system) {
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let motionObserver { reduceMotion.stopObserving(motionObserver) }
        motionObserver = nil
        if window == nil { stopAnimating(); return }
        motionObserver = reduceMotion.observe { [weak self] in
            guard let self, self.window != nil else { return }
            self.startAnimating()
        }
        startAnimating()
    }

    func startAnimating() {
        stopAnimating()
        if reduceMotion.isOn { holdStill(); return }
        let now = CACurrentMediaTime()
        for (layer, pulses) in animated {
            let start = layer.convertTime(now, from: nil)
            for pulse in pulses { layer.add(pulse.animation(startingAt: start), forKey: pulse.keyPath) }
        }
    }

    func stopAnimating() {
        for (layer, _) in animated { layer.removeAllAnimations() }
    }

    /// Each layer at its pulse's `still`: by default its peak, so the dots at full size and the
    /// glow at its fullest.
    private func holdStill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, pulses) in animated {
            for pulse in pulses { layer.setValue(pulse.still ?? pulse.to, forKeyPath: pulse.keyPath) }
        }
        CATransaction.commit()
    }
}

// MARK: - Typing dots

/// The three dots beside "Iris is thinking...": each grows from half size and fades in over
/// 0.6 s and back, the second 0.2 s and the third 0.4 s behind the first.
struct TypingDotsView: NSViewRepresentable {
    static let dotSize: CGFloat = 6
    static let spacing: CGFloat = 4
    static let width = dotSize * 3 + spacing * 2

    static func pulses(delay: CFTimeInterval) -> [AmbientPulse] {
        [AmbientPulse(keyPath: "transform.scale", from: 0.5, to: 1.0, duration: 0.6, delay: delay),
         AmbientPulse(keyPath: "opacity", from: 0.3, to: 1.0, duration: 0.6, delay: delay)]
    }

    func makeNSView(context: Context) -> TypingDotsNSView { TypingDotsNSView(reduceMotion: .system) }
    func updateNSView(_ view: TypingDotsNSView, context: Context) {}
}

final class TypingDotsNSView: AmbientLayerView {
    static let colors: [Color] = [.irisIndigo, .irisBlue, .irisTeal]
    static let delays: [CFTimeInterval] = [0.0, 0.2, 0.4]

    init(reduceMotion: ReduceMotion) {
        super.init(frame: NSRect(x: 0, y: 0, width: TypingDotsView.width, height: TypingDotsView.dotSize),
                   reduceMotion: reduceMotion)
        animated = zip(Self.colors, Self.delays).map { color, delay in
            let dot = CALayer()
            dot.backgroundColor = NSColor(color).cgColor
            dot.cornerRadius = TypingDotsView.dotSize / 2
            dot.transform = CATransform3DMakeScale(0.5, 0.5, 1)
            dot.opacity = 0.3
            layer?.addSublayer(dot)
            return (dot, TypingDotsView.pulses(delay: delay))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = TypingDotsView.dotSize
        for (index, entry) in animated.enumerated() {
            entry.layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            entry.layer.position = CGPoint(x: size / 2 + CGFloat(index) * (size + TypingDotsView.spacing),
                                           y: bounds.midY)
        }
        CATransaction.commit()
    }
}

// MARK: - Welcome glow

/// The empty conversation's icon over its indigo glow, breathing on a 2.6 s cycle: the glow from
/// 0.9 to 1.06 times its size and from half to 0.9 opacity, the icon to 1.03 times its size.
struct WelcomeGlowView: NSViewRepresentable {
    static let side: CGFloat = 320
    static let iconSide: CGFloat = 120
    static let glowPulses = [AmbientPulse(keyPath: "transform.scale", from: 0.9, to: 1.06, duration: 2.6),
                             AmbientPulse(keyPath: "opacity", from: 0.5, to: 0.9, duration: 2.6)]
    static let iconPulses = [AmbientPulse(keyPath: "transform.scale", from: 1.0, to: 1.03, duration: 2.6)]

    func makeNSView(context: Context) -> WelcomeGlowNSView { WelcomeGlowNSView(reduceMotion: .system) }
    func updateNSView(_ view: WelcomeGlowNSView, context: Context) {}
}

final class WelcomeGlowNSView: AmbientLayerView {
    let glow = CALayer()
    let icon = CALayer()

    init(reduceMotion: ReduceMotion) {
        super.init(frame: NSRect(x: 0, y: 0, width: WelcomeGlowView.side, height: WelcomeGlowView.side),
                   reduceMotion: reduceMotion)
        glow.contents = Self.glowImage
        glow.contentsGravity = .resize
        glow.opacity = 0.5
        glow.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        icon.contents = IrisAsset.icon
        icon.contentsGravity = .resizeAspect
        icon.shadowColor = NSColor(Color.irisIndigo).cgColor
        icon.shadowOpacity = 0.5
        icon.shadowRadius = 18
        icon.shadowOffset = .zero
        // Rasterized: a shadow with no path is redrawn by the render server on every frame of the
        // icon's scale animation. A 3% scale of a cached bitmap reads the same.
        icon.shouldRasterize = true
        layer?.addSublayer(glow)
        layer?.addSublayer(icon)
        animated = [(glow, WelcomeGlowView.glowPulses), (icon, WelcomeGlowView.iconPulses)]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        icon.rasterizationScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        glow.bounds = CGRect(x: 0, y: 0, width: WelcomeGlowView.side, height: WelcomeGlowView.side)
        glow.position = center
        icon.bounds = CGRect(x: 0, y: 0, width: WelcomeGlowView.iconSide, height: WelcomeGlowView.iconSide)
        icon.position = center
        CATransaction.commit()
    }

    /// The glow as SwiftUI drew it, rendered once: a radial indigo fade, blurred.
    @MainActor static let glowImage: CGImage? = {
        let renderer = ImageRenderer(content:
            Circle()
                .fill(RadialGradient(gradient: Gradient(colors: [Color.irisIndigo.opacity(0.45), .clear]),
                                     center: .center, startRadius: 2, endRadius: 140))
                .frame(width: WelcomeGlowView.side, height: WelcomeGlowView.side)
                .blur(radius: 14))
        renderer.scale = 2
        return renderer.cgImage
    }()
}

// MARK: - Model LED

/// A model LED's dot (#557): its colour, a 1 pt ring of that colour at 0.3, and its glow, growing
/// to 1.35 times its size over 0.6 s and back for as long as the LED is active.
struct LEDDotView: NSViewRepresentable {
    static let side: CGFloat = 10
    /// Stands still at full size under Reduce Motion, not at its 1.35 peak, which is the moving state.
    static let pulse = AmbientPulse(keyPath: "transform.scale", from: 1.0, to: 1.35, duration: 0.6, still: 1.0)
    let state: ModelLED.LEDState

    func makeNSView(context: Context) -> LEDDotNSView { LEDDotNSView(state: state, reduceMotion: .system) }
    func updateNSView(_ view: LEDDotNSView, context: Context) { view.state = state }
}

/// Unlike the dots and the glow, this view stays on screen while its animation comes and goes: the
/// primary LED goes active for every turn and back to ready after it.
final class LEDDotNSView: AmbientLayerView {
    let dot = CAShapeLayer()
    var state: ModelLED.LEDState {
        didSet {
            guard state != oldValue else { return }
            applyColors()
            pulse(wasPulsing: oldValue.isPulsing)
        }
    }

    init(state: ModelLED.LEDState, reduceMotion: ReduceMotion) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: LEDDotView.side, height: LEDDotView.side),
                   reduceMotion: reduceMotion)
        let circle = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: LEDDotView.side, height: LEDDotView.side),
                            transform: nil)
        dot.path = circle
        // The glow's shape given, so the render server doesn't derive it from the pixels each frame.
        dot.shadowPath = circle
        dot.shadowOffset = .zero
        dot.lineWidth = 1
        layer?.addSublayer(dot)
        applyColors()
        animated = [(dot, state.isPulsing ? [LEDDotView.pulse] : [])]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func pulse(wasPulsing: Bool) {
        animated = [(dot, state.isPulsing ? [LEDDotView.pulse] : [])]
        guard state.isPulsing != wasPulsing, window != nil else { return }
        if state.isPulsing { startAnimating() } else { settle() }
    }

    private func settle() {
        settle(from: dot.presentation()?.value(forKeyPath: "transform.scale") as? Double ?? 1)
    }

    /// Back to full size from `scale`, where the pulse was, as SwiftUI's default animation took it,
    /// rather than a jump. Internal so a test can give the scale a headless layer never has.
    func settle(from scale: Double) {
        stopAnimating()
        guard scale != 1 else { return }
        let back = CABasicAnimation(keyPath: "transform.scale")
        back.fromValue = scale
        back.toValue = 1.0
        back.duration = 0.2
        back.timingFunction = AmbientPulse.timing
        dot.add(back, forKey: "settle")
    }

    /// How the dot is drawn, apart from its pulse. Under Reduce Motion an active LED stands still
    /// (#561), and the pulse was all that told it from a ready one: both are the same green with the
    /// same glow. So it holds a cue instead (#538): a brighter fill, the colour blended toward
    /// white, and a stronger, fuller glow. With motion on, it is drawn exactly as before.
    struct Look: Equatable {
        var brighten: CGFloat
        var glowRadius: CGFloat
        var glowOpacity: Float

        static func of(_ state: ModelLED.LEDState, reduceMotion: Bool) -> Look {
            if reduceMotion && state == .active { return Look(brighten: 0.35, glowRadius: 7, glowOpacity: 1) }
            return Look(brighten: 0, glowRadius: state.glowRadius, glowOpacity: state.glowRadius > 0 ? 0.7 : 0)
        }
    }

    /// The state's colours as this view's appearance resolves them: `Color.green` is dynamic, and a
    /// CGColor is not.
    private func applyColors() {
        let look = Look.of(state, reduceMotion: reduceMotion.isOn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var base = NSColor(state.color)
            if look.brighten > 0, let rgb = base.usingColorSpace(.sRGB),
               let lit = rgb.blended(withFraction: look.brighten, of: .white) {
                base = lit
            }
            let color = base.cgColor
            dot.fillColor = color
            dot.strokeColor = color.copy(alpha: color.alpha * 0.3)
            dot.shadowColor = color
        }
        dot.shadowOpacity = look.glowOpacity
        dot.shadowRadius = look.glowRadius
        CATransaction.commit()
    }

    /// Joining a window, or the Reduce Motion setting changing, starts the animations over; the
    /// cue follows the setting with them.
    override func startAnimating() {
        super.startAnimating()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(x: 0, y: 0, width: LEDDotView.side, height: LEDDotView.side)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}
