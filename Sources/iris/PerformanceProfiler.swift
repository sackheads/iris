import Foundation
import Combine

/// A subsystem bucket a slice of command-execution time is attributed to.
/// "Other" is not a case here — it is derived in the view as the remainder.
public enum PerfCategory: String, CaseIterable, Sendable {
    case primaryLLM
    case toolExecution
    case vibecop
    case injectionGuard
    case hooks
    case contextAssembly

    public var displayName: String {
        switch self {
        case .primaryLLM: return "Primary LLM"
        case .toolExecution: return "Tool execution"
        case .vibecop: return "Vibecop"
        case .injectionGuard: return "Injection guard"
        case .hooks: return "Hooks"
        case .contextAssembly: return "Context assembly"
        }
    }

    /// Vibecop and the injection guard run *inside* the tool phase, so the UI shows them
    /// indented under tool execution rather than as additive top-level rows.
    public var isGuardSubMeasure: Bool {
        self == .vibecop || self == .injectionGuard
    }
}

public struct CategoryStat: Codable, Sendable, Equatable {
    public var ms: Double = 0
    public var count: Int = 0

    public init(ms: Double = 0, count: Int = 0) { self.ms = ms; self.count = count }

    public mutating func add(_ durationMs: Double) {
        ms += durationMs
        count += 1
    }
}

/// One model round within a turn. Token counts come from the provider's usage metadata and
/// are nil for the fake client.
public struct ModelCallRecord: Codable, Sendable, Equatable {
    public let round: Int
    public let model: String
    /// Wall time of the whole call including any retry backoff; the `primaryLLM` bucket excludes backoff.
    public let latencyMs: Double
    public let promptTokens: Int?
    public let outputTokens: Int?
    public let returnedToolCalls: Bool

    public init(round: Int, model: String, latencyMs: Double, promptTokens: Int?, outputTokens: Int?, returnedToolCalls: Bool) {
        self.round = round; self.model = model; self.latencyMs = latencyMs
        self.promptTokens = promptTokens; self.outputTokens = outputTokens; self.returnedToolCalls = returnedToolCalls
    }
}

/// One dispatched tool call. `ok` is false when the executor returned an error string.
public struct ToolCallRecord: Codable, Sendable, Equatable {
    public let name: String
    public let ms: Double
    public let ok: Bool

    public init(name: String, ms: Double, ok: Bool) {
        self.name = name; self.ms = ms; self.ok = ok
    }
}

public struct CommandProfile: Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let source: String
    public let startedAt: Date
    public var totalMs: Double = 0
    public var categories: [PerfCategory: CategoryStat] = [:]
    /// Named sub-spans finer than the six buckets, e.g. "guard.tier2", "assembly.userProfile".
    public var spans: [String: CategoryStat] = [:]
    public var modelCalls: [ModelCallRecord] = []
    public var toolCalls: [ToolCallRecord] = []

    public init(id: UUID, label: String, source: String, startedAt: Date) {
        self.id = id
        self.label = label
        self.source = source
        self.startedAt = startedAt
    }

    public mutating func add(_ category: PerfCategory, durationMs: Double) {
        categories[category, default: CategoryStat()].add(durationMs)
    }

    public mutating func addSpan(_ name: String, durationMs: Double) {
        spans[name, default: CategoryStat()].add(durationMs)
    }

    /// Unattributed remainder: turn wall-clock minus the sequential top-level phases.
    /// Guard sub-measures (vibecop/injection) are excluded because they are already counted
    /// inside tool execution.
    public var derivedOtherMs: Double {
        func ms(_ c: PerfCategory) -> Double { categories[c]?.ms ?? 0 }
        let topLevel = ms(.primaryLLM) + ms(.toolExecution) + ms(.hooks) + ms(.contextAssembly)
        return max(0, totalMs - topLevel)
    }
}

public final class PerformanceProfiler: ObservableObject, @unchecked Sendable {
    public static let shared = PerformanceProfiler()
    public static let maxRecent = 20

    /// Bound at the top of a turn (`IrisEngine.processInput`). Inherited by child tasks
    /// (e.g. parallel tool calls), so spans attribute to the right command automatically.
    @TaskLocal public static var currentTurnID: UUID?

    /// Observed by the diagnostics UI. Only mutated on the main thread.
    @Published public private(set) var recentCommands: [CommandProfile] = []

    private let lock = NSLock()
    private var active: [UUID: CommandProfile] = [:]

    /// Task-local sink for finished turn profiles, fired inline in `endTurn`. Nil in the shipping
    /// app (which observes `recentCommands`). A headless driver binds it around its own turns so it
    /// collects ONLY the profiles produced within that task tree — turns run by other concurrent
    /// work (e.g. parallel tests) inherit a nil sink and are never captured.
    @TaskLocal public static var runSink: (@Sendable (CommandProfile) -> Void)?

    public init() {}

    public func beginTurn(label: String, source: String) -> UUID {
        let id = UUID()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
        let profile = CommandProfile(id: id, label: short.isEmpty ? "(empty)" : short,
                                     source: source, startedAt: Date())
        lock.lock()
        active[id] = profile
        lock.unlock()
        return id
    }

    public func record(turnID: UUID?, category: PerfCategory, durationMs: Double) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.add(category, durationMs: durationMs)
        lock.unlock()
    }

    public func recordSpan(turnID: UUID?, name: String, durationMs: Double) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.addSpan(name, durationMs: durationMs)
        lock.unlock()
    }

    public func recordModelCall(turnID: UUID?, _ call: ModelCallRecord) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.modelCalls.append(call)
        lock.unlock()
    }

    public func recordToolCall(turnID: UUID?, _ call: ToolCallRecord) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.toolCalls.append(call)
        lock.unlock()
    }

    public func endTurn(_ id: UUID, totalMs: Double) {
        lock.lock()
        var profile = active.removeValue(forKey: id)
        lock.unlock()
        guard profile != nil else { return }
        profile!.totalMs = totalMs
        let finished = profile!
        // Fire the task-local sink first so a headless driver sees this run's result without a
        // runloop tick, and without capturing turns from other concurrent work.
        Self.runSink?(finished)
        // @Published mutation must happen on the main thread.
        if Thread.isMainThread {
            appendRecent(finished)
        } else {
            DispatchQueue.main.async { [weak self] in self?.appendRecent(finished) }
        }
    }

    private func appendRecent(_ profile: CommandProfile) {
        recentCommands.append(profile)
        if recentCommands.count > Self.maxRecent {
            recentCommands.removeFirst(recentCommands.count - Self.maxRecent)
        }
    }

    // MARK: - Test hooks
    #if DEBUG
    func activeProfileForTesting(_ id: UUID) -> CommandProfile? {
        lock.lock(); defer { lock.unlock() }
        return active[id]
    }
    var activeCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return active.count
    }
    #endif
}

/// Time an async subsystem span and attribute it to the current turn.
/// Inherits the caller's actor isolation (`#isolation`) so the work closure can safely touch
/// actor-isolated state without crossing an isolation boundary.
@discardableResult
public func measure<T>(_ category: PerfCategory,
                       isolation: isolated (any Actor)? = #isolation,
                       _ work: () async throws -> T) async rethrows -> T {
    let turnID = PerformanceProfiler.currentTurnID
    let start = CFAbsoluteTimeGetCurrent()
    do {
        let result = try await work()
        PerformanceProfiler.shared.record(turnID: turnID, category: category,
                                          durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
        return result
    } catch {
        PerformanceProfiler.shared.record(turnID: turnID, category: category,
                                          durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
        throw error
    }
}

/// Time a synchronous subsystem span and attribute it to the current turn.
@discardableResult
public func measureSync<T>(_ category: PerfCategory, _ work: () throws -> T) rethrows -> T {
    let turnID = PerformanceProfiler.currentTurnID
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        PerformanceProfiler.shared.record(turnID: turnID, category: category,
                                          durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
    }
    return try work()
}

/// Time an async span under a free-form name and attribute it to the current turn.
@discardableResult
public func measureSpan<T>(_ name: String,
                           isolation: isolated (any Actor)? = #isolation,
                           _ work: () async throws -> T) async rethrows -> T {
    let turnID = PerformanceProfiler.currentTurnID
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        PerformanceProfiler.shared.recordSpan(turnID: turnID, name: name,
                                              durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
    }
    return try await work()
}

/// Synchronous sibling of `measureSpan`.
@discardableResult
public func measureSpanSync<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
    let turnID = PerformanceProfiler.currentTurnID
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        PerformanceProfiler.shared.recordSpan(turnID: turnID, name: name,
                                              durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
    }
    return try work()
}
