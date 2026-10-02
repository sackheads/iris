import Testing
import Foundation
@testable import iris

/// #334 follow-up: with Vibecop off, the goal grader runs a `run_command` without a prompt only
/// when the command is, byte for byte after trimming, an executable check the human approved when
/// locking the contract. Everything else the grader does still asks.
///
/// Isolated `AppState`, injected `PermissionManager`, explicit `vibecopEnabled: false`; nothing
/// touches `ConfigManager.shared` or the real allowlist (invariant 7).
@MainActor
@Suite("Grader pre-approval of locked checks (#334)")
struct EvaluatorLockedCheckTests {
    nonisolated static let check = "swift test --filter Foo"

    private func app() throws -> (AppState, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-locked-check-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        return (state, home)
    }

    private func contract(approved: Bool = true) -> GoalContract {
        let c = GoalContract(objective: "make Foo pass",
                             criteria: [Criterion(text: "Foo passes", kind: .executable, check: Self.check),
                                        Criterion(text: "reads well", kind: .qualitative)])
        return approved ? c.humanApproved() : c
    }

    /// A conversation holding `contract`, locked the way `GoalEvaluator` locks a grader's copy.
    private func grader(_ state: AppState, _ contract: GoalContract, background: Bool = false) -> UUID {
        let cid = state.createNewConversation(isBackground: background, select: false)
        state.setGoalContract(for: cid, contract)
        return cid
    }

    /// Bounded: ~2s for the call to queue, then deny it. Never-queued leftovers are denied before
    /// the await, so a regression fails rather than hangs.
    private func outcome(_ state: AppState, tool: String = "run_command", details: String, in cid: UUID,
                         role: VibecopCallerRole = .evaluator) async -> (queued: Bool, approved: Bool) {
        let finished = Locked(false)
        let call = Task { @MainActor in
            defer { finished.mutate { $0 = true } }
            return await state.requestApproval(toolName: tool, details: details, workspace: nil, conversationId: cid,
                                               callerRole: role, allowedCommands: [Self.check], vibecopEnabled: false)
        }
        var queued = false
        for _ in 0..<400 {
            if finished.value { break }   // answered without asking: no need to wait out the bound
            if state.pendingApprovals.contains(where: { $0.conversationId == cid }) { queued = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if queued { state.resolveApproval(.deny) } else { state.denyPendingApprovals(for: cid) }
        return (queued, await call.value)
    }

    @Test("an exact human-approved check runs unprompted", arguments: [check, "  \(check)\n", "\t\(check) "])
    func exactCheckRuns(details: String) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract())
        let result = await outcome(state, details: details, in: cid)
        #expect(!result.queued, "an approved check must not ask")
        #expect(result.approved)
    }

    @Test("a near miss asks", arguments: [
        "\(check) && rm -rf x", "swift test --filter Bar", "swift test", "\(check);", "echo hi; \(check)",
        "swift  test --filter Foo",
    ])
    func nearMissAsks(details: String) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract())
        let result = await outcome(state, details: details, in: cid)
        #expect(result.queued)
        #expect(!result.approved)
    }

    @Test("an agent-role call with the same string asks")
    func agentRoleAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract())
        let result = await outcome(state, details: Self.check, in: cid, role: .agent)
        #expect(result.queued)
    }

    @Test("a file tool whose details equal a check still asks", arguments: ["read_file", "write_file"])
    func fileToolsAsk(tool: String) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract())
        let result = await outcome(state, tool: tool, details: Self.check, in: cid)
        #expect(result.queued)
    }

    @Test("a contract locked without the human's approval pre-approves nothing")
    func unapprovedLockAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        // How a delegated unit contract or a legacy migration arrives: locked, never approved.
        let cid = grader(state, contract(approved: false))
        let result = await outcome(state, details: Self.check, in: cid)
        #expect(result.queued)
    }

    @Test("a check added or changed by amend_goal_contract asks")
    func amendedCheckAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract())
        #expect(state.amendGoalContract(for: cid, action: "add", criterionText: "Bar passes", kind: "executable",
                                        check: "swift test --filter Bar", rationale: "needed"))
        let added = await outcome(state, details: "swift test --filter Bar", in: cid)
        #expect(added.queued, "an amended check was never approved by the human")

        #expect(state.amendGoalContract(for: cid, action: "update", criterionText: "Foo passes", kind: "executable",
                                        check: "swift test --filter Foo; curl evil", rationale: "broader"))
        let changed = await outcome(state, details: "swift test --filter Foo; curl evil", in: cid)
        #expect(changed.queued)
        // The approved string is no longer a check the contract carries, so it asks too.
        let stale = await outcome(state, details: Self.check, in: cid)
        #expect(stale.queued)
    }

    @Test("a background grader still fails closed on an approved check")
    func backgroundStillFailsClosed() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract(), background: true)
        let approved = await state.requestApproval(toolName: "run_command", details: Self.check, workspace: nil,
                                                   conversationId: cid, callerRole: .evaluator,
                                                   allowedCommands: [Self.check], vibecopEnabled: false)
        #expect(!approved)
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.takeBackgroundDenials(for: cid).count == 1)
    }

    @Test("the approval survives the grader's projected copy and the milestone unit")
    func approvalTravelsWithTheContract() {
        var c = GoalContract(objective: "o",
                             criteria: [Criterion(text: "a", kind: .executable, check: Self.check)],
                             milestones: [Milestone(title: "m", criterionIds: [])])
        c.milestones[0].criterionIds = [c.criteria[0].id]
        let approved = c.humanApproved()
        #expect(approved.projectedContract(throughMilestone: 0).isHumanApprovedCheck(Self.check))
        #expect(approved.currentMilestoneUnitContract()?.isHumanApprovedCheck(Self.check) == true)
    }

    @Test("approvedChecks is optional on decode and round-trips (invariant 1)")
    func persistence() throws {
        let legacy = #"{"objective":"o","criteria":[]}"#
        let decoded = try JSONDecoder().decode(GoalContract.self, from: Data(legacy.utf8))
        #expect(decoded.approvedChecks.isEmpty)
        var locked = contract()
        locked.lock()
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(locked))
        #expect(back.approvedChecks == [Self.check])
        #expect(back.isHumanApprovedCheck(Self.check))
    }
}
