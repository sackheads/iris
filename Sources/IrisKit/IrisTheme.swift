import QuartzCore
import SwiftUI

// MARK: - Brand palette

extension Color {
    /// Iris's signature indigo-violet, sampled from the icon's inner spectrum rings.
    static let irisIndigo = Color(red: 0.42, green: 0.31, blue: 0.86)   // ~#6C4FDB
    /// Cool companion hues (blue family) for the hairline and thinking-dots triad.
    static let irisBlue = Color(red: 0.31, green: 0.61, blue: 0.86)     // ~#4F9BDB
    static let irisAzure = Color(red: 0.20, green: 0.60, blue: 0.95)    // ~#3399F2
    static let irisTeal = Color(red: 0.25, green: 0.80, blue: 0.78)     // ~#40CCC7
}

/// Colours that read differently on a light window than on a dark one (#277). Pure functions of
/// the scheme, so a test can pin them without a view.
enum IrisPalette {
    /// The LED bar's well: a dark smoke on a dark window, a faint grey on a light one, where
    /// the same 30% black read as a heavy slab.
    static func ledWell(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.07)
    }
    /// The well's edge: a light hairline is invisible on a light window, so it goes dark there.
    static func ledEdge(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.12)
    }
    /// The unlit LED: 35% grey vanishes on white.
    /// Dynamic, because the dot is a layer that resolves it by its own appearance.
    static let ledOff = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.gray.withAlphaComponent(dark ? 0.35 : 0.5)
    })
    /// The faint end of the user bubble's gradient. White text sits on it, so on a light window
    /// it stays dark enough to read.
    static func bubbleFaintOpacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.55 : 0.8 }
    /// A filled indigo button with white text: its disabled fill must still carry the white.
    static func buttonFill(enabled: Bool, _ scheme: ColorScheme) -> Color {
        enabled ? .irisIndigo : Color.irisIndigo.opacity(scheme == .dark ? 0.4 : 0.6)
    }
    /// The spectrum line: pastel hues washed to 70% vanish on white, so it is full there.
    static func spectrumOpacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.7 : 1.0 }
}

// MARK: - Icon asset

enum IrisAsset {
    /// The app icon, loaded once from the bundled resource (same file the app uses for its
    /// dock icon). `nil` only if the resource is missing.
    static let icon: NSImage? = {
        guard let path = Bundle.module.path(forResource: "iris-icon", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()
}

// MARK: - Spectrum hairline

/// A thin cool-spectrum accent line that gently drifts. It always drifts slowly; while Iris is
/// working (`active`) the drift speeds up, so the line quietly "comes alive" and settles back
/// down when she's done.
///
/// Drawn by Core Animation, not by SwiftUI (#476). A `TimelineView` ticking every frame made each
/// frame a SwiftUI update, and every SwiftUI update in the chat window lays out the whole window
/// (#530), so an idle window cost 12-16% CPU. The render server runs this animation with no work
/// on the main thread. Its colours are fixed RGB, so an appearance change has nothing to redraw.
///
/// With Reduce Motion on it stands still, the gradient still shown, and working is told by a
/// one-shot 0.3 s fade to a brighter line and back rather than by speed (#538).
struct SpectrumLine: View {
    var active: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SpectrumLayerView(rate: active ? SpectrumClock.activeRate : SpectrumClock.idleRate)
            .frame(height: 2)
            .opacity(IrisPalette.spectrumOpacity(scheme))
    }
}

/// When the drift is, in layer time: CA's `beginTime`, `timeOffset` and `speed` for the drifting
/// layer. One unit of its local time scrolls the line one full width, so `speed` is the rate in
/// widths per second. Pure, so the continuity of a rate change can be tested without a layer.
struct SpectrumClock: Equatable {
    static let idleRate = 1.0 / 8.0
    static let activeRate = 1.0 / 3.0

    var beginTime: CFTimeInterval
    var timeOffset: CFTimeInterval
    var speed: Double

    static func starting(at now: CFTimeInterval, speed: Double) -> SpectrumClock {
        SpectrumClock(beginTime: now, timeOffset: 0, speed: speed)
    }

    /// The layer's local time at `now`, as Core Animation computes it.
    func localTime(at now: CFTimeInterval) -> CFTimeInterval {
        (now - beginTime) * speed + timeOffset
    }

    /// 0..<1: how far along one width the line has scrolled.
    func phase(at now: CFTimeInterval) -> Double {
        let t = localTime(at: now)
        return t - t.rounded(.down)
    }

    /// The same drift at a new rate from `now` on: local time is carried over, so the line
    /// carries on from where it is instead of jumping.
    func switching(to speed: Double, at now: CFTimeInterval) -> SpectrumClock {
        SpectrumClock(beginTime: now, timeOffset: localTime(at: now), speed: speed)
    }
}

struct SpectrumLayerView: NSViewRepresentable {
    var rate: Double

    func makeNSView(context: Context) -> SpectrumNSView { SpectrumNSView(rate: rate, reduceMotion: .system) }
    func updateNSView(_ view: SpectrumNSView, context: Context) { view.setRate(rate) }
}

/// Hosts the drifting layer. The doubled bar is an image, and the animation scrolls its
/// `contentsRect` from the first half to the second, which is in unit coordinates: a resize
/// re-frames the layer and the animation runs on undisturbed, at the same place.
final class SpectrumNSView: NSView {
    // Symmetric so the doubled bar loops seamlessly (first == last) and stays in the cool zone.
    static let colors: [Color] = [.irisIndigo, .irisBlue, .irisAzure, .irisTeal, .irisAzure, .irisBlue, .irisIndigo]
    static let animationKey = "drift"
    static let fadeKey = "brightness"
    /// The still line's opacity under Reduce Motion: dimmer at rest, full while Iris works.
    static let stillIdleOpacity: Float = 0.6
    static let stillActiveOpacity: Float = 1
    static let fadeDuration: CFTimeInterval = 0.3

    let drift = CALayer()
    /// Holds the drift and carries the still line's brightness: the drift runs on its own clock
    /// (its `speed` is the drift rate), so a fade on it would not take 0.3 s.
    let fader = CALayer()
    private(set) var clock: SpectrumClock
    let reduceMotion: ReduceMotion
    private var motionObserver: NSObjectProtocol?

    init(rate: Double, reduceMotion: ReduceMotion) {
        clock = .starting(at: CACurrentMediaTime(), speed: rate)
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 1
        drift.contents = Self.doubledBar
        drift.contentsGravity = .resize
        drift.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        drift.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        fader.actions = ["bounds": NSNull(), "position": NSNull()]
        fader.addSublayer(drift)
        layer?.addSublayer(fader)
        apply(clock)
        applyMotion(fading: false)
    }

    var isActive: Bool { clock.speed == SpectrumClock.activeRate }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let motionObserver { reduceMotion.stopObserving(motionObserver) }
        motionObserver = nil
        guard window != nil else { return }
        motionObserver = reduceMotion.observe { [weak self] in self?.applyMotion(fading: false) }
        applyMotion(fading: false)
    }

    /// Drifting, or, with Reduce Motion on, still at the bar's first half with its brightness
    /// saying whether Iris is working. A change of the setting takes the running animations off
    /// at once, not at the next state change.
    private func applyMotion(fading: Bool) {
        if reduceMotion.isOn {
            drift.removeAnimation(forKey: Self.animationKey)
            setStillOpacity(isActive ? Self.stillActiveOpacity : Self.stillIdleOpacity, fading: fading)
        } else {
            setStillOpacity(1, fading: false)
            guard drift.animation(forKey: Self.animationKey) == nil else { return }
            let animation = CABasicAnimation(keyPath: "contentsRect")
            animation.fromValue = CGRect(x: 0, y: 0, width: 0.5, height: 1)
            animation.toValue = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            animation.duration = 1
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            drift.add(animation, forKey: Self.animationKey)
        }
    }

    private func setStillOpacity(_ opacity: Float, fading: Bool) {
        let from = fader.presentation()?.opacity ?? fader.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fader.opacity = opacity
        CATransaction.commit()
        guard fading, from != opacity else { fader.removeAnimation(forKey: Self.fadeKey); return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fader.add(fade, forKey: Self.fadeKey)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fader.frame = bounds
        drift.frame = fader.bounds
        CATransaction.commit()
    }

    func setRate(_ rate: Double) {
        guard rate != clock.speed else { return }
        clock = clock.switching(to: rate, at: CACurrentMediaTime())
        apply(clock)
        if reduceMotion.isOn { applyMotion(fading: true) }
    }

    private func apply(_ clock: SpectrumClock) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drift.beginTime = clock.beginTime
        drift.timeOffset = clock.timeOffset
        drift.speed = Float(clock.speed)
        CATransaction.commit()
    }

    /// The two bars side by side, drawn once. A smooth gradient scales without visible loss, so
    /// one image serves every width and every screen scale.
    static let doubledBar: CGImage? = {
        let colors = (SpectrumNSView.colors + SpectrumNSView.colors.dropFirst()).map { NSColor($0).cgColor } as CFArray
        let count = SpectrumNSView.colors.count * 2 - 1
        let locations = (0..<count).map { CGFloat($0) / CGFloat(count - 1) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations),
              let context = CGContext(data: nil, width: 1024, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1024, y: 0), options: [])
        return context.makeImage()
    }()
}

// MARK: - Empty-conversation welcome

/// Shown when a conversation has no messages: the Iris icon over a soft indigo glow that
/// gently breathes (`WelcomeGlowView`), with a randomly chosen greeting.
struct IrisWelcomeView: View {
    @State private var greeting = IrisWelcomeView.pickGreeting()

    private static let greetings = [
        "What's next?",
        "What can I do for you?",
        "Ready.",
        "Let's go!",
        "Where to?",
        "At your service.",
        "What are we building?",
        "Ready when you are.",
        "Point me at something."
    ]

    /// Small chance of a wink; otherwise a uniform pick from the normal set.
    private static func pickGreeting() -> String {
        if Int.random(in: 0..<20) == 0 { return "Listo pollo?" }   // ~5%
        return greetings.randomElement() ?? "Ready."
    }

    var body: some View {
        VStack(spacing: 18) {
            // Core Animation, not `.repeatForever`: a SwiftUI animation here re-laid out the whole
            // window every frame (#540).
            WelcomeGlowView().frame(width: WelcomeGlowView.side, height: WelcomeGlowView.side)
            Text(greeting)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .onAppear {
            greeting = IrisWelcomeView.pickGreeting()
        }
    }
}
