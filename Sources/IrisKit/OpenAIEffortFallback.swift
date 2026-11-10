import Foundation

/// #1020: Chat Completions' `reasoning_effort` now goes to every OpenAI user who picks one, on
/// whatever route and model they configured. A model that takes no effort (gpt-4o, a local server),
/// or a word it does not list (`none` and `xhigh` are newer than `minimal`), answers 400 for the
/// whole request, so the client asks again without the field, once, and remembers per route, model
/// and word. Nothing here matches the error text: the effort counts as refused only when the
/// request succeeds without it, because a 400 for the prompt itself fails both and must not cost
/// the person their setting (the same rule as `GeminiThinkingFallback`, #1019).
enum OpenAIEffortFallback {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refused = Set<String>()

    static func key(baseURL: String, model: String, effort: String) -> String { "\(baseURL)|\(model)|\(effort)" }

    static func isRefused(_ key: String) -> Bool { lock.withLock { refused.contains(key) } }

    static func isRefusal(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return api.statusCode == 400 && !CloudAuxiliaryEngine.isModelUnavailable(api)
    }

    /// Runs `send` with `effort`, or without it when known refused; a 400 is answered once without.
    static func run<T>(key: String, effort: String?, send: (String?) async throws -> T) async throws -> T {
        guard let effort else { return try await send(nil) }
        if isRefused(key) { return try await send(nil) }
        do {
            return try await send(effort)
        } catch where isRefusal(error) {
            let first = error
            do {
                let result = try await send(nil)
                lock.withLock { _ = refused.insert(key) }
                return result
            } catch { throw first }
        }
    }

    /// The streaming form: a 400 comes before the first event, so only a stream that fails before
    /// yielding anything is reopened without the effort.
    static func stream(key: String, effort: String?,
                       open: @escaping @Sendable (String?) -> AsyncThrowingStream<LLMStreamEvent, Error>)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        guard let effort else { return open(nil) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var first: Error?
                for (index, sent) in ([isRefused(key) ? nil : effort, nil] as [String?]).enumerated() {
                    if index == 1 && (first == nil) { break }
                    var yielded = false
                    do {
                        for try await event in open(sent) {
                            if !yielded {
                                yielded = true
                                if index == 1 { lock.withLock { _ = refused.insert(key) } }
                            }
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch where !yielded && index == 0 && sent != nil && isRefusal(error) {
                        first = error
                    } catch {
                        continuation.finish(throwing: yielded ? error : (first ?? error))
                        return
                    }
                }
                continuation.finish(throwing: first ?? APIError(message: "OpenAI request failed"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
