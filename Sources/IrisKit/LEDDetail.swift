import SwiftUI

/// The lights on `ModelLEDBar`, left to right.
enum LEDKind: CaseIterable {
    case primary, vibecop, tier1, tier2, tier3

    var label: String {
        switch self {
        case .primary: "PRI"
        case .vibecop: "VC"
        case .tier1:   "P1"
        case .tier2:   "P2"
        case .tier3:   "P3"
        }
    }

    var title: String {
        switch self {
        case .primary: "Primary model"
        case .vibecop: "Vibecop guardian"
        case .tier1:   "Prompt guard, tier 1 (structural)"
        case .tier2:   "Prompt guard, tier 2 (classifier)"
        case .tier3:   "Prompt guard, tier 3 (canary)"
        }
    }

    var tierNumber: Int? {
        switch self {
        case .tier1: 1
        case .tier2: 2
        case .tier3: 3
        default:     nil
        }
    }

    /// Where this light's settings live.
    var tab: SettingsTab {
        switch self {
        case .primary:                  .models
        case .vibecop:                  .vibecop
        case .tier1, .tier2, .tier3:    .security
        }
    }
}

extension ModelLED.LEDState {
    /// The state in words, for VoiceOver.
    var spoken: String {
        switch self {
        case .off:           "off"
        case .configured:    "not loaded"
        case .ready:         "ready"
        case .active:        "working"
        case .downloading:   "downloading"
        case .unprovisioned: "model not downloaded"
        case .error:         "failing"
        }
    }

    /// Green: nothing for the person to do.
    var isGreen: Bool { self == .ready || self == .active }
}

/// What a light's popover says (#88). A value, so a test can assert on every state's text and
/// action without a window.
struct LEDDetail: Equatable {
    struct Fact: Equatable, Hashable {
        let label: String
        let value: String
    }
    struct Action: Equatable {
        let title: String
        let tab: SettingsTab
    }

    let title: String
    let summary: String
    let facts: [Fact]
    /// The recorded error behind a red P2/P3, in full (#218).
    let failure: String?
    /// The one fix-it step, for a light that is not green.
    let action: Action?
}

extension ModelLEDBar {
    func detail(for kind: LEDKind, state: ModelLED.LEDState, failure: String?) -> LEDDetail {
        LEDDetail(title: kind.title,
                  summary: summary(for: kind, state: state),
                  facts: facts(for: kind),
                  failure: state == .error ? failure : nil,
                  action: action(for: kind, state: state))
    }

    /// The models PRI stands for. These are the configured defaults: once a conversation can have
    /// its own tier (agent profiles part 3, #669/#667), this is the seam that must take the
    /// conversation's resolved tier and say so, or the popover names the wrong model there.
    func primaryModelFacts() -> [LEDDetail.Fact] {
        [.init(label: "Provider", value: config.primaryProvider),
         .init(label: "Default model", value: orNotSet(config.getModel(for: .medium))),
         .init(label: "Default easy model", value: orNotSet(config.getModel(for: .easy))),
         .init(label: "Default hard model", value: orNotSet(config.getModel(for: .hard)))]
    }

    private func facts(for kind: LEDKind) -> [LEDDetail.Fact] {
        switch kind {
        case .primary:
            return primaryModelFacts()
        case .vibecop:
            let model: String
            if config.vibecopEngine == "cloud" {
                let chosen = config.vibecopCloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
                model = chosen.isEmpty ? "the easy model (\(orNotSet(config.getModel(for: .easy))))" : chosen
            } else {
                model = orNotSet(config.vibecopModel)
            }
            return [.init(label: "Engine", value: Self.engineName(config.vibecopEngine)),
                    .init(label: "Model", value: model)]
        case .tier1:
            return [.init(label: "Model", value: "none, rules only")]
        case .tier2:
            return [.init(label: "Model", value: orNotSet(config.promptGuardCoreMLModel)),
                    .init(label: "Models folder", value: IrisPaths.default.modelsDir.path)]
        case .tier3:
            return [.init(label: "Engine", value: Self.engineName(config.promptGuardEngine)),
                    .init(label: "Model", value: orNotSet(config.promptGuardModel))]
        }
    }

    private func summary(for kind: LEDKind, state: ModelLED.LEDState) -> String {
        let tier = kind.tierNumber.map { "Tier \($0)" } ?? ""
        switch state {
        case .off:
            switch kind {
            case .primary: return "No model provider is set up yet."
            case .vibecop: return "Vibecop is turned off."
            default:       return "Prompt injection protection is turned off."
            }
        case .configured:
            // Only VC and P2 reach this, and it means different things for each.
            if kind == .vibecop { return "The model isn't downloaded yet." }
            return "The model is downloaded. It loads the first time it checks something."
        case .ready:
            switch kind {
            case .primary: return "Ready."
            case .vibecop: return "Ready to judge commands."
            default:       return "\(tier) is checking untrusted content."
            }
        case .active:
            return "Working on a reply."
        case .downloading:
            return "The model is downloading."
        case .unprovisioned:
            // Only P2 and P3 reach this and `.error` today; the plain sentence is for any other light.
            guard kind.tierNumber != nil else { return "The model isn't downloaded." }
            return "The model isn't downloaded, so \(tier.lowercased()) is skipped and checks nothing until it is."
        case .error:
            guard kind.tierNumber != nil else { return "The model is failing." }
            // No "installed": tier 3 fails this way for cloud, Ollama and MLX too (see the tooltip).
            return "The model is failing, so \(tier.lowercased()) is blocking guarded output rather than checking it."
        }
    }

    private func action(for kind: LEDKind, state: ModelLED.LEDState) -> LEDDetail.Action? {
        switch state {
        case .ready, .active:
            return nil
        case .configured where kind != .vibecop:
            // P2's model is on disk and loads on first use: there is nothing to fix.
            return nil
        case .configured, .unprovisioned:
            return .init(title: "Download the model in Settings", tab: kind.tab)
        case .downloading:
            return .init(title: "Show the download in Settings", tab: kind.tab)
        case .off, .error:
            return .init(title: "Open \(kind.tab.title) settings", tab: kind.tab)
        }
    }

    private func orNotSet(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "not set" : trimmed
    }

    static func engineName(_ engine: String) -> String {
        switch engine {
        case "llama_cpp": "Llama.cpp (embedded)"
        case "ollama":    "Ollama"
        case "mlx":       "MLX"
        case "cloud":     "Cloud (primary provider)"
        default:          engine
        }
    }
}

/// A light's details, shown when it is clicked.
struct LEDDetailPopover: View {
    let detail: LEDDetail
    let onAction: (SettingsTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.title).font(.headline)
            Text(detail.summary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(detail.facts, id: \.self) { fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary)
                        Text(fact.value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            .font(.callout)
            if let failure = detail.failure {
                // Bounded: a recorded error can be long, and an unbounded popover grows off screen.
                ScrollView {
                    Text(failure)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            if let action = detail.action {
                Button(action.title) { onAction(action.tab) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
