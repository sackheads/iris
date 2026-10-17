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
/// the view (the turn ended, the conversation got a message), nothing is left running.
class AmbientLayerView: NSView {
    /// Each animated layer with its pulses.
    var animated: [(layer: CALayer, pulses: [AmbientPulse])] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() } else { startAnimating() }
    }

    func startAnimating() {
        stopAnimating()
        let now = CACurrentMediaTime()
        for (layer, pulses) in animated {
            let start = layer.convertTime(now, from: nil)
            for pulse in pulses { layer.add(pulse.animation(startingAt: start), forKey: pulse.keyPath) }
        }
    }

    func stopAnimating() {
        for (layer, _) in animated { layer.removeAllAnimations() }
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

    func makeNSView(context: Context) -> TypingDotsNSView { TypingDotsNSView() }
    func updateNSView(_ view: TypingDotsNSView, context: Context) {}
}

final class TypingDotsNSView: AmbientLayerView {
    static let colors: [Color] = [.irisIndigo, .irisBlue, .irisTeal]
    static let delays: [CFTimeInterval] = [0.0, 0.2, 0.4]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: TypingDotsView.width, height: TypingDotsView.dotSize))
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

    func makeNSView(context: Context) -> WelcomeGlowNSView { WelcomeGlowNSView() }
    func updateNSView(_ view: WelcomeGlowNSView, context: Context) {}
}

final class WelcomeGlowNSView: AmbientLayerView {
    let glow = CALayer()
    let icon = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: WelcomeGlowView.side, height: WelcomeGlowView.side))
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
