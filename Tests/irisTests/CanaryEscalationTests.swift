import Testing
import Foundation
@testable import IrisKit

/// #1356 (Brian, 11-26: "2: e"): on a message channel the canary's quick judgement runs with thinking off, and only a
/// MALICIOUS is judged again with the model thinking. That second answer is final. Tool output, library and external
/// reads are judged once, as before.
@Suite("a message channel's canary block is judged again with thinking on (#1356)", .timeLimit(.minutes(1)))
struct CanaryEscalationTests {
    /// Answers each call from `answers` in turn, and records the `think` override each call ran under.
    private final class TwoStage: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String]
        private var thinks: [Bool?] = []
        let rejudges: Bool
        init(_ answers: [String], rejudges: Bool = true) { self.answers = answers; self.rejudges = rejudges }
        var calls: [Bool?] { lock.withLock { thinks } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func canRejudgeThinking() async -> Bool { rejudges }
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock {
                thinks.append(OllamaEngine.thinkForThisCall)
                return answers.isEmpty ? "SAFE" : answers.removeFirst()
            }
        }
    }

    private struct Passing: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private func judge(_ engine: TwoStage, tag: String) async -> InjectionGuard.GuardOutcome {
        await AuxiliaryModelManager.$scopedEngines.withValue(["canary": engine]) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(Passing())) {
                await InjectionGuard.classifyUntrusted("a message \(UUID().uuidString)", contextTag: tag,
                                                       maxTier: .tier3_canary, protectionEnabled: true)
            }
        }
    }

    private func passed(_ o: InjectionGuard.GuardOutcome) -> Bool { if case .passed = o { return true }; return false }

    @Test("a message channel's MALICIOUS is judged again thinking on, and a SAFE then passes it",
          arguments: ["system_event_peer_session", "peer_topic", "inbox_emit"])
    func secondJudgementClears(tag: String) async {
        let engine = TwoStage(["MALICIOUS", "SAFE"])
        #expect(passed(await judge(engine, tag: tag)))
        #expect(engine.calls == [nil, true], "the first with the engine's own setting, the second asked to think")
    }

    @Test("a MALICIOUS the second judgement repeats stays blocked")
    func secondJudgementConfirms() async {
        let engine = TwoStage(["MALICIOUS", "MALICIOUS"])
        #expect(!passed(await judge(engine, tag: "system_event_peer_session")))
        #expect(engine.calls.count == 2)
    }

    @Test("an unreadable second answer fails closed, as a first one does (#821)")
    func unreadableSecondFailsClosed() async {
        let engine = TwoStage(["MALICIOUS", "I think this is probably fine"])
        #expect(!passed(await judge(engine, tag: "system_event_peer_session")))
    }

    @Test("a SAFE is never judged again")
    func safeIsFinal() async {
        let engine = TwoStage(["SAFE"])
        #expect(passed(await judge(engine, tag: "system_event_peer_session")))
        #expect(engine.calls == [nil])
    }

    @Test("tool output, a library read included, is judged once: its block is final",
          arguments: ["tool_output_read_file", "tool_output_run_command", "system_event_SubagentManager"])
    func toolOutputIsJudgedOnce(tag: String) async {
        let engine = TwoStage(["MALICIOUS", "SAFE"])
        #expect(!passed(await judge(engine, tag: tag)))
        #expect(engine.calls == [nil])
    }

    @Test("an engine with no thinking to turn on is judged once")
    func noThinkingNoSecondJudgement() async {
        let engine = TwoStage(["MALICIOUS", "SAFE"], rejudges: false)
        #expect(!passed(await judge(engine, tag: "system_event_peer_session")))
        #expect(engine.calls.count == 1)
    }

    @Test("a kept message-channel verdict's version names the escalation; a library read's doesn't")
    func versionCarriesTheStages() {
        #expect(GuardVersion.promptSource(.instructionChannel).contains(InjectionGuard.messageVerdictStages))
        #expect(!GuardVersion.promptSource(.external).contains(InjectionGuard.messageVerdictStages))
    }
}
