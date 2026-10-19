import Testing
import Foundation
@testable import IrisKit

/// #263: a job's own run timeout, set with `schedule_job`'s `timeout_seconds`.
@Suite("Per-job run timeout (#263)")
struct JobRunTimeoutTests {
    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-runtimeout-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func job(_ policy: JobPolicy) -> Job {
        Job(name: "t", prompt: "p", trigger: .schedule(.interval(seconds: 60)), policy: policy)
    }

    // MARK: Resolution

    @Test("the override wins over the global setting, 600 included; without one, the legacy sentinel rule is unchanged")
    func resolution() {
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobRunTimeoutSeconds = 120

        // The sentinel case: every stored policy holds runTimeoutSeconds 600 and no override.
        #expect(JobLimits.resolve(job: job(JobPolicy()), config: config).runTimeoutSeconds == 120)
        #expect(JobLimits.resolve(job: job(JobPolicy(runTimeoutSeconds: 30)), config: config).runTimeoutSeconds == 30,
                "a hand-edited legacy figure still counts")

        #expect(JobLimits.resolve(job: job(JobPolicy(runTimeoutOverride: 600)), config: config).runTimeoutSeconds == 600,
                "an override can pin the figure the legacy key cannot")
        #expect(JobLimits.resolve(job: job(JobPolicy(runTimeoutSeconds: 30, runTimeoutOverride: 1_800)),
                                  config: config).runTimeoutSeconds == 1_800)
    }

    // MARK: Codec (invariant 1)

    @Test("an old policy row has no override; a non-positive or unreadable one decodes as none; one round-trips")
    func codec() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(JobPolicy.self, from: Data(#"{"overlap":"queue","runTimeoutSeconds":600}"#.utf8))
        #expect(old.runTimeoutOverride == nil && old.overlap == .queue)
        for raw in [#"{"runTimeoutOverride":0}"#, #"{"runTimeoutOverride":-5}"#, #"{"runTimeoutOverride":"long"}"#] {
            #expect(try decoder.decode(JobPolicy.self, from: Data(raw.utf8)).runTimeoutOverride == nil, "\(raw)")
        }
        let set = JobPolicy(runTimeoutOverride: 1_800)
        #expect(try decoder.decode(JobPolicy.self, from: JSONEncoder().encode(set)) == set)
        // Nothing written when there is no override, so an older build's view is unchanged.
        #expect(!String(decoding: try JSONEncoder().encode(JobPolicy()), as: UTF8.self).contains("runTimeoutOverride"))
    }

    // MARK: Parsing

    @Test("timeout_seconds is clamped to 60-3600 with a note, non-positive takes the global with a note, a fraction is refused")
    func parsing() throws {
        func parse(_ value: JSONValue) -> Result<ScheduleJobArguments, ToolMessage> {
            ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9), "timeout_seconds": value])
        }
        let plain = try parse(.int(1_800)).get()
        #expect(plain.runTimeoutSeconds == 1_800 && plain.notes.isEmpty)
        #expect(try parse(.string("900")).get().runTimeoutSeconds == 900)

        let low = try parse(.int(30)).get()
        #expect(low.runTimeoutSeconds == 60)
        #expect(low.notes == ["The run timeout was set to 60 seconds rather than the 30 asked for; a job's own timeout must be 60-3600 seconds."])
        let high = try parse(.int(36_000)).get()
        #expect(high.runTimeoutSeconds == 3_600 && high.notes.count == 1)

        let zero = try parse(.int(0)).get()
        #expect(zero.runTimeoutSeconds == nil)
        #expect(zero.notes == ["timeout_seconds must be positive, so this job uses the global run timeout."])

        #expect(parse(.double(90.5)) == .failure(ScheduleJobArguments.timeoutShape))
        #expect(parse(.string("an hour")) == .failure(ScheduleJobArguments.timeoutShape))
        #expect(try ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9)]).get().runTimeoutSeconds == nil)
    }

    @Test("makeJob stores the override, and the answer names it beside the global whenever they differ")
    func storedAndSaid() throws {
        let args = try ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9),
                                                   "timeout_seconds": .int(1_800)]).get()
        let made = try args.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []).get()
        #expect(made.policy.runTimeoutOverride == 1_800)
        #expect(made.policy.runTimeoutSeconds == 600, "the legacy key is left at its default")
        #expect(ScheduleJobArguments.resultSentence(for: made, globalRunTimeoutSeconds: 600)
            .contains("Run timeout: 30 min (global 10 min)."))
        #expect(ScheduleJobArguments.resultSentence(for: made, globalRunTimeoutSeconds: 1_800)
            .contains("Run timeout: 30 min."))

        let none = try ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9)]).get()
            .makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []).get()
        #expect(none.policy.runTimeoutOverride == nil)
        #expect(!ScheduleJobArguments.resultSentence(for: none).contains("Run timeout"))
        #expect(JobPolicy.durationText(90) == "90 s")
    }

    @Test("the pinned/tainted approval dialog shows the clamped timeout beside the global")
    func approvalLine() {
        let details = IrisEngine.jobApprovalDetails(toolName: "schedule_job", args: [
            "prompt": .string("p"), "intervalSeconds": .int(3600), "timeout_seconds": .int(99_999),
        ], globalRunTimeoutSeconds: 600)
        #expect(details.contains("Run timeout: 60 min (global 10 min)."))
        let none = IrisEngine.jobApprovalDetails(toolName: "schedule_job", args: [
            "prompt": .string("p"), "intervalSeconds": .int(3600),
        ], globalRunTimeoutSeconds: 600)
        #expect(!none.contains("Run timeout"))
    }

    @Test("/jobs shows a job's own timeout in the policy column")
    func policyColumn() {
        #expect(JobsCommand.policySummary(for: job(JobPolicy(runTimeoutOverride: 1_800))) == "timeout 30 min")
        #expect(JobsCommand.policySummary(for: job(JobPolicy())) == "default")
    }

    // MARK: Re-schedule

    @MainActor
    @Test("re-scheduling the same name without timeout_seconds returns the job to the global setting")
    func rescheduleResets() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let conversation = UUID()
        state.createNewConversation(id: conversation)
        state.selectedConversationId = conversation
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        func schedule(_ extra: [String: JSONValue]) async -> String {
            var args: [String: JSONValue] = ["prompt": .string("sweep"), "name": .string("sweep"),
                                             "intervalSeconds": .int(3600)]
            for (k, v) in extra { args[k] = v }
            return await engine.scheduleJob(ScheduleJobArguments.parse(args), conversationId: conversation,
                                            globalRunTimeoutSeconds: 600)
        }
        let first = await schedule(["timeout_seconds": .int(1_800)])
        #expect(first.contains("Run timeout: 30 min (global 10 min)."))
        #expect(try store.ledger.jobs().first?.policy.runTimeoutOverride == 1_800)

        let second = await schedule([:])
        #expect(second.contains(ScheduleJobArguments.replacedNote("sweep")))
        let jobs = try store.ledger.jobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.policy.runTimeoutOverride == nil)
        #expect(!second.contains("Run timeout"))
    }
}
