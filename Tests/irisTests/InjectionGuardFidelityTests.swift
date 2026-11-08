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
