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
/// things keep that from biting: a view or a test takes an instance (`ModelLEDBar(health:)`), so
/// only a test that specifically exercises *recording* touches `shared`; and unlike a scoped guard
/// model, a stray failure string changes no other suite's verdict — the blast radius is one LED.
@MainActor @Observable final class GuardTierHealth {
    static let shared = GuardTierHealth()

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

    /// Where a first-of-spell failure is said out loud. `AppState` installs it at launch; a test
    /// leaves it nil, or sets its own to assert on the sentence. Nil means "recorded but not
    /// announced" — the LED still changes, which is the point.
    ///
    /// The sink is here rather than at the recording site because `InjectionGuard` is a static
    /// enum with no `AppState` in reach, and giving it one to post a notice would be a much larger
    /// coupling than this closure.
    var announce: (@MainActor (String) -> Void)?

    init() {}

    /// Records a failure, and says it once per failing spell.
    ///
    /// Announcing on the *first* failure rather than at launch is deliberate: nothing has tried to
    /// load a guard model when the app starts, so "in that state at startup" is not a state that
    /// exists yet. The first guarded output is the earliest honest moment to say it — and it is
    /// also the moment the user starts getting `[CONTENT BLOCKED …]` in place of their content.
    func recordTier2Failure(_ description: String) {
        tier2Failure = description
        guard !tier2Announced else { return }
        tier2Announced = true
        announce?(Self.notice(tier: 2, description: description))
    }

    func recordTier3Failure(_ description: String) {
        tier3Failure = description
        guard !tier3Announced else { return }
        tier3Announced = true
        announce?(Self.notice(tier: 3, description: description))
    }

    /// Names the tier, what it is doing about it, and the error — a notice that says a guard is
    /// broken without saying what broke leaves the reader nowhere to go.
    static func notice(tier: Int, description: String) -> String {
        "The tier-\(tier) prompt-injection guard model is installed but failed to run, so guarded "
            + "output is being blocked rather than checked. Re-download it in Settings → Security, "
            + "or turn Tier 2 & 3 protection off there if you would rather run without it. "
            + "The error was: \(description)"
    }

    /// A tier that produced a verdict is working, whatever it said about the content.
    func clearTier2() {
        tier2Failure = nil
        tier2Announced = false
    }

    func clearTier3() {
        tier3Failure = nil
        tier3Announced = false
    }
}
