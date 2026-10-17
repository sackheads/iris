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
/// on the main thread. Like the SwiftUI version, it ignores Reduce Motion, and its colours are
/// fixed RGB, so an appearance change has nothing to redraw.
struct SpectrumLine: View {
    var active: Bool

    var body: some View {
        SpectrumLayerView(rate: active ? SpectrumClock.activeRate : SpectrumClock.idleRate)
            .frame(height: 2)
            .opacity(0.7)
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

    func makeNSView(context: Context) -> SpectrumNSView { SpectrumNSView(rate: rate) }
    func updateNSView(_ view: SpectrumNSView, context: Context) { view.setRate(rate) }
}

/// Hosts the drifting layer. The doubled bar is an image, and the animation scrolls its
/// `contentsRect` from the first half to the second, which is in unit coordinates: a resize
/// re-frames the layer and the animation runs on undisturbed, at the same place.
final class SpectrumNSView: NSView {
    // Symmetric so the doubled bar loops seamlessly (first == last) and stays in the cool zone.
    static let colors: [Color] = [.irisIndigo, .irisBlue, .irisAzure, .irisTeal, .irisAzure, .irisBlue, .irisIndigo]
    static let animationKey = "drift"

    let drift = CALayer()
    private(set) var clock: SpectrumClock

    init(rate: Double) {
        clock = .starting(at: CACurrentMediaTime(), speed: rate)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 1
        drift.contents = Self.doubledBar
        drift.contentsGravity = .resize
        drift.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        layer?.addSublayer(drift)
        apply(clock)
        let animation = CABasicAnimation(keyPath: "contentsRect")
        animation.fromValue = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        animation.toValue = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        animation.duration = 1
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        drift.add(animation, forKey: Self.animationKey)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drift.frame = bounds
        CATransaction.commit()
    }

    func setRate(_ rate: Double) {
        guard rate != clock.speed else { return }
        clock = clock.switching(to: rate, at: CACurrentMediaTime())
        apply(clock)
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
