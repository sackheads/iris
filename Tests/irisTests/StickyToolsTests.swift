import Testing
import Foundation
@testable import iris

@Suite struct StickyToolsTests {
    @Test func recordsOnlyEligibleNames() {
        var s = StickyTools()
        let id = UUID()
        s.record(["manage_fact", "run_command", "schedule_job", "goal_complete"], for: id)
        #expect(s.names(for: id) == ["manage_fact", "goal_complete"])
    }

    @Test func onlyGrows() {
        var s = StickyTools()
        let id = UUID()
        s.record(["manage_fact"], for: id)
        s.record(["reach_checkpoint", "delegate_milestone"], for: id)
        s.record([], for: id)
        #expect(s.names(for: id) == ["manage_fact", "reach_checkpoint", "delegate_milestone"])
    }

    @Test func aNewConversationStartsEmptyAndForgetClears() {
        var s = StickyTools()
        let a = UUID(), b = UUID()
        s.record(["manage_fact"], for: a)
        #expect(s.names(for: b).isEmpty, "a new conversation (or a rotation's new Iris) starts empty")
        s.forget(a)
        #expect(s.names(for: a).isEmpty)
    }

    @Test func eligibleSetIsTheStateGatedTools() {
        #expect(StickyTools.eligible == ["manage_fact", "list_sessions", "send_to_session", "set_session_card",
                                         "amend_goal_contract", "reach_checkpoint", "delegate_milestone",
                                         "waive_criterion", "goal_complete"])
        // Never the workflow triggers (decision 1), the pinned-only job tools (plan note 5) or
        // set_workspace (plan note 3).
        for name in ["rename_conversation", "propose_goal_contract", "schedule_job", "list_jobs", "set_workspace"] {
            #expect(!StickyTools.eligible.contains(name), Comment(rawValue: name))
        }
    }

    @MainActor
    @Test func deletingAConversationForgetsItsSet() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        state.createNewConversation(id: id)
        state.stickyTools.record(["manage_fact"], for: id)
        state.deleteConversation(id)
        #expect(state.stickyTools.names(for: id).isEmpty)
    }

    @MainActor
    @Test func archivingKeepsTheSet() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        state.createNewConversation(id: id)
        state.createNewConversation(id: UUID())   // so archiving `id` is allowed
        state.stickyTools.record(["manage_fact"], for: id)
        _ = state.archiveConversation(id)
        #expect(state.stickyTools.names(for: id) == ["manage_fact"], "an archived conversation can come back")
    }
}
