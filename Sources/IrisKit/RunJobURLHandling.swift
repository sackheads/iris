import Foundation

/// Whether one URL fire's answer has been counted: by the runner's report or, failing that, when
/// its task ends. Never both.
@MainActor
final class URLFireTicket {
    var decided = false
}

extension AppState {
    enum RunJobURLOutcome: Equatable, Sendable {
        case fired(UUID)
        case refused
    }

    /// An `iris://run-job/<token>` link (D6 decision 12): parse, hash, look up, apply the URL
    /// limit and fire, and say which in Iris. A store held by another process now holds the whole
    /// app at the gate (#463), so nothing here waits. It never creates, edits, resumes or unpauses
    /// a job; no route for those exists. No part of the link reaches a model. Callable from a
    /// test, with no GUI.
    ///
    /// Synchronous on the main actor from the count to the dispatch, so two links for one job
    /// cannot both pass the limit: the first is in `urlFireBatches` before the second is counted.
    @discardableResult
    func handleRunJobURL(_ url: URL, identity: BuildIdentity = .current) -> RunJobURLOutcome {
        // Asked lazily: a refusal coalesced into an existing line never reads `meta` (the D2
        // throttle).
        var resolvedIris: UUID?
        func iris() -> UUID {
            if let resolvedIris { return resolvedIris }
            let id = activityConversationId()
            resolvedIris = id
            return id
        }
        let token: String
        switch RunJobURL.parse(url, identity: identity) {
        case .failure(let refusal):
            refuseURLFire(job: nil, reason: refusal.sentence, to: iris())
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
            refuseURLFire(job: nil, reason: RunJobURL.ledgerUnreadableReason, to: iris())
            return .refused
        }
        guard let job else {
            refuseURLFire(job: nil, reason: RunJobURL.unknownTokenReason, to: iris())
            return .refused
        }
        if let reason = urlFireRefusal(for: job) {
            refuseURLFire(job: job, reason: reason, to: iris())
            return .refused
        }
        guard fireByURL(job, to: iris()) != nil else { return .refused }
        return .fired(job.id)
    }

    /// Why `job` may not be fired by a link right now, or nil. Decision 13: the limit is checked
    /// before admission, so a refused link writes no row, never counts toward the breaker and
    /// never pauses the job.
    func urlFireRefusal(for job: Job) -> String? {
        guard job.urlTrigger else { return RunJobURL.triggerOffReason(job.name) }
        if job.pausedReason != nil { return RunJobURL.pausedReason(job) }
        if !job.enabled { return RunJobURL.disabledReason }
        let windowStart = urlClock().addingTimeInterval(-RunJobURL.window)
        pruneHeldURLFires(job: job, windowStart: windowStart)
        let batch = urlFireBatches[job.id]
        // Rows from before the batch, plus every one of the batch's own fires: a fire in flight
        // or held counts once, whether or not its row has landed yet.
        guard let rows = try? store.ledger.urlFires(jobId: job.id, since: windowStart, before: batch?.since) else {
            return RunJobURL.ledgerUnreadableReason
        }
        let inBatch = batch?.dispatched.count ?? 0
        return rows + inBatch >= RunJobURL.maxFiresPerHour ? RunJobURL.overLimitReason : nil
    }

    /// Fires `job` from a link and counts the fire against the limit until its run has started
    /// or it is gone. The one place a URL fire is dispatched, so nothing fires uncounted.
    func fireByURL(_ job: Job, to iris: UUID) -> Task<JobRunner.Admission?, Never>? {
        let now = urlClock()
        let ticket = URLFireTicket()
        let jobId = job.id
        // Settled on the runner's answer for this fire, not when `fire` returns: a run whose
        // held slot keeps being refilled keeps `fire`'s loop going for hours.
        let onDecided: @Sendable (FireDecision) async -> Void = { [weak self] decision in
            await MainActor.run { self?.urlFireDecided(ticket, jobId: jobId, sent: now, decision) }
        }
        guard let fire = runJobByHand(job: job, origin: .url, announceTo: iris, onDecided: onDecided) else { return nil }
        var batch = urlFireBatches[job.id] ?? URLFireBatch(since: Self.urlBatchStart(after: now))
        batch.dispatched.append(now)
        batch.pending += 1
        urlFireBatches[job.id] = batch
        let task = Task { [weak self] in
            let admission = await fire.value
            // A fire the runner never saw (no runner yet) is answered here instead.
            self?.urlFireDecided(ticket, jobId: jobId, sent: now,
                                 FireDecision(admission: admission, holdGeneration: nil))
            return admission
        }
        urlFireTask = task
        return task
    }

    /// Where a new batch starts counting its own fires (#575): two milliseconds past `now`'s
    /// millisecond. The ledger keeps `startedAt` rounded to the nearest millisecond, so a row that
    /// began just before `now` can read back as late as the next millisecond, and the earlier
    /// `startedAt < since` check missed it: a link opened in the same millisecond as the previous
    /// fire's row got one fire past the limit. From here every earlier row is counted. The cost,
    /// in that same window only: a batch fire whose own row lands before this start is counted
    /// twice, as a row and as a dispatch, and refuses one fire early. A limit fails closed.
    nonisolated static func urlBatchStart(after now: Date) -> Date {
        Date(timeIntervalSince1970: ((now.timeIntervalSince1970 * 1000).rounded(.down) + 2) / 1000)
    }

    /// One URL fire's answer, once. A run's row is begun by now and every refusal's row written,
    /// so the fire stops being outstanding, unless it was held: then it waits for the held run.
    func urlFireDecided(_ ticket: URLFireTicket, jobId: UUID, sent: Date, _ decision: FireDecision) {
        guard !ticket.decided else { return }
        ticket.decided = true
        guard var batch = urlFireBatches[jobId] else { return }
        batch.pending -= 1
        if decision.admission == .queued {
            batch.held.append(HeldURLFire(sent: sent, generation: decision.holdGeneration ?? Int.max))
        }
        urlFireBatches[jobId] = batch.isOutstanding ? batch : nil
    }

    /// The held run of `generation` has begun its row (or was answered otherwise): every URL fire
    /// held into that hold, or an earlier one, is now that run's row.
    func heldURLFireDecided(jobId: UUID, generation: Int) {
        guard var batch = urlFireBatches[jobId] else { return }
        batch.held.removeAll { $0.generation <= generation }
        urlFireBatches[jobId] = batch.isOutstanding ? batch : nil
    }

    /// Lets go of held fires that have left the window: one the runner dropped instead of running
    /// (a policy switch, a delete, a failed hold) would otherwise hold the batch open for good.
    private func pruneHeldURLFires(job: Job, windowStart: Date) {
        guard var batch = urlFireBatches[job.id], !batch.held.isEmpty else { return }
        batch.held.removeAll { $0.sent < windowStart }
        urlFireBatches[job.id] = batch.isOutstanding ? batch : nil
    }

    /// Drops what the link handler keeps for a deleted job, so a job created later under the
    /// same id inherits none of it.
    func forgetURLState(jobId: UUID) {
        urlFireBatches[jobId] = nil
        urlRefusalLines[jobId.uuidString] = nil
    }

    /// Says a refusal in Iris, coalesced (plan note 8): the first in an hour is a line, and later
    /// ones raise its count. A later one costs a dictionary update and nothing else; the line
    /// catches up at most once a second (the D2 throttle), so a page opening links in a loop never
    /// scans Iris, rewrites a message or persists anything per link. `iris` is asked only when a
    /// line is made.
    func refuseURLFire(job: Job?, reason: String, to iris: @autoclosure () -> UUID) {
        let key = job?.id.uuidString ?? "unmatched"
        let now = urlClock()
        if var entry = urlRefusalLines[key], now.timeIntervalSince(entry.since) < RunJobURL.window {
            entry.count += 1
            entry.reason = reason
            urlRefusalLines[key] = entry
            scheduleURLRefusalFlush(key)
            return
        }
        // The window has rolled: the old line gets the count it had before a new one starts.
        if urlRefusalLines[key] != nil { flushURLRefusalLine(key) }
        let conversation = iris()
        let id = UUID()
        appendMessage(role: .system, content: RunJobURL.refusalLine(subject: job?.name, reason: reason, count: 1),
                      id: id, to: conversation)
        urlRefusalLines[key] = URLRefusalLine(messageId: id, since: now, count: 1, written: 1,
                                              conversationId: conversation, subject: job?.name, reason: reason)
    }

    private func scheduleURLRefusalFlush(_ key: String) {
        guard urlRefusalFlushPending.insert(key).inserted else { return }
        urlRefusalFlushTimer.schedule(RunJobURL.refusalFlushInterval) { [weak self] in
            self?.flushURLRefusalLine(key)
        }
    }

    /// Brings one coalesced line up to its count. The one place the line is looked for: if the
    /// owner deleted it, or Iris has been replaced since, the count goes on a new line in Iris.
    func flushURLRefusalLine(_ key: String) {
        urlRefusalFlushPending.remove(key)
        guard var entry = urlRefusalLines[key], entry.count != entry.written else { return }
        let text = RunJobURL.refusalLine(subject: entry.subject, reason: entry.reason, count: entry.count)
        let iris = activityConversationId()
        if entry.conversationId == iris,
           conversations.first(where: { $0.id == iris })?.messages.contains(where: { $0.id == entry.messageId }) == true {
            updateMessageContent(id: entry.messageId, content: text, in: iris, persist: true)
        } else {
            let id = UUID()
            appendMessage(role: .system, content: text, id: id, to: iris)
            entry.messageId = id
            entry.conversationId = iris
        }
        entry.written = entry.count
        urlRefusalLines[key] = entry
    }

    /// Every line still behind its count, now: at quit, and in tests.
    func flushURLRefusalLines() {
        for key in Array(urlRefusalLines.keys) { flushURLRefusalLine(key) }
    }
}
