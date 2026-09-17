import Foundation

/// Whether a run should switch the model-backed guards off. Only honoured when the settings
/// store is a volatile copy (see `IrisDefaults.isVolatileCopy`); otherwise ignored and logged.
enum GuardMode: Sendable { case asConfigured, off }

/// The timing captured for a headless scenario run.
struct ScenarioResult: Sendable {
    /// One `CommandProfile` per profiler turn (one per `processInput`), newest last.
    var turnProfiles: [CommandProfile]
    /// Wall-clock across all turns.
    var wallClockMs: Double
    /// The last agent message of each turn, in turn order ("" when a turn produced none).
    var finalTexts: [String]
    /// True when guards were actually switched off for this run.
    var guardsWereOff: Bool
}

/// Drives the iris core end-to-end without any UI: stands up a fresh `AppState`, builds an
/// `IrisEngine` with a fake or real client, runs the scenario's turns, and returns the
/// `PerformanceProfiler` breakdown. Consumed by both the profiling tests and `--bench`.
///
/// Runs are self-contained and safe to run concurrently: each uses its own throwaway `AppState`
/// and binds a task-local profiler sink so it collects only its own turns. It deliberately does
/// NOT mutate shared singletons (e.g. `ConfigManager`) — doing so would race with parallel work.
/// Heavy guard tiers are governed process-wide by `HeadlessMode` (set by `--bench`), not per run.
@MainActor
enum ScenarioRunner {
    static func run(_ scenario: Scenario,
                    guards: GuardMode = .asConfigured,
                    clientOverride: (any LLMClientProtocol)? = nil) async -> ScenarioResult {
        let state = AppState()
        state.autoApproveTools = true // non-interactive: never block on an approval prompt
        let conversationId = UUID()
        state.createNewConversation(id: conversationId)

        let client: any LLMClientProtocol
        if let clientOverride {
            client = clientOverride
        } else {
            switch scenario.clientMode {
            case .fake:
                let responses = scenario.scriptedResponses.map { $0.asGeminiResponse() }
                client = FakeLLMClient(responses: responses,
                                       latency: scenario.latencyMs ?? .init(minMs: 0, maxMs: 0))
            case .real:
                client = LLMClient()
            }
        }

        // Guard toggling writes through ConfigManager, whose setters persist. Only a volatile
        // copy of the store may be written to, so outside one this is a logged no-op.
        let config = ConfigManager.shared
        let savedVibecop = config.enableVibecop
        let savedGuard = config.enableAdvancedPromptInjectionProtection
        var guardsOff = false
        if guards == .off {
            if IrisDefaults.isVolatileCopy {
                config.enableVibecop = false
                config.enableAdvancedPromptInjectionProtection = false
                guardsOff = true
            } else {
                print("[ScenarioRunner] guards=off ignored: settings store is not a volatile copy")
            }
        }
        defer {
            if guardsOff {
                config.enableVibecop = savedVibecop
                config.enableAdvancedPromptInjectionProtection = savedGuard
            }
        }

        let engine = IrisEngine(state: state, tier: scenario.tier, client: client)

        // Collect this run's finished turn profiles via a task-local sink scoped to the turn loop.
        let collector = TurnCollector()
        var finalTexts: [String] = []
        let start = CFAbsoluteTimeGetCurrent()
        await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
            for turn in scenario.turns {
                await engine.processInput(turn.prompt, source: turn.source, conversationId: conversationId)
                let last = state.conversations.first { $0.id == conversationId }?
                    .messages.last { $0.role == .agent }?.content ?? ""
                finalTexts.append(last)
            }
        }
        let wallClockMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        return ScenarioResult(turnProfiles: collector.all, wallClockMs: wallClockMs,
                              finalTexts: finalTexts, guardsWereOff: guardsOff)
    }
}

/// Thread-safe accumulator for finished turn profiles (the @Sendable sink captures it).
private final class TurnCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandProfile] = []
    func append(_ p: CommandProfile) { lock.lock(); items.append(p); lock.unlock() }
    var all: [CommandProfile] { lock.lock(); defer { lock.unlock() }; return items }
}
