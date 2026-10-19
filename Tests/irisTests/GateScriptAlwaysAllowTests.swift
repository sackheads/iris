import Testing
import Foundation
@testable import IrisKit

/// #648: a gate script's escalation offers no "Always Allow" and writes no rule, because its rule
/// would match the composed gate text as a host command. Vibecop's review is untouched. Each test
/// has its own `AppState` and `PermissionManager` (Invariant 7).
@MainActor
@Suite("A gate script's escalation offers no Always Allow (#648)", .timeLimit(.minutes(1)))
struct GateScriptAlwaysAllowTests {
    private func app() throws -> (AppState, URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-648-\(UUID().uuidString)")
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        return (state, home)
    }

    /// Asks through the gate review's dialog half, waits for the request, and answers `answer`.
    private func ask(_ state: AppState, _ details: String, in id: UUID,
                     answer: AppState.ApprovalResolution) async throws -> (ToolApprovalRequest?, Bool) {
        let review = IrisEngine.gateScriptReview(state: state, conversationId: id, vibecopEnabled: false)
        let task = Task { await review.ask(details) }
        var seen: ToolApprovalRequest?
        for _ in 0..<400 {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                seen = request
                state.resolveApproval(id: request.id, answer)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if seen == nil { state.denyPendingApprovals(for: id) }
        return (seen, try await value(of: task))
    }

    @Test("the dialog offers no Always Allow for a gate script")
    func noButton() async throws {
        let (state, home) = try app(); defer { try? FileManager.default.removeItem(at: home) }
        let id = state.createNewConversation(isBackground: false, select: false)
        let (request, approved) = try await ask(state, "gate script: test -f /in/x && echo CHANGED", in: id, answer: .approve)
        let shown = try #require(request)
        #expect(!shown.offersAlwaysAllow)
        #expect(shown.humanOnly, "#687: a person approves every gate script; nothing stands in for the click")
        #expect(approved)
    }

    @Test("an Always Allow that reaches resolveApproval anyway approves this one and writes no rule")
    func noRule() async throws {
        let (state, home) = try app(); defer { try? FileManager.default.removeItem(at: home) }
        let id = state.createNewConversation(isBackground: false, select: false)
        let details = "gate script: echo CHANGED \(UUID().uuidString)"
        let (_, approved) = try await ask(state, details, in: id, answer: .alwaysAllowGlobal)
        #expect(approved, "the person did approve this one")
        #expect(!state.permissions.isAllowed(toolName: "run_command", details: details, workspace: nil),
                "and no standing rule matches the gate text as a host command")
    }

    @Test("an ordinary request still offers Always Allow and saves its rule")
    func ordinaryUnchanged() async throws {
        let (state, home) = try app(); defer { try? FileManager.default.removeItem(at: home) }
        let id = state.createNewConversation(isBackground: false, select: false)
        let details = "make ordinary-\(UUID().uuidString)"
        let task = Task { await state.enqueueUserApproval(toolName: "run_command", details: details, workspace: nil,
                                                         conversationId: id, origin: "Main agent") }
        var offered: Bool?
        for _ in 0..<400 {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                offered = request.offersAlwaysAllow
                state.resolveApproval(id: request.id, .alwaysAllowGlobal)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(offered == true)
        #expect(try await value(of: task))
        #expect(state.permissions.isAllowed(toolName: "run_command", details: details, workspace: nil))
    }
}
