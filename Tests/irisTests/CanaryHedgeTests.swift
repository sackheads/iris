import Testing
import Foundation
@testable import IrisKit

/// #871: the cloud canary sends a second request when the first has no answer after 20 s, takes the
/// first usable answer and stops the other. No test waits real time: the delay is a latch the test
/// opens, and every wait is bounded by `value(of:within:)`.
@Suite("Cloud canary hedge (#871)", .timeLimit(.minutes(1)))
struct CanaryHedgeTests {
    /// Opened once; a waiter ends early, throwing, if its task is cancelled.
    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        func open() {
            let toResume = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                opened = true; defer { waiters = [:] }; return Array(waiters.values)
            }
            toResume.forEach { $0.resume() }
        }
        func wait() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    let state = lock.withLock { () -> Int in
                        if opened { return 1 }
                        if Task.isCancelled { return 2 }
                        waiters[id] = cont; return 0
                    }
                    if state == 1 { cont.resume() } else if state == 2 { cont.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let cont = lock.withLock { waiters.removeValue(forKey: id) }
                cont?.resume(throwing: CancellationError())
            }
        }
    }

    /// Counts calls and records which one was cancelled.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var cancelledCalls = Set<Int>()
        func next() -> Int { lock.withLock { count += 1; return count } }
        var total: Int { lock.withLock { count } }
        func markCancelled(_ n: Int) { lock.withLock { _ = cancelledCalls.insert(n) } }
        func wasCancelled(_ n: Int) -> Bool { lock.withLock { cancelledCalls.contains(n) } }
    }

    struct Boom: Error, Equatable { let tag: String }
    private static let usage = UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 10, totalTokenCount: 110)

    private static func answer(_ text: String?, usage: UsageMetadata? = nil) -> GeminiResponse {
        let parts = text.map { [Part(text: $0)] } ?? []
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: parts))], usageMetadata: usage)
    }

    /// An engine whose first request is `first`, second `second`; `due` is the hedge delay, opened by the test.
    private static func engine(due: Latch, calls: Calls,
                               first: @escaping @Sendable (Int) async throws -> GeminiResponse,
                               second: @escaping @Sendable (Int) async throws -> GeminiResponse) -> CloudAuxiliaryEngine {
        var engine = CloudAuxiliaryEngine()
        engine.role = "canary-test"
        engine.model = { nil }
        engine.hedgeAfter = 20
        engine.hedgeSleep = { _ in try await due.wait() }
        engine.send = { _, _ in let n = calls.next(); return try await first(n) }
        engine.sendFresh = { _, _ in let n = calls.next(); return try await second(n) }
        return engine
    }

    private static func run(_ engine: CloudAuxiliaryEngine) -> Task<String, any Error> {
        Task { try await engine.generate(prompt: "p", jsonSchema: nil) }
    }

    @Test("the first request stalls: the hedge answers and the stalled request is cancelled, not waited out")
    func loserIsCancelled() async throws {
        let due = Latch(), calls = Calls()
        let engine = Self.engine(due: due, calls: calls,
            first: { n in
                do { try await Latch().wait() } catch { calls.markCancelled(n); throw error }   // parks until cancelled
                return Self.answer("MALICIOUS")
            },
            second: { _ in Self.answer("SAFE") })
        let start = TestClock.now()
        let task = Self.run(engine)
        due.open()
        let text = try await value(of: task, within: 10)
        #expect(text == "SAFE")
        #expect(calls.total == 2)
        #expect(calls.wasCancelled(1), "the group would have waited for the stalled request otherwise")
        #expect(TestClock.seconds(since: start) < 5)
    }

    @Test("a request that fails before the delay is not doubled: the call fails as it always did")
    func earlyFailureNotHedged() async throws {
        let due = Latch(), calls = Calls()
        let engine = Self.engine(due: due, calls: calls, first: { _ in throw Boom(tag: "first") },
                                 second: { _ in Self.answer("SAFE") })
        let task = Self.run(engine)
        await #expect(throws: Boom(tag: "first")) { try await value(of: task, within: 10) }
        #expect(calls.total == 1)
    }

    @Test("the first fails after the second is out and the second succeeds: success")
    func firstFailsSecondSucceeds() async throws {
        let due = Latch(), secondOut = Latch(), calls = Calls()
        let engine = Self.engine(due: due, calls: calls,
            first: { _ in try await secondOut.wait(); throw Boom(tag: "first") },
            second: { _ in secondOut.open(); return Self.answer("SAFE") })
        let task = Self.run(engine)
        due.open()
        #expect(try await value(of: task, within: 10) == "SAFE")
    }

    @Test("a first answer with no text is a failure: the call waits for the second")
    func malformedFirstWaitsForSecond() async throws {
        let due = Latch(), secondOut = Latch(), firstDone = Latch(), calls = Calls()
        let engine = Self.engine(due: due, calls: calls,
            first: { _ in try await secondOut.wait(); firstDone.open(); return Self.answer(nil) },
            // The second answers only once the first has, and a few turns later, so the first's
            // no-text answer is the one the race sees first.
            second: { _ in
                secondOut.open(); try await firstDone.wait()
                for _ in 0..<50 { await Task.yield() }
                return Self.answer("SAFE")
            })
        let task = Self.run(engine)
        due.open()
        #expect(try await value(of: task, within: 10) == "SAFE")
    }

    @Test("both requests fail: the first's error, which the caller fails closed on")
    func bothFail() async throws {
        let due = Latch(), secondOut = Latch(), calls = Calls()
        let engine = Self.engine(due: due, calls: calls,
            first: { _ in try await secondOut.wait(); throw Boom(tag: "first") },
            second: { _ in secondOut.open(); throw Boom(tag: "second") })
        let task = Self.run(engine)
        due.open()
        await #expect(throws: Boom(tag: "first")) { try await value(of: task, within: 10) }
    }

    @Test("no hedge delay set: one request, and the timer is never started")
    func unhedgedByDefault() async throws {
        let calls = Calls()
        var engine = CloudAuxiliaryEngine()
        engine.model = { nil }
        engine.hedgeSleep = { _ in Issue.record("the timer must not run without a hedge delay") }
        engine.send = { _, _ in _ = calls.next(); return Self.answer("SAFE") }
        engine.sendFresh = { _, _ in _ = calls.next(); return Self.answer("SAFE") }
        let task = Task { try await engine.generate(prompt: "p", jsonSchema: nil) }
        #expect(try await value(of: task, within: 10) == "SAFE")
        #expect(calls.total == 1)
    }

    @Test("both responses arrive: both are charged")
    func bothChargedWhenBothAnswer() async throws {
        let due = Latch(), secondOut = Latch(), calls = Calls()
        let engine = Self.engine(due: due, calls: calls,
            first: { _ in try await secondOut.wait(); return Self.answer("SAFE", usage: Self.usage) },
            second: { _ in secondOut.open(); return Self.answer("SAFE", usage: Self.usage) })
        let recorded = LockedUsage()
        let task = Task {
            try await GuardUsage.$sink.withValue(GuardUsage.Sink { recorded.add($0) }) {
                try await engine.generate(prompt: "p", jsonSchema: nil)
            }
        }
        due.open()
        _ = try await value(of: task, within: 10)
        #expect(recorded.prompt == 200, "the winner's by generate, the other's by the race")
    }

    @Test("only tier 3's canary is hedged, and its hedge is on a connection of its own")
    func wiring() {
        let canary = CloudAuxiliaryEngine.make(role: CloudAuxiliaryEngine.canaryRole)
        #expect(canary.hedgeAfter == CloudAuxiliaryEngine.canaryHedgeSeconds && CloudAuxiliaryEngine.canaryHedgeSeconds == 20)
        #expect(canary.sendFresh != nil)
        let vibecop = CloudAuxiliaryEngine.make(role: "vibecop")
        #expect(vibecop.hedgeAfter == nil && vibecop.sendFresh == nil)
    }

    // MARK: - The request path stops when its task is cancelled

    final class HangingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var started = Latch()
        nonisolated(unsafe) static var stopped = Latch()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.started.open() }   // never answers
        override func stopLoading() { Self.stopped.open() }
    }

    @Test("a provider request on a cancelled task cancels its URLSession task")
    func transportStopsOnCancel() async throws {
        HangingProtocol.started = Latch(); HangingProtocol.stopped = Latch()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let task = Task {
            try await OpenAIClient.generateContent(request: request, model: "m", apiKey: "k", baseURL: "http://hang.test/v1", session: session)
        }
        try await value(of: Task { try await HangingProtocol.started.wait() }, within: 10)
        task.cancel()
        try await value(of: Task { try await HangingProtocol.stopped.wait() }, within: 10)
        await #expect(throws: (any Error).self) { try await value(of: task, within: 10) }
    }
}
