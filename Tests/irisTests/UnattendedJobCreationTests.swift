import Testing
import Foundation
@testable import iris

/// The epic's standing ruling: no unattended job creation. A background run may not schedule a job
/// or register a watch — a run that could would be a run that writes its own cadence, and nobody
/// asked for the second one. Gated twice: the two tools are not declared to a background turn at
/// all (invariant 6 — they would be prompt weight even if the model behaved), and the dispatcher
/// refuses them outright, because declaration gating only stops a well-behaved model.
@MainActor
@Suite("No unattended job creation")
struct UnattendedJobCreationTests {

    private let names = ["schedule_job", "register_directory_watcher"]

    private func declaredToolNames(isBackground: Bool) async -> [String] {
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: isBackground, select: false)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("an ordinary turn still declares both job-creating tools")
    func declaredInTheForeground() async {
        let declared = await declaredToolNames(isBackground: false)
        for n in names { #expect(declared.contains(n), "\(n) is how the user gets a job created") }
    }

    @Test("a background turn is offered neither")
    func notDeclaredInTheBackground() async {
        let declared = await declaredToolNames(isBackground: true)
        for n in names { #expect(!declared.contains(n), "\(n) must not be offered to an unattended run") }
    }

    /// One turn in a background conversation with the model calling `tool`, reading back what the
    /// dispatcher actually returned to it.
    private func dispatchResult(for call: FunctionCall) async -> String {
        let app = AppState()
        app.conversations.removeAll()
        let id = app.createNewConversation(isBackground: true, select: false)
        let part = Part(text: nil, functionCall: call, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))],
                           usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        let responses = app.conversations.first { $0.id == id }?.history
            .flatMap { $0.parts }
            .compactMap { $0.functionResponse } ?? []
        return responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n")
    }

    @Test("a forged schedule_job in a background run is refused")
    func scheduleJobRefused() async {
        let result = await dispatchResult(for: FunctionCall(
            name: "schedule_job", args: ["prompt": .string("do it again"), "intervalSeconds": .int(60)]))
        #expect(result.contains(IrisEngine.unattendedJobCreationRefusal))
    }

    @Test("a forged schedule_job carrying a gate script is refused before any review happens")
    func gatedScheduleJobRefused() async {
        // The gate-script review ends in an approval dialog nobody would be there to answer, so
        // the refusal has to come first — it does, at the dispatcher, before the handler runs.
        let result = await dispatchResult(for: FunctionCall(
            name: "schedule_job", args: ["prompt": .string("watch it"),
                                         "intervalSeconds": .int(600),
                                         "gate_script": .string("echo CHANGED")]))
        #expect(result.contains(IrisEngine.unattendedJobCreationRefusal))
    }

    @Test("a forged register_directory_watcher in a background run is refused")
    func registerWatcherRefused() async {
        let result = await dispatchResult(for: FunctionCall(
            name: "register_directory_watcher",
            args: ["path": .string("/tmp"), "instructions": .string("watch it")]))
        #expect(result.contains(IrisEngine.unattendedJobCreationRefusal))
    }
}
