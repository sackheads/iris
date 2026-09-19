import Testing
import Foundation
@testable import iris

/// Transport-level failures (#131a). The first ladder run hit four 60 s URLSession timeouts in
/// about ninety calls and saw legitimate 38 s rounds; a timeout is a `URLError`, which the
/// HTTP-status retry never saw.
@Suite("LLMRetry transport errors and request policy")
struct LLMRetryTests {
    /// Fails `failures` times with `error`, then returns "ok".
    private final class Flaky: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private let error: Error
        private(set) var calls = 0
        init(failures: Int, error: Error) { remaining = failures; self.error = error }
        func attempt() throws -> String {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if remaining > 0 { remaining -= 1; throw error }
            return "ok"
        }
    }

    private final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test("the request policy applies a 180 s timeout to every provider request")
    func policyTimeout() {
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        LLMRequestPolicy.apply(to: &request)
        #expect(LLMRequestPolicy.timeoutSeconds == 180)
        #expect(request.timeoutInterval == 180)
    }

    @Test("a timed-out request is retried and succeeds on the next attempt")
    func timedOutIsRetried() async throws {
        let op = Flaky(failures: 1, error: URLError(.timedOut))
        let notices = Notices()
        let result = try await LLMRetry.run(delays: [0, 0], onRetry: { error, _, _ in notices.append(error.message) }) { try op.attempt() }
        #expect(result == "ok")
        #expect(op.calls == 2)
        #expect(notices.all.count == 1)
        #expect(notices.all.first?.lowercased().contains("timed out") == true)
    }

    @Test("a lost connection is retried")
    func connectionLostIsRetried() async throws {
        let op = Flaky(failures: 1, error: URLError(.networkConnectionLost))
        let result = try await LLMRetry.run(delays: [0]) { try op.attempt() }
        #expect(result == "ok")
        #expect(op.calls == 2)
    }

    @Test("cancellation and other transport errors are not retried")
    func othersAreNotRetried() async {
        for code in [URLError.cancelled, .badServerResponse, .notConnectedToInternet] {
            let op = Flaky(failures: 1, error: URLError(code))
            await #expect(throws: URLError.self) { try await LLMRetry.run(delays: [0, 0]) { try op.attempt() } }
            #expect(op.calls == 1, "\(code)")
        }
    }

    @Test("the attempt cap applies to transport errors too")
    func capApplies() async {
        let op = Flaky(failures: 5, error: URLError(.timedOut))
        await #expect(throws: URLError.self) { try await LLMRetry.run(delays: [0, 0]) { try op.attempt() } }
        #expect(op.calls == 3)
    }

    @Test("HTTP retryability is unchanged: a 429 is retried, a 401 is not")
    func httpUnchanged() async throws {
        let rate = APIError.http(provider: "Gemini", statusCode: 429, body: Data())
        let op = Flaky(failures: 1, error: rate)
        #expect(try await LLMRetry.run(delays: [0]) { try op.attempt() } == "ok")
        let auth = Flaky(failures: 1, error: APIError.http(provider: "Gemini", statusCode: 401, body: Data()))
        await #expect(throws: APIError.self) { try await LLMRetry.run(delays: [0]) { try auth.attempt() } }
    }

    @Test("an interruption after partial output is never retried, even when it wraps a retryable status")
    func interruptedIsNotRetried() async {
        let counter = Counter()
        let wrapped = StreamInterruptedError(underlying: APIError(message: "overloaded", statusCode: 529))
        var thrown: Error?
        do {
            _ = try await LLMRetry.run(delays: [0, 0]) { () -> Int in
                await counter.increment()
                throw wrapped
            }
        } catch { thrown = error }
        #expect(thrown is StreamInterruptedError)
        #expect(await counter.value == 1)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
