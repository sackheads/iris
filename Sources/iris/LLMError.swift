import Foundation

/// The error every provider client throws. `message` is a one-line headline fit for the chat;
/// `detail` is the provider's raw body, capped, for a disclosure. Provider bodies can be huge
/// (Vertex 429s carry ~90 KB of internal serving traces), so nothing unbounded is kept.
struct APIError: LocalizedError, Equatable {
    let message: String
    var statusCode: Int? = nil
    var provider: String? = nil
    var detail: String? = nil
    /// Seconds the provider asked us to wait (`Retry-After`), when it sent one.
    var retryAfter: TimeInterval? = nil

    var errorDescription: String? { message }

    /// Rate limits and overloads are transient; everything else is the caller's problem.
    var isRetryable: Bool {
        guard let statusCode else { return false }
        return [429, 503, 529].contains(statusCode)
    }

    static let detailLimit = 2048
    static let headlineLimit = 300

    /// Build from a non-200 response. Handles the Gemini (`error.status`), Anthropic and OpenAI
    /// (`error.type`) JSON shapes, including the array-wrapped form (`[{"error": {...}}]`) some
    /// Google endpoints and proxies return, and falls back to the first non-empty line of
    /// anything else. Pass the response headers so a `Retry-After` can steer the backoff.
    static func http(provider: String, statusCode: Int, body: Data, headers: [AnyHashable: Any] = [:]) -> APIError {
        let raw = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var headline = "\(provider) HTTP \(statusCode)"
        var summary: String?

        if let error = errorObject(in: body) {
            let label = (error["status"] as? String) ?? (error["type"] as? String)
            if let label, !label.isEmpty { headline += " \(label)" }
            summary = error["message"] as? String
        } else if !raw.isEmpty {
            summary = raw.split(whereSeparator: \.isNewline).first.map(String.init)
        }

        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            headline += ": " + truncated(summary, to: headlineLimit)
        }
        return APIError(message: headline, statusCode: statusCode, provider: provider,
                        detail: raw.isEmpty ? nil : truncated(raw, to: detailLimit),
                        retryAfter: retryAfter(from: headers))
    }

    /// The `error` dictionary from a top-level object or from the first element of an array.
    private static func errorObject(in body: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else { return nil }
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        return object?["error"] as? [String: Any]
    }

    /// Parse `Retry-After` (delay-seconds or an HTTP-date). Header names match case-insensitively
    /// because `allHeaderFields` preserves whatever casing the server used.
    static func retryAfter(from headers: [AnyHashable: Any], now: Date = Date()) -> TimeInterval? {
        guard let entry = headers.first(where: { ($0.key as? String)?.caseInsensitiveCompare("Retry-After") == .orderedSame }),
              let value = (entry.value as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        if let date = httpDateFormatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func truncated(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "… [truncated, \(s.count - limit) more characters]"
    }
}

/// Retry transient provider failures (see `APIError.isRetryable`) with a backoff schedule.
/// `delays` is one wait per retry, so `[2, 4, 8]` means up to four attempts. Non-retryable
/// errors and task cancellation propagate immediately.
/// Per-request settings every provider client applies before hitting the network.
enum LLMRequestPolicy {
    /// URLSession's default is 60 s; the first perf ladder saw legitimate 38 s rounds and four
    /// 60 s timeouts in ~90 calls. 180 s covers the observed tail while still bounding a hung
    /// connection. Streaming (#131) will make this less load-bearing.
    static let timeoutSeconds: TimeInterval = 180

    static func apply(to request: inout URLRequest) {
        request.timeoutInterval = timeoutSeconds
    }

    /// Transport failures worth one more try on the same schedule as a 429: the request never
    /// got an answer. Cancellation and everything else propagate immediately.
    static let retryableTransportErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost]

    /// Plain wording for the `[retry]` line; a bare URLError only names its numeric code.
    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "request timed out after \(Int(timeoutSeconds)) s"
        case .networkConnectionLost: return "network connection lost"
        default: return URLError(code).localizedDescription
        }
    }
}

enum LLMRetry {
    /// Waits are spread by up to this fraction so agents that fail together do not re-fire
    /// together against an already-exhausted quota.
    static let jitterFraction = 0.25
    /// A provider's `Retry-After` is honored up to this many seconds.
    static let retryAfterCap: TimeInterval = 60

    /// The wait before the next attempt. A `Retry-After` from the provider wins over the
    /// scheduled delay and is only ever stretched (0…+25%), never cut short; a scheduled delay
    /// is jittered both ways (±25%). `unitRandom` is injectable for tests.
    static func wait(scheduled: TimeInterval, retryAfter: TimeInterval?,
                     unitRandom: Double = .random(in: 0...1)) -> TimeInterval {
        if let retryAfter {
            return min(max(retryAfter, 0), retryAfterCap) * (1 + jitterFraction * unitRandom)
        }
        return max(scheduled, 0) * (1 + jitterFraction * (2 * unitRandom - 1))
    }

    static func run<T>(
        delays: [TimeInterval],
        onRetry: @Sendable (APIError, Int, TimeInterval) async -> Void = { _, _, _ in },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as APIError where error.isRetryable && attempt < delays.count {
                let delay = wait(scheduled: delays[attempt], retryAfter: error.retryAfter)
                attempt += 1
                await onRetry(error, attempt, delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch let error as URLError where LLMRequestPolicy.retryableTransportErrors.contains(error.code) && attempt < delays.count {
                let delay = wait(scheduled: delays[attempt], retryAfter: nil)
                attempt += 1
                // Synthesized so the existing `[retry]` notice renders the transport failure.
                await onRetry(APIError(message: LLMRequestPolicy.describe(error.code)), attempt, delay)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}
