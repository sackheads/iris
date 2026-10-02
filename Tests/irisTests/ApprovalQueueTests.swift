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

    /// 5b §0.5 fix (#187): `requestApproval`'s deterministic allowlist and its Vibecop consult
    /// (disabled-state verdict is an outright APPROVE, not an absence of one) could both stand in
    /// for a human click. `humanOnly` routes past both. Same call, same stored rule, twice: once
    /// ordinary (auto-approved, no queue entry) and once `humanOnly` (queued, needs a resolution).
    @Test("humanOnly reaches the queue even when a stored rule would otherwise answer")
    func humanOnlyReachesTheQueueDespiteAStoredRule() async throws {
        let app = AppState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-approvalqueue-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode([PermissionRule(toolName: "note_tool", details: "demo")])
            .write(to: paths.permissionsJSON)
        app.permissions = PermissionManager(paths: paths)

        let cid = UUID()
        let ordinary = await app.requestApproval(toolName: "note_tool", details: "demo",
                                                 workspace: nil, conversationId: cid)
        #expect(ordinary == true)
        #expect(app.pendingApprovals.isEmpty)

        async let gated = app.requestApproval(toolName: "note_tool", details: "demo", workspace: nil,
                                              conversationId: cid, humanOnly: true)
        for _ in 0..<200 where app.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(app.pendingApprovals.count == 1, "humanOnly must reach the queue despite the stored rule")
        // Fix round 2: the poll above is bounded, but `await gated` below is not — `resolveApproval`
        // is a no-op on an empty queue, so if the assertion above ever failed (nothing queued),
        // nothing would resolve the continuation and `await gated` would hang the whole suite
        // rather than fail this one test. `denyPendingApprovals` is scoped to `cid` and a no-op if
        // there is nothing queued for it, so either branch leaves the continuation resolved.
        if app.pendingApprovals.isEmpty {
            app.denyPendingApprovals(for: cid)
        } else {
            app.resolveApproval(.approve)
        }
        #expect(await gated == true)
    }

    @Test("humanOnly still honors the owner's autoApproveTools switch")
    func humanOnlyHonorsAutoApprove() async {
        let app = AppState()
        app.autoApproveTools = true
        let approved = await app.requestApproval(toolName: "schedule_job", details: "x", workspace: nil, humanOnly: true)
        #expect(approved == true)
        #expect(app.pendingApprovals.isEmpty)
    }

    /// Review #340, item 3 (defense in depth): `ChatView`'s banner already hides the Always-Allow
    /// buttons for a `humanOnly` request, but that is UI-level only — any other caller of
    /// `resolveApproval` could still reach `.alwaysAllowGlobal`/`.alwaysAllowProject` for one.
    /// `humanOnly` exists specifically so neither the allowlist nor Vibecop can stand in for a
    /// human's click on THIS job; persisting a rule here would let that one click silently approve
    /// every future one, defeating the whole point. Driven directly through `enqueueUserApproval` +
    /// `resolveApproval`, bypassing `ChatView` entirely, so a regression in the UI-level
    /// button-hiding cannot hide a regression here.
    @Test("resolveApproval refuses to persist an Always-Allow rule for a humanOnly request")
    func alwaysAllowNeverPersistsForHumanOnly() async throws {
        let app = AppState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-approvalqueue-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        app.permissions = PermissionManager(paths: paths)
        let cid = UUID()

        async let globalResult = app.enqueueUserApproval(toolName: "schedule_job", details: "sweep",
                                                          workspace: nil, conversationId: cid,
                                                          origin: "Main agent", humanOnly: true)
        for _ in 0..<200 where app.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(app.pendingApprovals.count == 1)
        app.resolveApproval(.alwaysAllowGlobal)
        #expect(await globalResult == true, "the human's click still approves THIS call")
        #expect(!app.permissions.isAllowed(toolName: "schedule_job", details: "sweep", workspace: nil),
                "a humanOnly request must never leave a standing rule behind")

        async let projectResult = app.enqueueUserApproval(toolName: "schedule_job", details: "sweep",
                                                           workspace: "/tmp/proj", conversationId: cid,
                                                           origin: "Main agent", humanOnly: true)
        for _ in 0..<200 where app.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(app.pendingApprovals.count == 1)
        app.resolveApproval(.alwaysAllowProject)
        #expect(await projectResult == true, "the human's click still approves THIS call")
        #expect(!app.permissions.isAllowed(toolName: "schedule_job", details: "sweep", workspace: "/tmp/proj"),
                "a humanOnly request must never leave a standing per-project rule behind either")
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
