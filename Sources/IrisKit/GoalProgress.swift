import Foundation
import SwiftUI

/// The goal progress panel's rows (#882, roadmap F), read-only: one row per criterion with its
/// latest verdict and evidence, and one per checkpoint from `Conversation.checkpointHistory`.
/// Everything is derived from what the conversation already persists (the contract, its latest
/// evaluation, its checkpoint history); nothing here is stored or written, so there is no new
/// field on any `Codable` type (Invariant 1).
struct GoalProgress: Equatable, Sendable {
    struct CriterionRow: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        let kind: CriterionKind
        /// 1-based checkpoint this criterion belongs to, nil without a ladder.
        let checkpoint: Int?
        /// The newest gradable verdict for this criterion, nil if none has been graded yet.
        let verdict: CriterionVerdictValue?
        let evidence: String
        /// Why the person waived it, or whether they judged it, when they did.
        let waivedBecause: String?
        let humanDecision: Bool?
    }

    struct CheckpointRow: Identifiable, Equatable, Sendable {
        let id: UUID
        /// 1-based, as the ladder numbers its rungs.
        let number: Int
        let title: String
        let resolution: CheckpointOutcome.Resolution
        let date: Date
        /// Criteria met out of those graded in that grade; nil when nothing was graded.
        let met: Int?
        let graded: Int?
    }

    /// nil when the conversation has no goal (finished or never set).
    let objective: String?
    let criteria: [CriterionRow]
    let checkpoints: [CheckpointRow]
    /// Verdicts on file for criteria the goal no longer has (it was amended): counted, not shown.
    let supersededVerdicts: Int
    /// True when a goal is running or draft; false for the record of a goal that has ended.
    let isLive: Bool

    var isEmpty: Bool { objective == nil && criteria.isEmpty && checkpoints.isEmpty }

    init(_ conversation: Conversation) {
        let contract = conversation.goalContract
        isLive = contract != nil
        objective = contract?.objective

        // The history outlives `clearGoal`, so it holds several goals' records: show this goal's
        // (by `contractId`), or, with no goal, the newest goal's. A record stored before the id
        // existed belongs to nobody in particular and is shown only when no id can be matched.
        let history = conversation.checkpointHistory
        let scopeId = contract?.id ?? history.last(where: { $0.contractId != nil })?.contractId
        let mine = history.filter { scopeId != nil ? $0.contractId == scopeId : $0.contractId == nil }
        checkpoints = mine.map { outcome in
            let graded = outcome.evaluation.map { $0.criteria.filter { $0.verdict != .humanPending }.count }
            let met = outcome.evaluation.map { $0.criteria.filter { $0.verdict == .met }.count }
            return CheckpointRow(id: outcome.id, number: outcome.milestoneIndex + 1, title: outcome.milestoneTitle,
                                 resolution: outcome.resolution, date: outcome.date, met: met, graded: graded)
        }

        // Newest grade first: the live evaluation (if it finished) and each checkpoint's grade.
        // A checkpoint's grade is cumulative, so a later one overrides an earlier for a criterion.
        var grades: [(date: Date, verdicts: [CriterionVerdict])] = mine.compactMap { outcome in
            outcome.evaluation.map { (outcome.date, $0.criteria) }
        }
        if let live = conversation.lastGoalEvaluation, live.status == .graded {
            grades.append((live.completedAt ?? live.startedAt, live.criteria))
        }
        grades.sort { $0.date > $1.date }
        func latest(for id: UUID) -> CriterionVerdict? {
            for grade in grades { if let v = grade.verdicts.first(where: { $0.criterionId == id }) { return v } }
            return nil
        }

        if let contract {
            var onFile = Set<UUID>()
            criteria = contract.criteria.map { criterion in
                let verdict = latest(for: criterion.id)
                if verdict != nil { onFile.insert(criterion.id) }
                let checkpoint = contract.milestones.firstIndex { $0.criterionIds.contains(criterion.id) }.map { $0 + 1 }
                return CriterionRow(id: criterion.id, text: criterion.text, kind: criterion.kind, checkpoint: checkpoint,
                                    verdict: verdict?.verdict, evidence: verdict?.evidence ?? "",
                                    waivedBecause: contract.waivers[criterion.id], humanDecision: contract.judgements[criterion.id])
            }
            let everSeen = Set(grades.flatMap { $0.verdicts.map(\.criterionId) })
            supersededVerdicts = everSeen.subtracting(Set(contract.criteria.map(\.id))).count
        } else if let ended = conversation.lastGoalEvaluation, ended.status == .graded {
            // No goal now: the last grade is the record of how the ended one finished.
            criteria = ended.criteria.map {
                CriterionRow(id: $0.criterionId, text: $0.criterionText, kind: $0.kind, checkpoint: nil, verdict: $0.verdict,
                             evidence: $0.evidence, waivedBecause: ended.waivers[$0.criterionId], humanDecision: nil)
            }
            supersededVerdicts = 0
        } else {
            criteria = []
            supersededVerdicts = 0
        }
    }
}

/// The rows, apart from the scroll view that holds them (so they can be drawn without it).
struct GoalProgressBody: View {
    let progress: GoalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let objective = progress.objective {
                Text(objective).font(.body)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05)).clipShape(.rect(cornerRadius: 6))
            }
            if !progress.criteria.isEmpty { criteria(progress) }
            if !progress.checkpoints.isEmpty { checkpoints(progress.checkpoints) }
        }
        .padding(12)
    }

    private func criteria(_ progress: GoalProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(progress.isLive ? "Criteria" : "Criteria (last grade)", systemImage: "list.bullet.clipboard")
                .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(progress.criteria) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: GoalProgressView.symbol(for: row)).foregroundStyle(GoalProgressView.color(for: row)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.text).font(.body)
                        Text(GoalProgressView.statusLine(for: row)).font(.caption).foregroundStyle(.secondary)
                        if !row.evidence.isEmpty {
                            Text(row.evidence).font(.caption).foregroundStyle(.tertiary).lineLimit(4)
                        }
                    }
                }
            }
            if progress.supersededVerdicts > 0 {
                Text("\(progress.supersededVerdicts) earlier verdict(s) were for criteria the goal no longer has.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func checkpoints(_ rows: [GoalProgress.CheckpointRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Checkpoints", systemImage: "flag.checkered").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: GoalProgressView.symbol(for: row.resolution)).foregroundStyle(GoalProgressView.color(for: row.resolution)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.number). \(row.title)").font(.body)
                        Text(GoalProgressView.line(for: row)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

}

/// The panel itself: shown in a popover from the toolbar, never in the composer's stack (Invariant 8),
/// and height-bounded anyway.
struct GoalProgressView: View {
    var state: AppState
    let conversationId: UUID

    var body: some View {
        let progress = state.conversations.first(where: { $0.id == conversationId }).map(GoalProgress.init)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Goal progress", systemImage: "target").font(.headline)
                Spacer()
                if let progress, !progress.isLive, !progress.isEmpty {
                    Text("ended").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            if let progress, !progress.isEmpty {
                ScrollView {
                    GoalProgressBody(progress: progress)
                }
                .frame(maxHeight: 380)
                .scrollIndicators(.visible)
            } else {
                Text("No goal in this conversation. Start one with /goal.")
                    .font(.callout).foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(width: 440)
    }

    // MARK: Labels (pure, tested)

    static func statusLine(for row: GoalProgress.CriterionRow) -> String {
        var parts: [String] = []
        if let n = row.checkpoint { parts.append("checkpoint \(n)") }
        if let why = row.waivedBecause { parts.append("waived: \(why)") }
        else if let decision = row.humanDecision { parts.append(decision ? "you judged it met" : "you judged it not met") }
        else {
            switch row.verdict {
            case .met?: parts.append("met")
            case .notMet?: parts.append("not met")
            case .cannotVerify?: parts.append("could not be verified")
            case .humanPending?: parts.append("waiting for your judgement")
            case nil: parts.append("not graded yet")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func line(for row: GoalProgress.CheckpointRow) -> String {
        let how: String
        switch row.resolution {
        case .autoAdvanced: how = "advanced on its own"
        case .humanApproved: how = "you approved it"
        case .humanSentBack: how = "you sent it back"
        }
        let grade = (row.met != nil && row.graded != nil) ? "\(row.met!) of \(row.graded!) met" : "not graded"
        return "\(how) · \(grade) · \(row.date.formatted(date: .abbreviated, time: .shortened))"
    }

    fileprivate static func symbol(for row: GoalProgress.CriterionRow) -> String {
        if row.waivedBecause != nil { return "minus.circle" }
        if let decision = row.humanDecision { return decision ? "checkmark.circle.fill" : "xmark.circle.fill" }
        switch row.verdict {
        case .met?: return "checkmark.circle.fill"
        case .notMet?: return "xmark.circle.fill"
        case .cannotVerify?: return "questionmark.circle"
        case .humanPending?: return "person.crop.circle.badge.questionmark"
        case nil: return "circle"
        }
    }

    fileprivate static func color(for row: GoalProgress.CriterionRow) -> Color {
        if row.waivedBecause != nil { return .secondary }
        if let decision = row.humanDecision { return decision ? .green : .red }
        switch row.verdict {
        case .met?: return .green
        case .notMet?: return .red
        case .cannotVerify?, .humanPending?: return .orange
        case nil: return Color.primary.opacity(0.25)
        }
    }

    fileprivate static func symbol(for r: CheckpointOutcome.Resolution) -> String {
        switch r {
        case .autoAdvanced: return "forward.circle.fill"
        case .humanApproved: return "checkmark.circle.fill"
        case .humanSentBack: return "arrow.uturn.backward.circle.fill"
        }
    }

    fileprivate static func color(for r: CheckpointOutcome.Resolution) -> Color {
        switch r {
        case .autoAdvanced: return Color.irisIndigo
        case .humanApproved: return .green
        case .humanSentBack: return .orange
        }
    }
}
