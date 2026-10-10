import Testing
import Foundation
@testable import IrisKit

/// The tier-2/3 verdict for identical content is memoized for the process lifetime (#130).
/// The first ladder run showed the tier-3 cloud canary re-sanitizing the static 32-byte
/// `USER.md` on every turn, 0.7-0.9 s each time. Hits skip the model tiers entirely, so they
/// record no `guard.tier2` / `guard.tier3` span, which is how these tests observe them.
@Suite("InjectionGuard sanitization cache", .timeLimit(.minutes(1)))
struct InjectionGuardCacheTests {
    /// Run `sanitize` inside its own profiler turn and return the tier-2/3 span counts it recorded.
    private func spans(for content: String, tag: String = "cache_test",
                       maxTier: InjectionGuard.SanitizationTier = .tier3_canary,
                       protection: Bool = false) async -> (out: String, tier2: Int, tier3: Int) {
        let id = PerformanceProfiler.shared.beginTurn(label: "cache", source: "test")
        defer { PerformanceProfiler.shared.endTurn(id, totalMs: 0) }
        let out = await PerformanceProfiler.$currentTurnID.withValue(id) {
            await InjectionGuard.sanitize(content, contextTag: tag, maxTier: maxTier, protectionEnabled: protection)
        }
        let profile = PerformanceProfiler.shared.activeProfileForTesting(id)
        return (out, profile?.spans["guard.tier2"]?.count ?? 0, profile?.spans["guard.tier3"]?.count ?? 0)
    }

    private func unique(_ s: String) -> String { "\(s) \(UUID().uuidString)" }

    @Test("a second sanitize of identical content skips the model tiers and returns the same string")
    func hitSkipsModelTiers() async {
        let content = unique("static user profile")
        let first = await spans(for: content)
        let second = await spans(for: content)
        #expect(first.tier2 == 1 && first.tier3 == 1)
        #expect(second.tier2 == 0 && second.tier3 == 0)
        #expect(second.out == first.out)
    }

    @Test("different content, tag, or tier each miss")
    func keyComponents() async {
        let content = unique("agents md")
        _ = await spans(for: content)
        let otherContent = await spans(for: content + "!")
        let otherTag = await spans(for: content, tag: "other_tag")
        let otherTier = await spans(for: content, maxTier: .tier2_coreML)
        #expect(otherContent.tier3 == 1)
        #expect(otherTag.tier3 == 1)
        #expect(otherTier.tier2 == 1)
    }

    @Test("tier-1-only requests are not cached")
    func tier1Bypasses() async {
        let content = unique("plain")
        _ = await spans(for: content, maxTier: .tier1_structural)
        // A later tier-3 request for the same content must still evaluate the model tiers.
        let later = await spans(for: content)
        #expect(later.tier3 == 1)
    }

    @Test("the cache is bounded: the oldest entry is evicted past capacity")
    func eviction() async {
        let oldest = unique("oldest")
        _ = await spans(for: oldest)
        for i in 0..<InjectionGuard.sanitizationCacheCapacity {
            _ = await spans(for: unique("filler \(i)"))
        }
        let again = await spans(for: oldest)
        #expect(again.tier3 == 1)
    }

    /// The cache is process-wide, but a verdict reached under a task-scoped mock is that scope's
    /// verdict, not the process's (#375). Before this, a suite whose hijacking canary judged the
    /// default "User profile is currently empty." cached a block that every later engine with an
    /// empty USER.md then served, so a test passed alone and failed in the full run.
    private func scopedSanitize(_ content: String, hijack: Bool) async -> String {
        await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": MockInferenceEngine(shouldHijack: hijack)]) {
                await InjectionGuard.sanitize(content, contextTag: "user_profile", maxTier: .tier3_canary, protectionEnabled: true)
            }
        }
    }

    @Test("a verdict reached under one scoped canary is never served to another scope (#375)")
    func scopedVerdictStaysInItsScope() async {
        let content = unique("shared profile text")
        let blocked = await scopedSanitize(content, hijack: true)
        #expect(blocked.contains("[CONTENT BLOCKED BY TIER 3 CANARY GUARD]"))
        let clean = await scopedSanitize(content, hijack: false)
        #expect(clean.contains(content), "got: \(clean)")
        #expect(!clean.contains("[CONTENT BLOCKED"))
    }

    @Test("nor to a caller with no scope (#375)")
    func scopedVerdictNeverReachesTheProcess() async {
        let content = unique("shared profile text")
        _ = await scopedSanitize(content, hijack: true)
        // Unscoped, tier 2 and tier 3 are unprovisioned under the per-process test home and skip.
        let unscoped = await InjectionGuard.sanitize(content, contextTag: "user_profile",
                                                     maxTier: .tier3_canary, protectionEnabled: true)
        #expect(unscoped.contains(content), "got: \(unscoped)")
    }

    @Test("and a scope never reads a verdict the process cached (#375)")
    func scopeIgnoresTheProcessCache() async {
        let content = unique("shared profile text")
        _ = await InjectionGuard.sanitize(content, contextTag: "user_profile",
                                          maxTier: .tier3_canary, protectionEnabled: true)
        let blocked = await scopedSanitize(content, hijack: true)
        #expect(blocked.contains("[CONTENT BLOCKED BY TIER 3 CANARY GUARD]"), "got: \(blocked)")
    }

    @Test("a cache hit is reported cacheable: the verdict it serves was a real one")
    func hitIsCacheable() async {
        let content = unique("cacheable hit")
        let first = await InjectionGuard.sanitizeCacheable(content, contextTag: "cache_test",
                                                           maxTier: .tier3_canary, protectionEnabled: true)
        let id = PerformanceProfiler.shared.beginTurn(label: "cache", source: "test")
        defer { PerformanceProfiler.shared.endTurn(id, totalMs: 0) }
        let second = await PerformanceProfiler.$currentTurnID.withValue(id) {
            await InjectionGuard.sanitizeCacheable(content, contextTag: "cache_test",
                                                   maxTier: .tier3_canary, protectionEnabled: true)
        }
        let profile = PerformanceProfiler.shared.activeProfileForTesting(id)
        #expect((profile?.spans["guard.tier3"]?.count ?? 0) == 0, "the second call was not a cache hit")
        #expect(first.cacheable && second.cacheable)
        #expect(second.text == first.text)
    }
}
