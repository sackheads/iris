import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Approval queue")
struct ApprovalQueueTests {
    @Test("autoApproveTools short-circuits requestApproval without enqueuing")
    func autoApproveShortCircuits() async {
        let app = AppState()
        app.autoApproveTools = true
        let cid = UUID()
        // Would otherwise consult permissions/Vibecop and then block on the interactive queue.
        let approved = await app.requestApproval(toolName: "run_command", details: "echo hi",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == true)
        #expect(app.pendingApprovals.isEmpty)
    }

    @Test("resolveApproval resolves the FIFO head; deny then approve")
    func fifoResolve() async {
        let app = AppState()
        let cid = UUID()
        // Enqueue in a DETERMINISTIC order. Two `async let`s start concurrently and can reach the
        // queue in either order; when "b" won, deny/approve landed on the wrong entries and the
        // assertions inverted. Wait for each to actually be queued before starting the next.
        func waitForQueue(_ count: Int) async {
            for _ in 0..<200 where app.pendingApprovals.count < count {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let t1 = Task { await app.enqueueUserApproval(toolName: "run_command", details: "a", workspace: nil, conversationId: cid, origin: "Main agent") }
        await waitForQueue(1)
        let t2 = Task { await app.enqueueUserApproval(toolName: "run_command", details: "b", workspace: nil, conversationId: cid, origin: "Main agent") }
        await waitForQueue(2)
        #expect(app.pendingApprovals.count == 2)
        #expect(app.pendingApprovals.first?.details == "a", "the head must be the first one queued")
        app.resolveApproval(.deny)     // head (a) denied
        app.resolveApproval(.approve)  // next (b) approved
        let v1 = await t1.value
        let v2 = await t2.value
        #expect(v1 == false)
        #expect(v2 == true)
        #expect(app.pendingApprovals.isEmpty)
    }

    @Test("denyPendingApprovals denies only the matching conversation")
    func denyByConversation() async {
        let app = AppState()
        let a = UUID(); let b = UUID()
        async let ra = app.enqueueUserApproval(toolName: "t", details: "a", workspace: nil, conversationId: a, origin: "Subagent (x)")
        async let rb = app.enqueueUserApproval(toolName: "t", details: "b", workspace: nil, conversationId: b, origin: "Main agent")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(app.pendingApprovals.count == 2)
        app.denyPendingApprovals(for: a)
        let va = await ra
        #expect(va == false)
        #expect(app.pendingApprovals.count == 1)
        #expect(app.pendingApprovals.first?.conversationId == b)
        app.resolveApproval(.approve)
        let vb = await rb
        #expect(vb == true)
    }

    @Test("enqueue in a cancelled task returns false and leaves the queue empty")
    func cancelledEnqueueNoLeak() async {
        let app = AppState()
        let cid = UUID()
        let t = Task { () -> Bool in
            // Give t.cancel() time to land before we reach enqueue; the sleep throws under
            // cancellation and try? swallows it, so we still call enqueueUserApproval.
            try? await Task.sleep(nanoseconds: 30_000_000)
            return await app.enqueueUserApproval(toolName: "t", details: "d", workspace: nil,
                                                 conversationId: cid, origin: "Subagent (x)")
        }
        t.cancel()
        let v = await t.value
        #expect(v == false)
        #expect(app.pendingApprovals.isEmpty)
    }
}
