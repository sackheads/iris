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
        private var sent: [String] = []
        var prompts: [String] { lock.withLock { sent } }
        let rejudges: Bool
        init(_ answers: [String], rejudges: Bool = true) { self.answers = answers; self.rejudges = rejudges }
        var calls: [Bool?] { lock.withLock { thinks } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func canRejudgeThinking() async -> Bool { rejudges }
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock {
                thinks.append(OllamaEngine.thinkForThisCall)
                sent.append(prompt)
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

    @Test("an engine with no thinking to turn on is judged once, without the clause: today's prompt byte for byte")
    func noThinkingNoSecondJudgement() async {
        let engine = TwoStage(["MALICIOUS", "SAFE"], rejudges: false)
        #expect(!passed(await judge(engine, tag: "system_event_peer_session")))
        #expect(engine.calls.count == 1)
        let prompt = try? #require(engine.prompts.first)
        #expect(prompt?.contains(InjectionGuard.impersonationClause) == false, "the clause goes only where its block gets a second look")
    }

    @Test("an engine that can escalate is sent the clause on a message channel, and not on tool output")
    func clauseFollowsTheEngine() async {
        let channel = TwoStage(["SAFE"])
        _ = await judge(channel, tag: "system_event_peer_session")
        #expect(channel.prompts.first?.contains(InjectionGuard.impersonationClause) == true)
        let tool = TwoStage(["SAFE"])
        _ = await judge(tool, tag: "tool_output_read_file")
        #expect(tool.prompts.first?.contains(InjectionGuard.impersonationClause) == false)
    }

    /// The planner's ruling: one row per engine kind. Only Ollama can turn thinking on; llama.cpp (the default),
    /// MLX and the cloud canary can't, so they keep today's prompt (#1419 parks them). llama.cpp isn't built here
    /// (its init loads the backend); it takes the protocol's default, as the fingerprint row shows.
    @Test("only an Ollama engine can be judged again thinking on")
    func onlyOllamaEscalates() async {
        #expect(!(await CloudAuxiliaryEngine.make(role: CloudAuxiliaryEngine.canaryRole).canRejudgeThinking()))
        #expect(!(await MLXEngine().canRejudgeThinking()))
        #expect(!InjectionGuard.clauseConfigured(fingerprint(engine: "llama_cpp")))
        #expect(!InjectionGuard.clauseConfigured(fingerprint(engine: "mlx")))
        #expect(!InjectionGuard.clauseConfigured(fingerprint(engine: "cloud")))
        #expect(InjectionGuard.clauseConfigured(fingerprint(engine: "ollama")))
    }

    private func fingerprint(engine: String) -> InjectionGuard.GuardConfigFingerprint {
        InjectionGuard.GuardConfigFingerprint(
            protectionEnabled: true, promptGuardEngine: engine, promptGuardModel: "m", promptGuardCoreMLModel: "",
            tier3CloudModel: "", tier3ThinkingLevel: "", tier2ModelsDir: "/tmp", tier3ModelsDir: "/tmp",
            tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    @Test("a kept message-channel verdict's version names the clause and the escalation on Ollama only; a library read's never")
    func versionCarriesTheStages() {
        #expect(GuardVersion.promptSource(.instructionChannel).contains(InjectionGuard.messageVerdictStages))
        #expect(GuardVersion.promptSource(.instructionChannel, clause: false) == GuardVersion.promptSource(.external),
                "another engine's message channel keeps the pre-#1356 version")
        #expect(!GuardVersion.promptSource(.external).contains(InjectionGuard.messageVerdictStages))
    }
}
