import Foundation

/// The learnings note a completed goal leaves in memory (#883, the first step of roadmap E). It says
/// which criteria were not met at first and were met by the end, and nothing else: it is built from
/// the contract and the verdict values only. A verdict's `evidence` is text a model wrote after
/// reading files and running commands, which is where a planted instruction would sit, so it never
/// reaches the note, not even capped. The trade-off is that the note names WHICH criteria flipped,
/// not HOW they were fixed.
enum GoalLearnings {
    static let category = "goal-learnings"
    /// Criteria named in one note; the rest are counted.
    static let namedCriteria = 5
    static let objectiveCap = 120
    static let criterionCap = 120

    /// The note, or nil when there is nothing to learn: no criterion was ever graded not met, or none of
    /// those ended met. A waived criterion is not "met at the end", and a goal that did not pass its gate
    /// (`outcome` other than `.passed`) leaves no note. No date and no id is in the text, so writing it
    /// twice stores one fact (the fact store returns the existing one for identical content).
    static func note(contract: GoalContract, final: GoalEvaluation?, outcome: GateOutcome) -> String? {
        guard outcome == .passed, !contract.everNotMet.isEmpty else { return nil }
        let metAtEnd = Set(final.map { $0.status == .graded ? $0.criteria.filter { $0.verdict == .met }.map(\.criterionId) : [] } ?? [])
        let flipped = contract.criteria.filter { criterion in
            contract.everNotMet.contains(criterion.id) && contract.waivers[criterion.id] == nil
                && (metAtEnd.contains(criterion.id) || contract.judgements[criterion.id] == true)
        }
        guard !flipped.isEmpty else { return nil }
        let shown = flipped.prefix(namedCriteria).map { "\"\(IrisEngine.flattenCardField($0.text, cap: criterionCap))\"" }
        let more = flipped.count > shown.count ? "; and \(flipped.count - shown.count) more" : ""
        let attempts = contract.gateAttempts > 0 ? " The completion gate refused \(contract.gateAttempts) time(s) first." : ""
        return "Goal learnings: in the goal \"\(IrisEngine.flattenCardField(contract.objective, cap: objectiveCap))\", "
            + "these criteria were not met at first and were met by the end: \(shown.joined(separator: "; "))\(more).\(attempts)"
    }
}
