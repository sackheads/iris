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

/// Fix round 2 (reviewer finding, #187): neither job-creating tool was gated on `principal`.
/// `register_directory_watcher` comes from `ToolExecutor.getTools()` with no principal check at
/// all, and `schedule_job` was gated only on `!isUnattended` — so an attended `.subagent` (never
/// itself the pinned conversation) was declared both, and the pinned conversation could call
/// `invoke_subagent` to have the subagent create the standing job the pinned-conversation approval
/// gate exists to stop, laundering it past a human. Gated the same way the background case is:
/// undeclared to a non-`.main` principal, and refused at dispatch for a forged or stale call.
@MainActor
@Suite("No subagent job creation")
struct SubagentJobCreationTests {

    private let names = ["schedule_job", "register_directory_watcher"]

    private func declaredToolNames(principal: Principal) async -> [String] {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("a main-principal turn still declares both job-creating tools")
    func declaredForMain() async {
        let declared = await declaredToolNames(principal: .main)
        for n in names { #expect(declared.contains(n), "\(n) is how the user gets a job created") }
    }

    @Test("a subagent is offered neither job-creating tool")
    func notDeclaredForSubagent() async {
        let declared = await declaredToolNames(principal: .subagent)
        for n in names { #expect(!declared.contains(n), "\(n) must not reach a subagent — it is never the pinned conversation") }
    }

    @Test("an evaluator is offered neither job-creating tool")
    func notDeclaredForEvaluator() async {
        let declared = await declaredToolNames(principal: .evaluator)
        for n in names { #expect(!declared.contains(n), Comment(rawValue: n)) }
    }

    /// One turn in a `.subagent`-principal conversation with the model calling `tool`, reading back
    /// what the dispatcher actually returned to it. `isPinned` lets the "outranks the approval gate"
    /// test below put the subagent's call in a pinned conversation's id, which cannot happen for a
    /// real subagent (it is never the pinned one) but proves ordering even in that impossible case.
    private func dispatchResult(for call: FunctionCall, isPinned: Bool = false) async -> (result: String, app: AppState) {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if isPinned, let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].isPinned = true
        }
        let part = Part(text: nil, functionCall: call, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))],
                           usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        // Final-review fix wave (#187): a regression that let a subagent's job-creation call reach
        // the pinned-conversation gate anyway would suspend on a real approval request that a plain
        // `await engine.processInput(...)` here never resolves — hanging the whole suite rather than
        // failing this one test. `denyTask` watches `pendingApprovals` concurrently and denies
        // anything that shows up (none should, if the subagent refusal above is still in place),
        // so that regression is a fast, visible failure instead; it costs the normal (fast) case
        // nothing, since `await turnTask.value` returns as soon as the real turn finishes, not after
        // a fixed poll.
        let turnTask = Task { await engine.processInput("go", source: "UI", conversationId: id) }
        let denyTask = Task {
            while !Task.isCancelled {
                if !app.pendingApprovals.isEmpty {
                    app.denyPendingApprovals(for: id)
                    break
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await turnTask.value
        denyTask.cancel()
        let responses = app.conversations.first { $0.id == id }?.history
            .flatMap { $0.parts }
            .compactMap { $0.functionResponse } ?? []
        return (responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n"), app)
    }

    @Test("a forged schedule_job from a subagent is refused")
    func scheduleJobRefused() async {
        let (result, _) = await dispatchResult(for: FunctionCall(
            name: "schedule_job", args: ["prompt": .string("do it again"), "intervalSeconds": .int(60)]))
        #expect(result.contains(IrisEngine.subagentJobCreationRefusal))
    }

    @Test("a forged register_directory_watcher from a subagent is refused")
    func registerWatcherRefused() async {
        let (result, _) = await dispatchResult(for: FunctionCall(
            name: "register_directory_watcher",
            args: ["path": .string("/tmp"), "instructions": .string("watch it")]))
        #expect(result.contains(IrisEngine.subagentJobCreationRefusal))
    }

    /// Even in the one place a subagent's job-creation attempt COULD reach the pinned-conversation
    /// gate — if it somehow ran inside the pinned conversation's id — the subagent refusal must win
    /// before the human-approval gate ever gets a turn, since asking a human to approve a call that
    /// was never a legitimate request in the first place is the wrong shape of safety.
    @Test("the subagent refusal outranks the pinned-conversation approval gate")
    func subagentRefusalOutranksPinnedGate() async throws {
        let call = FunctionCall(name: "schedule_job", args: ["prompt": .string("sweep"), "intervalSeconds": .int(60)])
        let (result, app) = await dispatchResult(for: call, isPinned: true)
        #expect(result.contains(IrisEngine.subagentJobCreationRefusal))
        #expect(app.pendingApprovals.isEmpty, "no approval should ever be requested for a subagent's call")
        #expect(try app.store.ledger.jobs().isEmpty)
    }
}
