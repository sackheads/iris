import Foundation

enum GoalEvaluationParsing {
    /// Reconciles the grader's submitted verdicts against the FULL criteria list (spec §4.3):
    /// a `humanJudged` criterion is ALWAYS `humanPending` (only the user may decide it); otherwise
    /// use a supplied verdict if present, else `cannotVerify`. So every criterion always carries a
    /// verdict and humanJudged never collapses to cannot_verify. `method` derives from the kind.
    static func verdicts(from args: [String: JSONValue],
                         criteria: [Criterion],
                         judgements: [UUID: Bool] = [:]) -> [CriterionVerdict] {
        // Index submitted verdicts by criterion_id.
        var submitted: [UUID: (value: CriterionVerdictValue, evidence: String)] = [:]
        if case .array(let items)? = args["evaluations"] {
            for item in items {
                guard case .object(let obj) = item,
                      let idString = obj["criterion_id"]?.stringValue,
                      let id = UUID(uuidString: idString) else { continue }
                let value = CriterionVerdictValue(rawValue: obj["verdict"]?.stringValue ?? "") ?? .cannotVerify
                // A grader must never mark a criterion humanPending; that is system-assigned.
                let safeValue: CriterionVerdictValue = (value == .humanPending) ? .cannotVerify : value
                submitted[id] = (safeValue, obj["evidence"]?.stringValue ?? "")
            }
        }

        return criteria.map { c in
            // A `humanJudged` criterion is the user's to decide, so the grader's answer is not
            // merely unused — it must not be read at all. Taking it would complete the goal
            // `.passed` with nobody having judged (the exact hole D2 closes), and it would then be
            // stamped `method == .human`, announcing a grader's verdict as "your judgement". The
            // prompt forbids grading one twice; this makes it structural, the same way a submitted
            // `human_pending` is downgraded above (spec §4.4, §6).
            //
            // D3: a decision the user already made IS read, from the contract's durable
            // `judgements`. Without that, every checkpoint re-grade would reset the criterion to
            // `human_pending` and ask again for a verdict already given.
            guard c.kind != .humanJudged else {
                let recorded = judgements[c.id]
                let value: CriterionVerdictValue = recorded == nil
                    ? .humanPending
                    : (recorded == true ? .met : .notMet)
                return CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                                        verdict: value, evidence: "", method: .human)
            }
            let method: VerdictMethod = (c.kind == .executable) ? .check : .judge
            guard let s = submitted[c.id] else {
                return CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                                        verdict: .cannotVerify, evidence: "", method: method)
            }
            return CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                                    verdict: s.value, evidence: s.evidence, method: method)
        }
    }
}
