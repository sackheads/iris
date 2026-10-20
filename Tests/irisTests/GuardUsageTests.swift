import Testing
import Foundation
@testable import IrisKit

/// #689: a cloud guard call's tokens (Vibecop's cloud engine, the tier-3 canary) are charged to
/// whatever caused the call, not thrown away. One test per guard path, each charged to the right
/// conversation or run; nothing here touches a process-global setting (Invariant 7).
@MainActor
@Suite("Cloud guard calls are charged (#689)", .timeLimit(.minutes(1)))
struct GuardUsageTests {
    nonisolated private static let usage = UsageMetadata(promptTokenCount: 120, candidatesTokenCount: 30, totalTokenCount: 150)

    /// The cloud engine with a scripted provider answer that carries usage.
    private func cloudEngine(_ text: String, role: String) -> CloudAuxiliaryEngine {
        var engine = CloudAuxiliaryEngine()
        engine.role = role
        engine.model = { nil }
        engine.send = { _, _ in
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                           usageMetadata: Self.usage)
        }
        return engine
    }

    private func isolatedConfig(vibecop: Bool) -> (ConfigManager, () -> Void) {
        let name = "iris-guardusage-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let config = ConfigManager(store: store)
        config.enableVibecop = vibecop
        return (config, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    @Test("a report goes to the bound sink; with none bound, it's logged once and never silently dropped")
    func sinkOrLog() async {
        let recorded = LockedUsage()
        await GuardUsage.$sink.withValue(GuardUsage.Sink { recorded.add($0) }) {
            await GuardUsage.report(Self.usage, role: "test-bound")
        }
        #expect(recorded.prompt == 120)
        let role = "test-unbound-\(UUID().uuidString)"
        #expect(!GuardUsage.wasUnattributed(role))
        await GuardUsage.report(Self.usage, role: role)
        #expect(GuardUsage.wasUnattributed(role))
    }

    @Test("the cloud engine reports its call's usage to the bound sink")
    func engineReports() async throws {
        let recorded = LockedUsage()
        let engine = cloudEngine("SAFE", role: "canary")
        _ = try await GuardUsage.$sink.withValue(GuardUsage.Sink { recorded.add($0) }) {
            try await engine.generate(prompt: "x", jsonSchema: nil)
        }
        #expect(recorded.prompt == 120 && recorded.output == 30)
    }

    @Test("Vibecop on an approval in a conversation is charged to that conversation")
    func vibecopInConversation() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        state.vibecopEnabledOverride = true
        let id = state.createNewConversation(isBackground: false, select: true)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [
            call("run_command", ["command": .string("true --never-run-\(UUID().uuidString)")]),
            text("done"),
        ]), retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let vibecop = cloudEngine(#"{"decision":"DENY","reason":"no"}"#, role: "vibecop")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            await engine.processInput("go", source: "UI", conversationId: id)
        }
        let usage = try #require(state.conversations.first { $0.id == id }?.tokenUsage)
        #expect(usage.promptTokenCount == 120, "the scripted model rounds carry no usage, so this is Vibecop's call")
        #expect(usage.candidatesTokenCount == 30)
    }

    @Test("the tier-3 canary on an arriving message is charged to the conversation it arrives in")
    func canaryOnArrival() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [text("noted")]), retryDelays: [],
                                protectionEnabled: true, sessionPeerCount: 0)
        let arrival = "Background subagent result: done \(UUID().uuidString)"
        let prompts = LockedPrompts()
        var canary = cloudEngine("SAFE", role: "canary")
        let answer = canary.send
        canary.send = { request, model in
            prompts.add(request.contents.flatMap(\.parts).compactMap(\.text).joined())
            return try await answer(request, model)
        }
        await AuxiliaryModelManager.$scopedEngines.withValue(["canary": canary]) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(MockCoreMLModel(probability: 0.0))) {
                await engine.handleSystemEvent(arrival, source: "SubagentManager", conversationId: id)
            }
        }
        #expect(prompts.all.contains { $0.contains(arrival) }, "the arrival went through the canary")
        let usage = try #require(state.conversations.first { $0.id == id }?.tokenUsage)
        // The turn makes canary calls of its own; every one of them, the arrival's included, is here.
        #expect(usage.promptTokenCount == 120 * prompts.all.count)
    }

    @Test("Vibecop's verdict on a blocked job run's card is charged to that run, though its row is closed")
    func vibecopOnJobRunCard() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [
            call("run_command", ["command": .string("true --never-run-\(UUID().uuidString)")]),
            text("blocked."),
        ]), protectionEnabled: false, sessionPeerCount: 0)
        let job = Job(name: "needs-hands", prompt: "Do the thing.", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(vibecop: true)
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true })
        let vibecop = cloudEngine(#"{"decision":"DENY","reason":"this deletes things"}"#, role: "vibecop")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            _ = await runner.fire(job: job, origin: .manual)
        }
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(run.promptTokens == 120 && run.candidateTokens == 30, "the card's verdict is the run's spend")
    }

    @Test("the tier-3 canary on a gate's output is charged to the run")
    func canaryOnGateOutput() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [text("nothing to do")]),
                                protectionEnabled: false, sessionPeerCount: 0)
        let job = Job(name: "gated", prompt: "Look.",
                      trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: .urlChanged(url: "https://example.invalid/f"))))
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(vibecop: false)
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: true, activity: RecordingActivity(), sandboxAvailable: { true },
                               gateEvaluator: { _, _ in .changed(signal: "etag=b", payload: "the feed has a new entry") })
        let canary = cloudEngine("SAFE", role: "canary")
        await AuxiliaryModelManager.$scopedEngines.withValue(["canary": canary]) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(MockCoreMLModel(probability: 0.0))) {
                _ = await runner.fire(job: job, origin: .cadence(kind: "poll"))
            }
        }
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.promptTokens >= 120, "the canary's call on the gate output is in the run's tokens")
    }
}

/// Usage recorded from a `@Sendable` sink.
final class LockedUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var p = 0, o = 0
    func add(_ usage: UsageMetadata) {
        lock.withLock { p += usage.promptTokenCount ?? 0; o += usage.candidatesTokenCount ?? 0 }
    }
    var prompt: Int { lock.withLock { p } }
    var output: Int { lock.withLock { o } }
}

final class LockedPrompts: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}
