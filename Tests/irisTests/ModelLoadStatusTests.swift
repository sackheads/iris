import Foundation
import Testing
@testable import IrisKit

/// A preload reply the test releases by hand, so "loading" can be observed before it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var calls = 0

    func wait() async {
        await withCheckedContinuation { c in
            let resumeNow = lock.withLock { () -> Bool in
                calls += 1
                if open { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters = [] }
            return waiters
        }
        all.forEach { $0.resume() }
    }

    var callCount: Int { lock.withLock { calls } }
}

private func psBody(_ names: [String]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0] }])
}

private func quietTracker() -> ModelLoadTracker { ModelLoadTracker(log: { _ in }) }

private func engine(tracker: ModelLoadTracker, ps: Data?, gate: Gate, status: Int = 200) -> OllamaEngine {
    OllamaEngine(tracker: tracker, transport: .init(
        ps: { ps },
        preload: { _ in
            await gate.wait()
            return (status, Data(#"{"done":true,"load_duration":1000000}"#.utf8))
        }))
}

private let config = AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "gemma4:12b")

@Suite("Model load status line (#779)", .timeLimit(.minutes(1)))
struct ModelLoadStatusTests {
    private func load(_ purpose: ModelLoadPurpose, _ name: String, at ms: Double) -> ModelLoad {
        ModelLoad(id: UUID(), purpose: purpose, name: name, startedAtMs: ms)
    }

    @Test func oneLineCountsWholeSeconds() {
        let l = load(.guardTier3, "gemma4:12b", at: 1_000)
        #expect(ModelLoadStatus.line(l, nowMs: 13_999) == "Loading guard (tier 3) model: gemma4:12b [12s]")
        #expect(ModelLoadStatus.line(l, nowMs: 1_000) == "Loading guard (tier 3) model: gemma4:12b [0s]")
        #expect(ModelLoadStatus.line(l, nowMs: 500) == "Loading guard (tier 3) model: gemma4:12b [0s]")
    }

    @Test func nothingLoadingShowsNothing() {
        #expect(ModelLoadStatus.lines([], nowMs: 0).isEmpty)
    }

    @Test func atMostThreeLinesThenMore() {
        let loads = [load(.guardTier2, "a", at: 0), load(.guardTier3, "b", at: 1), load(.vibecop, "c", at: 2),
                     load(.vision, "d", at: 3), load(.other("x"), "e", at: 4)]
        let lines = ModelLoadStatus.lines(loads, nowMs: 5_000)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Loading guard (tier 2) model: a"))
        #expect(lines[2].hasPrefix("Loading Vibecop model: c"))
        #expect(lines[3] == "+2 more")
        #expect(ModelLoadStatus.lines(Array(loads.prefix(3)), nowMs: 5_000).count == 3)
    }

    private func settle(_ e: OllamaEngine) async throws {
        if let task = await e.pendingPreload { try await value(of: task, within: 10) }
    }

    @Test func theLaunchPreloadIsLoadingUntilOllamaReplies() async throws {
        let tracker = quietTracker()
        let gate = Gate()
        let e = engine(tracker: tracker, ps: psBody([]), gate: gate)
        try await e.loadModel(config: config)
        #expect(tracker.active.map(\.name) == ["gemma4:12b"])
        #expect(tracker.active.first?.purpose == .guardTier3)
        gate.release()
        try await settle(e)
        #expect(tracker.active.isEmpty)
        #expect(gate.callCount == 1)
    }

    @Test func aFailedPreloadClearsTheLine() async throws {
        let tracker = quietTracker()
        let gate = Gate()
        let e = engine(tracker: tracker, ps: psBody([]), gate: gate, status: 500)
        try await e.loadModel(config: config)
        #expect(tracker.active.count == 1)
        gate.release()
        try await settle(e)
        #expect(tracker.active.isEmpty)
    }

    @Test func aColdCallResendsThePreloadAndEndsOnItsReply() async throws {
        let lines = ModelLoadTrackerLines()
        let tracker = ModelLoadTracker(log: { lines.append($0) })
        let gate = Gate()
        gate.release()
        // keep_alive ran out: ps no longer lists the model.
        let e = engine(tracker: tracker, ps: psBody(["other:latest"]), gate: gate)
        try await e.loadModel(config: config)
        try await settle(e)
        await e.prepareForGenerate()
        try await settle(e)
        #expect(gate.callCount == 2)
        #expect(tracker.active.isEmpty)
        #expect(lines.all.filter { $0.contains("model.load end") && $0.contains(" loaded") }.count == 2)
    }

    @Test func aListedModelIsNotALoad() async throws {
        let tracker = quietTracker()
        let gate = Gate()
        gate.release()
        let e = engine(tracker: tracker, ps: psBody(["gemma4:12b"]), gate: gate)
        try await e.loadModel(config: config)
        try await settle(e)
        await e.prepareForGenerate()
        #expect(await e.pendingPreload == nil)
        #expect(gate.callCount == 1)
    }

    @Test func anUnansweredPsShowsNothing() async throws {
        let tracker = quietTracker()
        let gate = Gate()
        gate.release()
        let e = engine(tracker: tracker, ps: nil, gate: gate)
        try await e.loadModel(config: config)
        try await settle(e)
        await e.prepareForGenerate()
        #expect(await e.pendingPreload == nil)
        #expect(gate.callCount == 1)
        #expect(await e.isModelLoaded() == false)
    }

    @Test func aCallDuringThePreloadDoesNotShowTwice() async throws {
        let tracker = quietTracker()
        let gate = Gate()
        let e = engine(tracker: tracker, ps: psBody([]), gate: gate)
        try await e.loadModel(config: config)
        await e.prepareForGenerate()
        await e.prepareForGenerate()
        #expect(tracker.active.count == 1)
        gate.release()
        try await settle(e)
        #expect(gate.callCount == 1)
        #expect(tracker.active.isEmpty)
    }
}

private final class ModelLoadTrackerLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
