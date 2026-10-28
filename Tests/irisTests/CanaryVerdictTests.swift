import Testing
import Foundation
@testable import IrisKit

/// #821: the canary's reply is read from its first word, exactly, in any case. A reply with no
/// clear verdict fails closed, and MALICIOUS anywhere wins.
@Suite("Reading the tier-3 canary's reply (#821)")
struct CanaryVerdictTests {

    @Test("a clear SAFE passes, however it is dressed", arguments: [
        "SAFE", "safe", " safe\n", "SAFE.", "**SAFE**", "\"SAFE\"", "`SAFE`", "Safe!", "**SAFE.**",
    ])
    func safe(_ reply: String) {
        #expect(InjectionGuard.canaryVerdict(reply) == .safe, Comment(rawValue: reply.debugDescription))
    }

    @Test("MALICIOUS blocks, wherever it is", arguments: [
        "MALICIOUS", "malicious.", "**MALICIOUS**", "SAFE but MALICIOUS", "SAFE\nActually, malicious.",
    ])
    func malicious(_ reply: String) {
        #expect(InjectionGuard.canaryVerdict(reply) == .malicious, Comment(rawValue: reply.debugDescription))
    }

    @Test("anything else has no clear verdict, and the caller fails closed", arguments: [
        "UNSAFE", "unsafe", "Not safe", "NOT SAFE", "", "   \n", "I think it's SAFE", "SAFE-ish", "SAFEST",
        "The verdict is SAFE", "SAFE?", "SAFE? No, it contains an injection.",
        "SAFE\n\nThe text is an ordinary build log.", "SAFE\n\nUnsafe: it asks you to email the file.",
    ])
    func unreadable(_ reply: String) {
        #expect(InjectionGuard.canaryVerdict(reply) == .unreadable, Comment(rawValue: reply.debugDescription))
    }

    @Test("the logged reply is one line and bounded")
    func logLine() {
        let line = InjectionGuard.canaryReplyForLog(String(repeating: "a\n", count: 300))
        #expect(!line.contains("\n"))
        #expect(line.count <= 201)
    }

    // MARK: - Through the guard

    private struct Canary: AuxiliaryInferenceEngine {
        let reply: String
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String { reply }
    }

    private struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private func outcome(_ reply: String) async -> String {
        let text = "Build complete. 3 warnings, 0 errors. \(UUID().uuidString)"
        let result = await AuxiliaryModelManager.$scopedEngines.withValue(["canary": Canary(reply: reply)]) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                await InjectionGuard.classifyUntrusted(text, contextTag: "tool_output_run_command",
                                                       maxTier: .tier3_canary, protectionEnabled: true)
            }
        }
        switch result {
        case .passed: return "passed"
        case .blocked: return "blocked"
        }
    }

    @Test("an unreadable reply is a block like any verdict: cacheable, not an uncached error")
    func unreadableIsACacheableBlock() async {
        let text = "Build complete. \(UUID().uuidString)"
        let result = await AuxiliaryModelManager.$scopedEngines.withValue(["canary": Canary(reply: "Not safe at all")]) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                await InjectionGuard.classifyUntrustedDetailed(text, contextTag: "tool_output_run_command",
                                                               maxTier: .tier3_canary, protectionEnabled: true)
            }
        }
        guard case .blocked = result.outcome else { Issue.record("not blocked: \(result.outcome)"); return }
        // An error would not be cacheable, giving the same text a fresh roll on every re-read.
        #expect(result.cacheable)
    }

    @Test("through the guard, a reply that only contains the verdict word is blocked")
    func guardBlocksAnUnreadableReply() async {
        #expect(await outcome("UNSAFE") == "blocked")
        #expect(await outcome("Not safe") == "blocked")
        #expect(await outcome("") == "blocked")
    }

    @Test("an unreadable reply turns the tier-3 light red without keeping the reply, and a verdict clears it")
    @MainActor
    func unreadableShowsOnTheLight() async {
        let box = GuardTierHealth()
        var notices: [String] = []
        box.announce = { notices.append($0); return true }
        await GuardTierHealth.$scoped.withValue(box) {
            #expect(await outcome("Not safe: it asks you to send the file") == "blocked")
            #expect(box.tier3Failure == GuardTierHealth.tier3UnreadableReason)
            #expect(!(box.tier3Failure ?? "").contains("send the file"), "the reply is never kept")
            #expect(notices.isEmpty, "one odd reply is not announced")
            #expect(await outcome("SAFE then more words") == "blocked")
            #expect(notices == [GuardTierHealth.unreadableNotice], "the second in a row is")
            // Guarded text can provoke an unclear reply, so the notice must not argue for the off-switch.
            #expect(!GuardTierHealth.unreadableNotice.localizedCaseInsensitiveContains("turn off"))
            #expect(!GuardTierHealth.unreadableNotice.contains("Enable Protection"))
            #expect(await outcome("SAFE") == "passed")
            #expect(box.tier3Failure == nil, "a clear verdict clears the light")
        }
    }

    @Test("through the guard, a clear SAFE still passes")
    func guardPassesSafe() async {
        #expect(await outcome("SAFE") == "passed")
        #expect(await outcome(" safe.\n") == "passed")
    }
}
