import Foundation

/// Small, exact statistics for perf records. Behaviour for n = 1 and n = 2 is pinned by tests
/// so reports are unambiguous.
enum PerfStats {
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Nearest-rank percentile: the value at rank ceil(p * n), 1-based.
    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, rank - 1))]
    }

    static func p90(_ xs: [Double]) -> Double? { percentile(xs, 0.90) }

    /// (to - from) / from; nil when the baseline is zero.
    static func percentChange(from a: Double, to b: Double) -> Double? {
        guard a != 0 else { return nil }
        return (b - a) / a
    }
}
