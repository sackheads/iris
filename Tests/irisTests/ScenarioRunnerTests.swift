import Testing
import Foundation
@testable import iris

@MainActor
@Suite("ScenarioRunner")
struct ScenarioRunnerTests {

    @Test("fake scenario with a tool call runs headlessly and profiles one turn")
    func runsFakeToolScenario() async {
        let scenario = Scenario(
            name: "echo",
            clientMode: .fake,
            turns: [Scenario.Turn(prompt: "run echo")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo hello")])
                ]),
                Scenario.ScriptedResponse(kind: .text, text: "done", calls: nil)
            ])

        let result = await ScenarioRunner.run(scenario)

        // One processInput => one profiler turn.
        #expect(result.turnProfiles.count == 1)
        #expect(result.wallClockMs > 0)
        let profile = result.turnProfiles.first
        // The model was consulted and a tool ran, headlessly, with no UI.
        #expect((profile?.categories[.primaryLLM]?.count ?? 0) >= 1)
        #expect((profile?.categories[.toolExecution]?.count ?? 0) >= 1)
    }

    /// Records each injected sleep instead of waiting (bounded-runs constraint).
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(seconds: Int, requestsSoFar: Int)] = []
        let client: CapturingLLMClient
        init(_ client: CapturingLLMClient) { self.client = client }
        func record(_ seconds: Int) { lock.withLock { calls.append((seconds, client.requests.count)) } }
        var all: [(seconds: Int, requestsSoFar: Int)] { lock.withLock { calls } }
    }

    private static func toolNames(_ request: GeminiRequest) -> Set<String> {
        Set(request.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    }

    @Test("a turn's pause runs once, before that turn, on a real-client scenario (5c)")
    func pauseBeforeTurn() async {
        let client = CapturingLLMClient(reply: "ok")
        let sleeps = SleepRecorder(client)
        let scenario = Scenario(name: "pause", clientMode: .real,
                                turns: [.init(prompt: "one"), .init(prompt: "two", pauseBeforeSeconds: 360)])
        _ = await ScenarioRunner.run(scenario, clientOverride: client, sleep: { sleeps.record($0) })
        let calls = sleeps.all
        #expect(calls.map(\.seconds) == [360])
        // After turn 1's one request and before turn 2's.
        #expect(calls.first?.requestsSoFar == 1)
        #expect(client.requests.count == 2)
    }

    @Test("the fake lane skips the pause")
    func fakeLaneSkipsPause() async {
        let client = CapturingLLMClient(reply: "ok")
        let sleeps = SleepRecorder(client)
        let scenario = Scenario(name: "pause", clientMode: .fake,
                                turns: [.init(prompt: "one"), .init(prompt: "two", pauseBeforeSeconds: 360)])
        _ = await ScenarioRunner.run(scenario, clientOverride: client, sleep: { sleeps.record($0) })
        #expect(sleeps.all.isEmpty)
    }

    @Test("background runs a job run's readOnly surface; an ordinary run does not (5c)")
    func backgroundIsAJobRun() async throws {
        let bgClient = CapturingLLMClient(reply: "ok")
        _ = await ScenarioRunner.run(Scenario(name: "bg", turns: [.init(prompt: "one")], background: true),
                                     clientOverride: bgClient)
        let fgClient = CapturingLLMClient(reply: "ok")
        _ = await ScenarioRunner.run(Scenario(name: "fg", turns: [.init(prompt: "one")]), clientOverride: fgClient)
        let bg = Self.toolNames(try #require(bgClient.requests.first))
        let fg = Self.toolNames(try #require(fgClient.requests.first))
        #expect(bg.contains("read_file"))
        #expect(!bg.contains("write_file"), "the readOnly profile narrows the declarations")
        #expect(fg.contains("write_file"))
    }

    @Test("freshConversationPerTurn sends each turn to its own conversation (5c)")
    func freshConversationPerTurn() async {
        let client = CapturingLLMClient(reply: "ok")
        let scenario = Scenario(name: "fresh", turns: [.init(prompt: "one"), .init(prompt: "two"), .init(prompt: "three")],
                                background: true, freshConversationPerTurn: true)
        let result = await ScenarioRunner.run(scenario, clientOverride: client)
        #expect(Set(result.conversationIds).count == 3)
        #expect(result.conversationId == result.conversationIds.first)
        #expect(client.requests.count == 3)
        for request in client.requests {
            #expect(request.contents.filter { $0.role == "user" }.count == 1, "no earlier turn in the history")
        }
        #expect(result.turnProfiles.count == 3)

        let shared = CapturingLLMClient(reply: "ok")
        let one = await ScenarioRunner.run(Scenario(name: "same", turns: [.init(prompt: "one"), .init(prompt: "two")]),
                                           clientOverride: shared)
        #expect(one.conversationIds.count == 1)
        #expect(shared.requests.last.map { $0.contents.filter { $0.role == "user" }.count } == 2)
    }

    @Test("the experiments reach the engine: a TTL override rides the request's cache hints (5c)")
    func ttlOverrideReachesRequest() async throws {
        let client = CapturingLLMClient(reply: "ok")
        let policy = CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes)
        _ = await ScenarioRunner.run(Scenario(name: "ttl", turns: [.init(prompt: "one")]), clientOverride: client,
                                     experiments: PerfExperiments(ttlOverride: policy))
        #expect(try #require(client.requests.first).cacheHints?.ttl == policy)
        let plain = CapturingLLMClient(reply: "ok")
        _ = await ScenarioRunner.run(Scenario(name: "ttl", turns: [.init(prompt: "one")]), clientOverride: plain)
        #expect(try #require(plain.requests.first).cacheHints?.ttl == .standard)
    }
}
