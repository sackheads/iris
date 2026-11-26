import CryptoKit
import Foundation
@testable import IrisKit

/// #1395 (part 0 of the background guard checker, #1391-#1394): a fake library to measure against, since a real
/// one barely exists yet. Deterministic from a seed, so two runs compare byte for byte.
///
/// Two shapes. `.home` is an Iris home's `library/` and `artifacts/`, fitted to the release home on 2026-11-26 (48
/// notes: 5 in `library/`, 43 in `artifacts/`; log-normal sizes, median 4.3 KB, mu 8.365, sigma 0.736, largest 16.7
/// KB). `.vault` is an Obsidian-like folder for external libraries (#1398): many small notes, `[[wiki links]]`,
/// folders up to four deep. Its sizes (median 1.5 KB, sigma 1.0) are an assumption, not a measurement.
///
/// A slice of notes carry an injection sample, and only ever one taken verbatim from the guard eval corpus
/// (`EvalGuardTask`'s dataset): no new attack payloads (#802). The rest is generated prose that asks nothing of
/// anyone.
///
/// Test tooling, so it lives with the tests (dev-3's #1401 review); #1391-#1394 measure through opt-in suites like
/// `SyntheticLibraryGuardTiming`.
enum SyntheticLibrary {
    enum Shape: String, Codable, Sendable {
        case home, vault

        /// Log-normal size parameters (bytes) and the clamp around them.
        var size: (mu: Double, sigma: Double, min: Int, max: Int) {
            switch self {
            case .home: return (8.365, 0.736, 400, 32_000)
            case .vault: return (7.313, 1.0, 120, 32_000)
            }
        }
    }

    struct Note: Codable, Equatable, Sendable {
        /// Relative to the root `generate` wrote into.
        var path: String
        var bytes: Int
        /// The corpus sample's id and payload, for an attack note.
        var sample: String?
        var payload: String?
    }

    struct Manifest: Codable, Equatable, Sendable {
        var shape: Shape
        var seed: UInt64
        var notes: [Note]
        /// sha256 over every note's path and bytes, in order: equal digests are equal libraries.
        var digest: String
        var attacks: [Note] { notes.filter { $0.sample != nil } }
    }

    enum Refusal: Error, Equatable {
        /// The root is, or is inside, a real Iris home.
        case realHome(String)
        case noAttacks
    }

    static let defaultAttackShare = 0.05

    /// The attack samples of the eval's default dataset, loaded through its manifest check.
    static func corpusAttacks(repoRoot: URL) throws -> [EvalSample] {
        try EvalDataset.load(from: EvalRunner.defaultDataset(repoRoot)).samples.filter(\.isAttack)
    }

    /// Writes `count` notes under `root`: for `.home` into `IrisPaths(root:)`'s library and artifacts folders, for
    /// `.vault` straight into `root`. Refuses a real home.
    @discardableResult
    static func generate(count: Int, shape: Shape, seed: UInt64, attacks: [EvalSample],
                         attackShare: Double = defaultAttackShare, into root: URL) throws -> Manifest {
        try refuseRealHome(root)
        guard !attacks.isEmpty || attackShare == 0 else { throw Refusal.noAttacks }
        var rng = SplitMix64(seed: seed)
        let base = shape == .home ? IrisPaths(root: root).memoryDir : root
        let folders = Self.folders(shape, count: count, rng: &rng)
        let titles = (0..<count).map { _ in Words.title(&rng) }
        let pool = attacks.sorted { $0.id < $1.id }
        let attackCount = Int((Double(count) * attackShare).rounded())
        var attackSlots = Set<Int>()
        while attackSlots.count < min(attackCount, count) { attackSlots.insert(Int.random(in: 0..<count, using: &rng)) }

        var notes: [Note] = []
        var hasher = SHA256()
        for i in 0..<count {
            let folder = folders[Int.random(in: 0..<folders.count, using: &rng)]
            let name = titles[i].lowercased().replacingOccurrences(of: " ", with: "-") + "-\(i).md"
            let path = folder.isEmpty ? name : folder + "/" + name
            let target = Self.size(shape, &rng)
            let links = (0..<Int.random(in: 0...3, using: &rng)).map { _ in titles[Int.random(in: 0..<count, using: &rng)] }
            var sample: EvalSample?
            if attackSlots.contains(i) { sample = pool[Int.random(in: 0..<pool.count, using: &rng)] }
            let text = Self.body(title: titles[i], target: target, shape: shape, links: links, embedding: sample?.text, rng: &rng)
            let file = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: file)
            hasher.update(data: Data(path.utf8)); hasher.update(data: data)
            notes.append(Note(path: path, bytes: data.count, sample: sample?.id, payload: sample?.payload))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Manifest(shape: shape, seed: seed, notes: notes, digest: digest)
    }

    /// #1391's write flood: `count` small notes written as fast as the disk takes them, in one folder under `dir`.
    /// With `trust`, each is recorded as Iris's own clean write, as `write_file` would, for the trusted-skip check.
    /// Returns the paths written.
    @discardableResult
    static func flood(count: Int = 10_000, into dir: URL, seed: UInt64, trust: GuardTrustStore? = nil) throws -> [URL] {
        try refuseRealHome(dir)
        var rng = SplitMix64(seed: seed)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [URL] = []
        written.reserveCapacity(count)
        for i in 0..<count {
            let text = "# Flood \(i)\n\n" + Words.sentence(&rng) + "\n"
            let file = dir.appendingPathComponent("flood-\(i).md")
            try Data(text.utf8).write(to: file)
            trust?.recordCleanWrite(path: file.path, content: text)
            written.append(file)
        }
        return written
    }

    private static func refuseRealHome(_ root: URL) throws {
        let target = root.standardizedFileURL.resolvingSymlinksInPath().path
        for home in [IrisPaths.standard.root, IrisPaths.release.root] {
            let real = home.standardizedFileURL.resolvingSymlinksInPath().path
            if target == real || target.hasPrefix(real + "/") { throw Refusal.realHome(real) }
        }
    }

    private static func size(_ shape: Shape, _ rng: inout SplitMix64) -> Int {
        // Box-Muller: one standard normal from two uniforms.
        let u1 = max(Double.random(in: 0..<1, using: &rng), .leastNonzeroMagnitude)
        let u2 = Double.random(in: 0..<1, using: &rng)
        let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        let p = shape.size
        return min(p.max, max(p.min, Int(exp(p.mu + p.sigma * z))))
    }

    /// `.home`: the release home's folders. `.vault`: about one folder per 25 notes, nested up to four deep.
    private static func folders(_ shape: Shape, count: Int, rng: inout SplitMix64) -> [String] {
        switch shape {
        case .home:
            // 5 of 48 notes are in library/, so library gets 1 slot in 10.
            let library = ["library/lessons", "library/protocols"]
            let artifacts = ["iris", "garden", "taxes"].flatMap { p in ["plans", "specs", "issues", "reviews"].map { "artifacts/\(p)/\($0)" } }
            return library + Array(artifacts.prefix(library.count * 9))
        case .vault:
            var out = [""]
            for _ in 0..<max(1, count / 25) {
                let parent = out[Int.random(in: 0..<out.count, using: &rng)]
                guard parent.split(separator: "/").count < 4 else { continue }
                let name = Words.title(&rng)
                out.append(parent.isEmpty ? name : parent + "/" + name)
            }
            return out
        }
    }

    /// A note of about `target` bytes; `embedding`, a corpus sample, goes in verbatim between two paragraphs.
    private static func body(title: String, target: Int, shape: Shape, links: [String], embedding: String?,
                             rng: inout SplitMix64) -> String {
        var parts: [String] = []
        if shape == .home || Bool.random(using: &rng) {
            parts.append("---\ntitle: \(title)\ntags: [\(Words.word(&rng)), \(Words.word(&rng))]\n---")
        }
        parts.append("# \(title)")
        var size = parts.joined(separator: "\n\n").utf8.count + (embedding?.utf8.count ?? 0)
        var blocks: [String] = []
        while size < target {
            let block: String
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: block = "## " + Words.title(&rng)
            case 1: block = "### " + Words.title(&rng)
            case 2, 3: block = (0..<Int.random(in: 2...5, using: &rng)).map { _ in "- " + Words.sentence(&rng) }.joined(separator: "\n")
            case 4: block = "```swift\nlet \(Words.word(&rng)) = \(Int.random(in: 1...999, using: &rng))\n```"
            default: block = (0..<Int.random(in: 2...6, using: &rng)).map { _ in Words.sentence(&rng) }.joined(separator: " ")
            }
            blocks.append(block)
            size += block.utf8.count + 2
        }
        if let embedding { blocks.insert(embedding, at: Int.random(in: 0...blocks.count, using: &rng)) }
        if !links.isEmpty {
            blocks.append(shape == .vault ? "Related: " + links.map { "[[\($0)]]" }.joined(separator: ", ")
                                          : "See also: " + links.map { "[\($0)](\($0.lowercased().replacingOccurrences(of: " ", with: "-")).md)" }.joined(separator: ", "))
        }
        return (parts + blocks).joined(separator: "\n\n") + "\n"
    }

    /// Plain words for plain prose: nothing in here instructs a reader.
    private enum Words {
        static let all = """
        garden tomato basil compost soil seed harvest rain sunlight trellis budget receipt invoice ledger quarter \
        estimate refund deadline meeting agenda minutes summary draft outline chapter section index appendix \
        recipe flour butter oven simmer pantry kettle bicycle tyre chain gear commute route ferry station \
        library shelf archive folder notebook margin sketch diagram figure table column row chart weekly monthly \
        river valley ridge trail campsite lantern map compass weather forecast cloud breeze harbour lighthouse \
        build test release branch module parser cache index queue worker timer request response latency metric \
        sample measure baseline result review comment question answer reference citation source quote footnote
        """.split(separator: " ").map(String.init)

        static func word(_ rng: inout SplitMix64) -> String { all[Int.random(in: 0..<all.count, using: &rng)] }

        static func title(_ rng: inout SplitMix64) -> String {
            (0..<Int.random(in: 2...4, using: &rng)).map { _ in word(&rng).capitalized }.joined(separator: " ")
        }

        static func sentence(_ rng: inout SplitMix64) -> String {
            let words = (0..<Int.random(in: 6...16, using: &rng)).map { _ in word(&rng) }
            return words.joined(separator: " ").prefix(1).uppercased() + words.joined(separator: " ").dropFirst() + "."
        }
    }
}

/// A seeded generator, so a library is the same for the same seed (`SystemRandomNumberGenerator` isn't seedable).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
