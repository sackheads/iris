import Foundation

extension AppState {
    /// A fire a person, or a link they made, asked for (D6 decision 12): the body `/jobs run`
    /// used to own, so both callers meet the same checks. Through `fire`, not `run`, so it meets
    /// the overlap, breaker and budget checks a scheduled fire does (§4). It skips the gate, which
    /// only a cadence meets. Returns nil when it refused before firing.
    ///
    /// `/jobs run` speaks in command output, as before. A URL fire speaks in one system line in
    /// `conversationId` (Iris), updated in place once admission answers (plan note 9).
    @discardableResult
    func runJobByHand(job: Job, origin: FireOrigin, announceTo conversationId: UUID,
                      onDecided: (@Sendable (FireDecision) async -> Void)? = nil) -> Task<JobRunner.Admission?, Never>? {
        let byURL = origin.root == .url
        // Admission drops a paused or disabled job without a word, and both are states the user
        // has to undo before a hand-started fire can do anything. Saying so before anything is
        // started is the difference between a command that did nothing and one that looks like
        // it worked.
        if job.pausedReason != nil || !job.enabled {
            if byURL {
                let refusal = JobRunner.refusalText(job.pausedReason != nil ? .dropPaused : .dropDisabled) ?? ""
                appendMessage(role: .system, content: RunJobURL.notStartedLine(job.name, refusal), to: conversationId)
            } else if job.pausedReason != nil {
                emitCommandOutput("'\(job.name)' is paused (\(job.pausedReason ?? "")); `/jobs resume \(job.name)` first.",
                                  format: .markdown, to: conversationId)
            } else {
                emitCommandOutput("'\(job.name)' is disabled.", format: .markdown, to: conversationId)
            }
            return nil
        }
        // Said before anything is attempted, because admission only answers when the fire is
        // over, and a run can take minutes. Silence in between reads as a command that did
        // nothing.
        let lineId = UUID()
        if byURL {
            appendMessage(role: .system, content: RunJobURL.firingLine(job.name), id: lineId, to: conversationId)
        } else {
            emitCommandOutput("Starting **\(job.name)** …", format: .markdown, to: conversationId)
        }
        let engine = self.engine
        return Task { [weak self] in
            guard let runner = await engine?.jobRunner() else {
                // No engine means no runner and no turn: the app has not finished wiring itself
                // up, or is shutting down. Saying so beats the line above being the last word on
                // a fire that never started.
                self?.finishHandFire(byURL ? RunJobURL.notStartedLine(job.name, JobRunner.runnerUnavailableRefusal)
                                           : "Jobs are not available yet.",
                                     byURL: byURL, lineId: lineId, to: conversationId)
                return nil
            }
            let admission = await runner.fire(job: job, origin: origin, onDecided: onDecided)
            guard let self else { return admission }
            let text: String
            if admission == nil {
                text = byURL ? RunJobURL.notStartedLine(job.name, "it is no longer in the jobs table")
                             : "'\(job.name)' is no longer in the jobs table."
            } else if byURL, let admission {
                text = RunJobURL.admissionLine(job.name, admission)
            } else if let refusal = admission.flatMap(JobRunner.refusalText) {
                text = "**\(job.name)** was not started: \(refusal)."
            } else {
                text = "Fired **\(job.name)**; the result arrives as a card."
            }
            self.finishHandFire(text, byURL: byURL, lineId: lineId, to: conversationId)
            return admission
        }
    }

    private func finishHandFire(_ text: String, byURL: Bool, lineId: UUID, to conversationId: UUID) {
        if byURL {
            updateMessageContent(id: lineId, content: text, in: conversationId, persist: true)
        } else {
            emitCommandOutput(text, format: .markdown, to: conversationId)
        }
    }
}
