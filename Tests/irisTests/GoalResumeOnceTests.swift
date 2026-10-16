import Testing
import Foundation
@testable import IrisKit

/// `ChatView`'s `.onAppear` calls `start()` every time the window opens, which the status item and
/// the hotkey now make routine (D6). Only the first may treat a running goal as interrupted.
@MainActor
@Suite("Goal resume runs once per engine", .timeLimit(.minutes(1)))
struct GoalResumeOnceTests {
    static let resumePrefix = "Goal was interrupted by restart. Resuming:"

    @Test("a second start finds the goal live, not interrupted: one resume line, one reprompt")
    func resumesOnce() async throws {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        let cid = state.createNewConversation()
        var contract = GoalContract(objective: "ship it", criteria: [Criterion(text: "c", kind: .qualitative)])
        contract.lock()
        state.setGoalContract(for: cid, contract)
        let idx = try #require(state.conversations.firstIndex { $0.id == cid })
        state.conversations[idx].activeGoal = "ship it"
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        defer { engine.goalLoop.cancelReprompt(for: cid) }

        func resumeLines() -> Int {
            state.conversations.first { $0.id == cid }?.messages
                .filter { $0.content.hasPrefix(Self.resumePrefix) }.count ?? 0
        }

        await engine.resumeInterruptedGoal()
        #expect(resumeLines() == 1)
        #expect(engine.goalLoopIsLive(for: cid), "the first start schedules the reprompt")

        // The reprompt has been taken up (stand-in: it is gone); the window reopens.
        engine.goalLoop.cancelReprompt(for: cid)
        await engine.resumeInterruptedGoal()

        #expect(resumeLines() == 1)
        #expect(!engine.goalLoopIsLive(for: cid), "no second reprompt is scheduled")
    }

    @Test("a goal started after the first start is never taken for an interrupted one")
    func laterGoalIsNotResumed() async throws {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        let cid = state.createNewConversation()
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        defer { engine.goalLoop.cancelReprompt(for: cid) }

        await engine.resumeInterruptedGoal()   // launch: nothing to resume

        var contract = GoalContract(objective: "ship it", criteria: [Criterion(text: "c", kind: .qualitative)])
        contract.lock()
        state.setGoalContract(for: cid, contract)
        let idx = try #require(state.conversations.firstIndex { $0.id == cid })
        state.conversations[idx].activeGoal = "ship it"
        await engine.resumeInterruptedGoal()   // the window reopens mid-goal

        #expect(state.conversations[idx].messages.allSatisfy { !$0.content.hasPrefix(Self.resumePrefix) })
        #expect(!engine.goalLoopIsLive(for: cid))
    }

    /// #471: `start()` awaits plugins, MCP servers and the Ollama probe before it resumes, which
    /// can take seconds. Switching conversation in that window must not lose the launch one's goal.
    @Test("the goal of the conversation selected at launch resumes even after the selection moves")
    func resumesTheLaunchSelection() async throws {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        let cid = state.createNewConversation()
        var contract = GoalContract(objective: "ship it", criteria: [Criterion(text: "c", kind: .qualitative)])
        contract.lock()
        state.setGoalContract(for: cid, contract)
        let idx = try #require(state.conversations.firstIndex { $0.id == cid })
        state.conversations[idx].activeGoal = "ship it"
        let other = state.createNewConversation()   // the user moved on while start() awaited
        #expect(state.selectedConversationId == other)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        defer { engine.goalLoop.cancelReprompt(for: cid) }

        await engine.resumeInterruptedGoal(launchSelection: cid)

        #expect(state.conversations[idx].messages.contains { $0.content.hasPrefix(Self.resumePrefix) })
        #expect(engine.goalLoopIsLive(for: cid))
    }
}
