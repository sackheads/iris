import Testing
import Foundation
@testable import iris

/// Slice B4: the contract a delegated milestone runs against is derived from the locked ladder,
/// never restated by a caller — so delegation cannot reshape the gate it is measured by.
@Suite("Milestone unit contract (B4)")
struct MilestoneUnitContractTests {
    private func laddered(currentMilestone: Int = 0) -> GoalContract {
        let a = Criterion(text: "parser handles nesting", kind: .qualitative, check: nil)
        let b = Criterion(text: "parser is tested", kind: .executable, check: "swift test")
        let c = Criterion(text: "wired into the app", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "Ship the parser", criteria: [a, b, c],
                                    outOfScope: ["rewriting the lexer"],
                                    stopBefore: ["force-pushing"])
        contract.milestones = [Milestone(title: "Parser", criterionIds: [a.id, b.id]),
                               Milestone(title: "Integration", criterionIds: [c.id])]
        contract.currentMilestone = currentMilestone
        contract.lock()
        return contract
    }

    @Test("the unit's criteria are exactly the current milestone's")
    func criteriaComeFromTheLadder() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        #expect(unit.criteria.count == 2)
        #expect(unit.criteria.map(\.text) == ["parser handles nesting", "parser is tested"])
        #expect(unit.criteria[1].check == "swift test")
    }

    @Test("the second milestone yields its own criteria, not the first's")
    func tracksCurrentMilestone() throws {
        let unit = try #require(laddered(currentMilestone: 1).currentMilestoneUnitContract())
        #expect(unit.criteria.map(\.text) == ["wired into the app"])
    }

    @Test("scope boundaries are inherited, so delegation cannot launder a restriction")
    func inheritsScopeBoundaries() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        #expect(unit.outOfScope == ["rewriting the lexer"])
        #expect(unit.stopBefore == ["force-pushing"])
    }

    @Test("the unit is locked and carries no ladder of its own")
    func lockedAndFlat() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        // A ladder here would strand the run: the oracle would tell the subagent to call
        // reach_checkpoint, which is gated to the main principal.
        #expect(unit.hasLadder == false)
        #expect(unit.isLocked)
    }

    @Test("the objective carries the goal, the ladder position, and the milestone title")
    func objectiveGivesContext() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        #expect(unit.objective.contains("Ship the parser"))
        #expect(unit.objective.contains("1/2"))
        #expect(unit.objective.contains("Parser"))
    }

    @Test("a contract with no ladder has no milestone to delegate")
    func noLadderNoUnit() {
        let flat = GoalContract(objective: "Ship", criteria: [
            Criterion(text: "it works", kind: .qualitative, check: nil)
        ])
        #expect(flat.currentMilestoneUnitContract() == nil)
    }
}
