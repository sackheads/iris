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
/// The 0..<1 `phase` is accumulated per frame in `.onChange(of:)` (a legit post-update side
/// effect that drives the redraw). Integrating the *rate* — rather than mapping absolute time
/// to phase — keeps the drift continuous when the speed changes between idle and thinking, so
/// there's no jump.
struct SpectrumLine: View {
    var active: Bool
    @State private var phase: CGFloat = 0
    @State private var last: Date?

    // Symmetric so the doubled bar loops seamlessly (first == last) and stays in the cool zone.
    private let colors: [Color] = [.irisIndigo, .irisBlue, .irisAzure, .irisTeal, .irisAzure, .irisBlue, .irisIndigo]

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    bar(width: w)
                    bar(width: w)
                }
                .offset(x: -phase * w)
            }
            .frame(height: 2)
            .clipShape(Capsule())
            .opacity(0.7)
            .onChange(of: timeline.date) { _, now in
                let rate: CGFloat = active ? 1.0 / 3.0 : 1.0 / 8.0
                if let last {
                    phase = (phase + CGFloat(now.timeIntervalSince(last)) * rate).truncatingRemainder(dividingBy: 1)
                }
                last = now
            }
        }
        .frame(height: 2)
    }

    private func bar(width: CGFloat) -> some View {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            .frame(width: width)
    }
}

// MARK: - Empty-conversation welcome

/// Shown when a conversation has no messages: the Iris icon over a soft indigo glow that
/// gently breathes, with a randomly chosen greeting.
struct IrisWelcomeView: View {
    @State private var breathe = false
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
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [Color.irisIndigo.opacity(0.45), .clear]),
                        center: .center, startRadius: 2, endRadius: 140))
                    .frame(width: 320, height: 320)
                    .blur(radius: 14)
                    .scaleEffect(breathe ? 1.06 : 0.9)
                    .opacity(breathe ? 0.9 : 0.5)

                if let icon = IrisAsset.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .scaleEffect(breathe ? 1.03 : 1.0)
                        .shadow(color: Color.irisIndigo.opacity(0.5), radius: 18)
                }
            }
            Text(greeting)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .onAppear {
            greeting = IrisWelcomeView.pickGreeting()
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
