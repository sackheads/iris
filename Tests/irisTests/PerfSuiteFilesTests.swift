// Tests/irisTests/PerfSuiteFilesTests.swift
import Testing
import Foundation
@testable import IrisKit

/// The committed suite and prompt files must load, or perf/run.sh fails at the worst moment.
@Suite("perf/ suite files")
struct PerfSuiteFilesTests {
    private let root = PerfPaths.repoRoot()

    @Test("every committed suite loads and every scenario it lists exists and decodes",
          arguments: ["smoke", "ladder", "tool-eagerness", "tool-eagerness-2"])
    func suitesLoad(name: String) throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/\(name).json").path)
        #expect(suite.name == name)
        for url in suite.scenarioURLs(relativeTo: root) {
            #expect(FileManager.default.fileExists(atPath: url.path), Comment(rawValue: url.path))
            let scenario = try Scenario.load(at: url.path)
            #expect(scenario.turns.count == 1, Comment(rawValue: "perf scenarios are single-turn so rungs 1-3 have one prompt"))
            if suite.lane == .real { #expect(scenario.clientMode == .real, Comment(rawValue: url.path)) }
        }
    }

    @Test("the real suites are paced and keep repetitions small")
    func realSuitesArePaced() throws {
        for name in ["ladder", "tool-eagerness", "tool-eagerness-2"] {
            let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/\(name).json").path)
            #expect(suite.lane == .real)
            #expect(suite.pauseMs >= 1000)
            #expect(suite.repetitions <= 5)
        }
    }

    @Test("the eagerness suite covers both categories")
    func eagernessCategories() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/tool-eagerness.json").path)
        let categories = Set(suite.scenarioURLs(relativeTo: root).map(PerfRunner.category(forScenarioAt:)))
        #expect(categories == ["model-only", "tool-use"])
    }

    /// The #314 Phase 1 measurement suite: the four caching scenarios plus `goal-tool-loop`, whose
    /// three turns each ask for 4-5 dependent shell steps so within-turn replay has rounds to carry.
    @Test("the 314-phase1 suite loads: real lane, rung 4, the caching scenarios plus goal-tool-loop")
    func phase1SuiteLoads() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/314-phase1.json").path)
        #expect(suite.name == "314-phase1")
        #expect(suite.lane == .real)
        #expect(suite.rungs == [4])
        let scenarios = try suite.scenarioURLs(relativeTo: root).map { try Scenario.load(at: $0.path) }
        #expect(scenarios.map(\.name) == ["six-turns", "every-turn-facts", "tool-heavy", "pinned-briefing", "goal-tool-loop"])
        let loop = try #require(scenarios.last)
        #expect(loop.clientMode == .real)
        #expect(loop.turns.count == 3)
        #expect(loop.expectedTools == ["run_command"])
    }

    /// Not part of `suitesLoad` above: that test asserts every scenario is single-turn, which is
    /// deliberately false for `caching` (5a) — its six turns are the point.
    @Test("the caching suite loads: real lane, rung 4 only, seeded multi-turn scenarios (5a)")
    func cachingSuiteLoads() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/caching.json").path)
        #expect(suite.name == "caching")
        #expect(suite.lane == .real)
        #expect(suite.rungs == [4])
        #expect(suite.pauseMs >= 1000)
        for url in suite.scenarioURLs(relativeTo: root) {
            #expect(FileManager.default.fileExists(atPath: url.path), Comment(rawValue: url.path))
            let scenario = try Scenario.load(at: url.path)
            #expect(scenario.clientMode == .real, Comment(rawValue: url.path))
            // six-turns: one fact turn in six (the best case); every-turn-facts: one seed per turn;
            // tool-heavy: a long tool turn between two fact turns (the k-2 read point, §1).
            // pinned-briefing: one seed that matches nothing, so its fact store is a fresh empty-ish
            // one and only the briefing changes (5b).
            let expected: [String: (turns: Int, seeds: Int)] = ["six-turns": (6, 2), "every-turn-facts": (6, 6), "tool-heavy": (5, 3),
                                                                 "pinned-briefing": (4, 1)]
            let shape = expected[scenario.name]
            #expect(shape != nil, "unexpected caching scenario \(scenario.name)")
            #expect(scenario.turns.count == shape?.turns)
            #expect(scenario.seedFacts?.count == shape?.seeds)
        }
        #expect(suite.scenarios.count == 4)
    }

    /// 5b §3 "Perf": a pinned conversation whose briefing changes every turn, with an event card
    /// mid-turn. The seed exists only to give the run a fresh store of its own (with no seeds the
    /// engine reads the shared one), and must match no turn, so the fact block never appears.
    @Test("pinned-briefing.json: pinned, ledger rows before turns 2-4, a card on the tool turn, no fact matches (5b)")
    func pinnedBriefingSchedule() throws {
        let scenario = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/pinned-briefing.json").path)
        #expect(scenario.pinned)
        #expect(scenario.turns.map { ($0.ledgerRuns ?? []).count } == [0, 1, 1, 1])
        #expect(scenario.turns.map { $0.eventCard != nil } == [false, false, true, false])
        // The card lands mid-turn only if turn 3 has a second round, so it asks for a command.
        #expect(scenario.turns[2].prompt.contains("shell command"))
        // The fake-lane script gives turn 3 its tool round too: 4 turns, 5 responses.
        #expect(scenario.scriptedResponses.count == 5)
        #expect(scenario.scriptedResponses[2].kind == .toolCalls)
        let store = try FactStoreManager(inMemory: true)
        for seed in try #require(scenario.seedFacts) { try store.addFact(content: seed) }
        for turn in scenario.turns {
            #expect(try store.search(query: turn.prompt, countsAsRetrieval: false).isEmpty, "\(turn.prompt)")
        }
    }

    /// The real fact-store match schedule for six-turns.json, built the way `ScenarioRunner` now
    /// builds it for a real run: a fresh in-memory store holding only this scenario's seeds, then
    /// the store's own `search` run against each turn's prompt exactly as `iris.swift` calls it
    /// (5a fix round 2, review finding #2). Before the reword, common words in the seeds ("The",
    /// "ships") made turns 3 and 6 match too under FTS5's any-token search; the seeds now carry
    /// only tokens distinctive enough that no other turn's prompt shares one.
    @Test("six-turns.json's seeds match only turn 2's prompt, never any other turn (5a)")
    func cachingSuiteFactScheduleIsDeterministic() throws {
        let scenario = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/six-turns.json").path)
        let seeds = try #require(scenario.seedFacts)
        let store = try FactStoreManager(inMemory: true)
        for seed in seeds { try store.addFact(content: seed) }
        let schedule = try scenario.turns.map { turn in
            !(try store.search(query: turn.prompt, countsAsRetrieval: false)).isEmpty
        }
        #expect(schedule == [false, true, false, false, false, false])
    }

    /// The realistic case (5a §3.1): with a real fact store most turns match some fact, and a
    /// different one each time, so the fact block changes on every turn. Each turn here must match
    /// exactly its own seed and no other, under the same any-token search production uses.
    @Test("every-turn-facts.json: each turn matches exactly its own seed (5a)")
    func everyTurnFactsScheduleIsOneToOne() throws {
        let scenario = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/every-turn-facts.json").path)
        let seeds = try #require(scenario.seedFacts)
        #expect(seeds.count == scenario.turns.count)
        let store = try FactStoreManager(inMemory: true)
        for seed in seeds { try store.addFact(content: seed) }
        for (i, turn) in scenario.turns.enumerated() {
            let matched = try store.search(query: turn.prompt, countsAsRetrieval: false).map(\.content)
            #expect(matched == [seeds[i]], "turn \(i + 1) matched \(matched)")
        }
    }

    /// 5a §1's read point. At turn k the request matches the cache only through the end of turn
    /// k-2, because turn k-1's entry is sent without the turn-context block it carried. Turn 2
    /// here runs a dozen sequential commands AND matches its own seed, so its entry changes at
    /// turn 3: turn 3 can read past the system prompt only through the end of turn 1, more than
    /// 20 blocks back, which the old placement reached by lookback and the new one marks
    /// explicitly. (The first version gave turn 2 no seed, so turn 3 read through turn 2's own
    /// last-round marker under either placement and the scenario proved nothing about it.)
    @Test("tool-heavy.json: turns 1, 2 and 3 each match their own seed, turns 4 and 5 match none (5a)")
    func toolHeavyFactSchedule() throws {
        let scenario = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/tool-heavy.json").path)
        let seeds = try #require(scenario.seedFacts)
        try #require(seeds.count == 3)
        let store = try FactStoreManager(inMemory: true)
        for seed in seeds { try store.addFact(content: seed) }
        let matches = try scenario.turns.map { try store.search(query: $0.prompt, countsAsRetrieval: false).map(\.content) }
        #expect(matches == [[seeds[0]], [seeds[1]], [seeds[2]], [], []])
        // Turn 2 asks for many separate commands, so it runs many tool rounds.
        #expect(scenario.turns[1].prompt.components(separatedBy: "`").count - 1 >= 24)
    }

    @Test("the second eagerness suite pairs bait prompts with tool-use controls (#138)")
    func eagerness2Categories() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/tool-eagerness-2.json").path)
        let categories = suite.scenarioURLs(relativeTo: root).map(PerfRunner.category(forScenarioAt:))
        #expect(Set(categories) == ["model-only-2", "tool-use"])
        #expect(categories.filter { $0 == "model-only-2" }.count == 6)
        #expect(categories.filter { $0 == "tool-use" }.count == 3)
        #expect(suite.rungs == [5])
    }

    @Test("every scenario file in perf/prompts/caching decodes (5c)")
    func everyCachingScenarioDecodes() throws {
        let dir = root.appendingPathComponent("perf/prompts/caching")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 6)
        for url in files {
            let scenario = try Scenario.load(at: url.path)
            #expect(scenario.clientMode == .real, Comment(rawValue: url.lastPathComponent))
        }
    }

    @Test("the cost-policy suite: real lane, rung 4, two repetitions, the three 5c scenarios (5c)")
    func costPolicySuiteLoads() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/cost-policy.json").path)
        #expect(suite.name == "cost-policy")
        #expect(suite.lane == .real && suite.rungs == [4] && suite.repetitions == 2 && suite.pauseMs >= 1000)
        let names = try suite.scenarioURLs(relativeTo: root).map { try Scenario.load(at: $0.path).name }
        #expect(names == ["pinned-pause", "job-cadence", "tool-heavy"])
        // One-scenario suites, so an arm that needs one scenario pays for no other.
        for name in names {
            let one = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/cost-policy-\(name).json").path)
            #expect(one.name == "cost-policy-\(name)")
            #expect(one.lane == .real && one.rungs == [4] && one.repetitions == 2)
            #expect(try one.scenarioURLs(relativeTo: root).map { try Scenario.load(at: $0.path).name } == [name])
        }
    }

    @Test("pinned-pause waits six minutes before turn 2; job-cadence is two fresh background runs fifteen minutes apart (5c)")
    func costPolicyScenarioShapes() throws {
        let pinned = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/pinned-pause.json").path)
        #expect(pinned.pinned && !pinned.background)
        #expect(pinned.turns.map(\.pauseBeforeSeconds) == [nil, 360])
        #expect(pinned.expectedTools == [])
        let cadence = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/job-cadence.json").path)
        #expect(cadence.background && cadence.freshConversationPerTurn && !cadence.pinned)
        #expect(cadence.turns.map(\.pauseBeforeSeconds) == [nil, 900])
        #expect(cadence.turns.allSatisfy { $0.source == "job:cadence" })
        // tool-heavy and pinned-briefing score every call but run_command as unexpected, which is
        // the spec's unprompted-call count for manage_fact and the peer tools.
        for name in ["tool-heavy", "pinned-briefing"] {
            let s = try Scenario.load(at: root.appendingPathComponent("perf/prompts/caching/\(name).json").path)
            #expect(s.expectedTools == ["run_command"], Comment(rawValue: name))
        }
    }
}
