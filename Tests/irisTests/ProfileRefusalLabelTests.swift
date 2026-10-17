import Testing
import Foundation
@testable import IrisKit

/// #553: a read-only job's profile refusal is stored as `blockedOnApproval`, but no approval can
/// lift it, so every surface that names the run says `refused by profile` instead. The refusals
/// themselves (no button, `markApproved`, `runApproved`, `executeApprovedCall`) are pinned in
/// `ApproveAndRunTests`; this suite pins the words.
@MainActor
@Suite("Profile refusal label (#553)")
struct ProfileRefusalLabelTests {
    private func run(_ reason: BlockedCall.Reason?, status: JobRun.Status = .blockedOnApproval,
                     tool: String = "write_file", jobId: UUID = UUID()) -> JobRun {
        var run = JobRun(jobId: jobId, jobName: "reader", triggerKind: "schedule", startedAt: Date(),
                         status: status)
        run.blockedTool = tool
        run.blockedCall = reason.map { BlockedCall(toolName: tool, reason: $0) }
        return run
    }

    private func card(_ reason: BlockedCall.Reason?) -> EventCard {
        EventCard(runId: UUID(), jobId: UUID(), jobName: "reader", status: .blockedOnApproval,
                  blockedTool: "write_file", startedAt: Date(), finishedAt: Date(),
                  blockedCall: reason.map { BlockedCall(toolName: "write_file", reason: $0) })
    }

    @Test("only a blocked run whose call the profile refused reads refused by profile")
    func statusText() {
        #expect(JobRun.Status.blockedOnApproval.text(blockedBy: .profile) == "refused by profile")
        #expect(JobRun.Status.blockedOnApproval.text(blockedBy: .approval) == "blocked on approval")
        // A row with no call on it (D2, or one that would not decode) keeps the stored word.
        #expect(JobRun.Status.blockedOnApproval.text(blockedBy: nil) == "blocked on approval")
        for status in [JobRun.Status.running, .completed, .failed, .interrupted] {
            #expect(status.text(blockedBy: .profile) == status.text)
        }
        #expect(run(.profile).statusText == "refused by profile")
        #expect(run(.profile).refusedByProfile)
        #expect(!run(.approval).refusedByProfile)
        #expect(!run(.profile, status: .failed).refusedByProfile)
    }

    @Test("the card's title says refused by profile, and still offers no Approve")
    func card() {
        let refused = card(.profile)
        #expect(refused.headline == "reader · refused by profile: write_file")
        #expect(!refused.offersApproval)
        #expect(card(.approval).headline == "reader · blocked on approval: write_file")
        // Round-tripped, as the transcript stores it: the reason travels with the call.
        let reread = try! #require(EventCard.decode(refused.encodedContent()))
        #expect(reread.statusText == "refused by profile")
    }

    @Test("/jobs, the briefing and the Run Log name the refusal, and it still waits to be acknowledged")
    func listings() {
        let refused = run(.profile)
        #expect(JobsCommand.failureLine(refused).contains(" · refused by profile · "))
        #expect(JobsCommand.failureLine(run(.approval)).contains(" · blocked on approval · "))
        #expect(Briefing.reason(refused, knownTools: ["write_file"]) == "refused by profile: write_file")
        #expect(Briefing.reason(run(.approval), knownTools: ["write_file"]) == "blocked: write_file")
        // An unknown tool name is never echoed, whichever the reason.
        #expect(Briefing.reason(refused, knownTools: []) == "refused by profile")

        let row = RunLogRow.make(refused, transcriptExists: { _ in true })
        #expect(row.statusText == "refused by profile")
        #expect(row.canAcknowledge, "a refusal still waits on a person, to recreate the job or dismiss it")
        #expect(row.opensCard)
    }

    @Test("the daily digest counts refusals apart from waits on approval")
    func digest() {
        let name = "iris-553-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let jobId = UUID()
        let refused = run(.profile, jobId: jobId), blocked = run(.approval, jobId: jobId)
        let text = DailyDigest.outcome(jobs: [], runs: [refused, refused, blocked], failures: [],
                                       tokensToday: [:], config: ConfigManager(store: store))
        #expect(text.contains(", 1 blocked"), "\(text)")
        #expect(text.contains(", 2 refused by profile"), "\(text)")
        let none = DailyDigest.outcome(jobs: [], runs: [blocked], failures: [], tokensToday: [:],
                                       config: ConfigManager(store: store))
        #expect(!none.contains("refused"), "\(none)")
    }

    @Test("the banner does not call a refusal a block")
    func notification() throws {
        let on = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false,
                                     selectedConversationId: nil)
        let refused = try #require(NotificationPolicy.decide(.card(card(.profile), destination: UUID(),
                                                                   jobPausedReason: nil), context: on))
        #expect(refused.body.contains("read-only and was refused"))
        #expect(!refused.body.contains("blocked"))
        let blocked = try #require(NotificationPolicy.decide(.card(card(.approval), destination: UUID(),
                                                                   jobPausedReason: nil), context: on))
        #expect(blocked.body.contains("is blocked on"))
    }

    @Test("the status menu says refused by profile only when every run of the job was refused")
    func menu() {
        let job = UUID()
        func b(_ refused: Bool) -> LedgerAttention.Blocked {
            LedgerAttention.Blocked(runId: UUID(), jobId: job, jobName: "reader", tool: "write_file",
                                    refusedByProfile: refused)
        }
        func text(_ runs: [LedgerAttention.Blocked]) -> String? {
            SurfaceAttention.menuRows(.actionRequired(runs.map { .blocked($0) }), ledger: .empty,
                                      runningCount: 0).first?.text
        }
        #expect(text([b(true), b(true)]) == "reader refused by profile: write_file (×2)")
        #expect(text([b(true), b(false)]) == "reader blocked: write_file (×2)")
        #expect(LedgerAttention.make(unacknowledged: [run(.profile)], paused: []).blocked.first?.refusedByProfile == true)
    }

    @Test("get_job_run and --run-job --json keep the stored status and add why the run stopped")
    func machineOutputs() throws {
        func object(_ json: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let model = try object(IrisEngine.jobRunJSON(run(.profile), outcome: nil, failureReason: nil,
                                                     gateSignal: nil, lastAgentMessage: nil))
        #expect(model["status"] as? String == "blockedOnApproval")
        #expect(model["blockedReason"] as? String == "profile")
        let plain = try object(IrisEngine.jobRunJSON(run(nil, status: .completed), outcome: nil, failureReason: nil,
                                                     gateSignal: nil, lastAgentMessage: nil))
        #expect(plain["blockedReason"] is NSNull)

        let cli = try object(RunJobCLI.renderJSON(row: run(.approval)))
        #expect(cli["status"] as? String == "blockedOnApproval")
        #expect(cli["blockedReason"] as? String == "approval")
        #expect(RunJobCLI.render(row: run(.profile)).contains("status: refused by profile"))
    }
}
