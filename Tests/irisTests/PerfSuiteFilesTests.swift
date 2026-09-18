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
        for name in ["ladder", "tool-eagerness"] {
            let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/\(name).json").path)
            #expect(suite.lane == .real)
            #expect(suite.pauseMs >= 1000)
            #expect(suite.repetitions <= 3)
        }
    }

    @Test("the eagerness suite covers both categories")
    func eagernessCategories() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/tool-eagerness.json").path)
        let categories = Set(suite.scenarioURLs(relativeTo: root).map(PerfRunner.category(forScenarioAt:)))
        #expect(categories == ["model-only", "tool-use"])
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
