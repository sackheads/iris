import Testing
import Foundation
@testable import iris

@Suite("schedule_job arguments")
struct ScheduleJobArgumentsTests {
    @Test("old-style arguments still parse; numbers may arrive as strings or doubles")
    func oldStyle() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("stand-up"), "hour": .string("9"), "minute": .double(30), "weekdays": .array([.int(2), .string("3")])]).get()
        #expect(a.alias == ScheduleAlias(minute: 30, hour: 9, weekdays: [2, 3]))
        #expect(a.name == nil && a.profile == nil)
    }

    @Test("new-style cron + timezone + name")
    func newStyle() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("p"), "cron": .string("*/5 * * * *"), "timezone": .string("Asia/Tokyo"), "name": .string("Five Min")]).get()
        #expect(a.alias.cron == "*/5 * * * *" && a.alias.timeZone == "Asia/Tokyo" && a.name == "Five Min")
    }

    @Test("missing prompt and mutating profile are refused with a message")
    func refusals() {
        #expect(ScheduleJobArguments.parse(["hour": .int(9)]) == .failure("schedule_job needs a prompt."))
        let a = try? ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9), "profile": .string("mutating")]).get()
        #expect(a?.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []) == .failure("mutating jobs arrive with deliverable 3; create the job without a profile to run it read-only."))
    }

    @Test("name is slugged and made unique against existing names")
    func naming() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("Check the PR queue"), "hour": .int(9)]).get()
        let j1 = try a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []).get()
        #expect(j1.name == "check-the-pr-queue")
        let j2 = try a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: ["check-the-pr-queue"]).get()
        #expect(j2.name == "check-the-pr-queue-2")
        let named = try ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9), "name": .string("My Job!")]).get()
        #expect(try named.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []).get().name == "my-job")
    }

    @Test("alias failures become model-readable messages")
    func aliasFailure() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("p"), "weekdays": .array([.int(9)]), "hour": .int(9)]).get()
        #expect(a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []) == .failure("Invalid weekday value(s) 9: use 1-7 with 1 = Sunday, or a cron expression."))
    }
}
