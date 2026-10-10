import Foundation

extension AppState {
    enum RunJobURLOutcome: Equatable, Sendable {
        case fired(UUID)
        case refused
        case deferred(UUID)
    }

    /// An `iris://run-job/<token>` link (D6 decision 12): parse, hash, look up, apply the URL
    /// limit, defer behind a foreign store holder or fire, and say which in Iris. It never
    /// creates, edits, resumes or unpauses a job; no route for those exists. No part of the link
    /// reaches a model. Callable from a test, with no GUI.
    ///
    /// Synchronous on the main actor from the count to the dispatch, so two links for one job
    /// cannot both pass the limit: the first is in `urlFireBatches` before the second is counted.
    @discardableResult
    func handleRunJobURL(_ url: URL, identity: BuildIdentity = .current) -> RunJobURLOutcome {
        let iris = activityConversationId()
        let token: String
        switch RunJobURL.parse(url, identity: identity) {
        case .failure(let refusal):
            refuseURLFire(job: nil, reason: refusal.sentence, to: iris)
            return .refused
        case .success(let parsed):
            token = parsed
        }
        // Looked up by digest: the raw token is never compared with anything stored.
        let digest = URLTriggerToken.digest(token)
        let job: Job?
        do {
            job = try store.ledger.job(urlTokenHash: digest)
        } catch {
            refuseURLFire(job: nil, reason: RunJobURL.ledgerUnreadableReason, to: iris)
            return .refused
        }
        guard let job else {
            refuseURLFire(job: nil, reason: RunJobURL.unknownTokenReason, to: iris)
            return .refused
        }
        if let reason = urlFireRefusal(for: job) {
            refuseURLFire(job: job, reason: reason, to: iris)
            return .refused
        }
        // A wait already under way is joined even if the holder has just gone: firing here too
        // would make its re-check a second fire (plan note 10).
        if pendingURLFires[job.id] != nil { return .deferred(job.id) }
        if let holder = foreignStoreHolder {
            if isProcessAlive(holder) {
                deferURLFire(job, tokenHash: digest, holder: holder, to: iris)
                return .deferred(job.id)
            }
            // Gone since launch: never asked about again, so a reused pid cannot hold fires back.
            foreignStoreHolder = nil
        }
        guard fireByURL(job, to: iris) != nil else { return .refused }
        return .fired(job.id)
    }

    /// Why `job` may not be fired by a link right now, or nil. Asked when the link arrives and
    /// again when a deferred fire comes due. Decision 13: the limit is checked before admission,
    /// so a refused link writes no row, never counts toward the breaker and never pauses the job.
    func urlFireRefusal(for job: Job) -> String? {
        guard job.urlTrigger else { return RunJobURL.triggerOffReason(job.name) }
        if job.pausedReason != nil { return RunJobURL.pausedReason(job) }
        if !job.enabled { return RunJobURL.disabledReason }
        let windowStart = urlClock().addingTimeInterval(-RunJobURL.window)
        guard (try? resolveHeldURLFires(job: job, windowStart: windowStart)) != nil else {
            return RunJobURL.ledgerUnreadableReason
        }
        let batch = urlFireBatches[job.id]
        // Rows from before the batch, plus every one of the batch's own fires: a fire in flight
        // or held counts once, whether or not its row has landed yet.
        guard let rows = try? store.ledger.urlFires(jobId: job.id, since: windowStart, before: batch?.since) else {
            return RunJobURL.ledgerUnreadableReason
        }
        // A fire waiting for a foreign holder is one more, however many links joined it.
        let inBatch = (batch?.dispatched.count ?? 0) + (pendingURLFires[job.id] == nil ? 0 : 1)
        return rows + inBatch >= RunJobURL.maxFiresPerHour ? RunJobURL.overLimitReason : nil
    }

    /// Fires `job` from a link and counts the fire against the limit until its run has started
    /// or it is gone. The one place a URL fire is dispatched, so nothing fires uncounted.
    func fireByURL(_ job: Job, to iris: UUID) -> Task<JobRunner.Admission?, Never>? {
        guard let fire = runJobByHand(job: job, origin: .url, announceTo: iris) else { return nil }
        let now = urlClock()
        var batch = urlFireBatches[job.id] ?? URLFireBatch(since: now)
        batch.dispatched.append(now)
        batch.pending += 1
        urlFireBatches[job.id] = batch
        let task = Task { [weak self] in
            let admission = await fire.value
            self?.urlFireSettled(jobId: job.id, dispatchedAt: now, held: admission == .queued)
            return admission
        }
        urlFireTask = task
        return task
    }

    private func urlFireSettled(jobId: UUID, dispatchedAt: Date, held: Bool) {
        guard var batch = urlFireBatches[jobId] else { return }
        batch.pending -= 1
        // A held fire's run starts later, as `url`; until then the batch keeps counting it.
        if held { batch.held.append(dispatchedAt) }
        urlFireBatches[jobId] = batch.isOutstanding ? batch : nil
    }

    /// Drops the held fires whose run has started, and closes the batch when nothing in it is
    /// outstanding: with none, every fire's row is written and the rows alone are the count. A
    /// held fire has run once a `url` row started after it was sent; one the runner dropped
    /// instead (a policy switch, a delete) is let go once it has left the window. Not keyed on
    /// the job's `queuedFire`: on a busy `queue` or watch job something is nearly always held,
    /// and a batch that waited for an empty slot would stay open, refusing every link, for hours.
    private func resolveHeldURLFires(job: Job, windowStart: Date) throws {
        guard var batch = urlFireBatches[job.id], !batch.held.isEmpty else { return }
        var still: [Date] = []
        for sent in batch.held where sent >= windowStart {
            if try store.ledger.urlFires(jobId: job.id, since: sent) == 0 { still.append(sent) }
        }
        batch.held = still
        urlFireBatches[job.id] = batch.isOutstanding ? batch : nil
    }

    /// Waits, visibly, for the foreign holder to finish (decision 14). One wait per job: a later
    /// link that passed the limit joins it (plan note 10), with no second line and no second fire.
    func deferURLFire(_ job: Job, tokenHash: String, holder: Int32, to iris: UUID) {
        guard pendingURLFires[job.id] == nil else { return }
        let lineId = UUID()
        appendMessage(role: .system, content: RunJobURL.waitingLine(job.name, pid: holder), id: lineId, to: iris)
        pendingURLFires[job.id] = PendingURLFire(jobId: job.id, jobName: job.name, tokenHash: tokenHash,
                                                 holder: holder, since: urlClock(), lineId: lineId,
                                                 conversationId: iris)
        scheduleURLRecheck(job.id)
    }

    private func scheduleURLRecheck(_ jobId: UUID) {
        urlDeferralTimer.schedule(URLDeferral.interval) { [weak self] in self?.recheckDeferredURLFire(jobId) }
    }

    /// One re-check of a waiting fire. When it comes due the job is read again and asked every
    /// question a fresh link would be: deleted, trigger off or token rotated, paused, disabled,
    /// or at its limit, while it waited. The wait's own count is dropped first, and `fireByURL`
    /// counts the fire, so it is counted once.
    func recheckDeferredURLFire(_ jobId: UUID) {
        guard let pending = pendingURLFires[jobId] else { return }
        switch URLDeferral.decide(holderAlive: isProcessAlive(pending.holder),
                                  waited: urlClock().timeIntervalSince(pending.since)) {
        case .wait:
            scheduleURLRecheck(jobId)
        case .giveUp:
            pendingURLFires[jobId] = nil
            // Re-read first: a job deleted, turned off or paused while it waited is that, not a
            // wait that ran out.
            if case .failure(let refusal) = deferredFireCheck(pending) {
                return abandonDeferredFire(pending, refusal)
            }
            updateMessageContent(id: pending.lineId, content: RunJobURL.gaveUpLine(pending.jobName, pid: pending.holder),
                                 in: pending.conversationId, persist: true)
        case .fire:
            pendingURLFires[jobId] = nil
            foreignStoreHolder = nil
            let job: Job
            switch deferredFireCheck(pending) {
            case .failure(let refusal): return abandonDeferredFire(pending, refusal)
            case .success(let current): job = current
            }
            updateMessageContent(id: pending.lineId, content: RunJobURL.waitEndedLine(job.name, pid: pending.holder),
                                 in: pending.conversationId, persist: true)
            _ = fireByURL(job, to: pending.conversationId)
        }
    }

    /// Why a waiting fire is dropped, under the name to say it with.
    struct DeferredFireRefusal: Error {
        let name: String
        let reason: String
    }

    /// The job, re-read, if a waiting fire may go ahead now; otherwise why not. Every question a
    /// fresh link would be asked: deleted, trigger off or token rotated, paused, disabled, or at
    /// its limit, while it waited.
    private func deferredFireCheck(_ pending: PendingURLFire) -> Result<Job, DeferredFireRefusal> {
        let job: Job?
        do {
            job = try store.ledger.job(id: pending.jobId)
        } catch {
            return .failure(.init(name: pending.jobName, reason: RunJobURL.ledgerUnreadableReason))
        }
        guard let job else { return .failure(.init(name: pending.jobName, reason: RunJobURL.deletedWhileWaitingReason)) }
        if let reason = urlFireRefusal(for: job) { return .failure(.init(name: job.name, reason: reason)) }
        // The flag alone is not the link: a token rotated during the wait is a new link, and
        // the one that was opened no longer names this job. A read error is a read error.
        let owner: Job?
        do {
            owner = try store.ledger.job(urlTokenHash: pending.tokenHash)
        } catch {
            return .failure(.init(name: job.name, reason: RunJobURL.ledgerUnreadableReason))
        }
        guard owner?.id == pending.jobId else {
            return .failure(.init(name: job.name, reason: RunJobURL.replacedWhileWaitingReason))
        }
        return .success(job)
    }

    private func abandonDeferredFire(_ pending: PendingURLFire, _ refusal: DeferredFireRefusal) {
        updateMessageContent(id: pending.lineId, content: RunJobURL.waitAbandonedLine(refusal.name, reason: refusal.reason),
                             in: pending.conversationId, persist: true)
    }

    /// Drops what the link handler keeps for a deleted job, so a job created later under the
    /// same id inherits none of it. A waiting fire says now that it will not fire, rather than
    /// at its next re-check.
    func forgetURLState(jobId: UUID) {
        urlFireBatches[jobId] = nil
        urlRefusalLines[jobId.uuidString] = nil
        if let pending = pendingURLFires.removeValue(forKey: jobId) {
            abandonDeferredFire(pending, .init(name: pending.jobName, reason: RunJobURL.deletedWhileWaitingReason))
        }
    }

    /// Says a refusal in Iris, coalesced (plan note 8): the first in an hour is a line, and each
    /// later one updates that line's count, so a flood cannot fill the conversation.
    func refuseURLFire(job: Job?, reason: String, to iris: UUID) {
        let key = job?.id.uuidString ?? "unmatched"
        let now = urlClock()
        if var entry = urlRefusalLines[key], entry.conversationId == iris,
           now.timeIntervalSince(entry.since) < RunJobURL.window,
           conversations.first(where: { $0.id == iris })?.messages.contains(where: { $0.id == entry.messageId }) == true {
            entry.count += 1
            urlRefusalLines[key] = entry
            updateMessageContent(id: entry.messageId,
                                 content: RunJobURL.refusalLine(subject: job?.name, reason: reason, count: entry.count),
                                 in: iris, persist: true)
            return
        }
        let id = UUID()
        appendMessage(role: .system, content: RunJobURL.refusalLine(subject: job?.name, reason: reason, count: 1),
                      id: id, to: iris)
        urlRefusalLines[key] = URLRefusalLine(messageId: id, since: now, count: 1, conversationId: iris)
    }
}
