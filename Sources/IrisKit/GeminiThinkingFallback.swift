import Foundation

/// #1019: Gemini's `thinkingConfig` fields (`thinkingLevel`, `includeThoughts`) now go to every
/// default user, on whatever route they configured (a custom base URL, a proxy, a model that takes
/// a budget and not a level). A route that rejects one answers 400 for the whole request, so the
/// client drops the field and asks again, once per rung, and remembers what was refused so the next
/// call does not pay the failed round trip. Nothing here matches the error text: a field counts as
/// refused only when the request succeeds without it, because a 400 for the prompt itself (too
/// large, malformed) fails every rung and must not cost the person their setting.
enum GeminiThinkingFallback {
    struct Attempt: Equatable, Sendable {
        var level: String?
        var includeThoughts: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var refusedLevels = Set<String>()
    nonisolated(unsafe) private static var refusedThoughts = Set<String>()

    /// `key` names the route and model (`endpointKey`); a refused level is also keyed by its word,
    /// since a model that takes "low" may refuse "minimal".
    static func endpointKey(authMode: String, baseURL: String, model: String) -> String {
        "\(authMode)|\(baseURL)|\(model)"
    }

    /// The requests to try, in order: the wanted one, then each field dropped alone, then neither.
    /// Fields already known refused are left out of every rung; rungs that repeat are dropped.
    static func ladder(key: String, level: String?, includeThoughts: Bool) -> [Attempt] {
        let (levelRefused, thoughtsRefused) = lock.withLock {
            (level.map { refusedLevels.contains("\(key)|\($0)") } ?? false, refusedThoughts.contains(key))
        }
        let wantLevel = levelRefused ? nil : level
        let wantThoughts = includeThoughts && !thoughtsRefused
        var rungs = [Attempt(level: wantLevel, includeThoughts: wantThoughts)]
        if wantLevel != nil && wantThoughts {
            rungs.append(Attempt(level: nil, includeThoughts: true))
            rungs.append(Attempt(level: wantLevel, includeThoughts: false))
        }
        if wantLevel != nil || wantThoughts { rungs.append(Attempt(level: nil, includeThoughts: false)) }
        var seen: [Attempt] = []
        for rung in rungs where !seen.contains(rung) { seen.append(rung) }
        return seen
    }

    /// Records what the accepted request left out of the one asked for.
    static func remember(key: String, level: String?, includeThoughts: Bool, accepted: Attempt) {
        lock.withLock {
            if let level, accepted.level == nil { refusedLevels.insert("\(key)|\(level)") }
            if includeThoughts, !accepted.includeThoughts { refusedThoughts.insert(key) }
        }
    }

    static func isRefusal(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return api.statusCode == 400 && !CloudAuxiliaryEngine.isModelUnavailable(api)
    }

    static func levelRefused(key: String, level: String) -> Bool {
        lock.withLock { refusedLevels.contains("\(key)|\(level)") }
    }

    static func thoughtsRefused(key: String) -> Bool {
        lock.withLock { refusedThoughts.contains(key) }
    }

    /// Runs `send` down the ladder until a rung is accepted. A non-400 error, or a 400 on the last
    /// rung, throws the first rung's error: that is the request the person asked for.
    /// `laddered: false` sends the one request as asked and lets a 400 through: a caller that
    /// answers the 400 itself (the guard's `sendAsking`, #800) must see it.
    static func run<T>(key: String, level: String?, includeThoughts: Bool, laddered: Bool = true,
                       send: (Attempt) async throws -> T) async throws -> T {
        guard laddered else { return try await send(Attempt(level: level, includeThoughts: includeThoughts)) }
        let rungs = ladder(key: key, level: level, includeThoughts: includeThoughts)
        var firstError: Error?
        for (index, rung) in rungs.enumerated() {
            do {
                let result = try await send(rung)
                if index > 0 { remember(key: key, level: level, includeThoughts: includeThoughts, accepted: rung) }
                return result
            } catch where isRefusal(error) && index < rungs.count - 1 {
                firstError = firstError ?? error
            } catch {
                throw firstError ?? error
            }
        }
        throw firstError ?? APIError(message: "Gemini request failed")
    }

    /// The streaming form: a 400 arrives before the first event, so a rung that fails before
    /// yielding anything is replaced by the next; once an event has gone out the stream is the
    /// caller's and its errors pass through.
    static func stream(key: String, level: String?, includeThoughts: Bool,
                       open: @escaping @Sendable (Attempt) -> AsyncThrowingStream<LLMStreamEvent, Error>)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let rungs = ladder(key: key, level: level, includeThoughts: includeThoughts)
                var firstError: Error?
                for (index, rung) in rungs.enumerated() {
                    var yielded = false
                    do {
                        for try await event in open(rung) {
                            if !yielded {
                                yielded = true
                                if index > 0 { remember(key: key, level: level, includeThoughts: includeThoughts, accepted: rung) }
                            }
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch where !yielded && isRefusal(error) && index < rungs.count - 1 {
                        firstError = firstError ?? error
                    } catch {
                        continuation.finish(throwing: yielded ? error : (firstError ?? error))
                        return
                    }
                }
                continuation.finish(throwing: firstError ?? APIError(message: "Gemini request failed"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
