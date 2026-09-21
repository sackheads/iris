import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Background conversation approvals fail closed")
struct BackgroundApprovalTests {
    @Test("a background conversation is denied without enqueuing, and the denial is recorded")
    func backgroundConversationDeniedAndRecorded() async {
        let app = AppState()
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "rm -rf x",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == false)
        #expect(app.pendingApprovals.isEmpty)

        let denials = app.takeBackgroundDenials(for: cid)
        #expect(denials.count == 1)
        #expect(denials.first?.toolName == "run_command")
        #expect(denials.first?.details == "rm -rf x")
        #expect(app.takeBackgroundDenials(for: cid).isEmpty, "takeBackgroundDenials must clear on read")

        let notice = String(format: AppState.unattendedDenialNotice, "run_command")
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.last?.role == .system)
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.last?.content == notice)
    }

    @Test("a non-background conversation with autoApproveTools still auto-approves (unchanged path)")
    func nonBackgroundAutoApproveUnchanged() async {
        let app = AppState()
        app.autoApproveTools = true
        let cid = app.createNewConversation(isBackground: false, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "echo hi",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == true)
        #expect(app.pendingApprovals.isEmpty)
        #expect(app.takeBackgroundDenials(for: cid).isEmpty)
    }

    @Test("a background conversation is still denied even with autoApproveTools set (fail closed beats auto-approve)")
    func backgroundBeatsAutoApprove() async {
        let app = AppState()
        app.autoApproveTools = true
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "rm -rf x",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == false)
        #expect(app.pendingApprovals.isEmpty)
        #expect(app.takeBackgroundDenials(for: cid).count == 1)
    }
}
