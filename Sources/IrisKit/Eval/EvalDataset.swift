import CryptoKit
import Foundation

/// One labelled text. `payload` is set for an attack: the distinctive part of the injected
/// instruction, whose absence from what the guard passes on means the attack was caught.
struct EvalSample: Codable, Equatable, Sendable {
    var id: String
    var category: String
    var source: String
    var split: String
    var text: String
    var payload: String?

    var isAttack: Bool { payload != nil }
    var bytes: Int { text.utf8.count }
}

/// A frozen dataset version (`eval/datasets/<family>/v<N>/`), checked against its manifest.
struct EvalDataset: Sendable {
    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable {
            var sha256: String
            var count: Int
        }
        var family: String
        var version: Int
        var files: [String: File]
    }

    var manifest: Manifest
    var samples: [EvalSample]

    static let fileNames = ["benign.jsonl", "attacks.jsonl"]

    /// Loads and verifies: a file whose sha256 or count differs from the manifest is refused,
    /// since a result would then name a version it wasn't scored on.
    static func load(from dir: URL) throws -> EvalDataset {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        var samples: [EvalSample] = []
        for name in fileNames {
            guard let expected = manifest.files[name] else { throw EvalError.datasetMismatch("\(name) is not in the manifest") }
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let digest = EvalFingerprint.hex(SHA256.hash(data: data))
            guard digest == expected.sha256 else { throw EvalError.datasetMismatch("\(name) sha256 \(digest), manifest \(expected.sha256)") }
            let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
                try JSONDecoder().decode(EvalSample.self, from: Data($0.utf8))
            }
            guard rows.count == expected.count else { throw EvalError.datasetMismatch("\(name) has \(rows.count) rows, manifest \(expected.count)") }
            samples += rows
        }
        return EvalDataset(manifest: manifest, samples: samples)
    }

    var sha256s: [String: String] { manifest.files.mapValues(\.sha256) }

    /// The texts of `split` ("test", "dev" or "all"), optionally a fixed sample of about `sample`
    /// of them: stratified by label and category, and the same texts every time, so two sampled
    /// runs compare. Each stratum keeps at least one text.
    func select(split: String, sample: Int?) -> [EvalSample] {
        let pool = samples.filter { split == "all" || $0.split == split }
        guard let sample, sample < pool.count else { return pool.sorted { $0.id < $1.id } }
        let strata = Dictionary(grouping: pool) { "\($0.isAttack ? "attack" : "benign")/\($0.category)" }
        var chosen: [EvalSample] = []
        for (_, members) in strata {
            let share = max(1, Int((Double(members.count) * Double(sample) / Double(pool.count)).rounded()))
            chosen += members.sorted { Self.sampleKey($0.id) < Self.sampleKey($1.id) }.prefix(share)
        }
        return chosen.sorted { $0.id < $1.id }
    }

    static func sampleKey(_ id: String) -> String {
        EvalFingerprint.hex(SHA256.hash(data: Data("eval-sample:\(id)".utf8)))
    }
}
