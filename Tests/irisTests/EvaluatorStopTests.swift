import Testing
import Foundation
@testable import IrisKit

/// #464 — a goal evaluator in flight is stopped with the work it grades. It registers in the
/// live-subagent registry, so the run drain, the parent's Stop and a walk of the delegation tree
/// reach it, and a stop cancels its model call rather than the task waiting on it. A stopped grade
/// is reported as stopped, never as a pass. Scripted clients only: the grader's call parks.
@MainActor
@Suite("A goal evaluator stops with its run or parent (#464)", .timeLimit(.minutes(1)))
struct EvaluatorStopTests {

    /// The grader (the engine offered `submit_evaluation`) parks until cancelled and counts both.
    /// A subagent's first call is `goal_complete`; the main lane plays its script.
    final class ParkedGraderClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var graderEntered = 0
        private var graderCancelled = 0
        private var mainIndex = 0
        private var subagentIndex = 0
        private let main: [GeminiResponse]

        init(main: [GeminiResponse] = []) { self.main = main }

        var graderCalls: Int { lock.withLock { graderEntered } }
        var graderCancellations: Int { lock.withLock { graderCancelled } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let offersSubmit = request.tools?.contains {
                $0.functionDeclarations.contains { $0.name == "submit_evaluation" }
            } ?? false
            if offersSubmit {
                lock.withLock { graderEntered += 1 }
                do {
                    try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                } catch {
                    lock.withLock { graderCancelled += 1 }
                    throw error
                }
                return EvaluatorStopTests.text("late")
            }
            let system = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            return lock.withLock {
                if system.contains("specialized subagent role") {
                    defer { subagentIndex += 1 }
                    return subagentIndex == 0 ? EvaluatorStopTests.goalComplete : EvaluatorStopTests.text("done")
                }
                defer { mainIndex += 1 }
                return main.isEmpty ? EvaluatorStopTests.text("ok") : main[min(mainIndex, main.count - 1)]
            }
        }
    }

    nonisolated static func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    nonisolated static var goalComplete: GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(functionCall: FunctionCall(name: "goal_complete", args: ["summary": .string("unit is done")]))]))],
                       usageMetadata: nil)
    }

    private func gradedUnit() -> DelegatedUnit {
        DelegatedUnit(contract: GoalContractParsing.unitContract(
            task: "build a widget",
            criteriaJSON: .array([.object(["text": .string("the widget exists"), "kind": .string("qualitative")])]))!,
                      grade: true)
    }

    private func state() throws -> AppState {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        return state
    }

    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func subagent(under parent: UUID, background: Bool, client: ParkedGraderClient, state: AppState)
        -> Task<(rendered: String, status: SubagentTerminalStatus, stoppedBy: SubagentStopKind?), Never> {
        let unit = gradedUnit()
        return Task {
            await SubagentManager.shared.runSubagent(
                role: "engineer", task: "build a widget", effort: "easy", parentConversationId: parent,
                unit: unit, background: background, turnTimeout: 600, client: client, appState: state,
                endSandboxSession: { _ in })
        }
    }

    /// Longer than the evaluator's reprompt delay (1.5 s): a loop left running would call again.
    private func noFurtherGraderCalls(_ client: ParkedGraderClient) async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(client.graderCalls == 1, "no grader call after the stop")
    }

    @Test("closing the run stops a grade in flight under it: its model call is cancelled and no other is made")
    func runCloseStopsGrading() async throws {
        let client = ParkedGraderClient()
        let state = try state()
        let run = state.createNewConversation(isBackground: true, select: false)

        // Nothing cancels this task: it is the run's turn that cancellation did not reach, which
        // leaves the drain as the only thing that can stop the grade.
        let outcome = subagent(under: run, background: false, client: client, state: state)
        #expect(await eventually { client.graderCalls == 1 })
        #expect(!state.liveSubagents(ofRun: run).isEmpty)

        // The walk the runner does as the run closes (#291).
        state.stopDelegates(under: run, reason: SubagentManager.runEndedReason)

        #expect(await eventually { client.graderCancellations == 1 }, "the grader's in-flight call was cancelled")
        let result = try await value(of: outcome)
        #expect(result.status == .completed, "the subagent's own run completed; only its grade was stopped")
        #expect(result.rendered.contains("Independent grading stopped before a verdict"))
        #expect(!result.rendered.contains("1 met") && !result.rendered.contains("— met"), "a stopped grade reports no verdict: \(result.rendered)")
        await noFurtherGraderCalls(client)
        #expect(await eventually { state.liveSubagents(ofRun: run).isEmpty }, "the evaluator left the registry")
    }

    @Test("deleting the parent stops the grade of its background subagent: the call is cancelled and none follows")
    func parentDeleteStopsGrading() async throws {
        let client = ParkedGraderClient()
        let state = try state()
        state.closeSandboxSession = { _ in }
        let parent = state.createNewConversation()

        // Background: no cancellation of the parent's tasks reaches it, only the delete's walk.
        let outcome = subagent(under: parent, background: true, client: client, state: state)
        #expect(await eventually { client.graderCalls == 1 })

        state.deleteConversation(parent)

        #expect(await eventually { client.graderCancellations == 1 }, "the grader's in-flight call was cancelled")
        let result = try await value(of: outcome)
        #expect(result.rendered.contains("Independent grading stopped before a verdict"))
        #expect(!result.rendered.contains("1 met") && !result.rendered.contains("— met"), "no verdict: \(result.rendered)")
        await noFurtherGraderCalls(client)
    }

    @Test("the parent's Stop stops the grade of its background subagent, and the result does not wake it")
    func parentStopStopsBackgroundGrading() async throws {
        let client = ParkedGraderClient()
        let state = try state()
        let parent = state.createNewConversation()

        let outcome = subagent(under: parent, background: true, client: client, state: state)
        #expect(await eventually { client.graderCalls == 1 })

        // The subagent is settled while it is graded; the grade is what is still running.
        #expect(state.stopBackgroundSubagents(under: parent) == 1)

        #expect(await eventually { client.graderCancellations == 1 })
        let result = try await value(of: outcome)
        #expect(result.stoppedBy == .parent)
        #expect(result.rendered.contains("Independent grading stopped before a verdict"))
        await noFurtherGraderCalls(client)
    }

    @Test("cancelling the turn waiting on a foreground grade stops the grader, reported as stopped")
    func callerCancellationStopsGrading() async throws {
        let client = ParkedGraderClient()
        let state = try state()
        let parent = state.createNewConversation()

        let outcome = subagent(under: parent, background: false, client: client, state: state)
        #expect(await eventually { client.graderCalls == 1 })
        outcome.cancel()   // the parent's Stop, or its deletion, cancelling the turn that waits

        #expect(await eventually { client.graderCancellations == 1 })
        let result = try await value(of: outcome)
        #expect(result.rendered.contains("Independent grading stopped before a verdict"))
        await noFurtherGraderCalls(client)
    }

    @Test("a main agent's goal whose grade is stopped is not marked complete, gated or ungated")
    func stoppedGateGradeIsNotAPass() async throws {
        let client = ParkedGraderClient(main: [Self.goalComplete, Self.text("ok")])
        let state = try state()
        let id = state.createNewConversation(isBackground: true, select: false)
        state.setGoalContract(for: id, GoalContract(objective: "ship it", criteria: [
            Criterion(text: "builds", kind: .qualitative, check: nil)]))
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client)
        let turn = Task { await engine.processInput("go", source: "User", conversationId: id) }
        #expect(await eventually { client.graderCalls == 1 })

        _ = state.takeBackgroundDenials(for: id)   // the run closes while its goal is graded
        _ = try await value(of: turn)
        engine.haltGoalLoop(for: id)   // the goal stays open; end its loop so the test does

        let conv = try #require(state.conversations.first { $0.id == id })
        #expect(conv.lastGoalEvaluation?.status == .stopped)
        #expect(conv.lastGoalEvaluation?.gateOutcome == nil, "not let through as a grader failure")
        #expect(conv.activeGoal != nil, "the goal was not marked complete")
        #expect(client.graderCancellations == 1)
    }
}
