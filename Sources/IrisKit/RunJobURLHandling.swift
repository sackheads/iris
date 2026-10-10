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
        let job: Job?
        do {
            job = try store.ledger.job(urlTokenHash: URLTriggerToken.digest(token))
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
        let batch = urlFireBatches[job.id]
        // Rows from before the batch, plus the batch's own fires: a fire in flight counts once,
        // whether or not its row has landed yet.
        guard let rows = try? store.ledger.urlFires(jobId: job.id, since: windowStart, before: batch?.since) else {
            return RunJobURL.ledgerUnreadableReason
        }
        let inBatch = batch?.dispatched.filter { $0 >= windowStart }.count ?? 0
        return rows + inBatch >= RunJobURL.maxFiresPerHour ? RunJobURL.overLimitReason : nil
    }

    /// Fires `job` from a link and counts the fire against the limit until it settles. The one
    /// place a URL fire is dispatched, so nothing fires uncounted.
    func fireByURL(_ job: Job, to iris: UUID) -> Task<JobRunner.Admission?, Never>? {
        guard let fire = runJobByHand(job: job, origin: .url, announceTo: iris) else { return nil }
        let now = urlClock()
        var batch = urlFireBatches[job.id] ?? URLFireBatch(since: now)
        batch.dispatched.append(now)
        batch.pending += 1
        urlFireBatches[job.id] = batch
        let task = Task { [weak self] in
            let admission = await fire.value
            self?.urlFireSettled(jobId: job.id)
            return admission
        }
        urlFireTask = task
        return task
    }

    private func urlFireSettled(jobId: UUID) {
        guard var batch = urlFireBatches[jobId] else { return }
        batch.pending -= 1
        // With none in flight every fire's row is written, so the rows alone are the count again.
        urlFireBatches[jobId] = batch.pending > 0 ? batch : nil
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
