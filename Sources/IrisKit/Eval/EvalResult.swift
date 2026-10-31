import Foundation

/// One eval run, as committed under `eval/results/<task>/`. Every optional is a metric that may
/// not have been measured, and is then left out of the JSON: absent, never zero (spec, section 9).
/// Synthesized `Encodable` writes optionals with `encodeIfPresent`, which is exactly that.
struct EvalResult: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    /// What must be equal for two results to compare (spec, section 9). `compare` refuses a
    /// difference in any part other than the one it's told is meant to differ.
    struct VersionKey: Codable, Equatable, Sendable {
        var task: String
        /// The guard configuration the texts went through, e.g. "tier 1 + 2": a stack result
        /// must never compare with a single-tier one by mistake (#788).
        var configuration: String
        var datasetFamily: String
        var datasetVersion: Int
        var datasetSha256: [String: String]
        var split: String
        /// Nil for a full split. A sample is a fixed set of texts, so equal sizes compare.
        var sample: Int?
        var runtime: String
        var runtimeVersion: String?
        var model: String
        var modelFingerprint: String
        /// Bumped by hand when a metric's meaning changes (a threshold rule, what "caught" means),
        /// never for a cosmetic change to the scorer.
        var scoringVersion: Int
        /// An LLM canary's thinking as sent: "on", "off", or "none" for a model that doesn't think
        /// (#789b). Absent for a classifier.
        var think: String? = nil
        /// Judgements per text (#789b): rates pool them, so a different count doesn't compare.
        /// Absent means one.
        var repeats: Int? = nil
    }

    struct Model: Codable, Equatable, Sendable {
        var spec: String
        var files: [EvalModelFile]?
        var bytesOnDisk: Int?
        var quantisation: String?
        var parameters: String?
        var licence: String?
    }

    struct Environment: Codable, Equatable, Sendable {
        var chip: String?
        var memoryBytes: Int?
        var macos: String
        var onBattery: Bool?
        var irisCommit: String?
        var irisDirty: Bool?
    }

    struct Rate: Codable, Equatable, Sendable {
        var n: Int
        var hits: Int
        /// hits / n, or absent when n is 0.
        var rate: Double?
        /// Fewer than 10 texts: reported, never barred.
        var smallN: Bool

        init(n: Int, hits: Int) {
            self.n = n
            self.hits = hits
            self.rate = n == 0 ? nil : Double(hits) / Double(n)
            self.smallN = n < 10
        }
    }

    struct Band: Codable, Equatable, Sendable {
        /// Upper bound in bytes, inclusive.
        var maxBytes: Int
        var falsePositives: Rate?
        var recall: Rate?
    }

    /// One slice of the scored texts, both rates over it; a side with no texts is absent.
    struct Subset: Codable, Equatable, Sendable {
        var falsePositives: Rate?
        var recall: Rate?
    }

    struct Latency: Codable, Equatable, Sendable {
        var maxBytes: Int
        var n: Int
        var p50Seconds: Double
        var p95Seconds: Double
    }

    struct Metrics: Codable, Equatable, Sendable {
        /// Benign texts with anything withheld or blocked, of those judged (fail-closed and infra apart).
        var falsePositives: Rate
        /// Attacks blocked, or whose payload is gone from what passes on, of those judged.
        var recall: Rate
        var falsePositivesByCategory: [String: Rate]
        var recallByCategory: [String: Rate]
        /// By input size, so a dataset's length mix can't hide a length effect (#785 review).
        var bySize: [Band]
        /// The texts marked `exposure: clean` (v2 on): nothing was tuned or scored on them before
        /// the split. Absent when none were scored.
        var clean: Subset? = nil
        /// v3's fresh attacks (`source: v3-fresh`), written after the split froze and all `test`:
        /// the recall no setting has seen (#789). Absent when none were scored.
        var freshRecall: Rate? = nil
        var failClosed: Int
        var infra: Int
        var rocAuc: Double?
        var highestBenignScore: Double?
        var lowestAttackScore: Double?
        /// The bar (spec, section 10 Q3): aggregate over a full `test` split only; absent otherwise.
        var passes: Bool?
        var latency: [Latency]?
        var loadSeconds: Double?
        var footprintAfterLoadMb: Double?
        var footprintAfterJudgingMb: Double?
        var costPerThousandUsd: Double?
        /// Classifiers: sha256 of every raw score rounded to 4 places, in id order.
        var scoresHash: String?
        /// With repeats: texts whose every judgement agreed, of the texts judged more than once.
        var agreement: Rate? = nil
        /// With repeats: the texts whose judgements disagreed, by id. `compare` leaves them out of
        /// the caught/missed flips (spec, section 9).
        var unstable: [String]? = nil
        /// Canary answers with neither SAFE nor MALICIOUS: the product blocks them, so they are
        /// in `failClosed` too, counted here apart (spec, section 2).
        var parseFailures: Int? = nil
        /// With repeats (#816): the aggregate rates of each repeat alone, in repeat order. The
        /// spread between them is the noise `compare`'s margin rule weighs a difference against.
        /// Absent on a result that didn't record them: "no spread recorded", never a zero spread.
        var falsePositivesByRepeat: [Rate]? = nil
        var recallByRepeat: [Rate]? = nil
    }

    struct Verdict: Codable, Equatable, Sendable {
        var id: String
        /// passed, withheld, blocked, fail-closed or infra.
        var outcome: String
        var caught: Bool?
        var rawScore: Double?
        var seconds: Double?
        /// Which judgement of the text this is, from 0, when a run repeats (#789b).
        var repeatIndex: Int? = nil
        /// `injection.stack` from scoring version 2 (#830): which tier blocked ("tier2", "tier3",
        /// "tier3_after_partial" or "none") and tier 2's verdict ("safe", "partial", "malicious",
        /// "error" or "skipped"). Absent on older rows and other tasks, never a guess.
        var blockedBy: String? = nil
        var tier2Verdict: String? = nil
    }

    var schemaVersion = EvalResult.schemaVersion
    var key: VersionKey
    var date: String
    var model: Model
    var environment: Environment
    /// The settings the product scored with (threshold, windows, caps), as text.
    var settings: [String: String]
    /// "pre-split" when the settings were chosen with this dataset's test texts in view; from v2
    /// on, "pre-split: N of M texts", counting the scored texts marked so.
    var contaminated: String?
    var modelChanged: Bool?
    var previousFingerprint: String?
    var metrics: Metrics
    var verdicts: [Verdict]
    /// Results this one replaces, by file name. A wrong result is superseded, never edited.
    var supersedes: [String]?
    var notes: [String]?

    static func decode(_ data: Data) throws -> EvalResult {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(EvalResult.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
