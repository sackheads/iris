import Foundation

/// The one answer to "does Iris need me?" (D6 decision 2), computed from four inputs and never
/// stored: the live asks, the goal waits of the user's own conversations, the jobs in flight,
/// and the ledger's snapshot. The status item draws it, and the run log refreshes from its
/// ledger half. Action required outranks running, which outranks idle.
enum SurfaceAttention: Equatable, Sendable {
    case actionRequired([Reason])
    case running(Int)
    case idle

    /// Something waiting on the owner that a click resolves (owner ruling 3).
    enum Reason: Equatable, Sendable {
        /// Every live ask, wherever it is charged. `conversationId` is the delegation root of the
        /// oldest one, which is where Open goes.
        case approvals(count: Int, conversationId: UUID?)
        /// An unarchived, user-facing conversation waiting on a goal decision.
        case goalWait(conversationId: UUID, title: String, phrase: String)
        case blocked(LedgerAttention.Blocked)
        /// Jobs paused for a reason that needs `/jobs resume`, grouped by `pauseLabel`.
        case paused(label: String, jobs: [LedgerAttention.Paused])
    }

    struct Ask: Equatable, Sendable {
        let id: UUID
        /// The delegation root the ask is charged to; nil for an ask with no conversation.
        let root: UUID?
        let requestedAt: Date
    }

    struct Wait: Equatable, Sendable {
        let conversationId: UUID
        let title: String
        let phrase: String
    }

    static func derive(asks: [Ask], waits: [Wait], runningJobs: [UUID: RunningJob],
                       ledger: LedgerAttention) -> SurfaceAttention {
        var reasons: [Reason] = []
        if let oldest = asks.min(by: { $0.requestedAt < $1.requestedAt }) {
            reasons.append(.approvals(count: asks.count, conversationId: oldest.root))
        }
        reasons += waits.map { .goalWait(conversationId: $0.conversationId, title: $0.title, phrase: $0.phrase) }
        reasons += ledger.blocked.map(Reason.blocked)
        let byLabel = Dictionary(grouping: ledger.attentionPaused) { pauseLabel($0.reason) }
        reasons += byLabel.keys.sorted().map { .paused(label: $0, jobs: byLabel[$0] ?? []) }
        if !reasons.isEmpty { return .actionRequired(reasons) }
        if !runningJobs.isEmpty { return .running(runningJobs.count) }
        return .idle
    }

    /// How many things are waiting: each ask, each wait, each blocked run, each paused job.
    var actionCount: Int {
        guard case .actionRequired(let reasons) = self else { return 0 }
        return reasons.reduce(0) { sum, reason in
            switch reason {
            case .approvals(let count, _): return sum + count
            case .goalWait, .blocked: return sum + 1
            case .paused(_, let jobs): return sum + jobs.count
            }
        }
    }

    /// The menu's word for why a job is paused. Matched against the reasons the runner and the
    /// scheduler write; `SurfaceAttentionTests.pauseLabels` pins each one, so a reworded reason
    /// fails a test rather than falling through to the catch-all.
    static func pauseLabel(_ reason: String) -> String {
        if reason.hasPrefix(JobRunner.breakerReasonPrefix) { return "breaker" }
        if Briefing.isBudgetReason(reason) { return "budget" }
        if reason == JobRunner.retriesExhaustedReason { return "retries used up" }
        if reason == JobRunner.gateFailingReason { return "gate failing" }
        if reason.hasPrefix(JobRunner.unknownBuiltinReason) { return "unknown built-in" }
        if reason == JobScheduler.unmatchableReason { return "schedule never matches" }
        return "needs /jobs resume"
    }
}

/// One line of the status item's menu, and where clicking it goes.
struct StatusMenuRow: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case conversation(UUID)
        case card(runId: UUID, jobId: UUID)
        case iris
        case nowhere
    }

    let id: String
    let text: String
    let target: Target
}

extension SurfaceAttention {
    static let menuTitleCap = 40

    /// The menu's rows: what is waiting, then the counts that never change the icon (decision 3).
    /// Model-chosen names are flattened and capped as the briefing does.
    static func menuRows(_ attention: SurfaceAttention, ledger: LedgerAttention,
                         runningCount: Int) -> [StatusMenuRow] {
        var rows: [StatusMenuRow] = []
        if case .actionRequired(let reasons) = attention {
            let blocked = reasons.compactMap { reason -> LedgerAttention.Blocked? in
                if case .blocked(let b) = reason { return b } else { return nil }
            }
            var seenBlockedJobs: Set<UUID> = []
            for reason in reasons {
                switch reason {
                case .approvals(let count, let root):
                    rows.append(StatusMenuRow(id: "approvals", text: "\(count) approval\(plural(count)) waiting",
                                              target: root.map(StatusMenuRow.Target.conversation) ?? .nowhere))
                case .goalWait(let id, let title, let phrase):
                    rows.append(StatusMenuRow(id: "wait-\(id)",
                                              text: "\(phrase.prefix(1).uppercased() + phrase.dropFirst()) in “\(field(title, cap: menuTitleCap))”",
                                              target: .conversation(id)))
                case .blocked(let b):
                    // One row per job (R10): the first of its runs here is the oldest, which is
                    // the card the row opens.
                    guard seenBlockedJobs.insert(b.jobId).inserted else { continue }
                    rows.append(blockedRow(b, runs: blocked.filter { $0.jobId == b.jobId }))
                case .paused(let label, let jobs):
                    rows.append(StatusMenuRow(id: "paused-\(label)",
                                              text: "\(jobs.count) job\(plural(jobs.count)) paused (\(label))",
                                              target: .iris))
                }
            }
        }
        if runningCount > 0 {
            rows.append(StatusMenuRow(id: "running", text: "\(runningCount) job\(plural(runningCount)) running",
                                      target: .nowhere))
        }
        if ledger.failedCount > 0 {
            rows.append(StatusMenuRow(id: "failed", text: "\(ledger.failedCount) failed run\(plural(ledger.failedCount))",
                                      target: .iris))
        }
        if ledger.ownerPausedCount > 0 {
            rows.append(StatusMenuRow(id: "owner-paused",
                                      text: "\(ledger.ownerPausedCount) job\(plural(ledger.ownerPausedCount)) paused by you",
                                      target: .nowhere))
        }
        return rows
    }

    /// `pr-sweep blocked: run_command (×4)`. A single run has no count, and runs blocked on
    /// different tools never name just one of them.
    private static func blockedRow(_ first: LedgerAttention.Blocked,
                                   runs: [LedgerAttention.Blocked]) -> StatusMenuRow {
        var text = "\(field(first.jobName)) blocked: \(field(first.tool ?? "a tool"))"
        if Set(runs.map(\.tool)).count > 1 { text += " and others" }
        if runs.count > 1 { text += " (×\(runs.count))" }
        return StatusMenuRow(id: "blocked-\(first.jobId)", text: text,
                             target: .card(runId: first.runId, jobId: first.jobId))
    }

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    private static func field(_ value: String, cap: Int = IrisEngine.cardNameCap) -> String {
        IrisEngine.flattenCardField(value, cap: cap)
    }
}

/// What the menu bar draws (D6 decision 4). Menu bar images are template-rendered, so the states
/// differ in shape: the base symbol alone, the symbol and a count, the symbol and `!` and a count.
struct StatusGlyph: Equatable, Sendable {
    let symbol: String
    let text: String?
    let accessibilityLabel: String

    static func make(_ attention: SurfaceAttention, identity: BuildIdentity) -> StatusGlyph {
        let base = identity.statusSymbol
        switch attention {
        case .idle:
            return StatusGlyph(symbol: base, text: nil, accessibilityLabel: "Iris: idle")
        case .running(let n):
            return StatusGlyph(symbol: base, text: "\(n)",
                               accessibilityLabel: "Iris: \(n) job\(n == 1 ? "" : "s") running")
        case .actionRequired:
            let n = attention.actionCount
            return StatusGlyph(symbol: base, text: "!\(n)",
                               accessibilityLabel: "Iris: \(n) thing\(n == 1 ? "" : "s") waiting on you")
        }
    }
}

extension AppState {
    /// D6 decision 2, over this app's state. An ask is counted wherever it is charged. A goal wait
    /// counts only in an unarchived, user-facing conversation (the `list_sessions` filter) that
    /// has no ask of its own, since that ask is already counted.
    var surfaceAttention: SurfaceAttention {
        let asks = pendingApprovals.map {
            SurfaceAttention.Ask(id: $0.id, root: $0.conversationId.map { delegationRoot(of: $0) },
                                 requestedAt: $0.requestedAt)
        }
        let askRoots = Set(asks.compactMap(\.root))
        let waits = conversations.compactMap { c -> SurfaceAttention.Wait? in
            guard !c.isArchived, c.isUserFacing, !askRoots.contains(c.id),
                  case .waiting(let on, _) = sessionStatus(for: c) else { return nil }
            return SurfaceAttention.Wait(conversationId: c.id, title: c.title, phrase: on)
        }
        return .derive(asks: asks, waits: waits, runningJobs: runningJobs, ledger: ledgerAttention)
    }
}
