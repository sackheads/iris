import Foundation

/// The grader's verdict for one criterion. `met`/`notMet`/`cannotVerify` are gradable outcomes;
/// `humanPending` marks a `humanJudged` criterion the grader must not auto-grade (spec §4.4).
enum CriterionVerdictValue: String, Codable, Sendable, Equatable {
    case met
    case notMet = "not_met"
    case cannotVerify = "cannot_verify"
    case humanPending = "human_pending"
}

/// How a verdict was reached: a run check (executable), an LLM judgement (qualitative), or
/// deferred to a human (humanJudged).
enum VerdictMethod: String, Codable, Sendable, Equatable {
    case check
    case judge
    case human
}

struct CriterionVerdict: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { criterionId }
    var criterionId: UUID
    var criterionText: String
    var kind: CriterionKind
    var verdict: CriterionVerdictValue
    var evidence: String
    var method: VerdictMethod
}

enum EvaluationStatus: String, Codable, Sendable, Equatable {
    case verifying   // grader running; verdicts not yet in
    case graded      // grader finished normally
    case failed      // grader errored or hit its iteration cap
}

/// How a goal got past the gate (slice D1). nil on an evaluation recorded before D1, and on a
/// checkpoint grade, which is not gated.
enum GateOutcome: String, Codable, Sendable, Equatable {
    case passed                 // nothing blocking
    case ungatedAtCap           // the retry cap was reached with criteria still not_met
    case ungatedGraderFailed    // the grader never delivered a verdict; its values are placeholders
}

struct GoalEvaluation: Codable, Equatable, Sendable {
    var id = UUID()
    var status: EvaluationStatus
    var criteria: [CriterionVerdict]
    var startedAt: Date
    var completedAt: Date?
    var gateOutcome: GateOutcome?
    /// Snapshot of the contract's waivers. Copied here because `clearGoal` nils `goalContract` on
    /// completion — anything living only on the contract disappears exactly when the report needs it.
    var waivers: [UUID: String] = [:]

    init(id: UUID = UUID(), status: EvaluationStatus, criteria: [CriterionVerdict], startedAt: Date,
         completedAt: Date? = nil, gateOutcome: GateOutcome? = nil, waivers: [UUID: String] = [:]) {
        self.id = id; self.status = status; self.criteria = criteria; self.startedAt = startedAt
        self.completedAt = completedAt; self.gateOutcome = gateOutcome; self.waivers = waivers
    }

    /// Custom decoder so D1's fields are `decodeIfPresent`-defaulted: a synthesized `Decodable`
    /// throws `keyNotFound` on an evaluation persisted before D1, which fails the WHOLE
    /// `[Conversation]` decode and drops every conversation. Older fields are decoded leniently
    /// too, for the same forward-compat reason.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        status = try c.decode(EvaluationStatus.self, forKey: .status)
        criteria = try c.decodeIfPresent([CriterionVerdict].self, forKey: .criteria) ?? []
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        gateOutcome = try c.decodeIfPresent(GateOutcome.self, forKey: .gateOutcome)
        waivers = try c.decodeIfPresent([UUID: String].self, forKey: .waivers) ?? [:]
    }
}
