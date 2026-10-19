import Testing
import Foundation
@testable import IrisKit

/// #687: a gate script has no internet unless it asks (`gate_network`), every gate script is
/// reviewed by a person (Vibecop advises), and existing gates go network-off at upgrade with one
/// notice. "Off" is the isolated network, which is host-only (#690), and every text says so.
@Suite(.timeLimit(.minutes(1)))
struct GateNetworkTests {
    private func scriptGate(network: Bool? = nil, script: Bool = true) -> Result<ScheduleJobArguments, ToolMessage> {
        var args: [String: JSONValue] = ["prompt": .string("watch"), "intervalSeconds": .int(600)]
        if script { args["gate_script"] = .string("echo CHANGED") }
        if let network { args["gate_network"] = .bool(network) }
        return ScheduleJobArguments.parse(args)
    }

    @Test("a stored gate from before #687 decodes network-off, and the flag round-trips")
    func decoding() throws {
        let old = #"{"kind":"script","command":"echo CHANGED","mounts":[],"timeoutSeconds":60}"#
        let decoded = try JSONDecoder().decode(Gate.self, from: Data(old.utf8))
        #expect(decoded == .script(command: "echo CHANGED", mounts: [], timeoutSeconds: 60, network: false))
        let on = Gate.script(command: "curl x", mounts: [], timeoutSeconds: 30, network: true)
        #expect(try JSONDecoder().decode(Gate.self, from: JSONEncoder().encode(on)) == on)
    }

    @Test("gate_network is parsed, defaults off, and needs a gate_script")
    func parsing() throws {
        let off = try #require(try scriptGate().get().resolvedGate(sandboxAvailable: true).get())
        #expect(off == .script(command: "echo CHANGED", mounts: [], timeoutSeconds: GateEvaluator.defaultTimeoutSeconds, network: false))
        let on = try #require(try scriptGate(network: true).get().resolvedGate(sandboxAvailable: true).get())
        guard case .script(_, _, _, true) = on else { Issue.record("expected network on, got \(on)"); return }
        let alone = try scriptGate(network: true, script: false).get().resolvedGate(sandboxAvailable: true)
        guard case .failure(let message) = alone else { Issue.record("gate_network without a script was accepted"); return }
        #expect(message.text.contains("gate_network"))
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                            "gate_script": .string("x"), "gate_network": .string("maybe")]).isFailure)
    }

    @Test("off makes the isolated network first and runs on it; on runs on the default network")
    func evaluationNetwork() async {
        let offRuntime = GateRuntime()
        _ = await GateEvaluator.evaluate(.script(command: "echo CHANGED", mounts: [], timeoutSeconds: 10),
                                         previous: nil, runtime: offRuntime, image: "img")
        #expect(offRuntime.ensuredNetworks == [NetworkMode.isolatedNetworkName])
        #expect(offRuntime.networks == [.isolated])
        let onRuntime = GateRuntime()
        _ = await GateEvaluator.evaluate(.script(command: "echo CHANGED", mounts: [], timeoutSeconds: 10, network: true),
                                         previous: nil, runtime: onRuntime, image: "img")
        #expect(onRuntime.ensuredNetworks.isEmpty)
        #expect(onRuntime.networks == [.default])
    }

    @Test("an isolated network that can't be made is a gate error, and nothing starts")
    func networkFailure() async {
        let runtime = GateRuntime()
        runtime.networkError = ContainerRuntimeError.networkFailed("no daemon")
        let result = await GateEvaluator.evaluate(.script(command: "echo CHANGED", mounts: [], timeoutSeconds: 10),
                                                  previous: nil, runtime: runtime, image: "img")
        guard case .error(let detail) = result else { Issue.record("expected an error, got \(result)"); return }
        #expect(detail.contains("isolated network"))
        #expect(runtime.creates.isEmpty, "never falls back to the default network")
    }

    @Test("the review says what the network means, in words, for each combination")
    func reviewText() {
        let off = GateScriptReview.details(script: "s", mounts: [], timeoutSeconds: 60, network: false)
        #expect(off.contains("Network: off (host-only)") && off.contains("can still reach services on this Mac"))
        let onWithMount = GateScriptReview.details(script: "s", mounts: ["/Users/me/p:/in:ro"], timeoutSeconds: 60, network: true)
        #expect(onWithMount.contains("send what it reads anywhere"))
        let onAlone = GateScriptReview.details(script: "s", mounts: [], timeoutSeconds: 60, network: true)
        #expect(onAlone.contains("download and run more code") && !onAlone.contains("send what it reads"))
        #expect(onAlone.hasSuffix("Script:\ns"), "the script still comes last")
    }

    private func job(_ name: String, gate: Gate?) -> Job {
        let trigger: Trigger = gate.map { .poll(PollSpec(schedule: .interval(seconds: 600), gate: $0)) }
            ?? .schedule(.interval(seconds: 600))
        return Job(name: name, prompt: "p", trigger: trigger)
    }

    @Test("the upgrade pauses every script-gate job once, names them, and a second launch does nothing")
    func upgradeNotice() throws {
        let name = "iris-687-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let jobs = [
            job("zeta", gate: .script(command: "x", mounts: [], timeoutSeconds: 60)),
            job("alpha", gate: .script(command: "y", mounts: [], timeoutSeconds: 60)),
            job("url", gate: .urlChanged(url: "https://example.com")),
            job("plain", gate: nil),
        ]
        let paused = Locked<[UUID]>([])
        let pause: (UUID) -> Void = { id in paused.mutate { $0.append(id) } }
        let notice = try #require(AppState.gateNetworkNotice(jobs: jobs, defaults: defaults, pause: pause))
        #expect(notice.contains("alpha, zeta"), "names only script gates, sorted")
        #expect(!notice.contains("url") && !notice.contains("plain"))
        #expect(notice.contains("Vibecop's review alone") && notice.contains("schedule it again"))
        #expect(notice.contains("gate_network: true") && notice.contains("services on this Mac"))
        #expect(Set(paused.value) == Set([jobs[0].id, jobs[1].id]), "every script-gate job pauses, nothing else")
        #expect(AppState.gateNetworkNotice(jobs: jobs, defaults: defaults, pause: pause) == nil, "idempotent")
        #expect(paused.value.count == 2, "a second launch pauses nothing")
    }

    @Test("with no script gates the notice says nothing, and still never runs again")
    func upgradeNoticeNothingToSay() throws {
        let name = "iris-687b-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        #expect(AppState.gateNetworkNotice(jobs: [], defaults: defaults, pause: { _ in }) == nil)
        let later = [job("late", gate: .script(command: "x", mounts: [], timeoutSeconds: 60))]
        #expect(AppState.gateNetworkNotice(jobs: later, defaults: defaults,
                                           pause: { _ in Issue.record("a gate made after the upgrade was reviewed; it never pauses") }) == nil)
    }
}

/// The upgrade through a real launch: a stored script-gate job pauses, the notice lands in the
/// selected conversation, and a second launch over the same store and defaults does nothing.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GateUpgradeLaunchTests {
    @Test("a launch pauses the stored gate job and says so; the next launch does not")
    func launch() throws {
        let suite = "iris-687c-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: defaults, guardedSecrets: KeychainManager(serviceSuffix: ".t", inMemory: true))
        let store = try ConversationStore.inMemory()
        let gated = Job(name: "watch-build", prompt: "p",
                        trigger: .poll(PollSpec(schedule: .interval(seconds: 600),
                                                gate: .script(command: "echo CHANGED", mounts: [], timeoutSeconds: 60))))
        _ = try store.ledger.upsert(gated)

        let first = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             guardedConfig: config, runsGateUpgrade: true)
        #expect(try store.ledger.jobs().first?.pausedReason == AppState.gateNeedsReviewReason)
        let target = try #require(first.selectedConversationId)
        let said = first.conversations.first { $0.id == target }?.messages.map(\.content) ?? []
        #expect(said.contains { $0.contains("watch-build") && $0.contains("paused") })

        try store.ledger.setPaused(jobId: gated.id, reason: nil)
        let second = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                              guardedConfig: config, runsGateUpgrade: true)
        #expect(try store.ledger.jobs().first?.pausedReason == nil, "the upgrade ran once")
        _ = second
    }
}

/// #693 review: only a re-schedule, which shows the script, lifts a review pause. `/jobs resume`
/// refuses, and `/jobs pause` leaves the reason alone so a later resume can't go round it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GateReviewPauseTests {
    private func reply(_ app: AppState, containing text: String) async -> Bool {
        let end = TestClock.deadline(10)
        while TestClock.now() < end {
            if app.conversations.contains(where: { $0.messages.contains { $0.content.contains(text) } }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    @Test("/jobs resume and /jobs pause leave a review pause in place")
    func commandsKeepTheReviewPause() async throws {
        let store = try ConversationStore.inMemory()
        var gated = Job(name: "watch-build", prompt: "p",
                        trigger: .poll(PollSpec(schedule: .interval(seconds: 600),
                                                gate: .script(command: "echo CHANGED", mounts: [], timeoutSeconds: 60))))
        gated.pausedReason = AppState.gateNeedsReviewReason
        _ = try store.ledger.upsert(gated)
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)

        app.sendMessage("/jobs resume watch-build")
        #expect(await reply(app, containing: "can't lift this pause"))
        #expect(try store.ledger.jobs().first?.pausedReason == AppState.gateNeedsReviewReason)

        app.sendMessage("/jobs pause watch-build")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(try store.ledger.jobs().first?.pausedReason == AppState.gateNeedsReviewReason,
                "an owner's pause never replaces the review pause")
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}
