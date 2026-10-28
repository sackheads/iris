import Foundation

/// What a local model is being loaded for, as a person would name it (#779).
enum ModelLoadPurpose: Sendable, Equatable {
    case guardTier2
    case guardTier3
    case vibecop
    case vision
    case other(String)

    /// The purpose of an `AuxiliaryModelManager` role. The guard runs tier 3 as "canary"; Settings
    /// and the Setup Wizard test the same model as "promptGuard".
    init(role: String) {
        switch role {
        case "canary", "promptGuard": self = .guardTier3
        case "vibecop": self = .vibecop
        case "vision": self = .vision
        default: self = .other(role)
        }
    }

    var label: String {
        switch self {
        case .guardTier2: return "guard (tier 2)"
        case .guardTier3: return "guard (tier 3)"
        case .vibecop: return "Vibecop"
        case .vision: return "vision"
        case .other(let role): return role
        }
    }
}

/// One load in flight.
struct ModelLoad: Sendable, Equatable, Identifiable {
    let id: UUID
    let purpose: ModelLoadPurpose
    let name: String
    /// `MonotonicClock` milliseconds: a load's age is uptime, not wall time.
    let startedAtMs: Double
}

/// Begin and end of every local model load, keyed by a per-load UUID (#778). Transient, like
/// `commandStartTimes` (Invariant 5): what is loading now, in this process, never persisted.
/// Each begin and end is also a timestamped `PerformanceProfiler` event, so the timings #778
/// measures and the status line #779 shows come from the same calls.
final class ModelLoadTracker: @unchecked Sendable {
    static let shared = ModelLoadTracker()

    enum Outcome: Sendable, Equatable {
        case loaded
        case failed(String)
    }

    private let lock = NSLock()
    private var loads: [UUID: ModelLoad] = [:]
    private let now: @Sendable () -> Double
    private let log: @Sendable (String) -> Void

    init(now: @escaping @Sendable () -> Double = { MonotonicClock.nowMs() },
         log: @escaping @Sendable (String) -> Void = { PerformanceProfiler.event($0) }) {
        self.now = now
        self.log = log
    }

    @discardableResult
    func begin(_ purpose: ModelLoadPurpose, name: String) -> UUID {
        let load = ModelLoad(id: UUID(), purpose: purpose, name: name, startedAtMs: now())
        lock.withLock { loads[load.id] = load }
        log("model.load begin purpose=\"\(purpose.label)\" name=\(name) id=\(load.id.uuidString.prefix(8))")
        return load.id
    }

    /// Ends a load. A second end, or one for an id never begun, does nothing, so a caller's
    /// cleanup path can always call it.
    func end(_ id: UUID, _ outcome: Outcome, detail: String = "") {
        guard let load = lock.withLock({ loads.removeValue(forKey: id) }) else { return }
        let ms = Int((now() - load.startedAtMs).rounded())
        let result: String
        switch outcome {
        case .loaded: result = "loaded"
        case .failed(let why): result = "failed error=\"\(why)\""
        }
        let extra = detail.isEmpty ? "" : " \(detail)"
        log("model.load end purpose=\"\(load.purpose.label)\" name=\(load.name) id=\(id.uuidString.prefix(8)) ms=\(ms) \(result)\(extra)")
    }

    /// Loads in flight, oldest first.
    var active: [ModelLoad] {
        lock.withLock { loads.values.sorted { ($0.startedAtMs, $0.id.uuidString) < ($1.startedAtMs, $1.id.uuidString) } }
    }

    /// Runs `work` as one load: ended as loaded when it returns and as failed when it throws.
    func track<T>(_ purpose: ModelLoadPurpose, name: String,
                  isolation: isolated (any Actor)? = #isolation,
                  _ work: () async throws -> T) async throws -> T {
        let id = begin(purpose, name: name)
        do {
            let result = try await work()
            end(id, .loaded)
            return result
        } catch {
            end(id, .failed("\(error)"))
            throw error
        }
    }
}
