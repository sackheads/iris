import Testing
import Foundation
@testable import iris

/// #345: `withTimeout` returns at the deadline, whether or not the operation listens to
/// cancellation. Every wait here is bounded by the operation itself (nothing parks forever), and
/// every test has a `.timeLimit` backstop.
@Suite("withTimeout", .timeLimit(.minutes(1)))
struct TimeoutTests {
    @Test("fast operation returns its value")
    func fastReturns() async throws {
        let v = try await withTimeout(seconds: 2) { () -> Int in 42 }
        #expect(v == 42)
    }

    @Test("slow operation throws TimeoutError")
    func slowThrows() async {
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
        }
    }

    /// The bug: a task group waits for every child, so an operation that never looks at
    /// cancellation held `withTimeout` for its whole duration.
    @Test("an operation that ignores cancellation is abandoned at the deadline")
    func nonCooperativeReturnsAtDeadline() async {
        let started = Date()
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.2) { () -> Int in
                await Self.ignoresCancellation(seconds: 2)
                return 1
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "returned after \(elapsed)s; the deadline was 0.2s")
    }

    @Test("a blocking operation is abandoned at the deadline")
    func blockingReturnsAtDeadline() async {
        let started = Date()
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.2) { () -> Int in
                Self.block(seconds: 2)
                return 1
            }
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test("a cooperative operation that finishes in time returns its value")
    func cooperativeInTime() async throws {
        let v = try await withTimeout(seconds: 5) { () -> String in
            try await Task.sleep(nanoseconds: 20_000_000)
            return "done"
        }
        #expect(v == "done")
    }

    struct Boom: Error, Equatable {}

    @Test("an error thrown by the operation propagates")
    func errorPropagates() async {
        await #expect(throws: Boom.self) {
            try await withTimeout(seconds: 5) { () -> Int in
                try await Task.sleep(nanoseconds: 10_000_000)
                throw Boom()
            }
        }
    }

    @Test("the operation is cancelled when the deadline passes")
    func operationSeesCancellationOnTimeout() async {
        let saw = Flag()
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.1) { () -> Int in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { saw.set() }
                return 1
            }
        }
        #expect(await saw.becomesTrue(within: 2))
    }

    @Test("cancelling the caller cancels the operation and returns promptly")
    func callerCancellationPropagates() async {
        let saw = Flag()
        let caller = Task {
            try await withTimeout(seconds: 30) { () -> Int in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { saw.set() }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        caller.cancel()
        let result = await caller.result
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(await saw.becomesTrue(within: 2))
    }

    @Test("cancelling the caller returns promptly even when the operation ignores it")
    func callerCancellationNonCooperative() async {
        let caller = Task {
            try await withTimeout(seconds: 30) { () -> Int in
                await Self.ignoresCancellation(seconds: 3)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        caller.cancel()
        let result = await caller.result
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("a caller already cancelled throws without waiting for the deadline")
    func alreadyCancelled() async {
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withTimeout(seconds: 30) { () -> Int in
                await Self.ignoresCancellation(seconds: 3)
                return 1
            }
        }
        let started = Date()
        let result = await caller.result
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// A caller that has already given up must not start the work at all: for `run_command` that
    /// would spawn a process only to terminate it.
    @Test("a caller already cancelled never runs the operation")
    func alreadyCancelledNeverStarts() async {
        let runs = Counter()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withTimeout(seconds: 30) { () -> Int in
                runs.increment()
                return 1
            }
        }
        let result = await caller.result
        #expect(throws: CancellationError.self) { try result.get() }
        // Bounded grace for a wrongly started body to show up before counting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(runs.value == 0)
    }

    /// The result and the timer land within microseconds of each other; a second resume of the
    /// continuation would trap, so surviving the loop is the assertion.
    @Test("result and deadline racing never resume twice")
    func tightRace() async {
        var values = 0, timeouts = 0
        for i in 0..<200 {
            do {
                let v = try await withTimeout(seconds: 0.0005) { () -> Int in
                    if i.isMultiple(of: 2) { try? await Task.sleep(nanoseconds: 500_000) }
                    return i
                }
                #expect(v == i)
                values += 1
            } catch is TimeoutError {
                timeouts += 1
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
        #expect(values + timeouts == 200)
    }

    // MARK: - helpers

    /// Holds a thread for `seconds`, like a synchronous native call.
    static func block(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// Suspends for `seconds` on a continuation nothing cancels, like a native inference call.
    static func ignoresCancellation(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func becomesTrue(within seconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if isSet { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return isSet
        }
    }
}
