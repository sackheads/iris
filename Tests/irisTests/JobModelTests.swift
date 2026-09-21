import Testing
import Foundation
@testable import iris

@Suite("Job model")
struct JobModelTests {
    @Test("round-trips every trigger kind")
    func roundTrip() throws {
        let triggers: [Trigger] = [
            .schedule(.cron(CronSchedule(expression: "0 9 * * 1-5", timeZone: "America/Los_Angeles"))),
            .schedule(.interval(seconds: 90)),
            .fsEvent(FSWatch(path: "/tmp/x", quietWindowSeconds: 3)),
            .poll(PollSpec(schedule: .interval(seconds: 300), gate: "curl -sI https://example.com")),
        ]
        for t in triggers {
            let data = try JSONEncoder().encode(t)
            #expect(try JSONDecoder().decode(Trigger.self, from: data) == t)
        }
        #expect(triggers.map(\.kind) == ["schedule", "schedule", "fsEvent", "poll"])
    }

    @Test("Job decodes with defaults for absent optional fields")
    func lenientJob() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","prompt":"p","trigger":{"kind":"schedule","schedule":{"kind":"interval","seconds":60}},"createdAt":0}"#
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.profile == .readOnly)
        #expect(job.enabled == true)
        #expect(job.destinationConversationId == nil && job.nextFireAt == nil && job.pausedReason == nil)
    }

    @Test("unknown trigger kind is a decoding error, not a crash")
    func unknownKind() {
        let json = #"{"kind":"telepathy"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Trigger.self, from: Data(json.utf8)) }
    }

    @Test("FSWatch quiet window defaults to 3")
    func fsWatchDefault() throws {
        let w = try JSONDecoder().decode(FSWatch.self, from: Data(#"{"path":"/tmp"}"#.utf8))
        #expect(w.quietWindowSeconds == 3)
    }

    @Test("slug from prompt")
    func slug() {
        #expect(Job.slug(from: "Check the PR queue every morning!") == "check-the-pr-queue")
        #expect(Job.slug(from: "   ") == "job")
        #expect(Job.slug(from: String(repeating: "abcdefghij ", count: 6)) == "abcdefghij-abcdefghij-abcdefghij")
    }

    @Test("interval schedule next fire is after + seconds")
    func intervalNext() {
        let d = Date(timeIntervalSince1970: 1_000_000)
        #expect(Schedule.interval(seconds: 90).next(after: d) == d.addingTimeInterval(90))
    }
}
