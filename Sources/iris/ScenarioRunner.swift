import Foundation

/// Whether a run should switch the model-backed guards off. Only honoured when the settings
/// store is a volatile copy (see `IrisDefaults.isVolatileCopy`); otherwise ignored and logged.
enum GuardMode: Sendable { case asConfigured, off }

/// Where a run's `run_command` executes. `.sandboxed` is honoured only under a volatile settings
/// copy (it writes the main-agent sandbox default for the run); otherwise ignored and logged.
enum ToolExecutionMode: Sendable { case asConfigured, sandboxed }

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
    /// True when Vibecop was consulted (and its span recorded) before each auto-approval (#135).
    var vibecopMeasured: Bool
    /// True when the run forced `run_command` through the sandbox.
    var toolsSandboxed: Bool
    /// The throwaway conversation the run used.
    var conversationId: UUID
    /// The first `[LLM_ERROR]` headline posted during each turn, in turn order (nil when the
    /// turn had none). The engine catches provider failures and posts a tagged system message
    /// instead of throwing, so a failed turn still produces a `CommandProfile` — this is how a
    /// caller (e.g. `PerfRunner`) tells a failed rung-4/5 repetition from a successful one.
    var turnErrors: [String?]
}

/// Drives the iris core end-to-end without any UI: stands up a fresh `AppState`, builds an
/// `IrisEngine` with a fake or real client, runs the scenario's turns, and returns the
/// `PerformanceProfiler` breakdown. Consumed by both the profiling tests and `--bench`.
///
/// Runs are self-contained and safe to run concurrently: each uses its own throwaway `AppState`
/// and binds a task-local profiler sink so it collects only its own turns. The one exception is
/// `guards: .off`, which mutates process-global `ConfigManager` state (only ever inside a
/// volatile copy) with a non-reentrant save/restore, so two `.off` runs must not overlap;
/// `PerfRunner` runs them sequentially. Heavy guard tiers are governed process-wide by
/// `HeadlessMode` (set by `--bench`), not per run.
@MainActor
enum ScenarioRunner {
    /// The guards=off notice is printed once per process; PerfRunner asks for .off on every
    /// fake-lane repetition and the test process is never a volatile copy.
    private static var warnedGuardsIgnored = false

    static func run(_ scenario: Scenario,
                    guards: GuardMode = .asConfigured,
                    toolExecution: ToolExecutionMode = .asConfigured,
                    clientOverride: (any LLMClientProtocol)? = nil) async -> ScenarioResult {
        let state = AppState()
        state.autoApproveTools = true // non-interactive: never block on an approval prompt
        // Pay the Vibecop cost a real run_command pays, unless this run is measuring guards off.
        state.vibecopUnderAutoApprove = guards != .off
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
            } else if !warnedGuardsIgnored {
                warnedGuardsIgnored = true
                print("[ScenarioRunner] guards=off ignored: settings store is not a volatile copy")
            }
        }
        // Same gate as the guards: only a volatile copy may be written. Unattended real-lane
        // tool prompts otherwise execute on the host with auto-approve (a 32-command storm did).
        let savedSandbox = config.mainAgentSandboxDefault
        var sandboxed = false
        if toolExecution == .sandboxed {
            if IrisDefaults.isVolatileCopy {
                config.mainAgentSandboxDefault = .sandboxed
                sandboxed = true
            } else if !warnedGuardsIgnored {
                warnedGuardsIgnored = true
                print("[ScenarioRunner] toolExecution=sandboxed ignored: settings store is not a volatile copy")
            }
        }
        defer {
            if guardsOff {
                config.enableVibecop = savedVibecop
                config.enableAdvancedPromptInjectionProtection = savedGuard
            }
            if sandboxed { config.mainAgentSandboxDefault = savedSandbox }
        }

        let engine = IrisEngine(state: state, tier: scenario.tier, client: client)

        // Collect this run's finished turn profiles via a task-local sink scoped to the turn loop.
        let collector = TurnCollector()
        var finalTexts: [String] = []
        var turnErrors: [String?] = []
        let start = MonotonicClock.nowMs()
        await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
            for turn in scenario.turns {
                let before = state.conversations.first { $0.id == conversationId }?.messages.count ?? 0
                await engine.processInput(turn.prompt, source: turn.source, conversationId: conversationId)
                let messages = state.conversations.first { $0.id == conversationId }?.messages ?? []
                // Only the messages this turn appended: scanning the whole conversation would let
                // a turn with no agent message (e.g. an engine-level failure) inherit the previous
                // turn's text instead of reporting none.
                let turnMessages = messages.dropFirst(before)
                let last = turnMessages.last { $0.role == .agent }?.content ?? ""
                finalTexts.append(last)
                // An engine-level LLM failure is posted as a tagged system message rather than
                // thrown, so it never reaches this loop's `catch` — scanning the turn's own slice
                // is the only way to see it.
                let error = turnMessages.compactMap { LLMErrorMessage.parse($0.content)?.headline }.first
                turnErrors.append(error)
            }
        }
        let wallClockMs = (MonotonicClock.nowMs() - start)

        // Every run is a fresh conversation, so a sandboxed run leaves a VM per repetition behind
        // unless it is ended here; the CLI process has no idle reaper. No-op without a session.
        await SandboxSessionManager.shared.endSession(conversationId)

        return ScenarioResult(turnProfiles: collector.all, wallClockMs: wallClockMs,
                              finalTexts: finalTexts, guardsWereOff: guardsOff, vibecopMeasured: state.vibecopUnderAutoApprove,
                              toolsSandboxed: sandboxed, conversationId: conversationId, turnErrors: turnErrors)
    }
}

/// Thread-safe accumulator for finished turn profiles (the @Sendable sink captures it).
private final class TurnCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandProfile] = []
    func append(_ p: CommandProfile) { lock.lock(); items.append(p); lock.unlock() }
    var all: [CommandProfile] { lock.lock(); defer { lock.unlock() }; return items }
}
