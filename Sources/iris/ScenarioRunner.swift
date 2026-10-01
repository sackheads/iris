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
                    clientOverride: (any LLMClientProtocol)? = nil,
                    workspacePath: String? = nil,
                    dumpRequestsTo: URL? = nil,
                    factStore: FactStoreManager? = nil,
                    retryDelays: [TimeInterval] = [2, 4, 8],
                    declareStateGatedTools: Bool = false) async -> ScenarioResult {
        let state = AppState()
        state.autoApproveTools = true // non-interactive: never block on an approval prompt
        // Pay the Vibecop cost a real run_command pays, unless this run is measuring guards off.
        state.vibecopUnderAutoApprove = guards != .off
        let conversationId = UUID()
        state.createNewConversation(id: conversationId)
        // Headless real-lane runs bind a scratch directory so workspace-relative file tools land
        // there rather than in the process cwd (#151). Only run_command is sandboxed.
        if let workspacePath { state.setWorkspace(for: conversationId, path: workspacePath) }

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

        // `--dump-requests`: a sink the engine's own main-loop call site invokes directly, tagged
        // with the engine's own round and retry attempt — not a client wrapper. Wrapping the
        // client used to see every call that passed through it, including the engine's own retries
        // and any call forwarded to a grader or subagent engine built on the same client, which
        // drifted the file numbering away from `ModelCallRecord.round` (5a review F4). Passing the
        // sink only to the top-level engine built below (never to a delegated engine, which gets
        // none) keeps the dump to exactly this run's own rounds. The collector is drained and
        // cleared after each turn below, so round numbers restart at 0 per turn.
        let roundRequests = dumpRequestsTo != nil ? RoundRequestCollector() : nil
        let requestDumpSink: (@Sendable (GeminiRequest, Int, Int) -> Void)?
        if let roundRequests {
            requestDumpSink = { request, round, retryAttempt in
                roundRequests.append(request, round: round, retryAttempt: retryAttempt)
            }
        } else {
            requestDumpSink = nil
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

        // Safety net for exit paths that skip the awaited teardown below (`defer` cannot await,
        // so this detaches; endSession is idempotent).
        defer { Task { await SandboxSessionManager.shared.endSession(conversationId) } }

        // Seed the fact store before turn 1 so a scenario like `caching` gets a deterministic
        // fact-store block: turns after this can rely on exactly these facts being present.
        // Best-effort — a seeding failure must not fail the whole scenario run (5a). Never
        // `.shared`, the process-global (or, outside a test process, the developer's real
        // on-disk) fact store: a caller-injected store is used as-is; otherwise, when this
        // scenario has seeds, a fresh in-memory store is minted for this run alone, unconditionally
        // — so a repetition never sees another repetition's seeds and a real-lane run never
        // inherits the developer's own facts (5a fix round 2, review finding #1/#2). There is no
        // hazard left to gate on: the fresh store never touches `.shared` or any on-disk home, fake
        // lane or real, volatile copy or not (5a review F5).
        let seedFacts = scenario.seedFacts ?? []
        let effectiveFactStore: FactStoreManager?
        if let factStore {
            effectiveFactStore = factStore
            for fact in seedFacts {
                _ = try? factStore.addFact(content: fact)
            }
        } else if !seedFacts.isEmpty {
            let fresh = try? FactStoreManager(inMemory: true)
            for fact in seedFacts {
                _ = try? fresh?.addFact(content: fact)
            }
            effectiveFactStore = fresh
        } else {
            effectiveFactStore = nil
        }

        // `AppState.init` auto-creates a conversation and this run adds its own above, so the
        // real peer count here is always >= 1 — the #185 session tools would land on every
        // perf-scenario turn and shift the #129/#144 declaration-size baselines this runner
        // exists to measure. Pin it off, matching `ToolSurfaceTrimTests`.
        let engine = IrisEngine(state: state, tier: scenario.tier, client: client, retryDelays: retryDelays,
                               factStore: effectiveFactStore, sessionPeerCount: 0, requestDumpSink: requestDumpSink,
                               declareStateGatedTools: declareStateGatedTools)

        // Collect this run's finished turn profiles via a task-local sink scoped to the turn loop.
        let collector = TurnCollector()
        var finalTexts: [String] = []
        var turnErrors: [String?] = []
        let start = MonotonicClock.nowMs()
        await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
            for (turnIndex, turn) in scenario.turns.enumerated() {
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

                if let dumpRequestsTo, let roundRequests {
                    writeRequestDumps(roundRequests.drain(), turn: turnIndex + 1, to: dumpRequestsTo, tier: scenario.tier)
                }
            }
        }
        let wallClockMs = (MonotonicClock.nowMs() - start)

        // Every run is a fresh conversation, so a sandboxed run leaves a VM per repetition behind
        // unless it is ended here; the CLI process has no idle reaper. No-op without a session.
        // Awaited here so callers (and tests) observe the teardown; the defer above is the net
        // for any exit path a future change adds, since a defer body cannot await.
        await SandboxSessionManager.shared.endSession(conversationId)

        return ScenarioResult(turnProfiles: collector.all, wallClockMs: wallClockMs,
                              finalTexts: finalTexts, guardsWereOff: guardsOff, vibecopMeasured: state.vibecopUnderAutoApprove,
                              toolsSandboxed: sandboxed, conversationId: conversationId, turnErrors: turnErrors)
    }

    /// Writes one turn's recorded requests as `<dir>/<turn>-<round>.json`, keyed on the engine's
    /// own round and retry attempt rather than call order, so files pair 1:1 with the profiler's
    /// `ModelCallRecord.round` even across a retry: a retry is named `<turn>-<round>-retry<k>.json`
    /// explicitly rather than shifting into the next round's slot (5a review F4). Uses the
    /// currently configured provider, model and streaming flag so the body matches what a real
    /// call would build (5a) — `RequestDump` used to hardcode non-streaming while production
    /// streams by default, so a dump never matched an actual turn's body (5a review #11). Best
    /// effort: a write failure is logged, not thrown, so `--dump-requests` never fails the run it
    /// is only meant to observe.
    private static func writeRequestDumps(_ entries: [RoundRequestCollector.Entry], turn: Int, to dir: URL, tier: ModelTier) {
        guard !entries.isEmpty else { return }
        let provider = ConfigManager.shared.primaryProvider
        let model = ConfigManager.shared.getModel(for: tier)
        let stream = ConfigManager.shared.streamResponses
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[ScenarioRunner] --dump-requests: could not create \(dir.path): \(error)")
            return
        }
        for entry in entries {
            let name = entry.retryAttempt == 0 ? "\(turn)-\(entry.round).json" : "\(turn)-\(entry.round)-retry\(entry.retryAttempt).json"
            do {
                let data = try RequestDump.body(for: entry.request, provider: provider, model: model, stream: stream)
                try data.write(to: dir.appendingPathComponent(name))
            } catch {
                print("[ScenarioRunner] --dump-requests: failed to write turn \(turn) round \(entry.round): \(error)")
            }
        }
    }
}

/// Thread-safe accumulator for one turn's recorded requests, used by `--dump-requests`. Each entry
/// is tagged with the engine's own round and retry attempt (0 = original call) at the main-loop
/// call site itself, not inferred from call order (5a review F4). `drain` both returns and clears
/// so numbering restarts at 0 for the next turn.
private final class RoundRequestCollector: @unchecked Sendable {
    struct Entry { var round: Int; var retryAttempt: Int; var request: GeminiRequest }
    private let lock = NSLock()
    private var items: [Entry] = []
    func append(_ request: GeminiRequest, round: Int, retryAttempt: Int) {
        lock.lock(); items.append(Entry(round: round, retryAttempt: retryAttempt, request: request)); lock.unlock()
    }
    func drain() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let out = items; items = []; return out
    }
}

/// Thread-safe accumulator for finished turn profiles (the @Sendable sink captures it).
private final class TurnCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandProfile] = []
    func append(_ p: CommandProfile) { lock.lock(); items.append(p); lock.unlock() }
    var all: [CommandProfile] { lock.lock(); defer { lock.unlock() }; return items }
}
