import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 9-11: the URL opt-in and its token digest have one writer, `setURLTrigger`.
/// `upsert` never writes them, and clears both when a job's prompt, profile or policy changes,
/// which covers both model rewrite paths at once.
@Suite("URL trigger in the ledger (D6)")
struct URLTriggerLedgerTests {
    private func makeLedger() throws -> JobLedger { try ConversationStore.inMemory().ledger }

    private func job(_ name: String = "pr-sweep") -> Job {
        Job(name: name, prompt: "sweep the PRs", trigger: .schedule(.interval(seconds: 60)))
    }

    @Test("a row and a JSON value written before D6 read back off, with no digest")
    func preD6ReadsOff() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)   // upsert never writes the column, so it is NULL, as on every older row
        #expect(try l.job(id: j.id)?.urlTrigger == false)

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as? [String: Any])
        object.removeValue(forKey: "urlTrigger")
        let old = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.urlTrigger == false, "invariant 1: a missing key decodes, it does not throw")
    }

    @Test("setURLTrigger writes the flag with the digest, rotates it, and turns both off")
    func setRotateOff() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)
        try l.setURLTrigger(jobId: j.id, tokenHash: "digest-1")
        #expect(try l.job(id: j.id)?.urlTrigger == true)
        #expect(try l.job(urlTokenHash: "digest-1")?.id == j.id)

        try l.setURLTrigger(jobId: j.id, tokenHash: "digest-2")
        #expect(try l.job(urlTokenHash: "digest-1") == nil, "a rotated-out digest finds nothing")

        try l.setURLTrigger(jobId: j.id, tokenHash: nil)
        #expect(try l.job(id: j.id)?.urlTrigger == false)
        #expect(try l.job(urlTokenHash: "digest-2") == nil)
        let nobody = UUID()
        #expect(throws: JobLedgerError.unknownJob(nobody)) { try l.setURLTrigger(jobId: nobody, tokenHash: "x") }
    }

    @Test("two jobs can never share a digest")
    func digestIsUnique() throws {
        let l = try makeLedger()
        let a = job("a"), b = job("b")
        try l.upsert(a)
        try l.upsert(b)
        try l.setURLTrigger(jobId: a.id, tokenHash: "same")
        #expect(throws: (any Error).self) { try l.setURLTrigger(jobId: b.id, tokenHash: "same") }
        // The refused write changed nothing on either side.
        #expect(try l.job(id: b.id)?.urlTrigger == false)
        #expect(try l.job(id: a.id)?.urlTrigger == true)
        #expect(try l.job(urlTokenHash: "same")?.id == a.id)
    }

    @Test("an empty digest is refused, and leaves the job as it was")
    func emptyDigestRefused() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)
        try l.setURLTrigger(jobId: j.id, tokenHash: "d")
        #expect(throws: JobLedgerError.emptyURLTokenHash) { try l.setURLTrigger(jobId: j.id, tokenHash: "") }
        #expect(try l.job(urlTokenHash: "d")?.id == j.id)
        #expect(try l.job(urlTokenHash: "") == nil)
    }

    @Test("a stale copy written back, and a new trigger alone, keep the flag")
    func staleCopyAndRescheduleKeep() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)
        try l.setURLTrigger(jobId: j.id, tokenHash: "d")

        var stale = j   // its urlTrigger is false: the copy predates the opt-in
        stale.nextFireAt = Date()
        #expect(try l.upsert(stale).urlTriggerCleared == false)

        var moved = try #require(try l.job(id: j.id))
        moved.trigger = .schedule(.cron(CronSchedule(expression: "0 9 * * *", timeZone: "UTC")))
        #expect(try l.upsert(moved).urlTriggerCleared == false, "/jobs reschedule changes only the trigger")
        #expect(try l.job(urlTokenHash: "d")?.id == j.id)
    }

    @Test("a changed prompt, profile, grant or budget clears the flag and the digest, and says so")
    func anyChangeClears() throws {
        let edits: [(String, (inout Job) -> Void)] = [
            ("prompt", { $0.prompt = "sweep the PRs and merge them" }),
            ("profile", { $0.profile = .mutating }),
            ("grant", { $0.policy.grants = JobGrant(mounts: [], network: true) }),
            ("daily budget", { $0.policy.dailyTokenBudget = 9_000_000 }),
            ("per-run budget", { $0.policy.perRunTokenBudget = 900_000 }),
            ("breaker", { $0.policy.maxRunsPerHour = 60 }),
        ]
        for (label, edit) in edits {
            let l = try makeLedger()
            let j = job()
            try l.upsert(j)
            try l.setURLTrigger(jobId: j.id, tokenHash: "d")
            var changed = try #require(try l.job(id: j.id))
            edit(&changed)

            #expect(try l.upsert(changed).urlTriggerCleared, Comment(rawValue: label))
            #expect(try l.job(id: j.id)?.urlTrigger == false, Comment(rawValue: label))
            #expect(try l.job(urlTokenHash: "d") == nil, Comment(rawValue: label))
        }
    }

    @Test("a change to a job that never had the trigger clears nothing")
    func changeWithoutTrigger() throws {
        let l = try makeLedger()
        var j = job()
        try l.upsert(j)
        j.prompt = "something else"
        #expect(try l.upsert(j).urlTriggerCleared == false)
    }

    @Test("urlFires counts only this job's url rows since the given time")
    func urlFiresCounts() throws {
        let l = try makeLedger()
        let j = job(), other = job("other")
        try l.upsert(j)
        try l.upsert(other)
        let now = Date()
        for (owner, kind, ago) in [(j, "url", 60.0), (j, "url", 120), (j, "manual", 60), (other, "url", 60), (j, "url", 7_200)] {
            try l.begin(run: JobRun(jobId: owner.id, jobName: owner.name, triggerKind: kind,
                                    startedAt: now.addingTimeInterval(-ago)))
        }
        #expect(try l.urlFires(jobId: j.id, since: now.addingTimeInterval(-3_600)) == 2)
    }
}
