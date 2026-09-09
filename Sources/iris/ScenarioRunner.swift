import Foundation

/// The timing captured for a headless scenario run.
struct ScenarioResult: Sendable {
    /// One `CommandProfile` per profiler turn (one per `processInput`), newest last.
    var turnProfiles: [CommandProfile]
    /// Wall-clock across all turns.
    var wallClockMs: Double
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
    static func run(_ scenario: Scenario) async -> ScenarioResult {
        let state = AppState()
        state.autoApproveTools = true // non-interactive: never block on an approval prompt
        let conversationId = UUID()
        state.createNewConversation(id: conversationId)

        let client: any LLMClientProtocol
        switch scenario.clientMode {
        case .fake:
            let responses = scenario.scriptedResponses.map { $0.asGeminiResponse() }
            client = FakeLLMClient(responses: responses,
                                   latency: scenario.latencyMs ?? .init(minMs: 0, maxMs: 0))
        case .real:
            client = LLMClient()
        }

        let engine = IrisEngine(state: state, tier: scenario.tier, client: client)

        // Collect this run's finished turn profiles via a task-local sink scoped to the turn loop.
        let collector = TurnCollector()
        let start = CFAbsoluteTimeGetCurrent()
        await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
            for turn in scenario.turns {
                await engine.processInput(turn.prompt, source: turn.source, conversationId: conversationId)
            }
        }
        let wallClockMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        return ScenarioResult(turnProfiles: collector.all, wallClockMs: wallClockMs)
    }
}

/// Thread-safe accumulator for finished turn profiles (the @Sendable sink captures it).
private final class TurnCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandProfile] = []
    func append(_ p: CommandProfile) { lock.lock(); items.append(p); lock.unlock() }
    var all: [CommandProfile] { lock.lock(); defer { lock.unlock() }; return items }
}
