import Testing
import Foundation
@testable import IrisKit

/// #766 (#198's narrow option): `GoalContract.oracleText()` goes into every reprompt of every goal,
/// so a sentence in it that the code stops honouring misleads the model on every turn of a long
/// run (slice D3 left three such strings). Each claim here that the code can check is checked
/// against the code that makes it true: change the behaviour and this fails, pointing at the
/// sentence to rewrite. Only the mechanically checkable claims; the rest stays review's.
@MainActor
@Suite("The oracle's claims hold (#766)", .timeLimit(.minutes(1)))
struct OracleClaimsTests {
    private let build = Criterion(text: "build green", kind: .executable, check: "swift build")
    private let docs = Criterion(text: "docs read well", kind: .qualitative, check: nil)
    private let taste = Criterion(text: "the owner likes it", kind: .humanJudged, check: nil)

    /// Locked, on `checkpoint` of a two-checkpoint ladder, or with no ladder when nil.
    private func contract(checkpoint: Int?) -> GoalContract {
        var c = GoalContract(objective: "Ship it", criteria: [build, docs, taste])
        if let checkpoint {
            c.milestones = [Milestone(title: "Compile", criterionIds: [build.id]),
                            Milestone(title: "Polish", criterionIds: [docs.id, taste.id])]
            c.currentMilestone = checkpoint
        }
        c.lock()
        return c
    }

    /// The tools one turn under `c` declares, through a real engine.
    private func declared(under c: GoalContract) async throws -> Set<String> {
        let app = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                factStore: try FactStoreManager(inMemory: true), protectionEnabled: false,
                                sessionPeerCount: 0, stickyTools: false)
        await engine.processInput("carry on", source: "UI", conversationId: id)
        return Set(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    }

    /// Every tool the oracle names in backticks.
    private func toolsNamed(in oracle: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: "`([a-z]+(?:_[a-z]+)+)`")
        return Set(regex.matches(in: oracle, range: NSRange(oracle.startIndex..., in: oracle))
            .compactMap { Range($0.range(at: 1), in: oracle).map { String(oracle[$0]) } })
    }

    @Test("every tool the oracle tells the model to call is declared on that turn: no ladder, a checkpoint, the final one")
    func namedToolsAreDeclared() async throws {
        for (label, checkpoint, expected) in [("no ladder", nil as Int?, ["amend_goal_contract"]),
                                              ("first checkpoint", 0, ["amend_goal_contract", "reach_checkpoint"]),
                                              ("final checkpoint", 1, ["amend_goal_contract", "goal_complete"])] {
            let c = contract(checkpoint: checkpoint)
            let named = toolsNamed(in: c.oracleText())
            #expect(Set(expected).isSubset(of: named), "\(label): the oracle names \(named.sorted())")
            let tools = try await declared(under: c)
            for name in named {
                #expect(tools.contains(name), "\(label): the oracle says to call `\(name)`, which this turn doesn't declare")
            }
        }
    }

    @Test("\"a clean grade advances on its own; anything contested pauses for the user\" is D3's rule")
    func checkpointSentenceIsTheRule() {
        let c = contract(checkpoint: 0)
        #expect(c.oracleText().contains("a clean grade advances on its own; anything contested pauses for the user"))
        func graded(_ v: CriterionVerdictValue) -> GoalEvaluation {
            GoalEvaluation(status: .graded,
                           criteria: [CriterionVerdict(criterionId: build.id, criterionText: build.text, kind: build.kind,
                                                       verdict: v, evidence: "e", method: .check)],
                           startedAt: Date())
        }
        #expect(c.canAutoAdvance(from: graded(.met)), "a clean grade advances on its own")
        for contested in [CriterionVerdictValue.notMet, .cannotVerify] {
            #expect(!c.canAutoAdvance(from: graded(contested)), "\(contested) pauses for the user")
        }
        #expect(!c.canAutoAdvance(from: nil), "no grade at all pauses")
        // The final checkpoint's sentence makes no auto-advance claim, and none is made.
        let last = contract(checkpoint: 1)
        #expect(!last.oracleText().contains("advances on its own"))
        #expect(!last.canAutoAdvance(from: graded(.met)))
    }

    @Test("\"human-judged — you do not grade this\": the grader is told the same, and only the person's acceptance clears it")
    func humanJudgedIsNotGraded() {
        var c = contract(checkpoint: nil)
        #expect(c.oracleText().contains("[human-judged — you do not grade this] \(taste.text)"))
        let line = GoalEvaluator.systemPrompt(for: c, workspaceDir: "/tmp/iris-766")
            .components(separatedBy: "\n").first { $0.contains(taste.id.uuidString) } ?? ""
        #expect(line.contains("do NOT grade this"), "the grader's line: \(line)")

        // On a ladder, a human-judged criterion is the person's: graded as met it still pauses until they accept it.
        c = contract(checkpoint: 0)
        c.milestones[0].criterionIds = [taste.id]
        let met = GoalEvaluation(status: .graded,
                                 criteria: [CriterionVerdict(criterionId: taste.id, criterionText: taste.text, kind: .humanJudged,
                                                             verdict: .met, evidence: "e", method: .judge)],
                                 startedAt: Date())
        #expect(!c.canAutoAdvance(from: met), "the grader can't settle it")
        c.judgements[taste.id] = true
        #expect(c.canAutoAdvance(from: met), "the person's acceptance does")
    }
}
