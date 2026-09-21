import Testing
import Foundation
@testable import iris

/// #187 §10 — the half of retention that `JobLedgerTests` cannot cover: `pruneDecision` is a pure
/// function over rows, but the transcripts it names are *conversations*, and deleting those is the
/// engine's job. What is tested here is the application of the decision — that the right
/// conversations go, that the exemptions survive the round trip, and that a ledger row pointing at
/// a conversation the user can see never takes it down with it.
@MainActor
@Suite("Retention (#187 §10)")
struct RetentionTests {

    private func makeEngine(_ state: AppState) -> IrisEngine {
        IrisEngine(state: state, client: FakeLLMClient(responses: []), protectionEnabled: false,
                   sessionPeerCount: 0)
    }

    /// A finished run started `at`, with a conversation of its own as its transcript. Returns the
    /// row as stored, so a caller can name the transcript it should (or should not) still find.
    @discardableResult
    private func seedRun(state: AppState, ledger: JobLedger, job: Job, at: Date,
                         status: JobRun.Status = .completed,
                         background: Bool = true) throws -> JobRun {
        let transcript = state.createNewConversation(isBackground: background,
                                                     title: "\(job.name) · \(at.timeIntervalSince1970)",
                                                     select: false)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: at,
                         transcriptConversationId: transcript)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: status, outcome: "ok", failureReason: nil,
                          blockedTool: nil, tokens: TokenUsage(), finishedAt: at.addingTimeInterval(1))
        return try #require(try ledger.run(id: run.id))
    }

    private func fixture() throws -> (AppState, JobLedger, Job) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned)
        let job = Job(name: "pr-sweep", prompt: "sweep", trigger: .schedule(.interval(seconds: 3600)))
        try store.ledger.upsert(job)
        return (state, store.ledger, job)
    }

    @Test("a job past the transcript cap loses its oldest transcripts, and only those")
    func transcriptCap() async throws {
        let (state, ledger, job) = try fixture()
        // Inside the 90-day window, so this exercises the transcript cap alone: `prune` is
        // called with the real clock, and a fixed epoch date would age every row out instead.
        let start = Date().addingTimeInterval(-40 * 86_400)
        var runs: [JobRun] = []
        for i in 0..<22 {
            runs.append(try seedRun(state: state, ledger: ledger, job: job,
                                    at: start.addingTimeInterval(Double(i) * 3600)))
        }
        let selected = state.selectedConversationId

        await makeEngine(state).applyRetention(ledger: ledger)

        let surviving = Set(state.conversations.map(\.id))
        for run in runs.prefix(2) {
            #expect(!surviving.contains(try #require(run.transcriptConversationId)),
                    "the two oldest transcripts are past the 20-run cap")
        }
        for run in runs.dropFirst(2) {
            #expect(surviving.contains(try #require(run.transcriptConversationId)))
        }
        #expect(state.conversations.filter(\.isBackground).count == 20)
        // Nothing the user was looking at moved: the deleted ids were never selected.
        #expect(state.selectedConversationId == selected)
        // Rows are young, so none of them aged out.
        #expect(try ledger.runCount(jobId: job.id) == 22)
    }

    @Test("an unacknowledged failure keeps its transcript past the cap")
    func unacknowledgedFailureIsExempt() async throws {
        let (state, ledger, job) = try fixture()
        let start = Date().addingTimeInterval(-40 * 86_400)   // inside the 90-day window
        var runs: [JobRun] = []
        for i in 0..<22 {
            runs.append(try seedRun(state: state, ledger: ledger, job: job,
                                    at: start.addingTimeInterval(Double(i) * 3600),
                                    status: i == 0 ? .failed : .completed))
        }

        await makeEngine(state).applyRetention(ledger: ledger)

        let surviving = Set(state.conversations.map(\.id))
        #expect(surviving.contains(try #require(runs[0].transcriptConversationId)),
                "nobody has seen this failure yet, so its evidence stays")
        #expect(!surviving.contains(try #require(runs[1].transcriptConversationId)),
                "the next-oldest goes in its place")
        #expect(state.conversations.filter(\.isBackground).count == 21)
    }

    @Test("a transcript id naming a conversation the user can see is never deleted")
    func userFacingTranscriptIsNeverDeleted() async throws {
        let (state, ledger, job) = try fixture()
        let start = Date().addingTimeInterval(-40 * 86_400)   // inside the 90-day window
        var runs: [JobRun] = []
        for i in 0..<22 {
            runs.append(try seedRun(state: state, ledger: ledger, job: job,
                                    at: start.addingTimeInterval(Double(i) * 3600),
                                    background: i != 0))
        }
        let visible = try #require(runs[0].transcriptConversationId)
        state.selectedConversationId = visible

        await makeEngine(state).applyRetention(ledger: ledger)

        #expect(state.conversations.contains { $0.id == visible },
                "a foreground conversation is the user's, whatever the ledger points at")
        #expect(state.selectedConversationId == visible)
        #expect(!state.conversations.contains { $0.id == runs[1].transcriptConversationId })
    }

    @Test("rows past the retention window are deleted with their transcripts")
    func rowRetention() async throws {
        let (state, ledger, job) = try fixture()
        let now = Date()
        let ancient = try seedRun(state: state, ledger: ledger, job: job,
                                  at: now.addingTimeInterval(-100 * 86_400))
        let recent = try seedRun(state: state, ledger: ledger, job: job,
                                 at: now.addingTimeInterval(-1 * 86_400))

        await makeEngine(state).applyRetention(ledger: ledger)

        #expect(try ledger.run(id: ancient.id) == nil, "older than 90 days")
        #expect(try ledger.run(id: recent.id) != nil)
        #expect(!state.conversations.contains { $0.id == ancient.transcriptConversationId })
        #expect(state.conversations.contains { $0.id == recent.transcriptConversationId })
    }
}
