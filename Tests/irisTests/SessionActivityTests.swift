import Testing
import Foundation
@testable import IrisKit

/// Pure mappings behind the activity strip (#217 + #19): the tool-argument → activity-text
/// derivation and the token-count formatter. No SwiftUI here by design (AGENTS.md: no SwiftUI
/// unit tests) — everything the strip renders from is testable as plain functions.
@Suite("SessionActivity", .timeLimit(.minutes(1)))
struct SessionActivityTests {
    @Test("run_command surfaces the command")
    func runCommand() {
        #expect(SessionActivity.detail(tool: "run_command", args: ["command": .string("swift test")]) == "swift test")
    }

    @Test("read_file surfaces the path's last two components")
    func readFile() {
        #expect(SessionActivity.detail(tool: "read_file", args: ["path": .string("Sources/iris/Foo.swift")]) == "iris/Foo.swift")
    }

    @Test("write_file surfaces the path's last two components")
    func writeFile() {
        #expect(SessionActivity.detail(tool: "write_file", args: ["path": .string("/a/b/c/d.txt")]) == "c/d.txt")
    }

    @Test("a path with one or two components is shown whole")
    func shortPath() {
        #expect(SessionActivity.detail(tool: "read_file", args: ["path": .string("foo.txt")]) == "foo.txt")
        #expect(SessionActivity.detail(tool: "read_file", args: ["path": .string("iris/foo.txt")]) == "iris/foo.txt")
    }

    @Test("search_memory surfaces the query")
    func searchMemory() {
        #expect(SessionActivity.detail(tool: "search_memory", args: ["query": .string("last deploy"), "scope": .string("all")]) == "last deploy")
    }

    @Test("subagent delegation tools surface the role")
    func delegation() {
        #expect(SessionActivity.detail(tool: "invoke_subagent", args: ["role": .string("code_reviewer"), "task": .string("review it")]) == "code_reviewer")
        #expect(SessionActivity.detail(tool: "delegate_milestone", args: ["role": .string("engineer")]) == "engineer")
    }

    @Test("an unrecognized tool falls back to the first allowlisted key present, not just any string arg")
    func fallback() {
        // Neither key is on the allowlist: no detail, even though both are strings.
        #expect(SessionActivity.detail(tool: "some_new_tool", args: ["z_arg": .string("last"), "a_arg": .string("first")]) == nil)
        // "id" and "name" are both allowlisted; "name" comes first in priority order.
        #expect(SessionActivity.detail(tool: "some_new_tool", args: ["id": .string("abc-123"), "name": .string("widget")]) == "widget")
    }

    @Test("a tool with no string argument has no detail")
    func noStringArg() {
        #expect(SessionActivity.detail(tool: "some_new_tool", args: ["count": .int(3)]) == nil)
        #expect(SessionActivity.detail(tool: "run_command", args: [:]) == nil)
    }

    @Test("fix round 1: write_file without a path has no detail — never falls back to file content")
    func writeFileWithoutPath() {
        let long = String(repeating: "SECRET BODY ", count: 10)
        #expect(SessionActivity.detail(tool: "write_file", args: ["content": .string(long)]) == nil)
        #expect(SessionActivity.detail(tool: "read_file", args: ["content": .string(long)]) == nil)
    }

    @Test("fix round 1: an email-send tool surfaces the subject, never the body")
    func emailToolSurfacesSubjectNotBody() {
        let detail = SessionActivity.detail(tool: "gmail_send_email", args: [
            "body": .string("a very long email body that must never be shown here"),
            "subject": .string("Q3 numbers")
        ])
        #expect(detail == "Q3 numbers")
    }

    @Test("fix round 1: a skill-authoring tool with only a body argument has no detail")
    func skillToolWithOnlyBody() {
        #expect(SessionActivity.detail(tool: "create_skill", args: ["body": .string("# Skill\n...")]) == nil)
        #expect(SessionActivity.detail(tool: "update_skill", args: ["body": .string("# Skill\n...")]) == nil)
    }

    @Test("detail is truncated to 60 characters")
    func truncation() {
        let long = String(repeating: "x", count: 90)
        let result = SessionActivity.detail(tool: "run_command", args: ["command": .string(long)])
        #expect(result?.count == 61)   // 60 chars + the ellipsis mark
        #expect(result?.hasSuffix("…") == true)
    }

    @Test("token count formatting")
    func tokenFormatting() {
        #expect(SessionActivity.formatTokenCount(0) == "0")
        #expect(SessionActivity.formatTokenCount(999) == "999")
        #expect(SessionActivity.formatTokenCount(4_200) == "4.2k")
        #expect(SessionActivity.formatTokenCount(210_900) == "210.9k")
        #expect(SessionActivity.formatTokenCount(1_300_000) == "1.3M")
    }

    @Test("fix round 1: 999_999 tokens rounds up to 1.0M, not 1000k")
    func tokenFormattingRoundsAtBoundary() {
        #expect(SessionActivity.formatTokenCount(999_999) == "1.0M")
        #expect(SessionActivity.formatTokenCount(999_499) == "999.5k")
    }

    @Test("fix round 1: elapsed-time formatting is shared by running and finished rows")
    func elapsedFormatting() {
        #expect(SessionActivity.formatElapsed(12) == "12s")
        #expect(SessionActivity.formatElapsed(65) == "1m 05s")
        #expect(SessionActivity.formatElapsed(3_720) == "1h 02m")
    }

    private static func session(_ phase: ActivitySummary.Phase, kind: ActivitySummary.Kind = .subagent) -> ActivitySummary {
        ActivitySummary(id: UUID(), kind: kind, role: "r", owner: nil, startTime: Date(), phase: phase, lastActivity: nil)
    }

    @Test("collapsed summary tells an evaluator apart from a subagent, like the expanded rows do")
    func collapsedSummaryEvaluators() {
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking, kind: .evaluator)]) == "1 evaluator running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking), Self.session(.responding, kind: .evaluator)])
                == "1 subagent running, 1 evaluator running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking, kind: .evaluator), Self.session(.finished(status: "completed", at: Date()))])
                == "1 evaluator running, 1 finished")
    }

    @Test("collapsed summary counts a background job run, whose conversation is hidden (#187)")
    func collapsedSummaryJobs() {
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking, kind: .job)]) == "1 job running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking, kind: .job), Self.session(.responding, kind: .job)])
                == "2 jobs running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking), Self.session(.thinking, kind: .evaluator), Self.session(.thinking, kind: .job)])
                == "1 subagent running, 1 evaluator running, 1 job running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.finished(status: "completed", at: Date()), kind: .job)]) == "1 finished")
    }

    @Test("collapsed summary: fix round 1 — the collapsed main line summarizes background work")
    func collapsedSummary() {
        #expect(SessionActivity.collapsedSummary(for: []) == "")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking)]) == "1 subagent running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking), Self.session(.executing(tool: "run_command", detail: nil))]) == "2 subagents running")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.finished(status: "completed", at: Date()))]) == "1 finished")
        #expect(SessionActivity.collapsedSummary(for: [Self.session(.thinking), Self.session(.finished(status: "failed", at: Date()))]) == "1 subagent running, 1 finished")
    }
}

/// `AppState`'s session-tracking surface: `registerSubagent`, `updateRunPhase`,
/// `finishRun`, and `visibleRuns`. Uses the isolated in-memory constructor (AGENTS.md
/// invariant 7) so nothing here touches `~/.iris`.
@MainActor
@Suite("AppState session tracking (#217 + #19)", .timeLimit(.minutes(1)))
struct SessionTrackingTests {
    private func isolatedApp() -> AppState {
        AppState(store: try! ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    @Test("registerSubagent adds a running session, defaulting to kind .subagent")
    func registerAdds() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "researcher")
        let session = app.stripRuns.first { $0.id == id }
        #expect(session?.kind == .subagent)
        #expect(session?.role == "researcher")
        #expect(session?.phase != nil)
        if case .finished = session?.phase { Issue.record("a freshly registered session must not start finished") }
    }

    @Test("registerSubagent(kind: .evaluator) is distinguishable from a plain subagent")
    func registerEvaluator() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "evaluator", kind: .evaluator)
        #expect(app.stripRuns.first { $0.id == id }?.kind == .evaluator)
    }

    @Test("updateRunPhase changes the tracked phase and records lastActivity for .executing")
    func updatePhase() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.updateRunPhase(id, .executing(tool: "run_command", detail: "swift build"))
        let session = app.stripRuns.first { $0.id == id }
        if case .executing(let tool, let detail) = session?.phase {
            #expect(tool == "run_command")
            #expect(detail == "swift build")
        } else {
            Issue.record("expected .executing")
        }
        #expect(session?.lastActivity == ActivitySummary.LastActivity(tool: "run_command", detail: "swift build"))
    }

    @Test("finishRun marks the session finished with the given status and keeps it")
    func finish() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.finishRun(id: id, status: "completed")
        let session = app.stripRuns.first { $0.id == id }
        if case .finished(let status, _) = session?.phase {
            #expect(status == "completed")
        } else {
            Issue.record("expected .finished")
        }
    }

    /// Fix round 1, item 1: `goal_complete` fires the completion callback from inside the tool
    /// handler while the SAME engine turn keeps running (its next round produces a closing text
    /// reply), so a `.responding`/`.thinking` update can land AFTER `finishRun` already ran.
    /// Once finished, nothing may move a session off that phase, and the sweep must still collect
    /// it (i.e. the guard doesn't also block the sweep from seeing it as finished).
    @Test("updateRunPhase after finishRun is a no-op; the sweep still removes it")
    func finishedSessionIgnoresLaterPhaseUpdates() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.finishRun(id: id, status: "completed")
        app.updateRunPhase(id, .responding)
        let session = app.stripRuns.first { $0.id == id }
        guard case .finished(let status, let at) = session?.phase else {
            Issue.record("expected .finished to survive a later updateRunPhase call")
            return
        }
        #expect(status == "completed")
        let swept = ActivitySummary.sweep(app.stripRuns, now: at.addingTimeInterval(61), lingerWindow: 60)
        #expect(swept.isEmpty)
    }

    /// Fix round 1, item 6: an evaluator's conversation is deleted by `GoalEvaluator` right after
    /// `finishRun` — there's no transcript behind a lingering row, so it's removed immediately.
    /// A subagent (not an evaluator) still lingers.
    @Test("finishRun removes an evaluator session immediately, with no linger")
    func evaluatorFinishHasNoLinger() {
        let app = isolatedApp()
        let evaluatorId = UUID(), subagentId = UUID()
        app.registerSubagent(id: evaluatorId, role: "evaluator", kind: .evaluator)
        app.registerSubagent(id: subagentId, role: "engineer")
        app.finishRun(id: evaluatorId, status: "graded")
        app.finishRun(id: subagentId, status: "completed")
        #expect(app.stripRuns.contains { $0.id == evaluatorId } == false)
        #expect(app.stripRuns.first { $0.id == subagentId }.map {
            if case .finished = $0.phase { return true } else { return false }
        } == true)
    }

    @Test("visibleRuns puts the main session first and includes only subagent/evaluator kinds owned by the focused conversation")
    func visibleSessionsOrdering() {
        let app = isolatedApp()
        let main = UUID()
        app.createNewConversation(id: main)
        app.selectedConversationId = main
        let subagentId = UUID(), evaluatorId = UUID()
        app.registerSubagent(id: subagentId, role: "engineer", owner: main)
        app.registerSubagent(id: evaluatorId, role: "evaluator", kind: .evaluator, owner: main)
        let visible = app.visibleRuns
        #expect(visible.first?.kind == .main)
        #expect(visible.first?.role == "main")
        #expect(Set(visible.dropFirst().map(\.id)) == [subagentId, evaluatorId])
        #expect(visible.dropFirst().allSatisfy { $0.kind == .subagent || $0.kind == .evaluator })
    }

    /// #986: Brian's decision B — the strip is scoped per focused session, not process-global.
    @Test("visibleRuns excludes runs owned by a different conversation")
    func visibleRunsIsolatesByOwner() {
        let app = isolatedApp()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        let subagentOfA = UUID()
        app.registerSubagent(id: subagentOfA, role: "engineer", owner: a)

        app.selectedConversationId = a
        #expect(app.visibleRuns.dropFirst().map(\.id) == [subagentOfA])

        app.selectedConversationId = b
        #expect(app.visibleRuns.dropFirst().isEmpty)
    }

    /// #986: an evaluator grading conversation A is attributed to A, not to whoever happens to be
    /// focused when it's registered.
    @Test("an evaluator is attributed to the conversation it grades")
    func evaluatorAttributedToGradedConversation() {
        let app = isolatedApp()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        let evaluatorOfA = UUID()
        app.registerSubagent(id: evaluatorOfA, role: "evaluator", kind: .evaluator, owner: a)

        app.selectedConversationId = b
        #expect(app.visibleRuns.dropFirst().isEmpty)

        app.selectedConversationId = a
        #expect(app.visibleRuns.dropFirst().map(\.id) == [evaluatorOfA])
    }

    /// #986: a background job has no interactive parent (`owner` nil) and must not surface in any
    /// focused session's strip — it belongs to the global #988 view only.
    @Test("a background job never appears in a focused session's visibleRuns")
    func jobOwnerNilNeverVisibleInFocusedStrip() {
        let app = isolatedApp()
        let a = UUID()
        app.createNewConversation(id: a)
        app.selectedConversationId = a
        let jobId = UUID()
        app.registerSubagent(id: jobId, role: "job:nightly", kind: .job, owner: nil)
        #expect(app.visibleRuns.dropFirst().isEmpty)
        // stripRuns itself still holds it — this is a visibleRuns-level scope, not a tracking gap.
        #expect(app.stripRuns.contains { $0.id == jobId })
    }

    /// #986: the linger sweep is independent of ownership — it must keep working on the raw
    /// `stripRuns` array regardless of the new scoping in `visibleRuns`.
    @Test("the finished-run sweep still works under the new owner filter")
    func sweepStillWorksWithOwner() {
        let app = isolatedApp()
        let owner = UUID()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer", owner: owner)
        app.finishRun(id: id, status: "completed")
        let at = Date()
        let swept = ActivitySummary.sweep(app.stripRuns, now: at.addingTimeInterval(61), lingerWindow: 60)
        #expect(swept.isEmpty)
    }

    /// #997 review (dev-2's question 3): a nested `invoke_subagent` passes its own conversation id
    /// as the parent — `SubagentManager`/`GoalEvaluator` resolve `owner` through the existing
    /// `delegationRoot(of:)` (already covered elsewhere) rather than using the immediate parent
    /// directly, so a grandchild still lands in the one strip that can ever be focused: main's.
    @Test("a grandchild subagent's owner resolves to the top-level conversation, not its immediate parent")
    func nestedSubagentOwnerResolvesToRoot() {
        let app = isolatedApp()
        let main = UUID(), subagent = UUID(), grandchild = UUID()
        app.createNewConversation(id: main)
        app.linkDelegate(subagent, of: main)
        // Mirrors SubagentManager.runSubagent: linkDelegate before registerSubagent, owner
        // resolved through the chain's root rather than the immediate parent (`subagent`).
        app.linkDelegate(grandchild, of: subagent)
        app.registerSubagent(id: grandchild, role: "nested", owner: app.delegationRoot(of: subagent))

        app.selectedConversationId = main
        #expect(app.visibleRuns.dropFirst().map(\.id) == [grandchild])
    }

    /// #997 review: the collapsed summary line must be scoped exactly like the expanded rows —
    /// `SessionActivity.collapsedSummary` itself takes a plain array, so this guards the call site
    /// (`CollapsedSummaryRow` in `ActivityStripView`) rather than the pure function.
    @Test("collapsedSummary over the scoped visibleRuns excludes a foreign owner's run")
    func collapsedSummaryExcludesForeignOwner() {
        let app = isolatedApp()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.registerSubagent(id: UUID(), role: "engineer", owner: a)
        app.selectedConversationId = b
        let scoped = app.visibleRuns.filter { $0.kind != .main }
        #expect(SessionActivity.collapsedSummary(for: scoped) == "")
    }

    /// Fix round 1 (#217/#19), items 1 + 4: the main row's elapsed time rendered as a
    /// multi-million-hour countdown, in part because timing was recorded on `beginThinking` — a
    /// single global counter shared by every engine (main, subagent, evaluator) — rather than
    /// per-conversation. It moved to `beginEngineTurn`/`endEngineTurn`, which already track a turn
    /// per conversation id; "running" is derived from `hasTurnInFlight`, not a separately-tracked
    /// idle flag. The `countsDown: false` / `TimelineView` half of the elapsed-time fix is a
    /// SwiftUI-layer change with no unit test (AGENTS.md: no SwiftUI unit tests).
    @Test("beginEngineTurn records a start on 0→1 only; a nested call does not overwrite it")
    func beginEngineTurnRecordsStartOnce() {
        let app = isolatedApp()
        let id = app.selectedConversationId!
        app.beginEngineTurn(for: id)
        let firstStart = app.visibleRuns.first?.elapsedStartTime
        #expect(firstStart != nil)
        app.beginEngineTurn(for: id)   // nested — must not reset the start
        #expect(app.visibleRuns.first?.elapsedStartTime == firstStart)
        app.endEngineTurn(for: id)     // 2→1: still running, start still held
        #expect(app.hasTurnInFlight(for: id))
        #expect(app.visibleRuns.first?.elapsedStartTime == firstStart)
        app.endEngineTurn(for: id)     // balance the nested begin above
    }

    @Test("endEngineTurn back to zero makes the main row idle (no elapsed time)")
    func endEngineTurnGoesIdle() {
        let app = isolatedApp()
        let id = app.selectedConversationId!
        app.beginEngineTurn(for: id)
        #expect(app.visibleRuns.first?.elapsedStartTime != nil)
        app.endEngineTurn(for: id)
        #expect(app.hasTurnInFlight(for: id) == false)
        #expect(app.visibleRuns.first?.elapsedStartTime == nil)
    }

    /// Fix round 1, item 4: two conversations, a turn running in A — selecting B must show B idle
    /// (not A's stale phase), and reselecting A must still show A's own phase intact.
    @Test("the main row reflects whichever conversation is selected, independently")
    func mainRowIsPerSelectedConversation() {
        let app = isolatedApp()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)

        app.selectedConversationId = a
        app.beginEngineTurn(for: a)
        app.updateRunPhase(a, .executing(tool: "run_command", detail: "echo hi"))
        #expect(app.visibleRuns.first?.phase == .executing(tool: "run_command", detail: "echo hi"))

        app.selectedConversationId = b
        #expect(app.visibleRuns.first?.phase == .idle)

        app.selectedConversationId = a
        #expect(app.visibleRuns.first?.phase == .executing(tool: "run_command", detail: "echo hi"))
        app.endEngineTurn(for: a)
    }

    /// Fix round 1 follow-up: `mainStartTimeByConversation`/`mainPhaseByConversation` used to keep
    /// one entry per conversation forever. `endEngineTurn` now prunes both once the conversation's
    /// own turn count returns to zero.
    @Test("endEngineTurn prunes the per-conversation main-timing entries")
    func endEngineTurnPrunesMainTiming() {
        let app = isolatedApp()
        let id = app.selectedConversationId!
        app.beginEngineTurn(for: id)
        app.updateRunPhase(id, .thinking)
        #expect(app.hasMainTimingEntry(for: id))
        app.endEngineTurn(for: id)
        #expect(app.hasMainTimingEntry(for: id) == false)
    }

    /// Fix round 1 follow-up: mirrors the `endEngineTurn` pruning for a conversation deleted while
    /// (or after) its turn ran — a deleted subagent/evaluator's id is never looked up again, so an
    /// un-pruned entry there was a permanent leak.
    @Test("deleteConversation prunes the per-conversation main-timing entries")
    func deleteConversationPrunesMainTiming() {
        let app = isolatedApp()
        let id = UUID()
        app.createNewConversation(id: id)
        app.beginEngineTurn(for: id)
        app.updateRunPhase(id, .thinking)
        #expect(app.hasMainTimingEntry(for: id))
        app.deleteConversation(id)
        #expect(app.hasMainTimingEntry(for: id) == false)
    }

    /// Fix round 1 follow-up: an evaluator's `finishRun` removes it from `sessions`
    /// immediately (item 6), but its SAME engine turn keeps running and can still reach
    /// `updateRunPhase` afterward with a trailing `.responding`. That must not leak into
    /// `mainPhaseByConversation` — the guard is `isSubagent == false`, and an evaluator
    /// conversation (a) is `isSubagent == true` and (b) is usually already deleted by
    /// `GoalEvaluator` by the time this fires, so the lookup fails either way.
    @Test("a subagent/evaluator's trailing phase update after finishRun does not leak into the main dictionary")
    func trailingPhaseUpdateForSubagentDoesNotLeak() {
        let app = isolatedApp()
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        app.registerSubagent(id: id, role: "evaluator", kind: .evaluator)
        app.finishRun(id: id, status: "graded")   // removes it from `sessions` immediately
        app.updateRunPhase(id, .responding)        // the trailing update from the same turn
        #expect(app.hasMainTimingEntry(for: id) == false)
    }
}

/// The linger sweep is a pure function over `[ActivitySummary]` + `now` (AppState schedules it via
/// a `Task.sleep`, which is not itself worth testing) — this is what makes the 60s window testable
/// without sleeping in a test.
@Suite("ActivitySummary.sweep", .timeLimit(.minutes(1)))
struct SessionSweepTests {
    private func finished(_ at: Date) -> ActivitySummary {
        ActivitySummary(id: UUID(), kind: .subagent, role: "r", owner: nil, startTime: at, phase: .finished(status: "completed", at: at), lastActivity: nil)
    }
    private func running() -> ActivitySummary {
        ActivitySummary(id: UUID(), kind: .subagent, role: "r", owner: nil, startTime: Date(), phase: .thinking, lastActivity: nil)
    }

    @Test("drops a finished entry older than the linger window")
    func dropsOld() {
        let now = Date()
        let old = finished(now.addingTimeInterval(-61))
        let result = ActivitySummary.sweep([old], now: now, lingerWindow: 60)
        #expect(result.isEmpty)
    }

    @Test("keeps a finished entry within the linger window")
    func keepsRecent() {
        let now = Date()
        let recent = finished(now.addingTimeInterval(-30))
        let result = ActivitySummary.sweep([recent], now: now, lingerWindow: 60)
        #expect(result.count == 1)
    }

    @Test("never drops a running entry")
    func keepsRunning() {
        let now = Date()
        let result = ActivitySummary.sweep([running()], now: now, lingerWindow: 60)
        #expect(result.count == 1)
    }
}

/// End-to-end through the engine: a scripted `run_command` call must leave the session's
/// `lastActivity` recording the tool and its detail. `lastActivity` (rather than asserting on
/// `phase` mid-call) is the seam #217/#19 needs, since by the time the turn returns the phase has
/// already moved on to `.thinking`/`.responding` for whatever round came after the tool call.
@MainActor
@Suite("executeToolWithHooks session activity (#217 + #19)", .timeLimit(.minutes(1)))
struct ExecuteToolSessionActivityTests {
    private static func response(_ fc: FunctionCall?, text: String = "ok") -> GeminiResponse {
        let part = Part(text: fc == nil ? text : nil, functionCall: fc)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    @Test("a scripted run_command call records lastActivity on the session")
    func recordsRunCommandActivity() async {
        let app = AppState(store: try! ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        app.registerSubagent(id: id, role: "engineer")

        // Fix round 1: this actually executes (autoApproveTools bypasses the approval prompt), so
        // the scripted command must be cheap — "swift test" here forked a NESTED `swift test` and
        // took 639s, tripping the tool's own timeout. `echo hi` matches every other scripted
        // run_command in this repo (ApprovalQueueTests, ScenarioTests, ScenarioRunnerTests, ...).
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo hi")])
        let client = FakeLLMClient(responses: [Self.response(call), Self.response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent, client: client)
        await engine.processInput("go", source: "System", conversationId: id)

        let session = app.stripRuns.first { $0.id == id }
        #expect(session?.lastActivity == ActivitySummary.LastActivity(tool: "run_command", detail: "echo hi"))
    }
}

@Suite("Activity strip toggle (#982)")
struct ActivityStripToggleTests {
    private func run(_ kind: ActivitySummary.Kind, _ phase: ActivitySummary.Phase = .thinking) -> ActivitySummary {
        ActivitySummary(id: UUID(), kind: kind, role: "r", owner: nil, startTime: Date(), phase: phase, lastActivity: nil)
    }

    @Test("with no runs, or only the main row, the toggle has nothing to do")
    func nothingToToggle() {
        #expect(!ActivityStripView.hasRunsToToggle([]))
        #expect(!ActivityStripView.hasRunsToToggle([run(.main)]))
        #expect(!ActivityStripView.hasRunsToToggle([run(.main, .idle)]))
    }

    @Test("a subagent, evaluator or job run, running or lingering finished, gives it something to toggle")
    func somethingToToggle() {
        let done = ActivitySummary.Phase.finished(status: "completed", at: Date())
        for kind in [ActivitySummary.Kind.subagent, .evaluator, .job] {
            #expect(ActivityStripView.hasRunsToToggle([run(.main), run(kind)]))
            #expect(ActivityStripView.hasRunsToToggle([run(kind, done)]))
        }
    }

    @Test("the cpu button collapses when runs exist and shows the idle note when none do")
    func toggleTarget() {
        #expect(ActivityStripView.toggleTarget([]) == .idleNote)
        #expect(ActivityStripView.toggleTarget([run(.main)]) == .idleNote)
        #expect(ActivityStripView.toggleTarget([run(.main), run(.subagent)]) == .collapse)
    }

    @Test("the idle note shows only while requested and only while nothing else is on the strip")
    func idleNoteVisibility() {
        #expect(ActivityStripView.showsIdleNote([run(.main, .idle)], requested: true))
        #expect(ActivityStripView.showsIdleNote([], requested: true))
        #expect(!ActivityStripView.showsIdleNote([run(.main, .idle)], requested: false))
        #expect(!ActivityStripView.showsIdleNote([run(.main), run(.subagent)], requested: true))
        #expect(ActivityStripView.idleNoteText == "No active runs")
    }

    @Test("a turn starting ends the idle-note request; main going idle keeps it (#989 review)")
    func idleNoteRequestFollowsMain() {
        #expect(!ActivityStripView.idleNoteRequest(true, mainIsIdle: false))
        #expect(ActivityStripView.idleNoteRequest(true, mainIsIdle: true))
        #expect(!ActivityStripView.idleNoteRequest(false, mainIsIdle: true))
    }
}
