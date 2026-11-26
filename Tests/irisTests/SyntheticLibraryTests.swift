import CryptoKit
import Foundation
import Testing
@testable import IrisKit

/// #1395: the synthetic library the background guard checker (#1391-#1394) is measured against. These are the
/// structural checks CI runs; the timed guard pass is `SyntheticLibraryGuardTiming`, opt-in.
@Suite("a synthetic library for the background guard checker (#1395)")
struct SyntheticLibraryTests {
    private static let corpus = try! EvalDataset.load(from: EvalRunner.defaultDataset(PerfPaths.repoRoot()))
    private var attacks: [EvalSample] { Self.corpus.samples.filter(\.isAttack) }

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-1395-\(UUID().uuidString)")
    }

    private func markdown(under dir: URL) -> [URL] {
        let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }
    }

    private func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }

    @Test("the same seed writes the same library; another seed doesn't")
    func deterministic() throws {
        let a = temp(), b = temp(), c = temp()
        defer { for dir in [a, b, c] { try? FileManager.default.removeItem(at: dir) } }
        let one = try SyntheticLibrary.generate(count: 100, shape: .home, seed: 7, attacks: attacks, into: a)
        let two = try SyntheticLibrary.generate(count: 100, shape: .home, seed: 7, attacks: attacks, into: b)
        let other = try SyntheticLibrary.generate(count: 100, shape: .home, seed: 8, attacks: attacks, into: c)
        #expect(one == two)
        #expect(other.digest != one.digest)
        let first = try Data(contentsOf: IrisPaths(root: a).memoryDir.appendingPathComponent(one.notes[0].path))
        #expect(try Data(contentsOf: IrisPaths(root: b).memoryDir.appendingPathComponent(two.notes[0].path)) == first)
    }

    @Test("a home library is written where a home keeps one, sized like the release home", arguments: [100, 500, 2_000])
    func homeShape(count: Int) throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try SyntheticLibrary.generate(count: count, shape: .home, seed: 1395, attacks: attacks, into: root)
        let paths = IrisPaths(root: root)
        let library = markdown(under: paths.libraryDir).count, artifacts = markdown(under: paths.artifactsDir).count
        #expect(library + artifacts == count)
        #expect(manifest.notes.count == count)
        #expect(GuardTrustStore.covers(paths.libraryDir.appendingPathComponent("x.md").path, paths: paths))
        // The release home: 5 of 48 notes in library/, median 4.3 KB, none over 17 KB.
        #expect((0.04...0.2).contains(Double(library) / Double(count)), "\(library) of \(count) in library/")
        let sizes = manifest.notes.filter { $0.sample == nil }.map(\.bytes)
        #expect((3_000...6_000).contains(median(sizes)), "median \(median(sizes))")
        // The size cap, plus the last paragraph and the links that can follow it.
        #expect(sizes.allSatisfy { $0 <= 33_000 }, "max \(sizes.max() ?? 0)")
    }

    @Test("every injection note carries a corpus sample verbatim, and no other note carries any payload")
    func attacksComeFromTheCorpus() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try SyntheticLibrary.generate(count: 500, shape: .home, seed: 3, attacks: attacks, into: root)
        let base = IrisPaths(root: root).memoryDir
        let byId = Dictionary(uniqueKeysWithValues: attacks.map { ($0.id, $0) })
        #expect(manifest.attacks.count == 25, "5% of 500")
        for note in manifest.attacks {
            let sample = try #require(note.sample.flatMap { byId[$0] }, "\(note.sample ?? "nil") is not a corpus attack")
            let text = try String(contentsOf: base.appendingPathComponent(note.path), encoding: .utf8)
            #expect(text.contains(sample.text), "\(note.path) doesn't hold \(sample.id) verbatim")
            #expect(note.payload == sample.payload)
        }
        let payloads = attacks.compactMap(\.payload)
        for note in manifest.notes where note.sample == nil {
            let text = try String(contentsOf: base.appendingPathComponent(note.path), encoding: .utf8)
            #expect(!payloads.contains { text.contains($0) }, "benign \(note.path) holds a payload")
        }
    }

    @Test("a vault is many small notes in nested folders, with wiki links")
    func vaultShape() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try SyntheticLibrary.generate(count: 2_000, shape: .vault, seed: 1398, attacks: attacks, into: root)
        #expect(markdown(under: root).count == 2_000)
        let depths = manifest.notes.map { $0.path.split(separator: "/").count - 1 }
        #expect(depths.max() == 4 && depths.contains(0) && depths.contains(2), "depths \(Set(depths).sorted())")
        let sizes = manifest.notes.filter { $0.sample == nil }.map(\.bytes)
        #expect((1_000...2_200).contains(median(sizes)), "median \(median(sizes))")
        let linked = try manifest.notes.prefix(200).filter {
            try String(contentsOf: root.appendingPathComponent($0.path), encoding: .utf8).contains("[[")
        }
        #expect(linked.count > 100)
    }

    @Test("it refuses to write into a real home", arguments: [IrisPaths.standard.root, IrisPaths.release.root])
    func refusesRealHome(home: URL) throws {
        let inside = home.appendingPathComponent("iris-1395-must-not-exist-\(UUID().uuidString)")
        #expect(throws: SyntheticLibrary.Refusal.self) {
            try SyntheticLibrary.generate(count: 1, shape: .vault, seed: 1, attacks: attacks, into: inside)
        }
        #expect(throws: SyntheticLibrary.Refusal.self) { try SyntheticLibrary.flood(count: 1, into: inside, seed: 1) }
        #expect(throws: SyntheticLibrary.Refusal.self) {
            try SyntheticLibrary.generate(count: 1, shape: .home, seed: 1, attacks: attacks, into: home)
        }
        #expect(!FileManager.default.fileExists(atPath: inside.path))
    }

    @Test("the write flood writes 10,000 files, and can record them as Iris's own writes")
    func flood() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let written = try SyntheticLibrary.flood(into: dir, seed: 1391)
        #expect(written.count == 10_000 && Set(written).count == 10_000)
        #expect(markdown(under: dir).count == 10_000)

        // The trust store rewrites its whole file per write, so the recorded flood is kept small here.
        let trusted = temp(), trustFile = temp().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: trusted); try? FileManager.default.removeItem(at: trustFile) }
        let trust = GuardTrustStore(file: trustFile)
        let recorded = try SyntheticLibrary.flood(count: 200, into: trusted, seed: 1391, trust: trust)
        #expect(try recorded.allSatisfy { trust.isClean(try Data(contentsOf: $0)) })
    }
}

/// #1395's timed pass: every sampled note judged by the product guard (tier 1, a passing tier 2, the canary) on a
/// real model, extrapolated to a full pass at each library size. Opt-in: `IRIS_SYNTH_GUARD_MODEL=ollama:gemma4:12b`
/// (any `EvalModelSpec`), optionally `IRIS_SYNTH_SAMPLE=<notes per shape>` (default 40) and `IRIS_SYNTH_OUT=<dir>` for a copy of each benign note that was blocked. It holds the build slot
/// (rule 33) and takes about 18 s a note on gemma.
@Suite("the guard's time over a synthetic library (#1395, opt-in)",
       .enabled(if: ProcessInfo.processInfo.environment["IRIS_SYNTH_GUARD_MODEL"] != nil, "opt-in: IRIS_SYNTH_GUARD_MODEL=<model spec>"),
       .serialized)
struct SyntheticLibraryGuardTiming {
    @Test("seconds per note, and a full pass extrapolated to each size")
    func timing() async throws {
        let env = ProcessInfo.processInfo.environment
        let spec = try #require(env["IRIS_SYNTH_GUARD_MODEL"].flatMap(EvalModelSpec.parse), "not a model spec")
        let perShape = env["IRIS_SYNTH_SAMPLE"].flatMap(Int.init) ?? 40
        let canary = try await EvalGuardTask.canary(spec, think: .product)
        let out = env["IRIS_SYNTH_OUT"].map { URL(fileURLWithPath: $0) }
        // Cold: an Ollama model is evicted first (keep_alive 0), so the first judgement pays the load, as the
        // first read after a launch or an idle unload does. Its own server reloads it on the next call.
        if spec.runtime == .ollama, var request = URL(string: "http://localhost:11434/api/generate").map({ URLRequest(url: $0) }) {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": spec.name, "keep_alive": 0])
            _ = try? await URLSession.shared.data(for: request)
        }
        var cold = true
        let config = EvalGuardTask.guardConfig(canary: spec, tier2: true, thinkingLevel: canary.thinkingLevel)
        let attacks = try SyntheticLibrary.corpusAttacks(repoRoot: PerfPaths.repoRoot())
        for (shape, count, sizes) in [(SyntheticLibrary.Shape.home, 2_000, [100, 500, 2_000]), (.vault, 10_000, [2_000, 5_000, 10_000])] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1395-timing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let manifest = try SyntheticLibrary.generate(count: count, shape: shape, seed: 1395, attacks: attacks, into: root)
            let base = shape == .home ? IrisPaths(root: root).memoryDir : root
            // Every 1-in-k note, so the sample keeps the library's mix of sizes and attacks.
            let sample = stride(from: 0, to: manifest.notes.count, by: max(1, manifest.notes.count / perShape)).map { manifest.notes[$0] }
            var seconds: [Double] = [], blockedBenign = 0, blockedAttack = 0
            for note in sample {
                let text = try String(contentsOf: base.appendingPathComponent(note.path), encoding: .utf8)
                let start = MonotonicClock.nowMs()
                let result = await EvalGuardTask.product(text, canary: canary.engine, config: config,
                                                         tier2: .init(GuardProbeFixtures.PassingTier2()))
                let took = (MonotonicClock.nowMs() - start) / 1000
                // One line a note, for the size breakdown; the cold call is kept out of the warm figures.
                print("synthetic-library: note \(shape.rawValue) \(cold ? "cold" : "warm") \(String(format: "%.2f", took)) s "
                      + "\(note.bytes) bytes \(result.outcome.rawValue) \(note.sample ?? "benign") \(note.path)")
                if cold { cold = false } else { seconds.append(took) }
                if result.outcome != .passed {
                    if note.sample == nil { blockedBenign += 1 } else { blockedAttack += 1 }
                    if note.sample == nil {
                        // A sampled canary may block once and pass the next time: judge it again to see which.
                        var again: [String] = []
                        for _ in 0..<5 {
                            again.append(await EvalGuardTask.product(text, canary: canary.engine, config: config,
                                                                     tier2: .init(GuardProbeFixtures.PassingTier2())).outcome.rawValue)
                        }
                        print("synthetic-library: rejudged \(note.path): \(again.joined(separator: " "))")
                        if let out {
                            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                            try? text.write(to: out.appendingPathComponent(note.path.replacingOccurrences(of: "/", with: "_")), atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            let sorted = seconds.sorted(), mean = seconds.reduce(0, +) / Double(seconds.count)
            let attacksSampled = sample.filter { $0.sample != nil }.count
            print("synthetic-library: \(shape.rawValue) \(spec.runtime.rawValue):\(spec.name), \(sample.count) notes sampled of \(count): "
                  + String(format: "mean %.1f s, median %.1f s, p95 %.1f s", mean, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
                  + "; blocked \(blockedBenign) of \(sample.count - attacksSampled) benign, \(blockedAttack) of \(attacksSampled) attacks")
            for size in sizes {
                print("synthetic-library: \(shape.rawValue) full pass at \(size) notes: "
                      + String(format: "%.1f h at N=1, %.1f h at N=2", mean * Double(size) / 3600, 2 * mean * Double(size) / 3600))
            }
        }
        if spec.runtime != .ollama, !canary.paid { await canary.engine.unloadModel() }
    }
}
