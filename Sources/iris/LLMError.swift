import Foundation

/// The error every provider client throws. `message` is a one-line headline fit for the chat;
/// `detail` is the provider's raw body, capped, for a disclosure. Provider bodies can be huge
/// (Vertex 429s carry ~90 KB of internal serving traces), so nothing unbounded is kept.
struct APIError: LocalizedError, Equatable {
    let message: String
    var statusCode: Int? = nil
    var provider: String? = nil
    var detail: String? = nil

    var errorDescription: String? { message }

    /// Rate limits and overloads are transient; everything else is the caller's problem.
    var isRetryable: Bool {
        guard let statusCode else { return false }
        return [429, 503, 529].contains(statusCode)
    }

    static let detailLimit = 2048
    static let headlineLimit = 300

    /// Build from a non-200 response. Handles the Gemini (`error.status`), Anthropic and OpenAI
    /// (`error.type`) JSON shapes, and falls back to the first non-empty line of anything else.
    static func http(provider: String, statusCode: Int, body: Data) -> APIError {
        let raw = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var headline = "\(provider) HTTP \(statusCode)"
        var summary: String?

        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any] {
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
                        detail: raw.isEmpty ? nil : truncated(raw, to: detailLimit))
    }

    static func truncated(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "… [truncated, \(s.count - limit) more characters]"
    }
}

/// Retry transient provider failures (see `APIError.isRetryable`) with a fixed backoff schedule.
/// `delays` is one wait per retry, so `[2, 4, 8]` means up to four attempts. Non-retryable
/// errors and task cancellation propagate immediately.
enum LLMRetry {
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
                let delay = delays[attempt]
                attempt += 1
                await onRetry(error, attempt, delay)
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            }
        }
    }
}
