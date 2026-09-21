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

    @Test("missing prompt, and a mutating profile with nowhere safe to run it, are refused")
    func refusals() {
        #expect(ScheduleJobArguments.parse(["hour": .int(9)]) == .failure("schedule_job needs a prompt."))
        // Creatable since D3 — but only where the container runtime it always runs in exists.
        // Injected, so the answer does not depend on what this machine has installed.
        let a = try? ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9), "profile": .string("mutating")]).get()
        #expect(a?.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [], sandboxAvailable: false)
                == .failure(ToolMessage(ScheduleJobArguments.noRuntimeForMutating)))
        let made = try? a?.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                   sandboxAvailable: true).get()
        #expect(made?.profile == .mutating)
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

    @Test("a number no Int can hold is unreadable, not a crash")
    func hugeNumbers() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .double(1e30)]).get()
        #expect(a.alias.intervalSeconds == nil)
        #expect(a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []) == .failure("Give a schedule: cron, intervalSeconds, or hour/minute/weekdays."))
    }

    @Test("a weekday that is not a number is refused, not dropped into 'every day'")
    func unreadableWeekdays() {
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "weekdays": .array([.string("monday"), .string("tuesday")])])
                == .failure("Invalid weekday value(s) monday, tuesday: use 1-7 with 1 = Sunday, or a cron expression."))
        // One bad element among good ones still refuses: the good ones alone are not what was asked.
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "weekdays": .array([.int(2), .string("tues")])])
                == .failure("Invalid weekday value(s) tues: use 1-7 with 1 = Sunday, or a cron expression."))
    }

    @Test("the stored job's sentence names its next run, or why it has none")
    func resultSentence() {
        var cron = Job(name: "standup", prompt: "p",
                       trigger: .schedule(.cron(CronSchedule(expression: "0 9 * * 1-5", timeZone: "America/Los_Angeles"))))
        cron.nextFireAt = Date(timeIntervalSince1970: 1_758_470_400)
        #expect(ScheduleJobArguments.resultSentence(for: cron)
                == "Scheduled 'standup' (cron 0 9 * * 1-5 America/Los_Angeles). Next run: 2025-09-21 09:00 America/Los_Angeles.")

        // An interval has no zone of its own, so the fire is written in the user's.
        var interval = Job(name: "ping", prompt: "p", trigger: .schedule(.interval(seconds: 90)))
        interval.nextFireAt = Date(timeIntervalSince1970: 1_758_470_400)
        let sentence = ScheduleJobArguments.resultSentence(for: interval)
        #expect(sentence.hasPrefix("Scheduled 'ping' (every 90 s). Next run: "))
        #expect(sentence.hasSuffix("\(TimeZone.current.identifier)."))

        var dead = Job(name: "leap", prompt: "p",
                       trigger: .schedule(.cron(CronSchedule(expression: "0 0 30 2 *", timeZone: "UTC"))))
        dead.pausedReason = JobScheduler.unmatchableReason
        #expect(ScheduleJobArguments.resultSentence(for: dead)
                == "Saved 'leap' but it will never fire: no matching time in the next four years.")
    }
}
