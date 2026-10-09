import Foundation

public enum MetricOperationType: String, CaseIterable, Identifiable, Sendable {
    case vibecop = "Vibecop"
    case easy = "Model (Easy)"
    case medium = "Model (Medium)"
    case hard = "Model (Hard)"
    case rename = "Rename"
    case auxiliary = "Auxiliary"
    case promptGuardTier2 = "Prompt Guard (Tier 2)"
    case promptGuardTier3 = "Prompt Guard (Tier 3)"
    
    public var id: String { rawValue }
}

public struct AggregatedLatencyMetric: Identifiable, Sendable {
    public let id: String
    public let operation: MetricOperationType
    public let modelName: String
    public var count: Int = 0
    public var minMs: Double = .greatestFiniteMagnitude
    public var maxMs: Double = -.greatestFiniteMagnitude
    public var avgMs: Double = 0
    private var m2: Double = 0
    
    public var stddevMs: Double {
        if count < 2 { return 0.0 }
        return sqrt(m2 / Double(count - 1))
    }
    
    public init(operation: MetricOperationType, modelName: String) {
        self.id = "\(operation.rawValue)-\(modelName)"
        self.operation = operation
        self.modelName = modelName
    }
    
    public mutating func update(durationMs: Double) {
        count += 1
        if durationMs < minMs { minMs = durationMs }
        if durationMs > maxMs { maxMs = durationMs }
        
        let delta = durationMs - avgMs
        avgMs += delta / Double(count)
        let delta2 = durationMs - avgMs
        m2 += delta * delta2
    }
}

@MainActor
public class MetricsManager: ObservableObject {
    public static let shared = MetricsManager()
    
    @Published public var aggregatedMetrics: [AggregatedLatencyMetric] = []
    
    private init() {}
    
    public func trackLatency(operation: MetricOperationType, modelName: String, durationMs: Double, success: Bool = true) {
        guard success else { return } // optionally only track successful requests for latency stats
        
        let id = "\(operation.rawValue)-\(modelName)"
        if let index = aggregatedMetrics.firstIndex(where: { $0.id == id }) {
            aggregatedMetrics[index].update(durationMs: durationMs)
        } else {
            var newMetric = AggregatedLatencyMetric(operation: operation, modelName: modelName)
            newMetric.update(durationMs: durationMs)
            aggregatedMetrics.append(newMetric)
        }
    }
}
