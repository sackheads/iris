import Foundation

/// Perf-only switches, read once from the environment at `iris --perf run` and passed down.
/// Never a global (invariant 7).
struct PerfExperiments: Sendable, Equatable {
    var declareStateGatedTools = false        // IRIS_PERF_DECLARE_STATE_TOOLS=1 (5a's "declared" arm)
    var stickyTools = true                    // IRIS_PERF_STICKY_TOOLS=0 (5a's "gated" arm)
    var ttlOverride: CacheTTLPolicy? = nil    // IRIS_PERF_TTL=5m|1h|1h-prefix

    static let declareKey = "IRIS_PERF_DECLARE_STATE_TOOLS"
    static let stickyKey = "IRIS_PERF_STICKY_TOOLS"
    static let ttlKey = "IRIS_PERF_TTL"

    /// The `IRIS_PERF_TTL` values: `5m` is every marker at five minutes, `1h` every marker at an
    /// hour, `1h-prefix` an hour on tools and system with history at five minutes.
    static let ttlValues: [(String, CacheTTLPolicy)] = [
        ("5m", .standard),
        ("1h", CacheTTLPolicy(prefix: .oneHour, history: .oneHour)),
        ("1h-prefix", CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes)),
    ]

    static func fromEnvironment(_ env: [String: String],
                                warn: (String) -> Void = { print($0) }) -> PerfExperiments {
        var e = PerfExperiments()
        e.declareStateGatedTools = env[declareKey] == "1"
        e.stickyTools = env[stickyKey] != "0"
        if let raw = env[ttlKey] {
            if let match = ttlValues.first(where: { $0.0 == raw }) {
                e.ttlOverride = match.1
            } else {
                warn("perf: ignoring \(ttlKey)=\(raw); expected one of " + ttlValues.map(\.0).joined(separator: ", "))
            }
        }
        return e
    }

    /// The switches that differ from an ordinary run, as `KEY=value`, for the record.
    var activeNames: [String] {
        var names: [String] = []
        if declareStateGatedTools { names.append("\(Self.declareKey)=1") }
        if !stickyTools { names.append("\(Self.stickyKey)=0") }
        if let ttl = ttlOverride, let label = Self.ttlValues.first(where: { $0.1 == ttl })?.0 {
            names.append("\(Self.ttlKey)=\(label)")
        }
        return names
    }

    /// One report line per recorded switch name. The declare switch keeps its pre-5c line, which
    /// `stateGatedToolsAlwaysDeclared` already prints, so it is not described here.
    static func describe(_ name: String) -> String? {
        switch name {
        case "\(stickyKey)=0":
            return "EXPERIMENT: sticky tool declarations off; state-gated tools come and go with their state (\(stickyKey)=0)"
        case "\(ttlKey)=5m":
            return "EXPERIMENT: every Anthropic cache marker at 5 minutes (\(ttlKey)=5m)"
        case "\(ttlKey)=1h":
            return "EXPERIMENT: every Anthropic cache marker at 1 hour (\(ttlKey)=1h)"
        case "\(ttlKey)=1h-prefix":
            return "EXPERIMENT: tools and system at 1 hour, history at 5 minutes (\(ttlKey)=1h-prefix)"
        case "\(declareKey)=1":
            return nil
        default:
            return "EXPERIMENT: \(name)"
        }
    }
}
