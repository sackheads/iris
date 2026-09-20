import SwiftUI

/// A compact row of retro LED indicators showing the status of Iris's
/// inference models — like an 80s stereo receiver's status lights.
///
/// Always visible between the SpectrumLine and the message composer.
///
/// LEDs left to right:
///   PRI — Primary model tier (color-coded; pulses during inference)
///   VC  — Vibecop Guardian auxiliary model
///   P1  — Prompt Injection Tier 1 (structural guard)
///   P2  — Prompt Injection Tier 2 (CoreML / ONNX classifier)
///   P3  — Prompt Injection Tier 3 (canary probe)

// MARK: - Individual LED

struct ModelLED: View {
    let label: String
    let state: LEDState

    enum LEDState: CaseIterable {
        case off, configured, ready, active, downloading, unprovisioned

        var color: Color {
            switch self {
            case .off:           Color.gray.opacity(0.35)
            case .configured:    Color.orange.opacity(0.55)
            case .ready:         Color.green
            case .active:        Color.green
            case .downloading:   Color.orange
            // A more red-leaning, saturated orange than `.configured` — this state means the
            // guard is actively skipping tier 3, not just "not loaded yet", and the tooltip
            // should not be the only way to tell the two apart (#202 fix round 4).
            case .unprovisioned: Color(red: 0.95, green: 0.35, blue: 0.1).opacity(0.65)
            }
        }
        var glowRadius: CGFloat {
            switch self {
            case .ready, .active: 4
            case .downloading:    3
            default:              0
            }
        }
        var isPulsing: Bool { self == .active }
    }

    private let dotSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.color)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: state.color.opacity(state.glowRadius > 0 ? 0.7 : 0),
                        radius: state.glowRadius)
                .overlay(
                    Circle()
                        .stroke(state.color.opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(state.isPulsing ? 1.35 : 1.0)
                .animation(
                    state.isPulsing
                        ? Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: state.isPulsing
                )

            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(state == .off ? .secondary : .primary)
        }
        .help(tooltip)
    }

    private var tooltip: String {
        switch state {
        case .off:           return "\(label) — disabled"
        case .configured:    return "\(label) — enabled, not loaded"
        case .ready:         return "\(label) — loaded & ready"
        case .active:        return "\(label) — active"
        case .downloading:   return "\(label) — downloading"
        case .unprovisioned:
            // Shared LED state for both P2 and P3 (#210): the tooltip names whichever tier this
            // LED represents rather than hardcoding "tier 3".
            let tier = label == "P2" ? "2" : "3"
            return "\(label) — enabled, model not downloaded; tier \(tier) skipped"
        }
    }
}

// MARK: - LED Bar

struct ModelLEDBar: View {
    @Bindable var config = ConfigManager.shared
    var isThinking: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            ModelLED(label: "PRI", state: primaryState())
            ModelLED(label: "VC",  state: vibecopState())
            ModelLED(label: "P1",  state: tier1State())
            ModelLED(label: "P2",  state: tier2State())
            ModelLED(label: "P3",  state: tier3State())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.black.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: - State derivation

    /// All state functions are public so they can be unit-tested (see ModelLEDBarTests).
    ///
    /// Note: the `.downloading` branch in vibecopState(), tier2State(), and tier3State()
    /// checks `ModelDownloader.shared.isDownloading` — a concrete singleton without a
    /// protocol abstraction, so unit tests cannot exercise the downloading path. Those
    /// branches are exercised manually and through integration testing.

    func primaryState() -> ModelLED.LEDState {
        guard config.isConfigured else { return .off }
        return isThinking ? .active : .ready
    }

    func vibecopState() -> ModelLED.LEDState {
        guard config.enableVibecop else { return .off }
        let d = ModelDownloader.shared
        if d.isDownloading && d.currentDownloadName == config.vibecopModel { return .downloading }
        if config.vibecopEngine == "llama_cpp" {
            return d.isModelDownloaded(name: config.vibecopModel) ? .ready : .configured
        }
        return .ready
    }

    func tier1State() -> ModelLED.LEDState {
        config.enableAdvancedPromptInjectionProtection ? .ready : .off
    }

    func tier2State() -> ModelLED.LEDState {
        guard config.enableAdvancedPromptInjectionProtection else { return .off }
        let d = ModelDownloader.shared
        let fn = ModelDownloader.resolvedFilename(for: config.promptGuardCoreMLModel)
        if d.isDownloading && d.currentDownloadName == fn { return .downloading }
        // Delegate to the same predicate the guard itself evaluates (#210, mirror of tier 3's
        // #202 fix round 4) instead of re-deriving "downloaded" here — the two must never drift
        // apart on what counts as provisioned.
        switch InjectionGuard.tier2Provisioning(modelName: config.promptGuardCoreMLModel,
                                                 modelsDir: IrisPaths.default.modelsDir) {
        case .provisioned:
            return CoreMLEvaluator.shared.hasModelLoaded ? .ready : .configured
        case .unprovisioned, .notConfigured:
            // Unlike the other LEDs' `.configured` fallback, an absent/unconfigured tier-2 model
            // isn't just "not loaded yet" — the guard actively skips tier 2 for every evaluation
            // until this is downloaded (#210), so it gets the same distinguishing state tier 3 got
            // in #202.
            return .unprovisioned
        }
    }

    func tier3State() -> ModelLED.LEDState {
        guard config.enableAdvancedPromptInjectionProtection else { return .off }
        let d = ModelDownloader.shared
        if d.isDownloading && d.currentDownloadName == config.promptGuardModel { return .downloading }
        // Delegate to the same predicate the guard itself evaluates (#202 fix round 4) instead of
        // re-deriving "downloaded" via `ModelDownloader` here — the two must never drift apart on
        // what counts as provisioned.
        switch InjectionGuard.tier3Provisioning(engine: config.promptGuardEngine,
                                                 modelName: config.promptGuardModel,
                                                 modelsDir: IrisPaths.default.modelsDir) {
        case .provisioned:
            return .ready
        case .unprovisioned:
            // Unlike the other LEDs' `.configured` fallback, an absent tier-3 model isn't just
            // "not loaded yet" — the guard actively skips tier 3 for every evaluation until this
            // is downloaded (#202), so it gets its own, more informative state.
            return .unprovisioned
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        ModelLEDBar(isThinking: false)
        ModelLEDBar(isThinking: true)
    }
    .padding()
    .frame(width: 350)
}
#endif
