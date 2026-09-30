import Testing
import Foundation
@testable import iris

@Suite("PerfSuite")
struct PerfSuiteTests {
    @Test("defaults: fake lane, 3 repetitions, no pause, rung 5 only")
    func defaults() throws {
        let suite = try PerfSuite.decode(from: Data(#"{"name":"s","scenarios":["scenarios/echo-latency.json"]}"#.utf8))
        #expect(suite.lane == .fake)
        #expect(suite.repetitions == 3)
        #expect(suite.pauseMs == 0)
        #expect(suite.rungs == [5])
    }

    @Test("fake lane rejects rungs that would time a sleep")
    func fakeLaneRejectsLadderRungs() {
        let json = #"{"name":"s","lane":"fake","rungs":[1,5],"scenarios":["a.json"]}"#
        #expect(throws: PerfSuiteError.fakeLaneNeedsFullTurn([1])) { try PerfSuite.decode(from: Data(json.utf8)) }
    }

    @Test("rungs outside 1...5, empty scenarios and zero repetitions are rejected")
    func validation() {
        #expect(throws: PerfSuiteError.invalidRung(7)) {
            try PerfSuite.decode(from: Data(#"{"name":"s","lane":"real","rungs":[7],"scenarios":["a.json"]}"#.utf8))
        }
        #expect(throws: PerfSuiteError.emptyScenarios) {
            try PerfSuite.decode(from: Data(#"{"name":"s","scenarios":[]}"#.utf8))
        }
        #expect(throws: PerfSuiteError.invalidRepetitions(0)) {
            try PerfSuite.decode(from: Data(#"{"name":"s","repetitions":0,"scenarios":["a.json"]}"#.utf8))
        }
    }

    /// Review finding #1 (5a fix round 1): a fake-lane scenario with `seedFacts` would write into
    /// the real, on-disk `FactStoreManager.shared` — `IrisPaths.useVolatileCopy` is only ever
    /// installed for a real-lane run. This is the fail-fast, whole-suite refusal; the second one
    /// (`ScenarioRunner.canSeedFacts`) is covered in `ScenarioRunnerOptionsTests`.
    @Test("a fake-lane scenario with seedFacts is refused at validation time, naming the scenario")
    func fakeLaneSeedFactsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-suite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scenarioPath = dir.appendingPathComponent("seeded.json")
        try #"{"name":"seeded-scenario","turns":[{"prompt":"p"}],"seedFacts":["a fact"]}"#
            .write(to: scenarioPath, atomically: true, encoding: .utf8)
        let suite = PerfSuite(name: "s", lane: .fake, scenarios: [scenarioPath.path])
        #expect(throws: PerfSuiteError.seedFactsNeedsRealLane(scenario: "seeded-scenario")) {
            try suite.validateScenarios(relativeTo: dir)
        }
        // A real-lane suite with the same scenario is fine: the guard is lane-specific.
        let realSuite = PerfSuite(name: "s", lane: .real, scenarios: [scenarioPath.path])
        #expect(throws: Never.self) { try realSuite.validateScenarios(relativeTo: dir) }
        // An empty seedFacts array is treated the same as none.
        let emptyPath = dir.appendingPathComponent("empty.json")
        try #"{"name":"empty-scenario","turns":[{"prompt":"p"}],"seedFacts":[]}"#
            .write(to: emptyPath, atomically: true, encoding: .utf8)
        let emptySuite = PerfSuite(name: "s", lane: .fake, scenarios: [emptyPath.path])
        #expect(throws: Never.self) { try emptySuite.validateScenarios(relativeTo: dir) }
    }

    @Test("scenario paths resolve against the repo root")
    func resolvesPaths() throws {
        let suite = try PerfSuite.decode(from: Data(#"{"name":"s","scenarios":["scenarios/echo-latency.json"]}"#.utf8))
        let root = PerfPaths.repoRoot()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        #expect(suite.scenarioURLs(relativeTo: root).first?.path == root.appendingPathComponent("scenarios/echo-latency.json").path)
    }

    /// #242 / #160. `repoRoot()` used to start from the process working directory, so whenever a
    /// parallel suite called `changeCurrentDirectoryPath` the whole perf suite resolved the root
    /// to "/" and failed on fixtures that were present all along. It is anchored on this module's
    /// compile-time source location now.
    ///
    /// Deliberately does NOT set the working directory to prove it: doing so would reintroduce
    /// exactly the global mutation #242 is about. Verified out of band instead — with the anchor
    /// reverted and cwd forced to "/", `repoRoot()` returns "/" and the fixture lookup fails.
    @Test("the repo root is found without consulting the working directory")
    func repoRootIsAnchoredOnSource() {
        let root = PerfPaths.repoRoot()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("perf/suites/smoke.json").path))
        // The explicit override still walks from where it is told, so the anchor did not become
        // an unconditional answer that happens to be right here.
        #expect(PerfPaths.repoRoot(from: URL(fileURLWithPath: "/")).path == "/")
    }
}
