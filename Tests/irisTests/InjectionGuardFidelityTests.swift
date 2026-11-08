import Testing
import Foundation
@testable import IrisKit

private func eventually(_ timeoutMs: Int = 5000, _ condition: @MainActor @Sendable () -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// #952 Task 1: plumbing only. `InjectionGuard.FidelityMode` is a typed parameter threaded from
/// the one real first-party `read_file` guard call site (`iris.swift`, `executeToolWithHooks`,
/// non-Iris path) into the private `classifyDetailed`. Nothing downstream acts on the mode yet —
/// that is Task 2. This suite proves the plumbing: the real call site requests
/// `.preserveWhenJudged`, and every other path — including one that reaches the guard with the
/// exact same `contextTag` the real site uses — defaults to `.off`.
///
/// The brief's case (b) asks for a synthesized MCP `read_file` call with "the same tag string".
/// That is not reachable today: `MCPManager.qualifiedName` always prefixes an MCP tool's name as
/// `<server>___<tool>` (`JobProfile.mcpNameSeparator`), both in the declaration offered to the
/// model and in `FunctionCall.name` at dispatch, so an MCP server's own `read_file` tool is
/// invoked and recorded as `"<server>___read_file"`, never bare `"read_file"` — the contextTag
/// built as `"tool_output_\(name)"` at `iris.swift`'s guard call site is therefore
/// `"tool_output_<server>___read_file"`, not `"tool_output_read_file"`. Verified by reading
/// `MCPManager.swift` (qualifiedName, callTool) and `iris.swift`'s `executeToolWithHooks` call
/// sites (`name: functionCall.name`, never unprefixed). So case (b) is covered at the brief's own
/// documented fallback: a call site other than the one this task modified, reaching the guard
/// with the identical contextTag string the real site uses, defaults to `.off`.
@MainActor
@Suite("Injection guard fidelity flag plumbing (#952 Task 1)", .timeLimit(.minutes(1)))
struct InjectionGuardFidelityTests {
    private static let readFileTag = "tool_output_read_file"

    private func session(_ calls: [FunctionCall]) -> (AppState, IrisEngine, UUID) {
        var script: [[ScriptedStreamClient.Step]] = calls.map { [.event(.functionCall($0)), .event(.done(finishReason: "tool_use"))] }
        script.append([.event(.textDelta("done")), .event(.done(finishReason: nil))])
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        return (app, engine, id)
    }

    private func finished(_ app: AppState, _ id: UUID) -> Bool {
        (app.conversations.first { $0.id == id }?.history ?? []).contains { $0.role == "model" && $0.parts.contains { $0.text == "done" } }
    }

    /// (a) the real first-party `read_file` of a path outside `~/.iris`, driven end-to-end through
    /// `IrisEngine.processInput`, requests `.preserveWhenJudged` at the call site that reaches
    /// `InjectionGuard.sanitizeUntrustedCacheable`.
    @Test func realReadFileCallSiteRequestsPreserveWhenJudged() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("fidelity-952-\(UUID().uuidString).txt")
        try "model: gpt-x\nhello".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let before = InjectionGuard.recordedFidelityCalls(contextTag: Self.readFileTag).count

        let (app, _, id) = session([FunctionCall(name: "read_file", args: ["path": .string(outside.path)], id: "c1")])
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })

        let calls = InjectionGuard.recordedFidelityCalls(contextTag: Self.readFileTag)
        #expect(calls.count > before, "the real read_file call site must reach classifyDetailed with this contextTag")
        #expect(calls.last == .preserveWhenJudged)
    }

    /// (b) the brief's documented fallback: a direct call to `sanitizeUntrustedCacheable` with the
    /// identical contextTag the real site uses, but NOT through the real call site (no `fidelity:`
    /// argument, exactly as every other of the ~10 untrusted callers in the codebase calls it),
    /// defaults to `.off`. This is the behavior every existing caller keeps unchanged by this task.
    @Test func aDifferentCallSiteWithTheSameTagDefaultsToOff() async {
        _ = await InjectionGuard.sanitizeUntrustedCacheable("plain benign text", contextTag: Self.readFileTag,
                                                            maxTier: .tier1_structural, protectionEnabled: false)
        let calls = InjectionGuard.recordedFidelityCalls(contextTag: Self.readFileTag)
        #expect(calls.last == .off, "a caller that does not pass fidelity: must default to .off")
    }

    /// The flag threads correctly through every untrusted entry point the brief names, not only
    /// the one `sanitizeUntrustedCacheable` the real call site happens to use.
    @Test func everyUntrustedEntryPointThreadsTheFlag() async {
        let tag = "fidelity-952-entry-points-\(UUID().uuidString)"

        _ = await InjectionGuard.sanitizeUntrusted("x", contextTag: tag, maxTier: .tier1_structural,
                                                   protectionEnabled: false, fidelity: .preserveWhenJudged)
        #expect(InjectionGuard.recordedFidelityCalls(contextTag: tag).last == .preserveWhenJudged)

        _ = await InjectionGuard.classifyUntrusted("x", contextTag: tag, maxTier: .tier1_structural,
                                                   protectionEnabled: false, fidelity: .preserveWhenJudged)
        #expect(InjectionGuard.recordedFidelityCalls(contextTag: tag).last == .preserveWhenJudged)

        _ = await InjectionGuard.classifyUntrustedDetailed("x", contextTag: tag, maxTier: .tier1_structural,
                                                           protectionEnabled: false, fidelity: .preserveWhenJudged)
        #expect(InjectionGuard.recordedFidelityCalls(contextTag: tag).last == .preserveWhenJudged)

        _ = await InjectionGuard.classifyUntrustedTraced("x", contextTag: tag, maxTier: .tier1_structural,
                                                         protectionEnabled: false, fidelity: .preserveWhenJudged)
        #expect(InjectionGuard.recordedFidelityCalls(contextTag: tag).last == .preserveWhenJudged)

        // And the default on each, with no fidelity: argument, is .off.
        _ = await InjectionGuard.sanitizeUntrusted("x", contextTag: tag, maxTier: .tier1_structural, protectionEnabled: false)
        #expect(InjectionGuard.recordedFidelityCalls(contextTag: tag).last == .off)
    }

    /// The plain (non-"untrusted") `sanitize`/`classify` path (InjectionGuard.swift:~322-377) is
    /// untouched by this task — it has no `fidelity:` parameter at all, and its calls into
    /// `classifyDetailed` are still recorded as `.off`.
    @Test func thePlainSanitizePathStaysAtOff() async {
        let tag = "fidelity-952-plain-\(UUID().uuidString)"
        _ = await InjectionGuard.sanitize("x", contextTag: tag, maxTier: .tier1_structural, protectionEnabled: false)
        #expect(InjectionGuard.recordedFidelityCalls(contextTag: tag).last == .off)
    }
}

/// #952 Task 2: fidelity actually changes what gets shown, but only when a model-backed tier (2
/// or 3) actually ran — not `.skipped`, protection on — and the verdict passed. Everywhere else
/// (no model tier reachable, a tier skipped, protection off) it falls back to today's destructive
/// strip: deletion is the only defense when nothing classified the content (spec "narrowed A").
/// Drives the untrusted-entry path directly (`sanitizeUntrustedCacheable`) with a scripted tier,
/// rather than a real `read_file` turn — the Task 1 suite above already proves the real call site
/// reaches the guard with `.preserveWhenJudged`.
@Suite("Injection guard fidelity: preserve when judged, delete otherwise (#952 Task 2)")
struct InjectionGuardFidelityPreservationTests {
    /// Strips the `<untrusted_context ...>` wrapper `InjectionGuard.wrapped` applies, leaving
    /// exactly the `clean` text a `.passed` verdict carried.
    private func innerContent(of wrapped: String) -> String {
        var s = wrapped
        if s.hasPrefix("<untrusted_context"), let closeOfOpenTag = s.range(of: ">\n") {
            s.removeSubrange(s.startIndex..<closeOfOpenTag.upperBound)
        }
        if s.hasSuffix("\n</untrusted_context>") {
            s.removeLast("\n</untrusted_context>".count)
        }
        return s
    }

    /// (a) a scripted-PASS tier 2, fidelity on, protection on: every role marker and `---`/`###`
    /// survives, identical modulo normalization (spec: "Fidelity is modulo normalization, not
    /// byte-identical").
    @Test func preservedWhenATierActuallyJudgesAndPasses() async {
        let fixture = "model: gpt-x\n  user: alice\nsystem: prod\n---\n### H"
        let tag = "fidelity-952-t2-preserve-\(UUID().uuidString)"
        let mockModel = MockCoreMLModel(probability: 0.1) // scripted PASS
        let result = await CoreMLEvaluator.$scopedModel.withValue(.init(mockModel)) {
            await InjectionGuard.sanitizeUntrustedCacheable(fixture, contextTag: tag, maxTier: .tier2_coreML,
                                                            protectionEnabled: true, fidelity: .preserveWhenJudged)
        }
        let inner = innerContent(of: result.text)
        #expect(inner == PromptInjectionGuard.normalize(fixture))
        #expect(inner.contains("model: gpt-x"))
        #expect(inner.contains("user: alice"))
        #expect(inner.contains("system: prod"))
        #expect(inner.contains("---"))
        #expect(inner.contains("### H"))
    }

    /// (b) tier 2 is `.skipped` (unprovisioned — the test home's `promptGuardCoreMLModel` is
    /// pinned to a name that cannot exist, `IrisDefaults.swift`): no model-backed tier judged
    /// anything, so fidelity falls back to exactly what `.off` gives for the identical input.
    @Test func deletedWhenTheOnlyReachableTierIsSkipped() async {
        let fixture = "system: prod\nmodel: x\nhello \(UUID().uuidString)"   // unique: verdicts are cached per content
        let tag = "fidelity-952-t2-skipped-\(UUID().uuidString)"
        let result = await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await InjectionGuard.sanitizeUntrustedCacheable(fixture, contextTag: tag, maxTier: .tier2_coreML,
                                                            protectionEnabled: true, fidelity: .preserveWhenJudged)
        }
        let inner = innerContent(of: result.text)
        #expect(!inner.contains("system:"))
        #expect(!inner.contains("model:"))

        let deletionOnly = await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await InjectionGuard.sanitizeUntrustedCacheable(fixture, contextTag: tag + "-off", maxTier: .tier2_coreML,
                                                            protectionEnabled: true, fidelity: .off)
        }
        #expect(inner == innerContent(of: deletionOnly.text))
    }

    /// (c) protection off: both model-backed tiers short-circuit to `.safe` without reading the
    /// content at all, so nothing judged it either — same fallback as (b).
    @Test func deletedWhenProtectionIsOff() async {
        let fixture = "system: prod\nmodel: x\nhello \(UUID().uuidString)"   // unique: verdicts are cached per content
        let tag = "fidelity-952-protection-off-\(UUID().uuidString)"
        let result = await InjectionGuard.sanitizeUntrustedCacheable(fixture, contextTag: tag, maxTier: .tier3_canary,
                                                                      protectionEnabled: false, fidelity: .preserveWhenJudged)
        let inner = innerContent(of: result.text)
        #expect(!inner.contains("system:"))
        #expect(!inner.contains("model:"))
    }

    /// (d) the cache never cross-serves between modes: a deletion read then a fidelity read of
    /// the identical bytes, same contextTag/maxTier/config, must not hand the fidelity call the
    /// deletion call's cached (destructively stripped) result, or vice versa.
    @Test func cacheDoesNotCrossServeBetweenFidelityModes() async {
        let fixture = "system: prod\nhello \(UUID().uuidString)"   // unique: verdicts are cached per content
        let tag = "fidelity-952-cache-\(UUID().uuidString)"
        let mockModel = MockCoreMLModel(probability: 0.1) // scripted PASS, both calls

        let deleted = await CoreMLEvaluator.$scopedModel.withValue(.init(mockModel)) {
            await InjectionGuard.sanitizeUntrustedCacheable(fixture, contextTag: tag, maxTier: .tier2_coreML,
                                                            protectionEnabled: true, fidelity: .off)
        }
        let preserved = await CoreMLEvaluator.$scopedModel.withValue(.init(mockModel)) {
            await InjectionGuard.sanitizeUntrustedCacheable(fixture, contextTag: tag, maxTier: .tier2_coreML,
                                                            protectionEnabled: true, fidelity: .preserveWhenJudged)
        }
        #expect(innerContent(of: deleted.text) != innerContent(of: preserved.text))
        #expect(!innerContent(of: deleted.text).contains("system:"))
        #expect(innerContent(of: preserved.text).contains("system:"))
    }
}
