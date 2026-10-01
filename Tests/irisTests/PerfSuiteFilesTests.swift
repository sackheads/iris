// Tests/irisTests/PerfSuiteFilesTests.swift
import Testing
import Foundation
@testable import iris

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

    /// Not part of `suitesLoad` above: that test asserts every scenario is single-turn, which is
    /// deliberately false for `caching` (5a) — its six turns are the point.
    @Test("the caching suite loads: real lane, rung 4 only, six seeded-fact turns (5a)")
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
            #expect(scenario.turns.count == 6)
            // six-turns: one fact turn in six (the best case); every-turn-facts: one seed per turn.
            let expectedSeeds = ["six-turns": 2, "every-turn-facts": 6][scenario.name]
            #expect(expectedSeeds != nil, "unexpected caching scenario \(scenario.name)")
            #expect(scenario.seedFacts?.count == expectedSeeds)
        }
        #expect(suite.scenarios.count == 2)
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

    @Test("the second eagerness suite pairs bait prompts with tool-use controls (#138)")
    func eagerness2Categories() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/tool-eagerness-2.json").path)
        let categories = suite.scenarioURLs(relativeTo: root).map(PerfRunner.category(forScenarioAt:))
        #expect(Set(categories) == ["model-only-2", "tool-use"])
        #expect(categories.filter { $0 == "model-only-2" }.count == 6)
        #expect(categories.filter { $0 == "tool-use" }.count == 3)
        #expect(suite.rungs == [5])
    }
}
