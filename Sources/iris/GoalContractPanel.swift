import SwiftUI

/// Displays the draft `GoalContract` proposed by the model, lets the user edit it,
/// and then either approves (locking the contract and starting the goal loop) or discards it.
struct GoalContractPanel: View {
    var state: AppState
    let conversation: Conversation

    // Local editable copies — edits stay here until the user approves.
    @State private var objective: String
    @State private var criteria: [Criterion]
    @State private var outOfScope: [String]
    @State private var stopBefore: [String]
    @State private var assumptions: [String]
    /// Milestone ladder being authored. Empty means no checkpoints (single-terminal behavior).
    @State private var milestones: [Milestone]
    /// Where the goal will run (#68). Empty means "let Iris pick a fresh workspace".
    @State private var workspace: String

    init(state: AppState, conversation: Conversation) {
        self.state = state
        self.conversation = conversation
        let contract = conversation.goalContract ?? GoalContract(
            objective: "",
            criteria: []
        )
        // Seeding @State from the conversation's draft contract is safe here because:
        // (a) GoalContractPanel only appears while goalContract.state == .draft, and
        // (b) the state machine never transitions a contract back to .draft once it leaves
        //     that phase — so this init runs exactly once per panel lifetime and there is
        //     no risk of a re-render clobbering in-progress edits.
        _objective = State(initialValue: contract.objective)
        _criteria = State(initialValue: contract.criteria)
        _workspace = State(initialValue: contract.workspace ?? "")
        _outOfScope = State(initialValue: contract.outOfScope)
        _stopBefore = State(initialValue: contract.stopBefore)
        _assumptions = State(initialValue: contract.assumptions)
        _milestones = State(initialValue: contract.milestones)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    objectiveSection
                    criteriaSection
                    if !outOfScope.isEmpty || !stopBefore.isEmpty || !assumptions.isEmpty {
                        listsSection
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 320)
            Divider()
            actionBar
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.irisIndigo)
                .font(.caption)
            Text("GOAL CONTRACT DRAFT")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Review and edit before approving")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var objectiveSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Objective", systemImage: "target")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TextField("Objective", text: $objective, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(2...4)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Where the goal will run (#68). Shown here so the choice passes through the approval
            // gate that already exists, rather than surprising the user after the fact.
            Label("Workspace", systemImage: "folder")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            TextField("A fresh workspace will be created", text: $workspace)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(resolvedWorkspaceDisplay)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.head)
            if let warning = resolvedWorkspaceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var criteriaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Done when…", systemImage: "list.bullet.clipboard")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach($criteria) { $criterion in
                CriterionRow(
                    criterion: $criterion,
                    milestones: milestones,
                    selectedMilestoneTitle: milestoneTitle(for: criterion.id),
                    onMilestoneChange: { newTitle in
                        assignMilestone(criterionId: criterion.id, toTitle: newTitle)
                    },
                    onAddMilestone: { title in
                        milestones = MilestoneLadderEditing.addMilestone(milestones, title: title, assigning: criterion.id)
                    }
                )
            }
            if !milestones.isEmpty && !draftedContract.ladderIsValidPartition() {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Some criteria are unassigned or assigned to multiple milestones.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(6)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// The contract as currently authored in the draft panel (not yet locked).
    private var draftedContract: GoalContract {
        GoalContract(
            objective: objective,
            criteria: criteria,
            outOfScope: outOfScope,
            stopBefore: stopBefore,
            assumptions: assumptions,
            milestones: milestones
        )
    }

    /// Which milestone title (if any) a criterion is currently assigned to.
    private func milestoneTitle(for criterionId: UUID) -> String? {
        milestones.first(where: { $0.criterionIds.contains(criterionId) })?.title
    }

    /// Rebuild the milestones array so `criterionId` belongs to the milestone with `toTitle`.
    /// Passing `nil` removes the criterion from whichever milestone currently holds it.
    /// First-appearance order of milestones is preserved; empty milestones are retained until
    /// the user explicitly removes them so accidental deselection doesn't destroy the ordering.
    private func assignMilestone(criterionId: UUID, toTitle: String?) {
        milestones = MilestoneLadderEditing.assign(milestones, criterionId: criterionId, toTitle: toTitle)
    }

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !outOfScope.isEmpty {
                StringListSection(
                    label: "Out of scope",
                    systemImage: "nosign",
                    items: $outOfScope
                )
            }
            if !stopBefore.isEmpty {
                StringListSection(
                    label: "Stop and ask before",
                    systemImage: "exclamationmark.triangle",
                    items: $stopBefore
                )
            }
            if !assumptions.isEmpty {
                StringListSection(
                    label: "Assumptions",
                    systemImage: "questionmark.circle",
                    items: $assumptions
                )
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Discard", role: .destructive) {
                state.clearGoal(for: conversation.id)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()

            let ladderOk = milestones.isEmpty || draftedContract.ladderIsValidPartition()
            Button("Approve & Lock") {
                approveAndLock()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .font(.subheadline.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(ladderOk ? Color.irisIndigo : Color.irisIndigo.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(!ladderOk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    /// The workspace this draft would run in. Calls the PURE resolver, so this is safe to
    /// evaluate on every keystroke: it stats paths, it never creates one (spec §4.1).
    private var resolvedWorkspacePath: String {
        let fm = FileManager.default
        switch GoalWorkspace.resolve(
            proposed: workspace.isEmpty ? nil : workspace,
            objective: objective,
            existingBinding: conversation.workspacePath,
            workspacesRoot: IrisPaths.default.root.appendingPathComponent("workspaces").path,
            directoryExists: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }) {
        case .existing(let p), .created(let p), .keptExisting(let p): return p
        }
    }

    private var resolvedWorkspaceDisplay: String {
        conversation.workspacePath != nil
            ? "Already bound to this conversation: \(resolvedWorkspacePath)"
            : "Will run in: \(resolvedWorkspacePath)"
    }

    private var resolvedWorkspaceWarning: String? {
        GoalWorkspace.warningText(for: resolvedWorkspacePath,
                                  homeDirectory: NSHomeDirectory(),
                                  processCwd: FileManager.default.currentDirectoryPath)
    }

    private func approveAndLock() {
        // Normalize: a criterion's `check` is only valid for `.executable` kind.
        // If the user switched the picker away from `.executable` after typing a command,
        // the check string is still in local state — strip it here so the locked contract
        // never carries a check value on a non-executable criterion.
        let normalizedCriteria = criteria.map { criterion in
            Criterion(
                id: criterion.id,
                text: criterion.text,
                kind: criterion.kind,
                check: criterion.kind == .executable ? criterion.check : nil
            )
        }
        let edited = GoalContract(
            objective: objective,
            criteria: normalizedCriteria,
            outOfScope: outOfScope,
            stopBefore: stopBefore,
            assumptions: assumptions,
            milestones: milestones,
            workspace: workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : workspace
        )
        // Bind BEFORE locking so the kickoff turn already runs in the right directory (#68).
        state.bindGoalWorkspace(for: conversation.id, contract: edited)
        state.setGoalContract(for: conversation.id, edited)
        state.sendGoalKickoff(for: conversation.id)
    }
}

// MARK: - Locked-run views

/// Compact read-only chip shown while a goal contract is locked and running.
struct LockedContractChip: View {
    var state: AppState
    let conversation: Conversation

    /// Text the human types before pressing "Send back".
    @State private var sendBackNote: String = ""

    var body: some View {
        if let contract = conversation.goalContract {
            VStack(alignment: .leading, spacing: 0) {
                chipHeader(contract: contract)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        lockedObjective(contract.objective)
                        // Where artifacts are landing, visible mid-run (#68).
                        if let ws = conversation.workspacePath {
                            Label(ws, systemImage: "folder")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if contract.hasLadder {
                            // The ladder nests each checkpoint's criteria, so it replaces the flat list.
                            ladderSection(contract: contract)
                        } else {
                            lockedCriteria(contract.criteria)
                        }
                        if !contract.changeLog.isEmpty {
                            changeLogSection(contract.changeLog)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 340)
                .scrollIndicators(.visible)
                // The pause evidence + resume controls render as a SEPARATE top-level chip
                // (CheckpointPauseChip in ChatView) — a nested section here did not reliably
                // re-render when the contract flipped to pausedForReview.
            }
            .background(.thinMaterial)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    private func chipHeader(contract: GoalContract) -> some View {
        HStack {
            Image(systemName: contract.checkpointStatus == .pausedForReview ? "pause.circle.fill" : "lock.fill")
                .foregroundStyle(contract.checkpointStatus == .pausedForReview ? Color.orange : Color.irisIndigo)
                .font(.caption)
                .accessibilityHidden(true)
            Text(contract.checkpointStatus == .pausedForReview ? "GOAL CONTRACT · PAUSED FOR REVIEW" : "GOAL CONTRACT · LOCKED")
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
            Spacer()
            Text(contract.checkpointStatus == .pausedForReview ? "Awaiting your decision" : "Read-only")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Vertical ladder: each checkpoint rung with ITS criteria nested beneath it, so the ladder
    /// reads as structure rather than duplicating the flat criteria list (which is why one
    /// criterion per checkpoint used to look redundant). When a ladder is present this replaces
    /// the separate "Done when…" list entirely.
    private func ladderSection(contract: GoalContract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Checkpoints", systemImage: "flag.checkered")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(Array(contract.milestones.enumerated()), id: \.element.id) { index, milestone in
                VStack(alignment: .leading, spacing: 4) {
                    MilestoneRungRow(
                        title: milestone.title,
                        rungState: contract.rungState(forMilestoneAt: index)
                    )
                    let ids = Set(milestone.criterionIds)
                    ForEach(contract.criteria.filter { ids.contains($0.id) }) { criterion in
                        LockedCriterionRow(criterion: criterion)
                            .padding(.leading, 22)
                    }
                }
            }
        }
    }

    /// The pause-review section: UNVERIFIED self-report + trusted verdict + action buttons.

    private func lockedObjective(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Objective", systemImage: "target")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(.rect(cornerRadius: 6))
        }
    }

    private func lockedCriteria(_ criteria: [Criterion]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Done when…", systemImage: "list.bullet.clipboard")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(criteria) { criterion in
                LockedCriterionRow(criterion: criterion)
            }
        }
    }

    private func changeLogSection(_ entries: [ContractChange]) -> some View {
        let identified = entries.map { IdentifiedChange(change: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            Label("Amendments", systemImage: "clock.arrow.2.circlepath")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(identified) { identified in
                VStack(alignment: .leading, spacing: 2) {
                    Text(identified.change.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(identified.change.rationale)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.irisIndigo.opacity(0.06))
                .clipShape(.rect(cornerRadius: 6))
            }
        }
    }
}

/// The checkpoint pause panel, rendered as a top-level chip by ChatView (like CompletionReportChip)
/// rather than nested in LockedContractChip — a nested section did not reliably re-render when the
/// contract flipped to `pausedForReview`. Shows the UNVERIFIED self-report, the trusted grader
/// verdict, and the resume controls (Send back / Approve & continue).
struct CheckpointPauseChip: View {
    var state: AppState
    let conversation: Conversation
    @State private var sendBackNote: String = ""

    var body: some View {
        if let contract = conversation.goalContract, contract.checkpointStatus == .pausedForReview {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text("CHECKPOINT \(contract.currentMilestone + 1) OF \(contract.milestones.count) · PAUSED FOR REVIEW")
                        .font(.caption2).bold()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Awaiting your decision")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // UNVERIFIED self-report
                if let report = conversation.lastGoalCompletionReport {
                    CompletionReportSection(report: report, evaluation: nil)
                }
                // Trusted grader verdict, reusing DriftCriterionRow
                if let evaluation = conversation.lastGoalEvaluation {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("GRADER VERDICT", systemImage: "checkmark.seal")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(evaluation.criteria) { verdict in
                            DriftCriterionRow(
                                verdict: verdict,
                                selfReportStatus: "",
                                evaluationStatus: evaluation.status,
                                reportPresent: conversation.lastGoalCompletionReport != nil
                            )
                        }
                    }
                }
                // Steering note + resume controls
                TextField("Optional feedback for the agent…", text: $sendBackNote, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...3)
                    .padding(6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 10) {
                    Button("Send back") {
                        let note = sendBackNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        state.holdCheckpoint(for: conversation.id, feedback: note.isEmpty ? nil : note)
                        sendBackNote = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Spacer()

                    Button("Approve & continue") {
                        state.advanceCheckpoint(for: conversation.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.irisIndigo)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
            .background(.thinMaterial)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }
}

private struct LockedCriterionRow: View {
    let criterion: Criterion

    private var kindLabel: String {
        switch criterion.kind {
        case .executable: return "executable"
        case .qualitative: return "qualitative"
        case .humanJudged: return "human-judged"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(kindLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.irisIndigo)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.irisIndigo.opacity(0.10))
                    .clipShape(.rect(cornerRadius: 3))
                Text(criterion.text)
                    .font(.body)
            }
            if criterion.kind == .executable, let check = criterion.check {
                Text(check)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(.rect(cornerRadius: 4))
                    .padding(.leading, 2)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 6))
    }
}

/// Pairs a stable UUID with a `ContractChange` so `ForEach` has a fixed identity
/// even if two amendments share the same timestamp.
private struct IdentifiedChange: Identifiable {
    let id = UUID()
    let change: ContractChange
}

/// Model for a parsed completion-report line, giving ForEach a stable identity.
struct CompletionReportItem: Identifiable {
    let id: String   // criterion text — unique within a single report
    let criterion: String
    let status: String
    let evidence: String
}

/// Pairs a contract criterion with the agent's self-report entry for it.
///
/// The self-report carries criterion TEXT, not ids (unlike `submit_evaluation`, which the grader
/// answers by id), and the model rarely echoes the text verbatim — so this has to be a text match.
/// The rule: exact wins; otherwise a partial match is used ONLY when exactly one candidate matches.
/// An ambiguous match reports nothing. Attributing one criterion's status to another is worse than
/// showing "not reported" in a panel whose whole job is separating claims from verified facts (#54).
enum CompletionSelfReportMatching {
    static func status(for criterionText: String, in items: [CompletionReportItem]) -> String {
        let needle = criterionText.lowercased().trimmingCharacters(in: .whitespaces)
        func normalized(_ item: CompletionReportItem) -> String {
            item.criterion.lowercased().trimmingCharacters(in: .whitespaces)
        }
        if let exact = items.first(where: { normalized($0) == needle }) {
            return exact.status
        }
        let partial = items.filter { needle.contains(normalized($0)) || normalized($0).contains(needle) }
        return partial.count == 1 ? partial[0].status : ""
    }
}

/// Renders the model's per-criterion completion self-report as a standalone chip, shown
/// after a goal finishes (the contract itself is cleared on completion, so this must not
/// depend on `goalContract`). Always labeled UNVERIFIED — never a verified affordance.
/// When `evaluation` is provided the chip expands to a two-column drift view.
struct CompletionReportChip: View {
    var state: AppState
    let conversation: Conversation
    /// Self-report JSON from `goal_complete`'s `criteria_status`. May be nil when the model
    /// omitted `criteria_status` but the grader evaluation is still present.
    let report: JSONValue?
    /// Optional grader evaluation; when present the chip shows the two-column drift view.
    var evaluation: GoalEvaluation? = nil
    var body: some View {
        // Bound the chip's height (like GoalContractPanel/LockedContractChip do). Unbounded, it
        // was the only goal chip without a height cap, and an unbounded subview in the composer's
        // VStack could collapse the surrounding layout — the window blanked the instant this chip
        // appeared at goal_complete (#62).
        ScrollView {
            CompletionReportSection(report: report, onDismiss: {
                state.dismissCompletionReport(for: conversation.id)
            }, evaluation: evaluation, conversation: conversation, state: state)
        }
        .frame(maxHeight: 320)
        .background(.thinMaterial)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}

/// Renders the model's per-criterion self-report as explicitly UNVERIFIED.
/// When `evaluation` is present each row shows a two-column drift layout:
///   left  = self-report (neutral, never green)
///   right = grader verdict (colored) + evidence, with a ⚠ drift badge on disagreement.
struct CompletionReportSection: View {
    /// Self-report JSON. May be nil when the model omitted `criteria_status` but an
    /// evaluation is present. The gate in ChatView guarantees at least one of `report`
    /// and `evaluation` is non-nil.
    let report: JSONValue?
    /// When set, a ✕ appears in the header to dismiss the report chip.
    var onDismiss: (() -> Void)? = nil
    /// Optional grader result. When nil the section falls back to single-column self-report.
    var evaluation: GoalEvaluation? = nil
    /// Slice D2 — supplied only by `CompletionReportChip`. nil for the checkpoint pause chip's use
    /// of this section, which must stay read-only (accept/reject belongs on the finished report).
    var conversation: Conversation? = nil
    var state: AppState? = nil

    /// Accept/reject handlers for one criterion, or nil when this section is read-only: either it
    /// has no conversation/state (the checkpoint pause chip), or the goal is not awaiting human
    /// judgement (a finished goal's report must not let the user "re-judge" it — recordHumanJudgement
    /// would just refuse, leaving buttons that visibly do nothing).
    private func judgementHandlers(for criterionId: UUID) -> (accept: () -> Void, reject: () -> Void)? {
        guard let conversation, let state,
              conversation.goalContract?.awaitingHumanJudgement == true else { return nil }
        return (
            accept: { state.recordHumanJudgement(for: conversation.id, criterionId: criterionId, accepted: true) },
            reject: { state.recordHumanJudgement(for: conversation.id, criterionId: criterionId, accepted: false) }
        )
    }

    private var items: [CompletionReportItem] {
        guard let report, case .array(let elements) = report else { return [] }
        // Index-prefixed id keeps ForEach identity stable even if the model echoes the
        // same criterion text twice (a duplicate bare-text id trips a SwiftUI warning
        // and can drop rows).
        return elements.enumerated().compactMap { index, element in
            guard case .object(let obj) = element else { return nil }
            let criterion = obj["criterion"]?.stringValue ?? ""
            let status    = obj["status"]?.stringValue    ?? ""
            let evidence  = obj["evidence"]?.stringValue  ?? ""
            guard !criterion.isEmpty else { return nil }
            return CompletionReportItem(
                id: "\(index)-\(criterion)",
                criterion: criterion,
                status: status,
                evidence: evidence
            )
        }
    }

    private func selfReportStatus(for criterionText: String) -> String {
        CompletionSelfReportMatching.status(for: criterionText, in: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(evaluation != nil
                     ? "COMPLETION REPORT · SELF-REPORT vs GRADER"
                     : "COMPLETION SELF-REPORT · UNVERIFIED")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.secondary)
                if let onDismiss {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss completion report")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Slice D1 — an ungated completion says so. A goal that ran out of retries with work
            // still unmet must never look like one that passed.
            if let outcome = evaluation?.gateOutcome,
               let banner = outcome.bannerText(unmetCount: evaluation?.criteria.filter { $0.verdict == .notMet }.count ?? 0) {
                Label(banner, systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            if let evaluation {
                // Two-column drift view — spine is the grader's criteria list.
                if evaluation.criteria.isEmpty {
                    Text("No criteria in evaluation.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(evaluation.criteria) { verdict in
                            DriftCriterionRow(
                                verdict: verdict,
                                selfReportStatus: selfReportStatus(for: verdict.criterionText),
                                evaluationStatus: evaluation.status,
                                reportPresent: report != nil,
                                waiverReason: evaluation.waivers[verdict.criterionId],
                                onAccept: judgementHandlers(for: verdict.criterionId)?.accept,
                                onReject: judgementHandlers(for: verdict.criterionId)?.reject
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
            } else {
                // Fallback: single-column self-report (no grader result yet).
                if items.isEmpty {
                    Text("No criterion statuses found in report.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            CompletionReportItemRow(item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                Text("Independent verification arrives with the drift evaluator (not yet built).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Drift criterion row (two-column: self-report LEFT, grader RIGHT)

/// A single row in the drift view. Shows criterion text + kind badge, then a left column
/// with the neutral self-report icon, and a right column with the grader's colored verdict.
/// A ⚠ drift badge appears when the self-report claims met but the grader says notMet.
private struct DriftCriterionRow: View {
    let verdict: CriterionVerdict
    /// Raw status string from the agent's self-report JSON ("met"/"not_met"/…), or "" if unknown.
    let selfReportStatus: String
    /// Overall evaluation status — used to decide whether to show a verifying spinner.
    let evaluationStatus: EvaluationStatus
    /// False when the self-report JSON was entirely absent (model omitted `criteria_status`).
    /// When false and selfReportStatus is empty, the left column shows a "not reported" placeholder.
    var reportPresent: Bool = true
    /// Slice D1 — the agent's stated reason for waiving this criterion, when it waived one. Shown
    /// BESIDE the grader's verdict, never in place of it: a waiver does not erase evidence.
    var waiverReason: String? = nil
    /// Slice D2 — supplied only by the completion report while the goal awaits judgement.
    var onAccept: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil

    /// True when the self-report says the criterion is met but the grader disagrees. Requires a
    /// real grade: a `.failed` grader produced placeholders, not a disagreement (#54).
    private var hasDrift: Bool {
        evaluationStatus == .graded && verdict.verdict == .notMet && selfReportStatus == "met"
    }

    /// Whether to show the "not reported" placeholder: report was absent AND no status was matched.
    private var isNotReported: Bool {
        !reportPresent && selfReportStatus.isEmpty
    }

    private var selfReportIcon: String {
        // Always neutral — never a green checkmark.
        if isNotReported { return "minus.circle" }
        switch selfReportStatus {
        case "met":         return "circle.dashed"
        case "not_met":     return "circle.slash"
        default:            return "questionmark.circle"
        }
    }

    private var selfReportAccessibilityLabel: String {
        if isNotReported { return "not reported" }
        switch selfReportStatus {
        case "met":         return "self-reported met (unverified)"
        case "not_met":     return "self-reported not met (unverified)"
        case "cannot_verify": return "self-reported: cannot verify"
        default:            return "self-report unknown"
        }
    }

    private var kindLabel: String {
        switch verdict.kind {
        case .executable:  return "exec"
        case .qualitative: return "qual"
        case .humanJudged: return "human"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: criterion text + kind badge + optional drift badge.
            HStack(alignment: .top, spacing: 6) {
                Text(verdict.criterionText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(kindLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 3))
                if hasDrift {
                    Label("drift", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("Drift detected: self-report disagrees with grader")
                }
            }

            // Two-column verdict row.
            HStack(alignment: .top, spacing: 8) {
                // LEFT — self-report (neutral)
                HStack(spacing: 4) {
                    Image(systemName: selfReportIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(selfReportAccessibilityLabel)
                    Text("self")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // RIGHT — grader verdict (colored)
                graderColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)

            // Grader evidence (shown below the two-column row when present and graded).
            if evaluationStatus == .graded, !verdict.evidence.isEmpty {
                Text(verdict.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }

            if let label = verdict.humanJudgementLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if verdict.verdict == .humanPending, let onAccept, let onReject {
                HStack(spacing: 8) {
                    Button("Accept", action: onAccept)
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                    Button("Reject", action: onReject)
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                }
                .font(.caption.bold())
                .padding(.top, 2)
            }

            if let waiverReason {
                Label("WAIVED by the agent: \"\(waiverReason)\"", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 6))
    }

    @ViewBuilder
    private var graderColumn: some View {
        switch evaluationStatus {
        case .verifying:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Grader verifying")
                Text("verifying…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            // The grader never delivered a verdict (crashed, hit its cap, stopped early). Its
            // per-criterion values are placeholders, so rendering them in the same colored form as
            // a real grade would present a non-result as a finding.
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Grader failed to produce a verdict")
                Text("grader failed")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .graded:
            let glyph = verdict.graderColumnGlyph
            HStack(spacing: 4) {
                Image(systemName: glyph.symbolName)
                    .font(.caption)
                    .foregroundStyle(graderColumnTint)
                    .accessibilityLabel(glyph.accessibilityLabel)
                verdictLabel
            }
        }
    }

    /// Colour for the graded-column glyph. A human's own verdict deliberately does NOT reuse the
    /// grader's "verified" green — that would read as machine-verified evidence for a claim the
    /// user asserted, not the grader (spec §6). `.blue` still communicates "met" without borrowing
    /// the grader's colour, and stays legible in both light and dark mode.
    private var graderColumnTint: Color {
        switch (verdict.method, verdict.verdict) {
        case (.human, .met):    return .blue
        case (.human, .notMet): return .orange
        case (_, .met):         return .green
        case (_, .notMet):      return .red
        case (_, .cannotVerify): return .secondary
        case (_, .humanPending): return .secondary
        }
    }

    @ViewBuilder
    private var verdictLabel: some View {
        switch verdict.verdict {
        case .met:
            Text("met")
                .font(.caption2)
                .foregroundStyle(.green)
        case .notMet:
            Text("not met")
                .font(.caption2)
                .foregroundStyle(.red)
        case .cannotVerify:
            Text("cannot verify")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .humanPending:
            Text("your call")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Single-column self-report row (used when no evaluation is available)

private struct CompletionReportItemRow: View {
    let item: CompletionReportItem

    private var statusIcon: String {
        // Intentionally neutral for all statuses — never a green checkmark.
        switch item.status {
        case "met": return "circle.dashed"
        case "not_met": return "circle.dashed"
        default: return "questionmark.circle"
        }
    }

    private var statusLabel: String {
        switch item.status {
        case "met": return "self-reported met"
        case "not_met": return "self-reported not met"
        case "cannot_verify": return "self-reported: cannot verify"
        default: return item.status
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: statusIcon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .accessibilityLabel(statusLabel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.criterion)
                        .font(.body)
                    Text("self-reported · unverified")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !item.evidence.isEmpty {
                Text(item.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(.rect(cornerRadius: 6))
    }
}

// MARK: - Subviews

private struct CriterionRow: View {
    @Binding var criterion: Criterion

    /// Current milestones from the draft panel — used for the checkpoint picker.
    let milestones: [Milestone]
    /// Which milestone title (if any) this criterion is currently assigned to.
    let selectedMilestoneTitle: String?
    /// Called when the user picks a different milestone (or nil = unassigned).
    let onMilestoneChange: (String?) -> Void
    /// Called when the user types a new milestone title in the "New…" field.
    let onAddMilestone: (String) -> Void

    /// Local mirror of `criterion.check` so we can use a plain `$checkText` binding
    /// instead of a manual `Binding(get:set:)`.
    @State private var checkText: String
    /// Tracks whether the "New milestone" inline TextField is shown.
    @State private var showingNewMilestoneField = false
    @State private var newMilestoneTitle = ""

    init(
        criterion: Binding<Criterion>,
        milestones: [Milestone],
        selectedMilestoneTitle: String?,
        onMilestoneChange: @escaping (String?) -> Void,
        onAddMilestone: @escaping (String) -> Void
    ) {
        _criterion = criterion
        _checkText = State(initialValue: criterion.wrappedValue.check ?? "")
        self.milestones = milestones
        self.selectedMilestoneTitle = selectedMilestoneTitle
        self.onMilestoneChange = onMilestoneChange
        self.onAddMilestone = onAddMilestone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Kind", selection: $criterion.kind) {
                    Text("Executable").tag(CriterionKind.executable)
                    Text("Qualitative").tag(CriterionKind.qualitative)
                    Text("Human-judged").tag(CriterionKind.humanJudged)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.caption)
                .frame(width: 130)

                TextField("Criterion description", text: $criterion.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...3)
                    .padding(6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if criterion.kind == .executable {
                TextField("Check command (e.g. swift test)", text: $checkText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(Color.irisIndigo.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 138)
                    .onChange(of: checkText) { _, new in
                        criterion.check = new.isEmpty ? nil : new
                    }
            }
            // Milestone assignment picker (always shown so the user can author the ladder).
            HStack(spacing: 6) {
                Menu {
                    Button("— none —") { onMilestoneChange(nil) }
                    Divider()
                    ForEach(milestones) { m in
                        Button(m.title) { onMilestoneChange(m.title) }
                    }
                    Divider()
                    Button("New checkpoint…") { showingNewMilestoneField = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flag")
                            .font(.caption2)
                        Text(selectedMilestoneTitle ?? "— no checkpoint —")
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(selectedMilestoneTitle != nil ? Color.irisIndigo : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.leading, 138)
            if showingNewMilestoneField {
                HStack(spacing: 6) {
                    TextField("Checkpoint name", text: $newMilestoneTitle)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .onSubmit {
                            commitNewMilestone()
                        }
                    Button("Add") { commitNewMilestone() }
                        .buttonStyle(.plain)
                        .font(.caption.bold())
                        .foregroundStyle(Color.irisIndigo)
                    Button("Cancel") {
                        showingNewMilestoneField = false
                        newMilestoneTitle = ""
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 138)
            }
        }
    }

    private func commitNewMilestone() {
        let trimmed = newMilestoneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAddMilestone(trimmed)
        newMilestoneTitle = ""
        showingNewMilestoneField = false
    }
}

// MARK: - Milestone ladder rung
// `MilestoneRungState` now lives on GoalContract.swift (testable, shared).

private struct MilestoneRungRow: View {
    let title: String
    let rungState: MilestoneRungState

    private var icon: String {
        switch rungState {
        case .done:          return "checkmark.circle.fill"
        case .current:       return "arrow.right.circle.fill"
        case .pausedCurrent: return "pause.circle.fill"
        case .upcoming:      return "circle"
        }
    }

    private var iconColor: Color {
        switch rungState {
        case .done:          return .green
        case .current:       return Color.irisIndigo
        case .pausedCurrent: return .orange
        case .upcoming:      return Color.primary.opacity(0.25)
        }
    }

    private var label: String {
        switch rungState {
        case .done:          return "done"
        case .current:       return "current"
        case .pausedCurrent: return "paused for review"
        case .upcoming:      return "upcoming"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.caption)
                .accessibilityLabel(label)
            Text(title)
                .font(rungState == .upcoming ? .caption : .caption.bold())
                .foregroundStyle(rungState == .upcoming ? .tertiary : .primary)
            if rungState == .pausedCurrent {
                Text("· paused for review")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rungState == .pausedCurrent
                    ? Color.orange.opacity(0.08)
                    : Color.primary.opacity(rungState == .upcoming ? 0.02 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Pairs a stable UUID with an index so `ForEach` can use a fixed identity while
/// `StringListSection` still binds edits directly into the underlying `[String]` array.
private struct IndexedString: Identifiable {
    let id: UUID
    let index: Int
}

private struct StringListSection: View {
    let label: String
    let systemImage: String
    @Binding var items: [String]

    /// Stable row identifiers generated once per section lifetime.
    /// Each entry maps a UUID to a positional index in `items`.
    /// Using UUID-based identity prevents SwiftUI from recycling rows incorrectly
    /// when the collection is mutated (add/delete in future iterations).
    @State private var rowIDs: [IndexedString]

    init(label: String, systemImage: String, items: Binding<[String]>) {
        self.label = label
        self.systemImage = systemImage
        _items = items
        _rowIDs = State(initialValue: items.wrappedValue.indices.map {
            IndexedString(id: UUID(), index: $0)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(rowIDs) { row in
                TextField(label, text: $items[row.index], axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...2)
                    .padding(6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
