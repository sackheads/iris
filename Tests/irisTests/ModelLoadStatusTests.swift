import Foundation
import Testing
@testable import IrisKit

private func psBody(_ names: [String]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0] }])
}

private func quietTracker() -> ModelLoadTracker { ModelLoadTracker(log: { _ in }) }

private func engine(tracker: ModelLoadTracker, ps: Data?, gate: TestGate, status: Int = 200) -> OllamaEngine {
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
        let gate = TestGate()
        let e = engine(tracker: tracker, ps: psBody([]), gate: gate)
        try await e.loadModel(config: config)
        #expect(tracker.active.map(\.name) == ["gemma4:12b"])
        #expect(tracker.active.first?.purpose == .guardTier3)
        gate.open()
        try await settle(e)
        #expect(tracker.active.isEmpty)
        #expect(gate.arrivals == 1)
    }

    @Test func aFailedPreloadClearsTheLine() async throws {
        let tracker = quietTracker()
        let gate = TestGate()
        let e = engine(tracker: tracker, ps: psBody([]), gate: gate, status: 500)
        try await e.loadModel(config: config)
        #expect(tracker.active.count == 1)
        gate.open()
        try await settle(e)
        #expect(tracker.active.isEmpty)
    }

    @Test func aColdCallResendsThePreloadAndEndsOnItsReply() async throws {
        let lines = ModelLoadTrackerLines()
        let tracker = ModelLoadTracker(log: { lines.append($0) })
        let gate = TestGate()
        gate.open()
        // keep_alive ran out: ps no longer lists the model.
        let e = engine(tracker: tracker, ps: psBody(["other:latest"]), gate: gate)
        try await e.loadModel(config: config)
        try await settle(e)
        // A reply this recent would mean the model is still loaded; age it past keep_alive.
        await e.prepareForGenerate(now: MonotonicClock.nowMs() + OllamaEngine.recentReplyMs + 1)
        try await settle(e)
        #expect(gate.arrivals == 2)
        #expect(tracker.active.isEmpty)
        #expect(lines.all.filter { $0.contains("model.load end") && $0.contains(" loaded") }.count == 2)
    }

    @Test func aListedModelIsNotALoad() async throws {
        let tracker = quietTracker()
        let gate = TestGate()
        gate.open()
        let e = engine(tracker: tracker, ps: psBody(["gemma4:12b"]), gate: gate)
        try await e.loadModel(config: config)
        try await settle(e)
        await e.prepareForGenerate(now: MonotonicClock.nowMs() + OllamaEngine.recentReplyMs + 1)
        #expect(await e.pendingPreload == nil)
        #expect(gate.arrivals == 1)
    }

    @Test func anUnansweredPsShowsNothing() async throws {
        let tracker = quietTracker()
        let gate = TestGate()
        gate.open()
        let e = engine(tracker: tracker, ps: nil, gate: gate)
        try await e.loadModel(config: config)
        try await settle(e)
        await e.prepareForGenerate(now: MonotonicClock.nowMs() + OllamaEngine.recentReplyMs + 1)
        #expect(await e.pendingPreload == nil)
        #expect(gate.arrivals == 1)
        #expect(await e.isModelLoaded() == false)
    }

    @Test func aCallDuringThePreloadDoesNotShowTwice() async throws {
        let tracker = quietTracker()
        let gate = TestGate()
        let e = engine(tracker: tracker, ps: psBody([]), gate: gate)
        try await e.loadModel(config: config)
        await e.prepareForGenerate()
        await e.prepareForGenerate()
        #expect(tracker.active.count == 1)
        gate.open()
        try await settle(e)
        #expect(gate.arrivals == 1)
        #expect(tracker.active.isEmpty)
    }
}

/// The cold-model check runs beside `generate`, never in front of it (#779 review, dev-3).
@Suite("Ollama generate and the cold-model check (#779)", .timeLimit(.minutes(1)))
struct OllamaGenerateColdCheckTests {
    private static let reply = Data(#"{"response":"SAFE","done":true}"#.utf8)

    @Test func generateDoesNotWaitOnPs() async throws {
        let psGate = TestGate()
        defer { psGate.open() }   // never leave the check parked, whatever fails
        let calls = ModelLoadTrackerLines()
        let e = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), transport: .init(
            ps: { calls.append("ps"); await psGate.wait(); return psBody([]) },
            // Never a 200, so no recent reply skips the check: it runs, and hangs on ps.
            preload: { _ in (500, Data()) },
            generate: { _ in calls.append("generate"); return (200, Self.reply) }))
        try await e.loadModel(config: AuxiliaryModelConfig(role: "vibecop", engineType: .ollama, modelPathOrName: "m"))
        if let t = await e.pendingPreload { try await value(of: t, within: 10) }
        let answer = try await e.generate(prompt: "x", jsonSchema: nil)
        #expect(answer == "SAFE")
        #expect(psGate.arrivals <= 1)
        psGate.open()
        if let check = await e.pendingColdCheck { try await value(of: check, within: 10) }
        #expect(calls.all.contains("ps"))
    }

    @Test func aColdModelResendsThePreloadBesideTheGenerate() async throws {
        let calls = ModelLoadTrackerLines()
        let tracker = ModelLoadTracker(log: { _ in })
        let e = OllamaEngine(tracker: tracker, transport: .init(
            ps: { calls.append("ps"); return psBody(["other:latest"]) },
            preload: { _ in calls.append("preload"); return (500, Data()) },   // never a reply: no "recent" skip
            generate: { _ in calls.append("generate"); return (200, Self.reply) }))
        try await e.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "gemma4:12b"))
        if let t = await e.pendingPreload { try await value(of: t, within: 10) }
        _ = try await e.generate(prompt: "x", jsonSchema: nil)
        if let check = await e.pendingColdCheck { try await value(of: check, within: 10) }
        if let t = await e.pendingPreload { try await value(of: t, within: 10) }
        #expect(calls.all.filter { $0 == "preload" }.count == 2)
        #expect(calls.all.contains("ps"))
        #expect(tracker.active.isEmpty)
    }

    @Test func aRecentReplySkipsPs() async throws {
        let calls = ModelLoadTrackerLines()
        let e = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), transport: .init(
            ps: { calls.append("ps"); return psBody([]) },
            preload: { _ in (200, Data("{}".utf8)) },
            generate: { _ in (200, Self.reply) }))
        try await e.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "m"))
        if let t = await e.pendingPreload { try await value(of: t, within: 10) }
        _ = try await e.generate(prompt: "x", jsonSchema: nil)
        if let check = await e.pendingColdCheck { try await value(of: check, within: 10) }
        #expect(!calls.all.contains("ps"))
    }
}

private final class ModelLoadTrackerLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
