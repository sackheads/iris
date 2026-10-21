import Testing
import Foundation
@testable import IrisKit

/// #650: the review that approved a gate or script job's script is recorded on the job and shown
/// on its run cards, never in a notification or the model's history line.
@Suite("Script review on the job and its cards (#650)")
struct ScriptReviewTests {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("an approved review returns when and Vibecop's advice; a decline or a DENY returns nothing")
    func reviewResult() async {
        let approved = GateScriptReview(verdict: { _ in VibecopDecision(decision: "APPROVE", reason: "reads one folder") },
                                        ask: { _ in true })
        let review = await approved.review(details: "x\n\nScript:\nls", now: { self.at })
        #expect(review == .success(ScriptReview(approvedAt: at, vibecopAdvice: "approve \u{2014} reads one folder")))

        let off = GateScriptReview(verdict: { _ in nil }, ask: { _ in true })
        #expect(await off.review(details: "x\n\nScript:\nls", now: { self.at }) == .success(ScriptReview(approvedAt: at, vibecopAdvice: nil)))

        let declined = GateScriptReview(verdict: { _ in nil }, ask: { _ in false })
        guard case .failure = await declined.review(details: "x\n\nScript:\nls") else { Issue.record("declined approved"); return }
        let denied = GateScriptReview(verdict: { _ in VibecopDecision(decision: "DENY", reason: "no") }, ask: { _ in true })
        guard case .failure = await denied.review(details: "x\n\nScript:\nls") else { Issue.record("DENY approved"); return }
    }

    @Test("Vibecop's advice is flattened and capped as it's recorded")
    func adviceFlattened() {
        let long = VibecopDecision(decision: "APPROVE", reason: "line one\nline two " + String(repeating: "x", count: 500))
        let advice = ScriptJobs.recordedAdvice(long) ?? ""
        #expect(!advice.isEmpty && !advice.contains("\n") && advice.count <= ScriptJobs.adviceCap + 1, "the cap's ellipsis is the + 1")
    }

    private func job(action: JobAction = .prompt, gate: Gate? = nil, review: ScriptReview? = nil) -> Job {
        let trigger: Trigger = gate.map { .poll(PollSpec(schedule: .interval(seconds: 600), gate: $0)) }
            ?? .schedule(.interval(seconds: 600))
        var job = Job(name: "j", prompt: "p", trigger: trigger, action: action)
        job.policy.scriptReview = review
        return job
    }

    private let spec = ScriptSpec(command: "df -h /", mounts: [], timeoutSeconds: 60, network: false)

    @Test("the card line: approved by you with or without advice, not recorded before this version, none for other jobs")
    func approvalLine() {
        let date = at.formatted(date: .abbreviated, time: .omitted)
        #expect(ScriptJobs.approvalLine(for: job(action: .script(spec), review: ScriptReview(approvedAt: at, vibecopAdvice: "approve \u{2014} fine")))
                == "script approved by you on \(date) (Vibecop advised: approve \u{2014} fine)")
        #expect(ScriptJobs.approvalLine(for: job(action: .script(spec), review: ScriptReview(approvedAt: at, vibecopAdvice: nil)))
                == "script approved by you on \(date)")
        #expect(ScriptJobs.approvalLine(for: job(gate: .script(command: "true", mounts: [], timeoutSeconds: 30, network: false)))
                == "gate script approval not recorded (created before this version)")
        #expect(ScriptJobs.approvalLine(for: job()) == nil, "a prompt job with no script gate")
        #expect(ScriptJobs.approvalLine(for: job(gate: .urlChanged(url: "https://example.invalid"))) == nil)
    }

    @Test("an older policy decodes with no review, and one written round-trips; the fingerprint ignores it")
    func storage() throws {
        let old = try JSONDecoder().decode(JobPolicy.self, from: Data(#"{"overlap":"skip"}"#.utf8))
        #expect(old.scriptReview == nil)
        var policy = JobPolicy()
        policy.scriptReview = ScriptReview(approvedAt: at, vibecopAdvice: "approve")
        let back = try JSONDecoder().decode(JobPolicy.self, from: try JSONEncoder().encode(policy))
        #expect(back.scriptReview == policy.scriptReview)
        // Writing the review leaves the script's fingerprint as it was (planner): it hashes the
        // script's own fields, never the policy.
        let before = job(action: .script(spec)), after = job(action: .script(spec), review: policy.scriptReview)
        #expect(before.action.scriptSpec?.fingerprint == after.action.scriptSpec?.fingerprint)
    }

    @Test("the approval line is on the card, but never in the model's history line or a notification")
    func notInHistoryOrBanner() throws {
        var card = EventCard(runId: UUID(), jobId: UUID(), jobName: "disk", status: .failed, outcome: "exit 1",
                             startedAt: at, finishedAt: at)
        card.scriptApproval = "script approved by you on today (Vibecop advised: SECRET-ADVICE)"
        #expect(!card.historyLine.contains("SECRET-ADVICE"))
        let context = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false, selectedConversationId: nil)
        if let banner = NotificationPolicy.decide(.card(card, destination: UUID(), jobPausedReason: "paused"), context: context) {
            #expect(!"\(banner)".contains("SECRET-ADVICE"))
        }
        let decoded = try JSONDecoder().decode(EventCard.self, from: try JSONEncoder().encode(card))
        #expect(decoded.scriptApproval == card.scriptApproval)
    }
}
