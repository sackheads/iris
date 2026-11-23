import Testing
import Foundation

/// The deadline reports this test injects, with the task-local each ran under, so a row can check
/// it was reported in the waiter's own task (#1343: there, Swift Testing finds the current test).
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(message: String, line: Int, marker: String?)] = []
    func add(_ message: String, _ location: SourceLocation) {
        let marker = Reports.marker
        lock.withLock { all.append((message, location.line, marker)) }
    }
    var list: [(message: String, line: Int, marker: String?)] { lock.withLock { all } }
    @TaskLocal static var marker: String?
}

/// `TestGate` (#1343): a stub's wait ends on a release, its task's cancellation or the gate's deadline.
@Suite("TestGate ends a wait on release, cancel or deadline (#1343)", .timeLimit(.minutes(1)))
struct TestGateTests {
    private static func gate(deadline: Double = 30, _ reports: Reports) -> TestGate {
        TestGate(deadline: deadline, onTimeout: { reports.add($0, $1) })
    }

    @Test("open latches: a parked wait and every later one pass")
    func openLatches() async throws {
        let reports = Reports(), gate = Self.gate(reports)
        let parked = Task { await gate.wait() }
        try await gate.waitForArrivals(1, within: 10)
        gate.open()
        try await value(of: parked, within: 10)
        try await value(of: Task { await gate.wait() }, within: 10)
        #expect(gate.waiting == 0 && gate.arrivals == 2)
        #expect(reports.list.isEmpty)
    }

    @Test("releaseWaiting frees who is parked and does not latch")
    func releaseWaitingDoesNotLatch() async throws {
        let reports = Reports(), gate = Self.gate(reports)
        let first = Task { await gate.wait() }
        try await gate.waitForArrivals(1, within: 10)
        gate.releaseWaiting()
        try await value(of: first, within: 10)
        let second = Task { await gate.wait() }
        try await gate.waitForArrivals(2, within: 10)
        #expect(gate.waiting == 1, "a wait after releaseWaiting parks again")
        gate.releaseWaiting()
        try await value(of: second, within: 10)
        #expect(reports.list.isEmpty)
    }

    @Test("release frees the oldest parked wait first, and a permit with nobody parked is banked")
    func releaseIsFIFOAndBanked() async throws {
        let reports = Reports(), gate = Self.gate(reports)
        let order = Reports()
        let a = Task { await gate.wait(); order.add("a", #_sourceLocation) }
        try await gate.waitForArrivals(1, within: 10)
        let b = Task { await gate.wait(); order.add("b", #_sourceLocation) }
        try await gate.waitForArrivals(2, within: 10)
        gate.release()
        try await value(of: a, within: 10)
        #expect(gate.waiting == 1 && order.list.map(\.message) == ["a"])
        gate.release()
        try await value(of: b, within: 10)
        gate.release(2)
        try await value(of: Task { await gate.wait() }, within: 10)
        try await value(of: Task { await gate.wait() }, within: 10)
        #expect(gate.waiting == 0)
        let third = Task { await gate.wait() }
        try await gate.waitForArrivals(5, within: 10)
        #expect(gate.waiting == 1, "two banked permits pass two waits, not three")
        gate.open()
        try await value(of: third, within: 10)
        #expect(reports.list.isEmpty)
    }

    @Test("cancelling the waiter's task ends its wait, parked or not yet parked, and reports nothing")
    func cancelEndsTheWait() async throws {
        let reports = Reports(), gate = Self.gate(reports)
        let parked = Task { await gate.wait() }
        try await gate.waitForArrivals(1, within: 10)
        parked.cancel()
        try await value(of: parked, within: 10)
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await gate.wait()
        }
        try await value(of: early, within: 10)
        #expect(gate.waiting == 0 && gate.arrivals == 2)
        #expect(reports.list.isEmpty, "a cancelled wait is not a missed deadline")
    }

    @Test("a deadline ends the wait, reported in the waiter's own task at the wait's call site")
    func deadlineReportsInTheWaitersTask() async throws {
        let reports = Reports(), gate = Self.gate(deadline: 0.2, reports)
        let line = #line + 1
        let waiter = Task { await Reports.$marker.withValue("waiter") { await gate.wait() } }
        try await value(of: waiter, within: 10)
        #expect(gate.waiting == 0)
        let got = reports.list
        #expect(got.count == 1)
        #expect(got.first?.message == "the gate was not released within 0.2s")
        #expect(got.first?.line == line, "reported at the caller's wait(), not inside the gate")
        #expect(got.first?.marker == "waiter", "reported in the waiter's task, where the current test is, not on the timer's queue")
    }

    @Test("waitOrThrow throws CancellationError on cancel and TestGateDeadline at the deadline")
    func waitOrThrowThrows() async throws {
        let reports = Reports(), gate = Self.gate(deadline: 0.2, reports)
        let cancelled = Task { () -> String in
            do { try await gate.waitOrThrow(); return "released" } catch { return "\(type(of: error))" }
        }
        try await gate.waitForArrivals(1, within: 10)
        cancelled.cancel()
        #expect(try await value(of: cancelled, within: 10) == "CancellationError")
        #expect(reports.list.isEmpty)
        let late = Task { () -> String in
            do { try await gate.waitOrThrow(); return "released" } catch { return "\(type(of: error))" }
        }
        #expect(try await value(of: late, within: 10) == "TestGateDeadline")
        #expect(reports.list.count == 1)
        gate.open()
        #expect(try await value(of: Task { try await gate.waitOrThrow(); return "released" }, within: 10) == "released")
    }

    @Test("waitForArrivals ends at its bound, reporting how many came")
    func waitForArrivalsIsBounded() async throws {
        let reports = Reports(), gate = Self.gate(reports)
        let start = TestClock.now()
        await #expect(throws: BoundedWaitTimeout.self) { try await gate.waitForArrivals(1, within: 0.2) }
        #expect(TestClock.seconds(since: start) < 5)
        #expect(reports.list.map(\.message) == ["1 arrivals at the gate did not come within 0.2s (0 did)"])
    }

    @Test("a release, a cancel and the deadline racing for one wait resume it exactly once")
    func racingClaimantsResumeOnce() async throws {
        let reports = Reports()
        for i in 0..<500 {
            let gate = Self.gate(deadline: 0.001 * Double(i % 4), reports)
            let waiter = Task { await gate.wait() }
            if i % 2 == 0 { try await gate.waitForArrivals(1, within: 10) }   // half race on a parked wait
            switch i % 3 {
            case 0: gate.release()
            case 1: waiter.cancel()
            default: gate.release(); waiter.cancel()
            }
            // A double resume traps a CheckedContinuation; a lost one hangs here until the bound.
            try await value(of: waiter, within: 10)
            #expect(gate.waiting == 0)
        }
    }

    @Test("by default a missed deadline records an issue, so a gate in a passing test cannot time out unnoticed")
    func defaultReporterRecordsAnIssue() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("BoundedWait.swift"), encoding: .utf8)
        #expect(source.contains("self.onTimeout = onTimeout ?? { message, location in Issue.record(Comment(rawValue: message), sourceLocation: location) }"))
    }
}
