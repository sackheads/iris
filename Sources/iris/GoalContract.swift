import Foundation

enum CriterionKind: String, Codable, Sendable, Equatable {
    case executable   // carries a runnable `check`
    case qualitative  // concrete "done looks like X"; no number
    case humanJudged  // "you decide" — never auto-graded
}

struct Criterion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var kind: CriterionKind
    var check: String?   // command/test for .executable; nil otherwise
}

struct Milestone: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var criterionIds: [UUID]
}

enum CheckpointStatus: String, Codable, Sendable, Equatable {
    case running          // loop active (or no ladder)
    case pausedForReview  // reached a checkpoint; auto-reprompt suppressed, awaiting the human
}

struct ContractChange: Codable, Equatable, Sendable {
    var date: Date = Date()
    var rationale: String
}

enum ContractState: String, Codable, Sendable, Equatable {
    case draft, locked
}

struct GoalContract: Codable, Equatable, Sendable {
    var id = UUID()
    var objective: String
    var criteria: [Criterion]
    var outOfScope: [String] = []
    var stopBefore: [String] = []
    var assumptions: [String] = []
    var changeLog: [ContractChange] = []
    var milestones: [Milestone] = []          // empty ⇒ no ladder ⇒ today's single-terminal behavior
    var currentMilestone: Int = 0             // index of the milestone being worked
    var checkpointStatus: CheckpointStatus = .running
    var state: ContractState = .draft

    init(id: UUID = UUID(), objective: String, criteria: [Criterion], outOfScope: [String] = [],
         stopBefore: [String] = [], assumptions: [String] = [], changeLog: [ContractChange] = [],
         milestones: [Milestone] = [], currentMilestone: Int = 0,
         checkpointStatus: CheckpointStatus = .running, state: ContractState = .draft) {
        self.id = id; self.objective = objective; self.criteria = criteria
        self.outOfScope = outOfScope; self.stopBefore = stopBefore; self.assumptions = assumptions
        self.changeLog = changeLog; self.milestones = milestones; self.currentMilestone = currentMilestone
        self.checkpointStatus = checkpointStatus; self.state = state
    }

    /// Custom decoder so the ladder fields (added in slice B1) are `decodeIfPresent`-defaulted:
    /// synthesized `Codable` ignores property defaults and would throw `keyNotFound` on a contract
    /// persisted by slice A/C (before `milestones`/`currentMilestone`/`checkpointStatus` existed),
    /// failing the WHOLE `[Conversation]` decode and dropping every conversation. All older
    /// defaulted fields are decoded leniently too, for the same forward-compat reason.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        objective = try c.decode(String.self, forKey: .objective)
        criteria = try c.decode([Criterion].self, forKey: .criteria)
        outOfScope = try c.decodeIfPresent([String].self, forKey: .outOfScope) ?? []
        stopBefore = try c.decodeIfPresent([String].self, forKey: .stopBefore) ?? []
        assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        changeLog = try c.decodeIfPresent([ContractChange].self, forKey: .changeLog) ?? []
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
        currentMilestone = try c.decodeIfPresent(Int.self, forKey: .currentMilestone) ?? 0
        checkpointStatus = try c.decodeIfPresent(CheckpointStatus.self, forKey: .checkpointStatus) ?? .running
        state = try c.decodeIfPresent(ContractState.self, forKey: .state) ?? .draft
    }

    var isLocked: Bool { state == .locked }

    mutating func lock() { state = .locked }

    var hasLadder: Bool { !milestones.isEmpty }
    var isFinalMilestone: Bool { currentMilestone >= milestones.count - 1 }

    func currentMilestoneCriteria() -> [Criterion] {
        guard hasLadder, milestones.indices.contains(currentMilestone) else { return criteria }
        let ids = Set(milestones[currentMilestone].criterionIds)
        return criteria.filter { ids.contains($0.id) }
    }

    /// A locked copy whose criteria are the cumulative set across milestones 0...n, with the ladder
    /// stripped, ready to hand to GoalEvaluator.evaluate() unchanged (spec §6).
    func projectedContract(throughMilestone n: Int) -> GoalContract {
        let clamped = max(0, min(n, milestones.count - 1))
        let ids = Set(milestones.prefix(clamped + 1).flatMap { $0.criterionIds })
        var copy = self
        copy.criteria = criteria.filter { ids.contains($0.id) }
        copy.milestones = []
        copy.currentMilestone = 0
        copy.state = .locked
        return copy
    }

    /// True iff the ladder is a disjoint cover of `criteria`. An empty ladder is valid (no ladder).
    func ladderIsValidPartition() -> Bool {
        guard hasLadder else { return true }
        let assigned = milestones.flatMap { $0.criterionIds }
        let assignedSet = Set(assigned)
        if assigned.count != assignedSet.count { return false }   // a criterion in two milestones
        return assignedSet == Set(criteria.map { $0.id })          // covering, no stray ids
    }

    /// Repairs a hand-edited/legacy ladder: drops ids with no criterion, folds any unassigned
    /// criteria into an implicit final milestone, drops empty milestones, clamps currentMilestone.
    func normalizedLadder() -> GoalContract {
        var copy = self
        guard copy.hasLadder else { copy.currentMilestone = 0; return copy }
        let realIds = Set(copy.criteria.map { $0.id })
        for i in copy.milestones.indices {
            copy.milestones[i].criterionIds = copy.milestones[i].criterionIds.filter { realIds.contains($0) }
        }
        let assigned = Set(copy.milestones.flatMap { $0.criterionIds })
        let unassigned = copy.criteria.map { $0.id }.filter { !assigned.contains($0) }
        if !unassigned.isEmpty {
            copy.milestones.append(Milestone(title: "Remaining", criterionIds: unassigned))
        }
        copy.milestones.removeAll { $0.criterionIds.isEmpty }
        copy.currentMilestone = copy.milestones.isEmpty ? 0 : max(0, min(copy.currentMilestone, copy.milestones.count - 1))
        return copy
    }

    /// The ONLY sanctioned edit to criteria. On a locked contract a non-empty rationale is
    /// mandatory (edit rejected otherwise) and the change is recorded in the change-log.
    /// On a draft, edits are free and unlogged. Returns false iff the edit was rejected.
    @discardableResult
    mutating func applyCriteriaEdit(rationale: String, _ edit: (inout [Criterion]) -> Void) -> Bool {
        let blank = rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isLocked && blank { return false }
        edit(&criteria)
        if isLocked { changeLog.append(ContractChange(rationale: rationale)) }
        return true
    }

    /// The contract as injected into the goal loop's context (the "decision oracle").
    func oracleText() -> String {
        var s = "## Active Goal Contract (the oracle — consult before deciding)\n"
        s += "Objective: \(objective)\n\nDone when ALL of these hold:\n"
        for c in criteria {
            let tag: String
            switch c.kind {
            case .executable: tag = "[executable\(c.check.map { ": \($0)" } ?? "")]"
            case .qualitative: tag = "[qualitative]"
            case .humanJudged: tag = "[human-judged — you do not grade this]"
            }
            s += "  - \(tag) \(c.text)\n"
        }
        if !outOfScope.isEmpty { s += "\nOut of scope (do NOT do): \(outOfScope.joined(separator: "; "))\n" }
        if !stopBefore.isEmpty { s += "Stop and ask before: \(stopBefore.joined(separator: "; "))\n" }
        s += "\nChanging these criteria requires the `amend_goal_contract` tool with a rationale — never silently."
        if hasLadder {
            let idx = min(max(currentMilestone, 0), milestones.count - 1)
            let m = milestones[idx]
            s += "\n## Checkpoint ladder (\(idx + 1) of \(milestones.count))\n"
            s += "Current checkpoint: \(m.title). Its definition of done is exactly these criteria:\n"
            for c in currentMilestoneCriteria() { s += "  - \(c.text)\n" }
            let upcoming = milestones.dropFirst(idx + 1)
            if !upcoming.isEmpty {
                s += "Upcoming checkpoints: " + upcoming.map { $0.title }.joined(separator: " → ") + "\n"
            }
            s += isFinalMilestone
                ? "This is the FINAL checkpoint — when its criteria hold, call `goal_complete`.\n"
                : "When THIS checkpoint's criteria hold, call `reach_checkpoint` (not `goal_complete`) — the run pauses for the user to review before the next checkpoint.\n"
        }
        return s
    }

    /// The display state of the milestone at `index` relative to `currentMilestone`/`checkpointStatus`.
    /// Extracted from the panel so it is unit-testable without a view harness.
    func rungState(forMilestoneAt index: Int) -> MilestoneRungState {
        if index < currentMilestone { return .done }
        if index == currentMilestone {
            return checkpointStatus == .pausedForReview ? .pausedCurrent : .current
        }
        return .upcoming
    }
}

/// The rendered state of one checkpoint rung in the ladder view.
enum MilestoneRungState: Equatable {
    case done          // the loop advanced past this milestone
    case current       // the milestone being worked (running)
    case pausedCurrent // the current milestone, paused at its checkpoint for review
    case upcoming      // not yet reached
}

/// Pure milestone-authoring transforms used by the draft panel. Extracted so the ordering and
/// partition behaviour can be unit-tested without driving SwiftUI. All functions are value-in,
/// value-out and preserve first-appearance milestone order.
enum MilestoneLadderEditing {
    /// Move `criterionId` to the milestone titled `toTitle` (or unassign it when `toTitle` is nil).
    /// The criterion is first removed from every milestone, then appended to the target if it exists.
    static func assign(_ milestones: [Milestone], criterionId: UUID, toTitle: String?) -> [Milestone] {
        var m = milestones
        for i in m.indices { m[i].criterionIds.removeAll { $0 == criterionId } }
        guard let title = toTitle else { return m }
        if let idx = m.firstIndex(where: { $0.title == title }) { m[idx].criterionIds.append(criterionId) }
        return m
    }

    /// Create a milestone titled `title` (if none exists) and assign `criterionId` to it.
    static func addMilestone(_ milestones: [Milestone], title: String, assigning criterionId: UUID) -> [Milestone] {
        var m = milestones
        if !m.contains(where: { $0.title == title }) { m.append(Milestone(title: title, criterionIds: [])) }
        return assign(m, criterionId: criterionId, toTitle: title)
    }
}

extension GoalContract {
    /// The bounded unit contract for the CURRENT milestone (slice B4).
    ///
    /// Everything comes from the locked ladder: criteria are the milestone's own, and the goal's
    /// scope boundaries are inherited so a delegated unit cannot be used to launder a restriction
    /// the parent is under. No caller supplies criteria, so delegation cannot reshape the gate the
    /// work is about to be measured by. Returns nil when there is no ladder to delegate from.
    func currentMilestoneUnitContract() -> GoalContract? {
        guard hasLadder, milestones.indices.contains(currentMilestone) else { return nil }
        let milestone = milestones[currentMilestone]
        let position = "checkpoint \(currentMilestone + 1)/\(milestones.count)"
        var unit = GoalContract(objective: "\(objective) — \(position): \(milestone.title)",
                                criteria: currentMilestoneCriteria(),
                                outOfScope: outOfScope,
                                stopBefore: stopBefore)
        // Flat and locked: a subagent cannot call `reach_checkpoint` (main-principal only), so a
        // ladder here would loop it to its iteration cap.
        unit.milestones = []
        unit.lock()
        return unit
    }
}
