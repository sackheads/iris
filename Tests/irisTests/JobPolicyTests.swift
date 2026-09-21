import Testing
import Foundation
@testable import iris

/// The pure half of deliverable 3's data layer (#187): `JobPolicy`, `Gate`, `BlockedCall`, and the
/// three new `Job` fields. Everything here is codec behaviour — the leniency that keeps a row
/// written by an older build readable (invariant 1).
@Suite("JobPolicy")
struct JobPolicyTests {
    let decoder = JSONDecoder()

    func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: JobPolicy

    @Test("an empty object decodes to every default")
    func emptyObjectIsDefault() throws {
        let policy = try decoder.decode(JobPolicy.self, from: Data("{}".utf8))
        #expect(policy == JobPolicy())
        #expect(policy.overlap == .skip)
        #expect(policy.catchUp == .coalesce)
        #expect(policy.runTimeoutSeconds == 600)
        #expect(policy.perRunTokenBudget == nil)
        #expect(policy.dailyTokenBudget == nil)
        #expect(policy.maxRunsPerHour == nil)
        #expect(policy.retry == true)
    }

    @Test("a fully populated policy round-trips")
    func roundTrip() throws {
        let policy = JobPolicy(overlap: .queue, catchUp: .replay(cap: 3), runTimeoutSeconds: 90,
                               perRunTokenBudget: 1_000, dailyTokenBudget: 2_000,
                               maxRunsPerHour: 4, retry: false)
        #expect(try decoder.decode(JobPolicy.self, from: Data(encodedJSON(policy).utf8)) == policy)
    }

    @Test("a negative limit decodes as unset, not as unlimited")
    func negativeLimitsDecodeAsUnset() throws {
        let policy = try decoder.decode(JobPolicy.self, from: Data(#"""
            {"runTimeoutSeconds":-1,"perRunTokenBudget":-1,"dailyTokenBudget":-5,"maxRunsPerHour":-99}
            """#.utf8))
        // `nil` is "take the global default", which is what a missing key means too. Reading -1 as
        // "no budget" would take a job's ceiling off on a typo.
        #expect(policy.perRunTokenBudget == nil)
        #expect(policy.dailyTokenBudget == nil)
        #expect(policy.maxRunsPerHour == nil)
        #expect(policy.runTimeoutSeconds == JobPolicy().runTimeoutSeconds,
                "and the timeout falls back to the default, which resolve reads as unset")

        // Zero is a different answer and is kept: it means unbounded for a budget on purpose.
        let zeroes = try decoder.decode(JobPolicy.self, from: Data(#"""
            {"perRunTokenBudget":0,"dailyTokenBudget":0,"maxRunsPerHour":0}
            """#.utf8))
        #expect(zeroes.perRunTokenBudget == 0)
        #expect(zeroes.dailyTokenBudget == 0)
        #expect(zeroes.maxRunsPerHour == 0)
    }

    @Test("an unknown overlap decodes as skip rather than failing the row")
    func unknownOverlap() throws {
        let policy = try decoder.decode(JobPolicy.self, from: Data(#"{"overlap":"stampede"}"#.utf8))
        #expect(policy.overlap == .skip)
    }

    // MARK: JobPolicy.CatchUp

    @Test("catchUp encodes as kind plus cap")
    func catchUpEncoding() throws {
        #expect(try encodedJSON(JobPolicy.CatchUp.coalesce) == #"{"kind":"coalesce"}"#)
        #expect(try encodedJSON(JobPolicy.CatchUp.skip) == #"{"kind":"skip"}"#)
        #expect(try encodedJSON(JobPolicy.CatchUp.replay(cap: 7)) == #"{"cap":7,"kind":"replay"}"#)
    }

    @Test("every catchUp case round-trips")
    func catchUpRoundTrip() throws {
        for value in [JobPolicy.CatchUp.coalesce, .skip, .replay(cap: 2)] {
            #expect(try decoder.decode(JobPolicy.CatchUp.self, from: Data(encodedJSON(value).utf8)) == value)
        }
    }

    @Test("an unknown catchUp kind decodes as coalesce, and replay without a cap takes the default")
    func catchUpLenient() throws {
        #expect(try decoder.decode(JobPolicy.CatchUp.self, from: Data(#"{"kind":"teleport"}"#.utf8)) == .coalesce)
        #expect(try decoder.decode(JobPolicy.CatchUp.self, from: Data("{}".utf8)) == .coalesce)
        #expect(try decoder.decode(JobPolicy.CatchUp.self, from: Data(#"{"kind":"replay"}"#.utf8))
                == .replay(cap: JobPolicy.defaultReplayCap))
    }

    // MARK: Job

    @Test("a Job written before the policy fields decodes with the defaults")
    func jobWithoutPolicy() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","prompt":"p","trigger":{"kind":"schedule","schedule":{"kind":"interval","seconds":60}},"createdAt":0}"#
        let job = try decoder.decode(Job.self, from: Data(json.utf8))
        #expect(job.policy == JobPolicy())
        #expect(job.retryAttempt == 0)
        #expect(job.queuedFire == nil)
    }

    @Test("the policy fields round-trip on a Job")
    func jobWithPolicy() throws {
        var job = Job(name: "n", prompt: "p", trigger: .schedule(.interval(seconds: 60)),
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        job.policy = JobPolicy(overlap: .queue, catchUp: .replay(cap: 5))
        job.retryAttempt = 2
        job.queuedFire = Date(timeIntervalSince1970: 1_700_000_100)
        #expect(try decoder.decode(Job.self, from: Data(encodedJSON(job).utf8)) == job)
    }

    // MARK: Gate

    @Test("every gate case round-trips")
    func gateRoundTrip() throws {
        let gates: [Gate] = [
            .urlChanged(url: "https://example.com/feed"),
            .pathChanged(path: "/tmp/watched"),
            .script(command: "diff -q a b", mounts: ["/tmp/a", "/tmp/b"], timeoutSeconds: 30),
        ]
        for gate in gates {
            #expect(try decoder.decode(Gate.self, from: Data(encodedJSON(gate).utf8)) == gate)
        }
    }

    @Test("an unknown gate kind fails to decode rather than guessing")
    func gateUnknownKind() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Gate.self, from: Data(#"{"kind":"vibes"}"#.utf8))
        }
    }

    // MARK: PollSpec

    @Test("a PollSpec whose gate is the old bare string decodes as a script gate")
    func legacyStringGate() throws {
        let json = #"{"schedule":{"kind":"interval","seconds":300},"gate":"curl -sI https://example.com"}"#
        let spec = try decoder.decode(PollSpec.self, from: Data(json.utf8))
        #expect(spec.schedule == .interval(seconds: 300))
        #expect(spec.gate == .script(command: "curl -sI https://example.com", mounts: [],
                                     timeoutSeconds: PollSpec.legacyGateTimeoutSeconds))
    }

    @Test("a legacy poll trigger still decodes through Trigger")
    func legacyTriggerGate() throws {
        let json = #"{"kind":"poll","poll":{"schedule":{"kind":"interval","seconds":60},"gate":"test -f /tmp/x"}}"#
        let trigger = try decoder.decode(Trigger.self, from: Data(json.utf8))
        #expect(trigger == .poll(PollSpec(schedule: .interval(seconds: 60),
                                          gate: .script(command: "test -f /tmp/x", mounts: [],
                                                        timeoutSeconds: PollSpec.legacyGateTimeoutSeconds))))
    }

    @Test("a PollSpec with a structured gate round-trips")
    func structuredGate() throws {
        let spec = PollSpec(schedule: .interval(seconds: 120), gate: .urlChanged(url: "https://example.com"))
        #expect(try decoder.decode(PollSpec.self, from: Data(encodedJSON(spec).utf8)) == spec)
    }

    // MARK: BlockedCall

    @Test("a BlockedCall round-trips with its arguments intact")
    func blockedCallRoundTrip() throws {
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string("/tmp/x"), "content": .string("hi"), "n": .int(3)],
                               cwd: "/tmp", reason: .profile, at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try decoder.decode(BlockedCall.self, from: Data(encodedJSON(call).utf8)) == call)
    }

    @Test("a BlockedCall missing every optional key decodes leniently")
    func blockedCallLenient() throws {
        let call = try decoder.decode(BlockedCall.self, from: Data(#"{"toolName":"run_command"}"#.utf8))
        #expect(call.toolName == "run_command")
        #expect(call.args.isEmpty)
        #expect(call.cwd == nil)
        #expect(call.reason == .approval)
        #expect(call.at == Date(timeIntervalSince1970: 0))
    }

    @Test("an unknown BlockedCall reason reads as approval")
    func blockedCallUnknownReason() throws {
        let call = try decoder.decode(BlockedCall.self,
                                      from: Data(#"{"toolName":"t","reason":"telepathy"}"#.utf8))
        #expect(call.reason == .approval)
    }
}
