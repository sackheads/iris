import Foundation
import Observation

/// One row of the Run Log window (D6 decision 15).
struct RunLogRow: Identifiable, Equatable, Sendable {
    enum Transcript: Equatable, Sendable {
        /// The run recorded no transcript: a built-in, a gate check, a stillborn row.
        case none
        case live(UUID)
        /// Recorded, and since removed by retention.
        case pruned
    }

    let id: UUID
    let jobId: UUID
    let started: Date
    /// nil while the run is still going.
    let duration: TimeInterval?
    let jobName: String
    let triggerKind: String
    let status: JobRun.Status
    let weightedTokens: Int
    /// The outcome, or the failure reason when there is none (`JobRun.detailText`).
    /// Shown as plain text in the window, and never sent to a model or a notification: it is the
    /// run's own words, which no human read before they arrived.
    let outcome: String?
    /// An unacknowledged failure or blocked run: the one-click clear owner ruling 3 needs.
    let canAcknowledge: Bool
    /// A blocked run links to its card, where the call and its verdict are. No Approve here.
    let opensCard: Bool
    let transcript: Transcript

    static func make(_ run: JobRun, transcriptExists: (UUID) -> Bool) -> RunLogRow {
        let waits = run.status == .failed || run.status == .blockedOnApproval
        let transcript: Transcript
        if let id = run.transcriptConversationId {
            transcript = transcriptExists(id) ? .live(id) : .pruned
        } else {
            transcript = .none
        }
        return RunLogRow(
            id: run.id, jobId: run.jobId, started: run.startedAt,
            duration: run.finishedAt.map { $0.timeIntervalSince(run.startedAt) },
            jobName: run.jobName, triggerKind: run.triggerKind, status: run.status,
            weightedTokens: CostWeights.weighted(run.components, provider: run.provider, model: run.model),
            outcome: run.detailText, canAcknowledge: waits && run.acknowledgedAt == nil,
            opensCard: run.status == .blockedOnApproval, transcript: transcript)
    }
}

/// The Run Log window's rows, paged from the ledger off the main actor.
@MainActor
@Observable
final class RunLogModel {
    private(set) var rows: [RunLogRow] = []
    private(set) var hasMore = false
    /// The job picker's choices, read with every reload (R9: never `jobs()`).
    private(set) var jobChoices: [JobLedger.JobName] = []
    // Each filter reloads itself, so a `loadMore` after a change waits for the new filter's first
    // page instead of paging the old filter from the old cursor (Task 8's ruling).
    var jobFilter: UUID? {
        didSet { if jobFilter != oldValue { reload() } }
    }
    var statusFilter: JobRun.Status? {
        didSet { if statusFilter != oldValue { reload() } }
    }
    var showGateChecks = false {
        didSet { if showGateChecks != oldValue { reload() } }
    }

    @ObservationIgnored private var next: JobLedger.RunLogCursor?
    @ObservationIgnored private let ledger: JobLedger
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let transcriptExists: @MainActor (UUID) -> Bool
    @ObservationIgnored private var generation = 0
    /// The reload whose page has not landed yet, if any.
    @ObservationIgnored private(set) var pendingReload: Task<Void, Never>?

    init(ledger: JobLedger, pageSize: Int = 100, transcriptExists: @escaping @MainActor (UUID) -> Bool) {
        self.ledger = ledger
        self.pageSize = pageSize
        self.transcriptExists = transcriptExists
    }

    /// Reads from the top. A filter change reads one page; a refresh (`keepingDepth`) reads as
    /// many rows as are showing, so the pages "Load more" brought in survive it.
    @discardableResult
    func reload(keepingDepth: Bool = false) -> Task<Void, Never> {
        let task = load(after: nil, limit: keepingDepth ? max(pageSize, rows.count) : pageSize)
        pendingReload = task
        return task
    }

    @discardableResult
    func loadMore() -> Task<Void, Never> {
        // A reload in flight owns the rows and the cursor: a page read from the old cursor would
        // supersede it and append to rows it is about to replace.
        if let pendingReload { return pendingReload }
        guard let next else { return Task {} }
        return load(after: next, limit: pageSize)
    }

    private func load(after cursor: JobLedger.RunLogCursor?, limit: Int) -> Task<Void, Never> {
        generation += 1
        let generation = self.generation
        let ledger = self.ledger
        let (jobId, status, gate) = (jobFilter, statusFilter, showGateChecks)
        return Task { [weak self] in
            let (result, names) = await Task.detached {
                (Result { try ledger.runLog(limit: limit, before: cursor, jobId: jobId, status: status,
                                            includeGateUnchanged: gate) },
                 cursor == nil ? try? ledger.jobNames() : nil)
            }.value
            // A reload started since makes this page stale: its filters or its cursor are gone.
            guard let self, generation == self.generation else { return }
            if cursor == nil { self.pendingReload = nil }
            if let names {
                self.jobChoices = names
                // A job deleted since it was picked: the picker has no row for it any more.
                if let picked = self.jobFilter, !names.contains(where: { $0.id == picked }) {
                    // Its didSet starts the unfiltered reload; this page belongs to the old filter.
                    self.jobFilter = nil
                    return
                }
            }
            let page: JobLedger.RunLogPage
            switch result {
            case .success(let read): page = read
            case .failure(let error):
                print("[RunLog] could not read the run log: \(error)")
                // A failed reload leaves no cursor that belongs to what is showing.
                if cursor == nil {
                    self.next = nil
                    self.hasMore = false
                }
                return
            }
            // Wrapped rather than passed: `transcriptExists` is `@MainActor`, the parameter is a
            // plain closure, and this task runs on the main actor.
            let exists = self.transcriptExists
            let made = page.runs.map { run in RunLogRow.make(run, transcriptExists: { exists($0) }) }
            self.rows = cursor == nil ? made : self.rows + made
            self.next = page.next
            self.hasMore = page.next != nil
        }
    }
}
