import Testing
import Foundation
@testable import iris

/// Pure mappings behind the session strip (#217 + #19): the tool-argument → activity-text
/// derivation and the token-count formatter. No SwiftUI here by design (AGENTS.md: no SwiftUI
/// unit tests) — everything the strip renders from is testable as plain functions.
@Suite("SessionActivity")
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

    private static func session(_ phase: SessionSummary.Phase, kind: SessionSummary.Kind = .subagent) -> SessionSummary {
        SessionSummary(id: UUID(), kind: kind, role: "r", startTime: Date(), phase: phase, lastActivity: nil)
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

/// `AppState`'s session-tracking surface: `registerSubagent`, `updateSessionPhase`,
/// `finishSession`, and `visibleSessions`. Uses the isolated in-memory constructor (AGENTS.md
/// invariant 7) so nothing here touches `~/.iris`.
@MainActor
@Suite("AppState session tracking (#217 + #19)")
struct SessionTrackingTests {
    private func isolatedApp() -> AppState {
        AppState(store: try! ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    @Test("registerSubagent adds a running session, defaulting to kind .subagent")
    func registerAdds() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "researcher")
        let session = app.sessions.first { $0.id == id }
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
        #expect(app.sessions.first { $0.id == id }?.kind == .evaluator)
    }

    @Test("updateSessionPhase changes the tracked phase and records lastActivity for .executing")
    func updatePhase() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.updateSessionPhase(id, .executing(tool: "run_command", detail: "swift build"))
        let session = app.sessions.first { $0.id == id }
        if case .executing(let tool, let detail) = session?.phase {
            #expect(tool == "run_command")
            #expect(detail == "swift build")
        } else {
            Issue.record("expected .executing")
        }
        #expect(session?.lastActivity == SessionSummary.LastActivity(tool: "run_command", detail: "swift build"))
    }

    @Test("finishSession marks the session finished with the given status and keeps it")
    func finish() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.finishSession(id: id, status: "completed")
        let session = app.sessions.first { $0.id == id }
        if case .finished(let status, _) = session?.phase {
            #expect(status == "completed")
        } else {
            Issue.record("expected .finished")
        }
    }

    /// Fix round 1, item 1: `goal_complete` fires the completion callback from inside the tool
    /// handler while the SAME engine turn keeps running (its next round produces a closing text
    /// reply), so a `.responding`/`.thinking` update can land AFTER `finishSession` already ran.
    /// Once finished, nothing may move a session off that phase, and the sweep must still collect
    /// it (i.e. the guard doesn't also block the sweep from seeing it as finished).
    @Test("updateSessionPhase after finishSession is a no-op; the sweep still removes it")
    func finishedSessionIgnoresLaterPhaseUpdates() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.finishSession(id: id, status: "completed")
        app.updateSessionPhase(id, .responding)
        let session = app.sessions.first { $0.id == id }
        guard case .finished(let status, let at) = session?.phase else {
            Issue.record("expected .finished to survive a later updateSessionPhase call")
            return
        }
        #expect(status == "completed")
        let swept = SessionSummary.sweep(app.sessions, now: at.addingTimeInterval(61), lingerWindow: 60)
        #expect(swept.isEmpty)
    }

    /// Fix round 1, item 6: an evaluator's conversation is deleted by `GoalEvaluator` right after
    /// `finishSession` — there's no transcript behind a lingering row, so it's removed immediately.
    /// A subagent (not an evaluator) still lingers.
    @Test("finishSession removes an evaluator session immediately, with no linger")
    func evaluatorFinishHasNoLinger() {
        let app = isolatedApp()
        let evaluatorId = UUID(), subagentId = UUID()
        app.registerSubagent(id: evaluatorId, role: "evaluator", kind: .evaluator)
        app.registerSubagent(id: subagentId, role: "engineer")
        app.finishSession(id: evaluatorId, status: "graded")
        app.finishSession(id: subagentId, status: "completed")
        #expect(app.sessions.contains { $0.id == evaluatorId } == false)
        #expect(app.sessions.first { $0.id == subagentId }.map {
            if case .finished = $0.phase { return true } else { return false }
        } == true)
    }

    @Test("visibleSessions puts the main session first and includes only subagent/evaluator kinds")
    func visibleSessionsOrdering() {
        let app = isolatedApp()
        let subagentId = UUID(), evaluatorId = UUID()
        app.registerSubagent(id: subagentId, role: "engineer")
        app.registerSubagent(id: evaluatorId, role: "evaluator", kind: .evaluator)
        let visible = app.visibleSessions
        #expect(visible.first?.kind == .main)
        #expect(visible.first?.role == "main")
        #expect(Set(visible.dropFirst().map(\.id)) == [subagentId, evaluatorId])
        #expect(visible.dropFirst().allSatisfy { $0.kind == .subagent || $0.kind == .evaluator })
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
        let firstStart = app.visibleSessions.first?.elapsedStartTime
        #expect(firstStart != nil)
        app.beginEngineTurn(for: id)   // nested — must not reset the start
        #expect(app.visibleSessions.first?.elapsedStartTime == firstStart)
        app.endEngineTurn(for: id)     // 2→1: still running, start still held
        #expect(app.hasTurnInFlight(for: id))
        #expect(app.visibleSessions.first?.elapsedStartTime == firstStart)
        app.endEngineTurn(for: id)     // balance the nested begin above
    }

    @Test("endEngineTurn back to zero makes the main row idle (no elapsed time)")
    func endEngineTurnGoesIdle() {
        let app = isolatedApp()
        let id = app.selectedConversationId!
        app.beginEngineTurn(for: id)
        #expect(app.visibleSessions.first?.elapsedStartTime != nil)
        app.endEngineTurn(for: id)
        #expect(app.hasTurnInFlight(for: id) == false)
        #expect(app.visibleSessions.first?.elapsedStartTime == nil)
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
        app.updateSessionPhase(a, .executing(tool: "run_command", detail: "echo hi"))
        #expect(app.visibleSessions.first?.phase == .executing(tool: "run_command", detail: "echo hi"))

        app.selectedConversationId = b
        #expect(app.visibleSessions.first?.phase == .idle)

        app.selectedConversationId = a
        #expect(app.visibleSessions.first?.phase == .executing(tool: "run_command", detail: "echo hi"))
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
        app.updateSessionPhase(id, .thinking)
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
        app.updateSessionPhase(id, .thinking)
        #expect(app.hasMainTimingEntry(for: id))
        app.deleteConversation(id)
        #expect(app.hasMainTimingEntry(for: id) == false)
    }

    /// Fix round 1 follow-up: an evaluator's `finishSession` removes it from `sessions`
    /// immediately (item 6), but its SAME engine turn keeps running and can still reach
    /// `updateSessionPhase` afterward with a trailing `.responding`. That must not leak into
    /// `mainPhaseByConversation` — the guard is `isSubagent == false`, and an evaluator
    /// conversation (a) is `isSubagent == true` and (b) is usually already deleted by
    /// `GoalEvaluator` by the time this fires, so the lookup fails either way.
    @Test("a subagent/evaluator's trailing phase update after finishSession does not leak into the main dictionary")
    func trailingPhaseUpdateForSubagentDoesNotLeak() {
        let app = isolatedApp()
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        app.registerSubagent(id: id, role: "evaluator", kind: .evaluator)
        app.finishSession(id: id, status: "graded")   // removes it from `sessions` immediately
        app.updateSessionPhase(id, .responding)        // the trailing update from the same turn
        #expect(app.hasMainTimingEntry(for: id) == false)
    }
}

/// The linger sweep is a pure function over `[SessionSummary]` + `now` (AppState schedules it via
/// a `Task.sleep`, which is not itself worth testing) — this is what makes the 60s window testable
/// without sleeping in a test.
@Suite("SessionSummary.sweep")
struct SessionSweepTests {
    private func finished(_ at: Date) -> SessionSummary {
        SessionSummary(id: UUID(), kind: .subagent, role: "r", startTime: at, phase: .finished(status: "completed", at: at), lastActivity: nil)
    }
    private func running() -> SessionSummary {
        SessionSummary(id: UUID(), kind: .subagent, role: "r", startTime: Date(), phase: .thinking, lastActivity: nil)
    }

    @Test("drops a finished entry older than the linger window")
    func dropsOld() {
        let now = Date()
        let old = finished(now.addingTimeInterval(-61))
        let result = SessionSummary.sweep([old], now: now, lingerWindow: 60)
        #expect(result.isEmpty)
    }

    @Test("keeps a finished entry within the linger window")
    func keepsRecent() {
        let now = Date()
        let recent = finished(now.addingTimeInterval(-30))
        let result = SessionSummary.sweep([recent], now: now, lingerWindow: 60)
        #expect(result.count == 1)
    }

    @Test("never drops a running entry")
    func keepsRunning() {
        let now = Date()
        let result = SessionSummary.sweep([running()], now: now, lingerWindow: 60)
        #expect(result.count == 1)
    }
}

/// End-to-end through the engine: a scripted `run_command` call must leave the session's
/// `lastActivity` recording the tool and its detail. `lastActivity` (rather than asserting on
/// `phase` mid-call) is the seam #217/#19 needs, since by the time the turn returns the phase has
/// already moved on to `.thinking`/`.responding` for whatever round came after the tool call.
@MainActor
@Suite("executeToolWithHooks session activity (#217 + #19)")
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

        let session = app.sessions.first { $0.id == id }
        #expect(session?.lastActivity == SessionSummary.LastActivity(tool: "run_command", detail: "echo hi"))
    }
}
