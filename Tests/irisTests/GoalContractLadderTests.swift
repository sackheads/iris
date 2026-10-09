import Testing
import Foundation
@testable import IrisKit

@Suite("GoalContract ladder")
struct GoalContractLadderTests {
    private func laddered() -> GoalContract {
        let a = Criterion(text: "build green", kind: .executable, check: "swift build")
        let b = Criterion(text: "tests pass", kind: .executable, check: "swift test")
        let c = Criterion(text: "docs updated", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "Ship it", criteria: [a, b, c])
        contract.milestones = [
            Milestone(title: "Compile", criterionIds: [a.id]),
            Milestone(title: "Verify", criterionIds: [b.id, c.id]),
        ]
        return contract
    }

    @Test("hasLadder and isFinalMilestone reflect the ladder")
    func flags() {
        var c = laddered()
        #expect(c.hasLadder)
        #expect(!c.isFinalMilestone)          // currentMilestone == 0, two milestones
        c.currentMilestone = 1
        #expect(c.isFinalMilestone)
        let empty = GoalContract(objective: "x", criteria: [])
        #expect(!empty.hasLadder)
    }

    @Test("currentMilestoneCriteria returns only the current milestone's criteria")
    func currentSlice() {
        let c = laddered()
        #expect(c.currentMilestoneCriteria().map(\.text) == ["build green"])
    }

    @Test("projectedContract is cumulative through N, locked, and de-laddered")
    func projection() {
        let c = laddered()
        let p0 = c.projectedContract(throughMilestone: 0)
        #expect(p0.criteria.map(\.text) == ["build green"])
        #expect(p0.milestones.isEmpty)
        #expect(p0.isLocked)
        let p1 = c.projectedContract(throughMilestone: 1)
        #expect(p1.criteria.map(\.text) == ["build green", "tests pass", "docs updated"])
    }

    @Test("ladderIsValidPartition accepts a disjoint cover and rejects a gap")
    func partition() {
        #expect(laddered().ladderIsValidPartition())
        var gap = laddered()
        gap.milestones = [gap.milestones[0]]     // drops criteria b and c
        #expect(!gap.ladderIsValidPartition())
        #expect(GoalContract(objective: "x", criteria: []).ladderIsValidPartition())  // no ladder is valid
    }

    @Test("normalizedLadder folds unassigned criteria into a final milestone and clamps index")
    func normalize() {
        var gap = laddered()
        gap.milestones = [gap.milestones[0]]     // b and c now unassigned
        gap.currentMilestone = 9
        let n = gap.normalizedLadder()
        #expect(n.milestones.count == 2)
        #expect(n.milestones.last?.criterionIds.count == 2)   // b and c folded in
        #expect(n.currentMilestone == 1)                       // clamped to last index
    }

    @Test("ladder round-trips through Codable and legacy contracts decode to no ladder")
    func codable() throws {
        var c = laddered(); c.lock()
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        // A contract encoded without ladder fields (simulated by a plain contract) has an empty ladder.
        let legacy = GoalContract(objective: "old", criteria: [Criterion(text: "y", kind: .qualitative, check: nil)])
        let legacyBack = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(legacy))
        #expect(!legacyBack.hasLadder)
        #expect(legacyBack.checkpointStatus == .running)
    }

    @Test("oracleText names the current checkpoint and the reach_checkpoint instruction")
    func oracleLadder() {
        var c = laddered(); c.lock()
        let t = c.oracleText()
        #expect(t.contains("Current checkpoint"))
        #expect(t.contains("Compile"))                 // current milestone title
        #expect(t.contains("reach_checkpoint"))
        #expect(t.contains("goal_complete"))
        // A no-ladder contract keeps the plain oracle (no checkpoint language).
        let plain = GoalContract(objective: "x", criteria: [Criterion(text: "y", kind: .qualitative, check: nil)])
        #expect(!plain.oracleText().contains("Current checkpoint"))
    }

    @Test("a slice-A/C contract JSON (no ladder keys) decodes with ladder defaults")
    func decodesPreLadderContract() throws {
        // A contract persisted BEFORE slice B1 existed — no milestones/currentMilestone/
        // checkpointStatus keys. Synthesized Codable would throw keyNotFound and drop the whole
        // conversation list; the custom decoder must default them instead.
        let cid = UUID().uuidString
        let json = """
        {"id":"\(UUID().uuidString)","objective":"Ship","criteria":[{"id":"\(cid)","text":"x","kind":"qualitative"}],"outOfScope":[],"stopBefore":[],"assumptions":[],"changeLog":[],"state":"locked"}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(GoalContract.self, from: json)
        #expect(c.objective == "Ship")
        #expect(c.isLocked)
        #expect(c.milestones.isEmpty)
        #expect(!c.hasLadder)
        #expect(c.currentMilestone == 0)
        #expect(c.checkpointStatus == .running)
    }

    @Test("rungState classifies done / current / pausedCurrent / upcoming")
    func rungStates() {
        var c = laddered()          // two milestones, currentMilestone == 0, running
        #expect(c.rungState(forMilestoneAt: 0) == .current)
        #expect(c.rungState(forMilestoneAt: 1) == .upcoming)
        c.checkpointStatus = .pausedForReview
        #expect(c.rungState(forMilestoneAt: 0) == .pausedCurrent)
        c.checkpointStatus = .running
        c.currentMilestone = 1
        #expect(c.rungState(forMilestoneAt: 0) == .done)
        #expect(c.rungState(forMilestoneAt: 1) == .current)
    }

    @Test("a locked ladder mid-run round-trips through Codable with position and pause state")
    func codablePausedMidRun() throws {
        var c = laddered(); c.lock()
        c.currentMilestone = 1
        c.checkpointStatus = .pausedForReview
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(c))
        #expect(back.currentMilestone == 1)
        #expect(back.checkpointStatus == .pausedForReview)
        #expect(back.milestones.map(\.title) == ["Compile", "Verify"])
        #expect(back == c)
    }
}

@Suite("MilestoneLadderEditing")
struct MilestoneLadderEditingTests {
    @Test("addMilestone creates the checkpoint and assigns the criterion")
    func addCreatesAndAssigns() {
        let c1 = UUID()
        let m = MilestoneLadderEditing.addMilestone([], title: "A", assigning: c1)
        #expect(m.map(\.title) == ["A"])
        #expect(m.first?.criterionIds == [c1])
    }

    @Test("reassigning a criterion preserves first-appearance order and leaves the old rung empty")
    func reassignPreservesOrder() {
        let c1 = UUID()
        var m = MilestoneLadderEditing.addMilestone([], title: "A", assigning: c1)   // [A:[c1]]
        m = MilestoneLadderEditing.addMilestone(m, title: "B", assigning: UUID())     // [A:[c1], B:[..]]
        m = MilestoneLadderEditing.assign(m, criterionId: c1, toTitle: "B")           // move c1 A→B
        #expect(m.map(\.title) == ["A", "B"])          // order preserved, A retained though now empty
        #expect(m[0].criterionIds.isEmpty)
        #expect(m[1].criterionIds.contains(c1))
    }

    @Test("assigning to nil unassigns from every milestone")
    func assignNilUnassigns() {
        let c1 = UUID()
        var m = MilestoneLadderEditing.addMilestone([], title: "A", assigning: c1)
        m = MilestoneLadderEditing.assign(m, criterionId: c1, toTitle: nil)
        #expect(m[0].criterionIds.isEmpty)
    }

    @Test("a criterion belongs to at most one milestone after assign")
    func assignIsDisjoint() {
        let c1 = UUID()
        var m = MilestoneLadderEditing.addMilestone([], title: "A", assigning: c1)
        m = MilestoneLadderEditing.addMilestone(m, title: "B", assigning: UUID())
        m = MilestoneLadderEditing.assign(m, criterionId: c1, toTitle: "B")
        let count = m.reduce(0) { $0 + ($1.criterionIds.contains(c1) ? 1 : 0) }
        #expect(count == 1)
    }
}
