import Testing
import Foundation
@testable import iris

/// End-to-end D3: reach_checkpoint grades first, then decides.
@MainActor
@Suite("Checkpoint auto-advance (D3)")
struct CheckpointAutoAdvanceTests {

    /// Routes by principal: the grader offers `submit_evaluation` and is scripted to hand back
    /// one fixed verdict/evidence pair for every criterion id found in its own system prompt
    /// (ladder ids are minted per test, so the grader can't be scripted by id). Everything else
    /// comes from `mainScript`, in order.
    final class RoutingClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let uuidPattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderCallCount = 0
        private let mainScript: [GeminiResponse]
        private let verdict: String
        private let evidence: String

        /// `graderSubmits: false` scripts a grader that answers in prose and never calls
        /// `submit_evaluation` — the crashed/confused/timed-out grader §4's fail-safe exists for.
        private let graderSubmits: Bool

        /// How many independent grading sessions may submit a verdict. Every other test in this
        /// file grades exactly one checkpoint, so the original `== 1` cutoff after the global
        /// first call was never wrong for them. The concurrent-checkpoint regression grades TWO
        /// sessions at once (both against milestone 0, since neither has advanced yet), and both
        /// must submit cleanly for the race it is reproducing to be reachable at all.
        private let graderSubmitLimit: Int

        init(main: [GeminiResponse], graderVerdict: (String, String), graderSubmits: Bool = true,
             graderSubmitLimit: Int = 1) {
            self.mainScript = main
            self.verdict = graderVerdict.0
            self.evidence = graderVerdict.1
            self.graderSubmits = graderSubmits
            self.graderSubmitLimit = graderSubmitLimit
        }
        var graderCalls: Int { lock.withLock { graderCallCount } }

        private static func text(_ s: String) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model",
                parts: [Part(text: s, functionCall: nil, functionResponse: nil,
                             thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: nil)
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let offersSubmit = request.tools?.contains {
                $0.functionDeclarations.contains { $0.name == "submit_evaluation" }
            } ?? false
            let systemText = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            if offersSubmit {
                let myCallIndex: Int = lock.withLock { graderCallCount += 1; return graderCallCount }
                guard self.graderSubmits else { return Self.text("I looked at it and it seems fine.") }
                guard myCallIndex <= self.graderSubmitLimit else { return Self.text("done") }
                // Stagger every grading session after the first: in production, two concurrent
                // `reach_checkpoint` grades finish minutes apart, not in the same instant, which
                // is exactly the gap the double-advance bug needs — the first call's full
                // grade-then-write has to land before the second call's re-read. A mocked client
                // with no delay lets both re-reads race ahead of either write instead, which
                // happens to self-correct and would hide the bug.
                if myCallIndex > 1 { try? await Task.sleep(nanoseconds: 50_000_000) }
                let ids = systemText.matches(of: Self.uuidPattern).map { String($0.output) }
                let evaluations = JSONValue.array(ids.map {
                    .object(["criterion_id": .string($0), "verdict": .string(self.verdict),
                             "evidence": .string(self.evidence)])
                })
                let part = Part(text: nil,
                                functionCall: FunctionCall(name: "submit_evaluation",
                                                           args: ["evaluations": evaluations],
                                                           id: nil, thought_signature: nil,
                                                           thoughtSignature: nil),
                                functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
                return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                      usageMetadata: nil)
            }
            return lock.withLock {
                let i = mainIndex
                mainIndex += 1
                return mainScript[min(i, mainScript.count - 1)]
            }
        }
    }

    static func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "ok" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    static func reachCheckpointCall() -> GeminiResponse {
        response(FunctionCall(name: "reach_checkpoint",
                              args: ["milestone_summary": .string("done with this checkpoint")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// Two `reach_checkpoint` calls in ONE model response — the shape a turn's concurrent
    /// `withTaskGroup` tool dispatch (AGENTS.md invariant 3) actually produces, unlike the
    /// existing `AutoAdvanceTransitionTests`, which calls `autoAdvanceCheckpoint` directly with a
    /// hand-written index and so cannot exercise how `performCheckpoint` computes that index.
    static func twoReachCheckpointCalls() -> GeminiResponse {
        let parts = (0..<2).map { _ in
            Part(text: nil,
                 functionCall: FunctionCall(name: "reach_checkpoint",
                                            args: ["milestone_summary": .string("done with this checkpoint")],
                                            id: nil, thought_signature: nil, thoughtSignature: nil),
                 functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        }
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: parts))],
                              usageMetadata: nil)
    }

    /// Three-milestone ladder on milestone 0, locked, one qualitative criterion per milestone.
    /// Three, not two: on a two-milestone ladder a double-advance from 0 would be clamped to the
    /// final milestone by `min(currentMilestone + 1, milestones.count - 1)` in both the buggy and
    /// fixed code, making the two indistinguishable. A third milestone gives the race somewhere
    /// to actually skip to.
    private func threeMilestoneLadder(on app: AppState, _ id: UUID) {
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        let c = Criterion(text: "shipped", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "Ship the parser", criteria: [a, b, c])
        contract.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                               Milestone(title: "Integration", criterionIds: [b.id]),
                               Milestone(title: "Ship", criterionIds: [c.id])]
        contract.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, contract)
    }

    /// Two-milestone ladder on milestone 0, locked, with one qualitative criterion per milestone.
    private func ladder(on app: AppState, _ id: UUID) {
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
    }

    @Test("a clean grade advances the ladder and does not pause")
    func testCleanGradeAdvances() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1, "a clean checkpoint should advance")
        #expect(c?.checkpointStatus == .running, "a clean checkpoint should not pause")
        let history = app.conversations.first { $0.id == id }?.checkpointHistory ?? []
        #expect(history.first?.resolution == .autoAdvanced)
    }

    @Test("a not_met grade pauses exactly as before")
    func testFailedGradePauses() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("not_met", "parser crashes on nested input"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 0)
        #expect(c?.checkpointStatus == .pausedForReview)
    }

    @Test("the setting off pauses on a grade that would otherwise advance")
    func testSettingOffPauses() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: client, checkpointAutoAdvance: false)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 0)
        #expect(c?.checkpointStatus == .pausedForReview)
    }

    @Test("an explicit true override advances, same as the setting-off override wins false")
    func testExplicitTrueOverrideAdvances() async {
        // Override precedence, explicit-true half of the pair with `testSettingOffPauses`
        // (explicit-false). `checkpointAutoAdvance` is `Bool?` now (#208 review item 1): this
        // pins the override winning over whatever config says, without reading config at all.
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: client, checkpointAutoAdvance: true)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1)
        #expect(c?.checkpointStatus == .running)
    }

    @Test("a nil override falls through to the live ConfigManager value")
    func testNilOverrideFallsThroughToConfig() async {
        // Exercises the fall-through wiring `checkpointAutoAdvanceOverride ?? ConfigManager.shared
        // .checkpointAutoAdvance` added for #208 review item 1. It cannot honestly prove the
        // toggle takes effect without a relaunch — doing that would mean mutating
        // `ConfigManager.shared` from a test, which invariant 7 forbids — so it only pins that an
        // explicit `nil` reaches the live config default (true, unset) rather than being treated
        // as `false`. Override precedence is otherwise covered by `testExplicitTrueOverrideAdvances`
        // and `testSettingOffPauses`.
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: client, checkpointAutoAdvance: nil)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1, "nil must fall through to config, not be treated as false")
        #expect(c?.checkpointStatus == .running)
    }

    @Test("an unjudged humanJudged criterion stops the checkpoint without asking for the verdict")
    func testHumanJudgedPausesWithoutAsking() async {
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, h, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id, h.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.currentMilestone == 0, "an unjudged human criterion must not be skipped")
        #expect(after?.checkpointStatus == .pausedForReview, "it still stops for the human")
        // It must NOT open a judgement pause. The inline Accept/Reject surface does not exist, so
        // asking here would stop the user with a question that has no answer button — and a
        // restart in that state is unrecoverable (`sanitizeLoaded` nils `lastGoalEvaluation`, so
        // `recordHumanJudgement` can never succeed again). Judgement stays at the terminal gate.
        #expect(after?.awaitingHumanJudgement == false,
                "the checkpoint stops for review; it does not ask for a verdict it cannot collect")
    }

    @Test("an unjudged humanJudged criterion in a FUTURE milestone must not trigger a judgement pause")
    func testFutureMilestoneHumanJudgedDoesNotTrapGoal() async {
        // Regression for a trapped-goal bug: the judgement-pause scan used to walk the WHOLE
        // contract, so an unjudged `humanJudged` criterion belonging to a milestone that hasn't
        // been reached yet — never part of the projected grade — would set
        // `awaitingHumanJudgement` with no way to ever clear it (it never appears in the
        // evaluation as `.humanPending`, so `recordHumanJudgement` can never find it). The fix
        // scans the evaluation, which only ever covers the projected (0...current) criteria.
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, h])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [h.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("not_met", "parser crashes on nested input"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.checkpointStatus == .pausedForReview, "a not_met grade on the current milestone still pauses")
        #expect(after?.awaitingHumanJudgement == false,
                "the human is asked about the current milestone only — the future criterion isn't graded yet")
    }

    @Test("a grader that never submits a verdict pauses the checkpoint")
    func testGraderThatNeverSubmitsPauses() async {
        // Spec §4's fail-safe, asserted end to end rather than only at the predicate. Grade-first
        // removed the structural guarantee that pausing is the default, so the path a real grader
        // actually fails on — answering in prose and never calling `submit_evaluation` — has to be
        // pinned where it can regress.
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "unused"), graderSubmits: false)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointStatus == .pausedForReview, "an ungraded checkpoint must stop")
        #expect(c?.currentMilestone == 0, "nothing was verified, so nothing may advance")
    }

    @Test("an auto-advance announces itself in the transcript")
    func testAutoAdvanceIsAnnounced() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let messages = app.conversations.first { $0.id == id }?.messages ?? []
        #expect(messages.contains { $0.content.contains("auto-advanced") },
                "a skipped checkpoint must leave an audit trail the user can read")
    }

    @Test("two concurrent reach_checkpoint calls advance the ladder exactly once")
    func testConcurrentReachCheckpointCallsAdvanceOnlyOnce() async {
        // Regression for the double-advance bug: `performCheckpoint` graded the PRE-grade
        // contract (milestone 0 for both A and B, since neither has written yet) but fed the
        // guard `decidedAt = current.currentMilestone` — a POST-grade re-read. Whichever call's
        // grade lands first advances 0→1 and its re-read reflects that; the second call then
        // re-reads milestone 1, sets decidedAt = 1, and the guard (`existing.currentMilestone ==
        // decidedAt`) matches trivially because decidedAt was copied FROM that same re-read.
        // Net effect: 0→2 on one turn, milestone 1 never worked, never graded, and
        // checkpointHistory gets two entries where a milestone 1 title carries milestone 0's
        // grade. `IrisEngine` dispatches a turn's tool calls concurrently in a `withTaskGroup`
        // (AGENTS.md invariant 3), so a model that emits two `reach_checkpoint` calls in one
        // batch really does hit this.
        let app = AppState(); let id = UUID(); threeMilestoneLadder(on: app, id)
        let client = RoutingClient(main: [Self.twoReachCheckpointCalls(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"), graderSubmitLimit: 2)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1,
                "the ladder must advance by exactly one milestone, not skip milestone 1")
        let history = app.conversations.first { $0.id == id }?.checkpointHistory ?? []
        #expect(history.count == 1, "one clean grade decided on, one audit entry")
        // The guard stopped the second advance, but the announcement used to be pushed
        // unconditionally from the pre-grade snapshot — two identical notices for one checkpoint.
        let messages = app.conversations.first { $0.id == id }?.messages ?? []
        #expect(messages.filter { $0.content.contains("auto-advanced") }.count == 1,
                "the refused call must stay silent, not repeat the winner's announcement")
    }
}
