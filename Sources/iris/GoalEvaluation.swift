import Foundation
import SwiftUI

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

    init(criterionId: UUID, criterionText: String, kind: CriterionKind, verdict: CriterionVerdictValue,
         evidence: String, method: VerdictMethod) {
        self.criterionId = criterionId; self.criterionText = criterionText; self.kind = kind
        self.verdict = verdict; self.evidence = evidence; self.method = method
    }

    /// Lenient decoder (invariant 1, #204 round 2): a `keyNotFound` here throws out of
    /// `GoalEvaluation.init(from:)`'s `try c.decodeIfPresent([CriterionVerdict].self, ...)`, which
    /// swallows a MISSING `criteria` key but not a decode error inside an element already present —
    /// so a required field added to this type later would still fail the whole `GoalEvaluation`,
    /// and from there `CheckpointOutcome`/`SubagentResult`/the conversation that owns them.
    /// `criterionId` stays required: `AppState.waiveCriterion`/`recordHumanJudgement` and
    /// `GoalContractPanel` match verdicts back to criteria by this value, and minting a fresh one
    /// would misattribute or orphan the verdict rather than merely blank its text. `verdict`
    /// defaults to `.cannotVerify` (the closest thing this enum has to "unspecified" — asserting
    /// `.met`/`.notMet` on missing data would fabricate a result) and `method` to `.judge` (neither
    /// a hard check nor a human call happened, so "the grader's best guess" is the least wrong
    /// label for data that arrived without one).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        criterionId = try c.decode(UUID.self, forKey: .criterionId)
        criterionText = try c.decodeIfPresent(String.self, forKey: .criterionText) ?? ""
        kind = try c.decodeIfPresent(CriterionKind.self, forKey: .kind) ?? .qualitative
        verdict = try c.decodeIfPresent(CriterionVerdictValue.self, forKey: .verdict) ?? .cannotVerify
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        method = try c.decodeIfPresent(VerdictMethod.self, forKey: .method) ?? .judge
    }
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

/// Everything the completion report's graded column renders for one verdict: glyph, spoken label,
/// visible text and tint, derived TOGETHER from `(method, verdict)`.
///
/// One derivation on purpose. These four were three separate switches, and they drifted: the glyph
/// and tint learned that a human accept is not grader-verified evidence while the visible text —
/// the most-read half of the pair — kept saying a flat green "met" under a column headed
/// "SELF-REPORT vs GRADER" (spec §6). Anything keyed on provenance belongs here, so the next
/// consumer cannot be fixed in one place and forgotten in another.
struct GraderColumnPresentation: Equatable {
    let symbolName: String
    /// What VoiceOver announces for the glyph.
    let accessibilityLabel: String
    /// The visible text beside the glyph.
    let text: String
    let tint: Color
    /// True when the user gave this verdict rather than the grader — the row must never present it
    /// as verified evidence.
    let isHumanJudgement: Bool
}

extension CriterionVerdict {
    /// The graded column's full rendering for this verdict. Kept out of the view so provenance can
    /// be tested without a SwiftUI harness.
    ///
    /// A human's verdict deliberately does NOT reuse the grader's "verified" green: that would read
    /// as machine-verified evidence for a claim the user asserted, not the grader. `.blue` still
    /// communicates "met" without borrowing the grader's colour, and stays legible in both light
    /// and dark mode.
    var graderColumnPresentation: GraderColumnPresentation {
        switch (method, verdict) {
        case (.human, .met):
            return .init(symbolName: "person.fill.checkmark", accessibilityLabel: "Your judgement: met",
                         text: "met — your judgement", tint: .blue, isHumanJudgement: true)
        case (.human, .notMet):
            return .init(symbolName: "person.fill.xmark", accessibilityLabel: "Your judgement: not met",
                         text: "not met — your judgement", tint: .orange, isHumanJudgement: true)
        case (_, .met):
            return .init(symbolName: "checkmark.circle.fill", accessibilityLabel: "Grader: met",
                         text: "met", tint: .green, isHumanJudgement: false)
        case (_, .notMet):
            return .init(symbolName: "xmark.octagon.fill", accessibilityLabel: "Grader: not met",
                         text: "not met", tint: .red, isHumanJudgement: false)
        case (_, .cannotVerify):
            return .init(symbolName: "questionmark.circle", accessibilityLabel: "Grader: cannot verify",
                         text: "cannot verify", tint: .secondary, isHumanJudgement: false)
        case (_, .humanPending):
            // Still the user's to decide, so this is not yet a judgement of theirs — the
            // Accept/Reject buttons speak for it.
            return .init(symbolName: "person.crop.circle.badge.questionmark",
                         accessibilityLabel: "Awaiting human judgment",
                         text: "your call", tint: .secondary, isHumanJudgement: false)
        }
    }
}

extension GateOutcome {
    /// One line for the completion chip, or nil when there is nothing to warn about. Kept out of
    /// the view so it can be tested without a SwiftUI harness.
    func bannerText(unmetCount: Int) -> String? {
        switch self {
        case .passed:
            return nil
        case .ungatedAtCap:
            let plural = unmetCount == 1 ? "criterion" : "criteria"
            return "Completed without passing the gate — \(unmetCount) \(plural) still not met after the retry limit."
        case .ungatedGraderFailed:
            return "Completed ungated — the grader did not finish, so nothing was verified."
        }
    }
}
