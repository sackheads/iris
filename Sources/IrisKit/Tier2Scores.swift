import Foundation

/// Tier 2's score for each input it judged, per context tag (#238), so its flat 0.9 threshold can
/// be calibrated per source from data. Kept on this Mac in `metrics/tier2-scores.json`, never sent:
/// tags and numbers only, never the text judged. Nothing reads it to decide anything, so a file
/// edited outside Iris can only skew what the Diagnostics table shows.
final class Tier2Scores: @unchecked Sendable {
    /// What tier 2 did with an input.
    enum Outcome: String, Codable, Sendable { case passed, withheld, blocked }

    /// One tag's record: every input counted, the last `kept` scores for the percentiles.
    struct Tag: Codable, Equatable, Sendable {
        var count = 0
        var withheld = 0
        var blocked = 0
        var recent: [Double] = []
        /// When it was last recorded, as a running count across every tag: the eviction order.
        var lastRecorded = 0
    }

    /// One row of the summary.
    struct Summary: Equatable, Sendable, Identifiable {
        var tag: String
        var count: Int
        var withheld: Int
        var blocked: Int
        var p50: Double
        var p95: Double
        var max: Double
        var id: String { tag }

        /// The Diagnostics row's cells, in its columns' order: source, inputs, p50, p95, max, the
        /// share of inputs with lines withheld, the share blocked whole.
        var cells: [String] {
            [tag, "\(count)", Self.score(p50), Self.score(p95), Self.score(max), Self.share(withheld, of: count), Self.share(blocked, of: count)]
        }

        static func score(_ value: Double) -> String { String(format: "%.3f", value) }
        static func share(_ part: Int, of whole: Int) -> String {
            whole == 0 ? "0%" : String(format: "%.1f%%", Double(part) / Double(whole) * 100)
        }
    }

    /// The scores kept per tag for the percentiles: recent enough to follow a model change,
    /// enough for a p95 that means something.
    static let kept = 200
    /// The most tags kept, the least recently recorded dropped first (#768 review): a tag can
    /// carry an MCP tool's, a plugin rule's or an event source's own name, so they're open-ended.
    static let maxTags = 100
    /// How long a record waits before it's written, so a burst of tool outputs is one write.
    static let saveDelaySeconds: Double = 5

    let url: URL?
    private let lock = NSLock()
    private var tags: [String: Tag]
    private var recorded = 0
    private var savePending = false
    private let queue = DispatchQueue(label: "iris.tier2-scores")

    /// `url` nil keeps the scores in memory only (a test's own store).
    init(url: URL?) {
        self.url = url
        tags = [:]
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        // A file that won't read starts the record over: it's measurements, not a decision.
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: Tag].self, from: data) {
            tags = stored.mapValues { var t = $0; t.recent = Array(t.recent.suffix(Self.kept)); return t }
            recorded = tags.values.map(\.lastRecorded).max() ?? 0
        } else {
            print("[Tier2Scores] \(url.path) couldn't be read; starting the record over (#238).")
        }
    }

    static let shared = Tier2Scores(url: IrisPaths.default.tier2ScoresJSON)

    /// A test's own store, so a guard call it makes records nowhere else (Invariant 7).
    @TaskLocal static var scoped: Tier2Scores?
    static var current: Tier2Scores { scoped ?? shared }

    func record(tag: String, score: Double, outcome: Outcome) {
        guard score.isFinite else { return }
        let schedule: Bool = lock.withLock {
            var t = tags[tag] ?? Tag()
            t.count += 1
            if outcome == .withheld { t.withheld += 1 }
            if outcome == .blocked { t.blocked += 1 }
            t.recent.append(score)
            if t.recent.count > Self.kept { t.recent.removeFirst(t.recent.count - Self.kept) }
            recorded += 1
            t.lastRecorded = recorded
            tags[tag] = t
            if tags.count > Self.maxTags, let stalest = tags.min(by: { $0.value.lastRecorded < $1.value.lastRecorded })?.key {
                tags[stalest] = nil
            }
            guard url != nil, !savePending else { return false }
            savePending = true
            return true
        }
        if schedule { queue.asyncAfter(deadline: .now() + Self.saveDelaySeconds) { self.save() } }
    }

    /// The table, busiest tag first.
    func summary() -> [Summary] {
        let snapshot = lock.withLock { tags }
        return snapshot.map { tag, t in
            let sorted = t.recent.sorted()
            return Summary(tag: tag, count: t.count, withheld: t.withheld, blocked: t.blocked,
                           p50: Self.percentile(sorted, 0.5), p95: Self.percentile(sorted, 0.95), max: sorted.last ?? 0)
        }.sorted { ($0.count, $1.tag) > ($1.count, $0.tag) }
    }

    /// Nearest-rank on sorted values; 0 for none.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count, Swift.max(rank, 1)) - 1]
    }

    /// Written now, and whatever was waiting with it.
    func save() {
        guard let url else { return }
        let snapshot: [String: Tag] = lock.withLock {
            savePending = false
            return tags
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
