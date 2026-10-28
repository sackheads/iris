import Foundation
import Testing
@testable import IrisKit

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Double = 1_000
    func now() -> Double { lock.withLock { ms } }
    func advance(_ by: Double) { lock.withLock { ms += by } }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

private struct LoadFailed: Error {}

@Suite("ModelLoadTracker (#778)")
struct ModelLoadTrackerTests {
    private func tracker() -> (ModelLoadTracker, ManualClock, Lines) {
        let clock = ManualClock()
        let lines = Lines()
        return (ModelLoadTracker(now: { clock.now() }, log: { lines.append($0) }), clock, lines)
    }

    @Test func beginAndEndLogTheLoadAndItsDuration() {
        let (t, clock, lines) = tracker()
        let id = t.begin(.guardTier3, name: "gemma4:12b")
        #expect(t.active.map(\.id) == [id])
        clock.advance(1_234)
        t.end(id, .loaded, detail: "load_duration_ms=1200")
        #expect(t.active.isEmpty)
        #expect(lines.all.count == 2)
        #expect(lines.all[0].hasPrefix("model.load begin purpose=\"guard (tier 3)\" name=gemma4:12b"))
        #expect(lines.all[1].contains("ms=1234 loaded load_duration_ms=1200"))
    }

    @Test func overlappingLoadsListOldestFirst() {
        let (t, clock, _) = tracker()
        let a = t.begin(.guardTier2, name: "a")
        clock.advance(10)
        let b = t.begin(.vibecop, name: "b")
        clock.advance(10)
        let c = t.begin(.guardTier3, name: "c")
        #expect(t.active.map(\.id) == [a, b, c])
        t.end(b, .loaded)
        #expect(t.active.map(\.id) == [a, c])
    }

    @Test func aSecondEndOrAnUnknownIdDoesNothing() {
        let (t, _, lines) = tracker()
        let id = t.begin(.vision, name: "v")
        t.end(id, .loaded)
        t.end(id, .failed("late"))
        t.end(UUID(), .loaded)
        #expect(lines.all.count == 2)
    }

    @Test func aLoadThatThrowsIsClearedAsFailed() async {
        let (t, _, lines) = tracker()
        await #expect(throws: LoadFailed.self) {
            try await t.track(.guardTier2, name: "broken") { () async throws -> Int in throw LoadFailed() }
        }
        #expect(t.active.isEmpty)
        #expect(lines.all.last?.contains("failed error=") == true)
    }

    @Test func trackReturnsTheLoadedValue() async throws {
        let (t, _, lines) = tracker()
        let value = try await t.track(.guardTier3, name: "m") { 7 }
        #expect(value == 7)
        #expect(t.active.isEmpty)
        #expect(lines.all.last?.contains(" loaded") == true)
    }

    @Test func concurrentLoadsAreKeyedByTheirOwnId() async {
        let (t, _, lines) = tracker()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<200 {
                group.addTask {
                    let id = t.begin(.other("r\(n)"), name: "m\(n)")
                    t.end(id, .loaded)
                }
            }
        }
        #expect(t.active.isEmpty)
        #expect(lines.all.filter { $0.contains(" loaded") }.count == 200)
    }

    @Test func rolesNameTheirPurpose() {
        #expect(ModelLoadPurpose(role: "canary") == .guardTier3)
        #expect(ModelLoadPurpose(role: "promptGuard") == .guardTier3)
        #expect(ModelLoadPurpose(role: "vibecop") == .vibecop)
        #expect(ModelLoadPurpose(role: "vision") == .vision)
        #expect(ModelLoadPurpose(role: "summary") == .other("summary"))
        #expect(ModelLoadPurpose.guardTier2.label == "guard (tier 2)")
        #expect(ModelLoadPurpose.vibecop.label == "Vibecop")
    }

    @Test func profilerEventsGoToTheTaskSink() {
        let lines = Lines()
        PerformanceProfiler.$eventSink.withValue({ lines.append($0) }) {
            PerformanceProfiler.event("guard.tier3 start")
        }
        #expect(lines.all.count == 1)
        #expect(lines.all[0].hasPrefix("[perf] "))
        #expect(lines.all[0].contains("ms guard.tier3 start"))
    }
}

@Suite("Ollama timings (#778)")
struct OllamaTimingsTests {
    @Test func nanosecondsBecomeMilliseconds() {
        let body = #"{"response":"","done":true,"load_duration":61234000000,"total_duration":61300000000}"#
        #expect(OllamaEngine.timings(from: Data(body.utf8)) == "load_duration_ms=61234 total_duration_ms=61300")
    }

    @Test func aBodyWithoutTimingsGivesNothing() {
        #expect(OllamaEngine.timings(from: Data(#"{"error":"model not found"}"#.utf8)) == "")
        #expect(OllamaEngine.timings(from: Data("not json".utf8)) == "")
    }
}

@Suite("iris --guard-probe (#778)")
struct GuardProbeCLITests {
    @Test func absentFlagIsNotAProbe() {
        #expect(GuardProbeCLI.parse(["iris"]) == nil)
    }

    @Test func parsesItsOptions() throws {
        let parsed = try #require(GuardProbeCLI.parse(["iris", "--guard-probe", "--reps", "3", "--text", "hi", "--prebuild", "20"]))
        #expect(parsed == .success(.init(text: "hi", reps: 3, prebuildSeconds: 20)))
        #expect(GuardProbeCLI.parse(["iris", "--guard-probe"]) == .success(.init()))
    }

    @Test func configOverridesAreOptionsNotSettings() throws {
        let parsed = try #require(GuardProbeCLI.parse(["iris", "--guard-probe", "--engine", "ollama", "--model", "gemma4:12b"]))
        guard case .success(let options) = parsed else { Issue.record("not parsed"); return }
        #expect(options.engine == "ollama" && options.model == "gemma4:12b" && options.tier2 == nil)
        #expect(options.overridesConfig)
        #expect(!GuardProbeCLI.Options().overridesConfig)
        #expect(GuardProbeCLI.parse(["iris", "--guard-probe", "--tier2"]) == .failure(.badValue("--tier2")))
    }

    @Test func refusesBadValues() {
        #expect(GuardProbeCLI.parse(["iris", "--guard-probe", "--reps", "0"]) == .failure(.badValue("--reps")))
        #expect(GuardProbeCLI.parse(["iris", "--guard-probe", "--text"]) == .failure(.badValue("--text")))
        #expect(GuardProbeCLI.parse(["iris", "--guard-probe", "--real"]) == .failure(.unknownFlag("--real")))
    }

    @Test func eachRepJudgesDifferentText() {
        let texts = (1...3).map { GuardProbeCLI.text("t", rep: $0) }
        #expect(Set(texts).count == 3)
        #expect(texts[0] == "t")
    }

    @Test func refusesTheReleaseBuild() async {
        #expect(await GuardProbeCLI.run(.init(), build: .release) == 1)
    }
}

/// The load sites report to the tracker they were given (#778 review): each site's begin and its
/// end, including the failure path a missing model takes.
@Suite("Model load sites report to the tracker (#778)", .timeLimit(.minutes(1)))
struct ModelLoadSiteTests {
    @Test func aMissingLlamaModelIsAFailedLoad() async {
        let lines = Lines()
        let tracker = ModelLoadTracker(log: { lines.append($0) })
        let manager = AuxiliaryModelManager(tracker: tracker)
        let config = AuxiliaryModelConfig(role: "canary", engineType: .llamaCPP,
                                          modelPathOrName: "missing-\(UUID().uuidString).gguf")
        await #expect(throws: (any Error).self) { _ = try await manager.getEngine(for: "canary", config: config) }
        #expect(tracker.active.isEmpty)
        #expect(lines.all.count == 2)
        #expect(lines.all[0].contains("begin purpose=\"guard (tier 3)\""))
        #expect(lines.all[1].contains("failed error="))
        #expect(!manager.hasEngine(for: "canary"))
    }

    @Test func aCloudEngineLoadsNothing() async throws {
        let lines = Lines()
        let manager = AuxiliaryModelManager(tracker: ModelLoadTracker(log: { lines.append($0) }))
        _ = try await manager.getEngine(for: "canary", config: AuxiliaryModelConfig(role: "canary", engineType: .cloud, modelPathOrName: "x"))
        #expect(lines.all.isEmpty)
    }

    @Test func aBrokenTier2BundleIsAFailedLoad() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-778-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bogus.mlmodelc"), withIntermediateDirectories: true)
        let lines = Lines()
        let tracker = ModelLoadTracker(log: { lines.append($0) })
        let evaluator = CoreMLEvaluator(tracker: tracker, configuredModel: { "bogus.mlmodelc" }, modelsDir: { dir })
        await #expect(throws: (any Error).self) { try await evaluator.loadModelIfNeeded() }
        #expect(tracker.active.isEmpty)
        #expect(lines.all.first?.contains("begin purpose=\"guard (tier 2)\" name=bogus.mlmodelc") == true)
        #expect(lines.all.last?.contains("failed error=") == true)
    }

    @Test func theOllamaPreloadIsALoadUntilItsReply() async throws {
        let lines = Lines()
        let tracker = ModelLoadTracker(log: { lines.append($0) })
        let replied = Lines()
        let engine = OllamaEngine(tracker: tracker, transport: .init(
            ps: { nil },
            preload: { _ in
                replied.append("sent")
                return (200, Data(#"{"done":true,"load_duration":2500000000}"#.utf8))
            }))
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "vibecop", engineType: .ollama, modelPathOrName: "gemma4:12b"))
        #expect(lines.all.first?.contains("begin purpose=\"Vibecop\" name=gemma4:12b") == true)
        if let task = await engine.pendingPreload { try await value(of: task, within: 10) }
        #expect(tracker.active.isEmpty)
        #expect(replied.all == ["sent"])
        #expect(lines.all.last?.contains("loaded load_duration_ms=2500") == true)
    }

    @Test func aRefusedOllamaPreloadIsAFailedLoad() async throws {
        let lines = Lines()
        let tracker = ModelLoadTracker(log: { lines.append($0) })
        let engine = OllamaEngine(tracker: tracker, transport: .init(
            ps: { nil }, preload: { _ in (404, Data(#"{"error":"model not found"}"#.utf8)) }))
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "nope"))
        if let task = await engine.pendingPreload { try await value(of: task, within: 10) }
        #expect(tracker.active.isEmpty)
        #expect(lines.all.last?.contains("failed error=\"HTTP 404\"") == true)
    }
}
