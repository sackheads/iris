import Foundation

/// The last load-or-inference failure for each model-backed guard tier, and whether it has been
/// announced yet (#218).
///
/// Both tiers already distinguish "model absent" from "model present but broken". The first is
/// visible — an `.unprovisioned` LED and a launch notice. The second had no signal at all: the LED
/// read `.configured` ("enabled, not loaded") while every tool output, USER.md, AGENTS.md and
/// plugin rule was being replaced by `[CONTENT BLOCKED …]`, and only a console print said why. A
/// half-unzipped CoreML directory or a truncated gguf lands you there.
///
/// `@Observable` so the LED bar re-renders when a tier breaks or recovers, and `@MainActor`
/// because that is where it is read.
///
/// **Injectable rather than a bare singleton.** `InjectionGuard` is static and reached from
/// everywhere, so the recorder has to outlive the call and cannot be a task-local. That makes it
/// process-global state, which suites running in parallel race — the #237 / #250 family. Two
/// things keep that from biting. A view or a test takes an instance (`ModelLEDBar(health:)`), so
/// nothing here needs the singleton to render or to assert. And the *sink* — the half that writes
/// into a conversation — is installed by `IrisApp`, never by `AppState.init`: suites that drive a
/// tier into `.error` on purpose (`InjectionGuardTests`, `GuardTestIsolationTests`) would
/// otherwise persist a system message into whichever store happened to own the live `AppState`.
/// What remains shared is a failure string, which changes no other suite's verdict.
@MainActor @Observable final class GuardTierHealth {
    static let shared = GuardTierHealth()

    /// A box scoped to the current task tree, taking precedence over `shared`.
    ///
    /// The same seam `CoreMLEvaluator.scopedModel` and `AuxiliaryModelManager.scopedEngines` got
    /// for #237, and for the same reason: it is what lets a test drive `InjectionGuard`'s
    /// recording sites end to end without reading a value another suite's successful evaluation
    /// could clear between the act and the assertion. Production never sets it.
    @TaskLocal static var scoped: GuardTierHealth?

    /// What `InjectionGuard` records into: the scoped box in a test, `shared` in the app.
    static var current: GuardTierHealth { scoped ?? shared }

    /// `nil` once a tier succeeds again: a tier that recovers stops claiming to be broken without
    /// anyone having to clear it (#218, "cleared on the next success").
    private(set) var tier2Failure: String?
    private(set) var tier3Failure: String?

    /// Announced once per failing *spell*, not once per call. A broken tier is retried on every
    /// evaluation — uncached, by design — so notifying per failure would paste the same line into
    /// the conversation for every tool output. Reset when the tier recovers, so a tier that breaks
    /// again later is announced again.
    private var tier2Announced = false
    private var tier3Announced = false
    /// Consecutive failures in the current spell, so a remote engine's notice can wait for a
    /// second one. Reset with the spell.
    private var tier3Consecutive = 0

    /// Where a first-of-spell failure is said out loud. `AppState` installs it at launch; a test
    /// leaves it nil, or sets its own to assert on the sentence. Nil means "recorded but not
    /// announced" — the LED still changes, which is the point.
    ///
    /// The sink is here rather than at the recording site because `InjectionGuard` is a static
    /// enum with no `AppState` in reach, and giving it one to post a notice would be a much larger
    /// coupling than this closure.
    /// Returns whether the notice was actually delivered. A sink that could not place it — no
    /// conversation to put it in — must not let the spell be marked announced, or the first real
    /// notice is swallowed for the rest of the spell.
    var announce: (@MainActor (String) -> Bool)?

    init() {}

    /// Records a failure, and says it once per failing spell.
    ///
    /// Announcing on the *first* failure rather than at launch is deliberate: nothing has tried to
    /// load a guard model when the app starts, so "in that state at startup" is not a state that
    /// exists yet. The first guarded output is the earliest honest moment to say it — and it is
    /// also the moment the user starts getting `[CONTENT BLOCKED …]` in place of their content.
    /// The spell is marked announced only when the notice was actually *delivered* — not merely
    /// when a sink existed. The sink is installed by the app, not by `AppState.init`, so there is
    /// a window at launch (and the whole of any test run) where it is nil; and even installed, it
    /// can find nowhere to put the line. A headless `--run-job` builds an `AppState` with nothing
    /// selected, which is exactly that case.
    func recordTier2Failure(_ description: String) {
        tier2Failure = description
        guard !tier2Announced, let announce else { return }
        tier2Announced = announce(Self.notice(tier: 2, description: description))
    }

    /// `engine` decides both what the notice can honestly advise and how eager it is to say it.
    ///
    /// `tier3Provisioning` returns `.provisioned` for every engine except `llama_cpp`, so this
    /// catch is reached by a cloud 5xx, an Ollama daemon that is not running, and an MLX model
    /// that would not load — none of which has anything downloaded to re-download. Telling those
    /// users to re-download is advice they cannot follow.
    ///
    /// A local engine fails structurally: the file is corrupt now and will be corrupt next time,
    /// so it is worth saying at once. A remote one fails transiently — a restart, a blip — and a
    /// notice is a permanent message in someone's transcript, so it waits for a second consecutive
    /// failure. The LED goes red immediately either way: a light can be wrong for two seconds, a
    /// system message cannot be taken back.
    func recordTier3Failure(_ description: String, engine: String) {
        tier3Failure = description
        tier3Consecutive += 1
        guard !tier3Announced, tier3Consecutive >= Self.announceThreshold(engine: engine),
              let announce else { return }
        tier3Announced = announce(Self.notice(tier: 3, description: description, engine: engine))
    }

    /// Local engines are named; anything else is remote or a daemon.
    static func announceThreshold(engine: String) -> Int {
        ["llama_cpp", "mlx"].contains(engine) ? 1 : 2
    }

    /// Names the tier, what it is doing about it, the error, and a remedy the reader can actually
    /// apply — a notice that says a guard is broken without saying what broke leaves them nowhere
    /// to go, and one that prescribes the wrong fix is worse than that.
    ///
    /// `engine` is nil for tier 2, which is always a local CoreML/ONNX file.
    static func notice(tier: Int, description: String, engine: String? = nil) -> String {
        let subject = "The tier-\(tier) prompt-injection guard"
        let consequence = " is failing, so guarded output is being blocked rather than checked. "
        // Quoting the Settings toggle exactly: "close enough to find" is not the same as findable.
        let offSwitch = "or turn off \"Enable Protection (Tier 2 & 3)\" in Settings → Security "
            + "if you would rather run without it."
        let remedy: String
        switch engine {
        case nil, "llama_cpp", "mlx":
            remedy = "The model is installed but will not run — re-download it in "
                + "Settings → Security, " + offSwitch
        case "ollama":
            remedy = "Check that Ollama is running and reachable, " + offSwitch
        default:
            remedy = "Check the provider's key and your network, " + offSwitch
        }
        return subject + consequence + remedy + " The error was: \(description)"
    }

    /// A tier that produced a verdict is working, whatever it said about the content.
    ///
    /// Known limit: nothing clears a failure when the user *changes* the guard model or toggles
    /// protection off and on, so the LED can read red for a model that is no longer the one that
    /// broke. It corrects itself on the next successful evaluation, which is the next guarded
    /// output — every tool result, so seconds in practice. Qualifying the failure by model name
    /// would close it properly and needs a model identifier threaded into both tier executors,
    /// which is more surgery on a security path than a self-healing wrong colour is worth.
    func clearTier2() {
        // See `clearTier3`: no-op writes on an `@Observable` are not free.
        guard tier2Failure != nil || tier2Announced else { return }
        tier2Failure = nil
        tier2Announced = false
    }

    func clearTier3() {
        // Nothing recorded means nothing to invalidate: this runs after *every* successful guard
        // evaluation — every tool output — and an unconditional write still goes through
        // `withMutation`, redrawing the LED bar on every tool call for no change.
        guard tier3Failure != nil || tier3Announced || tier3Consecutive > 0 else { return }
        tier3Failure = nil
        tier3Announced = false
        tier3Consecutive = 0
    }
}
